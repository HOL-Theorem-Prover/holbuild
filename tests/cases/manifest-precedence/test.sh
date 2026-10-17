#!/usr/bin/env bash
# holbuild.toml takes precedence over holproject.toml in the same directory,
# for the root project, dependencies, and nested-project boundaries.
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

write_holbuild_manifest() {
  local file=$1 name=$2
  {
    write_schema2_prelude
    cat <<TOML
[project]
name = "$name"

[build]
members = ["src"]
TOML
  } > "$file"
}

# The manifest shape Holmake reads from the same filename; holbuild's schema
# rejects every key in it.
write_holmake_manifest() {
  local file=$1 name=$2
  cat > "$file" <<TOML
name = "$name"
holpath = "$name"
exclude = ["developers"]
external_includes = ["\$(HOLDIR)/examples"]
TOML
}

write_source() {
  local dir=$1 name=$2
  mkdir -p "$dir/src"
  cat > "$dir/src/$name.sml" <<SML
val $name = 1;
SML
}

expect_context_failure() {
  local dir=$1
  local pattern=$2
  local log=$3
  if (cd "$dir" && "$HOLBUILD_BIN" context) > "$log" 2>&1; then
    echo "context unexpectedly succeeded in $dir" >&2
    exit 1
  fi
  require_grep "$pattern" "$log"
}

# Only holbuild.toml.
only=$tmpdir/only-holbuild
write_source "$only" Only
write_holbuild_manifest "$only/holbuild.toml" only_holbuild
(cd "$only" && "$HOLBUILD_BIN" context) > "$tmpdir/only.log"
require_grep "^manifest: $only/holbuild.toml$" "$tmpdir/only.log"
require_grep "^name: only_holbuild$" "$tmpdir/only.log"

# Neither file: the error names both.
none=$tmpdir/none
mkdir -p "$none"
expect_context_failure "$none" "no holbuild.toml or holproject.toml found" "$tmpdir/none.log"

# Both present: holbuild.toml wins over a Holmake-schema holproject.toml.
both=$tmpdir/both
write_source "$both" Both
write_holbuild_manifest "$both/holbuild.toml" both_holbuild
write_holmake_manifest "$both/holproject.toml" both_holmake
(cd "$both" && "$HOLBUILD_BIN" context) > "$tmpdir/both.log"
require_grep "^manifest: $both/holbuild.toml$" "$tmpdir/both.log"
require_grep "^name: both_holbuild$" "$tmpdir/both.log"
if grep -q "both_holmake" "$tmpdir/both.log"; then
  echo "holproject.toml content leaked into context output" >&2
  exit 1
fi

# Both present, invalid holbuild.toml: an error naming holbuild.toml, no
# fallback to the valid holproject.toml.
invalid=$tmpdir/invalid-holbuild
write_source "$invalid" Invalid
write_holbuild_manifest "$invalid/holproject.toml" invalid_fallback
{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "invalid_holbuild"

[build]
members = ["src"]

[mystery]
value = "nope"
TOML
} > "$invalid/holbuild.toml"
expect_context_failure "$invalid" "$invalid/holbuild.toml: unknown field in manifest: mystery" "$tmpdir/invalid.log"
if grep -q "invalid_fallback" "$tmpdir/invalid.log"; then
  echo "invalid holbuild.toml fell back to holproject.toml" >&2
  exit 1
fi

# An unreadable holbuild.toml is still the selected manifest: a loud error, no
# fallback to the valid holproject.toml beside it. Root ignores file modes.
if [[ $(id -u) -ne 0 ]]; then
  unreadable=$tmpdir/unreadable-holbuild
  write_source "$unreadable" Unreadable
  write_holbuild_manifest "$unreadable/holproject.toml" unreadable_fallback
  write_holbuild_manifest "$unreadable/holbuild.toml" unreadable_holbuild
  chmod 000 "$unreadable/holbuild.toml"
  expect_context_failure "$unreadable" "$unreadable/holbuild.toml: cannot read manifest" "$tmpdir/unreadable.log"
  chmod 600 "$unreadable/holbuild.toml"
  if grep -q "unreadable_fallback" "$tmpdir/unreadable.log"; then
    echo "unreadable holbuild.toml fell back to holproject.toml" >&2
    exit 1
  fi
fi

# Discovery from a subdirectory picks the nearest manifest: a nearer
# holproject.toml beats an ancestor's holbuild.toml.
outer=$tmpdir/outer
write_source "$outer" Outer
write_holbuild_manifest "$outer/holbuild.toml" outer_project
inner=$outer/inner
write_source "$inner" Inner
write_holbuild_manifest "$inner/holproject.toml" inner_project
mkdir -p "$inner/src/deep" "$outer/src/deep"
(cd "$inner/src/deep" && "$HOLBUILD_BIN" context) > "$tmpdir/inner.log"
require_grep "^manifest: $inner/holproject.toml$" "$tmpdir/inner.log"
require_grep "^name: inner_project$" "$tmpdir/inner.log"
(cd "$outer/src/deep" && "$HOLBUILD_BIN" context) > "$tmpdir/outer.log"
require_grep "^manifest: $outer/holbuild.toml$" "$tmpdir/outer.log"
require_grep "^name: outer_project$" "$tmpdir/outer.log"

# A nested directory with only holbuild.toml is a project boundary, excluded
# from the parent's automatic source discovery.
parent=$tmpdir/parent
write_source "$parent" Keep
cat > "$parent/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "parent"

