#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() {
  [[ -z ${server_pid:-} ]] || { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
unset HOLBUILD_OFFLINE HOLBUILD_REMOTE_CACHE_URL HOLBUILD_REMOTE_CACHE_CURL_CONFIG
use_case_cache "$tmpdir/cache"

# Record explicit clone/fetch and curl launches. Real HTTP requests (including
# libcurl) are recorded independently by the loopback cache server.
real_git=$(command -v git)
mkdir "$tmpdir/intercept"
export OFFLINE_ATTEMPTS=$tmpdir/attempts REAL_OFFLINE_GIT=$real_git
: > "$OFFLINE_ATTEMPTS"
cat > "$tmpdir/intercept/git" <<'GIT'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in clone|fetch) printf 'git %s\n' "$*" >> "$OFFLINE_ATTEMPTS"; exit 90 ;; esac
done
exec "$REAL_OFFLINE_GIT" "$@"
GIT
cat > "$tmpdir/intercept/curl" <<'CURL'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$OFFLINE_ATTEMPTS"
exit 90
CURL
chmod +x "$tmpdir/intercept/"*
blocked_path=$tmpdir/intercept:$PATH
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
export OFFLINE_URL=$remote_url OFFLINE_TMP=$tmpdir

expect_failure() {
  local log=$1 pattern=$2
  shift 2
  if "$@" > "$tmpdir/$log" 2>&1; then
    echo "unexpected success: $*" >&2; exit 1
  fi
  require_grep "$pattern" "$tmpdir/$log"
}
no_requests() {
  if [[ -s $OFFLINE_ATTEMPTS || -s $request_log ]]; then
    cat "$OFFLINE_ATTEMPTS" "$request_log" >&2
    echo "offline operation attempted network access" >&2
    exit 1
  fi
}

# Offline is accepted on local commands, and does not need a project.
(cd "$tmpdir" && "$HOLBUILD_BIN" --offline --version) > "$tmpdir/version"
require_grep '^holbuild [0-9]' "$tmpdir/version"
for command in build context buildhol action-spec exec-action import export clean gc cache heap executable check execution-plan; do
  (cd "$tmpdir" && "$HOLBUILD_BIN" --offline "$command" --help) > "$tmpdir/help-$command"
  (cd "$tmpdir" && "$HOLBUILD_BIN" "$command" --help) > "$tmpdir/online-help-$command"
  cmp "$tmpdir/help-$command" "$tmpdir/online-help-$command"
done
(cd "$tmpdir" && HOLBUILD_OFFLINE=1 "$HOLBUILD_BIN" --help) > "$tmpdir/help"
require_grep 'offline' "$tmpdir/help"

# Explicit remote options conflict before even looking for a manifest.
expect_failure cli-cache 'offline conflicts with explicit --remote-cache' \
  env PATH="$blocked_path" "$HOLBUILD_BIN" --offline --remote-cache "$remote_url" build
expect_failure env-cache 'offline conflicts with explicit --remote-cache' \
  env HOLBUILD_OFFLINE=1 PATH="$blocked_path" "$HOLBUILD_BIN" --remote-cache="$remote_url" build
expect_failure cli-exec 'offline conflicts with explicit --remote-exec' \
  env PATH="$blocked_path" "$HOLBUILD_BIN" --offline build --remote-exec "$remote_url"
expect_failure worker 'offline: cannot execute a remote action' \
  env PATH="$blocked_path" "$HOLBUILD_BIN" --offline exec-action missing
expect_failure upload 'offline: cannot upload action specs' \
  env PATH="$blocked_path" "$HOLBUILD_BIN" --offline action-spec --upload
no_requests

# Dependency materialization, including a mirror whose commit is already warm.
mkdir "$tmpdir/dep" "$tmpdir/project"
write_schema2_prelude > "$tmpdir/dep/holproject.toml"
printf '[project]\nname = "dep"\n' >> "$tmpdir/dep/holproject.toml"
rev=$(init_git_repo "$tmpdir/dep")
write_manifest() {
  cat > "$tmpdir/project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "offline"
[build]
members = ["src"]
[dependencies.dep]
git = "$tmpdir/dep"
rev = "$1"
TOML
}
write_manifest "$rev"
cd "$tmpdir/project"
expect_failure cold-dep 'offline: cannot materialize dependency dep at' \
  env PATH="$blocked_path" "$HOLBUILD_BIN" --offline context
require_grep 'run once without --offline' "$tmpdir/cold-dep"
no_requests
"$HOLBUILD_BIN" context > "$tmpdir/context-online"
HOLBUILD_OFFLINE=0 PATH="$blocked_path" "$HOLBUILD_BIN" --offline context > "$tmpdir/context-offline"
cmp "$tmpdir/context-online" "$tmpdir/context-offline"
mv .holbuild/src/dep "$tmpdir/saved-dep"
expect_failure warm-mirror 'offline: cannot materialize dependency dep at' \
  env HOLBUILD_OFFLINE=1 PATH="$blocked_path" "$HOLBUILD_BIN" context
