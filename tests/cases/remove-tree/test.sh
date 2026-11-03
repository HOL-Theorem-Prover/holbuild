#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { chmod -R u+w "$tmpdir" 2>/dev/null || true; rm -rf "$tmpdir"; }
trap cleanup EXIT

# Names a shell would split or expand are removed as given.
tree="$tmpdir/stage dir \$HOME 'q'"
other="$tmpdir/other;tree"
outside=$tmpdir/outside
mkdir -p "$tree/a/b" "$other" "$outside"
printf 'x\n' > "$tree/a/b/file"
printf 'y\n' > "$other/file"
printf 'keep\n' > "$outside/kept"
ln -s "$outside" "$tree/link-to-outside"
ln -s "$tmpdir/missing" "$tmpdir/dangling"
# The strict variant fails when something is left behind; a read-only
# directory keeps its entries, but root ignores directory permissions.
mkdir -p "$tmpdir/strict/a" "$tmpdir/stuck/ro" "$tmpdir/empty"
printf 'z\n' > "$tmpdir/strict/a/file"
printf 'z\n' > "$tmpdir/stuck/ro/file"
chmod a-w "$tmpdir/stuck/ro"
if [[ $EUID -ne 0 ]]; then expect_stuck=true; else expect_stuck=false; fi

cat > "$tmpdir/remove-tree-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val tmp =
  case OS.Process.getEnv "REMOVE_TREE_TEST_TMP" of
      SOME path => path
    | NONE => raise Fail "REMOVE_TREE_TEST_TMP not set";
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun join (a, b) = OS.Path.concat (a, b)
val _ = HolbuildRemoveTree.remove (join (tmp, "stage dir $HOME 'q'"));
val _ = List.app HolbuildRemoveTree.remove [join (tmp, "other;tree"), join (tmp, "dangling"),
                                            join (tmp, "missing")];
val _ = print "remove_tree done\n";
fun report f path =
  (f path; print ("removed " ^ path ^ "\n"))
  handle HolbuildRemoveTree.Error msg => print ("error: " ^ msg ^ "\n");
(* Live guard calls run from an empty directory, so a broken guard costs
   nothing; "/" is only checked through the predicate. *)
val _ = OS.FileSys.chDir (join (tmp, "empty"));
val _ = List.app (report HolbuildRemoveTree.remove) ["", "."];
val _ = if HolbuildRemoveTree.unsafe "/" then print "unsafe: /\n" else ();
val _ = report HolbuildRemoveTree.remove_strict (join (tmp, "strict"));
val _ = report HolbuildRemoveTree.remove_strict (join (tmp, "missing"));
val _ = report HolbuildRemoveTree.remove_strict (join (tmp, "stuck"));
SML

REMOVE_TREE_TEST_TMP="$tmpdir" "${HOLBUILD_POLY:-poly}" < "$tmpdir/remove-tree-test.sml" > "$tmpdir/remove-tree-test.log" 2>&1 || {
  cat "$tmpdir/remove-tree-test.log" >&2
  exit 1
}
require_grep "remove_tree done" "$tmpdir/remove-tree-test.log"
require_no_file "$tree"
require_no_file "$other"
[[ ! -L "$tmpdir/dangling" ]] || { echo "dangling link was not removed" >&2; exit 1; }
# A link inside the tree is removed without following it.
require_file "$outside/kept"
require_grep "error: refusing to remove unsafe path: $" "$tmpdir/remove-tree-test.log"
require_grep "error: refusing to remove unsafe path: \.$" "$tmpdir/remove-tree-test.log"
require_grep "^unsafe: /$" "$tmpdir/remove-tree-test.log"
require_grep "removed $tmpdir/strict$" "$tmpdir/remove-tree-test.log"
require_no_file "$tmpdir/strict"
require_grep "removed $tmpdir/missing$" "$tmpdir/remove-tree-test.log"
if $expect_stuck; then
  require_grep "error: failed to remove path: $tmpdir/stuck$" "$tmpdir/remove-tree-test.log"
  require_file "$tmpdir/stuck/ro/file"
else
  require_grep "removed $tmpdir/stuck$" "$tmpdir/remove-tree-test.log"
fi
