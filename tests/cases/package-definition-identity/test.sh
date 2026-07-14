#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src"
printf 'val a = true;\n' > "$project/src/A.sml"
printf 'val b = true;\n' > "$project/src/B.sml"

write_manifest() {
  local version=$1 roots=$2 cache=$3 order=$4
  if [[ $order == project-first ]]; then
    cat > "$project/holproject.toml" <<TOML
# Formatting and table order are not semantic.
[project]
version = "$version"
name = "identity"

[holbuild]
minimum_version = "0.10.0"
schema = 2

[build]
members = ["src"]
roots = [$roots]

[actions.A]
cache = $cache

[dependencies.hol]
rev = "$(holbuild_pinned_hol_rev)"
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
TOML
  else
    cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[actions.A]
cache = $cache

[build]
roots = [$roots]
members = ["src"]

[project]
name = "identity"
version = "$version"
TOML
  fi
}

ids() {
  (cd "$project" && "$HOLBUILD_BIN" context) |
    grep -E '^(package-definition|metadata|source-definition|entrypoint-definition|dependency-definition|runtime-definition|generator-definition|action-dependency-policy|action-input-policy|action-execution-policy)-id:'
}

write_manifest 1.0.0 '"src/A.sml"' true project-first
(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/first.context"
require_grep "package-origin: identity root" "$tmpdir/first.context"
require_grep "package-origin: hol implicit-hol:standard" "$tmpdir/first.context"
require_grep "package-retrieval: hol toolchain-cache" "$tmpdir/first.context"
ids > "$tmpdir/first.ids"
(cd "$project" && HOLBUILD_TEST_SOURCE_INVENTORY="$tmpdir/first.inventory" \
  HOLBUILD_TEST_PACKAGE_COMPONENTS="$tmpdir/first.components" \
  HOLBUILD_TEST_RESOLVED_GRAPH="$tmpdir/first.graph" \
  "$HOLBUILD_BIN" build --dry-run A) > "$tmpdir/first.plan"
project_copy=$tmpdir/project-copy
cp -a "$project" "$project_copy"
(cd "$project_copy" && HOLBUILD_TEST_SOURCE_INVENTORY="$tmpdir/copy.inventory" \
  HOLBUILD_TEST_PACKAGE_COMPONENTS="$tmpdir/copy.components" \
  HOLBUILD_TEST_RESOLVED_GRAPH="$tmpdir/copy.graph" \
  "$HOLBUILD_BIN" build --dry-run A) > "$tmpdir/copy.plan"
cmp "$tmpdir/first.inventory" "$tmpdir/copy.inventory"
cmp "$tmpdir/first.components" "$tmpdir/copy.components"
cmp "$tmpdir/first.graph" "$tmpdir/copy.graph"

write_manifest 1.0.0 '"src/A.sml"' true reordered
ids > "$tmpdir/reordered.ids"
cmp "$tmpdir/first.ids" "$tmpdir/reordered.ids"

write_manifest 2.0.0 '"src/A.sml"' true project-first
ids > "$tmpdir/version.ids"
[[ $(grep '^source-definition-id:' "$tmpdir/first.ids") == $(grep '^source-definition-id:' "$tmpdir/version.ids") ]]
[[ $(grep '^metadata-id:' "$tmpdir/first.ids") != $(grep '^metadata-id:' "$tmpdir/version.ids") ]]
[[ $(grep '^package-definition-id:' "$tmpdir/first.ids") != $(grep '^package-definition-id:' "$tmpdir/version.ids") ]]

write_manifest 1.0.0 '"src/B.sml"' false project-first
ids > "$tmpdir/policy.ids"
[[ $(grep '^source-definition-id:' "$tmpdir/first.ids") == $(grep '^source-definition-id:' "$tmpdir/policy.ids") ]]
[[ $(grep '^entrypoint-definition-id:' "$tmpdir/first.ids") != $(grep '^entrypoint-definition-id:' "$tmpdir/policy.ids") ]]
[[ $(grep '^action-dependency-policy-id:' "$tmpdir/first.ids") == $(grep '^action-dependency-policy-id:' "$tmpdir/policy.ids") ]]
[[ $(grep '^action-input-policy-id:' "$tmpdir/first.ids") == $(grep '^action-input-policy-id:' "$tmpdir/policy.ids") ]]
[[ $(grep '^action-execution-policy-id:' "$tmpdir/first.ids") != $(grep '^action-execution-policy-id:' "$tmpdir/policy.ids") ]]
