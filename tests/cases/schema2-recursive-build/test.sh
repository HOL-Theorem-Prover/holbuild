#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"

git_identity() { git -C "$1" config user.email test@example.com; git -C "$1" config user.name 'Holbuild Test'; git -C "$1" config commit.gpgsign false; }
commit_repo() { git -C "$1" add .; git -C "$1" commit -q -m initial; git -C "$1" rev-parse HEAD; }

hol=$tmpdir/hol
mkdir -p "$hol"
git -C "$hol" init -q
git_identity "$hol"
mkdir -p "$hol/bin" "$hol/tools"
cat > "$hol/.gitignore" <<'EOF_IGNORE'
/bin/hol
/bin/hol.state
/configured
/built
/built-at
EOF_IGNORE
cat > "$hol/tools/smart-configure.sml" <<'SML'
(* fake configure script; HOLBUILD_POLY fixture handles it *)
SML
cat > "$hol/bin/build" <<'SH'
#!/usr/bin/env sh
set -eu
[ "$#" -eq 1 ] && [ "$1" = "--no-helpdocs" ]
touch built
pwd > built-at
cat > bin/hol <<'HOL'
#!/usr/bin/env sh
exit 0
HOL
chmod +x bin/hol
echo fake-state > bin/hol.state
SH
chmod +x "$hol/bin/build"
hol_rev=$(commit_repo "$hol")
export HOLBUILD_CANONICAL_HOL_GIT="$hol"

fakebin=$tmpdir/fakebin
mkdir -p "$fakebin"
cat > "$fakebin/poly" <<'SH'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = "-v" ]; then
  echo "Fake Poly/ML 1.0"
  exit 0
fi
touch configured
SH
chmod +x "$fakebin/poly"
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
if [ -z "$out" ]; then
  echo "fake polyc missing -o" >&2
  exit 1
fi
cat > "$out" <<'ANALYSER'
#!/usr/bin/env sh
set -eu
resp=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --response) resp=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$resp" <<'RESP'
version 1
ok
begin-file 1
end-file 1
end
RESP
ANALYSER
chmod +x "$out"
SH
chmod +x "$fakebin/polyc"
export HOLBUILD_POLYC="$fakebin/polyc"

b=$tmpdir/b
mkdir -p "$b/src"
git -C "$b" init -q
git_identity "$b"
cat > "$b/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "b"

[build]
members = ["src"]

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"
TOML
cat > "$b/src/Foo.sml" <<'SML'
structure Foo = struct
  val value = true
end
SML
b_rev=$(commit_repo "$b")

a=$tmpdir/a
mkdir -p "$a"
git -C "$a" init -q
git_identity "$a"
cat > "$a/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "a"

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"

[dependencies.b]
git = "$b"
rev = "$b_rev"
TOML
a_rev=$(commit_repo "$a")

root=$tmpdir/root
mkdir -p "$root"
cat > "$root/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "root"

[dependencies.a]
git = "$a"
rev = "$a_rev"
TOML

context_log=$tmpdir/context.log
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" context) > "$context_log"
require_grep "package: hol \[root=$HOLBUILD_CACHE/hol-toolchains/" "$context_log"
shared_hol_from_context=$(awk -F'root=' '/package: hol / { split($2, parts, ","); print parts[1]; exit }' "$context_log")
if find -L "$shared_hol_from_context" \( -name configured -o -name built \) 2>/dev/null | grep -q .; then
  echo "schema 2 context unexpectedly built HOL" >&2
  exit 1
fi
if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/context-holdir.log" 2>&1; then
  echo "schema 2 context unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'no longer supported' "$tmpdir/context-holdir.log"

if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" run) > "$tmpdir/run-holdir.log" 2>&1; then
  echo "schema 2 run unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'no longer supported' "$tmpdir/run-holdir.log"

if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" heap fake) > "$tmpdir/heap-holdir.log" 2>&1; then
  echo "schema 2 heap unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'no longer supported' "$tmpdir/heap-holdir.log"

toolchain_entry=${shared_hol_from_context%/hol}
stale_lock="$HOLBUILD_CACHE/hol-toolchains/.locks/hol-toolchain-$(basename "$toolchain_entry").lock"
mkdir -p "$stale_lock"

dry_log=$tmpdir/dry.log
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" build --dry-run Foo) > "$dry_log" 2>&1
require_grep "removing obsolete directory HOL toolchain lock" "$dry_log"
require_grep "Foo (sml, package b)" "$dry_log"
[[ -f "$stale_lock" ]] || { echo "toolchain lock was not recreated as a file" >&2; exit 1; }
[[ ! -e "$stale_lock.owner" ]] || { echo "toolchain lock owner survived successful bootstrap" >&2; exit 1; }
shared_hol=$shared_hol_from_context
require_file "$shared_hol/configured"
require_file "$shared_hol/built"
require_file "$shared_hol/bin/hol"
require_file "$shared_hol/bin/hol.state"
shared_hol_real=$(cd "$shared_hol" && pwd -P)
built_at=$(cat "$shared_hol/built-at")
if [[ "$built_at" != "$shared_hol" && "$built_at" != "$shared_hol_real" ]]; then
  echo "unexpected fake HOL build directory: $built_at" >&2
  exit 1
fi
rm "$shared_hol/configured" "$shared_hol/built"
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" buildhol) > "$tmpdir/buildhol.log"
require_grep "$shared_hol" "$tmpdir/buildhol.log"
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" build --dry-run Foo) > "$tmpdir/dry2.log"
if [ -e "$shared_hol/configured" ] || [ -e "$shared_hol/built" ]; then
  echo "already-built schema 2 HOL was rebuilt" >&2
  exit 1
fi

if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run Foo) > "$tmpdir/holdir.log" 2>&1; then
  echo "schema 2 build unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'no longer supported' "$tmpdir/holdir.log"

echo dirty >> "$shared_hol/bin/build"
if (cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" build --dry-run Foo) > "$tmpdir/dirty.log" 2>&1; then
  echo "dirty HOL checkout unexpectedly accepted" >&2
  exit 1
fi
require_grep 'dirty HOL toolchain cache entry' "$tmpdir/dirty.log"

[ -d "$root/.holbuild/src/b/.git" ]
[ ! -d "$root/.holbuild/src/b/.holbuild" ]
[ ! -d "$root/.holbuild/packages/a/.holbuild" ]
[ ! -d "$root/.holbuild/packages/a/.holbuild/src/b" ]
