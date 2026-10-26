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
use_case_cache "$tmpdir/cache"

git_identity() {
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name 'Holbuild Test'
  git -C "$1" config commit.gpgsign false
}

hol_repo=$tmpdir/hol-repo
mkdir -p "$hol_repo"
git -C "$hol_repo" init -q
git_identity "$hol_repo"
echo upstream-hol-without-holproject > "$hol_repo/README"
git -C "$hol_repo" add .
git -C "$hol_repo" commit -q -m hol
hol_rev=$(git -C "$hol_repo" rev-parse HEAD)
export HOLBUILD_CANONICAL_HOL_GIT="$hol_repo"

repo=$tmpdir/dep-repo
mkdir -p "$repo"
git -C "$repo" init -q
git_identity "$repo"
cat > "$repo/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[project]
name = "dep"
TOML
mkdir -p "$repo/subdir"
cat > "$repo/subdir/sub.manifest.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

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

project=$tmpdir/project
mkdir -p "$project"
cat > "$project/sub.manifest.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[project]
name = "subdep"
TOML
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

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

# A materialized immutable revision must remain usable without its remote.
mv "$repo" "$tmpdir/dep-repo-offline"
(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context-offline.log"
mv "$tmpdir/dep-repo-offline" "$repo"
[ "$(git -C "$project/.holbuild/src/dep" rev-parse HEAD)" = "$rev1" ]

# The shared bare cache already exists, so a commit subsequently advertised only
# by a non-default branch must be fetched explicitly rather than through HEAD.
default_branch=$(git -C "$repo" symbolic-ref --short HEAD)
git -C "$repo" checkout -q -b side "$rev1"
echo side > "$repo/value.txt"
git -C "$repo" commit -q -am side
side_rev=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q "$default_branch"
python3 - "$project/holproject.toml" "$rev1" "$side_rev" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read().replace(old, new)
open(path, 'w').write(text)
PY
(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context-side.log"
[ "$(git -C "$project/.holbuild/src/dep" rev-parse HEAD)" = "$side_rev" ]
require_grep '^side$' "$project/.holbuild/src/dep/value.txt"

python3 - "$project/holproject.toml" "$side_rev" "$rev2" <<'PY'
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
minimum_version = "0.10.0"

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
minimum_version = "0.10.0"

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
minimum_version = "0.10.0"

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
require_grep "dependency dep manifest not found: no holbuild.toml or holproject.toml in $no_manifest_project/.holbuild/src/dep" "$tmpdir/no-manifest.log"

missing_from_manifest=$tmpdir/missing-from-manifest
mkdir -p "$missing_from_manifest"
cat > "$missing_from_manifest/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

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
minimum_version = "0.10.0"

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
minimum_version = "0.10.0"

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
minimum_version = "0.10.0"

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
minimum_version = "0.10.0"

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
require_grep "fetch origin '$missing_rev'" "$tmpdir/missing.log"

# Concurrent materialization: a git shim that stalls every clone keeps racing
# processes inside the clone-and-publish window together. Two project roots
# share a fresh cache, so their first runs also race to create the mirror.
use_case_cache "$tmpdir/race-cache"
slow_git=$tmpdir/slow-git
mkdir -p "$slow_git"
real_git=$(command -v git)
cat > "$slow_git/git" <<SH
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = clone ]; then sleep 1; break; fi
done
exec "$real_git" "\$@"
SH
chmod +x "$slow_git/git"

set_dep_rev() {
  python3 - "$1/holproject.toml" "$2" <<'PY'
import re, sys
path, rev = sys.argv[1:]
text = open(path).read()
text = re.sub(r'(\[dependencies\.dep\]\ngit = "[^"]*"\nrev = ")[0-9a-f]*(")', r'\g<1>' + rev + r'\g<2>', text)
open(path, 'w').write(text)
PY
}

for race in race1 race2; do
  mkdir -p "$tmpdir/$race"
  cat > "$tmpdir/$race/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "$race"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[dependencies.dep]
git = "$repo"
rev = "$rev1"
TOML
done

race_context() {
  local label=$1 rev=$2
  shift 2
  local -a pids=()
  local project i=0 failed=0
  for project in "$@"; do
    (cd "$project" && PATH="$slow_git:$PATH" "$HOLBUILD_BIN" context) > "$tmpdir/$label-$i.log" 2>&1 &
    pids+=("$!")
    i=$((i + 1))
  done
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      echo "concurrent context $label-$i failed" >&2
      cat "$tmpdir/$label-$i.log" >&2
      failed=1
    fi
  done
  [ "$failed" = 0 ]
  for project in "$@"; do
    [ "$(git -C "$project/.holbuild/src/dep" rev-parse HEAD)" = "$rev" ]
    if compgen -G "$project/.holbuild/src/.tmp-*" > /dev/null; then
      echo "checkout temp dir left in $project/.holbuild/src" >&2
      exit 1
    fi
  done
}

# A mirror clone killed mid-way leaves a temp dir that the next clone removes.
mkdir -p "$HOLBUILD_CACHE/git/remotes"
mkdir "$HOLBUILD_CACHE/git/remotes/$(printf %s "$repo" | sha1sum | cut -d' ' -f1).git.tmp-999999999"
race_context cold "$rev1" "$tmpdir/race1" "$tmpdir/race1" "$tmpdir/race2" "$tmpdir/race2"
if compgen -G "$HOLBUILD_CACHE/git/remotes/*.tmp-*" > /dev/null; then
  echo "mirror temp dir left in $HOLBUILD_CACHE/git/remotes" >&2
  exit 1
fi

rm -rf "$tmpdir/race1/.holbuild/src" "$tmpdir/race2/.holbuild/src"
race_context warm-mirror "$rev1" "$tmpdir/race1" "$tmpdir/race1" "$tmpdir/race2" "$tmpdir/race2"

set_dep_rev "$tmpdir/race1" "$rev2"
set_dep_rev "$tmpdir/race2" "$rev2"
race_context repin "$rev2" "$tmpdir/race1" "$tmpdir/race1" "$tmpdir/race2" "$tmpdir/race2"

# A holbuild process that has materialized dep keeps its lease while it runs:
# another process at the same rev still proceeds, but none may replace the tree
# until the holder exits. The holder is kept alive by a second git dependency
# whose mirror clone blocks on a FIFO.
blocker_repo=$tmpdir/blocker-repo
mkdir -p "$blocker_repo"
git -C "$blocker_repo" init -q
git_identity "$blocker_repo"
cat > "$blocker_repo/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "$hol_repo"
rev = "$hol_rev"

[project]
name = "blocker"
TOML
git -C "$blocker_repo" add .
git -C "$blocker_repo" commit -q -m blocker
blocker_rev=$(git -C "$blocker_repo" rev-parse HEAD)
cp "$tmpdir/race1/holproject.toml" "$tmpdir/race1.toml"
cat >> "$tmpdir/race1/holproject.toml" <<TOML

[dependencies.blocker]
git = "$blocker_repo"
rev = "$blocker_rev"
TOML

blocking_git=$tmpdir/blocking-git
mkdir -p "$blocking_git"
mkfifo "$tmpdir/blocker.fifo"
cat > "$blocking_git/git" <<SH
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "$blocker_repo" ]; then
    : > "$tmpdir/blocker.ready"
    timeout 120 cat "$tmpdir/blocker.fifo" > /dev/null
    break
  fi
