#!/usr/bin/env bash
set -euo pipefail

# An edit made while a watch build runs must be built before the watch waits:
# the inotify watch only starts after the build, so it never sees that edit.

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
  echo "watch-edit-during-build test requires inotifywait" >&2
  exit 1
}

project=$tmpdir/project
runs=$tmpdir/runs
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "watch-edit-during-build"

[build]
members = ["src"]
TOML
# Each run of the script appends a line to $runs, then sleeps so the test can
# edit the script while the build is still running.
cat > "$project/src/AScript.sml" <<SML
open HolKernel boolLib bossLib;
val _ = new_theory "A";
val _ = let val f = TextIO.openAppend "$runs" in TextIO.output (f, "run\n"); TextIO.closeOut f end;
val _ = OS.Process.sleep (Time.fromSeconds 8);
val trivial = Q.store_thm ("trivial", \`T\`, rw []);
val _ = export_theory ();
SML

watch_log=$tmpdir/watch.log
(trap - INT; cd "$project" && exec "$WATCH_HOLBUILD_BIN" build --watch ATheory) >"$watch_log" 2>&1 &
watch_pid=$!

run_count() { if [[ -f "$runs" ]]; then wc -l < "$runs"; else echo 0; fi; }

deadline=$((SECONDS + 120))
until [[ "$(run_count)" -ge 1 ]]; do
  (( SECONDS < deadline )) || { echo "theory never started executing" >&2; cat "$watch_log" >&2; exit 1; }
  kill -0 "$watch_pid" 2>/dev/null || { echo "watch exited early" >&2; cat "$watch_log" >&2; exit 1; }
  sleep 0.1
done

# The edited script doesn't sleep, so the rebuild is quick.
sed -i 's/Time.fromSeconds 8/Time.fromSeconds 0/' "$project/src/AScript.sml"

deadline=$((SECONDS + 120))
until grep -q "waiting for changes" "$watch_log"; do
  (( SECONDS < deadline )) || { echo "watch never reached waiting state" >&2; cat "$watch_log" >&2; exit 1; }
  kill -0 "$watch_pid" 2>/dev/null || { echo "watch exited early" >&2; cat "$watch_log" >&2; exit 1; }
  sleep 0.25
done

if [[ "$(run_count)" -ne 2 ]]; then
  echo "edit made during the build was not built before waiting: theory ran $(run_count) time(s), expected 2" >&2
  cat "$watch_log" >&2
  exit 1
fi
