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
mkdir -p "$project/src/a" "$project/src/b"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "exclude"

[build]
members = ["src"]
exclude = ["*/selftest.sml", "src/generated/*"]
TOML
cat > "$project/src/a/selftest.sml" <<'SML'
val x = 1;
SML
cat > "$project/src/b/selftest.sml" <<'SML'
val x = 2;
SML
mkdir -p "$project/src/generated"
cat > "$project/src/generated/Generated.sml" <<'SML'
val generated = 1;
SML
cat > "$project/src/Keep.sml" <<'SML'
val keep = 1;
SML
mkdir -p "$project/src/local"
cat > "$project/src/local/MachineOnly.sml" <<'SML'
val machine_only = 1;
SML
cat > "$project/.holconfig.toml" <<'TOML'
[build]
exclude = ["src/local/*"]
TOML

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log"
require_grep "exclude: \*/selftest.sml, src/generated/\*, src/local/\*" "$tmpdir/context.log"
(cd "$project" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/dry.log"
require_grep "Keep (sml, package exclude)" "$tmpdir/dry.log"
if grep -q "selftest\|Generated\|MachineOnly" "$tmpdir/dry.log"; then
  echo "excluded source appeared in dry-run plan" >&2
  exit 1
fi
