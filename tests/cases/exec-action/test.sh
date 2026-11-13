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
cat > "$project/src/MissingRssScript.sml" <<'SML'
Theory MissingRss
Ancestors bool

Theorem checked: T
Proof
  simp[]
QED

(* The exporter tolerates unavailable process status, so its report is optional. *)
structure TextIO = struct
  open TextIO
  fun openIn path =
    if path = "/proc/self/status" then
      raise IO.Io {name = path, function = "openIn",
                   cause = OS.SysErr ("process status unavailable", SOME Posix.Error.acces)}
    else TextIO.openIn path
end
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

hb action-spec --upload --all-checkpoints CTheory MissingRssTheory > "$tmpdir/batch.txt"
spec_a=$(spec_for "$tmpdir/batch.txt" worker:ATheory)
spec_b=$(spec_for "$tmpdir/batch.txt" worker:BTheory)
spec_c=$(spec_for "$tmpdir/batch.txt" worker:CTheory)
spec_missing_rss=$(spec_for "$tmpdir/batch.txt" worker:MissingRssTheory)
key_a=$(key_for "$tmpdir/batch.txt" worker:ATheory)
[[ -n "$spec_a" && -n "$spec_b" && -n "$spec_c" && -n "$spec_missing_rss" ]] || { cat "$tmpdir/batch.txt" >&2; exit 1; }

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
require_grep '^detail=.' "$tmpdir/tampered.result"
if grep -q '^log=' "$tmpdir/tampered.result"; then
  echo 'a rejected spec uploaded a log' >&2
  exit 1
fi
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
# Matching declarations and action hashes must not let the trusted parent
# publish files outside the validated stage tree.
echo 'outside-output-sentinel' > "$tmpdir/outside-output"
for output in "../../../../../../../../../../../../${tmpdir#/}/outside-output" \
              /proc/self/environ ../outside-output results/../../../outside-output ./..; do
  python3 - "$project/.holbuild/action-specs/$spec_a" "$tmpdir/escape-output" "$output" <<'PY'
import hashlib, sys
head, text = open(sys.argv[1], "rb").read().split(b"\naction-text\n", 1)
output = sys.argv[3].encode()
head += b"\noutput extra " + output
text += b"source_extra_output=" + output + b"\n"
key = hashlib.sha256(text).hexdigest().encode()
lines = []
for line in head.split(b"\n"):
    if line.startswith(b"input-key="): line = b"input-key=" + key
    elif line.startswith(b"action-text-sha256="): line = b"action-text-sha256=" + key
    lines.append(line)
open(sys.argv[2], "wb").write(b"\n".join(lines) + b"\naction-text\n" + text)
PY
  spec_escape_output=$(sha256sum "$tmpdir/escape-output" | cut -d' ' -f1)
  curl -fsS -X PUT --data-binary "@$tmpdir/escape-output" "$remote_url/cas/$spec_escape_output"
  worker escape-output "$spec_escape_output"
  expect escape-output 4 "status=failed" "failure=spec-rejected"
  require_grep "leaves the action root" "$tmpdir/escape-output.log"
done
# Or one whose package, though consistent with its action text, would put
# files outside the action root.
for package in ../../x ./..; do
  python3 - "$project/.holbuild/action-specs/$spec_a" "$tmpdir/escape" "$package" <<'PY'
import hashlib, sys
head, text = open(sys.argv[1], "rb").read().split(b"\naction-text\n", 1)
package = sys.argv[3].encode()
old = [l for l in head.split(b"\n") if l.startswith(b"target ")][0].split(b" ")[1].split(b":")[0]
text = text.replace(b"\npackage=" + old + b"\n", b"\npackage=" + package + b"\n", 1)
key = hashlib.sha256(text).hexdigest().encode()
lines = []
for line in head.split(b"\n"):
    if line.startswith(b"input-key="): line = b"input-key=" + key
    elif line.startswith(b"action-text-sha256="): line = b"action-text-sha256=" + key
    elif line.startswith(b"target "): line = line.replace(old + b":", package + b":", 1)
    elif line.startswith(b"source "): line = line.replace(b" " + old + b" ", b" " + package + b" ", 1)
    lines.append(line)
