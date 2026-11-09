#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"
unset HOLBUILD_REMOTE_CACHE_URL
store=$tmpdir/cache/checkpoint-store

# Two worktrees of one project share the host's deps heaps.
make_tree() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "heaps"

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
  cat > "$project/src/helperLib.sml" <<'SML'
structure helperLib = struct val helper_thm = boolTheory.TRUTH end
SML
  cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A
Libs helperLib

Theorem b_thm:
  T
Proof
  ACCEPT_TAC helperLib.helper_thm
QED
SML
}
outputs() { (cd "$1/.holbuild/obj/src" && sha256sum ATheory.sig ATheory.sml ATheory.dat BTheory.sig BTheory.sml BTheory.dat); }
# Each build uses the cache, which turns the store on, but misses its action
# entries, so the theories build from source.
build_uncached() { rm -rf "$HOLBUILD_CACHE/actions" "$HOLBUILD_CACHE/blobs"; "$HOLBUILD_BIN" build "$@"; }
deps_heap() { find "$1/.holbuild/checkpoints/heaps/src/$2Script.sml.deps" -name deps_loaded.save | head -n 1; }

first=$tmpdir/first
second=$tmpdir/second
make_tree "$first"
make_tree "$second"

# The first tree's build adds its deps heaps to the store, by hard link.
(cd "$first" && build_uncached BTheory) > "$tmpdir/first.log" 2>&1 \
  || { cat "$tmpdir/first.log" >&2; exit 1; }
first_outputs=$(outputs "$first")
first_heap=$(deps_heap "$first" B)
[[ -n "$first_heap" ]] || { echo "the first tree saved no deps heap for B" >&2; exit 1; }
stored=$(find "$store" -name deps_loaded.save -samefile "$first_heap")
[[ -n "$stored" ]] || { echo "B's deps heap is not linked into the store" >&2; find "$store" >&2; exit 1; }

# HOL puts the project's directories on the load path when it starts; the
# stored heap keeps only the toolchain's entries, so a later load in another
# tree can't find files in this one.
mkdir -p "$tmpdir/elsewhere"
cat > "$tmpdir/loadpath.sml" <<'SML'
val _ = print ("holdir " ^ Systeml.HOLDIR ^ "\n");
val _ = app (fn d => print ("loadpath " ^ d ^ "\n")) (!Meta.loadPath);
SML
(cd "$tmpdir/elsewhere" && "$HOLDIR/bin/hol" run --noconfig --holstate "$stored" "$tmpdir/loadpath.sml") \
  > "$tmpdir/loadpath.log" 2>&1 || { cat "$tmpdir/loadpath.log" >&2; exit 1; }
holdir=$(sed -n 's/^holdir //p' "$tmpdir/loadpath.log")
[[ -n "$holdir" ]] || { cat "$tmpdir/loadpath.log" >&2; exit 1; }
require_grep "^loadpath $holdir/sigobj\$" "$tmpdir/loadpath.log"
if grep '^loadpath ' "$tmpdir/loadpath.log" | grep -v -e "^loadpath $holdir/" -e "^loadpath $holdir\$" | grep -q .; then
  echo "the stored heap's load path has entries outside the toolchain" >&2
  cat "$tmpdir/loadpath.log" >&2
  exit 1
fi

# With the first tree gone, the second resumes from the store's heaps and
# builds the same outputs: nothing in the heap points into the deleted tree.
stored_id=$(stat -c %d:%i "$stored")
rm -rf "$first"
(cd "$second" && build_uncached BTheory) > "$tmpdir/second.log" 2>&1 \
  || { cat "$tmpdir/second.log" >&2; exit 1; }
grep -A1 '^resuming BTheory' "$tmpdir/second.log" | grep -q 'from: deps-loaded checkpoint' \
  || { echo "the second tree did not resume B from the shared deps heap" >&2; cat "$tmpdir/second.log" >&2; exit 1; }
if grep -q 'discarding invalid checkpoint' "$tmpdir/second.log"; then
  echo "the second tree could not resume from the shared deps heap" >&2
  cat "$tmpdir/second.log" >&2
  exit 1
