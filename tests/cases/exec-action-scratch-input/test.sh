#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# build --scratch-input FILE: theory children read FILE through
# HOLBUILD_SCRATCH_INPUT, here and on a worker, and nothing keys it: the
# action, its dependencies and every checkpoint before the target are the
# same with and without it, and whatever FILE holds.

tmpdir=$(make_temp_dir)
server_pid=""
background=()
cleanup() {
  for pid in "${background[@]}" "$server_pid"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "scratch"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML
# write_u PROOF: U reads its scratch input between its theorems, so a build
# resumed after u1 reads it too, and proves u2 by PROOF.
write_u() {
  cat > "$project/src/UScript.sml" <<SML
Theory U
Ancestors A

Theorem u1:
  T
Proof
  simp[]
QED

val _ =
  print ("scratch input: " ^
         (case OS.Process.getEnv "HOLBUILD_SCRATCH_INPUT" of
              SOME path =>
                let val input = TextIO.openIn path
                in TextIO.inputAll input before TextIO.closeIn input end
            | NONE => "none\n"));

Theorem u2:
  T
Proof
  $1
QED
SML
}
write_u 'simp[]'
printf 'one\n' > "$tmpdir/one.txt"
printf 'two\n' > "$tmpdir/two.txt"

hb() { (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@"); }
field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }
specs=$project/.holbuild/action-specs

# The option adds one line to each exported spec, naming FILE by its SHA-256,
# and changes nothing else: not the input key, the deps key or the action text.
hb action-spec --upload UTheory > "$tmpdir/batch-plain.txt"
for file in one two; do
  hb action-spec --upload --scratch-input "$tmpdir/$file.txt" UTheory > "$tmpdir/batch-$file.txt"
  sha=$(sha256sum "$tmpdir/$file.txt" | cut -d' ' -f1)
  for theory in ATheory UTheory; do
    [[ "$(field "$tmpdir/batch-plain.txt" "scratch:$theory" 2)" == "$(field "$tmpdir/batch-$file.txt" "scratch:$theory" 2)" ]] || {
      echo "--scratch-input changed $theory's input key" >&2; exit 1; }
    diff "$specs/$(field "$tmpdir/batch-plain.txt" "scratch:$theory" 4)" \
         "$specs/$(field "$tmpdir/batch-$file.txt" "scratch:$theory" 4)" > "$tmpdir/spec.diff" && {
      echo "$theory's spec does not name the scratch input" >&2; exit 1; }
    [[ "$(grep -c '^[<>]' "$tmpdir/spec.diff")" == 1 ]] && grep -qx "> option scratch-input=$sha" "$tmpdir/spec.diff" || {
      echo "--scratch-input changed more of $theory's spec than its option:" >&2; cat "$tmpdir/spec.diff" >&2; exit 1; }
  done
  [[ -f "$tmpdir/remote/cas/$sha" ]] || { echo "the scratch input was not uploaded" >&2; exit 1; }
done
if hb action-spec --scratch-input "$tmpdir/missing.txt" UTheory > "$tmpdir/missing.log" 2>&1; then
  echo "a missing scratch input was accepted" >&2; exit 1
fi
require_grep "\-\-scratch-input: no file" "$tmpdir/missing.log"
mkfifo "$tmpdir/fifo"
if hb action-spec --scratch-input "$tmpdir/fifo" UTheory > "$tmpdir/fifo.log" 2>&1; then
  echo "a FIFO was accepted as the scratch input" >&2; exit 1
fi
require_grep "\-\-scratch-input takes a regular file" "$tmpdir/fifo.log"

# An unchanged input keeps its hash from export to export, by git's index
# scheme: the record is believed while the file's stat matches (a forged
# one shows it), and a touched file is hashed again.  Without --upload, as
# the forged hash would name the wrong bytes.
stats=$project/.holbuild/scratch-input-stats
sha_one=$(sha256sum "$tmpdir/one.txt" | cut -d' ' -f1)
sha_two=$(sha256sum "$tmpdir/two.txt" | cut -d' ' -f1)
scratch_option() {
  hb action-spec --scratch-input "$tmpdir/one.txt" UTheory > "$tmpdir/batch-$1.txt"
  sed -n 's/^option scratch-input=//p' "$specs/$(field "$tmpdir/batch-$1.txt" scratch:UTheory 4)"
}
# Only a file changed over a second before the export is recorded.
while (( $(date +%s) - $(stat -c %Z "$tmpdir/one.txt") < 2 )); do sleep 0.2; done
[[ "$(scratch_option first)" == "$sha_one" ]] || { echo "the scratch input's hash is wrong" >&2; exit 1; }
require_grep "$sha_one" "$stats"
sed -i "s/$sha_one/$sha_two/" "$stats"
[[ "$(scratch_option forged)" == "$sha_two" ]] || { echo "an unchanged scratch input was hashed again" >&2; exit 1; }
touch "$tmpdir/one.txt"
[[ "$(scratch_option touched)" == "$sha_one" ]] || { echo "a touched scratch input kept its old hash" >&2; exit 1; }

# worker_command NAME SPEC [OPTION...]: exec-action of SPEC in the worker's
# cache root, sharing heaps.
worker_cache=$tmpdir/worker
link_hol_toolchain_cache "$worker_cache"
worker_command() {
  local name=$1 spec=$2
  shift 2
  HOLBUILD_CACHE=$worker_cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
    --cache-limit-gb 1000 --share-heaps --result "$tmpdir/$name.result" "$@" > "$tmpdir/$name.log" 2>&1
}
# built NAME INPUT: the worker built U, which read INPUT.
built() {
  grep -qx "status=built" "$tmpdir/$1.result" || {
    echo "worker $1 did not build:" >&2; cat "$tmpdir/$1.log" "$tmpdir/$1.result" >&2; exit 1; }
  local log_sha
  log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/$1.result")
  curl -fsS "$remote_url/cas/$log_sha" > "$tmpdir/$1.hol"
  grep -qx "scratch input: $2" "$tmpdir/$1.hol" || {
    echo "worker $1: U did not read '$2'" >&2; cat "$tmpdir/$1.hol" "$tmpdir/$1.log" >&2; exit 1; }
}

# A run loading ahead of a parent still building stages the input for the
# child it starts.
waiting=$worker_cache/action/.holbuild/ahead/waiting-ATheory
worker_command u-one "$(field "$tmpdir/batch-one.txt" scratch:UTheory 4)" \
  --ahead-parent "$(field "$tmpdir/batch-one.txt" scratch:ATheory 2):$(field "$tmpdir/batch-one.txt" scratch:ATheory 4)" &
u_pid=$!
background+=("$u_pid")
for _ in {1..1200}; do
  [[ -e "$waiting" ]] && break
  kill -0 "$u_pid" 2>/dev/null || break
  sleep 0.1
done
[[ -e "$waiting" ]] || { echo "U never waited for A" >&2; cat "$tmpdir/u-one.log" >&2; exit 1; }
link_hol_toolchain_cache "$tmpdir/worker-a"
HOLBUILD_CACHE=$tmpdir/worker-a "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action \
  "$(field "$tmpdir/batch-one.txt" scratch:ATheory 4)" --cache-limit-gb 1000 \
  --result "$tmpdir/a.result" > "$tmpdir/a.log" 2>&1 || {
  echo "worker a failed" >&2; cat "$tmpdir/a.log" >&2; exit 1; }
wait "$u_pid" || true
built u-one one

# Another input resumes from the theorem context the first shared.  The run
# loads ahead of A, unpublished until U waits for it; then the heap U shared
# makes the load ahead start over plain, which empties the action root, so
# the input is staged again.
write_u 'ACCEPT_TAC TRUTH'
hb action-spec --upload --scratch-input "$tmpdir/two.txt" UTheory > "$tmpdir/batch-u2.txt"
# A is built, so only the first batch exports it.
key_A=$(field "$tmpdir/batch-one.txt" scratch:ATheory 2)
ac_A=$(printf 'holbuild-remote-ac-v1\n%s\n' "$key_A" | sha256sum | cut -d' ' -f1)
mv "$tmpdir/remote/ac/$ac_A" "$tmpdir/ac-A"
worker_command u-two "$(field "$tmpdir/batch-u2.txt" scratch:UTheory 4)" \
  --ahead-parent "$key_A:$(field "$tmpdir/batch-one.txt" scratch:ATheory 4)" &
u_pid=$!
background+=("$u_pid")
for _ in {1..1200}; do
  [[ -e "$waiting" ]] && break
  kill -0 "$u_pid" 2>/dev/null || break
  sleep 0.1
done
[[ -e "$waiting" ]] || { echo "U never waited for A" >&2; cat "$tmpdir/u-two.log" >&2; exit 1; }
mv "$tmpdir/ac-A" "$tmpdir/remote/ac/$ac_A"
wait "$u_pid" || true
built u-two two
# Staged again with the blob in the worker's cache, the input is a link to it.
[[ "$(stat -c %a "$worker_cache/blobs/$sha_two")" == 444 ]] || {
  echo "the restaged scratch input is not the cache's read-only blob" >&2; exit 1; }
require_grep "loading ahead found a build to reuse; building plain" "$tmpdir/u-two.log"
require_grep "from: theorem-context checkpoint after u1" "$tmpdir/u-two.log"

# Locally the child reads FILE itself, and every checkpoint U saves has the
# key it has without the option.
write_u 'simp[]'
local_build() {
  rm -rf "$project/.holbuild"
  use_case_cache "$tmpdir/local-$1"
  (cd "$project" && "$HOLBUILD_BIN" build --no-cache "${@:2}" UTheory) > "$tmpdir/local-$1.log" 2>&1 || {
    cat "$tmpdir/local-$1.log" >&2; exit 1; }
  require_grep "scratch input: $1" "$project/.holbuild/logs/current/scratch/UTheory/build.log"
  find "$project/.holbuild/checkpoints" -name '*.ok' -print0 | sort -z | xargs -0 cat > "$tmpdir/keys-$1"
  [[ -s "$tmpdir/keys-$1" ]] || { echo "U saved no checkpoints" >&2; exit 1; }
}
local_build none
local_build one --scratch-input "$tmpdir/one.txt"
local_build two --scratch-input "$tmpdir/two.txt"
cmp "$tmpdir/keys-none" "$tmpdir/keys-one"
cmp "$tmpdir/keys-none" "$tmpdir/keys-two"