open(sys.argv[2], "wb").write(b"\n".join(lines) + b"\naction-text\n" + text)
PY
  spec_escape=$(sha256sum "$tmpdir/escape" | cut -d' ' -f1)
  curl -fsS -X PUT --data-binary "@$tmpdir/escape" "$remote_url/cas/$spec_escape"
  worker escape "$spec_escape"
  expect escape 4 "status=failed" "failure=spec-rejected"
  require_grep "path $package leaves the action root" "$tmpdir/escape.log"
done
# A file hash names a blob in the worker's cache, so a hash that is a path
# must be rejected before any lookup.
python3 - "$project/.holbuild/action-specs/$spec_a" "$tmpdir/blob-path" \
  "../../../../../../../../../../../../${tmpdir#/}/outside-output" <<'PY'
import sys
head, text = open(sys.argv[1], "rb").read().split(b"\naction-text\n", 1)
head += b"\nfile library lib/Outside.sml " + sys.argv[3].encode() + b" 24"
open(sys.argv[2], "wb").write(head + b"\naction-text\n" + text)
PY
spec_blob_path=$(sha256sum "$tmpdir/blob-path" | cut -d' ' -f1)
curl -fsS -X PUT --data-binary "@$tmpdir/blob-path" "$remote_url/cas/$spec_blob_path"
worker blob-path "$spec_blob_path"
expect blob-path 4 "status=failed" "failure=spec-rejected"
require_grep "a file's SHA-256 is malformed" "$tmpdir/blob-path.log"
# Or one that writes where the worker keeps a dependency other than as
# that dependency: a library manifest over its object, a library file or
# an output at its script, or a path spelled two ways.
for edit in manifest library output dot; do
  python3 - "$project/.holbuild/action-specs/$spec_b" "$tmpdir/overlap" "$edit" <<'PY'
import sys
head, text = open(sys.argv[1], "rb").read().split(b"\naction-text\n", 1)
lines = head.split(b"\n")
dep = [l for l in lines if l.startswith(b"dep theory ")][0].split(b" ")
target, stem = dep[2], dep[3]
edit = sys.argv[3]
if edit == "manifest":
    lines.append(b"lib " + target + b" " + stem + b" .ui")
elif edit == "library":
    lines.append(b"file library " + stem + b".sml " + b"0" * 64 + b" 24")
elif edit == "output":
    lines = [b"output sml " + stem + b".sml" if l.startswith(b"output sml ") else l for l in lines]
else:
    lines.append(b"file library .holbuild/action-src/./lib/A.sml " + b"0" * 64 + b" 24")
open(sys.argv[2], "wb").write(b"\n".join(lines) + b"\naction-text\n" + text)
PY
  spec_overlap=$(sha256sum "$tmpdir/overlap" | cut -d' ' -f1)
  curl -fsS -X PUT --data-binary "@$tmpdir/overlap" "$remote_url/cas/$spec_overlap"
  worker overlap "$spec_overlap"
  expect overlap 4 "status=failed" "failure=spec-rejected"
  case $edit in
    manifest) require_grep "two items of the spec write" "$tmpdir/overlap.log" ;;
    library|dot) require_grep "a library file is not a canonical action-src path" "$tmpdir/overlap.log" ;;
    output) require_grep "the outputs are not one theory's" "$tmpdir/overlap.log" ;;
  esac
done
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

# Only the trees the hydrate keeps stay, with their records, for the next
# action; the writable trees and the action's own files go, so another
# tenant can't inherit them.
for dir in stage logs tool-cache ahead action-spec; do
  [[ ! -e "$built_worker/action/.holbuild/$dir" ]] || { echo "the action's $dir was not emptied" >&2; exit 1; }