fi
[[ "$(stat -c %d:%i "$(deps_heap "$second" B)")" == "$stored_id" ]] \
  || { echo "the second tree's deps heap is not the stored one" >&2; exit 1; }
if [[ "$first_outputs" != "$(outputs "$second")" ]]; then
  echo "a shared deps heap changed theory outputs" >&2
  exit 1
fi

# A tree resuming from the stored heap searches its own directories: its
# theory loads a module of its own, built beforehand, that isn't in the
# preload.
own=$tmpdir/own
make_tree "$own"
cat > "$own/src/ownLib.sml" <<'SML'
structure ownLib = struct val own_thm = boolTheory.TRUTH end
SML
sed -i 's/^Theorem b_thm:/val _ = load ("own" ^ "Lib");\n\nTheorem b_thm:/' "$own/src/BScript.sml"
(cd "$own" && build_uncached ownLib && build_uncached BTheory) > "$tmpdir/own.log" 2>&1 \
  || { cat "$tmpdir/own.log" >&2; exit 1; }
grep -A1 '^resuming BTheory' "$tmpdir/own.log" | grep -q 'from: deps-loaded checkpoint' \
  || { echo "the tree with its own module did not resume B from the shared deps heap" >&2; cat "$tmpdir/own.log" >&2; exit 1; }
if grep -q 'discarding invalid checkpoint' "$tmpdir/own.log"; then
  echo "the tree with its own module could not resume from the shared deps heap" >&2
  cat "$tmpdir/own.log" >&2
  exit 1
fi
[[ "$(stat -c %d:%i "$(deps_heap "$own" B)")" == "$stored_id" ]] \
  || { echo "the own-module tree's deps heap is not the stored one" >&2; exit 1; }

# A build with --no-cache neither resumes from the store nor adds to it.
nocache=$tmpdir/nocache
make_tree "$nocache"
(cd "$nocache" && "$HOLBUILD_BIN" build --no-cache BTheory) > "$tmpdir/nocache.log" 2>&1 \
  || { cat "$tmpdir/nocache.log" >&2; exit 1; }
if grep -A1 '^resuming BTheory' "$tmpdir/nocache.log" | grep -q 'from: deps-loaded checkpoint'; then
  echo "a --no-cache build resumed from the stored heap" >&2
  exit 1
fi
[[ "$(stat -c %d:%i "$stored")" == "$stored_id" ]] \
  || { echo "a --no-cache build changed the stored heap" >&2; exit 1; }

# A tree whose dependencies differ doesn't resume from the store's heap.
changed=$tmpdir/changed
make_tree "$changed"
printf 'structure helperExtra = struct val n = 1 end\n' >> "$changed/src/helperLib.sml"
(cd "$changed" && build_uncached BTheory) > "$tmpdir/changed.log" 2>&1 \
  || { cat "$tmpdir/changed.log" >&2; exit 1; }
if grep -A1 '^resuming BTheory' "$tmpdir/changed.log" | grep -q 'from: deps-loaded checkpoint'; then
  echo "a tree with other dependencies resumed from the stored heap" >&2
  exit 1
fi

# A stored heap whose parent isn't this build's base state is not used.
third=$tmpdir/third
make_tree "$third"
printf 'not a heap\n' > "$tmpdir/bogus" && cp "$tmpdir/bogus" "$stored.tmp-bogus"
mv "$stored.tmp-bogus" "$stored"
(cd "$third" && build_uncached BTheory) > "$tmpdir/third.log" 2>&1 \
  || { cat "$tmpdir/third.log" >&2; exit 1; }
if grep -A1 '^resuming BTheory' "$tmpdir/third.log" | grep -q 'from: deps-loaded checkpoint'; then
  echo "the third tree resumed from a bogus stored heap" >&2
  exit 1
fi
[[ "$(deps_heap "$third" B)" -ef "$stored" ]] \
  || { echo "a successful build did not replace the bogus stored heap" >&2; exit 1; }

