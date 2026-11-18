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

pad=$(printf 'x%.0s' $(seq 1 150))

# An extra input file and an (empty) member directory per name make a watch set
# whose paths, and whose directories alone, are each longer than the 128 KiB
# Linux allows for one command-line argument.
setup_project() {
  local project=$1
  local mixed=$2
  mkdir -p "$project/src" "$project/data"
  {
    cat <<TOML
$(write_schema2_prelude)
[project]
name = "watch-large-set"

[build]
members = [
  "src",
TOML
    if [[ -n $mixed ]]; then
      mkdir -p "$project/vendor/_build/pkg"
      echo '  "vendor/_build/pkg",'
    fi
    for i in $(seq 1 1000); do
      printf '  "m%s-%04d",\n' "$pad" "$i"
      mkdir "$project/m$pad-$(printf %04d "$i")"
    done
    cat <<TOML
]

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

  local file_bytes dir_bytes
  file_bytes=$(find "$project/data" -type f | wc -c)
  dir_bytes=$(find "$project" -mindepth 1 -maxdepth 1 -type d -name 'm*' | wc -c)
  if (( file_bytes <= 131072 || dir_bytes <= 131072 )); then
    echo "test setup: watched files are $file_bytes bytes, directories $dir_bytes" >&2
    exit 1
  fi
}

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

run_variant() {
  local project=$1
  local mixed=${2:-}
  local watch_log=$project.log
  setup_project "$project" "$mixed"
  # holbuild's own directories below a watched one: writes there must not
  # trigger a rebuild.
  mkdir -p "$project/src/.holbuild" "$project/src/_build"

  (cd "$project" && exec "$WATCH_HOLBUILD_BIN" build --watch ATheory) >"$watch_log" 2>&1 &
  watch_pid=$!

  wait_for_count "waiting for changes" "$watch_log" 1 90
  sleep 1

  echo noise > "$project/src/.holbuild/noise"
  echo noise > "$project/src/_build/noise"
  sleep 2
  if [[ $(grep -c -- "waiting for changes" "$watch_log") -ne 1 ]]; then
    echo "watch mode rebuilt after writes in skipped directories" >&2
    cat "$watch_log" >&2
    exit 1
  fi

  echo v2 > "$project/data/$pad-0001.txt"
  wait_for_count "waiting for changes" "$watch_log" 2 45
  sleep 1

  echo v2 > "$project/data/$pad-1000.txt"
  wait_for_count "waiting for changes" "$watch_log" 3 45
  sleep 1

  if [[ -n $mixed ]]; then
    echo v2 > "$project/vendor/_build/pkg/file"
    wait_for_count "waiting for changes" "$watch_log" 4 45
  fi

  ! grep -q "inotifywait failed" "$watch_log" || { cat "$watch_log" >&2; exit 1; }
  kill -TERM "$watch_pid"
  wait "$watch_pid" 2>/dev/null || true
  watch_pid=""
}

# With no skipped name in any watched path, below a _build ancestor, and with
# a member below a skipped name as well, itself below a _build ancestor or not.
run_variant "$tmpdir/plain/project"
run_variant "$tmpdir/_build/project"
run_variant "$tmpdir/mixed/project" mixed
run_variant "$tmpdir/_build/mixed/project" mixed
# A newline in a watched path doesn't split it in the list of paths.
run_variant "$tmpdir/new
line/project"
