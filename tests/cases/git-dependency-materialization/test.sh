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
mkdir -p "$repo/subdir"
cat > "$repo/subdir/sub.manifest.toml" <<'TOML'
[project]
name = "subdep"
TOML
echo one > "$repo/value.txt"
git -C "$repo" add .
git -C "$repo" commit -q -m one
rev1=$(git -C "$repo" rev-parse HEAD)
echo two > "$repo/value.txt"
git -C "$repo" commit -q -am two
rev2=$(git -C "$repo" rev-parse HEAD)

hol_repo=$tmpdir/hol-repo
mkdir -p "$hol_repo"
git -C "$hol_repo" init -q
git_identity "$hol_repo"
echo upstream-hol-without-holproject > "$hol_repo/README"
git -C "$hol_repo" add .
git -C "$hol_repo" commit -q -m hol
hol_rev=$(git -C "$hol_repo" rev-parse HEAD)
export HOLBUILD_CANONICAL_HOL_GIT="$hol_repo"

project=$tmpdir/project
mkdir -p "$project"
cat > "$project/sub.manifest.toml" <<'TOML'
[project]
name = "subdep"
TOML
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "project"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[dependencies.dep]
git = "$repo"
rev = "$rev1"

[dependencies.subdep]
from = "dep"
path = "subdir"
manifest = "sub.manifest.toml"
TOML

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context1.log"
require_grep 'dependency: dep \[git=' "$tmpdir/context1.log"
require_grep "package: dep \[root=$project/.holbuild/src/dep, manifest=$project/.holbuild/src/dep/holproject.toml, artifact-root=$project/.holbuild/packages/dep\]" "$tmpdir/context1.log"
require_grep "package: subdep \[root=$project/.holbuild/src/dep/subdir, manifest=$project/sub.manifest.toml, artifact-root=$project/.holbuild/packages/subdep\]" "$tmpdir/context1.log"
require_grep "dependency: subdep \[from=dep, path=subdir, manifest=sub.manifest.toml, local=$project/.holbuild/src/dep/subdir, resolved-manifest=$project/sub.manifest.toml" "$tmpdir/context1.log"
[ "$(git -C "$project/.holbuild/src/dep" rev-parse HEAD)" = "$rev1" ]
require_grep '^one$' "$project/.holbuild/src/dep/value.txt"

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context2.log"
[ "$(git -C "$project/.holbuild/src/dep" rev-parse HEAD)" = "$rev1" ]

python3 - "$project/holproject.toml" "$rev1" "$rev2" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read().replace(old, new)
open(path, 'w').write(text)
PY
(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context3.log"
[ "$(git -C "$project/.holbuild/src/dep" rev-parse HEAD)" = "$rev2" ]
require_grep '^two$' "$project/.holbuild/src/dep/value.txt"

bad_short=$tmpdir/bad-short
mkdir -p "$bad_short"
cat > "$bad_short/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "bad-short"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[dependencies.dep]
git = "$repo"
rev = "${rev1:0:12}"
TOML
if (cd "$bad_short" && "$HOLBUILD_BIN" context) > "$tmpdir/bad-short.log" 2>&1; then
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
if (cd "$bad_name" && "$HOLBUILD_BIN" context) > "$tmpdir/bad-name.log" 2>&1; then
  echo "unsafe name unexpectedly accepted" >&2
  exit 1
fi
require_grep 'dependencies.../dep must be a safe dependency name' "$tmpdir/bad-name.log"

no_manifest_repo=$tmpdir/no-manifest-repo
mkdir -p "$no_manifest_repo"
git -C "$no_manifest_repo" init -q
git_identity "$no_manifest_repo"
echo content > "$no_manifest_repo/file.txt"
git -C "$no_manifest_repo" add .
git -C "$no_manifest_repo" commit -q -m initial
no_manifest_rev=$(git -C "$no_manifest_repo" rev-parse HEAD)
no_manifest_project=$tmpdir/no-manifest-project
mkdir -p "$no_manifest_project"
cat > "$no_manifest_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "no-manifest-project"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[dependencies.dep]
git = "$no_manifest_repo"
rev = "$no_manifest_rev"
TOML
if (cd "$no_manifest_project" && "$HOLBUILD_BIN" context) > "$tmpdir/no-manifest.log" 2>&1; then
  echo "missing git manifest unexpectedly accepted" >&2
  exit 1
fi
require_grep 'dependency dep manifest not found:' "$tmpdir/no-manifest.log"

missing_from_manifest=$tmpdir/missing-from-manifest
mkdir -p "$missing_from_manifest"
cat > "$missing_from_manifest/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "missing-from-manifest"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[dependencies.dep]
git = "$repo"
rev = "$rev1"

[dependencies.subdep]
from = "dep"
path = "subdir"
manifest = "missing.toml"
TOML
if (cd "$missing_from_manifest" && "$HOLBUILD_BIN" context) > "$tmpdir/missing-from-manifest.log" 2>&1; then
  echo "missing from manifest unexpectedly accepted" >&2
  exit 1
fi
require_grep 'dependency subdep manifest not found:' "$tmpdir/missing-from-manifest.log"

unknown_from=$tmpdir/unknown-from
mkdir -p "$unknown_from"
cat > "$unknown_from/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "unknown-from"

[dependencies.subdep]
from = "missing"
path = "."
manifest = "sub.manifest.toml"
TOML
if (cd "$unknown_from" && "$HOLBUILD_BIN" context) > "$tmpdir/unknown-from.log" 2>&1; then
  echo "unknown from unexpectedly accepted" >&2
  exit 1
fi
require_grep 'dependencies.subdep from dependency is unknown: missing' "$tmpdir/unknown-from.log"

from_from=$tmpdir/from-from
mkdir -p "$from_from"
cat > "$from_from/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "from-from"

[dependencies.a]
from = "b"
path = "."
manifest = "a.toml"

[dependencies.b]
from = "dep"
path = "."
manifest = "b.toml"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[dependencies.dep]
git = "$repo"
rev = "$rev1"
TOML
if (cd "$from_from" && "$HOLBUILD_BIN" context) > "$tmpdir/from-from.log" 2>&1; then
  echo "from-from unexpectedly accepted" >&2
  exit 1
fi
require_grep 'dependencies.a from dependency must refer to a direct git dependency: b' "$tmpdir/from-from.log"

bad_from_path=$tmpdir/bad-from-path
mkdir -p "$bad_from_path"
cat > "$bad_from_path/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "bad-from-path"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[dependencies.dep]
git = "$repo"
rev = "$rev1"

[dependencies.subdep]
from = "dep"
path = "../escape"
manifest = "sub.manifest.toml"
TOML
if (cd "$bad_from_path" && "$HOLBUILD_BIN" context) > "$tmpdir/bad-from-path.log" 2>&1; then
  echo "bad from path unexpectedly accepted" >&2
  exit 1
fi
require_grep 'dependencies.subdep.path must be package-root-relative' "$tmpdir/bad-from-path.log"

missing=$tmpdir/missing
mkdir -p "$missing"
missing_rev=0000000000000000000000000000000000000000
cat > "$missing/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "missing"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[dependencies.dep]
git = "$repo"
rev = "$missing_rev"
TOML
if (cd "$missing" && "$HOLBUILD_BIN" context) > "$tmpdir/missing.log" 2>&1; then
  echo "missing rev unexpectedly accepted" >&2
  exit 1
fi
require_grep 'cat-file -e' "$tmpdir/missing.log"
