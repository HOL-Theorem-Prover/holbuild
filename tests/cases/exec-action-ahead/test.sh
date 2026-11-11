#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action --ahead-parent: a theory loads ahead of a parent another worker
# is still building, and builds what a plain run would once it arrives.

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
name = "ahead"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T /\ T
Proof
  simp[]
QED
SML
cat > "$project/src/helperLib.sml" <<'SML'
structure helperLib = struct val helper_value = 1 end
SML
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A
Libs helperLib

Theorem b_thm:
  T
Proof
  ACCEPT_TAC (CONJUNCT1 a_thm)
QED
SML
# F reaches A only through a library's manifest.
cat > "$project/src/aLib.sml" <<'SML'
structure aLib = struct val a = ATheory.a_thm end
SML
cat > "$project/src/FScript.sml" <<'SML'
Theory F
Ancestors bool
Libs aLib

Theorem f_thm:
  T
Proof
  ACCEPT_TAC (CONJUNCT1 aLib.a)
QED
SML
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors B

Theorem c_thm:
  T
Proof
  ACCEPT_TAC b_thm
QED
SML
# D records an ML dependency its source doesn't name literally, so the
# manifest predicted for it misses one its load evaluates.
cat > "$project/src/DScript.sml" <<'SML'
Theory D
Ancestors bool
Libs helperLib

val _ = Theory.add_ML_dependency ("helper" ^ "Lib")

Theorem d_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/EScript.sml" <<'SML'
Theory E
Ancestors D

Theorem e_thm:
  T
Proof
  ACCEPT_TAC d_thm
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
# worker_start NAME SPEC [OPTION...]: as worker, in the background;
# worker_wait NAME collects it.
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
# await_marker NAME FILE: until the worker's ahead child has written FILE.
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

# expect NAME EXIT LINE...: the worker's exit code and result lines.
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
# ahead_phases NAME: whether the result reports the load-ahead timings.
ahead_phases() { grep -q '^phase-ms=.*aheadload:[0-9]*,aheadwait:[0-9]*' "$tmpdir/$1.result"; }

spec_for() { awk -v want="$2" '$1 == "action" && $5 == want { print $4 }' "$1"; }
key_for() { awk -v want="$2" '$1 == "action" && $5 == want { print $2 }' "$1"; }

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
hb action-spec --upload CTheory ETheory FTheory > "$tmpdir/batch.txt"
for theory in A B C D E F; do
  declare "spec_$theory=$(spec_for "$tmpdir/batch.txt" "ahead:${theory}Theory")"
  declare "key_$theory=$(key_for "$tmpdir/batch.txt" "ahead:${theory}Theory")"
done
[[ -n "$spec_A" && -n "$spec_B" && -n "$spec_C" && -n "$spec_D" && -n "$spec_E" && -n "$spec_F" ]] || {
  cat "$tmpdir/batch.txt" >&2
  exit 1
}

# A parent that never arrives gives the run up once the wait runs out.
worker never "$spec_B" --ahead-parent "$key_A:$spec_A" --ahead-wait-seconds 3
expect never 3 "status=failed" "failure=ahead-abandoned"
require_grep 'did not arrive in time' "$tmpdir/never.log"

# The parent arrives while the children wait for it, and they build, also
# the one that loads it through a library.
worker_start ahead "$spec_B" --ahead-parent "$key_A:$spec_A"
worker_start ahead-lib "$spec_F" --ahead-parent "$key_A:$spec_A"
await_marker ahead waiting-ATheory
await_marker ahead-lib waiting-ATheory
worker a "$spec_A"
expect a 0 "status=built"
for name in ahead ahead-lib; do
  worker_wait "$name"
  expect "$name" 0 "status=built"
  ahead_phases "$name" || { echo "no load-ahead timings:" >&2; cat "$tmpdir/$name.result" >&2; exit 1; }
done

# An action built already is given up, since the claim of a plain run finds it.
worker again "$spec_B" --ahead-parent "$key_A:$spec_A"
expect again 3 "status=failed" "failure=ahead-abandoned"

# A parent published by the time the run starts is no reason to load ahead.
worker late "$spec_C" --ahead-parent "$key_B:$spec_B"
expect late 0 "status=built"
if ahead_phases late; then echo "loaded ahead of a published parent" >&2; exit 1; fi

# A parent whose load evaluates files its predicted manifest doesn't name
# gives the run up, and the plain retry builds.
worker_start mismatch "$spec_E" --ahead-parent "$key_D:$spec_D"
await_marker mismatch waiting-DTheory
worker d "$spec_D"
expect d 0 "status=built"
worker_wait mismatch
expect mismatch 3 "status=failed" "failure=ahead-abandoned"
require_grep 'evaluated other files than its manifest names' "$tmpdir/mismatch.log"
worker plain-e "$spec_E"
expect plain-e 0 "status=built"

# A plain build of B against a second cache publishes the same entry.
first_remote=$tmpdir/remote
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true
start_remote_cache_server "$tmpdir/remote2" "$tmpdir/server2"
hb action-spec --upload BTheory > /dev/null
worker plain-a "$spec_A"
expect plain-a 0 "status=built"
worker plain-b "$spec_B"
expect plain-b 0 "status=built"
ac_B=$(printf 'holbuild-remote-ac-v1\n%s\n' "$key_B" | sha256sum | cut -d' ' -f1)
cmp "$first_remote/ac/$ac_B" "$tmpdir/remote2/ac/$ac_B"
