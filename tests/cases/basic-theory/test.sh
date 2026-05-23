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
export HOLBUILD_CACHE="$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
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
  "$HOLBUILD_BIN" --holdir "$HOLDIR" --maxheap 4096 build ATheory) > "$first_log" 2>&1
require_grep "holbuild checkpoint kind=deps_loaded share=false" "$first_log"
require_grep "holbuild checkpoint kind=final_context share=false" "$first_log"
require_grep $'^phase\tname=build\.keys\tstatus=ok\tms=' "$first_timing"

coarse_timing=$tmpdir/coarse.tool-timing
(cd "$project" && HOLBUILD_TIMING_LOG="$coarse_timing" "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run ATheory) > /dev/null
if grep -q 'build\.keys\.external' "$coarse_timing"; then
  echo "fine-grained external timing should require HOLBUILD_TIMING_DETAIL=fine" >&2
  exit 1
fi

require_file "$project/.holbuild/obj/src/ATheory.sig"
require_file "$project/.holbuild/obj/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
if strings -a "$project/.holbuild/obj/src/ATheory.dat" | grep -q '\.holbuild.*stage'; then
  echo "theory dat should not record transient holbuild stage paths" >&2
  exit 1
fi
require_file "$project/.holbuild/dep/basic/src/AScript.sml.key"
if ! find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "successful build should retain checkpoint files for incremental rebuilds" >&2
  exit 1
fi
if grep -q "deps_loaded=\|final_context=\|theorem_boundary" "$project/.holbuild/dep/basic/src/AScript.sml.key"; then
  echo "metadata should not retain checkpoint paths" >&2
  exit 1
fi

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --verbose --holdir "$HOLDIR" build ATheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"

source_dir_context_log=$tmpdir/source-dir-context.log
(cd "$tmpdir" && "$HOLBUILD_BIN" --source-dir "$project" --holdir "$HOLDIR" context) > "$source_dir_context_log"
require_grep "root: $project" "$source_dir_context_log"
require_grep "artifact-root: $tmpdir" "$source_dir_context_log"

source_dir_env_log=$tmpdir/source-dir-env.log
rm -rf "$tmpdir/.holbuild"
(cd "$tmpdir" && HOLBUILD_CACHE_TRACE=1 HOLBUILD_SOURCE_DIR="$project" "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$source_dir_env_log"
source_dir_cache_key=$(require_cache_hit_key ATheory "$source_dir_env_log")
require_file "$HOLBUILD_CACHE/actions/$source_dir_cache_key/manifest"
require_grep "ATheory restored from cache" "$source_dir_env_log"
require_file "$tmpdir/.holbuild/obj/src/ATheory.dat"
if strings -a "$tmpdir/.holbuild/obj/src/ATheory.dat" | grep -q '\.holbuild.*stage'; then
  echo "cache-restored theory dat should not contain transient holbuild stage paths" >&2
  exit 1
fi

: > "$project/.holbuild/obj/src/ATheory.sml"
: > "$project/.holbuild/obj/src/ATheory.sig"
zero_output_log=$tmpdir/zero-output.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$zero_output_log"
if grep -q "ATheory is up to date" "$zero_output_log"; then
  echo "zero-byte theory outputs were treated as up to date" >&2
  exit 1
fi
if [[ ! -s "$project/.holbuild/obj/src/ATheory.sml" || ! -s "$project/.holbuild/obj/src/ATheory.sig" ]]; then
  echo "zero-byte theory outputs were not repaired" >&2
  exit 1
fi

metadata="$project/.holbuild/dep/basic/src/AScript.sml.key"
require_grep "^output-sha1=" "$metadata"
sed -i 's/^output-sha1=.*/output-sha1=stale-diagnostic-hash/' "$metadata"
stale_hash_log=$tmpdir/stale-output-hash.log
(cd "$project" && "$HOLBUILD_BIN" --verbose --holdir "$HOLDIR" build ATheory) > "$stale_hash_log"
require_grep "ATheory is up to date" "$stale_hash_log"

rm -rf "$project/.holbuild"
cache_log=$tmpdir/cache-restore.log
(cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$cache_log"
cache_key=$(require_cache_hit_key ATheory "$cache_log")
cache_manifest="$HOLBUILD_CACHE/actions/$cache_key/manifest"
require_file "$cache_manifest"
touch -d '10 days ago' "$cache_manifest"
cache_hit_marker=$tmpdir/cache-hit-marker
touch -d '1 minute ago' "$cache_hit_marker"

rm -rf "$project/.holbuild"
cache_log=$tmpdir/cache-restore-after-touch.log
(cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$cache_log"
require_grep "cache hit: ATheory .* key=$cache_key" "$cache_log"
require_grep "ATheory restored from cache" "$cache_log"
require_file "$project/.holbuild/obj/src/ATheory.sig"
require_file "$project/.holbuild/obj/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
# cache restore does not create checkpoints (no HOL process runs),
# but previously-saved checkpoints persist for incremental rebuilds
if [[ ! "$cache_manifest" -nt "$cache_hit_marker" ]]; then
  echo "cache hit did not refresh action manifest retention time" >&2
  exit 1
fi
require_file "$cache_manifest"
printf 'mldep /stale/.holbuild/stage/%s/ATheory\n' "$cache_key" >> "$cache_manifest"
rm -rf "$project/.holbuild"
stale_cache_log=$tmpdir/stale-cache-manifest.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$stale_cache_log" 2>&1
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
old_holbuild_cache=$HOLBUILD_CACHE
export HOLBUILD_CACHE="$tmpdir/bad-cache"
probe_log=$tmpdir/stale-cache-key-probe.log
if (cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$probe_log" 2>&1; then
  echo "source failure key probe unexpectedly succeeded" >&2
  exit 1
fi
bad_key=$(awk '/cache miss: ATheory (source\/dependency|parent-output|path-dependent parent-output) key=.*\(no manifest\)/ {sub(/^.* key=/, ""); sub(/ .*/, ""); print; exit}' "$probe_log")
[[ -n "$bad_key" ]] || { echo "could not determine ATheory cache key" >&2; cat "$probe_log" >&2; exit 1; }
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
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$bad_manifest_log" 2>&1; then
  echo "source failure test unexpectedly succeeded" >&2
  exit 1
fi
require_grep "cache entry unusable for ATheory" "$bad_manifest_log"
require_grep "deleted cache manifest" "$bad_manifest_log"
[[ ! -e "$bad_manifest" ]] || { echo "transient stage mldep manifest survived failed source rebuild" >&2; exit 1; }
export HOLBUILD_CACHE=$old_holbuild_cache
cp "$tmpdir/AScript.good.sml" "$project/src/AScript.sml"

rm -rf "$project/.holbuild"
no_cache_log=$tmpdir/no-cache.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --no-cache ATheory) > "$no_cache_log"
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
no_cache_publish_log=$tmpdir/no-cache-publish.log
(cd "$no_cache_publish_project" && HOLBUILD_CACHE="$no_cache_publish_cache" "$HOLBUILD_BIN" --holdir "$HOLDIR" build --no-cache ATheory) > "$no_cache_publish_log"
rm -rf "$no_cache_publish_project/.holbuild"
no_cache_after_log=$tmpdir/no-cache-after.log
(cd "$no_cache_publish_project" && HOLBUILD_CACHE="$no_cache_publish_cache" "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$no_cache_after_log"
if grep -q "ATheory restored from cache" "$no_cache_after_log"; then
  echo "--no-cache published to cache" >&2
  exit 1
fi
require_file "$no_cache_publish_project/.holbuild/obj/src/ATheory.dat"

skip_project=$tmpdir/skip-project
mkdir -p "$skip_project/src"
cp "$project/holproject.toml" "$skip_project/holproject.toml"
cp "$project/src/AScript.sml" "$skip_project/src/AScript.sml"
skip_log=$tmpdir/skip.log
(cd "$skip_project" && \
  HOLBUILD_CHECKPOINT_TIMING=1 HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-checkpoints ATheory) \
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

bad_flags_log=$tmpdir/bad-flags.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-goalfrag --tactic-timeout 0 ATheory) > "$bad_flags_log" 2>&1; then
  echo "--skip-goalfrag --tactic-timeout should fail" >&2
  exit 1
fi
require_grep "requires theorem instrumentation" "$bad_flags_log"

deprecated_new_ir_log=$tmpdir/deprecated-new-ir.log
(cd "$project" && "$HOLBUILD_BIN" --verbose --holdir "$HOLDIR" build --new-ir ATheory) > "$deprecated_new_ir_log" 2>&1
require_grep "new-ir is deprecated and has no effect; proof IR is the default" "$deprecated_new_ir_log"
require_grep "ATheory is up to date" "$deprecated_new_ir_log"

deprecated_goalfrag_log=$tmpdir/deprecated-goalfrag.log
(cd "$project" && "$HOLBUILD_BIN" --verbose --holdir "$HOLDIR" build --goalfrag ATheory) > "$deprecated_goalfrag_log" 2>&1
require_grep "goalfrag is deprecated; proof IR is the default" "$deprecated_goalfrag_log"
require_grep "ATheory is up to date" "$deprecated_goalfrag_log"
