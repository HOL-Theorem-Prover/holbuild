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

project=$tmpdir/project
cache=$tmpdir/cache
mkdir -p \
  "$project/.holbuild/stage/old-stage" \
  "$project/.holbuild/logs" \
  "$project/.holbuild/checkpoints/pkg/src/theory.deps/key" \
  "$cache/tmp/old" \
  "$cache/actions/old" \
  "$cache/blobs"

cat > "$project/holproject.toml" <<'TOML'
[project]
name = "gc"

[build]
members = []
TOML

printf 'stage residue\n' > "$project/.holbuild/stage/old-stage/file"
printf 'old log\n' > "$project/.holbuild/logs/old.log"
printf 'checkpoint\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save"
printf 'ok\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save.ok"
printf 'meta\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save.meta"
printf 'prefix\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save.prefix"
printf 'tmp\n' > "$cache/tmp/old/file"
printf 'holbuild-cache-action-v2\nblob dat deadbeef\n' > "$cache/actions/old/manifest"
printf 'blob\n' > "$cache/blobs/deadbeef"

gc_log=$tmpdir/gc.log
(cd "$project" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$cache" \
  "$HOLBUILD_BIN" gc --retention-days 0 --cache-dir "$cache") > "$gc_log" 2>&1

require_grep "project clean: removed" "$gc_log"
require_grep "checkpoint_gb_initial=" "$gc_log"
require_grep "checkpoint_gb_before=" "$gc_log"
require_grep "checkpoint_gb_after=" "$gc_log"
require_grep "checkpoint_max_gb=" "$gc_log"
require_grep "cache gc: removed" "$gc_log"
[[ ! -e "$project/.holbuild/stage/old-stage" ]] || { echo "gc left stale stage dir" >&2; exit 1; }
[[ ! -e "$project/.holbuild/logs/old.log" ]] || { echo "gc left stale log" >&2; exit 1; }
if find "$project/.holbuild/checkpoints" -type f -print -quit 2>/dev/null | grep -q .; then
  echo "gc left stale checkpoint artifacts" >&2
  exit 1
fi
[[ ! -e "$cache/tmp/old" ]] || { echo "gc left stale cache tmp" >&2; exit 1; }
[[ ! -e "$cache/actions/old" ]] || { echo "gc left stale cache action" >&2; exit 1; }
[[ ! -e "$cache/blobs/deadbeef" ]] || { echo "gc left stale cache blob" >&2; exit 1; }


clean_only_project=$tmpdir/clean-only-project
clean_only_cache=$tmpdir/clean-only-cache
mkdir -p "$clean_only_project/.holbuild/stage/old" "$clean_only_cache/tmp/old"
cat > "$clean_only_project/holproject.toml" <<'TOML'
[project]
name = "gc-clean-only"

[build]
members = []
TOML
printf 'stage residue\n' > "$clean_only_project/.holbuild/stage/old/file"
printf 'cache residue\n' > "$clean_only_cache/tmp/old/file"
(cd "$clean_only_project" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$clean_only_cache" \
  "$HOLBUILD_BIN" gc --clean-only --retention-days 0 --cache-dir "$clean_only_cache") > "$tmpdir/clean-only.log" 2>&1
require_grep "project clean: removed" "$tmpdir/clean-only.log"
require_grep "checkpoint_gb_before=" "$tmpdir/clean-only.log"
if grep -q "cache gc:" "$tmpdir/clean-only.log"; then
  echo "--clean-only ran cache gc" >&2
  exit 1
fi
[[ ! -e "$clean_only_project/.holbuild/stage/old" ]] || { echo "--clean-only left project stage" >&2; exit 1; }
[[ -e "$clean_only_cache/tmp/old" ]] || { echo "--clean-only removed cache state" >&2; exit 1; }

budget_project=$tmpdir/budget-project
budget_family="$budget_project/.holbuild/checkpoints/checkpoint-budget/src/BadScript.sml"
mkdir -p \
  "$budget_project/src" \
  "$budget_family.deps/old-deps-key" \
  "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix"
cat > "$budget_project/holproject.toml" <<'TOML'
[project]
name = "checkpoint-budget"

[build]
members = ["src"]
TOML
cat > "$budget_project/src/BadScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Bad";
val _ = raise Fail "forced failure after stale checkpoint budget fixture";
SML
truncate -s 6G "$budget_family.deps/old-deps-key/deps_loaded.save"
printf 'ok\n' > "$budget_family.deps/old-deps-key/deps_loaded.save.ok"
printf 'child\n' > "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix/first_context.save"
printf 'child ok\n' > "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix/first_context.save.ok"
touch -d '2 days ago' \
  "$budget_family.deps/old-deps-key/deps_loaded.save" \
  "$budget_family.deps/old-deps-key/deps_loaded.save.ok" \
  "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix/first_context.save" \
  "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix/first_context.save.ok"
if (cd "$budget_project" && "$HOLBUILD_BIN" --holdir "$_HOLDIR" build BadTheory) > "$tmpdir/budget.log" 2>&1; then
  echo "checkpoint budget failure fixture unexpectedly succeeded" >&2
  exit 1
fi
require_grep "checkpoint budget: .*evicted=" "$tmpdir/budget.log"
require_grep "checkpoint_gb_before=" "$tmpdir/budget.log"
require_grep "checkpoint_gb_after=" "$tmpdir/budget.log"
require_grep "checkpoint_limit_gb=5" "$tmpdir/budget.log"
if [[ -e "$budget_family.deps/old-deps-key" || -e "$budget_family.theorems/old-deps-key" ]]; then
  echo "checkpoint budget evicted stale parent/child heap family only partially" >&2
  exit 1
fi

if (cd "$project" && "$HOLBUILD_BIN" gc --clean-only --cache-only) > "$tmpdir/bad-flags.log" 2>&1; then
  echo "gc accepted mutually exclusive flags" >&2
  exit 1
fi
require_grep "mutually exclusive" "$tmpdir/bad-flags.log"
