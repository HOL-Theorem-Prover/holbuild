#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Export specs from one checkout, run them as a worker would with only the
# remote cache as input, then restore the results in the original checkout.

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

remote_root=$tmpdir/remote
start_remote_cache_server "$remote_root" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "worker"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["results/A.nsv"]
val _ = let val out = TextIO.openOut "results/A.nsv"
        in TextIO.output (out, "A result\n"); TextIO.closeOut out end

Theorem a_thm:
  T
Proof
  simp[]
QED

Theorem a_thm2:
  T /\ T
Proof
  simp[]
QED
SML
cat > "$project/src/helperLib.sml" <<'SML'
structure helperLib = struct val helper_value = 1 end
SML
echo data > "$project/src/data.txt"
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A
Libs helperLib

fun holbuild_extra_deps (_ : string list) = ()
val _ = holbuild_extra_deps ["data.txt"]

Theorem b_thm:
  T
Proof
  ACCEPT_TAC (CONJUNCT1 a_thm2)
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

hb() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@")
}

# worker NAME SPEC [OPTION...]: exec-action in its own cache root and cwd, as
# a separate worker container would; the record goes to $tmpdir/NAME.result.
worker() {
  local name=$1 spec=$2
  shift 2
  local cache=$tmpdir/worker-$name
  link_hol_toolchain_cache "$cache"
  mkdir -p "$tmpdir/cwd-$name"
  set +e
  (cd "$tmpdir/cwd-$name" &&
     HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
       --cache-limit-gb 1000 --result "$tmpdir/$name.result" "$@") > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
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

spec_for() { awk -v want="$2" '$1 == "action" && $5 == want { print $4 }' "$1"; }
key_for() { awk -v want="$2" '$1 == "action" && $5 == want { print $2 }' "$1"; }

hb action-spec --upload CTheory > "$tmpdir/batch.txt"
spec_a=$(spec_for "$tmpdir/batch.txt" worker:ATheory)
spec_b=$(spec_for "$tmpdir/batch.txt" worker:BTheory)
spec_c=$(spec_for "$tmpdir/batch.txt" worker:CTheory)
key_a=$(key_for "$tmpdir/batch.txt" worker:ATheory)
[[ -n "$spec_a" && -n "$spec_b" && -n "$spec_c" ]] || { cat "$tmpdir/batch.txt" >&2; exit 1; }

# A theory whose parent isn't in the cache yet fails without building it.
worker early "$spec_c"
expect early 3 "spec=$spec_c" "status=failed" "failure=input-missing" "missing=theory $key_a"

# A spec that doesn't match its own action text is rejected, as is one the
# cache doesn't have.
python3 - "$project/.holbuild/action-specs/$spec_a" "$tmpdir/tampered" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(data.replace(b"\naction-text\n", b"\naction-text\n(* edited *)\n", 1))
PY
spec_tampered=$(sha256sum "$tmpdir/tampered" | cut -d' ' -f1)
curl -fsS -X PUT --data-binary "@$tmpdir/tampered" "$remote_url/cas/$spec_tampered"
worker tampered "$spec_tampered"
expect tampered 4 "status=failed" "failure=spec-rejected"
# So is one whose extra input isn't the file its action text names.
python3 - "$project/.holbuild/action-specs/$spec_b" "$tmpdir/other-input" <<'PY'
import hashlib, sys
lines = open(sys.argv[1], "rb").read().split(b"\n")
other = hashlib.sha256(b"other data\n").hexdigest().encode()
for i, line in enumerate(lines):
    if line.startswith(b"file input "):
        fields = line.split(b" ")
        fields[3] = other
        lines[i] = b" ".join(fields)
        break
else:
    sys.exit("spec has no file input line")
open(sys.argv[2], "wb").write(b"\n".join(lines))
PY
spec_other=$(sha256sum "$tmpdir/other-input" | cut -d' ' -f1)
curl -fsS -X PUT --data-binary "@$tmpdir/other-input" "$remote_url/cas/$spec_other"
worker other-input "$spec_other"
expect other-input 4 "status=failed" "failure=spec-rejected"
# Or one with an extra output its action text doesn't declare.
python3 - "$project/.holbuild/action-specs/$spec_a" "$tmpdir/extra-output" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(data.replace(b"\naction-text\n", b"\noutput extra extra.txt\naction-text\n", 1))
PY
spec_extra=$(sha256sum "$tmpdir/extra-output" | cut -d' ' -f1)
curl -fsS -X PUT --data-binary "@$tmpdir/extra-output" "$remote_url/cas/$spec_extra"
worker extra-output "$spec_extra"
expect extra-output 4 "status=failed" "failure=spec-rejected"
require_grep "the extra outputs do not match the action text" "$tmpdir/extra-output.log"
# Or one whose package, though consistent with its action text, would put
# files outside the action root.
python3 - "$project/.holbuild/action-specs/$spec_a" "$tmpdir/escape" <<'PY'
import hashlib, sys
head, text = open(sys.argv[1], "rb").read().split(b"\naction-text\n", 1)
old = [l for l in head.split(b"\n") if l.startswith(b"target ")][0].split(b" ")[1].split(b":")[0]
text = text.replace(b"\npackage=" + old + b"\n", b"\npackage=../../x\n", 1)
key = hashlib.sha256(text).hexdigest().encode()
lines = []
for line in head.split(b"\n"):
    if line.startswith(b"input-key="): line = b"input-key=" + key
    elif line.startswith(b"action-text-sha256="): line = b"action-text-sha256=" + key
    elif line.startswith(b"target "): line = line.replace(old + b":", b"../../x:", 1)
    elif line.startswith(b"source "): line = line.replace(b" " + old + b" ", b" ../../x ", 1)
    lines.append(line)
open(sys.argv[2], "wb").write(b"\n".join(lines) + b"\naction-text\n" + text)
PY
spec_escape=$(sha256sum "$tmpdir/escape" | cut -d' ' -f1)
curl -fsS -X PUT --data-binary "@$tmpdir/escape" "$remote_url/cas/$spec_escape"
worker escape "$spec_escape"
expect escape 4 "status=failed" "failure=spec-rejected"
require_grep "path ../../x leaves the action root" "$tmpdir/escape.log"
worker absent "$(printf 'absent' | sha256sum | cut -d' ' -f1)"
expect absent 4 "status=failed" "failure=spec-rejected"

# Two workers run the same spec at once: both succeed, and the cache holds
# one entry for it.
worker_bg() {
  ( worker "$@"; echo "$worker_status" > "$tmpdir/$1.status" ) &
  background+=("$!")
}
worker_bg twin1 "$spec_a"
worker_bg twin2 "$spec_a"
wait "${background[@]}"
background=()
for name in twin1 twin2; do
  worker_status=$(< "$tmpdir/$name.status")
  expect "$name" 0 "spec=$spec_a" "input-key=$key_a"
  grep -qx 'status=built\|status=cached' "$tmpdir/$name.result" || { cat "$tmpdir/$name.result" >&2; exit 1; }
done
built=$(grep -lx 'status=built' "$tmpdir/twin1.result" "$tmpdir/twin2.result" | head -n 1)
[[ -n "$built" ]] || { echo "neither concurrent worker built the action" >&2; exit 1; }
built_worker=$tmpdir/worker-$(basename "$built" .result)
ac_a=$(awk '$1 == "action" && $5 == "worker:ATheory" { print $3 }' "$tmpdir/batch.txt")
require_file "$remote_root/ac/$ac_a"

# The action root is emptied after the run; the checkpoints are kept.
[[ ! -e "$built_worker/action" ]] || { echo "the action root was not emptied" >&2; exit 1; }
find "$built_worker/checkpoints" -name 'deps_loaded.save' | grep -q . ||
  { echo "the worker kept no deps heap" >&2; find "$built_worker" -maxdepth 3 >&2; exit 1; }
find "$built_worker/checkpoints" -path '*.theorems*' -type f | grep -q . ||
  { echo "the worker kept no theorem checkpoints" >&2; exit 1; }

# A successful build reports its peak memory and uploads its log.
require_grep '^peak-rss-mb=[1-9][0-9]*$' "$built"
require_grep '^log=[0-9a-f]\{64\} [0-9][0-9]*$' "$built"
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$built")
curl -fsS "$remote_url/cas/$log_sha" > "$tmpdir/a-build.log"
[[ -s "$tmpdir/a-build.log" ]] || { echo "the uploaded log is empty" >&2; exit 1; }

# Rerunning a done action reports it cached.
worker again "$spec_a"
expect again 0 "status=cached"

# A worker that still holds an entry the remote lost publishes it again
# before reporting it cached.
rm "$remote_root/ac/$ac_a"
worker "$(basename "$built_worker" | sed 's/^worker-//')" "$spec_a"
expect "$(basename "$built_worker" | sed 's/^worker-//')" 0 "status=cached"
require_file "$remote_root/ac/$ac_a"

# Likewise for a blob of the entry the remote lost.
lost_blob=$(grep -oE '[0-9a-f]{64}' "$remote_root/ac/$ac_a" | while read -r h; do
              [[ -f "$remote_root/cas/$h" ]] && { echo "$h"; break; }; done)
[[ -n "$lost_blob" ]] || { echo "no blob of A's entry in the remote" >&2; exit 1; }
rm "$remote_root/cas/$lost_blob"
worker "$(basename "$built_worker" | sed 's/^worker-//')" "$spec_a"
expect "$(basename "$built_worker" | sed 's/^worker-//')" 0 "status=cached"
require_file "$remote_root/cas/$lost_blob"

# The rest of the chain builds in order on another worker.
worker b "$spec_b"
expect b 0 "status=built"
worker c "$spec_c"
expect c 0 "status=built"

# A cached theory whose parent in the cache isn't the one it was built against
# can't be restored, however often the worker retries, and says so.  Here the
# worker's own cache holds an A whose .dat differs from the one B recorded.
key_b=$(key_for "$tmpdir/batch.txt" worker:BTheory)
stale=$tmpdir/worker-stale
link_hol_toolchain_cache "$stale"
mkdir -p "$stale/actions/$key_a" "$stale/blobs"
dat_a=$(awk '$1 == "blob" && $2 == "dat" { print $3 }' "$built_worker/actions/$key_a/manifest")
{ cat "$built_worker/blobs/$dat_a"; echo; } > "$tmpdir/stale.dat"
stale_dat=$(sha256sum "$tmpdir/stale.dat" | cut -d' ' -f1)
cp "$tmpdir/stale.dat" "$stale/blobs/$stale_dat"
awk '$1 == "blob" { print $3 }' "$built_worker/actions/$key_a/manifest" | while read -r h; do
  [[ "$h" == "$dat_a" ]] || cp "$built_worker/blobs/$h" "$stale/blobs/$h"
done
sed "s/$dat_a/$stale_dat/" "$built_worker/actions/$key_a/manifest" > "$stale/actions/$key_a/manifest"
worker stale "$spec_c"
expect stale 3 "status=failed" "failure=input-missing" "missing=theory $key_b" "missing-reason=parents"
require_grep "does not match its parents in the cache" "$tmpdir/stale.log"

# The original checkout restores all three results without building.
hb build CTheory > "$tmpdir/client.log" 2>&1 || { cat "$tmpdir/client.log" >&2; exit 1; }
for theory in A B C; do
  require_grep "${theory}Theory restored from cache" "$tmpdir/client.log"
done
require_grep "A result" "$project/src/results/A.nsv"

# Proof failures and tactic timeouts are final failures (exit 1).
cat > "$project/src/DScript.sml" <<'SML'
Theory D
Ancestors A

Theorem d_bad:
  F
Proof
  simp[]
QED
SML
cat > "$project/src/EScript.sml" <<'SML'
Theory E
Ancestors A

fun slow_tac g = (OS.Process.sleep (Time.fromReal 2.0); ACCEPT_TAC TRUTH g);

Theorem e_slow:
  T
Proof
  slow_tac
QED
SML
hb action-spec --upload DTheory > "$tmpdir/batch-d.txt"
hb action-spec --upload --tactic-timeout 0.5 ETheory > "$tmpdir/batch-e.txt"
spec_d=$(spec_for "$tmpdir/batch-d.txt" worker:DTheory)

# A failure around the HOL child, here a machine memory budget no child fits
# in, is an infrastructure failure (exit 3), not a proof failure.
link_hol_toolchain_cache "$tmpdir/worker-budget"
mkdir -p "$tmpdir/coop" "$tmpdir/cwd-budget"
set +e
(cd "$tmpdir/cwd-budget" &&
   HOLBUILD_CACHE=$tmpdir/worker-budget "$HOLBUILD_BIN" --remote-cache "$remote_url" \
     --cooperate-dir "$tmpdir/coop" --machine-max-mem 1024 --child-charge 2048 \
     exec-action "$spec_d" --cache-limit-gb 1000 --result "$tmpdir/budget.result") \
  > "$tmpdir/budget.log" 2>&1
worker_status=$?
set -e
expect budget 3 "status=failed" "failure=internal"
require_grep "exceeds the machine budget" "$tmpdir/budget.log"

worker d "$spec_d"
expect d 1 "status=failed" "failure=proof"
worker e "$(spec_for "$tmpdir/batch-e.txt" worker:ETheory)"
expect e 1 "status=failed" "failure=tactic-timeout"
