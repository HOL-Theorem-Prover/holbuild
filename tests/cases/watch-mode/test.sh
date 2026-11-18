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

# Ancestors named like directories the watch skips (_build, .holbuild, .git)
# must not hide the project from it, and other dot-directories are watched
# (lib/.hidden is a member).
project=$tmpdir/_build/.dot/project
mkdir -p "$project/src" "$project/lib/.hidden"
write_project_file() {
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "watch-mode"

[build]
members = ["src", "lib", "lib/.hidden"]
TOML
}

write_bad_project_file() {
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "watch-mode"
unknown = "invalid"
TOML
}

write_bad_holbuild_file() {
  cat > "$project/holbuild.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "watch-mode"
unknown = "invalid"
TOML
}

write_good_holbuild_file() {
  cat > "$project/holbuild.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "watch-mode"

[build]
members = ["src"]
TOML
}

write_good_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel boolLib bossLib;
val _ = new_theory "A";
val trivial = Q.store_thm ("trivial", `T`, rw []);
val _ = export_theory ();
SML
}

write_bad_source() {
  cat > "$project/src/AScript.sml" <<'SML'
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

write_project_file
write_good_source
# holbuild's own directories below a watched one: writes there must
# not trigger a rebuild.
mkdir -p "$project/src/.holbuild" "$project/src/_build"
# Residue that would trigger an automatic project GC, which watch never runs.
printf '[gc]\nproject_builds = 1\n' > "$project/.holconfig.toml"
mkdir -p "$project/.holbuild/stage/abandoned"
: > "$project/.holbuild/stage/abandoned/leftover"
touch -d '10 days ago' "$project/.holbuild/stage/abandoned"
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

echo "noise" > "$project/src/.holbuild/noise"
echo "noise" > "$project/src/_build/noise"
sleep 2
skipped_count=$(grep -c -- "waiting for changes" "$watch_log" 2>/dev/null || true)
if [[ "$skipped_count" -ne 1 ]]; then
  echo "watch mode rebuilt after writes in skipped directories" >&2
  cat "$watch_log" >&2
  exit 1
fi

echo "(* edit one *)" >> "$project/src/AScript.sml"
wait_for_count "waiting for changes" "$watch_log" 2 45
sleep 1

write_bad_project_file
wait_for_count "waiting for changes" "$watch_log" 3 45
require_grep "build failed:" "$watch_log"
sleep 1

write_project_file
wait_for_count "waiting for changes" "$watch_log" 4 45
sleep 1

write_bad_source
wait_for_count "waiting for changes" "$watch_log" 5 45
sleep 1

write_good_source
wait_for_count "waiting for changes" "$watch_log" 6 45
sleep 1

# A holbuild.toml appearing beside the manifest in use takes precedence and is
# noticed without any watched path changing; so are fixing and removing it.
write_bad_holbuild_file
wait_for_count "waiting for changes" "$watch_log" 7 45
require_grep "holbuild.toml: unknown field in project: unknown" "$watch_log"
sleep 1

write_good_holbuild_file
wait_for_count "waiting for changes" "$watch_log" 8 45
sleep 1

rm "$project/holbuild.toml"
wait_for_count "waiting for changes" "$watch_log" 9 45
sleep 1

cat > "$project/lib/.hidden/BScript.sml" <<'SML'
Theory B
Ancestors bool
SML
wait_for_count "waiting for changes" "$watch_log" 10 45

kill -INT "$watch_pid"
wait_for_exit "$watch_pid" 10
require_file "$project/.holbuild/stage/abandoned/leftover"
! grep -q "automatic" "$watch_log" || { echo "watch ran automatic gc" >&2; cat "$watch_log" >&2; exit 1; }

python3 - "$project" <<'PYCODE'
import json,pathlib,sys
records=[json.loads(p.read_text()) for p in (pathlib.Path(sys.argv[1])/'.holbuild/commands').glob('*.json')]
assert len(records)==1, records
plans=records[0]['plans']
assert sum(p['cold_worktree'] for p in plans)==1, plans
assert plans[1]['changed_sources'], plans
assert not plans[2]['changed_sources'], plans
assert all(not p['newly_observed_sources'] for p in plans[1:3]), plans
PYCODE
