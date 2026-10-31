#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Poly/ML's initial heap is 8 MB and the analyser reads a source as one
# allocation, so analysing a source of a few MB dies with "Run out of store -
# interrupting threads" unless the analyser is spawned with a heap floor. The
# fake analyser below fails the same way when its command line carries no heap
# floor large enough for the largest source in its request, so this test fails
# if holbuild stops passing one to every analyser process.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
project=$tmpdir/project
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
hol_rev=$(init_git_repo "$hol")
write_fake_poly "$fakebin"
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
[ -n "$out" ]
cat > "$out" <<'ANALYSER'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = --version ]; then
  printf 'holbuild-hol-analyser holbuild-hol-analyser-v2\n'
  exit 0
fi
request=
response=
minheap=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --minheap) minheap=$2; shift 2 ;;
    --request) request=$2; shift 2 ;;
    --response) response=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$request" ]
[ -n "$response" ]
[ -n "${HOLBUILD_TEST_ANALYSER_LOG:-}" ] || exit 73
largest=0
while read -r keyword id path _rest; do
  [ "$keyword" = file ] || continue
  size=$(wc -c < "$path" | tr -d ' ')
  if [ "$size" -gt "$largest" ]; then largest=$size; fi
done < "$request"
# Emulate the measured requirement: for a 2.3 MB source the real analyser
# failed at the 8 MB default and passed at 16 MB, so four times the largest
# source's size in MB is the floor this fake needs.
need_mb=$(( (largest / 262144) + 1 ))
if [ "${minheap:-8}" -lt "$need_mb" ]; then
  printf 'Run out of store - interrupting threads\nInterrupt\n' >&2
  exit 1
fi
printf 'largest=%s minheap=%s\n' "$largest" "$minheap" >> "$HOLBUILD_TEST_ANALYSER_LOG"
{
  printf 'version 1\nok\n'
  while read -r keyword id _rest; do
    [ "$keyword" = file ] || continue
    printf 'begin-file %s\nend-file %s\n' "$id" "$id"
  done < "$request"
  printf 'end\n'
} > "$response"
ANALYSER
chmod +x "$out"
SH
chmod +x "$fakebin/polyc"

mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "analyser-heap-floor-test"

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML
# A generated source the size of the one that kills the real analyser (2.3 MB).
awk 'BEGIN { for (i = 0; i < 140000; i++) printf "val v%d = %d : num;\n", i, i }' \
  > "$project/src/BigScript.sml"
big_bytes=$(wc -c < "$project/src/BigScript.sml" | tr -d ' ')
if [ "$big_bytes" -lt 2000000 ]; then
  echo "generated source is only $big_bytes bytes" >&2
  exit 1
fi

unset HOLDIR HOLBUILD_HOLDIR HOLBUILD_REMOTE_CACHE_URL
export HOLBUILD_CANONICAL_HOL_GIT=$hol
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count
analyser_log=$tmpdir/analyser.log
: > "$analyser_log"
export HOLBUILD_TEST_ANALYSER_LOG=$analyser_log

build_log=$tmpdir/build.log
if ! (cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory BigTheory) > "$build_log" 2>&1; then
  echo "planning a build with a large source failed" >&2
  cat "$build_log" >&2
  exit 1
fi
if [ ! -s "$analyser_log" ]; then
  echo "the build ran no analyser, so it proves nothing about the heap floor" >&2
  cat "$build_log" >&2
  exit 1
fi
# A run records only what it survived: the large source must have reached an
# analyser that had a heap floor.
if ! awk -v size="$big_bytes" '
    {
      largest = 0
      minheap = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^largest=/) { split($i, field, "="); largest = field[2] + 0 }
        if ($i ~ /^minheap=/) { split($i, field, "="); minheap = field[2] + 0 }
      }
      if (largest >= size && minheap > 0) found = 1
    }
    END { exit !found }
  ' "$analyser_log"; then
  echo "no analyser run saw the large source with a heap floor" >&2
  cat "$analyser_log" >&2
  cat "$build_log" >&2
  exit 1
fi
