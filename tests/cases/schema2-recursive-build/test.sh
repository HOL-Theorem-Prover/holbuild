#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
first_builder=
second_builder=
release=
killed_builder=
replacement_builder=
replacement_release=
orphan_pid=
orphan_pgid=
regression_failures=()
cleanup() {
  [[ -z "$release" ]] || touch "$release"
  [[ -z "$replacement_release" ]] || touch "$replacement_release"
  [[ -z "$orphan_pgid" ]] || kill -CONT -- "-$orphan_pgid" 2>/dev/null || true
  [[ -z "$first_builder" ]] || wait "$first_builder" 2>/dev/null || true
  [[ -z "$second_builder" ]] || wait "$second_builder" 2>/dev/null || true
  [[ -z "$killed_builder" ]] || wait "$killed_builder" 2>/dev/null || true
  [[ -z "$replacement_builder" ]] || wait "$replacement_builder" 2>/dev/null || true
  [[ -z "$orphan_pgid" ]] || kill -KILL -- "-$orphan_pgid" 2>/dev/null || true
  [[ -z "$orphan_pid" ]] || kill -KILL "$orphan_pid" 2>/dev/null || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

fail() { echo "$*" >&2; exit 1; }
record_regression_failure() { regression_failures+=("$*"); echo "$*" >&2; }
wait_for_file() {
  local path=$1
  local description=$2
  for _ in $(seq 1 200); do
    [[ -f "$path" ]] && return
    sleep 0.05
  done
  fail "$description"
}
process_alive() {
  local pid=$1
  local state
  kill -0 "$pid" 2>/dev/null || return 1
  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  [[ "$state" != Z* ]]
}
wait_for_process_exit() {
  local pid=$1
  local description=$2
  for _ in $(seq 1 200); do
    process_alive "$pid" || return 0
    sleep 0.05
  done
  fail "$description"
}
process_group_alive() {
  local pgid=$1
  ps -eo pgid=,stat= | awk -v pgid="$pgid" '$1 == pgid && $2 !~ /^Z/ { found = 1 } END { exit !found }'
}
wait_for_process_group_exit() {
  local pgid=$1
  local description=$2
  for _ in $(seq 1 200); do
    process_group_alive "$pgid" || return 0
    sleep 0.05
  done
  fail "$description"
}
wait_for_process_stop() {
  local pid=$1
  local description=$2
  local state
  for _ in $(seq 1 200); do
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    [[ "$state" == T* ]] && return 0
    sleep 0.05
  done
  fail "$description"
}
observe_file_while_process_runs() {
  local path=$1
  local pid=$2
  for _ in $(seq 1 60); do
    [[ ! -e "$path" ]] || return 0
    process_alive "$pid" || return 2
    sleep 0.05
  done
  return 1
}

hol=$tmpdir/hol
mkdir -p "$hol/bin" "$hol/tools" "$hol/tools/build" "$hol/tools/sequences" "$hol/src/post" "$hol/src/n-bit"
cat > "$hol/.gitignore" <<'EOF_IGNORE'
/bin/hol
/bin/Holmake
/bin/hol.state
/sigobj
/configured
/built
/built-at
EOF_IGNORE
cat > "$hol/tools/smart-configure.sml" <<'SML'
(* fake configure script; HOLBUILD_POLY fixture handles it *)
SML
printf '#include sequences/upto-hol\nsrc/post\n' > "$hol/tools/build/build-sequence"
printf 'fake upto-hol sequence\n' > "$hol/tools/sequences/upto-hol"
cat > "$hol/src/post/PostScript.sml" <<'SML'
val _ = new_theory "Post";
val _ = export_theory();
SML
cat > "$hol/src/n-bit/wordsScript.sml" <<'SML'
val _ = new_theory "words";
val _ = export_theory();
SML
cat > "$hol/bin/build" <<'SH'
#!/usr/bin/env sh
set -eu
[ "$#" -eq 2 ] && [ "$1" = "--no-helpdocs" ] && [ "$2" = "--seq=tools/sequences/upto-hol" ]
if [ -n "${HOLBUILD_TEST_ATTEMPTS:-}" ]; then
  printf 'attempt\n' >> "$HOLBUILD_TEST_ATTEMPTS"
fi
if [ -n "${HOLBUILD_TEST_BUILD_PID:-}" ]; then
  printf '%s\n' "$$" > "$HOLBUILD_TEST_BUILD_PID"
fi
if [ -n "${HOLBUILD_TEST_BUILD_STARTED:-}" ]; then
  touch "$HOLBUILD_TEST_BUILD_STARTED"
  while [ ! -e "$HOLBUILD_TEST_BUILD_RELEASE" ]; do
    sleep 0.05
  done
fi
if [ "${HOLBUILD_TEST_FAIL_BUILD:-0}" = "1" ]; then
  touch partial-build
  exit 1
fi
touch built
pwd > built-at
mkdir -p sigobj
: > sigobj/BaseTheory.uo
cat > bin/hol <<'HOL'
#!/usr/bin/env sh
exit 0
HOL
chmod +x bin/hol
cat > bin/Holmake <<'HOLMAKE'
#!/usr/bin/env sh
set -eu
holdir=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${HOLBUILD_TEST_MANIFEST_PID:-}" ]; then
  printf '%s\n' "$$" > "$HOLBUILD_TEST_MANIFEST_PID"
fi
if [ -n "${HOLBUILD_TEST_MANIFEST_STARTED:-}" ]; then
  touch "$HOLBUILD_TEST_MANIFEST_STARTED"
  while [ ! -e "$HOLBUILD_TEST_MANIFEST_RELEASE" ]; do
    sleep 0.05
  done
fi
if [ -n "${HOLBUILD_TEST_MANIFEST_WRITE:-}" ]; then
  touch "$holdir/$HOLBUILD_TEST_MANIFEST_WRITE"
fi
cat <<EOF
[
{
  "target" : "$holdir/src/n-bit/wordsScript.sml",
  "command" : "fake	command"
}
]
EOF
HOLMAKE
chmod +x bin/Holmake
echo fake-state > bin/hol.state
SH
chmod +x "$hol/bin/build"
hol_rev=$(init_git_repo "$hol")
export HOLBUILD_CANONICAL_HOL_GIT="$hol"

fakebin=$tmpdir/fakebin
mkdir -p "$fakebin"
cat > "$fakebin/poly" <<'SH'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = "-v" ]; then
  echo "Fake Poly/ML 1.0"
  exit 0
