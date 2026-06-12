#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
holbuild_pid=""
sleeper_pid=""
cleanup() {
  if [[ -n "$holbuild_pid" ]]; then
    kill -KILL "$holbuild_pid" 2>/dev/null || true
  fi
  if [[ -n "$sleeper_pid" ]]; then
    kill -KILL "$sleeper_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
started=$tmpdir/sleeper.started
pid_file=$tmpdir/sleeper.pid
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "interrupt_cleanup"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = OS.Process.system "sh -c 'echo \$\$ > $pid_file; touch $started; exec sleep 30'";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/build.log" 2>&1 &
holbuild_pid=$!

for _ in $(seq 1 100); do
  [[ -s "$pid_file" && -f "$started" ]] && break
  sleep 0.1
done

if [[ ! -s "$pid_file" ]]; then
  echo "build did not start sleeper process" >&2
  cat "$tmpdir/build.log" >&2 || true
  exit 1
fi
sleeper_pid=$(cat "$pid_file")

kill_pid=$holbuild_pid
if ps -o args= -p "$holbuild_pid" 2>/dev/null | grep -q 'holbuild-wrapper'; then
  child_pid=$(pgrep -P "$holbuild_pid" | head -n1 || true)
  [[ -n "$child_pid" ]] && kill_pid=$child_pid
fi

kill -TERM "$kill_pid"
set +e
wait "$holbuild_pid"
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "interrupted build exited successfully" >&2
  exit 1
fi
holbuild_pid=""

for _ in $(seq 1 50); do
  if ! kill -0 "$sleeper_pid" 2>/dev/null; then
    sleeper_pid=""
    exit 0
  fi
  state=$(ps -o stat= -p "$sleeper_pid" 2>/dev/null | tr -d ' ' || true)
  if [[ "$state" == Z* ]]; then
    sleeper_pid=""
    exit 0
  fi
  sleep 0.1
done

echo "interrupted build left child process running: $sleeper_pid" >&2
ps -o pid,pgid,stat,cmd -p "$sleeper_pid" >&2 || true
exit 1
