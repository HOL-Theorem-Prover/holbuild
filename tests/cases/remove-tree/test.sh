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
val _ = HolbuildBuildExec.remove_tree (join (tmp, "stage dir $HOME 'q'"));
val _ = HolbuildBuildExec.remove_trees [join (tmp, "other;tree"), join (tmp, "dangling"),
                                        join (tmp, "missing")];
val _ = print "remove_tree done\n";
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