no_requests
mv "$tmpdir/saved-dep" .holbuild/src/dep
write_manifest 0000000000000000000000000000000000000000
expect_failure wrong-rev 'offline: cannot materialize dependency dep at' \
  env PATH="$blocked_path" "$HOLBUILD_BIN" --offline context
[[ $(git -C .holbuild/src/dep rev-parse HEAD) == "$rev" ]]
write_manifest "$rev"
no_requests

# Cold and invalid HOL entries fail without replacing anything. Use fake HOL
# in a private cache, never the suite's shared installed toolchain.
write_fake_hol "$tmpdir/fake-hol"
fake_rev=$(init_git_repo "$tmpdir/fake-hol")
write_fake_poly "$tmpdir/fake-poly"
mkdir "$tmpdir/fake-project"
cat > "$tmpdir/fake-project/holproject.toml" <<TOML
[project]
name = "offline-toolchain"
[dependencies.hol]
git = "$tmpdir/fake-hol"
rev = "$fake_rev"
TOML
(
  cd "$tmpdir/fake-project"
  export HOLBUILD_CACHE=$tmpdir/fake-cache HOLBUILD_POLY=$tmpdir/fake-poly/poly
  export HOLBUILD_POLYC=$tmpdir/fake-poly/polyc HOLBUILD_TEST_BUILD_COUNT=$tmpdir/build-count
  expect_failure cold-hol "offline: cannot prepare HOL toolchain $fake_rev" \
    env PATH="$blocked_path" HOLBUILD_REMOTE_CACHE_URL="$remote_url" "$HOLBUILD_BIN" --offline buildhol
  no_requests
  "$HOLBUILD_BIN" buildhol > "$tmpdir/fake-buildhol"
  fake_holdir=$(tail -n 1 "$tmpdir/fake-buildhol")
  fake_entry=$(dirname "$fake_holdir")
  # Valid entries may rebuild local metadata and the analyser offline.
  rm "$fake_entry/hol-source.manifest.toml" "$fake_entry/hol-source.members"
  mv "$fake_entry/analysers" "$tmpdir/old-analysers"
  PATH="$blocked_path" "$HOLBUILD_BIN" --offline buildhol > "$tmpdir/fake-offline"
  [[ $(tail -n 1 "$tmpdir/fake-offline") == "$fake_holdir" ]]
  require_file "$fake_entry/hol-source.manifest.toml"
  [[ $(wc -l < "$tmpdir/build-count") == 1 ]]
  # An invalid entry must survive refusal byte for byte.
  printf 'sentinel\n' > "$fake_entry/sentinel"
  rm "$fake_holdir/bin/hol.state"
  expect_failure invalid-hol "offline: cannot repair HOL toolchain $fake_rev" \
    env PATH="$blocked_path" "$HOLBUILD_BIN" --offline buildhol
  require_grep '^sentinel$' "$fake_entry/sentinel"
  [[ $(wc -l < "$tmpdir/build-count") == 1 ]]
  no_requests
)

# Fully materialized real HOL build: remote settings are ignored before client
# setup, even a nonexistent curl config or libcurl library. Then restore the
# new theory from the local artifact cache after deleting project outputs.
mkdir src
cat > src/AScript.sml <<'SML'
Theory A
Ancestors bool
Theorem a:
  T
Proof
  simp[]
QED
SML
cat > .holconfig.toml <<TOML
[remote_cache]
url = "$remote_url"
curl_config = "$tmpdir/nonexistent-config"
TOML
export HOLBUILD_REMOTE_CACHE_URL=$remote_url HOLBUILD_REMOTE_CACHE_CURL_CONFIG=$tmpdir/also-missing
export HOLBUILD_TEST_LIBCURL=$tmpdir/nonexistent-libcurl
PATH="$blocked_path" "$HOLBUILD_BIN" --offline build ATheory > "$tmpdir/build" 2>&1
require_file .holbuild/obj/src/ATheory.dat
PATH="$blocked_path" "$HOLBUILD_BIN" --offline clean ATheory > "$tmpdir/clean"
HOLBUILD_OFFLINE=1 HOLBUILD_CACHE_TRACE=1 PATH="$blocked_path" \
  "$HOLBUILD_BIN" build ATheory > "$tmpdir/reuse" 2>&1
require_file .holbuild/obj/src/ATheory.dat
require_grep 'cache hit' "$tmpdir/reuse"
no_requests
unset HOLBUILD_REMOTE_CACHE_URL HOLBUILD_REMOTE_CACHE_CURL_CONFIG HOLBUILD_TEST_LIBCURL

