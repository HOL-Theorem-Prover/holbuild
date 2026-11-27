#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A worker checking a named target that resumes from a checkpoint installs
# no dependency before HOL: the checkpoint has them loaded.  It installs them
# once the theory passes, before its outputs, which are the ones a full
# install gives.  A script that loads a dependency the checkpoint lacks finds
# no file: the worker installs every dependency and builds the theory again.
# A project that reads dependency files itself, or a target the build didn't
# name, has them installed before HOL starts.

tmpdir=$(make_temp_dir)
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
# write_toml [EXTRA]: the manifest, with EXTRA in its [build] table.
write_toml() {
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "light"

[build]
members = ["src"]
${1:-}

[actions.TTheory]
deps = ["CTheory"]
TOML
}
write_toml

cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors bool

Theorem c:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML
# A differs each time it is built.
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

val _ = save_thm ("a" ^ LargeInt.toString (Time.toMicroseconds (Time.now ())), TRUTH);
SML

# write_t STEP [AFTER]: theory T, on A, whose second theorem's last step is
# STEP, followed by AFTER.  C is a dependency T's preload doesn't load.
write_t() {
  cat > "$project/src/TScript.sml" <<SML
Theory T
Ancestors A

Theorem t1:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem t2:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $1
QED
${2:-}
SML
}
# After the theorem a check resumes at: a load of C, by its path from the
# script's directory in the worker's stage, which the analyser doesn't see,
# and a theorem whose proof is $1.
load_c() {
  printf '\nval _ = load ("../../../obj/src/C" ^ "Theory");\n\nTheorem t3:\n  T\nProof\n  %s\nQED\n' "$1"
}

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
url=$remote_url
worker_cache=$tmpdir/worker
field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }
# worker NAME [keep|fresh] [unnamed]: runs T's action on a fresh worker cache
# (the last one with keep), exported with T named as the build's target
# (with unnamed, none: every root theory is one).
worker() {
  local name=$1 targets=(TTheory)
  [[ ${3:-} == unnamed ]] && targets=()
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload "${targets[@]}") \
    > "$tmpdir/$name.batch"
  spec=$(field "$tmpdir/$name.batch" light:TTheory 4)
  remote_key=$(field "$tmpdir/$name.batch" light:TTheory 3)
  [[ -n "$spec" ]] || { cat "$tmpdir/$name.batch" >&2; exit 1; }
  run_spec "$name" "${2:-}"
}
# run_spec NAME [keep]: runs the last worker's spec again, on a fresh worker
# cache (the last one with keep).
run_spec() {
  local name=$1
  if [[ ${2:-} != keep ]]; then
    rm -rf "$worker_cache"
    link_hol_toolchain_cache "$worker_cache"
  fi
  set +e
  HOLBUILD_CACHE=$worker_cache "$HOLBUILD_BIN" --remote-cache "$url" exec-action "$spec" --share-heaps \
    --cache-limit-gb 1000 --result "$tmpdir/$name.result" > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
}
expect_worker() {
  local name=$1 code=$2
  shift 2
  if [[ "$worker_status" != "$code" ]]; then
    echo "worker $name exited $worker_status, wanted $code" >&2
    cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2 || true
    exit 1
  fi
  for line in "$@"; do
    grep -qxF -- "$line" "$tmpdir/$name.result" || {
      echo "worker $name result lacks '$line':" >&2; cat "$tmpdir/$name.result" >&2; exit 1; }
  done
}
phases() { sed -n 's/^phase-ms=//p' "$tmpdir/$1.result" | tr , '\n'; }
# hydrated NAME LIGHT INSTALLED: the worker's hydrate left LIGHT dependencies
# uninstalled (full: it installed every one first), and installed INSTALLED.
hydrated() {
  if [[ $2 == full ]]; then
    ! phases "$1" | grep -q "^hydlightn:" || {
      echo "worker $1 left dependencies uninstalled:" >&2; cat "$tmpdir/$1.result" >&2; exit 1; }
  else
    phases "$1" | grep -qx "hydlightn:$2" || {
      echo "worker $1 left not $2 dependencies uninstalled:" >&2; cat "$tmpdir/$1.result" >&2; exit 1; }
  fi
  if [[ $3 == 0 ]]; then
    ! phases "$1" | grep -q "^hydinstn:[1-9]" || {
      echo "worker $1 installed a dependency:" >&2; cat "$tmpdir/$1.result" "$tmpdir/$1.log" >&2; exit 1; }
  else
    phases "$1" | grep -qx "hydinstn:$3" || {
      echo "worker $1 installed not $3 dependencies:" >&2; cat "$tmpdir/$1.result" >&2; exit 1; }
  fi
}
reran() {
  phases "$1" | grep -qx "lightrerun:1" || {
    echo "worker $1 did not build again on every dependency:" >&2; cat "$tmpdir/$1.result" "$tmpdir/$1.log" >&2; exit 1; }
}
# outputs NAME: T's entry in the remote cache, which names its outputs'
# hashes.
outputs() {
  require_file "$tmpdir/remote/ac/$remote_key"
  cp "$tmpdir/remote/ac/$remote_key" "$tmpdir/$1.entry"
}
# Removes T's entry from the remote, so the next action builds it again.
forget_t() { rm -f "$tmpdir/remote/ac/$remote_key"; }
# report NAME: the log the worker reported, timings aside.
report() {
  local log
  log=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/$1.result")
  require_file "$tmpdir/remote/cas/$log"
  grep -v '^holbuild hol-phases ' "$tmpdir/remote/cas/$log"
}
asks_dependencies_first() { grep -rqx "option install-dependencies-first=true" "$tmpdir/remote"; }

