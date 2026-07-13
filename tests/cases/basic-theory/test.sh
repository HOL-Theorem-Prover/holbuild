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
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "basic"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);

val _ = export_theory();
SML
cat > "$project/src/ATheory.sml" <<'SML'
this source-tree generated theory artifact must be ignored by discovery
SML
cat > "$project/src/ATheory.sig" <<'SML'
this source-tree generated theory artifact must be ignored by discovery
SML

first_log=$tmpdir/first.log
first_timing=$tmpdir/first.tool-timing
(cd "$project" && \
  HOLBUILD_TIMING_LOG="$first_timing" HOLBUILD_TIMING_DETAIL=fine HOLBUILD_CHECKPOINT_TIMING=1 HOLBUILD_SHARE_COMMON_DATA=0 HOLBUILD_ECHO_CHILD_LOGS=1 \
  "$HOLBUILD_BIN" --maxheap 4096 build ATheory) > "$first_log" 2>&1
require_grep "holbuild checkpoint kind=deps_loaded share=false" "$first_log"
require_grep "holbuild checkpoint kind=final_context share=false" "$first_log"
require_grep $'^phase\tname=build\.keys\tstatus=ok\tms=' "$first_timing"
require_grep $'^phase\tname=build\.keys\.external\.source_hash\tstatus=ok\tms=.*\tcount=' "$first_timing"
require_grep $'^phase\tname=build\.keys\.external\.dep_cache\tstatus=ok\tms=.*\tcount=' "$first_timing"
require_grep $'^phase\tname=build\.keys\.external\.theory_stamp\tstatus=ok\tms=.*\tcount=' "$first_timing"
require_grep $'^phase\tname=build\.keys\.external\.lib_artifact\tstatus=ok\tms=.*\tcount=' "$first_timing"
require_grep $'^phase\tname=build\.exec\.node\.analyse_boundaries\tstatus=ok\tms=' "$first_timing"
require_grep $'^phase\tname=build\.exec\.node\.analyse_terminations\tstatus=ok\tms=' "$first_timing"
require_grep $'^phase\tname=build\.exec\.node\.child_run\tstatus=ok\tms=' "$first_timing"
require_grep $'^phase\tname=build\.exec\.checkpoint_budget\tstatus=ok\tms=' "$first_timing"
require_grep $'^phase\tname=build\.exec\.publish_cache\tstatus=ok\tms=' "$first_timing"
require_file "$project/.holbuild/logs/current/basic/ATheory/build.log"

coarse_timing=$tmpdir/coarse.tool-timing
(cd "$project" && HOLBUILD_TIMING_LOG="$coarse_timing" "$HOLBUILD_BIN" build --dry-run ATheory) > /dev/null
if grep -q 'build\.keys\.external' "$coarse_timing"; then
  echo "fine-grained external timing should require HOLBUILD_TIMING_DETAIL=fine" >&2
  exit 1
fi
if grep -q 'build\.exec\.node\|build\.exec\.checkpoint_budget\|build\.exec\.publish_cache' "$coarse_timing"; then
  echo "fine-grained execution timing should require HOLBUILD_TIMING_DETAIL=fine" >&2
  exit 1
fi

require_file "$project/.holbuild/obj/src/ATheory.sig"
require_file "$project/.holbuild/obj/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
for ext in sig sml dat; do
  if ! cmp -s "$project/.holbuild/obj/src/ATheory.$ext" "$project/.holbuild/obj/src/.hol/objs/ATheory.$ext"; then
    echo "remapped ATheory.$ext does not match canonical output" >&2
    exit 1
  fi
done
if strings -a "$project/.holbuild/obj/src/ATheory.dat" | grep -q '\.holbuild.*stage'; then
  echo "theory dat should not record transient holbuild stage paths" >&2
  exit 1
fi
require_file "$project/.holbuild/dep/basic/src/AScript.sml.key"
metadata="$project/.holbuild/dep/basic/src/AScript.sml.key"
if grep -q "^output-sha1=" "$metadata"; then
  echo "default build metadata should not emit output-sha1 diagnostics" >&2
  exit 1
fi
if ! find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "successful build should retain checkpoint files for incremental rebuilds" >&2
  exit 1
