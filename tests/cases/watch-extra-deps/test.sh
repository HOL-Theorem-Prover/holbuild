#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../lib.sh"

HOLBUILD_BIN=$1
WATCH_HOLBUILD_BIN=${REAL_HOLBUILD_BIN:-$HOLBUILD_BIN}

tmpdir=$(make_temp_dir)
watch_pid=""

cleanup() {
  if [[ -n "$watch_pid" ]] && kill -0 "$watch_pid" 2>/dev/null; then
    kill -TERM "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

command -v inotifywait >/dev/null || {
  echo "watch-extra-deps test requires inotifywait" >&2
  exit 1
}

# Extra inputs outside the members: ones named by globs in the manifest, one
# declared in the source.  Changing any must trigger a rebuild, including
# creating the missing directory of a glob whose parent exists.
project=$tmpdir/project
mkdir -p "$project/src" "$project/data" "$project/extra" "$project/more"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "watch-extra-deps"

[build]
members = ["src"]

[actions.ATheory]
extra_deps = ["data/*.txt", "more/tables/*.txt"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel boolLib bossLib;
fun holbuild_extra_deps (_ : string list) = ()
val _ = holbuild_extra_deps ["../extra/table.txt"]
val _ = new_theory "A";
val trivial = Q.store_thm ("trivial", `T`, rw []);
val _ = export_theory ();
SML
echo v1 > "$project/data/table.txt"
echo v1 > "$project/extra/table.txt"

wait_for_count() {
  local pattern=$1
  local path=$2
  local expected=$3
  local timeout=$4
  local deadline=$((SECONDS + timeout))
  local count
  while (( SECONDS < deadline )); do
    count=$(grep -c -- "$pattern" "$path" 2>/dev/null || true)
    if (( count >= expected )); then
      return 0
    fi
    if ! kill -0 "$watch_pid" 2>/dev/null; then
      echo "watch process exited while waiting for '$pattern' count $expected" >&2
      cat "$path" >&2 || true
      exit 1
    fi
    sleep 0.25
  done
  echo "timed out waiting for '$pattern' count $expected in $path" >&2
  cat "$path" >&2 || true
  exit 1
}

watch_log=$tmpdir/watch.log
(cd "$project" && exec "$WATCH_HOLBUILD_BIN" build --watch ATheory) >"$watch_log" 2>&1 &
watch_pid=$!

wait_for_count "waiting for changes" "$watch_log" 1 90
sleep 1

echo v2 > "$project/data/table.txt"
wait_for_count "waiting for changes" "$watch_log" 2 45
sleep 1

echo v2 > "$project/extra/table.txt"
wait_for_count "waiting for changes" "$watch_log" 3 45
sleep 1

mkdir "$project/more/tables"
echo v1 > "$project/more/tables/table.txt"
wait_for_count "waiting for changes" "$watch_log" 4 45