done
require_file "$built_worker/action-resident"
[[ ! -e "$built_worker/checkpoints" ]] || { echo "the worker retained private checkpoints" >&2; exit 1; }

# A successful build reports its peak memory and uploads its log.
require_grep '^peak-rss-mb=[1-9][0-9]*$' "$built"
require_grep '^log=[0-9a-f]\{64\} [0-9][0-9]*$' "$built"
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$built")
curl -fsS "$remote_url/cas/$log_sha" > "$tmpdir/a-build.log"
[[ -s "$tmpdir/a-build.log" ]] || { echo "the uploaded log is empty" >&2; exit 1; }

# A subdirectory theory still publishes when the exporter could not record RSS.
worker missing-rss "$spec_missing_rss"
expect missing-rss 0 "status=built"
if grep -q '^peak-rss-mb=' "$tmpdir/missing-rss.result"; then
  echo 'unavailable process status produced a peak RSS report' >&2
  exit 1
fi

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

# An input the remote lost fails the action as missing, with its blob named,
# though the worker fetches inputs in parallel.
data_blob=$(sha256sum "$project/src/data.txt" | cut -d' ' -f1)
require_file "$remote_root/cas/$data_blob"
mv "$remote_root/cas/$data_blob" "$tmpdir/data.blob"
worker lost-input "$spec_b"
expect lost-input 3 "status=failed" "failure=input-missing" "missing=blob $data_blob"
# A failed hydrate still reports the steps it ran.
grep -qE "^phase-ms=(.*,)?hydrate:[0-9]+,hydfiles:[0-9]+(,|\$)" "$tmpdir/lost-input.result" || {
  echo "lost-input's record lacks hydrate's steps:" >&2; cat "$tmpdir/lost-input.result" >&2; exit 1; }
mv "$tmpdir/data.blob" "$remote_root/cas/$data_blob"

# A resident dependency manifest must not hide a lost local payload.
link_hol_toolchain_cache "$tmpdir/worker-b"
cp -r "$built_worker/actions" "$built_worker/blobs" "$tmpdir/worker-b/"
dep_dat=$(awk '$1 == "blob" && $2 == "dat" { print $3 }' "$tmpdir/worker-b/actions/$key_a/manifest")
require_file "$tmpdir/worker-b/blobs/$dep_dat"
mv "$tmpdir/worker-b/blobs/$dep_dat" "$tmpdir/dep.dat"

# The rest of the chain builds in order on another worker.
worker b "$spec_b"
expect b 0 "status=built"
cmp "$tmpdir/dep.dat" "$tmpdir/worker-b/blobs/$dep_dat"
# Its record times the action and its phases.
require_grep '^wall-ms=[0-9][0-9]*$' "$tmpdir/b.result"
for phase in hydrate hydfiles hyddeps hydstale hydmisfit modules hol check; do
  grep -qE "^phase-ms=(.*,)?$phase:[0-9]+(,|\$)" "$tmpdir/b.result" || {
    echo "b's record lacks phase $phase:" >&2; cat "$tmpdir/b.result" >&2; exit 1; }
