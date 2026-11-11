#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A package's capsule source snapshot builds like its git checkout: a chain
# A <- B <- C is built from git checkouts and from snapshots extracted with plain
# tar (dependencies reached through `.holconfig.toml` path overrides, so nothing
# is cloned), and the builds must share action keys and cache entries.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

new_cache() {
  link_hol_toolchain_cache "$tmpdir/cache-$1"
}

# hb DIR CACHE ARGS...: run holbuild in DIR with the named cache.
hb() {
  local dir=$1 cache=$2
  shift 2
  (cd "$dir" && HOLBUILD_CACHE="$tmpdir/cache-$cache" "$HOLBUILD_BIN" "$@")
}

expect_failure() {
  local name=$1 pattern=$2
  shift 2
  if "$@" > "$tmpdir/$name.log" 2>&1; then
    echo "$name: command succeeded but should have failed" >&2
    exit 1
  fi
  require_grep "$pattern" "$tmpdir/$name.log"
}

# build_chain DIR CACHE NAME STATE...: build CTheory in DIR and require each
# theory's state (built or restored from cache) in the build's log.
build_chain() {
  local dir=$1 cache=$2 name=$3 log=$tmpdir/$3.log
  shift 3
  hb "$dir" "$cache" build CTheory > "$log" 2>&1 || { cat "$log" >&2; exit 1; }
  require_grep "ATheory $1" "$log"
  require_grep "BTheory $2" "$log"
  require_grep "CTheory $3" "$log"
}

# An overridden dependency is used in place, never cloned.
require_no_clone() {
  [[ ! -e $1/.holbuild/src ]] || { echo "a dependency was cloned into $1" >&2; exit 1; }
}

# keys DIR CACHE OUT: one line per theory with its input key, from a dry run.
keys() {
  hb "$1" "$2" build --dry-run CTheory > "$3.dry" 2>&1
  awk '/^[A-Za-z0-9_]+ \(theory,/ {name = $1} /^  input_key:/ {print name, $2}' "$3.dry" | sort > "$3"
  [[ $(wc -l < "$3") -eq 3 ]] || { echo "expected 3 input keys in $3.dry" >&2; cat "$3.dry" >&2; exit 1; }
}

# extract_snapshot CAPSULE DEST: the source snapshot with plain tar.
extract_snapshot() {
  mkdir -p "$2"
  tar -xf "$1" -C "$2" --strip-components=2 holbuild-package/source
}

# Roots of C's snapshot: dependencies resolve to the extracted snapshots.
override_deps() {
  local root=$1 snaps=$2
  cat > "$root/.holconfig.toml" <<TOML
[overrides.pkg_a]
path = "$snaps/A"

[overrides.pkg_b]
path = "$snaps/B"
TOML
}

# The chain's git repositories.  A generates src/gen.txt from data/gen-in.txt;
# B declares data/b.txt as an extra input.
a_repo=$tmpdir/repos/A
b_repo=$tmpdir/repos/B
c_repo=$tmpdir/repos/C
mkdir -p "$a_repo"/{src,data} "$b_repo"/{src,data} "$c_repo/src"

cat > "$a_repo/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "pkg_a"
version = "1.0.0"

[build]
members = ["src"]

