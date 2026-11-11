#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

source_cache=$tmpdir/source-cache
fresh_cache=$tmpdir/fresh-cache
link_hol_toolchain_cache "$source_cache"
link_hol_toolchain_cache "$fresh_cache"

SECRET=sentinel-secret-7f3a

dep_repo=$tmpdir/dep-repo
mkdir -p "$dep_repo/src"
{ write_schema2_prelude; cat <<TOML
[project]
name = "dep"

[build]
members = ["src"]
TOML
} > "$dep_repo/holproject.toml"
cat > "$dep_repo/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
dep_rev=$(init_git_repo "$dep_repo")

# A root package with a dependency, a declared extra input and files nothing
# declares.
project=$tmpdir/project
mkdir -p "$project"/{src,data,notes}
{ write_schema2_prelude; cat <<TOML
[dependencies.dep]
git = "$dep_repo"
rev = "$dep_rev"

[project]
name = "capsule"
version = "1.2.3"

[build]
members = ["src"]

[actions.ATheory]
extra_inputs = ["data/extra.txt", "data/tool.sh"]
TOML
} > "$project/holproject.toml"
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BTheory;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
printf 'extra\n' > "$project/data/extra.txt"
printf 'untracked\n' > "$project/notes/untracked.txt"
printf '#!/bin/sh\n' > "$project/data/tool.sh"
chmod 755 "$project/data/tool.sh"
init_git_repo "$project" > /dev/null
git -C "$project" remote add origin "https://user:$SECRET@example.org/capsule.git"

run_in() {
  local dir=$1 cache=$2
  shift 2
  (cd "$dir" && HOLBUILD_CACHE="$cache" "$HOLBUILD_BIN" "$@")
}

expect_failure() {
  local name=$1 pattern=$2
  shift 2
  if "$@" > "$tmpdir/$name.log" 2>&1; then
    echo "$name: command succeeded but should have failed" >&2
    exit 1
  fi
  require_grep "$pattern" "$tmpdir/$name.log"
}

run_in "$project" "$source_cache" build --tactic-timeout 0 ATheory > "$tmpdir/build.log" 2>&1
require_grep "ATheory built" "$tmpdir/build.log"

# Package-cut (the default): the root package's snapshot and its own entries.
capsule=$tmpdir/capsule.hbx
capsule_json=$tmpdir/capsule.hbx.json
run_in "$project" "$source_cache" export -o "$capsule" --metadata-out "$capsule_json" ATheory \
  > "$tmpdir/export.log" 2>&1
require_grep "exported 1 cache action(s) and the source snapshot of capsule to" "$tmpdir/export.log"
tar -tf "$capsule" > "$tmpdir/capsule.list"
require_grep '^holbuild-cache/manifest$' "$tmpdir/capsule.list"
require_grep '^holbuild-cache/project/manifest$' "$tmpdir/capsule.list"
require_grep '^holbuild-package/manifest$' "$tmpdir/capsule.list"
for file in holproject.toml src/AScript.sml data/tool.sh data/extra.txt; do
  require_grep "^holbuild-package/source/$file\$" "$tmpdir/capsule.list"
done
if grep -q '^holbuild-cache/deps/' "$tmpdir/capsule.list"; then
  echo "a package-cut capsule carries a dependency's cache entries" >&2
  exit 1
fi
if grep -q -e 'untracked' -e '\.git' -e '\.holbuild' "$tmpdir/capsule.list"; then
  echo "the snapshot holds a file nothing declares" >&2
  exit 1
fi
tar -tvf "$capsule" holbuild-package/source/data/tool.sh holbuild-package/source/src/AScript.sml \
  > "$tmpdir/capsule.modes"
require_grep '^-rwxr-xr-x .*data/tool.sh$' "$tmpdir/capsule.modes"
require_grep '^-rw-r--r-- .*src/AScript.sml$' "$tmpdir/capsule.modes"

tar -xOf "$capsule" holbuild-package/manifest > "$tmpdir/capsule.manifest"
require_grep '^holbuild-hbx-capsule-v1$' "$tmpdir/capsule.manifest"
require_grep '^name=capsule$' "$tmpdir/capsule.manifest"
require_grep '^version=1.2.3$' "$tmpdir/capsule.manifest"
require_grep '^toolchain_key=[0-9a-f]\{64\}$' "$tmpdir/capsule.manifest"
require_grep '^holbuild_version=' "$tmpdir/capsule.manifest"
tar -xOf "$capsule" holbuild-cache/manifest > "$tmpdir/capsule.cache-manifest"
require_grep '^holbuild-hbx-v2$' "$tmpdir/capsule.cache-manifest"
require_grep '^action_count=1$' "$tmpdir/capsule.cache-manifest"
require_grep '^target ATheory$' "$tmpdir/capsule.cache-manifest"
tar -xOf "$capsule" holbuild-package/source/holproject.toml | cmp - "$project/holproject.toml"