fi
touch configured
SH
chmod +x "$fakebin/poly"
cat > "$fakebin/polyc" <<'SH'
#!/usr/bin/env sh
set -eu
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "$out" ]; then
  echo "fake polyc missing -o" >&2
  exit 1
fi
cat > "$out" <<'ANALYSER'
#!/usr/bin/env sh
set -eu
resp=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --response) resp=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$resp" <<'RESP'
version 1
ok
begin-file 1
end-file 1
end
RESP
ANALYSER
chmod +x "$out"
SH
chmod +x "$fakebin/polyc"
export HOLBUILD_POLYC="$fakebin/polyc"

b=$tmpdir/b
mkdir -p "$b/src"
cat > "$b/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "b"

[build]
members = ["src"]

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"
TOML
cat > "$b/src/Foo.sml" <<'SML'
structure Foo = struct
  val value = true
end
SML
b_rev=$(init_git_repo "$b")

a=$tmpdir/a
mkdir -p "$a"
cat > "$a/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "a"

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"

[dependencies.b]
git = "$b"
rev = "$b_rev"
TOML
a_rev=$(init_git_repo "$a")

root=$tmpdir/root
mkdir -p "$root/src"
cat > "$root/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "root"

[dependencies.a]
git = "$a"
rev = "$a_rev"

[actions.ATheory]
loads = ["BaseTheory"]
TOML
cat > "$root/src/AScript.sml" <<'SML'
val _ = new_theory "A";
val _ = export_theory();
SML