# A stored heap with the right parent that HOL can't resume from is
# replaced by the fresh one, also when the theory then fails.
fourth=$tmpdir/fourth
make_tree "$fourth"
sed -i 's/ACCEPT_TAC helperLib.helper_thm/NO_TAC/' "$fourth/src/BScript.sml"
# Poly/ML checks the parent's time stamp in the header when it loads the
# state, not when it reads the parent name. On 64-bit hosts that stamp is
# bytes 68-75 in the v5.9.2-seq4 header and 72-79 in the v5.9.2-seq5 one;
# bytes 72-75 are in it for both.
cp "$stored" "$tmpdir/stale"
printf '\xff\xff\xff\xff' | dd of="$tmpdir/stale" bs=1 seek=72 conv=notrunc status=none
mv "$tmpdir/stale" "$stored"
stale_sum=$(sha256sum < "$stored")
if (cd "$fourth" && build_uncached BTheory) > "$tmpdir/fourth.log" 2>&1; then
  echo "the failing theory built" >&2
  exit 1
fi
require_grep 'discarding invalid checkpoint after HOL state load failure' "$tmpdir/fourth.log"
[[ "$(sha256sum < "$stored")" != "$stale_sum" ]] \
  || { echo "a failed build kept a stored heap HOL could not resume from" >&2; cat "$tmpdir/fourth.log" >&2; exit 1; }
[[ "$(deps_heap "$fourth" B)" -ef "$stored" ]] \
  || { echo "the store does not hold the failed build's fresh heap" >&2; exit 1; }

