#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT
export HOLBUILD_CACHE="$tmpdir/cache"

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
if find "$HOLBUILD_CACHE/hol-toolchains" -name configured -o -name built 2>/dev/null | grep -q .; then
  echo "schema 2 context unexpectedly built HOL" >&2
  exit 1
fi
if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/context-holdir.log" 2>&1; then
  echo "schema 2 context unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'not supported for schema 2 projects' "$tmpdir/context-holdir.log"

if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" run) > "$tmpdir/run-holdir.log" 2>&1; then
  echo "schema 2 run unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'not supported for schema 2 projects' "$tmpdir/run-holdir.log"

if (cd "$root" && "$HOLBUILD_BIN" --holdir "$HOLDIR" heap fake) > "$tmpdir/heap-holdir.log" 2>&1; then
  echo "schema 2 heap unexpectedly accepted --holdir" >&2
  exit 1
fi
require_grep 'not supported for schema 2 projects' "$tmpdir/heap-holdir.log"

dry_log=$tmpdir/dry.log
(cd "$root" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_POLY="$fakebin/poly" "$HOLBUILD_BIN" build --dry-run Foo) > "$dry_log"
require_grep "Foo (sml, package b)" "$dry_log"
shared_hol=$(find "$HOLBUILD_CACHE/hol-toolchains" -path '*/hol' -type d | head -1)
require_file "$shared_hol/configured"
require_file "$shared_hol/built"
require_file "$shared_hol/bin/hol"
require_file "$shared_hol/bin/hol.state"
require_grep "^$shared_hol$" "$shared_hol/built-at"
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
require_grep 'not supported for schema 2 projects' "$tmpdir/holdir.log"

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