context_log=$tmpdir/context.log
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" context) > "$context_log"
require_grep "package: hol \[root=$HOLBUILD_CACHE/hol-toolchains/" "$context_log"
shared_hol_from_context=$(awk -F'root=' '/package: hol / { split($2, parts, ","); print parts[1]; exit }' "$context_log")
if find -L "$shared_hol_from_context" \( -name configured -o -name built \) 2>/dev/null | grep -q .; then
  echo "schema 2 context unexpectedly built HOL" >&2
  exit 1
fi
if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/context-holdir.log" 2>&1; then
  echo "schema 2 context unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'no longer supported' "$tmpdir/context-holdir.log"

if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" run) > "$tmpdir/run-holdir.log" 2>&1; then
  echo "schema 2 run unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'no longer supported' "$tmpdir/run-holdir.log"

if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" heap fake) > "$tmpdir/heap-holdir.log" 2>&1; then
  echo "schema 2 heap unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'no longer supported' "$tmpdir/heap-holdir.log"

toolchain_entry=${shared_hol_from_context%/hol}
toolchain_key=$(basename "$toolchain_entry")
toolchains_dir=$HOLBUILD_CACHE/hol-toolchains
stale_lock="$toolchains_dir/.locks/hol-toolchain-$toolchain_key.lock"
attempts=$tmpdir/toolchain-build-attempts

