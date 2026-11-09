#!/usr/bin/env bash
set -euo pipefail
HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

# exec-action builds a HOL toolchain from a repository it may not trust
# beyond the commit, so every program that comes from it runs confined:
# configuration, bin/build, the built bin/hol and Holmake, and the analyser
# compiled against it. Each tries to read the worker's credential and other
# toolchains, write worker state, and change modes outside its tree; a
# detached child must not outlive its step, and a link out of the tree fails
# the build. A fake Poly/ML runs scripts as shell, so tools/smart-configure.sml
# stands for any configuration code.

tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
unset HOLBUILD_REMOTE_CACHE_URL HOLBUILD_REMOTE_CACHE_CURL_CONFIG
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"

# A real action spec, pointed at the fake HOL below.
use_case_cache "$tmpdir/client"
mkdir -p "$tmpdir/project/src"
cat > "$tmpdir/project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "toolchain-sandbox"
[build]
members = ["src"]
TOML
cat > "$tmpdir/project/src/PlainScript.sml" <<'SML'
Theory Plain
Ancestors bool
Theorem plain: T
Proof
  simp[]
QED
SML
(cd "$tmpdir/project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload PlainTheory) > "$tmpdir/batch"
spec=$(awk '$1 == "action" && $5 == "toolchain-sandbox:PlainTheory" {print $4}' "$tmpdir/batch")
[[ -n "$spec" ]]

worker=$tmpdir/worker
secret=$tmpdir/cache.curl
outside=$tmpdir/outside
printf 'user = "sentinel:credential"\n' > "$secret"
chmod 600 "$secret"
printf 'original\n' > "$outside"
mkdir -p "$worker/hol-toolchains/sibling/hol/bin" "$worker/hol-toolchains/.locks" "$worker/actions"
printf 'original\n' > "$worker/hol-toolchains/sibling/hol/bin/hol"

hol=$tmpdir/hol
write_fake_hol "$hol"
cat >> "$hol/.gitignore" <<'EOF'
/attack-report
/detached.pid
/late-marker
/bin/hol.real
/bin/Holmake.real
EOF
cat > "$hol/tools/attack.sh" <<SH
#!/bin/sh
try() {
  name=\$1; shift
  if ("\$@") >/dev/null 2>&1; then echo "ALLOWED \$label \$name"; else echo "denied \$label \$name"; fi
}
label=\$1
try read-credential cat '$secret'
try read-sibling ls '$worker/hol-toolchains/sibling/hol'
try write-sibling sh -c 'echo planted > "\$1"' - '$worker/hol-toolchains/sibling/hol/bin/hol'
try write-lock sh -c 'echo planted > "\$1"' - '$worker/hol-toolchains/.locks/planted'
try write-actions sh -c 'echo planted > "\$1"' - '$worker/actions/planted'
try write-outside sh -c 'echo planted > "\$1"' - '$outside'
try chmod-credential chmod 644 '$secret'
try chmod-outside chmod 777 '$outside'
SH
cat > "$hol/tools/smart-configure.sml" <<'SH'
sh tools/attack.sh configure >> attack-report
SH
cat >> "$hol/bin/build" <<'SH'
sh tools/attack.sh build >> attack-report
# Modes change only within the tree, and never to setuid or setgid.
if chmod 4755 bin/build 2>/dev/null; then echo 'ALLOWED build setuid' >> attack-report; fi
# The repository is out of reach: a .git planted here is discarded, never run.
mkdir -p .git
printf '[core]\n\tfsmonitor = planted-monitor\n' > .git/config
# Scratch space is for files, not links.
if [ -d /tmp ] && ln -s /etc/passwd "/tmp/holbuild-toolchain-link.$$" 2>/dev/null; then
  rm -f "/tmp/holbuild-toolchain-link.$$"
  echo 'ALLOWED build scratch link' >> attack-report
fi
# A child that leaves the build's process group must still die with it.
setsid sh -c 'echo $$ > detached.pid; sleep 3; echo late > late-marker' </dev/null >/dev/null 2>&1 &
while [ ! -s detached.pid ]; do sleep 0.05; done
for tool in hol Holmake; do
  mv "bin/$tool" "bin/$tool.real"
  printf '#!/bin/sh\nsh "$(dirname "$0")/../tools/attack.sh" %s >&2\nexec "$0.real" "$@"\n' "$tool" > "bin/$tool"
  chmod +x "bin/$tool"
done
if [ -e escape ]; then ln -s "$(cat escape)" leak; fi
# Creating a file setuid needs no chmod; the tree check catches it.
if [ -e setuid ]; then python3 -c 'import os; os.close(os.open("bin/suid", os.O_CREAT | os.O_WRONLY, 0o4755))'; fi
SH
hol_rev=$(init_git_repo "$hol")

fakebin=$tmpdir/fakebin
write_fake_poly "$fakebin"
cat > "$fakebin/poly" <<'SH'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = -v ]; then
  printf 'Poly/ML 1.0 Release    RTS version: Fake-1.0 (Git version v1.0)\n'
  exit 0