# A and C are in the remote cache, as a batch's client leaves them.
write_t 'FAIL_TAC "first failure"'
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" build --force-theory ATheory CTheory) \
  > "$tmpdir/publish.log" 2>&1 || { cat "$tmpdir/publish.log" >&2; exit 1; }

# A failing target, with no checkpoint to resume from, starts from a fresh
# preload: its dependencies are installed first.  It shares its prefix.
worker first
expect_worker first 1 "status=failed" "failure=proof"
asks_dependencies_first && { echo "a named target's spec asks for the dependencies first" >&2; exit 1; }
hydrated first 2 2

# Resuming from it on a fresh host, a failing check installs nothing.
write_t 'ALL_TAC >> FAIL_TAC "resumed failure"'
worker resume-fail
expect_worker resume-fail 1 "status=failed" "failure=proof"
require_grep "resumed failure" "$tmpdir/resume-fail.log"
hydrated resume-fail 2 0

# A passing one installs its dependencies after HOL, and publishes the
# outputs a full install gives.
write_t "ALL_TAC >> ACCEPT_TAC TRUTH"
worker resume-pass
expect_worker resume-pass 0 "status=built"
require_grep "from: failed-prefix checkpoint in t2" "$tmpdir/resume-pass.log"
hydrated resume-pass 2 2
outputs resume-pass
# Run again on a fresh host, it restores its published entry, installs the
# dependencies and restores it again against them.
run_spec resume-cached
expect_worker resume-cached 0 "status=cached"
hydrated resume-cached 2 2
forget_t
write_toml "install_dependencies_first = true"
worker full-pass
expect_worker full-pass 0 "status=built"
asks_dependencies_first || { echo "no spec asks for the dependencies first" >&2; exit 1; }
hydrated full-pass full 2
outputs full-pass
cmp "$tmpdir/resume-pass.entry" "$tmpdir/full-pass.entry" ||
  { echo "the light and the full install published different entries" >&2; exit 1; }
write_toml

