#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../lib.sh"

HOLBUILD_BIN=$1
WATCH_HOLBUILD_BIN=${REAL_HOLBUILD_BIN:-$HOLBUILD_BIN}

tmpdir=$(make_temp_dir)
watch_pid=""
watch_status=""

cleanup() {
  if [[ -n "$watch_pid" ]] && kill -0 "$watch_pid" 2>/dev/null; then
    kill -TERM "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

command -v inotifywait >/dev/null || {
  echo "watch-mode test requires inotifywait" >&2
  exit 1
}

project=$tmpdir/project
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "watch-mode"
TOML

write_good_source() {
  cat > "$project/AScript.sml" <<'SML'
open HolKernel boolLib bossLib;
val _ = new_theory "A";
val trivial = Q.store_thm ("trivial", `T`, rw []);
val _ = export_theory ();
SML
}

write_bad_source() {
  cat > "$project/AScript.sml" <<'SML'
open HolKernel boolLib bossLib;
val _ = new_theory "A";
val broken =
SML
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
    if [[ -n "$watch_pid" ]] && ! kill -0 "$watch_pid" 2>/dev/null; then
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

wait_for_exit() {
  local pid=$1
  local timeout=$2
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      set +e
      wait "$pid"
      watch_status=$?
      set -e
      watch_pid=""
      return 0
    fi
    local state
    state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
    if [[ "$state" == Z* ]]; then
      set +e
      wait "$pid"
      watch_status=$?
      set -e
      watch_pid=""
      return 0
    fi
    sleep 0.1
  done
  echo "watch process did not exit within ${timeout}s after SIGINT" >&2
  return 1
}

write_good_source
watch_log=$tmpdir/watch.log
(trap - INT; cd "$project" && exec "$WATCH_HOLBUILD_BIN" build --watch ATheory) >"$watch_log" 2>&1 &
watch_pid=$!

wait_for_count "waiting for changes" "$watch_log" 1 90
sleep 2
stable_count=$(grep -c -- "waiting for changes" "$watch_log" 2>/dev/null || true)
if [[ "$stable_count" -ne 1 ]]; then
  echo "watch mode retriggered without source changes" >&2
  cat "$watch_log" >&2
  exit 1
fi

echo "(* edit one *)" >> "$project/AScript.sml"
wait_for_count "waiting for changes" "$watch_log" 2 45
sleep 1

write_bad_source
wait_for_count "waiting for changes" "$watch_log" 3 45
sleep 1

write_good_source
wait_for_count "waiting for changes" "$watch_log" 4 45

kill -INT "$watch_pid"
wait_for_exit "$watch_pid" 10
