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
  echo "watch-large-set test requires inotifywait" >&2
  exit 1
}

# One extra input file per declared path puts each on the watch set, so the
# paths together are longer than the 128 KiB Linux allows for one command-line
# argument.
project=$tmpdir/project
mkdir -p "$project/src" "$project/data"
pad=$(printf 'x%.0s' $(seq 1 150))
{
  cat <<TOML
$(write_schema2_prelude)
[project]
name = "watch-large-set"

[build]
members = ["src"]

[actions.ATheory]
extra_deps = [
TOML
  for i in $(seq 1 1000); do
    printf '  "data/%s-%04d.txt",\n' "$pad" "$i"
    echo v1 > "$project/data/$pad-$(printf %04d "$i").txt"
  done
  echo "]"
} > "$project/holproject.toml"
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel boolLib bossLib;
val _ = new_theory "A";
val trivial = Q.store_thm ("trivial", `T`, rw []);
val _ = export_theory ();
SML

path_bytes=$(find "$project/data" -type f | wc -c)
if (( path_bytes <= 131072 )); then
  echo "test setup: watched paths are only $path_bytes bytes" >&2
  exit 1
fi

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

echo v2 > "$project/data/$pad-0001.txt"
wait_for_count "waiting for changes" "$watch_log" 2 45
sleep 1

echo v2 > "$project/data/$pad-1000.txt"
wait_for_count "waiting for changes" "$watch_log" 3 45

! grep -q "inotifywait failed" "$watch_log" || { cat "$watch_log" >&2; exit 1; }