done
exec "$real_git" "\$@"
SH
chmod +x "$blocking_git/git"

(cd "$tmpdir/race1" && PATH="$blocking_git:$PATH" "$HOLBUILD_BIN" context) > "$tmpdir/holder.log" 2>&1 &
lease_holder=$!
for _ in {1..600}; do
  [[ -e "$tmpdir/blocker.ready" ]] && break
  sleep 0.05
done
require_file "$tmpdir/blocker.ready"
# The holder has read its manifest; later runs see dep alone.
cp "$tmpdir/race1.toml" "$tmpdir/race1/holproject.toml"
(cd "$tmpdir/race1" && "$HOLBUILD_BIN" context) > "$tmpdir/leased-same.log"
set_dep_rev "$tmpdir/race1" "$rev1"
if (cd "$tmpdir/race1" && "$HOLBUILD_BIN" context) > "$tmpdir/leased-replace.log" 2>&1; then
  echo "checkout replaced while another holbuild process was using it" >&2
  exit 1
fi
require_grep "another holbuild process is using it (pid [0-9][0-9]*)" "$tmpdir/leased-replace.log"
[ "$(git -C "$tmpdir/race1/.holbuild/src/dep" rev-parse HEAD)" = "$rev2" ]
echo > "$tmpdir/blocker.fifo"
if ! wait "$lease_holder"; then
  cat "$tmpdir/holder.log" >&2
  exit 1
fi
(cd "$tmpdir/race1" && "$HOLBUILD_BIN" context) > "$tmpdir/released-replace.log"
[ "$(git -C "$tmpdir/race1/.holbuild/src/dep" rev-parse HEAD)" = "$rev1" ]
