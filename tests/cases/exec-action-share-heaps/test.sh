#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action --share-heaps: a worker whose local heap, checkpoints and store
# are gone resumes from the heap and checkpoints an earlier run published,
# and builds the same outputs as a cold worker does.

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

# Two remote caches: the sharing worker's, and a cold worker's to compare.
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
name = "share"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML

# write_t FIRST LAST: theory T, its first theorem's statement and its last
# theorem's proof varied.
write_t() {
  cat > "$project/src/TScript.sml" <<SML
Theory T
Ancestors A

Theorem t1:
  $1
Proof
  simp[]
QED

Theorem t2:
  T /\\ T
Proof
  ACCEPT_TAC (CONJ a_thm a_thm)
QED

Theorem t3:
  T /\\ (1 = 1)
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $2
QED
SML
}

# worker NAME URL CACHE [OPTION...]: exec-action of T's current spec on the
# cache root CACHE; the record goes to $tmpdir/NAME.result.
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

field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }

shared=$tmpdir/worker-shared
cold=$tmpdir/worker-cold

# export VERSION: T's spec in both remote caches, and A built in both.
export_t() {
  local version=$1 url
  for url in "$shared_url" "$cold_url"; do
    (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload TTheory) \
      > "$tmpdir/batch-$version-${url##*:}.txt"
  done
  batch=$tmpdir/batch-$version-${shared_url##*:}.txt
  spec_t=$(field "$batch" share:TTheory 4)
  ac_t=$(field "$batch" share:TTheory 3)
  spec_a=$(field "$batch" share:ATheory 4)
  if [[ -n "$spec_a" ]]; then
    worker "a-shared-$version" "$shared_url" "$shared" "$spec_a" --share-heaps
    expect "a-shared-$version" 0 "status=built"
    worker "a-cold-$version" "$cold_url" "$cold" "$spec_a"
    expect "a-cold-$version" 0 "status=built"
  fi
  [[ -n "$spec_t" ]] || { cat "$batch" >&2; exit 1; }
}

# cold VERSION CODE: T built from scratch on the cold remote.
cold() {
  rm -rf "$cold/checkpoints"
  worker "cold-$1" "$cold_url" "$cold" "$spec_t"
  expect "cold-$1" "$2"
}

# same_outputs VERSION: both remotes hold the same entry for T.
same_outputs() {
  cmp "$tmpdir/remote/ac/$ac_t" "$tmpdir/remote-cold/ac/$ac_t" || {
    echo "version $1: the sharing worker's outputs differ from a cold build's" >&2
    exit 1
  }
}

# Only the remote cache holds what an earlier run shared.
forget_local() { rm -rf "$shared/checkpoints" "$shared/checkpoint-store"; }

write_t "T" "simp[]"
export_t v1
worker v1 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v1 0 "status=built"
[[ -d "$shared/checkpoint-store" ]] || { echo "v1 added nothing to the store" >&2; exit 1; }
[[ ! -e "$shared/checkpoints" ]] || { echo "the private checkpoint tree outlived the action" >&2; exit 1; }

# An edit of the first theorem resumes from the shared heap alone.
write_t "T \\/ F" "simp[]"
export_t v2
cold v2 0
forget_local
worker v2 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v2 0 "status=built"
require_grep "restored shared deps-loaded heap" "$tmpdir/v2.log"
require_grep "from: deps-loaded checkpoint" "$tmpdir/v2.log"
same_outputs v2

# An edit of the last theorem resumes from the context after the one before.
write_t "T \\/ F" "REFL_TAC"
export_t v3
cold v3 0
forget_local
worker v3 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v3 0 "status=built"
require_grep "restored shared theorem_context checkpoint" "$tmpdir/v3.log"
require_grep "from: theorem-context checkpoint after t2" "$tmpdir/v3.log"
same_outputs v3

# A failed proof shares its failed prefix, and the fixed proof resumes from it.
write_t "T \\/ F" "FAIL_TAC \"seeded failure\""
export_t v4
worker v4 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v4 1 "status=failed" "failure=proof"
require_grep "seeded failure" "$tmpdir/v4.log"
write_t "T \\/ F" "rw[]"
export_t v5
cold v5 0
forget_local
worker v5 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v5 0 "status=built"
require_grep "restored shared failed_prefix checkpoint" "$tmpdir/v5.log"
require_grep "from: failed-prefix checkpoint in t3" "$tmpdir/v5.log"
same_outputs v5