# A script that loads C, which the resumed checkpoint lacks, finds no file;
# the worker installs every dependency and builds T again, to the verdict
# and diagnostics a full install gives.
write_t "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH" "$(load_c 'ACCEPT_TAC (DB.fetch "C" "c")')"
worker load-pass
expect_worker load-pass 0 "status=built"
reran load-pass
write_t "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH" "$(load_c 'FAIL_TAC "after the load"')"
# The full install below starts from the remote as this run finds it, and
# reports the same log, timings aside; the light run's missing file is in
# neither.
cp -a "$tmpdir/remote" "$tmpdir/remote.before"
worker load-fail
expect_worker load-fail 1 "status=failed" "failure=proof"
reran load-fail
require_grep "after the load" "$tmpdir/load-fail.log"
report load-fail > "$tmpdir/load-fail.report"
write_toml "install_dependencies_first = true"
rm -rf "$tmpdir/remote"/*
cp -a "$tmpdir/remote.before"/. "$tmpdir/remote"/
worker load-fail-full
expect_worker load-fail-full 1 "status=failed" "failure=proof"
require_grep "after the load" "$tmpdir/load-fail-full.log"
diff "$tmpdir/load-fail.report" <(report load-fail-full) ||
  { echo "the rerun and the full install reported different logs" >&2; exit 1; }
! grep -q "Cannot find file" "$tmpdir/load-fail.report" ||
  { echo "the rerun reported the light run's missing file" >&2; exit 1; }

# A script that catches the failed load and passes, exporting what it found,
# is caught by its log: the worker builds T again on every dependency, and
# publishes what a full install gives.
write_toml
write_t "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH" "$(printf '\n%s\n%s\n' \
  'val c_loaded = (load ("../../../obj/src/C" ^ "Theory"); true) handle _ => false;' \
  'val _ = save_thm (if c_loaded then "c_loaded" else "c_missing", TRUTH);')"
worker load-catch
expect_worker load-catch 0 "status=built"
reran load-catch
outputs load-catch
forget_t
write_toml "install_dependencies_first = true"
worker load-catch-full
expect_worker load-catch-full 0 "status=built"
outputs load-catch-full
cmp "$tmpdir/load-catch.entry" "$tmpdir/load-catch-full.entry" ||
  { echo "the rerun and the full install published different entries" >&2; exit 1; }

# A script that looks for C's file itself, which finds none on a light
# install and says nothing HOL would, passes when its project asks for the
# dependencies first.
write_t "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH" "$(printf '\nTheorem t3:\n  T\nProof\n  %s\nQED\n' \
  '(if OS.FileSys.access ("../../../obj/src/C" ^ "Theory.ui", []) then ACCEPT_TAC TRUTH else FAIL_TAC "no C")')"
worker probe-full
expect_worker probe-full 0 "status=built"
hydrated probe-full full 2
write_toml

# A target the build didn't name, as every root theory is one when it names
# none, has its dependencies installed first.
write_t "ALL_TAC >> ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
worker unnamed fresh unnamed
expect_worker unnamed 0 "status=built"
hydrated unnamed full 2

# A kept copy of A whose entry the remote has since replaced, as when A was
# built again: a failing check resumes from the checkpoint the copy's records
# give, and reports its verdict; a passing one finds the install differs from
# those records, an internal failure, which the retry, on the remote's copy,
# passes.  So does a failing one on a host that may decline the checkpoint's
# short deps heap, which installs the dependencies first to weigh it.
write_t "ALL_TAC >> ALL_TAC >> ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
worker kept-pass
expect_worker kept-pass 0 "status=built"
a_key=$(cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory | awk '/input_key:/ {print $2; exit}')
a_entry=$tmpdir/remote/ac/$(printf 'holbuild-remote-ac-v1\n%s\n' "$a_key" | sha256sum | cut -d' ' -f1)
require_file "$a_entry"
# The client's own cache keeps A's first outputs, which a rebuild publishes
# again: drop it too.
rm -r "$a_entry" "$tmpdir/cache/actions/$a_key"
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" build --force-theory ATheory) \
  > "$tmpdir/republish.log" 2>&1 || { cat "$tmpdir/republish.log" >&2; exit 1; }
# Each check below starts from this host, with its stale copy of A.
cp -a "$worker_cache" "$tmpdir/worker.kept"
restore_kept() { rm -rf "$worker_cache"; cp -a "$tmpdir/worker.kept" "$worker_cache"; }
# A host whose module store holds none can decline no heap.
rm -rf "$worker_cache/theory-modules"
write_t 'ALL_TAC >> FAIL_TAC "kept failure"'
worker kept-fail keep
expect_worker kept-fail 1 "status=failed" "failure=proof"
require_grep "kept failure" "$tmpdir/kept-fail.log"
hydrated kept-fail 0 0
if [[ ${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-0} == 1 ]]; then
  # The earlier checks stored modules, and the heap the first one published
  # loads none.
  restore_kept
  find "$worker_cache/theory-modules" -mindepth 2 -maxdepth 2 -type f -name '[0-9a-fA-F]*-*' | grep -q . ||
    { echo "the host stored no theory module" >&2; exit 1; }
  run_spec kept-short keep
  expect_worker kept-short 3 "status=failed" "failure=internal"
  cat "$tmpdir/kept-short.result" "$tmpdir/kept-short.log" > "$tmpdir/kept-short.both"
  require_grep "the dependencies installed differ from the records the build started from" "$tmpdir/kept-short.both"
fi
restore_kept
write_t "ALL_TAC >> ALL_TAC >> ALL_TAC >> ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
worker kept-stale keep
expect_worker kept-stale 3 "status=failed" "failure=internal"
cat "$tmpdir/kept-stale.result" "$tmpdir/kept-stale.log" > "$tmpdir/kept-stale.both"
require_grep "the dependencies installed differ from the records the build started from" "$tmpdir/kept-stale.both"
worker kept-retry keep
expect_worker kept-retry 0 "status=built"

# A light check leaves what an earlier action installed in the worker's
# root, though its spec doesn't name it: a failing one never prunes the root;
# a passing one prunes it as it installs.  Here T drops C, which the host
# holds from the checks above.
cp -a "$worker_cache" "$tmpdir/worker.with-c"
write_toml
sed -i '/^\[actions\.TTheory\]/,$d' "$project/holproject.toml"
write_t 'FAIL_TAC "without C"'
worker drop-c-first
expect_worker drop-c-first 1 "status=failed" "failure=proof"
c_files() { find "$worker_cache" -path '*/obj/src/CTheory.dat' | grep -q .; }
rm -rf "$worker_cache"
cp -a "$tmpdir/worker.with-c" "$worker_cache"
c_files || { echo "the host holds no copy of C" >&2; exit 1; }
# Nor may it decline the heap, which would install first.
rm -rf "$worker_cache/theory-modules"
write_t 'ALL_TAC >> FAIL_TAC "resumed without C"'
worker drop-c-fail keep
expect_worker drop-c-fail 1 "status=failed" "failure=proof"
require_grep "resumed without C" "$tmpdir/drop-c-fail.log"
! phases drop-c-fail | grep -q "^hydprune" ||
  { echo "a failing light check pruned the root" >&2; cat "$tmpdir/drop-c-fail.result" >&2; exit 1; }
