#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A source's dependency analysis depends on the HOL sources the analyser is
# built against, so a cached analysis must not survive a HOL pin change: a
# worktree analysed under the old pin otherwise keeps the old facts and
# computes action keys that a fresh checkout and CI do not share.

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
  cat > "$project/holproject.toml" <<TOML
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
write_manifest "$first_rev"
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

plan() {
  local name=$1
  : > "$analyser_log"
  if ! (cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory) > "$tmpdir/$name.log" 2>&1; then
    echo "$name: planning the build failed" >&2
    cat "$tmpdir/$name.log" >&2
    exit 1
  fi
}

plan first
require_grep "AScript.sml" "$analyser_log"

plan cached
if grep -q "AScript.sml" "$analyser_log"; then
  echo "an unchanged source was analysed again under the same toolchain" >&2
  exit 1
fi

printf 'val changed_runtime = true\n' >> "$hol/src/runtime/Runtime.sml"
git -C "$hol" commit -qam change
write_manifest "$(git -C "$hol" rev-parse HEAD)"

plan new-hol
if ! grep -q "AScript.sml" "$analyser_log"; then
  echo "a HOL pin change reused the dependency analysis made under the old HOL" >&2
  exit 1
fi