fi
if grep -q "deps_loaded=\|final_context=\|theorem_boundary" "$metadata"; then
  echo "metadata should not retain checkpoint paths" >&2
  exit 1
fi

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build ATheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"

source_dir_context_log=$tmpdir/source-dir-context.log
(cd "$tmpdir" && "$HOLBUILD_BIN" --source-dir "$project" context) > "$source_dir_context_log"
require_grep "root: $project" "$source_dir_context_log"
require_grep "artifact-root: $tmpdir" "$source_dir_context_log"

source_dir_env_log=$tmpdir/source-dir-env.log
rm -rf "$tmpdir/.holbuild"
(cd "$tmpdir" && HOLBUILD_CACHE_TRACE=1 HOLBUILD_SOURCE_DIR="$project" "$HOLBUILD_BIN" build ATheory) > "$source_dir_env_log"
require_grep "cache hit: ATheory source/dependency key=" "$source_dir_env_log"
require_grep "ATheory restored from cache" "$source_dir_env_log"
require_file "$tmpdir/.holbuild/obj/src/ATheory.dat"
if strings -a "$tmpdir/.holbuild/obj/src/ATheory.dat" | grep -q '\.holbuild.*stage'; then
  echo "cache-restored theory dat should not contain transient holbuild stage paths" >&2
  exit 1
fi

: > "$project/.holbuild/obj/src/ATheory.sml"
: > "$project/.holbuild/obj/src/ATheory.sig"
zero_output_log=$tmpdir/zero-output.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$zero_output_log"
if grep -q "ATheory is up to date" "$zero_output_log"; then
  echo "zero-byte theory outputs were treated as up to date" >&2
  exit 1
fi
if [[ ! -s "$project/.holbuild/obj/src/ATheory.sml" || ! -s "$project/.holbuild/obj/src/ATheory.sig" ]]; then
  echo "zero-byte theory outputs were not repaired" >&2
  exit 1
fi

if grep -q "^output-sha1=" "$metadata"; then
  echo "default repaired metadata should not emit output-sha1 diagnostics" >&2
  exit 1
fi

emit_hash_log=$tmpdir/emit-output-hashes.log
(cd "$project" && "$HOLBUILD_BIN" build --force --emit-output-hashes ATheory) > "$emit_hash_log"
require_grep "ATheory built" "$emit_hash_log"
hash_line_count=$(grep -c "^output-sha1=" "$metadata")
if [[ "$hash_line_count" -ne 12 ]]; then
  echo "expected 12 output-sha1 diagnostic lines, found $hash_line_count" >&2
  exit 1