fi
if [ "${1:-}" = --script ]; then sh "$2"; fi
: > configured
SH
# The analyser compiler links code from the toolchain, and the analyser runs
# it; both try the attacks.
cat > "$fakebin/polyc" <<'SH'
#!/usr/bin/env sh
set -eu
out=
for arg in "$@"; do [ "${prev:-}" = -o ] && out=$arg; prev=$arg; done
sh "$HOLBUILD_HOLDIR/tools/attack.sh" polyc > "$(dirname "$out")/polyc-report"
cat > "$out" <<ANALYSER
#!/bin/sh
sh $HOLBUILD_HOLDIR/tools/attack.sh analyser
if [ "\${1:-}" = --version ]; then
  printf 'holbuild-hol-analyser holbuild-hol-analyser-v2\\n'
  exit 0
fi
response=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --response) response=\$2; shift 2 ;;
    *) shift ;;
  esac
done
printf 'version 1\\nok\\nend\\n' > "\$response"
ANALYSER
chmod +x "$out"
SH
chmod +x "$fakebin/polyc"
# This one leaves a link out of its output directory and tries to vouch for
# the build itself.
sed 's|^chmod +x "\$out"$|&\nln -s /etc "$(dirname "$out")/up"\nif : > "$(dirname "$(dirname "$out")")/build.ok"; then echo ALLOWED polyc build.ok; fi 2>/dev/null|' \
  "$fakebin/polyc" > "$fakebin/polyc-bad"
chmod +x "$fakebin/polyc-bad"

retarget() {
  local rev=$1 hash
  sed "s|^toolchain git=[^ ]* rev=[^ ]* |toolchain git=$hol rev=$rev |" "$tmpdir/remote/cas/$spec" > "$tmpdir/spec"
  hash=$(sha256sum "$tmpdir/spec" | cut -d' ' -f1)
  mv "$tmpdir/spec" "$tmpdir/remote/cas/$hash"
  printf '%s\n' "$hash"
}
run_worker() {
  local cache=$1 target=$2 log=$3
  set +e
  HOLBUILD_CACHE=$cache HOLBUILD_POLY=$fakebin/poly HOLBUILD_POLYC=${POLYC:-$fakebin/polyc} \
    HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES="$hol=master" HOLBUILD_REMOTE_CACHE_CURL_CONFIG=$secret \
    HOLBUILD_COOPERATE_DIR= "$HOLBUILD_BIN" --max-heap 1024 --remote-cache "$remote_url" \
    exec-action "$target" --cache-limit-gb 1000 --result "$log.result" > "$log" 2>&1
  set -e
}
damage() {
  [[ $(cat "$secret") == 'user = "sentinel:credential"' && $(stat -c %a "$secret") == 600 ]] ||
    { echo 'credential changed' >&2; return 1; }
  [[ $(cat "$outside") == original && $(stat -c %a "$outside") == "$1" ]] || { echo 'outside file changed' >&2; return 1; }
  [[ $(cat "$worker/hol-toolchains/sibling/hol/bin/hol") == original ]] || { echo 'sibling toolchain changed' >&2; return 1; }
  [[ ! -e "$worker/hol-toolchains/.locks/planted" && ! -e "$worker/actions/planted" ]] ||
    { echo 'worker state planted' >&2; return 1; }
  if grep -rq 'sentinel:credential' "$worker" "$tmpdir/remote" 2>/dev/null; then
    echo 'credential copied' >&2; return 1
  fi
}
outside_mode=$(stat -c %a "$outside")

