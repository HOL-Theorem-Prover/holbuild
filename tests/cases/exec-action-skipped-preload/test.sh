#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action --share-heaps: an edit that names a theory an earlier preload
# or hol.state already loads adds a preload HOL's loader skips, so the worker
# keeps the shared heap and checkpoints; one that changes what loads, or the
# order theories load in, loads afresh.

tmpdir=$(make_temp_dir)
server_pids=()
cleanup() {
  for pid in ${server_pids[@]+"${server_pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
server_pids+=("$server_pid")
shared_url=$remote_url
start_remote_cache_server "$tmpdir/remote-cold" "$tmpdir/server-cold"
server_pids+=("$server_pid")
cold_url=$remote_url
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "skip"

[build]
members = ["src"]
TOML
for thy in Alpha Beta Zed; do
  lower=$(tr '[:upper:]' '[:lower:]' <<< "$thy")
  cat > "$project/src/${thy}Script.sml" <<SML
Theory $thy
Ancestors bool

Theorem ${lower}_thm:
  T
Proof
  simp[]
QED
SML
done
# Mid loads Alpha, Beta and Zed, in that order.
cat > "$project/src/MidScript.sml" <<'SML'
Theory Mid
Ancestors Alpha Beta Zed

Theorem mid_thm:
  T
Proof
  ACCEPT_TAC zed_thm
QED
SML

# write_top ANCESTORS THIRD: theory Top, its third theorem's proof varied.
write_top() {
  cat > "$project/src/TopScript.sml" <<SML
Theory Top
Ancestors $1

Theorem t1:
  T
Proof
  simp[]
QED

Theorem t2:
  T /\\ T
Proof
  ACCEPT_TAC (CONJ mid_thm mid_thm)
QED

Theorem t3:
  T
Proof
  $2
QED
SML
}

worker() {
  local name=$1 url=$2 cache=$3 spec=$4
  shift 4
  link_hol_toolchain_cache "$cache"
  set +e
  HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$url" exec-action "$spec" \
    --cache-limit-gb 1000 --result "$tmpdir/$name.result" "$@" > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
}

expect() {
  local name=$1 code=$2
  shift 2
  if [[ "$worker_status" != "$code" ]]; then
    echo "worker $name exited $worker_status, wanted $code" >&2
    cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2 || true
    exit 1
  fi
  for line in "$@"; do
    grep -qxF -- "$line" "$tmpdir/$name.result" || {
      echo "worker $name result lacks '$line':" >&2
      cat "$tmpdir/$name.result" "$tmpdir/$name.log" >&2
      exit 1
    }
  done
}

shared=$tmpdir/worker-shared
cold=$tmpdir/worker-cold

# export VERSION: Top's spec in both remote caches, its dependencies built
# in both.
export_top() {
  local version=$1 url batch name spec
  for url in "$shared_url" "$cold_url"; do
    batch=$tmpdir/batch-$version-${url##*:}.txt
    (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload TopTheory) > "$batch"
    while read -r name spec; do
      worker "$name-$version-${url##*:}" "$url" "$tmpdir/deps-${url##*:}" "$spec"
      expect "$name-$version-${url##*:}" 0 "status=built"
    done < <(awk '$1 == "action" && $5 != "skip:TopTheory" { print $5, $4 }' "$batch")
  done
  batch=$tmpdir/batch-$version-${shared_url##*:}.txt
  spec_top=$(awk '$1 == "action" && $5 == "skip:TopTheory" { print $4 }' "$batch")
  ac_top=$(awk '$1 == "action" && $5 == "skip:TopTheory" { print $3 }' "$batch")
  [[ -n "$spec_top" ]] || { cat "$batch" >&2; exit 1; }
}

# run VERSION CODE: Top on the sharing worker with only what the remote
# cache holds, and from scratch on the cold one; both build the same entry.
run() {
  rm -rf "$shared/checkpoints" "$shared/checkpoint-store" "$cold/checkpoints"
  worker "$1" "$shared_url" "$shared" "$spec_top" --share-heaps
  expect "$1" "$2"
  [[ "$2" != 0 ]] || {
    worker "cold-$1" "$cold_url" "$cold" "$spec_top"
    expect "cold-$1" 0 "status=built"
    cmp "$tmpdir/remote/ac/$ac_top" "$tmpdir/remote-cold/ac/$ac_top" || {
      echo "version $1: the sharing worker's outputs differ from a cold build's" >&2
      exit 1
    }
  }
}

# resumed VERSION FROM: the sharing worker resumed from FROM and kept it.
resumed() {
  require_grep "from: $2" "$tmpdir/$1.log"
  if grep -q "discarding" "$tmpdir/$1.log"; then
    echo "version $1: the build discarded the restored state" >&2
    cat "$tmpdir/$1.log" >&2
    exit 1
  fi
}

# not_restored VERSION: the sharing worker restored nothing shared.
not_restored() {
  if grep -q "restored shared" "$tmpdir/$1.log"; then
    echo "version $1 restored state saved for another preload" >&2
    cat "$tmpdir/$1.log" >&2
    exit 1
  fi
}

write_top "Mid" "FAIL_TAC \"seeded failure\""
export_top v1
run v1 1

# The fix names Zed, which Mid loads: Zed's preload comes after Mid's and
# is skipped, so the fix resumes from the failed prefix.
write_top "Mid" "ACCEPT_TAC ZedTheory.zed_thm"
export_top v2
run v2 0
resumed v2 "failed-prefix checkpoint in t3"

# Likewise when the header imports Zed, though the changed header leaves
# only the heap of loaded dependencies to resume from.
write_top "Mid Zed" "ACCEPT_TAC ZedTheory.zed_thm"
export_top v3
run v3 0
resumed v3 "deps-loaded checkpoint"

# Beta's preload comes before Mid's, so it loads Beta ahead of Alpha: not
# the same session, so nothing is restored.
write_top "Mid" "ACCEPT_TAC BetaTheory.beta_thm"
export_top v4
run v4 0

not_restored v4

# hol.state loads optionTheory, so an import of it resumes from the heap of
# loaded dependencies, and a fix naming it from the failed prefix.  The
# import comes first: a heap saved with optionTheory in its preload would
# serve the fix too.
write_top "Mid" "FAIL_TAC \"seeded failure again\""
export_top v5
run v5 1
write_top "Mid option" "ACCEPT_TAC (K TRUTH optionTheory.NOT_NONE_SOME)"
export_top v6
run v6 0
resumed v6 "deps-loaded checkpoint"
write_top "Mid" "ACCEPT_TAC (K TRUTH optionTheory.NOT_NONE_SOME)"
export_top v7
run v7 0
resumed v7 "failed-prefix checkpoint in t3"

# hol.state doesn't load bitTheory, so naming it loads afresh.
write_top "Mid" "ACCEPT_TAC (K TRUTH bitTheory.BIT_ZERO)"
export_top v8
run v8 0
not_restored v8