# A build sweeps store heaps no tree links that no build used within a day,
# and keeps one a tree still links, however old.
family=$(dirname "$stored")
orphan=$store/orphan-family
mkdir -p "$orphan"
cp "$stored" "$orphan/deps_loaded.save"
touch -d '2 days ago' "$orphan" "$family"
(cd "$second" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/sweep.log" 2>&1 \
  || { cat "$tmpdir/sweep.log" >&2; exit 1; }
[[ ! -e "$orphan" ]] || { echo "a build kept an unlinked, unused store heap" >&2; exit 1; }
[[ -e "$stored" ]] || { echo "a build swept a store heap a tree still links" >&2; exit 1; }

# gc removes families no build used within the retention window. It runs
# on its own cache, so it can't touch the suite's shared toolchains.
gc_cache=$tmpdir/gc-cache
mkdir -p "$gc_cache"
cp -a "$store" "$gc_cache/"
family=$(dirname "${stored#"$store/"}")
touch -d '60 days ago' "$gc_cache/checkpoint-store/$family"
# A heap a tree still links stays, however old: removing it frees nothing.
linked=$gc_cache/checkpoint-store/linked-family
mkdir -p "$linked"
cp "$stored" "$linked/deps_loaded.save"
ln "$linked/deps_loaded.save" "$tmpdir/tree-link"
touch -d '60 days ago' "$linked"
HOLBUILD_CACHE=$gc_cache "$HOLBUILD_BIN" gc --cache-only --days 30 > "$tmpdir/gc.log" 2>&1 \
  || { cat "$tmpdir/gc.log" >&2; exit 1; }
[[ ! -e "$gc_cache/checkpoint-store/$family" ]] || { echo "gc kept a stale store family" >&2; exit 1; }
[[ -e "$linked" ]] || { echo "gc removed a store heap a tree still links" >&2; exit 1; }
require_grep "checkpoint store gc: removed families=1" "$tmpdir/gc.log"

# Cleaning a project's checkpoints keeps the store family while another tree
# links it or while a process leases it, and evicts it once the last tree link
# goes with no lease held (retaining the .lease file).
family_dir=$(dirname "$stored")
fourth_heap=$(deps_heap "$fourth" B)
third_heap=$(deps_heap "$third" B)
ln -f "$stored" "$third_heap"
(cd "$third" && "$HOLBUILD_BIN" gc --clean-only --days 0) > "$tmpdir/clean-linked.log" 2>&1 \
  || { cat "$tmpdir/clean-linked.log" >&2; exit 1; }
[[ -e "$stored" ]] || { echo "clean-only gc removed a store heap another tree still links" >&2; exit 1; }

fourth_ok=$(cat "$fourth_heap.ok")
python3 - "$family_dir.lease" <<'PY' > "$tmpdir/lease.ready" &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.lockf(fd, fcntl.LOCK_SH)
sys.stdout.write("locked\n")
sys.stdout.flush()
time.sleep(60)
PY
lease_pid=$!
while [[ ! -s "$tmpdir/lease.ready" ]]; do sleep 0.02; done
(cd "$fourth" && "$HOLBUILD_BIN" gc --clean-only --days 0) > "$tmpdir/clean-leased.log" 2>&1 \
  || { kill "$lease_pid" 2>/dev/null || true; cat "$tmpdir/clean-leased.log" >&2; exit 1; }
kill "$lease_pid" 2>/dev/null || true
wait "$lease_pid" 2>/dev/null || true
[[ -e "$stored" ]] || { echo "clean-only gc removed a leased store family" >&2; exit 1; }

mkdir -p "$(dirname "$fourth_heap")"
ln "$stored" "$fourth_heap"
printf '%s\n' "$fourth_ok" > "$fourth_heap.ok"
(cd "$fourth" && "$HOLBUILD_BIN" gc --clean-only --days 0) > "$tmpdir/clean-last.log" 2>&1 \
  || { cat "$tmpdir/clean-last.log" >&2; exit 1; }
[[ ! -e "$family_dir" ]] || { echo "clean-only gc kept an unlinked, unleased store family" >&2; exit 1; }
[[ -e "$family_dir.lease" ]] || { echo "clean-only gc unlinked the store family lease file" >&2; exit 1; }

# A build's local store sweep caps recent unlinked (st_nlink == 1) families at
# 5 GB, evicting oldest first, not counting leased families that could not be
# evicted, and leaving linked (st_nlink >= 2) and remote-exec families alone.
orphan_leased=$store/cap-leased
orphan_old=$store/cap-old
orphan_new=$store/cap-new
linked_big=$store/cap-linked
remote_big=$store/cap-remote
mkdir -p "$orphan_leased" "$orphan_old" "$orphan_new" "$linked_big" "$remote_big"
truncate -s 2G "$orphan_leased/deps_loaded.save" "$orphan_old/deps_loaded.save" \
  "$orphan_new/deps_loaded.save" "$linked_big/deps_loaded.save" \
  "$remote_big/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
ln "$linked_big/deps_loaded.save" "$tmpdir/cap-linked-ref"
touch -d '4 hours ago' "$remote_big"
touch -d '3 hours ago' "$linked_big"
touch -d '2 hours ago' "$orphan_leased"
touch -d '1 hour ago' "$orphan_old"

rm -f "$tmpdir/lease.ready"
python3 - "$orphan_leased.lease" <<'PY' > "$tmpdir/lease.ready" &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.lockf(fd, fcntl.LOCK_SH)
sys.stdout.write("locked\n")
sys.stdout.flush()
time.sleep(60)
PY
lease_pid=$!
while [[ ! -s "$tmpdir/lease.ready" ]]; do sleep 0.02; done
(cd "$second" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/cap-sweep.log" 2>&1 \
  || { kill "$lease_pid" 2>/dev/null || true; cat "$tmpdir/cap-sweep.log" >&2; exit 1; }
kill "$lease_pid" 2>/dev/null || true
wait "$lease_pid" 2>/dev/null || true

[[ ! -e "$orphan_old" ]] || { echo "cap sweep kept the oldest unlinked family over budget" >&2; exit 1; }
[[ -e "$orphan_old.lease" ]] || { echo "cap sweep removed the evicted family's lease file" >&2; exit 1; }
[[ -e "$orphan_leased" ]] || { echo "cap sweep removed a leased family" >&2; exit 1; }
[[ -e "$orphan_new" ]] || { echo "cap sweep removed a newer family within the 5 GB cap" >&2; exit 1; }
[[ -e "$linked_big" ]] || { echo "cap sweep removed a linked store family" >&2; exit 1; }
[[ -e "$remote_big" ]] || { echo "cap sweep removed a remote-exec store family" >&2; exit 1; }
