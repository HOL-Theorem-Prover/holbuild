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

project=$tmpdir/project
mkdir -p "$project/src/nested"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "ignore-subprojects"

[build]
members = ["src"]
TOML
cat > "$project/src/Keep.sml" <<'SML'
val keep = 1;
SML
cat > "$project/src/nested/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "nested"

[build]
members = ["."]
TOML
cat > "$project/src/nested/Nested.sml" <<'SML'
val nested = 1;
SML

(cd "$project" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/dry.log"
require_grep "Keep (sml, package ignore-subprojects)" "$tmpdir/dry.log"
if grep -q "Nested" "$tmpdir/dry.log"; then
  echo "source from nested subproject appeared in dry-run plan" >&2
  exit 1
fi

explicit=$tmpdir/explicit
mkdir -p "$explicit/src/nested"
cp "$project/src/nested/holproject.toml" "$explicit/src/nested/holproject.toml"
cp "$project/src/nested/Nested.sml" "$explicit/src/nested/Nested.sml"
cat > "$explicit/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "explicit-subproject-member"

[build]
members = ["src/nested"]
TOML

(cd "$explicit" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/explicit-dry.log"
require_grep "Nested (sml, package explicit-subproject-member)" "$tmpdir/explicit-dry.log"
