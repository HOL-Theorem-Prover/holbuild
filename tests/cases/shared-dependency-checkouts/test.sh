#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Git dependencies are checked out once per cache, read-only, and linked from
# each project's .holbuild/src; cache GC collects checkouts like toolchains.

tmpdir=$(make_temp_dir)
holder=
cleanup() {
  if [[ -n $holder ]]; then
    timeout 10 sh -c ': > "$1"' sh "$tmpdir/blocker.fifo" || true
    wait "$holder" || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fail() { echo "$*" >&2; exit 1; }

# snapshot DIR: every entry's path, mode and modification time.
snapshot() {
  python3 - "$1" <<'PY' | LC_ALL=C sort
import os, sys
root = sys.argv[1]
for top, dirs, files in os.walk(root):
    for path in [top] + [os.path.join(top, name) for name in files]:
        st = os.lstat(path)
        print(os.path.relpath(path, root), oct(st.st_mode), st.st_mtime_ns)
PY
}

# age DAYS PATH: set the modification time DAYS days back.
age() { python3 -c 'import os, sys, time; t = time.time() - float(sys.argv[1]) * 86400; os.utime(sys.argv[2], (t, t))' "$1" "$2"; }

checkout_of() { printf '%s/git/checkouts/%s-%s' "$HOLBUILD_CACHE" "$(printf %s "$1" | sha1sum | cut -d' ' -f1)" "$2"; }

# A real build against a theory in a git dependency writes nothing into the
# shared checkout: the dependency's declared extra outputs, an SML source among
# them, go under each consuming project's .holbuild, whether its theory is
# built or restored from the cache.  Another theory reads one of them as an
# extra input.  The dependency's members overlap, so discovery reaches its
# generated source twice.
use_case_cache "$tmpdir/cache"
dep=$tmpdir/dep
mkdir -p "$dep/src"
{
  write_schema2_prelude
  printf '[project]\nname = "dep"\n\n[build]\nmembers = [".", "src"]\n\n'
  printf '[actions.DUse]\ndeps = ["DTheory"]\n'
} > "$dep/holproject.toml"
cat > "$dep/src/DScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ();
val () = holbuild_extra_outputs ["results/D.txt", "DGenML.sml"];
fun write path text = let val out = TextIO.openOut path in TextIO.output (out, text); TextIO.closeOut out end;
val () = write "results/D.txt" "dep result\n";
val () = write "DGenML.sml" "structure DGenML = struct val x = 42 end\n";
open HolKernel Parse boolLib bossLib;
val _ = new_theory "D";
val d_def = new_definition("d_def", ``d_const = T``);
val _ = export_theory();
SML
cat > "$dep/src/EScript.sml" <<'SML'
fun holbuild_extra_deps (_ : string list) = ();
fun holbuild_extra_outputs (_ : string list) = ();
val () = holbuild_extra_deps ["results/D.txt"];
val () = holbuild_extra_outputs ["results/E.txt"];
val () = let val input = TextIO.openIn "results/D.txt"; val text = TextIO.inputAll input
             val () = TextIO.closeIn input; val out = TextIO.openOut "results/E.txt"
         in TextIO.output (out, "read " ^ text); TextIO.closeOut out end;
open HolKernel Parse boolLib bossLib;
val _ = new_theory "E";
val _ = export_theory();
SML
cat > "$dep/src/DUse.sml" <<'SML'
structure DUse = struct val y = DGenML.x + 1 end
SML
dep_rev=$(init_git_repo "$dep")

project=$tmpdir/project
mkdir -p "$project/src"
{
  write_schema2_prelude
  printf '[project]\nname = "user"\n\n[build]\nmembers = ["src"]\n\n'
  printf '[dependencies.dep]\ngit = "%s"\nrev = "%s"\n' "$dep" "$dep_rev"
} > "$project/holproject.toml"
cat > "$project/src/UScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ();
val () = holbuild_extra_outputs ["results/U.txt"];
open HolKernel Parse boolLib bossLib DTheory ETheory;
val () = let val out = TextIO.openOut "results/U.txt"
         in TextIO.output (out, "user result " ^ Int.toString DUse.y ^ "\n"); TextIO.closeOut out end;
val _ = new_theory "U";
val u_thm = store_thm("u_thm", ``d_const``, REWRITE_TAC [d_def]);
val _ = export_theory();
SML
cp -R "$project" "$tmpdir/copy"

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log"
checkout=$(checkout_of "$dep" "$dep_rev")
[[ $(readlink "$project/.holbuild/src/dep") == "$checkout" ]] || fail ".holbuild/src/dep does not link to $checkout"
require_file "$checkout/src/DScript.sml"
[[ ! -e $checkout/.git ]] || fail "shared checkout has git metadata"
[[ -z $(find "$checkout" -type f -perm -u=w) ]] || fail "shared checkout has writable files"
if (echo edit >> "$project/.holbuild/src/dep/src/DScript.sml") 2> /dev/null; then fail "edited a shared checkout file in place"; fi
before=$(snapshot "$checkout")
# require_outputs PROJECT: the dependency's and the project's extra outputs.
require_outputs() {
  require_grep "dep result" "$1/.holbuild/packages/dep/extra-outputs/src/results/D.txt"
  require_file "$1/.holbuild/packages/dep/extra-outputs/src/DGenML.sml"
  require_grep "read dep result" "$1/.holbuild/packages/dep/extra-outputs/src/results/E.txt"
  require_grep "user result 43" "$1/src/results/U.txt"
}
(cd "$project" && "$HOLBUILD_BIN" build) > "$tmpdir/build.log" 2>&1 || { cat "$tmpdir/build.log" >&2; fail "build failed"; }
require_outputs "$project"
[[ $(snapshot "$checkout") == "$before" ]] || fail "build wrote into the shared checkout"
(cd "$project" && "$HOLBUILD_BIN" --verbose build) > "$tmpdir/rebuild.log" 2>&1 || { cat "$tmpdir/rebuild.log" >&2; fail "rebuild failed"; }
require_grep "UTheory is up to date" "$tmpdir/rebuild.log"

# A second project directory links to the same checkout instead of cloning,
# and restores the dependency's theory and its outputs from the cache.  An
# output of its own that it never claimed is still refused.  Its record from
# 0.14.64 of outputs in the dependency's sources, here files the checkout
# tracks, is dropped without removing them, whether or not their claims
# survived.
(cd "$tmpdir/copy" && "$HOLBUILD_BIN" context) > /dev/null
record=$(grep -l 'results/D.txt' "$project"/.holbuild/extra-outputs/actions/*.outputs)
output=$(grep -m1 '^path .*results/D.txt$' "$record")
output=${output#path }
legacy=${output%%/.holbuild/*}
legacy=${legacy%/project}/copy/.holbuild/src/dep
legacy_unclaimed=$legacy/holproject.toml
legacy=$legacy/src/DScript.sml
legacy_claim=$tmpdir/copy/.holbuild/extra-outputs/owners/$(printf %s "$legacy" | sha256sum | cut -d' ' -f1).owner
mkdir -p "$tmpdir/copy/.holbuild/extra-outputs/actions" "$tmpdir/copy/.holbuild/extra-outputs/owners"
printf 'holbuild-extra-output-action-v1\n%s\npath %s\npath %s\n' "$(sed -n 2p "$record")" "$legacy" "$legacy_unclaimed" \
  > "$tmpdir/copy/.holbuild/extra-outputs/actions/${record##*/}"
printf 'holbuild-extra-output-owner-v1\n%s\npath %s\n' "$(sed -n 2p "$record")" "$legacy" > "$legacy_claim"
[[ $(readlink "$tmpdir/copy/.holbuild/src/dep") == "$checkout" ]] || fail "second project did not link the shared checkout"
[[ $(find "$HOLBUILD_CACHE/git/checkouts" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l) == 1 ]] ||
  fail "second project made another checkout"
mkdir -p "$tmpdir/copy/src/results"
echo stray > "$tmpdir/copy/src/results/U.txt"
if (cd "$tmpdir/copy" && "$HOLBUILD_BIN" build) > "$tmpdir/copy-unowned.log" 2>&1; then
  fail "build overwrote an unowned extra output"
fi
require_grep "extra output already exists without an ownership record: .*src/results/U.txt" "$tmpdir/copy-unowned.log"
require_grep "DTheory restored from cache" "$tmpdir/copy-unowned.log"
rm "$tmpdir/copy/src/results/U.txt"
(cd "$tmpdir/copy" && "$HOLBUILD_BIN" build) > "$tmpdir/copy-build.log" 2>&1 || { cat "$tmpdir/copy-build.log" >&2; fail "second build failed"; }
require_grep "UTheory restored from cache" "$tmpdir/copy-build.log"
require_outputs "$tmpdir/copy"
[[ $(snapshot "$checkout") == "$before" ]] || fail "second build wrote into the shared checkout"
[[ ! -e $legacy_claim ]] || fail "second build kept its claim on an output in the dependency's sources"

# A source in the extra-output directory that no theory of the dependency
# declares, say from an older pin, is not the dependency's.
echo 'structure DUse = struct val y = 0 end' > "$tmpdir/copy/.holbuild/packages/dep/extra-outputs/src/DUse.sml"
(cd "$tmpdir/copy" && "$HOLBUILD_BIN" --verbose build) > "$tmpdir/copy-stale.log" 2>&1 || { cat "$tmpdir/copy-stale.log" >&2; fail "build with a stale output failed"; }
require_grep "UTheory is up to date" "$tmpdir/copy-stale.log"

# GC runs on a cache of its own, which links no shared toolchains, with a HOL
# dependency that is never built.
export HOLBUILD_CACHE=$tmpdir/gc-cache
hol=$tmpdir/hol
mkdir -p "$hol"
echo upstream-hol-without-holproject > "$hol/README"
hol_rev=$(init_git_repo "$hol")
hol_dependency=$(printf '[dependencies.hol]\ngit = "%s"\nrev = "%s"' "$hol" "$hol_rev")
# write_manifest DIR NAME [DEPENDENCY NAME]...: a manifest with the HOL
# dependency and the named git dependencies at the revs in $<name>_rev.
write_manifest() {
  local dir=$1 name=$2 dependency rev_var
  shift 2
  mkdir -p "$dir"
  {
    printf '[holbuild]\nminimum_version = "0.13.18"\n\n[project]\nname = "%s"\n\n%s\n' "$name" "$hol_dependency"
    for dependency in "$@"; do
      rev_var=${dependency}_rev
      printf '\n[dependencies.%s]\ngit = "%s"\nrev = "%s"\n' "$dependency" "$tmpdir/$dependency" "${!rev_var}"
    done
  } > "$dir/holproject.toml"
}
write_manifest "$tmpdir/lib" lib
lib_rev=$(init_git_repo "$tmpdir/lib")
gc_project=$tmpdir/gc-project
write_manifest "$gc_project" gc_project lib
lib_checkout=$(checkout_of "$tmpdir/lib" "$lib_rev")
context() { (cd "$1" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log" 2>&1 || { cat "$tmpdir/context.log" >&2; fail "context failed in $1"; }; }
gc() { "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/gc.log" 2>&1 || { cat "$tmpdir/gc.log" >&2; fail "gc failed"; }; }

# 1. Every use rewrites the checkout's last-used marker.
context "$gc_project"
require_file "$lib_checkout.last-used"
age 30 "$lib_checkout.last-used"
context "$gc_project"
[[ -n $(find "$lib_checkout.last-used" -mtime -1) ]] || fail "use did not refresh the last-used marker"

# 2. A holbuild process using the checkout holds its usage lease until it
# exits, so GC skips it however old its marker is. The holder is kept alive by
# a second git dependency whose mirror clone blocks on a FIFO.
write_manifest "$tmpdir/blocker" blocker
blocker_rev=$(init_git_repo "$tmpdir/blocker")
write_manifest "$tmpdir/holder" holder lib blocker
blocking_git=$tmpdir/blocking-git
mkdir -p "$blocking_git"
mkfifo "$tmpdir/blocker.fifo"
real_git=$(command -v git)
cat > "$blocking_git/git" <<SH
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "$tmpdir/blocker" ]; then
    : > "$tmpdir/blocker.ready"
    timeout 120 cat "$tmpdir/blocker.fifo" > /dev/null
    break
  fi
done
exec "$real_git" "\$@"
SH
chmod +x "$blocking_git/git"
(cd "$tmpdir/holder" && PATH="$blocking_git:$PATH" "$HOLBUILD_BIN" context) > "$tmpdir/holder.log" 2>&1 &
holder=$!
for _ in {1..600}; do
  [[ -e "$tmpdir/blocker.ready" ]] && break
  sleep 0.05
done
require_file "$tmpdir/blocker.ready"
age 30 "$lib_checkout.last-used"
gc
require_grep "checkouts=0 checkouts-busy=1" "$tmpdir/gc.log"
require_file "$lib_checkout/holproject.toml"
timeout 10 sh -c ': > "$1"' sh "$tmpdir/blocker.fifo"
wait "$holder" || { cat "$tmpdir/holder.log" >&2; fail "lease holder failed"; }
holder=

# 3. Once no process uses it, GC removes a checkout unused for the retention
# period; a recently used one stays, and so do the mirrors.
age 6 "$lib_checkout.last-used"
gc
require_grep "checkouts=0 checkouts-busy=0" "$tmpdir/gc.log"
require_file "$lib_checkout/holproject.toml"
age 8 "$lib_checkout.last-used"
gc
require_grep "checkouts=1 checkouts-busy=0" "$tmpdir/gc.log"
[[ ! -e $lib_checkout && ! -e $lib_checkout.last-used ]] || fail "GC left the stale checkout"
[[ -L $gc_project/.holbuild/src/lib && ! -e $gc_project/.holbuild/src/lib ]] || fail "expected a dangling link"
[[ -d $HOLBUILD_CACHE/git/remotes/$(printf %s "$tmpdir/lib" | sha1sum | cut -d' ' -f1).git ]] || fail "GC removed the mirror"

# 4. The next use of a project linking to the collected checkout makes it again.
context "$gc_project"
require_file "$gc_project/.holbuild/src/lib/holproject.toml"
[[ $(readlink "$gc_project/.holbuild/src/lib") == "$lib_checkout" ]] || fail "link changed on re-materialisation"

# GC removes what an interrupted GC left in its trash.
leftover=$HOLBUILD_CACHE/git/checkouts/.trash/leftover.999999999
mkdir -p "$leftover/sub"
: > "$leftover/sub/file"
chmod a-w "$leftover/sub/file"
gc
[[ ! -e $leftover ]] || fail "GC left checkout trash"

# A private clone already at the pinned commit, as earlier versions made, is
# used as it is until the pin changes, offline too, without making the shared
# checkout.
upgrade=$tmpdir/upgrade
write_manifest "$upgrade" upgrade lib
mkdir -p "$upgrade/.holbuild/src"
git clone -q "$tmpdir/lib" "$upgrade/.holbuild/src/lib"
rm -rf "$lib_checkout"
(cd "$upgrade" && "$HOLBUILD_BIN" --offline context) > "$tmpdir/context.log" 2>&1 ||
  { cat "$tmpdir/context.log" >&2; fail "offline context failed on a clone at the pin"; }
context "$upgrade"
[[ -d $upgrade/.holbuild/src/lib/.git && ! -L $upgrade/.holbuild/src/lib ]] || fail "existing clone at the pin was replaced"
[[ ! -e $lib_checkout ]] || fail "made a shared checkout that a clone at the pin made unnecessary"
echo two > "$tmpdir/lib/value.txt"
git -C "$tmpdir/lib" add value.txt
git -C "$tmpdir/lib" commit -q -m two
lib_rev=$(git -C "$tmpdir/lib" rev-parse HEAD)
write_manifest "$upgrade" upgrade lib
context "$upgrade"
[[ $(readlink "$upgrade/.holbuild/src/lib") == "$(checkout_of "$tmpdir/lib" "$lib_rev")" ]] ||
  fail "repinned clone was not replaced by a link"

# A dependency with generators writes into its own sources, so it gets a
# private clone, which later runs keep.
write_manifest "$tmpdir/gen" gen
cat >> "$tmpdir/gen/holproject.toml" <<'TOML'

[[generate]]
name = "out"
command = ["sh", "-c", "echo generated > out.txt"]
outputs = ["out.txt"]
TOML
gen_rev=$(init_git_repo "$tmpdir/gen")
write_manifest "$tmpdir/gen-project" gen_project gen
for _ in 1 2; do
  context "$tmpdir/gen-project"
  [[ -d $tmpdir/gen-project/.holbuild/src/gen/.git && ! -L $tmpdir/gen-project/.holbuild/src/gen ]] ||
    fail "dependency with generators did not get a private clone"
done

# Without a usable shared checkout directory, holbuild warns and clones.
export HOLBUILD_CACHE=$tmpdir/fallback-cache
mkdir -p "$HOLBUILD_CACHE/git"
: > "$HOLBUILD_CACHE/git/checkouts"
fallback=$tmpdir/fallback
write_manifest "$fallback" fallback lib
(cd "$fallback" && "$HOLBUILD_BIN" context) > /dev/null 2> "$tmpdir/fallback.log"
require_grep "cannot use a shared dependency checkout, cloning instead" "$tmpdir/fallback.log"
[[ -d $fallback/.holbuild/src/lib/.git && ! -L $fallback/.holbuild/src/lib ]] || fail "fallback did not clone"
