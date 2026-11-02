#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# The global -j reaches HOL's bin/build when holbuild builds a toolchain,
# and stays out of the toolchain key.

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
project=$tmpdir/project
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
rev=$(init_git_repo "$hol")
write_fake_poly "$fakebin"
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "buildhol-jobs-test"

[dependencies.hol]
git = "$hol"
rev = "$rev"
TOML

unset HOLDIR HOLBUILD_HOLDIR HOLBUILD_REMOTE_CACHE_URL
export HOLBUILD_CANONICAL_HOL_GIT=$hol
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count

# holbuild [ARGS...] in the project with cache $cache; prints the last line.
run() {
  (cd "$project" && "$HOLBUILD_BIN" --cache-dir "$cache" "$@") > "$tmpdir/run.log" 2>&1 ||
    { cat "$tmpdir/run.log" >&2; exit 1; }
  tail -n 1 "$tmpdir/run.log"
}
last_build() { tail -n 1 "$build_count"; }

cache=$tmpdir/cache-jobs
jobs_holdir=$(run -j 3 buildhol)
[[ $(last_build) == "build -j 3 "* ]] || { echo "bin/build args: $(last_build)" >&2; exit 1; }

# Another -j reuses the same toolchain.
[[ $(run -j 5 buildhol) == "$jobs_holdir" ]]
[[ $(wc -l < "$build_count") -eq 1 ]]

# Without -j, bin/build gets no -j, and the toolchain key is the same.
cache=$tmpdir/cache-default
default_holdir=$(run buildhol)
[[ $(last_build) != *"-j"* ]] || { echo "bin/build args: $(last_build)" >&2; exit 1; }
[[ $(basename "$(dirname "$default_holdir")") == $(basename "$(dirname "$jobs_holdir")") ]]

# A cold toolchain bootstrap during build honours -j too.
cache=$tmpdir/cache-build
run -j 2 build > /dev/null
[[ $(last_build) == "build -j 2 "* ]] || { echo "bin/build args: $(last_build)" >&2; exit 1; }
