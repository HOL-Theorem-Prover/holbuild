#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
mkdir -p "$tmpdir/repo"
printf base > "$tmpdir/repo/base"
base=$(init_git_repo "$tmpdir/repo")
git -C "$tmpdir/repo" checkout -qb unmerged
printf untrusted > "$tmpdir/repo/untrusted"
git -C "$tmpdir/repo" add untrusted
git -C "$tmpdir/repo" commit -qm unmerged
unmerged=$(git -C "$tmpdir/repo" rev-parse HEAD)
git -C "$tmpdir/repo" update-ref refs/pull/1/head "$unmerged"
git -C "$tmpdir/repo" tag -am annotated annotated "$base"
tag=$(git -C "$tmpdir/repo" rev-parse annotated)
export HOLBUILD_CACHE=$tmpdir/cache
export HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES="$tmpdir/repo=master"
export HOLBUILD_TRUST_TEST_REPO=$tmpdir/repo
cat > "$tmpdir/check.sml" <<'SML'
use "sml/holbuild-script.sml";
val repository = valOf (OS.Process.getEnv "HOLBUILD_TRUST_TEST_REPO");
val revision = valOf (OS.Process.getEnv "HOLBUILD_TRUST_TEST_REV");
val expected = valOf (OS.Process.getEnv "HOLBUILD_TRUST_TEST_RESULT");
val actual =
  (HolbuildActionSandbox.require_trusted_repository {git = repository, rev = revision}; "accepted")
  handle HolbuildActionSandbox.Rejected _ => "rejected"
       | HolbuildActionSandbox.Error _ => "configuration";
val _ = if actual = expected then () else raise Fail ("expected " ^ expected ^ ", got " ^ actual);
SML
check() {
  (cd "$ROOT" && HOLBUILD_TRUST_TEST_REV="$1" HOLBUILD_TRUST_TEST_RESULT="$2" \
    "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/check.sml") > "$tmpdir/check.log" 2>&1 ||
    { cat "$tmpdir/check.log" >&2; exit 1; }
}
check "$base" accepted
check "$unmerged" rejected
check "$tag" rejected
check not-a-revision rejected
graph=$(find "$tmpdir/cache/toolchain-trust" -mindepth 1 -maxdepth 1 -type d)
[[ $(git -C "$graph" for-each-ref --format='%(refname)') == refs/heads/master ]]
# Merely having an untrusted object in the graph must not confer trust.
git -C "$graph" fetch -q --no-tags "$tmpdir/repo" "$unmerged"
check "$unmerged" rejected
git -C "$graph" fetch -q --no-tags "$tmpdir/repo" "$tag"
check "$tag" rejected
# A newly advanced approved branch makes its ancestors acceptable on refresh.
git -C "$tmpdir/repo" update-ref refs/heads/master "$unmerged"
check "$unmerged" accepted
# Only currently configured branches confer trust, even if old refs remain.
HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES="$tmpdir/repo=missing" check "$base" configuration
HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES="$tmpdir/repo=../pull/1/head" check "$base" configuration
HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES='' check "$base" configuration
HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES='/unconfigured=master' check "$base" rejected
# "*" trusts any https repository, but only at an exact commit.
any=0123456789abcdef0123456789abcdef01234567
https_repo=https://example.invalid/HOL.git
HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES='*' HOLBUILD_TRUST_TEST_REPO=$https_repo check "$any" accepted
HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES='*' HOLBUILD_TRUST_TEST_REPO=$https_repo check 0123456 rejected
HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES='*' HOLBUILD_TRUST_TEST_REPO=$https_repo check master rejected
HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES='*' check "$base" rejected
HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES='*' HOLBUILD_TRUST_TEST_REPO=http://example.invalid/HOL.git check "$any" rejected
printf 'trusted ancestry accepted; unmerged, tag, malformed and unconfigured revisions denied; * accepts only exact https commits\n'