failed_log=$tmpdir/interrupted-build.log
if (cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" \
    HOLBUILD_TEST_ATTEMPTS="$attempts" \
    HOLBUILD_TEST_FAIL_BUILD=1 "$HOLBUILD_BIN" build --dry-run Foo) > "$failed_log" 2>&1; then
  fail "interrupted toolchain build unexpectedly succeeded"
fi
[[ ! -e "$toolchain_entry" ]] ||
  fail "interrupted toolchain build exposed an incomplete final entry"
: > "$attempts"

mkdir -p "$toolchain_entry"
touch "$toolchain_entry/interrupted-build"
rm -f "$stale_lock"
mkdir -p "$stale_lock"

started=$tmpdir/toolchain-build-started
release=$tmpdir/toolchain-build-release
dry_log=$tmpdir/dry.log
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" \
  HOLBUILD_TEST_ATTEMPTS="$attempts" \
  HOLBUILD_TEST_BUILD_STARTED="$started" HOLBUILD_TEST_BUILD_RELEASE="$release" \
  "$HOLBUILD_BIN" build --dry-run Foo) > "$dry_log" 2>&1 &
first_builder=$!
wait_for_file "$started" "toolchain build did not reach the publish gate"
[[ -d "$toolchain_entry" ]] ||
  fail "toolchain build did not use its configured final directory"
[[ ! -e "$toolchain_entry/build.ok" ]] ||
  fail "toolchain entry was committed before build completion"
[[ ! -e "$toolchain_entry/interrupted-build" ]] ||
  fail "incomplete toolchain entry was not invalidated"

race_log=$tmpdir/dry-race.log
race_waiting=$tmpdir/toolchain-lock-waiting
race_revalidated=$tmpdir/toolchain-lock-revalidated
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" \
  HOLBUILD_TEST_ATTEMPTS="$attempts" \
  HOLBUILD_TEST_TOOLCHAIN_LOCK_WAITING="$race_waiting" \
  HOLBUILD_TEST_TOOLCHAIN_REVALIDATED="$race_revalidated" \
  "$HOLBUILD_BIN" build --dry-run Foo) > "$race_log" 2>&1 &
second_builder=$!
wait_for_file "$race_waiting" \
  "concurrent toolchain request did not observe the active builder's lock"
[[ ! -e "$race_revalidated" ]] ||
  fail "concurrent toolchain request revalidated before the active builder committed"
touch "$release"
wait "$first_builder"
wait "$second_builder"
first_builder=
second_builder=
release=
require_file "$race_revalidated"

require_grep "removing obsolete directory HOL toolchain lock" "$dry_log"
require_grep "Foo (sml, package b)" "$dry_log"
require_grep "Foo (sml, package b)" "$race_log"
[[ "$(wc -l < "$attempts" | tr -d ' ')" = "1" ]] ||
  fail "lock waiter rebuilt instead of consuming the committed toolchain entry"

rm -rf "$toolchain_entry"
killed_started=$tmpdir/killed-toolchain-build-started
killed_release=$tmpdir/killed-toolchain-build-release
killed_child_pid_file=$tmpdir/killed-toolchain-build-child-pid
killed_log=$tmpdir/killed-toolchain-build.log
release=$killed_release
(
  cd "$root"
  exec env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" \
    HOLBUILD_TEST_BUILD_STARTED="$killed_started" \
    HOLBUILD_TEST_BUILD_RELEASE="$killed_release" \
    HOLBUILD_TEST_BUILD_PID="$killed_child_pid_file" \
    "$REAL_HOLBUILD_BIN" build --dry-run Foo
) > "$killed_log" 2>&1 &
killed_builder=$!
wait_for_file "$killed_started" "toolchain build did not reach the parent-termination gate"
wait_for_file "$killed_child_pid_file" "toolchain build child did not report its pid"
orphan_pid=$(cat "$killed_child_pid_file")
orphan_pgid=$(ps -o pgid= -p "$orphan_pid" | tr -d ' ')
[[ -n "$orphan_pgid" ]] || fail "toolchain build child did not report a process group"
kill -0 "$killed_builder" 2>/dev/null ||
  fail "toolchain build parent exited before the termination test"
process_alive "$orphan_pid" ||
  fail "toolchain build child exited before its parent was terminated"

# Freeze the mutating group, including the parent watcher. Cache exclusion must
# remain correct even when watcher scheduling delays termination after SIGKILL.
kill -STOP -- "-$orphan_pgid"
wait_for_process_stop "$orphan_pid" "toolchain build process group did not stop"
kill -KILL "$killed_builder"
if wait "$killed_builder" 2>/dev/null; then
  fail "SIGKILLed toolchain build parent unexpectedly succeeded"
fi
killed_builder=
[[ -d "$toolchain_entry" && ! -e "$toolchain_entry/build.ok" ]] ||
  fail "parent termination did not leave a markerless toolchain entry"

replacement_started=$tmpdir/replacement-toolchain-build-started
replacement_release=$tmpdir/replacement-toolchain-build-release
replacement_log=$tmpdir/post-kill-rebuild.log
(
  cd "$root"
  exec env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" \
    HOLBUILD_TEST_BUILD_STARTED="$replacement_started" \
    HOLBUILD_TEST_BUILD_RELEASE="$replacement_release" \
    "$REAL_HOLBUILD_BIN" build --dry-run Foo
) > "$replacement_log" 2>&1 &
replacement_builder=$!
replacement_overlapped=0
if process_group_alive "$orphan_pgid"; then
  set +e
  observe_file_while_process_runs "$replacement_started" "$replacement_builder"
  replacement_observation=$?
  set -e
  case "$replacement_observation" in
    0) process_group_alive "$orphan_pgid" && replacement_overlapped=1 ;;
    1) ;;
    *) fail "replacement toolchain build exited before reaching bin/build" ;;
  esac
fi

kill -CONT -- "-$orphan_pgid" 2>/dev/null || true
touch "$replacement_release"
wait_for_process_group_exit "$orphan_pgid" \
  "old toolchain process group did not exit after resume"
orphan_pid=
orphan_pgid=
release=
if ! wait "$replacement_builder"; then
  replacement_builder=
  fail "replacement toolchain build failed; see $replacement_log"
fi
replacement_builder=
replacement_release=
require_file "$toolchain_entry/build.ok"
require_grep "Foo (sml, package b)" "$replacement_log"
if [[ "$replacement_overlapped" -ne 0 ]]; then
  record_regression_failure \
    "replacement mutated the cache while the previous toolchain process group was alive"
fi