# A toolchain from this repository builds, but none of its attacks lands.
run_worker "$worker" "$(retarget "$hol_rev")" "$tmpdir/build.log"
entry=$(find "$worker/hol-toolchains" -mindepth 1 -maxdepth 1 -type d ! -name sibling ! -name .locks)
# Every toolchain step finished: only the spec's real toolchain can match.
require_grep "the toolchain's identity does not match the action text" "$tmpdir/build.log"
[[ -f "$entry/build.ok" && -f "$entry/hol-source.manifest.toml" ]]
for label in configure build; do
  [[ $(grep -c "^denied $label " "$entry/hol/attack-report") == 8 ]] ||
    { cat "$entry/hol/attack-report" >&2; exit 1; }
done
report=$(find "$entry/analysers" -name polyc-report)
[[ $(grep -c '^denied polyc ' "$report") == 8 ]] || { cat "$report" >&2; exit 1; }
if grep -h ALLOWED "$entry/hol/attack-report" "$report" "$tmpdir/build.log"; then exit 1; fi
damage "$outside_mode"
[[ ! -e "$entry/.git-bootstrap" ]]
if grep -q planted-monitor "$entry/hol/.git/config"; then echo 'a planted .git survived the build' >&2; exit 1; fi
[[ $(git -C "$entry/hol" rev-parse HEAD) == "$hol_rev" ]]
detached=$(cat "$entry/hol/detached.pid")
sleep 4
if kill -0 "$detached" 2>/dev/null; then echo 'detached child outlived the build' >&2; exit 1; fi
[[ ! -e "$entry/hol/late-marker" ]] || { echo 'detached child wrote after the build' >&2; exit 1; }

# Without its entry, the worker restores the published archive and runs its
# bin/hol confined. (HOL bakes in its path, so only the same cache root can.)
rm -rf "$entry"
run_worker "$worker" "$(retarget "$hol_rev")" "$tmpdir/restore.log"
require_grep "the toolchain's identity does not match the action text" "$tmpdir/restore.log"
[[ $(cat "$entry/hol/detached.pid") == "$detached" ]] || { echo 'the toolchain was rebuilt, not restored' >&2; exit 1; }
if grep ALLOWED "$tmpdir/restore.log"; then exit 1; fi
damage "$outside_mode"

# A rejected analyser build leaves nothing behind, so the next one starts
# afresh.
rm -rf "$entry/analysers"
POLYC=$fakebin/polyc-bad run_worker "$worker" "$(retarget "$hol_rev")" "$tmpdir/bad-analyser.log"
require_grep '^failure=internal$' "$tmpdir/bad-analyser.log.result"
if grep ALLOWED "$tmpdir/bad-analyser.log"; then exit 1; fi
[[ -z $(ls -A "$entry/analysers") ]] || { find "$entry/analysers" >&2; cat "$tmpdir/bad-analyser.log" >&2; exit 1; }
run_worker "$worker" "$(retarget "$hol_rev")" "$tmpdir/analyser-retry.log"
require_grep "the toolchain's identity does not match the action text" "$tmpdir/analyser-retry.log"
[[ -n $(find "$entry/analysers" -name build.ok) ]]

# A build that links out of its tree fails, and leaves nothing behind.
printf '%s\n' "$secret" > "$hol/escape"
git -C "$hol" add escape
git -C "$hol" commit -qm escape
escape_rev=$(git -C "$hol" rev-parse HEAD)
run_worker "$worker" "$(retarget "$escape_rev")" "$tmpdir/escape.log"
require_grep '^failure=internal$' "$tmpdir/escape.log.result"
[[ $(find "$worker/hol-toolchains" -mindepth 1 -maxdepth 1 -type d | wc -l) == 3 ]] ||
  { ls -la "$worker/hol-toolchains" >&2; cat "$tmpdir/escape.log" >&2; exit 1; }
damage "$outside_mode"

