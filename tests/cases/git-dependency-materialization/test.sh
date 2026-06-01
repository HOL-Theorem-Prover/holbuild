#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
export HOLBUILD_CACHE="$tmpdir/cache"

git_identity() {
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name 'Holbuild Test'
  git -C "$1" config commit.gpgsign false
}

repo=$tmpdir/dep-repo
mkdir -p "$repo"
git -C "$repo" init -q
git_identity "$repo"
cat > "$repo/holproject.toml" <<'TOML'
[project]
name = "dep"
TOML
echo one > "$repo/value.txt"
git -C "$repo" add .
git -C "$repo" commit -q -m one
rev1=$(git -C "$repo" rev-parse HEAD)
echo two > "$repo/value.txt"
git -C "$repo" commit -q -am two
rev2=$(git -C "$repo" rev-parse HEAD)

project=$tmpdir/project
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "project"

[dependencies.dep]
git = "$repo"
rev = "$rev1"
TOML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/context1.log"
require_grep 'dependency: dep \[git=' "$tmpdir/context1.log"
[ "$(git -C "$project/.holbuild/src/dep" rev-parse HEAD)" = "$rev1" ]
require_grep '^one$' "$project/.holbuild/src/dep/value.txt"

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/context2.log"
[ "$(git -C "$project/.holbuild/src/dep" rev-parse HEAD)" = "$rev1" ]

python3 - "$project/holproject.toml" "$rev1" "$rev2" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read().replace(old, new)
open(path, 'w').write(text)
PY
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/context3.log"
[ "$(git -C "$project/.holbuild/src/dep" rev-parse HEAD)" = "$rev2" ]
require_grep '^two$' "$project/.holbuild/src/dep/value.txt"

bad_short=$tmpdir/bad-short
mkdir -p "$bad_short"
cat > "$bad_short/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "bad-short"

[dependencies.dep]
git = "$repo"
rev = "${rev1:0:12}"
TOML
if (cd "$bad_short" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/bad-short.log" 2>&1; then
  echo "short rev unexpectedly accepted" >&2
  exit 1
fi
require_grep 'git dependency rev must be a full 40-character lowercase hex commit' "$tmpdir/bad-short.log"

bad_name=$tmpdir/bad-name
mkdir -p "$bad_name"
cat > "$bad_name/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "bad-name"

[dependencies."../dep"]
git = "$repo"
rev = "$rev1"
TOML
if (cd "$bad_name" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/bad-name.log" 2>&1; then
  echo "unsafe name unexpectedly accepted" >&2
  exit 1
fi
require_grep 'unsafe dependency name for materialization' "$tmpdir/bad-name.log"

missing=$tmpdir/missing
mkdir -p "$missing"
missing_rev=0000000000000000000000000000000000000000
cat > "$missing/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "missing"

[dependencies.dep]
git = "$repo"
rev = "$missing_rev"
TOML
if (cd "$missing" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/missing.log" 2>&1; then
  echo "missing rev unexpectedly accepted" >&2
  exit 1
fi
require_grep 'cat-file -e' "$tmpdir/missing.log"
