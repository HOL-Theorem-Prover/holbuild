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

make_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<'TOML'
[project]
name = "concurrent"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
}

run_parallel_builds() {
  local phase=$1
  shift
  local -a pids=()
  local -a logs=()
  local project
  for project in "$@"; do
    local name
    name=$(basename "$project")
    local log="$tmpdir/$phase-$name.log"
    logs+=("$log")
    (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$log" 2>&1 &
    pids+=("$!")
  done

  local failed=0
  local i
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      failed=1
      cat "${logs[$i]}" >&2
    fi
  done
  if [[ "$failed" -ne 0 ]]; then
    echo "parallel $phase builds failed" >&2
    exit 1
  fi
}

projects=()
for i in 1 2 3 4; do
  project="$tmpdir/project-$i"
  make_project "$project"
  projects+=("$project")
done

run_parallel_builds publish "${projects[@]}"

manifest_count=$(find "$HOLBUILD_CACHE/actions" -mindepth 2 -maxdepth 2 -name manifest | wc -l | tr -d ' ')
[[ "$manifest_count" -ge "1" ]] || { echo "expected at least one cache manifest" >&2; exit 1; }
if [[ -d "$HOLBUILD_CACHE/locks" ]] && find "$HOLBUILD_CACHE/locks" -mindepth 1 -maxdepth 1 -name 'action-*.lock' | grep -q .; then
  echo "stale action cache lock left behind" >&2
  exit 1
fi

for project in "${projects[@]}"; do
  require_file "$project/.holbuild/obj/src/ATheory.dat"
  rm -rf "$project/.holbuild"
done

run_parallel_builds restore "${projects[@]}"

for project in "${projects[@]}"; do
  name=$(basename "$project")
  require_grep "ATheory restored from cache" "$tmpdir/restore-$name.log"
  require_file "$project/.holbuild/obj/src/ATheory.dat"
done

rm -rf "${projects[0]}/.holbuild"
trace_restore_log=$tmpdir/trace-restore.log
(cd "${projects[0]}" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$trace_restore_log" 2>&1
require_grep "ATheory restored from cache" "$trace_restore_log"
a_cache_key=$(require_cache_hit_key ATheory "$trace_restore_log")

parent_sensitive_source=$tmpdir/parent-sensitive-source
parent_sensitive_a1=$tmpdir/parent-sensitive-a1
parent_sensitive_a2=$tmpdir/parent-sensitive-a2
mkdir -p "$parent_sensitive_source/src" "$parent_sensitive_a1" "$parent_sensitive_a2"
cat > "$parent_sensitive_source/holproject.toml" <<'TOML'
[project]
name = "parentsensitive"

[build]
members = ["src"]
TOML
cat > "$parent_sensitive_source/src/AScript.sml" <<'SML'
Theory A
Ancestors arithmetic

Theorem add_one:
  1 + 1 = 2
Proof
  simp[]
QED

val _ = export_theory();
SML
cat > "$parent_sensitive_source/src/BScript.sml" <<'SML'
Theory B
Ancestors A

val _ = export_theory();
SML

(cd "$parent_sensitive_a1" && "$HOLBUILD_BIN" --source-dir "$parent_sensitive_source" --holdir "$HOLDIR" build BTheory) > "$tmpdir/parent-sensitive-a1.log" 2>&1
(cd "$parent_sensitive_a2" && "$HOLBUILD_BIN" --source-dir "$parent_sensitive_source" --holdir "$HOLDIR" build BTheory) > "$tmpdir/parent-sensitive-a2.log" 2>&1
if grep -q "cache entry already exists with different outputs" "$tmpdir/parent-sensitive-a2.log"; then
  cat "$tmpdir/parent-sensitive-a2.log" >&2
  echo "cache key ignored local parent theory output hash" >&2
  exit 1
fi
require_file "$parent_sensitive_a1/.holbuild/obj/src/BTheory.dat"
require_file "$parent_sensitive_a2/.holbuild/obj/src/BTheory.dat"

manifest="$HOLBUILD_CACHE/actions/$a_cache_key/manifest"
require_file "$manifest"
sig_hash=$(awk '/^blob sig / { print $3 }' "$manifest")
dat_hash=$(awk '/^blob dat / { print $3 }' "$manifest")
python3 - <<PY
from pathlib import Path
path = Path("$manifest")
text = path.read_text()
path.write_text(text.replace("blob sig $sig_hash", "blob sig $dat_hash"))
PY

conflict_log="$tmpdir/cache-conflict.log"
(cd "${projects[0]}" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force ATheory) > "$conflict_log" 2>&1
require_grep "cache entry already exists with different outputs for ATheory" "$conflict_log"
require_grep "existing cache entry: .*manifest" "$conflict_log"
require_grep "existing outputs: sig=$dat_hash" "$conflict_log"
require_grep "new outputs: sig=$sig_hash" "$conflict_log"
