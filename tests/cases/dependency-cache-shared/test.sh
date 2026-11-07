#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A source's dependency analysis is kept in the project and in the shared
# cache, so another checkout of the same sources does not analyse them again.
# The analysis depends on the HOL sources the analyser is built against, so
# neither copy may survive a HOL pin change: a worktree analysed under the old
# pin otherwise keeps the old facts and computes action keys that a fresh
# checkout and CI do not share.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
project=$tmpdir/project
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
first_rev=$(init_git_repo "$hol")
write_fake_poly "$fakebin"
# An analyser that records each source it is asked about.
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) request=$2; shift 2 ;;
    --response) response=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$request" ]
[ -n "$response" ]
{
  printf 'version 1\nok\n'
  while read -r keyword id path _rest; do
    [ "$keyword" = file ] || continue
    printf '%s\n' "$path" >> "${HOLBUILD_TEST_ANALYSER_LOG:?}"
    printf 'begin-file %s\nend-file %s\n' "$id" "$id"
  done < "$request"
  printf 'end\n'
} > "$response"
ANALYSER
chmod +x "$out"
SH
chmod +x "$fakebin/polyc"

write_manifest() {
  cat > "$2/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "dependency-cache-toolchain-test"

[dependencies.hol]
git = "$hol"
rev = "$1"

[build]
members = ["src"]
TOML
}

mkdir -p "$project/src"
write_manifest "$first_rev" "$project"
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML

unset HOLDIR HOLBUILD_HOLDIR HOLBUILD_REMOTE_CACHE_URL
export HOLBUILD_CACHE=$tmpdir/cache
export HOLBUILD_CANONICAL_HOL_GIT=$hol
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count
analyser_log=$tmpdir/analyser.log
export HOLBUILD_TEST_ANALYSER_LOG=$analyser_log

shared=$HOLBUILD_CACHE/analysis

plan() {
  local name=$1 dir=${2:-$project}
  : > "$analyser_log"
  if ! (cd "$dir" && "$HOLBUILD_BIN" build --dry-run ATheory) > "$tmpdir/$name.log" 2>&1; then
    echo "$name: planning the build failed" >&2
    cat "$tmpdir/$name.log" >&2
    exit 1
  fi
}

# A copy of the project with no .holbuild of its own.
fresh_copy() {
  rm -rf "$1"
  mkdir -p "$1"
  cp -R "$project/src" "$project/holproject.toml" "$1/"
}

require_analysed() {
  grep -q "AScript.sml" "$analyser_log" || { echo "$1" >&2; exit 1; }
}

require_not_analysed() {
  if grep -q "AScript.sml" "$analyser_log"; then echo "$1" >&2; exit 1; fi
}

plan first
require_analysed "the first plan did not analyse its source"
[ "$(find "$shared" -type f | wc -l)" -eq 1 ] || { echo "expected one shared analysis entry" >&2; find "$shared" >&2; exit 1; }
first_entry=$(find "$shared" -type f)

plan cached
require_not_analysed "an unchanged source was analysed again under the same toolchain"

fresh_copy "$tmpdir/copy"
plan copy "$tmpdir/copy"
require_not_analysed "a fresh copy of the project analysed a source the shared cache holds"
require_grep "analyser=" "$tmpdir/copy/.holbuild/obj/src/AScript.uo.deps"

# An entry written by another extractor version is not used.
sed -i 's/^extractor=.*/extractor=another-extractor/' "$first_entry"
fresh_copy "$tmpdir/other-extractor"
plan other-extractor "$tmpdir/other-extractor"
require_analysed "a shared analysis from another extractor version was used"

printf 'val changed_runtime = true\n' >> "$hol/src/runtime/Runtime.sml"
git -C "$hol" commit -qam change
write_manifest "$(git -C "$hol" rev-parse HEAD)" "$project"

plan new-hol
require_analysed "a HOL pin change reused the dependency analysis made under the old HOL"
[ "$(find "$shared" -type f | wc -l)" -eq 2 ] || { echo "expected a shared entry per HOL pin" >&2; find "$shared" >&2; exit 1; }

# gc removes the entries no checkout has used within the retention period.
touch -d '30 days ago' "$first_entry"
"$HOLBUILD_BIN" gc --cache-only > "$tmpdir/gc.log" 2>&1
require_grep "analysis=1" "$tmpdir/gc.log"
[ ! -e "$first_entry" ] || { echo "gc kept a stale shared analysis" >&2; exit 1; }
[ "$(find "$shared" -type f | wc -l)" -eq 1 ] || { echo "gc removed a shared analysis in use" >&2; find "$shared" >&2; exit 1; }
