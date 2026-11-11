#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

# One package with every kind of declared file, and files nothing declares.
base=$tmpdir/base
mkdir -p "$base"/{src/globdata,data/dir/sub,data/dir/.holbuild,gen,shims,notes,.git}
cat > "$base/holproject.toml" <<TOML
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[dependencies.dep]
git = "https://example.invalid/dep"
rev = "0123456789abcdef0123456789abcdef01234567"

[dependencies.keccak]
from = "dep"
path = "sub"
manifest = "shims/keccak.toml"

[project]
name = "snap"

[build]
members = ["src"]
exclude_globs = ["*/Selftest.sml"]

[actions.ATheory]
extra_inputs = ["data/manifest-input.txt", "gendata", "gendata/out.txt"]

[[generate]]
name = "gen"
command = ["true"]
inputs = ["gen/input.txt"]
outputs = ["src/Generated.sml", "data/dir/gen.out", "gendata/out.txt"]

[[generate]]
name = "chained"
command = ["true"]
inputs = ["./data/dir/gen.out"]
outputs = ["gendata/chained.txt"]
TOML
cat > "$base/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val () = holbuild_extra_deps ["../data/dir"];
val () = holbuild_extra_deps ["globdata/*.txt"];
val _ = new_theory "A";
val _ = export_theory();
SML
printf 'structure B = struct end\n' > "$base/src/B.sml"
printf 'structure Selftest = struct end\n' > "$base/src/Selftest.sml"
printf 'x\n' > "$base/data/manifest-input.txt"
printf 'x\n' > "$base/data/dir/a.txt"
printf 'x\n' > "$base/data/dir/sub/b.txt"
printf 'x\n' > "$base/data/dir/.holbuild/state"
printf 'x\n' > "$base/gen/input.txt"
printf 'x\n' > "$base/src/globdata/g1.txt"
printf 'x\n' > "$base/src/globdata/g2.txt"
printf 'x\n' > "$base/src/globdata/skipped.dat"
printf 'x\n' > "$base/shims/keccak.toml"
printf 'x\n' > "$base/README.md"
printf 'x\n' > "$base/data/undeclared.txt"
printf 'x\n' > "$base/notes/other.txt"
printf 'x\n' > "$base/.git/config"

cat > "$tmpdir/expected" <<'LIST'
data/dir/a.txt
data/dir/sub/b.txt
data/manifest-input.txt
gen/input.txt
holproject.toml
shims/keccak.toml
src/AScript.sml
src/B.sml
src/globdata/g1.txt
src/globdata/g2.txt
LIST

# The same package elsewhere, with a local configuration that excludes a
# source, and after its generator ran.
cp -a "$base" "$tmpdir/copy"
cp -a "$base" "$tmpdir/configured"
cat > "$tmpdir/configured/.holconfig.toml" <<'TOML'
[build]
exclude = ["src/B.sml"]
TOML
cp -a "$base" "$tmpdir/built"
mkdir -p "$tmpdir/built/gendata"
printf 'val () = holbuild_extra_deps ["../notes/other.txt"];\n' > "$tmpdir/built/src/Generated.sml"
printf 'x\n' > "$tmpdir/built/data/dir/gen.out"
ln -s ../README.md "$tmpdir/built/gendata/out.txt"
printf 'x\n' > "$tmpdir/built/gendata/chained.txt"

# Links the glob walk passes but its matches do not contain.
cp -a "$base" "$tmpdir/glob-links"
ln -s ../data "$tmpdir/glob-links/src/linkdir"
ln -s nowhere "$tmpdir/glob-links/src/dangling"

# Errors: a symlink in an expanded directory, a symlinked declared file, a
# dangling one, and a declaration outside the package.
cp -a "$base" "$tmpdir/link-in-dir"
ln -s ../manifest-input.txt "$tmpdir/link-in-dir/data/dir/link.txt"
cp -a "$base" "$tmpdir/link-declared"
rm "$tmpdir/link-declared/data/manifest-input.txt"
ln -s ../README.md "$tmpdir/link-declared/data/manifest-input.txt"
cp -a "$base" "$tmpdir/link-dangling"
rm "$tmpdir/link-dangling/gen/input.txt"
ln -s nowhere "$tmpdir/link-dangling/gen/input.txt"
cp -a "$base" "$tmpdir/outside"
printf 'val () = holbuild_extra_deps ["../../escape.txt"];\n' >> "$tmpdir/outside/src/B.sml"
cp -a "$base" "$tmpdir/missing"
rm "$tmpdir/missing/data/manifest-input.txt"

for name in base copy configured built glob-links link-in-dir link-declared link-dangling outside missing; do
  printf '%s %s\n' "$name" "$tmpdir/$name"
done > "$tmpdir/projects"

cat > "$tmpdir/snapshot-test.sml" <<'SML'
fun env name =
  case OS.Process.getEnv name of
      SOME value => value
    | NONE => raise Fail (name ^ " not set");
val _ = OS.FileSys.chDir (env "HOLBUILD_ROOT");
use "sml/holbuild-script.sml";

fun lines path =
  let
    val input = TextIO.openIn path
    fun loop acc =
      case TextIO.inputLine input of
          NONE => rev acc before TextIO.closeIn input
        | SOME line => loop (String.substring(line, 0, size line - 1) :: acc)
  in loop [] end;

fun report line =
  case String.tokens (fn c => c = #" ") line of
      [name, dir] =>
        let
          val package =
            HolbuildProject.project_package (HolbuildProject.parse (dir ^ "/holproject.toml"))
        in
          print ("== " ^ name ^ "\n");
          List.app (fn rel => print (rel ^ "\n")) (HolbuildPackageSnapshot.files package)
          handle HolbuildPackageSnapshot.Error msg => print ("error: " ^ msg ^ "\n")
        end
    | _ => raise Fail line;
val _ = List.app report (lines (env "SNAPSHOT_PROJECTS"));
val _ = print "== done\n";
SML

SNAPSHOT_PROJECTS="$tmpdir/projects" "${HOLBUILD_POLY:-poly}" < "$tmpdir/snapshot-test.sml" > "$tmpdir/snapshot.log" 2>&1 || {
  cat "$tmpdir/snapshot.log" >&2
  exit 1
}
require_grep "^== done$" "$tmpdir/snapshot.log"

section() {
  awk -v name="$1" '/^== /{on = ($2 == name); next} on' "$tmpdir/snapshot.log"
}

# The declared files, and nothing else, wherever the package is checked out,
# whatever the local configuration says and whether or not generators ran.
for name in base copy configured built glob-links; do
  section "$name" > "$tmpdir/$name.list"
  if ! diff -u "$tmpdir/expected" "$tmpdir/$name.list"; then
    echo "snapshot of $name differs from the declared files" >&2
    exit 1
  fi
done

expect_error() {
  section "$1" > "$tmpdir/$1.list"
  require_grep "^error: $2\$" "$tmpdir/$1.list"
}
expect_error link-in-dir 'symlink in package snapshot: data/dir/link.txt'
expect_error link-declared 'symlink in package snapshot: data/manifest-input.txt'
expect_error link-dangling 'symlink in package snapshot: gen/input.txt'
expect_error outside 'snapshot path is outside the package root: .*/escape.txt'
expect_error missing 'extra dependency not found: data/manifest-input.txt'
