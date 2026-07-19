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
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src/a" "$project/src/b" "$project/deprecated/src/a"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "exclude"

[build]
members = ["src"]
exclude = ["src/generated"]
exclude_globs = ["*/selftest.sml"]
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
exclude = ["src/local"]
TOML

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log"
require_grep "exclude: src/generated, src/local" "$tmpdir/context.log"
require_grep "exclude_globs: \*/selftest.sml" "$tmpdir/context.log"
(cd "$project" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/dry.log"
require_grep "Keep (sml, package exclude)" "$tmpdir/dry.log"
if grep -q "selftest\|Generated\|MachineOnly" "$tmpdir/dry.log"; then
  echo "excluded source appeared in dry-run plan" >&2
  exit 1
fi

cat > "$project/.holconfig.toml" <<'TOML'
[build]
exclude = ["src/local/*"]
TOML
(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/local-glob.log" 2> "$tmpdir/local-glob.err"
require_grep "exclude_globs: \*/selftest.sml, src/local/\*" "$tmpdir/local-glob.log"
local_warning='.holconfig.toml build.exclude glob pattern "src/local/\*" is deprecated; use .holconfig.toml build.exclude_globs instead'
require_grep "$local_warning" "$tmpdir/local-glob.err"
if [[ $(grep -c "$local_warning" "$tmpdir/local-glob.err") -ne 1 ]]; then
  echo "expected one local build.exclude deprecation warning" >&2
  exit 1
fi
(cd "$project" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/local-glob-dry.log" 2>&1
require_grep "Keep (sml, package exclude)" "$tmpdir/local-glob-dry.log"
if grep -q "selftest\|Generated\|MachineOnly" "$tmpdir/local-glob-dry.log"; then
  echo "source excluded by local build.exclude glob appeared in dry-run plan" >&2
  exit 1
fi

cat > "$project/deprecated/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "deprecated-exclude"

[build]
members = ["src"]
exclude = ["src/Skipped.sml", "*/selftest.sml", "src/a/*.sig"]
TOML
cat > "$project/deprecated/src/a/selftest.sml" <<'SML'
val old = 1;
SML
cat > "$project/deprecated/src/a/Ignored.sig" <<'SML'
signature Ignored = sig end;
SML
cat > "$project/deprecated/src/Keep.sml" <<'SML'
val keep = 1;
SML
cat > "$project/deprecated/src/Skipped.sml" <<'SML'
val skipped = 1;
SML
(cd "$project/deprecated" && "$HOLBUILD_BIN" context) > "$tmpdir/deprecated-context.log" 2> "$tmpdir/deprecated-context.err"
require_grep "exclude: src/Skipped.sml" "$tmpdir/deprecated-context.log"
require_grep "exclude_globs: \*/selftest.sml, src/a/\*.sig" "$tmpdir/deprecated-context.log"
manifest_warning='build.exclude glob pattern "\*/selftest.sml" is deprecated; use build.exclude_globs instead'
require_grep "$manifest_warning" "$tmpdir/deprecated-context.err"
if [[ $(grep -c "build.exclude glob pattern" "$tmpdir/deprecated-context.err") -ne 1 ]]; then
  echo "expected one manifest build.exclude deprecation warning" >&2
  exit 1
fi
(cd "$project/deprecated" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/deprecated-dry.log" 2> "$tmpdir/deprecated-dry.err"
require_grep "Keep (sml, package deprecated-exclude)" "$tmpdir/deprecated-dry.log"
if grep -q "selftest\|Ignored\|Skipped" "$tmpdir/deprecated-dry.log"; then
  echo "source excluded by manifest build.exclude appeared in dry-run plan" >&2
  exit 1
fi