done
PYTHONPATH="$HOLBUILD_ROOT/remote-exec" python3 - "$tmpdir/b.result" <<'PY'
import pathlib,sys
from remote_exec.formats import parse_result
timings=parse_result(pathlib.Path(sys.argv[1]).read_text()).timings
assert timings['started'] <= timings['holstart'] <= timings['holend'] <= timings['publishstart']
assert timings['publishstart'] <= timings['publishend'] <= timings['finished']
assert timings['started'] <= timings['logstart'] <= timings['logend'] <= timings['finished']
assert timings['rebuilt']==1
PY
# A corrupt local payload is fetched by the same verified path.
link_hol_toolchain_cache "$tmpdir/worker-c"
cp -r "$tmpdir/worker-b/actions" "$tmpdir/worker-b/blobs" "$tmpdir/worker-c/"
printf 'corrupt dependency\n' > "$tmpdir/worker-c/blobs/$dep_dat"
worker c "$spec_c"
expect c 0 "status=built"
cmp "$tmpdir/dep.dat" "$tmpdir/worker-c/blobs/$dep_dat"
# Before C's child ran, the worker wrote the modules of the theories it
# loads into the host's store, which the child itself only reads.
if [[ ${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-0} == 1 ]]; then
  for theory in A B; do
    compgen -G "$tmpdir/worker-c/theory-modules/*/*-$theory-*.pmo" > /dev/null || {
      echo "worker c wrote no module for $theory" >&2
      cat "$tmpdir/c.log" >&2
      exit 1
    }
  done
  compgen -G "$tmpdir/worker-c/theory-modules/*/base-theories" > /dev/null || {
    echo "worker c recorded no base-state theories" >&2; exit 1; }
  # The next child on worker c loads A and B from those modules, not from
  # their .dat files.
  cat > "$project/src/DScript.sml" <<'SML'
Theory D
Ancestors B

val _ = if length (PolyML.SaveState.showLoadedModules ()) >= 2 then ()
        else raise Fail "D's child loaded no theory modules"

Theorem d_thm:
  T
Proof
  ACCEPT_TAC b_thm
QED
SML
  hb action-spec --upload DTheory > "$tmpdir/batch-d.txt"
  worker c "$(spec_for "$tmpdir/batch-d.txt" worker:DTheory)"
  expect c 0 "status=built"
  rm "$project/src/DScript.sml"
elif [[ ! -e "$HOLDIR/tools-poly/poly/theory_modules.ML" ]]; then
  # A HOL without the module helper starts no writer, which alone makes
  # the store.
  [[ ! -e "$tmpdir/worker-c/theory-modules" ]] || {
    echo "worker c started a module writer for a HOL without modules" >&2; exit 1; }
fi

# The next action on worker c keeps the dependencies it names again, here
# A, and removes the rest; a dependency whose local entry changed since is
# installed again, and without its records the worker empties the root.
cat > "$project/src/A2Script.sml" <<'SML'
Theory A2
Ancestors A

Theorem a2_thm:
  T
Proof
  ACCEPT_TAC a_thm
QED
SML
hb action-spec --upload A2Theory > "$tmpdir/batch-a2.txt"
spec_a2=$(spec_for "$tmpdir/batch-a2.txt" worker:A2Theory)
resident_stem() { awk -F'\t' -v want="$1" '$1 == "theory" && $3 ~ want { print $2 }' "$tmpdir/worker-c/action-resident"; }
stem_a=$(resident_stem 'ATheory$')
stem_b=$(resident_stem 'BTheory$')
[[ -n "$stem_a" && -n "$stem_b" ]] || { cat "$tmpdir/worker-c/action-resident" >&2; exit 1; }
inode_a=$(stat -c %i "$stem_a.dat")
# Held, so that a reinstall can't get the same inode back.
ln "$stem_a.dat" "$tmpdir/a-held.dat"
worker c "$spec_a2"
expect c 0
[[ $(stat -c %i "$stem_a.dat") == "$inode_a" ]] || { echo "worker c installed A again" >&2; exit 1; }
[[ ! -e "$stem_b.dat" && -z $(resident_stem 'BTheory$') ]] || { echo "worker c kept B, which A2 doesn't name" >&2; exit 1; }
printf '\n' >> "$tmpdir/worker-c/actions/$key_a/manifest"
worker c "$spec_a2"
expect c 0
[[ $(stat -c %i "$stem_a.dat") != "$inode_a" ]] || { echo "worker c kept A after its entry changed" >&2; exit 1; }
touch "$tmpdir/worker-c/action/.holbuild/obj/stray"
rm "$tmpdir/worker-c/action-resident"
worker c "$spec_a2"
expect c 0
[[ ! -e "$tmpdir/worker-c/action/.holbuild/obj/stray" ]] || { echo "worker c kept a root it has no records of" >&2; exit 1; }
# A release that keeps no records removes the root around its actions; the
# records go once the root is emptied, even when the action then fails.
rm -rf "$tmpdir/worker-c/action"
worker c "$spec_a2"
expect c 0
rm -rf "$tmpdir/worker-c/action"
worker c "$(printf 'absent' | sha256sum | cut -d' ' -f1)"
expect c 4 "status=failed" "failure=spec-rejected"
worker c "$spec_a2"
expect c 0
# A file where the previous action had a directory of the same name: the
# directory a removed file leaves empty goes with it, as in a cold root.
printf 'payload\n' > "$tmpdir/payload"
payload=$(sha256sum "$tmpdir/payload" | cut -d' ' -f1)
curl -fsS -X PUT --data-binary "@$tmpdir/payload" "$remote_url/cas/$payload"
for path in extra/item extra; do
  python3 - "$project/.holbuild/action-specs/$spec_a2" "$tmpdir/nested" "$path" "$payload" <<'PY'