# Manifest discovery runs after bin/build but before build.ok. Killing holbuild
# here must not leave an untracked Holmake able to write into a replacement.
rm -rf "$toolchain_entry"
manifest_started=$tmpdir/manifest-holmake-started
manifest_release=$tmpdir/manifest-holmake-release
manifest_pid_file=$tmpdir/manifest-holmake-pid
manifest_writer=$toolchain_entry/hol/orphan-manifest-writer
manifest_log=$tmpdir/manifest-interrupted-build.log
release=$manifest_release
(
  cd "$root"
  exec env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" \
    HOLBUILD_TEST_MANIFEST_STARTED="$manifest_started" \
    HOLBUILD_TEST_MANIFEST_RELEASE="$manifest_release" \
    HOLBUILD_TEST_MANIFEST_PID="$manifest_pid_file" \
    HOLBUILD_TEST_MANIFEST_WRITE="orphan-manifest-writer" \
    "$REAL_HOLBUILD_BIN" build --dry-run Foo
) > "$manifest_log" 2>&1 &
killed_builder=$!
wait_for_file "$manifest_started" "manifest Holmake did not reach the parent-termination gate"
wait_for_file "$manifest_pid_file" "manifest Holmake did not report its pid"
orphan_pid=$(cat "$manifest_pid_file")
kill -KILL "$killed_builder"
if wait "$killed_builder" 2>/dev/null; then
  fail "SIGKILLed manifest build parent unexpectedly succeeded"
fi
killed_builder=
[[ -d "$toolchain_entry" && ! -e "$toolchain_entry/build.ok" ]] ||
  fail "manifest interruption did not leave a markerless toolchain entry"

manifest_rebuild_log=$tmpdir/manifest-post-kill-rebuild.log
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" \
  "$HOLBUILD_BIN" build --dry-run Foo) > "$manifest_rebuild_log" 2>&1
require_file "$toolchain_entry/build.ok"
require_grep "Foo (sml, package b)" "$manifest_rebuild_log"
manifest_survived=0
process_alive "$orphan_pid" && manifest_survived=1
touch "$manifest_release"
wait_for_process_exit "$orphan_pid" "manifest Holmake did not exit after release"
orphan_pid=
release=

