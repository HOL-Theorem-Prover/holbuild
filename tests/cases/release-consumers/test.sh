#!/usr/bin/env bash
set -euo pipefail
root=${HOLBUILD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
python3 - "$root/.github/workflows/release.yml" <<'PY'
import sys
from pathlib import Path

import yaml

jobs = yaml.safe_load(Path(sys.argv[1]).read_text())["jobs"]
needs = jobs["publish"]["needs"]
assert "consumers" in (needs if isinstance(needs, list) else [needs]), "publication must require consumers"
tag_only = {
    "startsWith(github.ref, 'refs/tags/v') && github.event_name == 'push'",
}
assert jobs["consumers"].get("if") in tag_only
assert jobs["consumers"]["permissions"]["contents"] == "read"
assert "secrets.HOLBUILD_REMOTE_" not in str(yaml.safe_load(Path(sys.argv[1]).read_text()).get("env", {}))
for name, job in jobs.items():
    if "secrets.HOLBUILD_REMOTE_" in str(job):
        assert job.get("if") in tag_only, f"{name} can expose service credentials outside tag runs"
guard = jobs["guard"]["steps"][-1]["run"]
assert guard.index("release-consumers-verified.sh") < guard.index("^Consumers ready:"), "readiness must not bypass consumer evidence"
print("release workflow dependencies and credential isolation checks passed")
PY
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'echo "release-consumers test failed at line $LINENO" >&2; [[ ! -f $tmp/output ]] || tail -n 40 "$tmp/output" >&2' ERR
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test
export GIT_AUTHOR_EMAIL=test@example.org GIT_COMMITTER_EMAIL=test@example.org
export TEST_ROOT="$tmp"
mkdir -p "$tmp/bin" "$tmp/remotes/HOL-Theorem-Prover" "$tmp/remotes/verifereum"
git config --global url."file://$tmp/remotes/".insteadOf https://github.com/
git init -q -b main "$tmp/source"
echo fixture > "$tmp/source/fixture"
git -C "$tmp/source" add .
git -C "$tmp/source" commit -qm base
git -C "$tmp/source" tag -a v1.0.0 -m base
echo candidate >> "$tmp/source/fixture"
git -C "$tmp/source" commit -qam candidate
git -C "$tmp/source" tag -a v1.0.1 -m candidate
git clone -q --bare "$tmp/source" "$tmp/remotes/HOL-Theorem-Prover/holbuild.git"
for consumer in vyper-hol verifereum solidity-hol; do
  git clone -q --bare "$tmp/source" "$tmp/remotes/verifereum/$consumer.git"
done

cat > "$tmp/client" <<'CLIENT'
#!/usr/bin/env bash
set -euo pipefail
name=$(basename "$(dirname "$(dirname "$0")")")
version=${name#holbuild-v}
version=${version%-linux-x86_64}
if [[ $* == --version ]]; then
  if [[ $version == 1.0.1 ]]; then version=${TEST_CANDIDATE_VERSION:-$version}; fi
  echo "holbuild $version"; exit
fi
consumer=$(basename "$PWD")
printf '%s %s %s\n' "$consumer" "$version" "$*" >> "$TEST_ROOT/trace"
case $1 in
  build)
    [[ $* == 'build --skip-proof-steps --remote-only --remote-exec https://fleet.invalid' ]]
    [[ -f $HOLBUILD_REMOTE_EXEC_CURL_CONFIG && -f $HOLBUILD_REMOTE_CACHE_CURL_CONFIG ]]
    [[ ${TEST_FAIL_CONSUMER:-} != "$consumer" && ${TEST_TOOLCHAIN_MISS:-} != "$consumer" ]] || exit 75
    ;;
  *) exit 98 ;;
esac
CLIENT
chmod +x "$tmp/client"
for version in 1.0.1; do
  name="holbuild-v$version-linux-x86_64"
  mkdir -p "$tmp/package/$name/bin" "$tmp/assets-$version"
  cp "$tmp/client" "$tmp/package/$name/bin/holbuild"
  tar -czf "$tmp/assets-$version/$name.tar.gz" -C "$tmp/package" "$name"
  (cd "$tmp/assets-$version" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
done
mkdir -p "$tmp/source/download"
cp "$tmp/assets-1.0.1/"* "$tmp/source/download/"

cat > "$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ -z ${EXEC_CURL_CONFIG_CONTENT+x} && -z ${CACHE_CURL_CONFIG_CONTENT+x} ]]
[[ -z ${TEST_CURL_FAIL:-} ]] || exit 7
while [[ $1 != -K ]]; do shift; done
[[ $(stat -c '%a' "$2") == 600 ]]
case $3 in
  https://fleet.invalid/v1/queue) echo "${TEST_FLEET_STATUS:-200}" ;;
  https://cache.invalid/ac/*) echo "${TEST_CACHE_STATUS:-404}" ;;
  *) exit 99 ;;
