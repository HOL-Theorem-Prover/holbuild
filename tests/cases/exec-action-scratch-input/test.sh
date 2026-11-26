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
# same with and without it, and whatever FILE holds.  Given more than once,
# the variable holds the paths in order, separated by ":".  A worker's child
# reads each through a link to the worker's blob cache, and no other blob
# there.

tmpdir=$(make_temp_dir)
server_pid=""
background=()
xdev=""
cleanup() {
  for pid in "${background[@]}" "$server_pid"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
  [[ -z "$xdev" ]] || rm -rf "$xdev"
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
  case OS.Process.getEnv "HOLBUILD_SCRATCH_INPUT" of
      SOME paths =>
        List.app (fn path =>
          let val input = TextIO.openIn path
          in
            print ("scratch input: " ^ TextIO.inputAll input);
            TextIO.closeIn input;
            print ("scratch path: " ^ path ^ "\n");
            (* On a worker it links to the cache's blob, which other actions
               trust unread: the child can't change, move or remove it, nor
               list the cache or read the input of another build. *)
            if not (String.isSubstring "/.holbuild/scratch/" path) then () else
            let
              val blobs = "$worker_cache/blobs"
              fun denied f = (f (); false) handle _ => true
              val tries =
                [("append", fn () => BinIO.closeOut (BinIO.openAppend path)),
                 ("rename", fn () => OS.FileSys.rename {old = path, new = path ^ ".moved"}),
                 ("remove", fn () => OS.FileSys.remove path),
                 ("remove-blob", fn () => OS.FileSys.remove (OS.Path.concat (blobs, OS.Path.file path))),
                 ("list", fn () => OS.FileSys.closeDir (OS.FileSys.openDir blobs)),
                 ("other", fn () => TextIO.closeIn (TextIO.openIn (OS.Path.concat (blobs, "$other_blob"))))]
            in
              print ("scratch links: " ^ Int.toString (Posix.FileSys.ST.nlink (Posix.FileSys.stat path)) ^ "\n");
              print ("scratch target: " ^ (Posix.FileSys.readlink path handle OS.SysErr _ => "none") ^ "\n");
              print ("scratch tamper: " ^
                     String.concatWith " " (map (fn (what, f) => what ^ (if denied f then "=denied" else "=allowed")) tries) ^ "\n")
            end
          end) (String.fields (fn c => c = #":") paths)
    | NONE => print "scratch input: none\n";

Theorem u2:
  T
Proof
  $1
QED
SML
}
printf 'one\n' > "$tmpdir/one.txt"
printf 'two\n' > "$tmpdir/two.txt"
# The blob a child of a build with input two must not read, in the
# worker's cache.
other_blob=$(sha256sum "$tmpdir/one.txt" | cut -d' ' -f1)
worker_cache=$tmpdir/worker
write_u 'simp[]'

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

# Given twice, each file gets its own line, in order, and is uploaded.
hb action-spec --upload --scratch-input "$tmpdir/two.txt" --scratch-input "$tmpdir/one.txt" UTheory \
  > "$tmpdir/batch-both.txt"
[[ "$(sed -n 's/^option scratch-input=//p' "$specs/$(field "$tmpdir/batch-both.txt" scratch:UTheory 4)")" == \
   "$(sha256sum "$tmpdir/two.txt" "$tmpdir/one.txt" | cut -d' ' -f1)" ]] || {
  echo "two scratch inputs are not named in order" >&2; exit 1; }
mkdir "$tmpdir/a:b"
cp "$tmpdir/one.txt" "$tmpdir/a:b/one.txt"
if hb action-spec --scratch-input "$tmpdir/two.txt" --scratch-input "$tmpdir/a:b/one.txt" UTheory > "$tmpdir/colon.log" 2>&1; then
  echo "a path with a colon was accepted beside another scratch input" >&2; exit 1
fi
require_grep "takes no path with" "$tmpdir/colon.log"

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
while (( $(date +%s) - $(stat -c %Z "$tmpdir/two.txt") < 2 )); do sleep 0.2; done
[[ "$(scratch_option first)" == "$sha_one" ]] || { echo "the scratch input's hash is wrong" >&2; exit 1; }
require_grep "$sha_one" "$stats"
sed -i "s/$sha_one/$sha_two/" "$stats"
[[ "$(scratch_option forged)" == "$sha_two" ]] || { echo "an unchanged scratch input was hashed again" >&2; exit 1; }
# Another build's input joins the record rather than replacing it.
hb action-spec --scratch-input "$tmpdir/two.txt" UTheory > /dev/null
[[ "$(scratch_option kept)" == "$sha_two" ]] || { echo "another input's export dropped this one's record" >&2; exit 1; }
[[ "$(grep -c "$sha_two" "$stats")" == 2 ]] || { echo "the other input was not recorded beside it" >&2; cat "$stats" >&2; exit 1; }
# Dated ahead, it stays in the racy window however late the export starts.
touch -d "+1 hour" "$tmpdir/one.txt"
[[ "$(scratch_option touched)" == "$sha_one" ]] || { echo "a touched scratch input kept its old hash" >&2; exit 1; }
if grep -q "$sha_one" "$stats"; then echo "a hash read within a second of a change was recorded" >&2; exit 1; fi

# worker_command NAME SPEC [OPTION...]: exec-action of SPEC in the worker's
# cache root, sharing heaps.
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

copies() { sed -n 's/.*[=,]scratchcopyn:\([0-9]*\).*/\1/p' "$tmpdir/$1.result"; }
# in_place NAME SHA LINKS TARGET: worker NAME's child read the input SHA
# staged in its action root, a file with LINKS links, a symbolic link to
# TARGET if not "none", and could neither change it nor see other blobs.
in_place() {
  grep -qx "scratch path: $(realpath "$worker_cache/action")/.holbuild/scratch/$2" "$tmpdir/$1.hol" &&
    grep -qx "scratch links: $3" "$tmpdir/$1.hol" && grep -qx "scratch target: $4" "$tmpdir/$1.hol" || {
    echo "worker $1: the input is not staged as expected" >&2; grep "^scratch" "$tmpdir/$1.hol" >&2; exit 1; }
  grep -qx "scratch tamper: append=denied rename=denied remove=denied remove-blob=denied list=denied other=denied" "$tmpdir/$1.hol" || {
    echo "worker $1: the child could change the input, list the cache or read another blob" >&2
    grep "scratch tamper" "$tmpdir/$1.hol" >&2; exit 1; }
}

# A run loading ahead of a parent still building stages the input for the
# child it starts: the input, which the worker's cache lacks, is fetched into
# it read-only, and the child reads a hard link to it.
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
in_place u-one "$sha_one" 2 none
[[ "$(copies u-one)" == 1 && "$(stat -c %a "$worker_cache/blobs/$sha_one")" == 444 ]] || {
  echo "the input was not fetched read-only into the cache" >&2; cat "$tmpdir/u-one.result" >&2
  ls -la "$worker_cache/blobs" >&2; exit 1; }

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
in_place u-two "$sha_two" 2 none
require_grep "loading ahead found a build to reuse; building plain" "$tmpdir/u-two.log"
require_grep "from: theorem-context checkpoint after u1" "$tmpdir/u-two.log"

# Two inputs: the worker stages both and the child reads them in order.
write_u 'ACCEPT_TAC TRUTH ORELSE simp[]'
hb action-spec --upload --scratch-input "$tmpdir/one.txt" --scratch-input "$tmpdir/two.txt" UTheory \
  > "$tmpdir/batch-both.txt"
worker_command u-both "$(field "$tmpdir/batch-both.txt" scratch:UTheory 4)"
built u-both one
grep -A5 -x "scratch input: one" "$tmpdir/u-both.hol" | grep -qx "scratch input: two" || {
  echo "worker u-both: U did not read both inputs in order" >&2; cat "$tmpdir/u-both.hol" >&2; exit 1; }
# Both are in the cache already: nothing is fetched.
[[ "$(copies u-both)" == 0 ]] || { echo "u-both fetched an input the cache holds" >&2; cat "$tmpdir/u-both.result" >&2; exit 1; }

# Across file systems, as a worker container's action root beside a
# host-mounted cache, the input is a symbolic link to the cache's blob,
# which the child may read alone of the cache.
if [[ -d /dev/shm && -w /dev/shm && "$(stat -c %d /dev/shm)" != "$(stat -c %d "$worker_cache")" ]]; then
  xdev=$(mktemp -d /dev/shm/holbuild-test.XXXXXX)
  cp -a "$worker_cache/blobs/." "$xdev/"
  rm -rf "$worker_cache/blobs"
  ln -s "$xdev" "$worker_cache/blobs"
  write_u 'ALL_TAC >> simp[]'
  hb action-spec --upload --scratch-input "$tmpdir/two.txt" UTheory > "$tmpdir/batch-xdev.txt"
  worker_command u-xdev "$(field "$tmpdir/batch-xdev.txt" scratch:UTheory 4)"
  built u-xdev two
  in_place u-xdev "$sha_two" 1 "$(realpath "$xdev")/$sha_two"
  [[ "$(copies u-xdev)" == 0 ]] || { echo "u-xdev fetched an input the cache holds" >&2; cat "$tmpdir/u-xdev.result" >&2; exit 1; }
  # The blob leaves the cache while the child waits for a parent still
  # building, so the child can't read it: the action fails as the worker's
  # fault, to be retried, and the retry fetches the input again.
  printf '\nTheorem a2:\n  T\nProof\n  simp[]\nQED\n' >> "$project/src/AScript.sml"
  hb action-spec --upload --scratch-input "$tmpdir/two.txt" UTheory > "$tmpdir/batch-evict.txt"
  worker_command u-evict "$(field "$tmpdir/batch-evict.txt" scratch:UTheory 4)" \
    --ahead-parent "$(field "$tmpdir/batch-evict.txt" scratch:ATheory 2):$(field "$tmpdir/batch-evict.txt" scratch:ATheory 4)" &
  u_pid=$!
  background+=("$u_pid")
  for _ in {1..1200}; do
    [[ -e "$waiting" ]] && break
    kill -0 "$u_pid" 2>/dev/null || break
    sleep 0.1
  done
  [[ -e "$waiting" ]] || { echo "U never waited for A" >&2; cat "$tmpdir/u-evict.log" >&2; exit 1; }
  rm "$xdev/$sha_two"
  HOLBUILD_CACHE=$tmpdir/worker-a "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action \
    "$(field "$tmpdir/batch-evict.txt" scratch:ATheory 4)" --cache-limit-gb 1000 \
    --result "$tmpdir/a-evict.result" > "$tmpdir/a-evict.log" 2>&1 || {
    echo "worker a failed" >&2; cat "$tmpdir/a-evict.log" >&2; exit 1; }
  wait "$u_pid" || true
  grep -qx "failure=internal" "$tmpdir/u-evict.result" && require_grep "a scratch input left the worker's cache" "$tmpdir/u-evict.log" || {
    echo "a child that lost its scratch input did not fail as the worker's fault" >&2
    cat "$tmpdir/u-evict.result" "$tmpdir/u-evict.log" >&2; exit 1; }
  worker_command u-evict "$(field "$tmpdir/batch-evict.txt" scratch:UTheory 4)"
  built u-evict two
  in_place u-evict "$sha_two" 1 "$(realpath "$xdev")/$sha_two"
  [[ "$(copies u-evict)" == 1 ]] || { echo "the retry did not fetch the input again" >&2; cat "$tmpdir/u-evict.result" >&2; exit 1; }
else
  echo "skipping the cross-file-system scratch input check: no writable /dev/shm on another device"
fi

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
