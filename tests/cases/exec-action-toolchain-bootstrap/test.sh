#!/usr/bin/env bash
set -euo pipefail
HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

# exec-action builds a HOL toolchain from a trusted repository at the spec's
# commit, publishes it, and restores the published archive on a worker
# without it. A .git the build plants is discarded, never run.

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
name = "toolchain-bootstrap"
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
spec=$(awk '$1 == "action" && $5 == "toolchain-bootstrap:PlainTheory" {print $4}' "$tmpdir/batch")
[[ -n "$spec" ]]

worker=$tmpdir/worker

hol=$tmpdir/hol
write_fake_hol "$hol"
printf '/build-stamp\n' >> "$hol/.gitignore"
# The fake Poly/ML runs configuration as shell.
echo true > "$hol/tools/smart-configure.sml"
cat >> "$hol/bin/build" <<'SH'
date +%s%N > build-stamp
# The repository is out of reach: a .git planted here is discarded, never run.
mkdir -p .git
printf '[core]\n\tfsmonitor = planted-monitor\n' > .git/config
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
cat > "$fakebin/polyc" <<'SH'
#!/usr/bin/env sh
set -eu
out=
for arg in "$@"; do [ "${prev:-}" = -o ] && out=$arg; prev=$arg; done
cat > "$out" <<ANALYSER
#!/bin/sh
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
  HOLBUILD_CACHE=$cache HOLBUILD_POLY=$fakebin/poly HOLBUILD_POLYC=$fakebin/polyc \
    HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES="$hol=master" \
    HOLBUILD_COOPERATE_DIR= timeout 300 "$HOLBUILD_BIN" --max-heap 1024 --remote-cache "$remote_url" \
    exec-action "$target" --cache-limit-gb 1000 --result "$log.result" > "$log" 2>&1
  set -e
}

# A toolchain from this repository builds.
run_worker "$worker" "$(retarget "$hol_rev")" "$tmpdir/build.log"
entry=$(find "$worker/hol-toolchains" -mindepth 1 -maxdepth 1 -type d ! -name .locks)
# Every toolchain step finished: only the spec's real toolchain can match.
require_grep "the toolchain's identity does not match the action text" "$tmpdir/build.log"
[[ -f "$entry/build.ok" && -f "$entry/hol-source.manifest.toml" ]]
[[ -n $(find "$entry/analysers" -name build.ok) ]]
[[ ! -e "$entry/.git-bootstrap" ]]
if grep -q planted-monitor "$entry/hol/.git/config"; then echo 'a planted .git survived the build' >&2; exit 1; fi
[[ $(git -C "$entry/hol" rev-parse HEAD) == "$hol_rev" ]]
stamp=$(cat "$entry/hol/build-stamp")

# Without its entry, the worker restores the published archive. (HOL bakes
# in its path, so only the same cache root can.)
rm -rf "$entry"
run_worker "$worker" "$(retarget "$hol_rev")" "$tmpdir/restore.log"
require_grep "the toolchain's identity does not match the action text" "$tmpdir/restore.log"
[[ $(cat "$entry/hol/build-stamp") == "$stamp" ]] || { echo 'the toolchain was rebuilt, not restored' >&2; exit 1; }

# Actions only read a built toolchain, so the worker does not recheck its
# checkout: one dirtied from outside still serves.
echo '# dirty' >> "$entry/hol/.gitignore"
run_worker "$worker" "$(retarget "$hol_rev")" "$tmpdir/dirty.log"
require_grep "the toolchain's identity does not match the action text" "$tmpdir/dirty.log"

# A published archive whose manifest is not a regular file is refused before
# anything reads it (a FIFO would block the reader for good).
python3 - "$tmpdir/remote" <<'PY'
import hashlib, io, pathlib, re, sys, tarfile
root = pathlib.Path(sys.argv[1])
name = ".holbuild-toolchain-archive-manifest"
for record in (root / "ac").rglob("*"):
    if not record.is_file():
        continue
    text = record.read_text(errors="replace")
    for old in set(re.findall(r"[0-9a-f]{64}", text)):
        blob = root / "cas" / old
        if not blob.is_file() or not tarfile.is_tarfile(blob):
            continue
        with tarfile.open(blob) as src:
            members = [(m, src.extractfile(m).read() if m.isreg() else None) for m in src.getmembers()]
        if not any(m.name.removeprefix("./") == name for m, _ in members):
            continue
        out = io.BytesIO()
        with tarfile.open(fileobj=out, mode="w") as dst:
            for member, data in members:
                if member.name.removeprefix("./") == name:
                    fifo = tarfile.TarInfo(member.name)
                    fifo.type = tarfile.FIFOTYPE
                    dst.addfile(fifo)
                else:
                    dst.addfile(member, None if data is None else io.BytesIO(data))
        data = out.getvalue()
        new = hashlib.sha256(data).hexdigest()
        (root / "cas" / new).write_bytes(data)
        text = text.replace(f"{old} {blob.stat().st_size}", f"{new} {len(data)}").replace(old, new)
        head, marker, manifest = text.partition("manifest-text-v1\n")
        head = re.sub(r"manifest-sha256 \S+", "manifest-sha256 " + hashlib.sha256(manifest.encode()).hexdigest(), head)
        head = re.sub(r"manifest-size \S+", f"manifest-size {len(manifest.encode())}", head)
        record.write_text(head + marker + manifest)
        print("fifo manifest in", record.name)
PY
rm -rf "$entry"
run_worker "$worker" "$(retarget "$hol_rev")" "$tmpdir/fifo.log"
require_grep 'extracted toolchain archive manifest is missing' "$tmpdir/fifo.log"
require_grep "the toolchain's identity does not match the action text" "$tmpdir/fifo.log"

# A commit the trusted branch held when the worker checked it, but no branch
# or tag holds now, still builds: a clone leaves it out, so the worker fetches
# it by hash. A clone of a plain path copies every object, so here git clones
# over its transport, as from GitHub.
echo side > "$hol/side"
git -C "$hol" add side
git -C "$hol" commit -qm side
side_rev=$(git -C "$hol" rev-parse HEAD)
git -C "$hol" commit -q --allow-empty -m tip
run_worker "$worker" "$(retarget "$(git -C "$hol" rev-parse HEAD)")" "$tmpdir/tip.log"
require_grep "the toolchain's identity does not match the action text" "$tmpdir/tip.log"
git -C "$hol" update-ref refs/hidden/side "$side_rev"
git -C "$hol" reset -q --hard "$hol_rev"
git -C "$hol" config uploadpack.allowReachableSHA1InWant true
mkdir -p "$tmpdir/remote-git"
cat > "$tmpdir/remote-git/git" <<SH
#!/bin/sh
for arg do
  shift
  set -- "\$@" "\$arg"
  if [ "\$arg" = clone ]; then set -- "\$@" --no-local; fi
done
exec $(command -v git) "\$@"
SH
chmod +x "$tmpdir/remote-git/git"
PATH=$tmpdir/remote-git:$PATH run_worker "$worker" "$(retarget "$side_rev")" "$tmpdir/side.log"
require_grep "the toolchain's identity does not match the action text" "$tmpdir/side.log"
for tree in "$worker"/hol-toolchains/*/hol; do
  if [[ $(git -C "$tree" rev-parse HEAD 2>/dev/null) == "$side_rev" ]]; then side_tree=$tree; fi
done
[[ -n "${side_tree:-}" ]] || { cat "$tmpdir/side.log" >&2; exit 1; }