import sys
head, text = open(sys.argv[1], "rb").read().split(b"\naction-text\n", 1)
head += b"\nfile library .holbuild/action-src/worker/" + sys.argv[3].encode() + b" " + sys.argv[4].encode() + b" 8"
open(sys.argv[2], "wb").write(head + b"\naction-text\n" + text)
PY
  spec_nested=$(sha256sum "$tmpdir/nested" | cut -d' ' -f1)
  curl -fsS -X PUT --data-binary "@$tmpdir/nested" "$remote_url/cas/$spec_nested"
  worker c "$spec_nested"
  expect c 0
done
# Extra outputs a dependency's records don't name, as an early cutoff
# restores under the action's earlier key, go at the next hydrate.
orphan="$tmpdir/worker-c/action/.holbuild/action-extra/$(printf 'orphan' | sha256sum | cut -d' ' -f1)"
mkdir -p "$orphan/results"
worker c "$spec_a2"
expect c 0
[[ ! -e "$orphan" ]] || { echo "worker c kept extra outputs nobody records" >&2; exit 1; }
require_file "$tmpdir/worker-c/action/.holbuild/action-extra/$key_a/results/A.nsv"

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

val _ = ((raise mk_HOL_ERR "Optional" "branch" "handled diagnostic")
         handle e as HOL_ERR _ => print (Feedback.exn_to_string e));
Theorem d_continued:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = print (String.concat (List.tabulate (16, fn _ => "continued output\n")));

Theorem d_bad:
  F
Proof
  FAIL_TAC "terminal proof failure"
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
if grep -q '^log=' "$tmpdir/budget.result"; then
  echo "pre-HOL failure published an unvalidated action log" >&2
  exit 1
fi

# A malformed one-line theorem recovers a boundary with an empty tactic.
# Its source diagnostic must survive protocol parsing and proof planning.
cat > "$project/src/InlineScript.sml" <<'SML'
Theory Inline
Ancestors bool
Theorem marker: T Proof simp[] QED
SML
hb action-spec --upload InlineTheory > "$tmpdir/batch-inline.txt"
worker inline "$(spec_for "$tmpdir/batch-inline.txt" worker:InlineTheory)"
expect inline 1 "status=failed" "failure=proof"
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/inline.result")
[[ -n "$log_sha" ]] || { echo "malformed source has no action log" >&2; exit 1; }
curl -fsS "$remote_url/cas/$log_sha" > "$tmpdir/inline-action.log"
require_grep "a theorem's statement ends" "$tmpdir/inline-action.log"
require_grep "InlineScript.sml:" "$tmpdir/inline-action.log"
if grep -q "bad analyser boundary record" "$tmpdir/inline-action.log"; then
  echo "malformed source lost its empty boundary field" >&2
  exit 1
