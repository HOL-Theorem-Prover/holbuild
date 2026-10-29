#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

git_identity() {
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name 'Holbuild Test'
  git -C "$1" config commit.gpgsign false
}

commit_repo() {
  git -C "$1" add .
  git -C "$1" commit -q -m initial
  git -C "$1" rev-parse HEAD
}

make_project_dir() {
  local dir=$1 name=$2 extra=${3:-}
  mkdir -p "$dir/src"
  cat > "$dir/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "$name"
$extra

[build]
members = ["src"]
TOML
  cat > "$dir/src/${name}.sml" <<SML
structure ${name} = struct
  val value = true
end
SML
}

hol=$tmpdir/hol
mkdir -p "$hol"
git -C "$hol" init -q
git_identity "$hol"
echo upstream-hol-without-holproject > "$hol/README"
hol_rev=$(commit_repo "$hol")
export HOLBUILD_CANONICAL_HOL_GIT="$hol"

leaf=$tmpdir/leaf
make_project_dir "$leaf" leaf "
[dependencies.hol]
git = \"$hol\"
rev = \"$hol_rev\"
"

project=$tmpdir/direct-project
mkdir -p "$project"
cat > "$project/holproject.toml" <<'TOML'
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "direct_project"

[dependencies.leaf]
git = "https://example.invalid/leaf.git"
rev = "1111111111111111111111111111111111111111"
TOML
cat > "$project/.holconfig.toml" <<'TOML'
[overrides.leaf]
path = "$LEAF_OVERRIDE"
TOML

direct_log=$tmpdir/direct.log
(cd "$project" && LEAF_OVERRIDE="$leaf" "$HOLBUILD_BIN" context) > "$direct_log"
require_grep "override=$leaf" "$direct_log"
require_grep "local=$leaf" "$direct_log"
require_grep "resolved-manifest=$leaf/holproject.toml" "$direct_log"
require_grep "package: leaf \[root=$leaf" "$direct_log"
require_grep "package-snapshot: leaf .*git-v1" "$direct_log"
require_grep "package-retrieval: leaf trusted-path:$leaf" "$direct_log"
if [ -e "$project/.holbuild/src/leaf" ]; then
  echo "overridden direct dependency was materialized into .holbuild/src" >&2
  exit 1
fi

git_leaf=$tmpdir/git-leaf
mkdir -p "$git_leaf"
git -C "$git_leaf" init -q
git_identity "$git_leaf"
make_project_dir "$git_leaf" git_leaf "
[dependencies.hol]
git = \"$hol\"
rev = \"$hol_rev\"
"
git_leaf_rev=$(commit_repo "$git_leaf")

git_project=$tmpdir/git-project
mkdir -p "$git_project"
cat > "$git_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "git_project"

[dependencies.git_leaf]
git = "https://example.invalid/git-leaf.git"
rev = "$git_leaf_rev"
TOML
cat > "$git_project/.holconfig.toml" <<'TOML'
[overrides.git_leaf]
git = "$GIT_LEAF_OVERRIDE"
TOML

git_log=$tmpdir/git.log
(cd "$git_project" && GIT_LEAF_OVERRIDE="../git-leaf" "$HOLBUILD_BIN" context) > "$git_log"
require_grep "override-git=$git_leaf" "$git_log"
require_grep "local=$git_project/.holbuild/src/git_leaf" "$git_log"
require_grep "package: git_leaf \[root=$git_project/.holbuild/src/git_leaf" "$git_log"
[ "$(git -C "$git_project/.holbuild/src/git_leaf" rev-parse HEAD)" = "$git_leaf_rev" ]

transitive=$tmpdir/transitive
make_project_dir "$transitive" transitive "
[dependencies.hol]
git = \"$hol\"
rev = \"$hol_rev\"
"

mid=$tmpdir/mid-repo
mkdir -p "$mid"
git -C "$mid" init -q
git_identity "$mid"
make_project_dir "$mid" mid "
[dependencies.transitive]
git = \"https://example.invalid/transitive.git\"
rev = \"2222222222222222222222222222222222222222\"
"
mid_rev=$(commit_repo "$mid")

recursive_project=$tmpdir/recursive-project
mkdir -p "$recursive_project"
cat > "$recursive_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "recursive_project"

[dependencies.mid]
git = "$mid"
rev = "$mid_rev"
TOML
cat > "$recursive_project/.holconfig.toml" <<TOML
[overrides.transitive]
path = "../transitive"
TOML

recursive_log=$tmpdir/recursive.log
(cd "$recursive_project" && "$HOLBUILD_BIN" context) > "$recursive_log"
require_grep "package: mid \[root=$recursive_project/.holbuild/src/mid" "$recursive_log"
require_grep "package: transitive \[root=$transitive" "$recursive_log"
require_grep "override: transitive path -> $transitive" "$recursive_log"
if [ -e "$recursive_project/.holbuild/src/transitive" ]; then
  echo "overridden transitive dependency was materialized into .holbuild/src" >&2
  exit 1