[[generate]]
name = "gen"
command = ["sh", "-c", "cp data/gen-in.txt src/gen.txt"]
inputs = ["data/gen-in.txt"]
outputs = ["src/gen.txt"]
TOML
printf 'one\n' > "$a_repo/data/gen-in.txt"
write_a_script() {
  cat > "$a_repo/src/AScript.sml" <<SML
fun holbuild_extra_deps (_ : string list) = ()
val () = holbuild_extra_deps ["gen.txt"]
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val contents = let val s = TextIO.openIn "gen.txt" in TextIO.inputAll s before TextIO.closeIn s end
val flag = if String.isPrefix "one" contents then ``T`` else ``F``
val a_flag_def = Define \`a_flag = ^flag\`;
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
$1
val _ = export_theory();
SML
}
write_a_script ""
a_rev=$(init_git_repo "$a_repo")

cat > "$b_repo/holproject.toml" <<TOML
$(write_schema2_prelude)
[dependencies.pkg_a]
git = "$a_repo"
rev = "$a_rev"

[project]
name = "pkg_b"
version = "1.0.0"

[build]
members = ["src"]

[actions.BTheory]
extra_inputs = ["data/b.txt"]
TOML
printf 'one\n' > "$b_repo/data/b.txt"
cat > "$b_repo/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
val contents = let val s = TextIO.openIn "../data/b.txt" in TextIO.inputAll s before TextIO.closeIn s end
val flag = if String.isPrefix "one" contents then ``T`` else ``F``
val b_flag_def = Define `b_flag = ^flag`;
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
b_rev=$(init_git_repo "$b_repo")

cat > "$c_repo/holproject.toml" <<TOML
$(write_schema2_prelude)
[dependencies.pkg_b]
git = "$b_repo"
rev = "$b_rev"

[project]
name = "pkg_c"
version = "1.0.0"

[build]
members = ["src"]
TOML
cat > "$c_repo/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BTheory;
val _ = new_theory "C";
val c_thm = store_thm("c_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
c_rev=$(init_git_repo "$c_repo")

clone_at() {
  git clone -q "$1" "$2"
}

# The reference: the chain built from git checkouts.
new_cache git
clone_at "$c_repo" "$tmpdir/git-c"
build_chain "$tmpdir/git-c" git git-build built built built
keys "$tmpdir/git-c" git "$tmpdir/git.keys"

# Publish each package from its own checkout.
new_cache pub
for p in A B C; do
  clone_at "$tmpdir/repos/$p" "$tmpdir/pub-$p"
  hb "$tmpdir/pub-$p" pub export --build -o "$tmpdir/$p.hbx" "${p}Theory" > "$tmpdir/export-$p.log" 2>&1 \
    || { cat "$tmpdir/export-$p.log" >&2; exit 1; }
  hb "$tmpdir/pub-$p" pub export --sources-only -o "$tmpdir/$p-src.hbx" > "$tmpdir/export-src-$p.log" 2>&1 \
    || { cat "$tmpdir/export-src-$p.log" >&2; exit 1; }
done

# Source-only and package-cut capsules carry the same snapshot.
for p in A B C; do
  extract_snapshot "$tmpdir/$p.hbx" "$tmpdir/cut/$p"
  extract_snapshot "$tmpdir/$p-src.hbx" "$tmpdir/src/$p"
  diff -r "$tmpdir/cut/$p" "$tmpdir/src/$p" > /dev/null || {
    echo "package-cut and sources-only capsules of $p hold different snapshots" >&2
    exit 1
  }
done
[[ ! -e $tmpdir/src/A/src/gen.txt ]] || { echo "a generator output is in A's snapshot" >&2; exit 1; }

# Cold build from the snapshots alone: no cache entries, and the generator and
# the declared extra inputs work from the snapshot.
override_deps "$tmpdir/src/C" "$tmpdir/src"
new_cache snap
build_chain "$tmpdir/src/C" snap snap-build built built built
require_no_clone "$tmpdir/src/C"
require_file "$tmpdir/src/A/src/gen.txt"

# The snapshot builds under the git checkout's action keys.
keys "$tmpdir/src/C" snap "$tmpdir/snap.keys"
cmp "$tmpdir/git.keys" "$tmpdir/snap.keys" || {
  echo "snapshot and git checkout have different action keys:" >&2
  diff "$tmpdir/git.keys" "$tmpdir/snap.keys" >&2
  exit 1
}

# Entries made from git restore the snapshot build, and entries made from the
# snapshot restore a git build.
extract_snapshot "$tmpdir/C-src.hbx" "$tmpdir/cross/C"
for p in A B; do extract_snapshot "$tmpdir/$p-src.hbx" "$tmpdir/cross/$p"; done
override_deps "$tmpdir/cross/C" "$tmpdir/cross"
R="restored from cache"
build_chain "$tmpdir/cross/C" git snap-from-git "$R" "$R" "$R"
require_no_clone "$tmpdir/cross/C"
clone_at "$c_repo" "$tmpdir/git-c2"
build_chain "$tmpdir/git-c2" snap git-from-snap "$R" "$R" "$R"

# A capsule whose cache part holds entries under keys this chain does not
# compute (here: the cache part of another revision of A under A's snapshot).
# Import works, and the chain build rebuilds from the snapshots.
clone_at "$a_repo" "$tmpdir/pub-A2"
printf '(* another revision *)\n' >> "$tmpdir/pub-A2/src/AScript.sml"
git -C "$tmpdir/pub-A2" -c user.email=test@example.invalid -c user.name=test commit -q -a -m other
hb "$tmpdir/pub-A2" pub export --build -o "$tmpdir/A2.hbx" ATheory > "$tmpdir/export-A2.log" 2>&1 \
  || { cat "$tmpdir/export-A2.log" >&2; exit 1; }
python3 - "$tmpdir/A.hbx" "$tmpdir/A2.hbx" "$tmpdir/A-foreign.hbx" <<'PY'
import sys
import tarfile

package, cache, out = sys.argv[1:]
with tarfile.open(out, "w") as dst:
    for path, prefix in ((package, "holbuild-package"), (cache, "holbuild-cache")):
        with tarfile.open(path) as src:
            for member in src:
                if member.name.split("/")[0] == prefix:
                    dst.addfile(member, src.extractfile(member) if member.isreg() else None)
PY
new_cache foreign
hb "$tmpdir/pub-A2" foreign import "$tmpdir/A-foreign.hbx" > "$tmpdir/import-foreign.log" 2>&1 \
  || { cat "$tmpdir/import-foreign.log" >&2; exit 1; }
require_grep "imported 1 cache action" "$tmpdir/import-foreign.log"
extract_snapshot "$tmpdir/A-foreign.hbx" "$tmpdir/foreign/A"
for p in B C; do extract_snapshot "$tmpdir/$p-src.hbx" "$tmpdir/foreign/$p"; done
override_deps "$tmpdir/foreign/C" "$tmpdir/foreign"
build_chain "$tmpdir/foreign/C" foreign foreign-build built built built
require_no_clone "$tmpdir/foreign/C"

# B's capsule has no cache entries: A and C come from the cache, B builds.
new_cache nob
for capsule in A.hbx C.hbx B-src.hbx; do
  hb "$tmpdir/pub-A" nob import "$tmpdir/$capsule" > "$tmpdir/import-$capsule.log" 2>&1 \
    || { cat "$tmpdir/import-$capsule.log" >&2; exit 1; }
done
for p in A B C; do extract_snapshot "$tmpdir/$p-src.hbx" "$tmpdir/nob-snaps/$p"; done
override_deps "$tmpdir/nob-snaps/C" "$tmpdir/nob-snaps"
build_chain "$tmpdir/nob-snaps/C" nob nob-build "$R" built "$R"
require_no_clone "$tmpdir/nob-snaps/C"

# A script that reads a file nothing declares passes in the git checkout and
# fails from the snapshot, which holds only declared files.  The action stage
# hides undeclared files, but a path out of the stage
# (.holbuild/stage/KEY/src to the package root) still reaches the checkout.
u_repo=$tmpdir/repos/U
mkdir -p "$u_repo"/{src,data}
cat > "$u_repo/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "pkg_u"

[build]
members = ["src"]
TOML
printf 'undeclared\n' > "$u_repo/data/undeclared.txt"
cat > "$u_repo/src/UScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "U";
val contents = let val s = TextIO.openIn "../../../../data/undeclared.txt" in TextIO.inputAll s before TextIO.closeIn s end
val u_thm = store_thm("u_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
init_git_repo "$u_repo" > /dev/null
new_cache u
clone_at "$u_repo" "$tmpdir/git-u"
hb "$tmpdir/git-u" u build UTheory > "$tmpdir/git-u.log" 2>&1 || { cat "$tmpdir/git-u.log" >&2; exit 1; }
require_grep "UTheory built" "$tmpdir/git-u.log"
hb "$tmpdir/git-u" u export --sources-only -o "$tmpdir/U-src.hbx" > /dev/null 2>&1
extract_snapshot "$tmpdir/U-src.hbx" "$tmpdir/snap-u"
require_no_file "$tmpdir/snap-u/data/undeclared.txt"
new_cache u-snap
expect_failure snap-u "UTheory" hb "$tmpdir/snap-u" u-snap build UTheory
require_grep "ENOENT.*undeclared.txt" "$tmpdir/snap-u.log"

# The key comparison is not vacuous: a changed declared input changes the keys.
printf 'two\n' > "$tmpdir/cross/B/data/b.txt"
keys "$tmpdir/cross/C" git "$tmpdir/changed.keys"
if cmp -s "$tmpdir/git.keys" "$tmpdir/changed.keys"; then
  echo "editing a declared extra input of B did not change the action keys" >&2
  exit 1
fi