fi

worker d "$spec_d"
expect d 1 "status=failed" "failure=proof"
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/d.result")
curl -fsS "$remote_url/cas/$log_sha" > "$tmpdir/d-action.log"
require_grep "d_bad" "$tmpdir/d-action.log"
require_grep 'Saved theorem .*"d_continued"' "$tmpdir/d-action.log"
require_grep 'handled diagnostic' "$tmpdir/d-action.log"
python3 - "$tmpdir/d-action.log" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
summary = text.split('\nholbuild: exec-action failed: ', 1)[1].split('child failure:\n', 1)[1]
assert summary.startswith('Exception raised at boolLib.store_thm_at:'), summary
assert 'terminal proof failure' in summary, summary
assert 'handled diagnostic' not in summary, summary
PY

cp "$HOLBUILD_ROOT/tests/fixtures/TerminalFailureScript.sml" "$project/src/TerminalFailureScript.sml"
hb action-spec --upload TerminalFailureTheory > "$tmpdir/batch-terminal.txt"
worker terminal "$(spec_for "$tmpdir/batch-terminal.txt" worker:TerminalFailureTheory)"
expect terminal 1 "status=failed" "failure=proof"
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/terminal.result")
curl -fsS "$remote_url/cas/$log_sha" > "$tmpdir/terminal-action.log"
python3 - "$tmpdir/terminal-action.log" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
assert 'handled diagnostic' in text and 'Saved theorem' in text, text
summary = text.split('\nholbuild: exec-action failed: ', 1)[1].split('child failure:\n', 1)[1]
assert summary.startswith('Uncaught exception'), summary
assert 'terminal child failure' in summary.splitlines()[0], summary
assert 'preceding HOL output:' in summary and 'HOL message: terminal context' in summary, summary
assert 'handled diagnostic' not in summary, summary
assert len(summary.strip().splitlines()) <= 12, summary
PY
worker e "$(spec_for "$tmpdir/batch-e.txt" worker:ETheory)"
expect e 1 "status=failed" "failure=tactic-timeout"

# A HOL child killed by a signal leaves no diagnostic of its own: the action's
# log says how it died and how large the child grew, and names no path in the
# action root, which is emptied.
cat > "$project/src/KilledScript.sml" <<'SML'
Theory Killed
Ancestors bool

val _ = Posix.Process.kill (Posix.Process.K_PROC (Posix.ProcEnv.getpid ()), Posix.Signal.kill);
SML
hb action-spec --upload KilledTheory > "$tmpdir/batch-killed.txt"
worker killed "$(spec_for "$tmpdir/batch-killed.txt" worker:KilledTheory)"
expect killed 3 "status=failed" "failure=internal"
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/killed.result")
[[ -n "$log_sha" ]] || { echo "the killed action has no log" >&2; cat "$tmpdir/killed.result" >&2; exit 1; }
curl -fsS "$remote_url/cas/$log_sha" > "$tmpdir/killed-action.log"
require_grep "HOL was killed by signal 9 (SIGKILL)" "$tmpdir/killed-action.log"
require_grep "largest child resident set so far: [1-9][0-9]* MB" "$tmpdir/killed-action.log"
if grep -q "instrumented log:" "$tmpdir/killed-action.log"; then
  echo "the action log names a path in the emptied action root" >&2
  cat "$tmpdir/killed-action.log" >&2
  exit 1
fi

# A failure after the export still reports the peak the exporter measured.
cat > "$project/src/UnwrittenScript.sml" <<'SML'
Theory Unwritten
Ancestors bool

fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["results/unwritten.txt"]
SML
hb action-spec --upload UnwrittenTheory > "$tmpdir/batch-unwritten.txt"
worker unwritten "$(spec_for "$tmpdir/batch-unwritten.txt" worker:UnwrittenTheory)"
expect unwritten 3 "status=failed"
require_grep '^peak-rss-mb=[1-9][0-9]*$' "$tmpdir/unwritten.result"