fi

transitive_git=$tmpdir/transitive-git
mkdir -p "$transitive_git"
git -C "$transitive_git" init -q
git_identity "$transitive_git"
make_project_dir "$transitive_git" transitive_git "
[dependencies.hol]
git = \"$hol\"
rev = \"$hol_rev\"
"
transitive_git_rev=$(commit_repo "$transitive_git")

mid_git=$tmpdir/mid-git-repo
mkdir -p "$mid_git"
git -C "$mid_git" init -q
git_identity "$mid_git"
make_project_dir "$mid_git" mid_git "
[dependencies.transitive_git]
git = \"https://example.invalid/transitive-git.git\"
rev = \"$transitive_git_rev\"
"
mid_git_rev=$(commit_repo "$mid_git")

recursive_git_project=$tmpdir/recursive-git-project
mkdir -p "$recursive_git_project"
cat > "$recursive_git_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "recursive_git_project"

[dependencies.mid_git]
git = "$mid_git"
rev = "$mid_git_rev"
TOML
cat > "$recursive_git_project/.holconfig.toml" <<'TOML'
[overrides.transitive_git]
git = "$TRANSITIVE_GIT_OVERRIDE"
TOML

recursive_git_log=$tmpdir/recursive-git.log
(cd "$recursive_git_project" && TRANSITIVE_GIT_OVERRIDE="../transitive-git" "$HOLBUILD_BIN" context) > "$recursive_git_log"
require_grep "package: mid_git \[root=$recursive_git_project/.holbuild/src/mid_git" "$recursive_git_log"
require_grep "package: transitive_git \[root=$recursive_git_project/.holbuild/src/transitive_git" "$recursive_git_log"
require_grep "override: transitive_git git -> $transitive_git" "$recursive_git_log"
[ "$(git -C "$recursive_git_project/.holbuild/src/transitive_git" rev-parse HEAD)" = "$transitive_git_rev" ]

# A from/path/manifest shim lives inside its from dependency's checkout, so
# overriding the from dependency must move the shim's package root with it.
shim_foo=$tmpdir/shim-foo
mkdir -p "$shim_foo/sub/lib"
cat > "$shim_foo/holproject.toml" <<'TOML'
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "foo"

[build]
members = ["."]
exclude = ["sub"]
TOML
cat > "$shim_foo/sub/lib/shimLibScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "shimLib";
val shim_thm = store_thm("shim_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
git -C "$shim_foo" init -q
git_identity "$shim_foo"
shim_foo_rev=$(commit_repo "$shim_foo")

shim_project=$tmpdir/shim-project
mkdir -p "$shim_project/shims"
cat > "$shim_project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "shim_consumer"

[build]
members = ["."]
roots = ["useShimScript.sml"]

[dependencies.foo]
git = "https://example.invalid/foo.git"
rev = "$shim_foo_rev"

[dependencies.keccak]
from = "foo"
path = "sub/lib"
manifest = "shims/keccak.toml"
TOML
cat > "$shim_project/shims/keccak.toml" <<'TOML'
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "keccak"

[build]
members = ["."]
TOML
cat > "$shim_project/useShimScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open shimLibTheory;
val _ = new_theory "useShim";
val use_thm = store_thm("use_thm", ``T``, ACCEPT_TAC shimLibTheory.shim_thm);
val _ = export_theory();
SML
cat > "$shim_project/.holconfig.toml" <<'TOML'
[overrides.foo]
path = "../shim-foo"
TOML

shim_log=$tmpdir/shim.log
(cd "$shim_project" && env -u HOLBUILD_CANONICAL_HOL_GIT "$HOLBUILD_BIN" context) > "$shim_log"
require_grep "package-source-root: keccak $shim_foo\$" "$shim_log"
require_grep "package-root: keccak $shim_foo/sub/lib\$" "$shim_log"
require_grep "dependency: keccak \[from=foo, path=sub/lib, manifest=shims/keccak.toml, local=$shim_foo/sub/lib," "$shim_log"

rm -rf "$shim_project/.holbuild"
(cd "$shim_project" && env -u HOLBUILD_CANONICAL_HOL_GIT "$HOLBUILD_BIN" build) > "$tmpdir/shim-build.log" 2>&1 ||
  { cat "$tmpdir/shim-build.log" >&2; exit 1; }
if [ -e "$shim_project/.holbuild/src/foo" ]; then
  echo "overridden from dependency was materialized into .holbuild/src" >&2
  exit 1
fi