python3 - "$capsule_json" "$capsule" "$dep_rev" "$dep_repo" <<'PY'
import json
import sys

path, archive, dep_rev, dep_repo = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    metadata = json.load(f)
assert metadata["archive_format"] == "holbuild-hbx-v2", metadata
assert metadata["capsule_format"] == "holbuild-hbx-capsule-v1", metadata
assert metadata["name"] == "capsule", metadata
assert metadata["version"] == "1.2.3", metadata
assert len(metadata["toolchain_key"]) == 64, metadata
assert metadata["targets"] == ["ATheory"], metadata
assert metadata["action_count"] == 1, metadata
assert metadata["source_repo"] == "https://example.org/capsule.git", metadata
deps = {d["name"]: d for d in metadata["dependencies"]}
assert deps["dep"] == {"name": "dep", "git": dep_repo, "rev": dep_rev}, deps
assert deps["hol"]["git"].startswith("https://"), deps
PY
grep -h '^toolchain_key=' "$tmpdir/capsule.manifest" | cut -d= -f2 > "$tmpdir/capsule.key"
grep -q "\"toolchain_key\": \"$(cat "$tmpdir/capsule.key")\"" "$capsule_json"

# --closure: today's archive, with the dependency's entries and no package part.
closure=$tmpdir/closure.hbx
closure_json=$tmpdir/closure.hbx.json
run_in "$project" "$source_cache" export --closure -o "$closure" --metadata-out "$closure_json" ATheory \
  > "$tmpdir/closure.log" 2>&1
require_grep "exported 2 cache action(s) to" "$tmpdir/closure.log"
tar -tf "$closure" > "$tmpdir/closure.list"
require_grep '^holbuild-cache/deps/dep-' "$tmpdir/closure.list"
if grep -q '^holbuild-package' "$tmpdir/closure.list"; then
  echo "a closure archive carries a package part" >&2
  exit 1
fi
python3 - "$closure_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    metadata = json.load(f)
assert metadata["archive_format"] == "holbuild-hbx-v2", metadata
assert "capsule_format" not in metadata, metadata
assert metadata["action_count"] == 2, metadata
assert metadata["name"] == "capsule" and metadata["version"] == "1.2.3", metadata
PY

# --sources-only: no cache part, no targets, no build; the bytes do not depend
# on the publisher's umask or on what a generator has written.
genproject=$tmpdir/genproject
cp -r "$project" "$genproject"
rm -rf "$genproject/.holbuild" "$genproject/.git"
cat >> "$genproject/holproject.toml" <<'TOML'

[[generate]]
name = "gen"
command = ["true"]
inputs = ["data/extra.txt"]
outputs = ["data/generated.txt"]
TOML
sources=$tmpdir/sources.hbx
sources_json=$tmpdir/sources.hbx.json
run_in "$genproject" "$fresh_cache" export --sources-only -o "$sources" --metadata-out "$sources_json" \
  > "$tmpdir/sources.log" 2>&1
require_grep "exported the source snapshot of capsule to" "$tmpdir/sources.log"
tar -tf "$sources" > "$tmpdir/sources.list"
if grep -q '^holbuild-cache' "$tmpdir/sources.list"; then
  echo "a sources-only capsule carries a cache part" >&2
  exit 1
fi
require_grep '^holbuild-package/manifest$' "$tmpdir/sources.list"
require_grep '^holbuild-package/source/src/AScript.sml$' "$tmpdir/sources.list"
python3 - "$sources_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    metadata = json.load(f)
assert "archive_format" not in metadata, metadata
assert metadata["capsule_format"] == "holbuild-hbx-capsule-v1", metadata
assert metadata["targets"] == [] and metadata["action_count"] == 0, metadata
assert metadata["name"] == "capsule", metadata
PY

printf 'generated\n' > "$genproject/data/generated.txt"
sources_again=$tmpdir/sources-again.hbx
(umask 077; run_in "$genproject" "$fresh_cache" export --sources-only -o "$sources_again" > /dev/null 2>&1)
cmp "$sources" "$sources_again"
if tar -tf "$sources_again" | grep -q 'generated.txt'; then
  echo "a generator output is in the snapshot" >&2
  exit 1
fi

# Neither the capsule's manifest nor the sidecar carries the origin's credential.
for file in "$tmpdir/capsule.manifest" "$tmpdir/capsule.cache-manifest" "$capsule_json" \
            "$closure_json" "$sources_json"; do
  if grep -q "$SECRET" "$file"; then
    echo "origin credential leaked into $file" >&2
    exit 1
  fi
done

