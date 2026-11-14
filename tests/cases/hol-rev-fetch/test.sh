#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A HOL toolchain pinned to a commit that no branch or tag holds, which a
# clone therefore leaves out but the server still serves by hash, as GitHub
# serves one from its fork network. exec-action's hardened fetch is checked in
# exec-action-toolchain-sandbox.

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
project=$tmpdir/project
write_fake_hol "$hol"
init_git_repo "$hol" > /dev/null
echo side > "$hol/side.txt"
git -C "$hol" add side.txt
git -C "$hol" commit -q --no-gpg-sign -m side
rev=$(git -C "$hol" rev-parse HEAD)
git -C "$hol" update-ref refs/hidden/side "$rev"
git -C "$hol" reset -q --hard HEAD~1
git -C "$hol" config uploadpack.allowReachableSHA1InWant true
write_fake_poly "$fakebin"
mkdir -p "$project"
# file:// clones over git's transport; a plain path would copy every object.
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "hol-rev-fetch-test"

[dependencies.hol]
git = "file://$hol"
rev = "$rev"
TOML

unset HOLDIR HOLBUILD_HOLDIR HOLBUILD_REMOTE_CACHE_URL
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc

(cd "$project" && "$HOLBUILD_BIN" --cache-dir "$tmpdir/cache" buildhol) > "$tmpdir/buildhol.log" 2>&1 ||
  { cat "$tmpdir/buildhol.log" >&2; exit 1; }
holdir=$(tail -n 1 "$tmpdir/buildhol.log")
[[ $(git -C "$holdir" rev-parse HEAD) == "$rev" && -f "$holdir/side.txt" ]] ||
  { echo "toolchain is not at the pinned commit: $holdir" >&2; exit 1; }