c_files || { echo "a failing light check removed C" >&2; exit 1; }
write_t "ALL_TAC >> ACCEPT_TAC TRUTH"
worker drop-c-pass keep
expect_worker drop-c-pass 0 "status=built"
require_grep "from: failed-prefix checkpoint in t2" "$tmpdir/drop-c-pass.log"
phases drop-c-pass | grep -qx "hydprunen:[1-9][0-9]*" ||
  { echo "a passing light check did not prune the root" >&2; cat "$tmpdir/drop-c-pass.result" >&2; exit 1; }
! c_files || { echo "a passing light check kept C" >&2; exit 1; }

# A light check writes its own files over what an earlier action left in
# their way: here an input file where it now needs a directory, and back.
write_toml
printf 'extra_inputs = ["data/x"]\n' >> "$project/holproject.toml"
mkdir -p "$project/data"
echo file > "$project/data/x"
write_t 'FAIL_TAC "input file"'
worker input-file
expect_worker input-file 1 "status=failed" "failure=proof"
rm "$project/data/x"
mkdir "$project/data/x"
echo nested > "$project/data/x/y"
write_toml
printf 'extra_inputs = ["data/x/y"]\n' >> "$project/holproject.toml"
worker input-dir keep
expect_worker input-dir 1 "status=failed" "failure=proof"
rm -r "$project/data/x"
echo file > "$project/data/x"
write_toml
printf 'extra_inputs = ["data/x"]\n' >> "$project/holproject.toml"
worker input-back keep
expect_worker input-back 1 "status=failed" "failure=proof"