if [[ "$manifest_survived" -ne 0 ]]; then
  require_file "$manifest_writer"
  manifest_dirty_log=$tmpdir/manifest-orphan-dirty.log
  if (cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" \
    "$HOLBUILD_BIN" build --dry-run Foo) > "$manifest_dirty_log" 2>&1; then
    record_regression_failure \
      "manifest Holmake outlived its parent and the replacement cache commit"
  else
    require_grep "dirty HOL toolchain cache entry" "$manifest_dirty_log"
    record_regression_failure \
      "orphaned manifest Holmake dirtied the committed replacement entry"
  fi
  rm -rf "$toolchain_entry"
  (cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" \
    "$HOLBUILD_BIN" build --dry-run Foo) > "$tmpdir/manifest-clean-rebuild.log" 2>&1
fi

(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" build --dry-run wordsTheory) > "$tmpdir/words-hol-source.log" 2>&1
require_grep "wordsTheory (theory, package hol)" "$tmpdir/words-hol-source.log"
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" build --dry-run ATheory) > "$tmpdir/base-external.log" 2>&1
require_grep "ATheory (theory, package root)" "$tmpdir/base-external.log"
if grep -q "BaseTheory (theory, package hol)" "$tmpdir/base-external.log"; then
  echo "toolchain sigobj theory was unexpectedly discovered as HOL source" >&2
  exit 1
fi
[[ -f "$stale_lock" ]] || { echo "toolchain lock was not recreated as a file" >&2; exit 1; }
[[ ! -e "$stale_lock.owner" ]] || { echo "toolchain lock owner survived successful bootstrap" >&2; exit 1; }
shared_hol=$shared_hol_from_context
require_file "$toolchain_entry/build.ok"
require_file "$shared_hol/configured"
require_file "$shared_hol/built"
require_file "$shared_hol/bin/hol"
require_file "$shared_hol/bin/hol.state"
shared_hol_real=$(cd "$shared_hol" && pwd -P)
built_at=$(cat "$shared_hol/built-at")
if [[ "$built_at" != "$shared_hol" && "$built_at" != "$shared_hol_real" ]]; then
  echo "unexpected fake HOL build directory: $built_at" >&2
  exit 1
fi
rm "$shared_hol/configured" "$shared_hol/built"
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" buildhol) > "$tmpdir/buildhol.log"
require_grep "$shared_hol" "$tmpdir/buildhol.log"
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" build --dry-run Foo) > "$tmpdir/dry2.log"
if [ -e "$shared_hol/configured" ] || [ -e "$shared_hol/built" ]; then
  echo "already-built schema 2 HOL was rebuilt" >&2
  exit 1
fi

# Older pinned HOL revisions predate tools/sequences/upto-hol.  They must keep
# working through the historical full-build path instead of becoming
# unbuildable when the reduced toolchain sequence is unavailable.
legacy_hol=$tmpdir/legacy-hol
mkdir -p "$legacy_hol/bin" "$legacy_hol/tools/build"
cat > "$legacy_hol/.gitignore" <<'EOF_IGNORE'
/bin/hol
/bin/Holmake
/bin/hol.state
/sigobj
/configured
/legacy-built
EOF_IGNORE
cat > "$legacy_hol/tools/smart-configure.sml" <<'SML'
(* fake configure script; HOLBUILD_POLY fixture handles it *)
SML
printf 'src/post\n' > "$legacy_hol/tools/build/build-sequence"
cat > "$legacy_hol/bin/build" <<'SH'
#!/usr/bin/env sh
set -eu
[ "$#" -eq 1 ] && [ "$1" = "--no-helpdocs" ]
touch legacy-built
mkdir -p sigobj
: > sigobj/BaseTheory.uo
cat > bin/hol <<'HOL'
#!/usr/bin/env sh
exit 0
HOL
chmod +x bin/hol
cat > bin/Holmake <<'HOLMAKE'
#!/usr/bin/env sh
printf '[]\n'
HOLMAKE
chmod +x bin/Holmake
echo fake-state > bin/hol.state
SH
chmod +x "$legacy_hol/bin/build"
legacy_hol_rev=$(init_git_repo "$legacy_hol")

legacy_root=$tmpdir/legacy-root
mkdir -p "$legacy_root"
cat > "$legacy_root/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "legacy-root"

[dependencies.hol]
git = "$legacy_hol"
rev = "$legacy_hol_rev"
TOML
legacy_log=$tmpdir/legacy-hol.log
(cd "$legacy_root" && env -u HOLDIR -u HOLBUILD_HOLDIR \
  HOLBUILD_CANONICAL_HOL_GIT="$legacy_hol" HOLBUILD_POLY="$fakebin/poly" \
  "$HOLBUILD_BIN" buildhol) > "$legacy_log" 2>&1
require_grep "falling back to full HOL build" "$legacy_log"
legacy_shared_hol=$(tail -n 1 "$legacy_log")
require_file "$legacy_shared_hol/legacy-built"

if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run Foo) > "$tmpdir/holdir.log" 2>&1; then
  echo "schema 2 build unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'no longer supported' "$tmpdir/holdir.log"

echo dirty >> "$shared_hol/bin/build"
if (cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" build --dry-run Foo) > "$tmpdir/dirty.log" 2>&1; then
  echo "dirty HOL checkout unexpectedly accepted" >&2
  exit 1
fi
require_grep 'dirty HOL toolchain cache entry' "$tmpdir/dirty.log"

[ -d "$root/.holbuild/src/b/.git" ]
[ ! -d "$root/.holbuild/src/b/.holbuild" ]
[ ! -d "$root/.holbuild/packages/a/.holbuild" ]
[ ! -d "$root/.holbuild/packages/a/.holbuild/src/b" ]

if [[ ${#regression_failures[@]} -ne 0 ]]; then
  printf 'toolchain interruption regressions:\n' >&2
  printf '  - %s\n' "${regression_failures[@]}" >&2
  exit 1
fi