# A dependency's credential does not reach the sidecar either.
creds=$tmpdir/creds
mkdir -p "$creds/src"
{ write_schema2_prelude; cat <<TOML
[dependencies.dep]
git = "https://user:$SECRET@example.invalid/other.git"
rev = "$dep_rev"

[project]
name = "creds"

[build]
members = ["src"]
TOML
} > "$creds/holproject.toml"
printf 'structure S = struct end\n' > "$creds/src/S.sml"
# The credentialed URL is served by the local dependency repository.
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$dep_repo.insteadOf" \
  GIT_CONFIG_VALUE_0="https://user:$SECRET@example.invalid/other.git" \
  run_in "$creds" "$fresh_cache" export --sources-only -o "$tmpdir/creds.hbx" --metadata-out "$tmpdir/creds.json" \
  > "$tmpdir/creds.log" 2>&1
tar -xOf "$tmpdir/creds.hbx" holbuild-package/manifest > "$tmpdir/creds.manifest"
if grep -q "$SECRET" "$tmpdir/creds.manifest" "$tmpdir/creds.json"; then
  echo "dependency credential leaked into the manifest or sidecar" >&2
  exit 1
fi
require_grep '"git": "https://example.invalid/other.git"' "$tmpdir/creds.json"

# The cache part of a capsule imports as an archive's does, a sources-only
# capsule imports no actions, and in a cache that holds only the capsule's
# entries the dependency's theory is unbuilt: package-cut and sources-only
# export succeed, --closure names the theory.
import_cache=$tmpdir/import-cache
link_hol_toolchain_cache "$import_cache"
HOLBUILD_CACHE="$import_cache" "$HOLBUILD_BIN" import "$capsule" > "$tmpdir/import-capsule.log" 2>&1
require_grep "imported 1 cache action" "$tmpdir/import-capsule.log"
HOLBUILD_CACHE="$import_cache" "$HOLBUILD_BIN" import "$sources" > "$tmpdir/import-sources.log" 2>&1
require_grep "imported 0 cache action" "$tmpdir/import-sources.log"

run_in "$project" "$import_cache" export -o "$tmpdir/unbuilt.hbx" ATheory > "$tmpdir/unbuilt.log" 2>&1
require_grep "exported 1 cache action(s) and the source snapshot of capsule" "$tmpdir/unbuilt.log"
run_in "$project" "$import_cache" export --sources-only -o "$tmpdir/unbuilt-sources.hbx" > /dev/null 2>&1
expect_failure unbuilt-closure "target BTheory is not built in the cache" \
  run_in "$project" "$import_cache" export --closure -o "$tmpdir/unbuilt-closure.hbx" ATheory
[[ ! -e "$tmpdir/unbuilt-closure.hbx" ]] || { echo "a failed export left an archive" >&2; exit 1; }

# A target in another package is dropped from a capsule, not an error.
run_in "$project" "$source_cache" export -o "$tmpdir/dep-target.hbx" ATheory BTheory > "$tmpdir/dep-target.log" 2>&1
require_grep "exported 1 cache action(s)" "$tmpdir/dep-target.log"
tar -xOf "$tmpdir/dep-target.hbx" holbuild-cache/manifest > "$tmpdir/dep-target.manifest"
require_grep '^target ATheory$' "$tmpdir/dep-target.manifest"
if grep -q '^target BTheory$' "$tmpdir/dep-target.manifest"; then
  echo "a package-cut capsule records another package's target" >&2
  exit 1
fi

# The cache part restores the root theory; the dependency builds from source.
find "$project/.holbuild" -mindepth 1 -maxdepth 1 ! -name src -exec rm -rf {} +
run_in "$project" "$import_cache" build --allow-cache-timeout-discrepancy --tactic-timeout 60 ATheory \
  > "$tmpdir/restore.log" 2>&1
require_grep "ATheory restored from cache" "$tmpdir/restore.log"

# Usage errors, and snapshot errors surface as an export failure.
expect_failure both "export --closure and --sources-only are exclusive" \
  run_in "$project" "$source_cache" export --closure --sources-only -o "$tmpdir/x.hbx"
expect_failure with-target "export --sources-only takes no targets" \
  run_in "$project" "$source_cache" export --sources-only -o "$tmpdir/x.hbx" ATheory
expect_failure with-build "export --sources-only does not build" \
  run_in "$project" "$source_cache" export --sources-only --build -o "$tmpdir/x.hbx"
ln -s data/extra.txt "$project/data/link.txt"
sed -i 's|"data/tool.sh"\]|"data/tool.sh", "data/link.txt"]|' "$project/holproject.toml"
expect_failure symlink "symlink in package snapshot: data/link.txt" \
  run_in "$project" "$source_cache" export --sources-only -o "$tmpdir/x.hbx"
[[ ! -e "$tmpdir/x.hbx" ]] || { echo "a failed export left an archive" >&2; exit 1; }
