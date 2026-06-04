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
make_repo() {
  local dir=$1 name=$2 extra=${3:-}
  mkdir -p "$dir"
  git -C "$dir" init -q
  git_identity "$dir"
  cat > "$dir/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "$name"
$extra
TOML
  git -C "$dir" add .
  git -C "$dir" commit -q -m initial
  git -C "$dir" rev-parse HEAD
}

hol=$tmpdir/hol
hol_rev=$(make_repo "$hol" hol)
export HOLBUILD_CANONICAL_HOL_GIT="$hol"

b=$tmpdir/b
b_rev=$(make_repo "$b" b "
[dependencies.hol]
git = \"$hol\"
rev = \"$hol_rev\"
")

a=$tmpdir/a
a_rev=$(make_repo "$a" a "
[dependencies.hol]
git = \"$hol\"
rev = \"$hol_rev\"

[dependencies.b]
git = \"$b\"
rev = \"$b_rev\"
")

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
(cd "$root" && "$HOLBUILD_BIN" context) > "$tmpdir/root.log"
require_grep "package: a \[root=$root/.holbuild/src/a" "$tmpdir/root.log"
require_grep "package: b \[root=$root/.holbuild/src/b" "$tmpdir/root.log"
require_grep "package: hol \[root=$HOLBUILD_CACHE/hol-toolchains/" "$tmpdir/root.log"
[ -d "$root/.holbuild/src/b/.git" ]
[ ! -d "$root/.holbuild/packages/a/.holbuild/src/b" ]

# Missing hol is rejected.
nohol=$tmpdir/nohol
mkdir -p "$nohol"
cat > "$nohol/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "nohol"

[dependencies.b]
git = "$b"
rev = "$b_rev"
TOML
# b brings hol, so use another package named b with no dependencies for the true missing-hol case.
plain=$tmpdir/plain
plain_rev=$(make_repo "$plain" b)
python3 - <<PY
p='$nohol/holproject.toml'
s=open(p).read().replace('$b', '$plain').replace('$b_rev', '$plain_rev')
open(p,'w').write(s)
PY
if (cd "$nohol" && "$HOLBUILD_BIN" context) > "$tmpdir/nohol.log" 2>&1; then
  echo "missing hol unexpectedly accepted" >&2
  exit 1
fi
require_grep 'schema 2 dependency graph must contain exactly one hol dependency' "$tmpdir/nohol.log"

# Conflicting same-name dependency is rejected.
b2=$tmpdir/b2
b2_rev=$(make_repo "$b2" b "
[dependencies.hol]
git = \"$hol\"
rev = \"$hol_rev\"
")
c=$tmpdir/c
c_rev=$(make_repo "$c" c "
[dependencies.hol]
git = \"$hol\"
rev = \"$hol_rev\"

[dependencies.b]
git = \"$b2\"
rev = \"$b2_rev\"
")
conflict=$tmpdir/conflict
mkdir -p "$conflict"
cat > "$conflict/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "conflict"

[dependencies.a]
git = "$a"
rev = "$a_rev"

[dependencies.c]
git = "$c"
rev = "$c_rev"
TOML
if (cd "$conflict" && "$HOLBUILD_BIN" context) > "$tmpdir/conflict.log" 2>&1; then
  echo "conflict unexpectedly accepted" >&2
  exit 1
fi
require_grep 'conflicting dependency b' "$tmpdir/conflict.log"
