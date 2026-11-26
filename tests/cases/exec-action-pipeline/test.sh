#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action --pipeline: a theory publishes its outline under its own key
# before proving, a child loading ahead of it starts on that outline, and
# the child commits only once the parent's final entry passes the gate
# against the outline it loaded.

tmpdir=$(make_temp_dir)
background=()
cleanup() {
  for pid in ${background[@]+"${background[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "pipe"

[build]
members = ["src"]
TOML

# Proofs the outline stubs, slow enough for a child to take the outline
# before the parent's final entry arrives, in steps short enough for the
# tactic timeout.  a_imp uses no theorem from disk, so it is exported
# without the DISK_THM oracle its outline stub carries.
pause='(fn g => (OS.Process.sleep (Time.fromSeconds 2); ALL_TAC g))'
cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool

Theorem a_thm:
  T /\ T
Proof
  $pause >> $pause >> $pause >> $pause >> CONJ_TAC >> ACCEPT_TAC TRUTH
QED

Theorem a_imp:
  p ==> p
Proof
  DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC
QED
SML
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A

Theorem b_thm:
  T
Proof
  ACCEPT_TAC (CONJUNCT1 a_thm)
QED
SML
# O's proof makes an oracle, which nothing in scope shows, so its outline
# lacks it and P's gate fails.
cat > "$project/src/OScript.sml" <<SML
Theory O
Ancestors bool

Theorem o_thm:
  T
Proof
  $pause >> $pause >> $pause >> (fn (asl, w) => ACCEPT_TAC (mk_oracle_thm "made_here" (asl, w)) (asl, w))
QED
SML
cat > "$project/src/PScript.sml" <<'SML'
Theory P
Ancestors O

Theorem p_thm:
  T
Proof
  ACCEPT_TAC o_thm
QED
SML
# R's deferred proofs depend on each other's stubs, so its pipelined build
# fails and it builds again with its proofs in place.
cat > "$project/src/RScript.sml" <<'SML'
Theory R
Ancestors bool

val r = ref TRUTH;
Theorem r_thm:
  T
Proof
  (fn g => ACCEPT_TAC (!r) g)
QED
val _ = r := r_thm;
SML
# Q loads ahead of O and R, for a cache failure once O's outline is in.
cat > "$project/src/QScript.sml" <<'SML'
Theory Q
Ancestors O R

Theorem q_thm:
  T
Proof
  ACCEPT_TAC o_thm
QED
SML
# E declares an extra output, which a pipelined build doesn't install.
cat > "$project/src/EScript.sml" <<'SML'
Theory E
Ancestors bool

fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["E.nsv"]
val _ = let val out = TextIO.openOut "E.nsv" in TextIO.output (out, "E\n"); TextIO.closeOut out end

Theorem e_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML
# The build's target, which isn't pipelined: a target saves checkpoints.
cat > "$project/src/ZScript.sml" <<'SML'
Theory Z
Ancestors B E P Q R

Theorem z_thm:
  T
Proof
  ACCEPT_TAC b_thm
QED
SML

hb() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@")
}

# worker_command NAME SPEC [OPTION...]: exec-action in its own cache root and
# cwd, as a separate worker container would.
worker_command() {
  local name=$1 spec=$2
  shift 2
  local cache=$tmpdir/worker-$name
  link_hol_toolchain_cache "$cache"
  mkdir -p "$tmpdir/cwd-$name"
  (cd "$tmpdir/cwd-$name" &&
     HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
       --cache-limit-gb 1000 --result "$tmpdir/$name.result" "$@") > "$tmpdir/$name.log" 2>&1
}
worker() {
  set +e
  worker_command "$@"
  worker_status=$?
  set -e
}
declare -A worker_pid
worker_start() {
  worker_command "$@" &
  worker_pid[$1]=$!
  background+=("$!")
}
worker_wait() {
  set +e
  wait "${worker_pid[$1]}"
  worker_status=$?
  set -e
}
await_marker() {
  local path=$tmpdir/worker-$1/action/.holbuild/ahead/$2
  for _ in {1..1200}; do
    [[ -e "$path" ]] && return 0
    if ! kill -0 "${worker_pid[$1]}" 2>/dev/null; then break; fi
    sleep 0.1
  done
  echo "worker $1 never wrote $2" >&2
  cat "$tmpdir/$1.log" "$tmpdir/$1.result" >&2 || true
  exit 1
}
expect() {
  local name=$1 code=$2
  shift 2
  if [[ "$worker_status" != "$code" ]]; then
    echo "worker $name exited $worker_status, wanted $code" >&2
    cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2 || true
    exit 1
  fi
  require_grep '^holbuild-action-result-v1$' "$tmpdir/$name.result"
  for line in "$@"; do
    grep -qxF -- "$line" "$tmpdir/$name.result" || {
      echo "worker $name result lacks '$line':" >&2
      cat "$tmpdir/$name.result" "$tmpdir/$name.log" >&2
      exit 1
    }
  done
}
require_no_grep() {
  if grep -q -- "$1" "$2"; then echo "unexpected '$1' in $2" >&2; cat "$2" >&2; exit 1; fi
}
phase() { grep -qE "^phase-ms=(.*,)?$2:" "$tmpdir/$1.result"; }

spec_for() { awk -v want="$2" '$1 == "action" && $5 == want { print $4 }' "$1"; }
key_for() { awk -v want="$2" '$1 == "action" && $5 == want { print $2 }' "$1"; }
ac_of() { printf 'holbuild-remote-ac-v1\n%s\n' "$1" | sha256sum | cut -d' ' -f1; }
outline_ac_of() { ac_of "$(printf 'holbuild-outline-v1\n%s\n' "$1" | sha256sum | cut -d' ' -f1)"; }

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$tmpdir/control"
hb action-spec --upload ZTheory > "$tmpdir/batch.txt"
for theory in A B E O P Q R Z; do
  declare "spec_$theory=$(spec_for "$tmpdir/batch.txt" "pipe:${theory}Theory")"
  declare "key_$theory=$(key_for "$tmpdir/batch.txt" "pipe:${theory}Theory")"
done
# The client lets each theory but the target pipeline.
for spec in "$spec_A" "$spec_B" "$spec_O" "$spec_P" "$spec_Q" "$spec_R"; do
  require_grep '^option pipeline=true$' "$tmpdir/remote/cas/$spec"
done
for spec in "$spec_E" "$spec_Z"; do
  require_no_grep '^option pipeline=true$' "$tmpdir/remote/cas/$spec"
done

# B starts on A's outline while A proves, and commits once A's final entry
# passes the gate.
worker_start b "$spec_B" --ahead-parent "$key_A:$spec_A" --pipeline
await_marker b waiting-ATheory
worker_start a "$spec_A" --pipeline
# The worker learns of the outline from a file beside the result, once the
# outline is in the cache under its own key, while A still proves.
for _ in {1..600}; do
  [[ -e "$tmpdir/a.result.outline" ]] && break
  kill -0 "${worker_pid[a]}" 2>/dev/null || break
  sleep 0.05
done
require_file "$tmpdir/a.result.outline"
require_file "$tmpdir/remote/ac/$(outline_ac_of "$key_A")"
[[ ! -e "$tmpdir/remote/ac/$(ac_of "$key_A")" ]] || { echo "A published its entry before proving" >&2; exit 1; }
worker_wait a
expect a 0 "status=built"
require_grep 'pipeline: published the outline' "$tmpdir/a.log"
worker_wait b
expect b 0 "status=built"
grep -qE '^phase-ms=(.*,)?outlined:1(,|$)' "$tmpdir/b.result" || {
  echo "B did not start on A's outline:" >&2; cat "$tmpdir/b.result" "$tmpdir/b.log" >&2; exit 1
}
# How long B, its run done, waited for A's final entry: some time, since
# A's proof pauses well past B's run.
grep -qE '^phase-ms=(.*,)?finalswait:[1-9][0-9]*(,|$)' "$tmpdir/b.result" || {
  echo "B's result lacks its wait for A's final entry:" >&2; cat "$tmpdir/b.result" >&2; exit 1
}

# P starts on O's outline, which lacks the oracle O's proof makes: P is
# given up and publishes nothing.  Q, also on O's outline, is given up when
# the cache fails while it waits for R.
worker_start p "$spec_P" --ahead-parent "$key_O:$spec_O" --pipeline
worker_start q "$spec_Q" --ahead-parent "$key_O:$spec_O" --ahead-parent "$key_R:$spec_R" --pipeline
await_marker p waiting-OTheory
await_marker q waiting-OTheory
worker_start o "$spec_O" --pipeline
await_marker q arrived-OTheory
echo 500 > "$tmpdir/control/ac-get-status-$(ac_of "$key_R")"
worker_wait q
expect q 3 "status=failed" "failure=ahead-abandoned"
require_grep 'built on an outline' "$tmpdir/q.log"
rm "$tmpdir/control/ac-get-status-$(ac_of "$key_R")"
worker_wait o
expect o 0 "status=built"
worker_wait p
expect p 3 "status=failed" "failure=ahead-abandoned"
require_grep 'the outline of pipe:OTheory failed the gate: digest differs' "$tmpdir/p.log"
# Given up after its wait for O's final entry, P still reports the wait.
phase p finalswait || { echo "P's result lacks its wait for O's final entry:" >&2; cat "$tmpdir/p.result" >&2; exit 1; }
[[ ! -e "$tmpdir/remote/ac/$(ac_of "$key_P")" ]] || { echo "P published on a failed gate" >&2; exit 1; }
worker plain-p "$spec_P"
expect plain-p 0 "status=built"

# A pipelined build that fails builds again with its proofs in place.
worker r "$spec_R" --pipeline
expect r 0 "status=built"
require_grep 'pipeline: building plain' "$tmpdir/r.log"
phase r fallback || { echo "no fallback phase:" >&2; cat "$tmpdir/r.result" >&2; exit 1; }
# Why it was given up reaches the batch record and the uploaded log.
require_grep '^detail=pipelined attempt failed, built plain: .*deferred proofs depend on each other' "$tmpdir/r.result"
read -r r_log _ < <(sed -n 's/^log=//p' "$tmpdir/r.result")
require_grep '^holbuild: pipeline: building plain: ' "$tmpdir/remote/cas/$r_log"
require_grep 'deferred proofs depend on each other' "$tmpdir/remote/cas/$r_log"

# Plain builds against a second cache publish the same entries, and a worker
# not asked to pipeline publishes no outline.
first_remote=$tmpdir/remote
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true
start_remote_cache_server "$tmpdir/remote2" "$tmpdir/server2"
hb action-spec --upload ZTheory > /dev/null
for theory in A B O R; do
  name=plain-$(tr '[:upper:]' '[:lower:]' <<<"$theory")2
  spec_var=spec_$theory
  worker "$name" "${!spec_var}"
  expect "$name" 0 "status=built"
  require_no_grep 'published the outline' "$tmpdir/$name.log"
  [[ ! -e "$tmpdir/$name.result.outline" ]] || { echo "$name marked an outline" >&2; exit 1; }
done
for key in "$key_A" "$key_B" "$key_O" "$key_R"; do
  cmp "$first_remote/ac/$(ac_of "$key")" "$tmpdir/remote2/ac/$(ac_of "$key")"
done
[[ ! -e "$tmpdir/remote2/ac/$(outline_ac_of "$key_A")" ]] || { echo "a plain build published an outline" >&2; exit 1; }

# An outline the remote cache refuses its entry is no outline: the worker
# isn't told of one.
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true
start_remote_cache_server "$tmpdir/remote3" "$tmpdir/server3" "$tmpdir/control3"
hb action-spec --upload ZTheory > /dev/null
echo 403 > "$tmpdir/control3/ac-put-status"
worker refused "$spec_A" --pipeline
require_grep 'not publishing the outline: .*the remote cache refused its entry' "$tmpdir/refused.log"
[[ ! -e "$tmpdir/refused.result.outline" ]] || { echo "a refused outline was marked" >&2; exit 1; }

# A spec asking to pipeline a theory it shows can't be (one with an extra
# output) builds plain, publishing no outline.
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true
start_remote_cache_server "$tmpdir/remote4" "$tmpdir/server4"
hb action-spec --upload ZTheory > /dev/null
python3 - "$tmpdir/remote4/cas/$spec_E" "$tmpdir/extra-spec" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(data.replace(b"\naction-text\n", b"\noption pipeline=true\naction-text\n", 1))
PY
require_grep '^option pipeline=true$' "$tmpdir/extra-spec"
extra_spec=$(sha256sum "$tmpdir/extra-spec" | cut -d' ' -f1)
cp "$tmpdir/extra-spec" "$tmpdir/remote4/cas/$extra_spec"
worker extra "$extra_spec" --pipeline
expect extra 0 "status=built"
require_no_grep 'published the outline' "$tmpdir/extra.log"
[[ ! -e "$tmpdir/extra.result.outline" ]] || { echo "an ineligible spec marked an outline" >&2; exit 1; }
[[ ! -e "$tmpdir/remote4/ac/$(outline_ac_of "$key_E")" ]] || { echo "an ineligible spec published an outline" >&2; exit 1; }