fi
while IFS= read -r line; do
  payload=${line#output-sha1=}
  path=${payload% *}
  hash=${payload##* }
  actual=$(sha1sum "$path" | awk '{print $1}')
  if [[ "$hash" != "$actual" ]]; then
    echo "stale output-sha1 diagnostic for $path" >&2
    exit 1
  fi
done < <(grep "^output-sha1=" "$metadata")
for ext in sig sml dat; do
  if ! cmp -s "$project/.holbuild/obj/src/ATheory.$ext" "$project/.holbuild/obj/src/.hol/objs/ATheory.$ext"; then
    echo "remapped ATheory.$ext does not match canonical output after diagnostic build" >&2
    exit 1
  fi
done
sed -i 's/^output-sha1=.*/output-sha1=stale-diagnostic-hash/' "$metadata"
stale_hash_log=$tmpdir/stale-output-hash.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build --emit-output-hashes ATheory) > "$stale_hash_log"
require_grep "ATheory is up to date" "$stale_hash_log"
if grep -q 'output-sha1=stale-diagnostic-hash' "$metadata"; then
  echo "up-to-date --emit-output-hashes did not refresh output diagnostics" >&2
  exit 1
fi
while IFS= read -r line; do
  payload=${line#output-sha1=}
  path=${payload% *}
  hash=${payload##* }
  actual=$(sha1sum "$path" | awk '{print $1}')
  if [[ "$hash" != "$actual" ]]; then
    echo "up-to-date --emit-output-hashes wrote a stale output diagnostic for $path" >&2
    exit 1
  fi
done < <(grep "^output-sha1=" "$metadata")

# A remapped artifact is a distinct file.  Its diagnostic hash must describe
# its own bytes even if it has been corrupted independently of the canonical
# artifact.
remapped_sml=$project/.holbuild/obj/src/.hol/objs/ATheory.sml
printf 'corrupted remapped artifact\n' > "$remapped_sml"
(cd "$project" && "$HOLBUILD_BIN" --verbose build --emit-output-hashes ATheory) > "$tmpdir/corrupt-remap-hash.log"
expected_remapped_hash=$(sha1sum "$remapped_sml" | awk '{print $1}')
reported_remapped_hash=$(awk -v prefix="output-sha1=$remapped_sml " 'index($0, prefix) == 1 { print $NF }' "$metadata")
if [[ "$reported_remapped_hash" != "$expected_remapped_hash" ]]; then
  echo "output diagnostic did not hash the remapped artifact itself" >&2
  exit 1
fi

input_key=$(grep '^input_key=' "$project/.holbuild/dep/basic/src/AScript.sml.key" | cut -d= -f2)
cache_manifest="$HOLBUILD_CACHE/actions/$input_key/manifest"
require_file "$cache_manifest"
touch -d '10 days ago' "$cache_manifest"
cache_hit_marker=$tmpdir/cache-hit-marker
touch -d '1 minute ago' "$cache_hit_marker"

rm -rf "$project/.holbuild"
cache_log=$tmpdir/cache-restore.log
(cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build ATheory) > "$cache_log"
require_grep "cache hit: ATheory source/dependency key=$input_key" "$cache_log"
require_grep "ATheory restored from cache" "$cache_log"
require_file "$project/.holbuild/obj/src/ATheory.sig"
require_file "$project/.holbuild/obj/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
for ext in sig sml dat; do
  if ! cmp -s "$project/.holbuild/obj/src/ATheory.$ext" "$project/.holbuild/obj/src/.hol/objs/ATheory.$ext"; then
    echo "cache-restored remapped ATheory.$ext does not match canonical output" >&2
    exit 1
  fi
done
if grep -q "^output-sha1=" "$metadata"; then
  echo "default cache-restore metadata should not emit output-sha1 diagnostics" >&2
  exit 1
fi
# cache restore does not create checkpoints (no HOL process runs),
# but previously-saved checkpoints persist for incremental rebuilds
if [[ ! "$cache_manifest" -nt "$cache_hit_marker" ]]; then
  echo "cache hit did not refresh action manifest retention time" >&2
  exit 1
fi
require_file "$cache_manifest"
printf 'mldep /stale/.holbuild/stage/%s/ATheory\n' "$input_key" >> "$cache_manifest"
rm -rf "$project/.holbuild"
stale_cache_log=$tmpdir/stale-cache-manifest.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$stale_cache_log" 2>&1
if grep -q "ATheory restored from cache" "$stale_cache_log"; then
  echo "cache manifest with transient stage mldep was restored" >&2
  exit 1
fi
require_grep "cache entry unusable for ATheory" "$stale_cache_log"
require_grep "deleted cache manifest" "$stale_cache_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"
if [[ -e "$cache_manifest" ]] && grep -q "\.holbuild/stage" "$cache_manifest"; then
  echo "transient stage mldep survived cache manifest republish" >&2
  exit 1
fi

cp "$project/src/AScript.sml" "$tmpdir/AScript.good.sml"
cat >> "$project/src/AScript.sml" <<'SML'
val _ = raise Fail "forced source failure after cache miss";
SML
bad_key=$(cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory | awk '/input_key:/ {print $2; exit}')
bad_manifest="$HOLBUILD_CACHE/actions/$bad_key/manifest"
mkdir -p "$(dirname "$bad_manifest")"
cat > "$bad_manifest" <<EOF
holbuild-cache-action-v2
input_key=$bad_key
kind=theory
mldeps
mldep /stale/.holbuild/stage/$bad_key/ATheory
blob sig 0000000000000000000000000000000000000000
blob sml 0000000000000000000000000000000000000000
blob dat 0000000000000000000000000000000000000000
EOF
rm -rf "$project/.holbuild"
bad_manifest_log=$tmpdir/stale-cache-manifest-source-fails.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$bad_manifest_log" 2>&1; then
  echo "source failure test unexpectedly succeeded" >&2
  exit 1
fi
require_grep "cache entry unusable for ATheory" "$bad_manifest_log"
require_grep "deleted cache manifest" "$bad_manifest_log"
[[ ! -e "$bad_manifest" ]] || { echo "transient stage mldep manifest survived failed source rebuild" >&2; exit 1; }
cp "$tmpdir/AScript.good.sml" "$project/src/AScript.sml"

rm -rf "$project/.holbuild"
no_cache_log=$tmpdir/no-cache.log
(cd "$project" && "$HOLBUILD_BIN" build --no-cache ATheory) > "$no_cache_log"
if grep -q "ATheory restored from cache" "$no_cache_log"; then
  echo "--no-cache restored from cache" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"

no_cache_publish_project=$tmpdir/no-cache-publish-project
mkdir -p "$no_cache_publish_project/src"
cp "$project/holproject.toml" "$no_cache_publish_project/holproject.toml"
cp "$project/src/AScript.sml" "$no_cache_publish_project/src/AScript.sml"
no_cache_publish_cache=$tmpdir/no-cache-publish-cache
link_hol_toolchain_cache "$no_cache_publish_cache"
no_cache_publish_log=$tmpdir/no-cache-publish.log
(cd "$no_cache_publish_project" && HOLBUILD_CACHE="$no_cache_publish_cache" "$HOLBUILD_BIN" build --no-cache ATheory) > "$no_cache_publish_log"
rm -rf "$no_cache_publish_project/.holbuild"
no_cache_after_log=$tmpdir/no-cache-after.log
(cd "$no_cache_publish_project" && HOLBUILD_CACHE="$no_cache_publish_cache" "$HOLBUILD_BIN" build ATheory) > "$no_cache_after_log"
if grep -q "ATheory restored from cache" "$no_cache_after_log"; then
  echo "--no-cache published to cache" >&2
  exit 1
fi
require_file "$no_cache_publish_project/.holbuild/obj/src/ATheory.dat"

cache_dir_option_project=$tmpdir/cache-dir-option-project
cache_dir_option_cache=$tmpdir/cache-dir-option-cache
cache_dir_option_ignored_cache=$tmpdir/cache-dir-option-ignored-cache
mkdir -p "$cache_dir_option_project/src"
link_hol_toolchain_cache "$cache_dir_option_cache"
cp "$project/holproject.toml" "$cache_dir_option_project/holproject.toml"
cp "$project/src/AScript.sml" "$cache_dir_option_project/src/AScript.sml"
cache_dir_option_log=$tmpdir/cache-dir-option.log
(cd "$cache_dir_option_project" && HOLBUILD_CACHE="$cache_dir_option_ignored_cache" \
  "$HOLBUILD_BIN" build --cache-dir "$cache_dir_option_cache" ATheory) > "$cache_dir_option_log"
if ! find "$cache_dir_option_cache/actions" -mindepth 2 -maxdepth 2 -name manifest -print -quit | grep -q .; then
  echo "--cache-dir build did not publish to selected cache" >&2
  exit 1
fi
if [[ -d "$cache_dir_option_ignored_cache/actions" ]] && find "$cache_dir_option_ignored_cache/actions" -mindepth 2 -maxdepth 2 -name manifest -print -quit | grep -q .; then
  echo "--cache-dir build used HOLBUILD_CACHE instead of selected cache" >&2
  exit 1
fi
require_file "$cache_dir_option_project/.holbuild/obj/src/ATheory.dat"

no_export_project=$tmpdir/no-export-project
mkdir -p "$no_export_project/src"
cp "$project/holproject.toml" "$no_export_project/holproject.toml"
cat > "$no_export_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem no_export_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML
(cd "$no_export_project" && "$HOLBUILD_BIN" build --no-cache ATheory) > "$tmpdir/no-export.log"
require_file "$no_export_project/.holbuild/obj/src/ATheory.sig"
require_file "$no_export_project/.holbuild/obj/src/ATheory.sml"
require_file "$no_export_project/.holbuild/obj/src/ATheory.dat"

child_failure_project=$tmpdir/child-failure-project
mkdir -p "$child_failure_project/src"
cp "$project/holproject.toml" "$child_failure_project/holproject.toml"
cat > "$child_failure_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = print "child failure debug marker\n";
val _ = raise Fail "forced child failure";
SML
child_failure_log=$tmpdir/child-failure.log
if (cd "$child_failure_project" && "$HOLBUILD_BIN" build ATheory) > "$child_failure_log" 2>&1; then
  echo "expected child failure build to fail" >&2
  exit 1
fi
require_grep "end child log tail" "$child_failure_log"
require_grep "child log: .*\.holbuild/logs/current/basic/ATheory/build\.log" "$child_failure_log"
retained_child_log=$(awk '/child log: / { path=$0; sub(/^child log: /, "", path) } END { print path }' "$child_failure_log")
require_file "$retained_child_log"
require_grep "child failure debug marker" "$retained_child_log"

skip_project=$tmpdir/skip-project
mkdir -p "$skip_project/src"
cp "$project/holproject.toml" "$skip_project/holproject.toml"
cp "$project/src/AScript.sml" "$skip_project/src/AScript.sml"
skip_log=$tmpdir/skip.log
(cd "$skip_project" && \
  HOLBUILD_CHECKPOINT_TIMING=1 HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" build --skip-checkpoints ATheory) \
  > "$skip_log" 2>&1
if grep -q "holbuild checkpoint kind=deps_loaded\|holbuild checkpoint kind=final_context" "$skip_log"; then
  echo "--skip-checkpoints created theory checkpoints" >&2
  exit 1
fi
require_file "$skip_project/.holbuild/obj/src/ATheory.sig"
require_file "$skip_project/.holbuild/obj/src/ATheory.sml"
require_file "$skip_project/.holbuild/obj/src/ATheory.dat"
if find "$skip_project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "--skip-checkpoints left checkpoint files" >&2
  exit 1
fi

stage_residue_project=$tmpdir/stage-residue-project
mkdir -p "$stage_residue_project/src"
cp "$project/holproject.toml" "$stage_residue_project/holproject.toml"
cp "$project/src/AScript.sml" "$stage_residue_project/src/AScript.sml"
stage_residue_key=$(cd "$stage_residue_project" && "$HOLBUILD_BIN" build --dry-run ATheory | awk '/input_key:/ {print $2; exit}')
stage_residue_dir="$stage_residue_project/.holbuild/stage/$stage_residue_key"
mkdir -p "$stage_residue_dir"
printf 'poisoned stale stage file\n' > "$stage_residue_dir/ATheory.dat"
printf 'poisoned stale generated source\n' > "$stage_residue_dir/ATheory.sml"
printf 'poisoned stale generated signature\n' > "$stage_residue_dir/ATheory.sig"
(cd "$stage_residue_project" && "$HOLBUILD_BIN" build --skip-proof-steps --no-cache ATheory) > "$tmpdir/stage-residue.log"
require_grep "ATheory built" "$tmpdir/stage-residue.log"
require_file "$stage_residue_project/.holbuild/obj/src/ATheory.dat"
if strings -a "$stage_residue_project/.holbuild/obj/src/ATheory.dat" | grep -q "poisoned stale"; then
  echo "stale stage residue was reused by build" >&2
  exit 1
fi
bad_flags_log=$tmpdir/bad-flags.log
if (cd "$project" && "$HOLBUILD_BIN" build --skip-proof-steps --tactic-timeout 0 ATheory) > "$bad_flags_log" 2>&1; then
  echo "--skip-proof-steps --tactic-timeout should fail" >&2
  exit 1
fi
require_grep "tactic-timeout requires proof steps; remove --skip-proof-steps" "$bad_flags_log"

deprecated_new_ir_log=$tmpdir/deprecated-new-ir.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build --new-ir ATheory) > "$deprecated_new_ir_log" 2>&1
require_grep "new-ir is deprecated and has no effect; proof IR is the default" "$deprecated_new_ir_log"
require_grep "ATheory is up to date" "$deprecated_new_ir_log"

removed_legacy_proof_steps_log=$tmpdir/removed-legacy-proof-steps.log
if (cd "$project" && "$HOLBUILD_BIN" --verbose build --goalfrag ATheory) > "$removed_legacy_proof_steps_log" 2>&1; then
  echo "expected removed legacy proof-step option to fail" >&2
  exit 1
fi
require_grep "goalfrag has been removed; proof steps are enabled by default" "$removed_legacy_proof_steps_log"
