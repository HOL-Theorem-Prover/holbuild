#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# HOL records its directory with symlinks resolved, so Holmake --dirs names
# targets under the physical path.  A toolchain built under a cache root
# reached through a symlink must still list the source directories those
# targets lie in; it used to keep only the build-sequence roots.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
project=$tmpdir/project
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
mkdir -p "$hol/src/extra"
printf 'val extra = true\n' > "$hol/src/extra/Extra.sml"
# Like HOL's, this Holmake names --dirs targets under the physical directory.
cat >> "$hol/bin/build" <<'SH'
cat > bin/Holmake <<'HOLMAKE'
#!/usr/bin/env sh
set -eu
case "$*" in
  *--dirs*)
    printf '[\n  {\n    "node_id" : 0,\n    "target" : "%s/src/extra/Extra.sml",\n    "dependencies" : []\n  }\n]\n' "$(pwd -P)"
    ;;
esac
HOLMAKE
chmod +x bin/Holmake
SH
hol_rev=$(init_git_repo "$hol")
write_fake_poly "$fakebin"

mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "hol-source-symlinked-cache-test"

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"
TOML

cache_real=$tmpdir/cache-real
cache=$tmpdir/cache
mkdir -p "$cache_real"
ln -s "$cache_real" "$cache"

unset HOLDIR HOLBUILD_HOLDIR HOLBUILD_REMOTE_CACHE_URL
export HOLBUILD_CACHE=$cache
export HOLBUILD_CANONICAL_HOL_GIT=$hol
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count

buildhol() {
  local name=$1
  if ! (cd "$project" && "$HOLBUILD_BIN" buildhol) > "$tmpdir/$name.log" 2>&1; then
    echo "$name: buildhol failed" >&2
    cat "$tmpdir/$name.log" >&2
    exit 1
  fi
}

buildhol first
holdir=$(tail -n 1 "$tmpdir/first.log")
members=$(dirname "$holdir")/hol-source.members
manifest=$(dirname "$holdir")/hol-source.manifest.toml
require_file "$members"
if ! grep -qx "src/extra" "$members"; then
  echo "a symlinked cache root dropped Holmake's source directories" >&2
  cat "$members" >&2
  exit 1
fi

# A list that an earlier holbuild truncated is regenerated.
printf 'src/runtime\n' > "$members"
{ printf '# holbuild-hol-source-manifest-v3\n'; tail -n +2 "$manifest"; } > "$tmpdir/manifest"
mv "$tmpdir/manifest" "$manifest"
buildhol regenerate
[[ $(wc -l < "$build_count") -eq 1 ]]
if ! grep -qx "src/extra" "$members"; then
  echo "a truncated source member list from an earlier holbuild was kept" >&2
  cat "$members" >&2
  exit 1
fi