# Default action specs enable theorem checkpoints for dependencies too.
cat > "$project/src/FScript.sml" <<'SML'
Theory F

Theorem f_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/GScript.sml" <<'SML'
Theory G
Ancestors F

Theorem g_thm:
  T
Proof
  ACCEPT_TAC f_thm
QED
SML
hb action-spec --upload GTheory > "$tmpdir/batch-g.txt"
spec_f=$(spec_for "$tmpdir/batch-g.txt" worker:FTheory)
spec_g=$(spec_for "$tmpdir/batch-g.txt" worker:GTheory)
for spec in "$spec_f" "$spec_g" "$spec_a" "$spec_d"; do
  if grep -q 'theorem-checkpoints' "$project/.holbuild/action-specs/$spec"; then
    echo "a default spec disables theorem checkpoints" >&2
    exit 1
  fi
done
worker f "$spec_f"
expect f 0 "spec=$spec_f" "status=built"
[[ ! -e "$tmpdir/worker-f/checkpoints" ]] || { echo "the non-target worker retained private checkpoints" >&2; exit 1; }

# A warm worker's local copies go out of date when the remote's entries for
# their keys change, as for a nondeterministic theory built twice: the worker
# replaces them by the remote's in the same attempt.  stale_worker NAME
# THEORY: a worker cache holding THEORY and its ancestors built apart from the
# remote, from a copy of the project.
cat > "$project/src/NScript.sml" <<'SML'
Theory N
Ancestors bool

val _ = save_thm ("n" ^ LargeInt.toString (Time.toMicroseconds (Time.now ())), TRUTH);
SML
for theory in M:N P:M; do
  cat > "$project/src/${theory%%:*}Script.sml" <<SML