esac
CURL
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/gh-trace"
case "$*" in
  'api --paginate '*'/actions/workflows/release.yml/runs?'*)
    [[ -z ${TEST_API_FAIL:-} ]] || exit 1
    if [[ ${TEST_RUN_FAILED:-} == 1 && $* == *status=success* ]]; then exit 0; fi
    if [[ -z ${TEST_NO_RUNS:-} ]]; then
      printf '42\t%s\t%s\n' "${TEST_RUN_TAG:-v1.0.1}" "${TEST_RUN_SHA:-$GITHUB_SHA}"
    fi ;;
  'api --paginate '*'/actions/runs/42/jobs?'*)
    [[ -z ${TEST_JOBS_FAIL:-} ]] || exit 1
    if [[ -z ${TEST_NO_JOB:-} ]]; then echo "${TEST_JOB_RESULT:-success}"; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
GH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export HOME="$tmp/home"
mkdir -p "$HOME"
export GITHUB_WORKSPACE="$tmp/source" GITHUB_SHA
GITHUB_SHA=$(git -C "$tmp/source" rev-parse HEAD)
export GITHUB_REF_NAME=v1.0.1 GH_REPO=HOL-Theorem-Prover/holbuild GH_TOKEN=fixture-only
export HOLBUILD_REMOTE_EXEC_URL=https://fleet.invalid HOLBUILD_REMOTE_CACHE_URL=https://cache.invalid
export EXEC_CURL_CONFIG_CONTENT='header = "fixture-auth"' CACHE_CURL_CONFIG_CONTENT='user = "fixture-auth"'
export RUNNER_TEMP="$tmp/run" GITHUB_STEP_SUMMARY="$tmp/summary"
mkdir -p "$RUNNER_TEMP"

check() {
  local want=$1 status=0
  shift
  rm -rf "$RUNNER_TEMP/release-consumers"
  : > "$tmp/trace"
  : > "$tmp/gh-trace"
  : > "$tmp/summary"
  env "$@" bash "$root/tools/release-consumer-check.sh" > "$tmp/output" 2>&1 || status=$?
  if [[ $status != "$want" ]]; then
    cat "$tmp/output" >&2
    echo "wanted status $want, got $status ($*)" >&2
    exit 1
  fi
  [[ -z $(find "$RUNNER_TEMP" -name '*.curl' -print -quit) ]]
  ! grep -q fixture-auth "$tmp/output" "$tmp/summary" "$tmp/trace"
}

check 0
for consumer in vyper-hol verifereum solidity-hol; do
  grep -q "$consumer main: .*$GITHUB_SHA" "$tmp/summary"
  grep -q "^$consumer 1.0.1 build --skip-proof-steps --remote-only" "$tmp/trace"
done
check 75 TEST_FAIL_CONSUMER=verifereum
! grep -q '^solidity-hol .* build ' "$tmp/trace"
check 75 TEST_TOOLCHAIN_MISS=vyper-hol
! grep -q '^verifereum .* build ' "$tmp/trace"
check 1 TEST_FLEET_STATUS=401
check 1 TEST_CACHE_STATUS=503
check 7 TEST_CURL_FAIL=1
check 1 EXEC_CURL_CONFIG_CONTENT=
check 1 CACHE_CURL_CONFIG_CONTENT=
check 2 GITHUB_REF_NAME=master
check 2 GITHUB_REF_NAME=v1.0.0
check 2 GITHUB_SHA=0000000000000000000000000000000000000000
check 2 TEST_CANDIDATE_VERSION=1.0.0
printf corrupt >> "$tmp/source/download/holbuild-v1.0.1-linux-x86_64.tar.gz"
check 1
! grep -q ' build ' "$tmp/trace"

verified() {
  local want=$1 status=0
  shift
  env "$@" bash "$root/tools/release-consumers-verified.sh" v1.0.1 "$GITHUB_SHA" > "$tmp/verified" 2>&1 || status=$?
  if [[ $status != "$want" ]]; then cat "$tmp/verified" >&2; exit 1; fi
}
verified 0
verified 0 TEST_RUN_FAILED=1
verified 1 TEST_RUN_TAG=v1.0.0
verified 1 TEST_RUN_SHA=0000000000000000000000000000000000000000
verified 1 TEST_JOB_RESULT=failure
verified 1 TEST_NO_JOB=1
verified 1 TEST_NO_RUNS=1
verified 1 TEST_API_FAIL=1
verified 1 TEST_JOBS_FAIL=1
echo 'release consumer success/failure/identity checks passed'