# Actual lazy-fetch fixture: delete a loose commit from a promisor repository.
# The online control must invoke the upload-pack interceptor and retrieve it.
mkdir "$tmpdir/promisor-origin"
printf 'payload\n' > "$tmpdir/promisor-origin/file"
promisor_rev=$(init_git_repo "$tmpdir/promisor-origin")
"$real_git" clone -q --no-local "$tmpdir/promisor-origin" "$tmpdir/promisor"
# Unpack the cloned pack so exactly the commit can be removed.
# unpack-objects skips objects already packed: use an empty objects directory.
mv "$tmpdir/promisor/.git/objects" "$tmpdir/packed-objects"
mkdir "$tmpdir/promisor/.git/objects"
"$real_git" -C "$tmpdir/promisor" unpack-objects < "$(echo "$tmpdir/packed-objects/pack/"*.pack)"
"$real_git" -C "$tmpdir/promisor" config remote.origin.promisor true
"$real_git" -C "$tmpdir/promisor" config remote.origin.partialclonefilter blob:none
cat > "$tmpdir/upload-pack" <<'UPLOAD'
#!/bin/sh
printf 'lazy-fetch\n' >> "$OFFLINE_ATTEMPTS"
exec git-upload-pack "$@"
UPLOAD
chmod +x "$tmpdir/upload-pack"
"$real_git" -C "$tmpdir/promisor" config remote.origin.uploadpack "$tmpdir/upload-pack"
commit_object=$tmpdir/promisor/.git/objects/${promisor_rev:0:2}/${promisor_rev:2}
rm "$commit_object"
"$real_git" -C "$tmpdir/promisor" cat-file -e "$promisor_rev^{commit}"
require_grep 'lazy-fetch' "$OFFLINE_ATTEMPTS"
# Fetch produces a pack; return to the same missing-object state.
rm -r "$tmpdir/promisor/.git/objects"
mkdir "$tmpdir/promisor/.git/objects"
"$real_git" -C "$tmpdir/promisor" unpack-objects < "$(echo "$tmpdir/packed-objects/pack/"*.pack)"
rm "$commit_object"
: > "$OFFLINE_ATTEMPTS"
export OFFLINE_PROMISOR_REV=$promisor_rev

# Exercise alternate callers directly, rather than relying only on config
# suppression. Both HTTP transports and every coordinator operation are gated.
cat > "$tmpdir/direct.sml" <<'SML'
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
val tmp = valOf (OS.Process.getEnv "OFFLINE_TMP");
val url = valOf (OS.Process.getEnv "OFFLINE_URL");
val revision = valOf (OS.Process.getEnv "OFFLINE_PROMISOR_REV");
fun assert label yes = if yes then () else raise Fail label;
fun denied label f =
  assert label ((f (); false) handle HolbuildOffline.Error _ => true);
val _ = HolbuildHttp.setup {user = NONE};
val _ = HolbuildOffline.enable ();
val _ = HolbuildRemoteCacheConfig.set_url url;
val _ = HolbuildRemoteCacheConfig.setup_client ();
val _ = assert "configured remote not suppressed" (HolbuildRemoteCacheConfig.url () = NONE);
val _ = denied "HTTP setup" (fn () => HolbuildHttp.setup {user = NONE});
val _ = denied "libcurl GET" (fn () => ignore (HolbuildHttp.get {url=url, dst=tmp ^ "/get", timeout=1}));
val _ = denied "libcurl HEAD" (fn () => ignore (HolbuildHttp.head {url=url, timeout=1}));
val _ = denied "libcurl PUT" (fn () => ignore (HolbuildHttp.put {url=url, src=tmp ^ "/version", headers=[], timeout=1}));
val _ = HolbuildRemoteCacheConfig.libcurl_ready := SOME false;
val _ = assert "curl CLI"
  (case HolbuildRemoteCache.curl_get {url=url, dst=tmp ^ "/cli-get"} of
       HolbuildCacheBackend.Corrupt message => String.isSubstring "offline" message
     | _ => false);
val _ = denied "submit" (fn () => ignore (HolbuildRemoteExec.submit url NONE "batch"));
val _ = denied "follow" (fn () => ignore (HolbuildRemoteExec.follow url "batch" (fn _ => ())));
val _ = denied "cancel" (fn () => ignore (HolbuildRemoteExec.cancel url "batch"));
val _ = denied "restore" (fn () => ignore (HolbuildHolSharedCache.restore_entry "missing"));
val missing = ((ignore (HolbuildGitCache.verify_commit (tmp ^ "/promisor") revision); false)
               handle HolbuildGitCache.Error _ => true);
val _ = assert "missing commit unexpectedly fetched" missing;
val _ = OS.Process.exit OS.Process.success;
SML
PATH="$blocked_path" "${HOLBUILD_POLY:-poly}" --script "$tmpdir/direct.sml" > "$tmpdir/direct.log" 2>&1 ||
  { cat "$tmpdir/direct.log" >&2; exit 1; }
no_requests