Theory ${theory%%:*}
Ancestors ${theory##*:}

Theorem ${theory%%:*}_thm:
  T
Proof
  simp[]
QED
SML
done
stale_worker() {
  mkdir -p "$tmpdir/copy-$1"
  cp -r "$project/src" "$project/holproject.toml" "$tmpdir/copy-$1/"
  link_hol_toolchain_cache "$tmpdir/worker-$1"
  (cd "$tmpdir/copy-$1" && HOLBUILD_CACHE=$tmpdir/worker-$1 "$HOLBUILD_BIN" build "$2") \
    > "$tmpdir/copy-$1.log" 2>&1 || { cat "$tmpdir/copy-$1.log" >&2; exit 1; }
}
stale_worker stale-deps MTheory
stale_worker stale-own MTheory
hb action-spec --upload MTheory > "$tmpdir/batch-m.txt"
spec_m=$(spec_for "$tmpdir/batch-m.txt" worker:MTheory)
key_n=$(key_for "$tmpdir/batch-m.txt" worker:NTheory)
hb build MTheory > "$tmpdir/remote-m.log" 2>&1 || { cat "$tmpdir/remote-m.log" >&2; exit 1; }
hb action-spec --upload PTheory > "$tmpdir/batch-p.txt"
spec_p=$(spec_for "$tmpdir/batch-p.txt" worker:PTheory)
[[ -n $spec_m && -n $key_n && -n $spec_p ]] || { cat "$tmpdir/batch-m.txt" "$tmpdir/batch-p.txt" >&2; exit 1; }

# The worker's NTheory and MTheory differ from the remote's: it restores the
# remote's and builds PTheory.
worker stale-deps "$spec_p"
expect stale-deps 0 "spec=$spec_p" "status=built"

# The worker's MTheory doesn't fit the remote's NTheory, which it doesn't
# hold: it restores the remote's MTheory rather than building it.
rm "$tmpdir/worker-stale-own/actions/$key_n/manifest"
worker stale-own "$spec_m"
expect stale-own 0 "spec=$spec_m" "status=cached"

# Likewise for a parent the theory loads only through a project library's
# implementation, behind its signature.
cat > "$project/src/nLib.sig" <<'SML'
signature nLib = sig val loaded : bool end
SML
cat > "$project/src/nLib.sml" <<'SML'
structure nLib :> nLib = struct local open NTheory in val loaded = true end end
SML
cat > "$project/src/QScript.sml" <<'SML'
Theory Q
Ancestors bool
Libs nLib

Theorem q_thm:
  T
Proof
  simp[]
QED
SML
stale_worker stale-lib NTheory
hb action-spec --upload QTheory > "$tmpdir/batch-q.txt"
spec_q=$(spec_for "$tmpdir/batch-q.txt" worker:QTheory)
[[ -n $spec_q ]] || { cat "$tmpdir/batch-q.txt" >&2; exit 1; }
worker stale-lib "$spec_q"
expect stale-lib 0 "spec=$spec_q" "status=built"

# If both stores lose a payload, discard the dead local manifest so a later
# attempt can restore a rebuilt entry whose outputs differ (N is nondeterministic).
cat > "$project/src/RScript.sml" <<'SML'
Theory R
Ancestors N

Theorem r_thm: T
Proof
  simp[]
QED
SML
hb action-spec --upload RTheory > "$tmpdir/batch-r.txt"
spec_r=$(spec_for "$tmpdir/batch-r.txt" worker:RTheory)
[[ -n $spec_r ]] || { cat "$tmpdir/batch-r.txt" >&2; exit 1; }
old_dat=$(awk '$1 == "blob" && $2 == "dat" { print $3 }' "$tmpdir/worker-stale-deps/actions/$key_n/manifest")
rm "$tmpdir/worker-stale-deps/blobs/$old_dat"
mv "$remote_root/cas/$old_dat" "$tmpdir/old-n.dat"
# A worker still holding N in its action root needs neither payload; this
# one must restore it.
rm "$tmpdir/worker-stale-deps/action-resident"
worker stale-deps "$spec_r"
expect stale-deps 3 "status=failed" "failure=input-missing" "missing=theory $key_n"
[[ ! -f "$tmpdir/worker-stale-deps/actions/$key_n/manifest" ]] || {
  echo "the worker retained the dead dependency manifest" >&2; exit 1; }

stale_worker replacement NTheory
new_dat=$(awk '$1 == "blob" && $2 == "dat" { print $3 }' "$tmpdir/worker-replacement/actions/$key_n/manifest")
[[ $old_dat != "$new_dat" ]] || { echo "N did not produce replacement outputs" >&2; exit 1; }
# Publish that independently checked replacement to the fixture cache.
python3 - "$tmpdir/worker-replacement" "$remote_root" "$key_n" <<'PYTHON'
import hashlib, pathlib, shutil, sys
cache, remote = map(pathlib.Path, sys.argv[1:3])
key = sys.argv[3]
manifest = (cache / "actions" / key / "manifest").read_bytes()
metadata = ["holbuild-remote-cache-action-v2",
            "manifest-sha256 " + hashlib.sha256(manifest).hexdigest(),
            "manifest-size " + str(len(manifest))]
for line in manifest.decode().splitlines():
    fields = line.split()
    if fields[:1] == ["blob"]:
        blob = fields[2]
        src = cache / "blobs" / blob
        shutil.copyfile(src, remote / "cas" / blob)
        metadata.append("blob " + blob + " " + str(src.stat().st_size))
ac = hashlib.sha256(("holbuild-remote-ac-v1\n" + key + "\n").encode()).hexdigest()
(remote / "ac" / ac).write_bytes(("\n".join(metadata) + "\nmanifest-text-v1\n").encode() + manifest)
PYTHON
worker stale-deps "$spec_r"
expect stale-deps 0 "status=built"
cmp "$tmpdir/worker-replacement/blobs/$new_dat" "$tmpdir/worker-stale-deps/blobs/$new_dat"