[build]
members = ["src"]
TOML
nested=$parent/src/nested
mkdir -p "$nested"
cat > "$nested/holbuild.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "nested"

[build]
members = ["."]
TOML
cat > "$nested/Nested.sml" <<'SML'
val nested = 1;
SML
(cd "$parent" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/dry.log"
require_grep "Keep (sml, package parent)" "$tmpdir/dry.log"
if grep -q "Nested" "$tmpdir/dry.log"; then
  echo "source from nested holbuild.toml project appeared in dry-run plan" >&2
  exit 1
fi

# Dependencies: the same preference for a local-override directory and for a
# materialized git dependency.
hol=$tmpdir/hol
mkdir -p "$hol"
git -C "$hol" init -q
git_identity "$hol"
echo upstream-hol > "$hol/README"
hol_rev=$(commit_repo "$hol")
export HOLBUILD_CANONICAL_HOL_GIT="$hol"

write_dependency_manifest() {
  local file=$1 name=$2
  cat > "$file" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "$name"

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"

[build]
members = ["src"]
TOML
}

write_dependency_dir() {
  local dir=$1 name=$2
  write_source "$dir" "$name"
  write_dependency_manifest "$dir/holbuild.toml" "$name"
  write_holmake_manifest "$dir/holproject.toml" "${name}_holmake"
}

write_override_project() {
  local dir=$1 name=$2 dep=$3 override=$4
  mkdir -p "$dir"
  cat > "$dir/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "$name"

[dependencies.$dep]
git = "https://example.invalid/$dep.git"
rev = "1111111111111111111111111111111111111111"
TOML
  cat > "$dir/.holconfig.toml" <<TOML
[overrides.$dep]
path = "$override"
TOML
}

leaf=$tmpdir/leaf
write_dependency_dir "$leaf" leaf

override_project=$tmpdir/override-project
write_override_project "$override_project" override_project leaf "$leaf"
(cd "$override_project" && "$HOLBUILD_BIN" context) > "$tmpdir/override.log"
require_grep "resolved-manifest=$leaf/holbuild.toml" "$tmpdir/override.log"
require_grep "package: leaf \[root=$leaf, manifest=$leaf/holbuild.toml," "$tmpdir/override.log"

# An invalid dependency holbuild.toml is an error naming it, not a fallback to
# the valid holproject.toml beside it.
bad_leaf=$tmpdir/bad-leaf
write_source "$bad_leaf" bad_leaf
write_dependency_manifest "$bad_leaf/holproject.toml" bad_leaf
write_dependency_manifest "$bad_leaf/holbuild.toml" bad_leaf
printf '\n[mystery]\nvalue = "nope"\n' >> "$bad_leaf/holbuild.toml"
bad_project=$tmpdir/bad-project
write_override_project "$bad_project" bad_project bad_leaf "$bad_leaf"
expect_context_failure "$bad_project" "$bad_leaf/holbuild.toml: unknown field in manifest: mystery" "$tmpdir/bad.log"
if grep -q "package: bad_leaf" "$tmpdir/bad.log"; then
  echo "invalid dependency holbuild.toml fell back to holproject.toml" >&2
  exit 1
fi

# A dependency directory with neither file: the error names both.
missing_leaf=$tmpdir/missing-leaf
mkdir -p "$missing_leaf"
missing_project=$tmpdir/missing-project
write_override_project "$missing_project" missing_project missing_leaf "$missing_leaf"
expect_context_failure "$missing_project" "dependency missing_leaf manifest not found: no holbuild.toml or holproject.toml in $missing_leaf" "$tmpdir/missing.log"

# A materialized git dependency, and an explicit shim manifest that stays
# authoritative although the shim's directory has a holbuild.toml.
git_leaf=$tmpdir/git-leaf
mkdir -p "$git_leaf"
git -C "$git_leaf" init -q
git_identity "$git_leaf"
write_dependency_dir "$git_leaf" git_leaf
write_source "$git_leaf/subdir" Sub
write_dependency_manifest "$git_leaf/subdir/holbuild.toml" sub_holbuild
git_leaf_rev=$(commit_repo "$git_leaf")

git_project=$tmpdir/git-project
mkdir -p "$git_project"
write_dependency_manifest "$git_project/sub.manifest.toml" sub
cat > "$git_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "git_project"

[dependencies.git_leaf]
git = "$git_leaf"
rev = "$git_leaf_rev"

[dependencies.sub]
from = "git_leaf"
path = "subdir"
manifest = "sub.manifest.toml"
TOML
(cd "$git_project" && "$HOLBUILD_BIN" context) > "$tmpdir/git.log"
materialized=$git_project/.holbuild/src/git_leaf
require_file "$materialized/holbuild.toml"
require_file "$materialized/holproject.toml"
require_grep "resolved-manifest=$materialized/holbuild.toml" "$tmpdir/git.log"
require_grep "package: git_leaf \[root=$materialized, manifest=$materialized/holbuild.toml," "$tmpdir/git.log"
require_file "$materialized/subdir/holbuild.toml"
require_grep "resolved-manifest=$git_project/sub.manifest.toml" "$tmpdir/git.log"
require_grep "package: sub \[root=$materialized/subdir, manifest=$git_project/sub.manifest.toml," "$tmpdir/git.log"