# So does one that creates a setuid file.
git -C "$hol" rm -q escape
: > "$hol/setuid"
git -C "$hol" add setuid
git -C "$hol" commit -qm setuid
run_worker "$worker" "$(retarget "$(git -C "$hol" rev-parse HEAD)")" "$tmpdir/setuid.log"
require_grep '^failure=internal$' "$tmpdir/setuid.log.result"
require_grep 'linked or special file: .*/bin/suid' "$tmpdir/setuid.log"
[[ $(find "$worker/hol-toolchains" -mindepth 1 -maxdepth 1 -type d | wc -l) == 3 ]] ||
  { ls -la "$worker/hol-toolchains" >&2; cat "$tmpdir/setuid.log" >&2; exit 1; }

# The analyser runs confined to a fresh directory, read only once checked.
analyser=$tmpdir/analysers/key/bin/holbuild-hol-analyser
mkdir -p "$(dirname "$analyser")" "$tmpdir/action" "$tmpdir/checkpoints"
cp "$hol/tools/attack.sh" "$tmpdir/analysers/key/attack.sh"
cat > "$analyser" <<SH
#!/bin/sh
sh '$tmpdir/analysers/key/attack.sh' analyser
setsid sh -c 'echo "detached \$\$"; exec sleep 30 > /dev/null' &
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --response) response=\$2; shift 2 ;;
    *) shift ;;
  esac
done
ln -s '$secret' "\$response.link" && echo 'ALLOWED analyser link'
ln '$secret' "\$response.hard" && echo 'ALLOWED analyser hard link'
echo 'version 1' > "\$response"
echo 'refused' >&2
SH
chmod +x "$analyser"
cat > "$tmpdir/analyse.sml" <<SML
use "sml/holbuild-script.sml";
val _ = HolbuildActionSandbox.enable ("$tmpdir/action", "$tmpdir/checkpoints");
val _ = HolbuildActionSandbox.poly_executable := HolbuildHolSharedCache.poly_executable_path ();
val {output, response, stderr} =
  HolbuildDependencies.run_analyser {analyser = "$analyser", request = "request\n", capture_stderr = true};
val _ = print output;
val _ = if response = SOME "version 1\n" andalso String.isSuffix "refused\n" stderr then ()
        else raise Fail "unexpected analyser response";
SML
(cd "$SCRIPT_DIR/../../.." && HOLBUILD_CACHE=$worker HOLBUILD_REMOTE_CACHE_CURL_CONFIG=$secret \
  "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/analyse.sml") > "$tmpdir/analyse.log" 2>&1 ||
  { cat "$tmpdir/analyse.log" >&2; exit 1; }
[[ $(grep -c '^denied analyser ' "$tmpdir/analyse.log") == 8 ]] || { cat "$tmpdir/analyse.log" >&2; exit 1; }
if grep ALLOWED "$tmpdir/analyse.log"; then exit 1; fi
detached=$(sed -n 's/^detached //p' "$tmpdir/analyse.log")
[[ -n "$detached" ]] && ! kill -0 "$detached" 2>/dev/null || { echo 'detached analyser child survived' >&2; exit 1; }
[[ -z $(find "$worker" -maxdepth 1 -name 'sandbox-*') ]] || { echo 'analyser work left behind' >&2; exit 1; }
damage "$outside_mode"

# An archive from elsewhere is checked the same way before anything runs it.
tree=$tmpdir/tree
mkdir -p "$tree/bin"
printf 'x\n' > "$tree/bin/file"
ln -s file "$tree/bin/inside"
validate() { python3 -I "$SCRIPT_DIR/../../../sml/action_sandbox.py" --validate-tree "$tree" > /dev/null 2>&1; }
validate || { echo 'a closed tree was rejected' >&2; exit 1; }
ln -s "$secret" "$tree/bin/leak"
if validate; then echo 'a link out of the tree was accepted' >&2; exit 1; fi
rm "$tree/bin/leak"
ln "$tree/bin/file" "$tree/bin/hard"
if validate; then echo 'a hard link was accepted' >&2; exit 1; fi
rm "$tree/bin/hard"
chmod u+s "$tree/bin/file"
if validate; then echo 'a setuid file was accepted' >&2; exit 1; fi
printf 'toolchain bootstrap, Holmake, bin/hol and analyser confined; escapes rejected\n'
