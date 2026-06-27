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

source_cache=$tmpdir/source-cache
import_cache=$tmpdir/import-cache
link_hol_toolchain_cache "$source_cache"
link_hol_toolchain_cache "$import_cache"

dep_repo=$tmpdir/dep-repo
mkdir -p "$dep_repo/src"
cat > "$dep_repo/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "dep"

[build]
members = ["src"]
TOML
cat > "$dep_repo/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
dep_rev=$(init_git_repo "$dep_repo")

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[dependencies.dep]
git = "$dep_repo"
rev = "$dep_rev"

[project]
name = "hbxarchive"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BTheory;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

build_log=$tmpdir/build.log
(cd "$project" && HOLBUILD_CACHE="$source_cache" "$HOLBUILD_BIN" build ATheory) > "$build_log" 2>&1
require_grep "BTheory built" "$build_log"
require_grep "ATheory built" "$build_log"

archive=$tmpdir/a.hbx
metadata=$tmpdir/a.hbx.json
export_log=$tmpdir/export.log
(cd "$project" && HOLBUILD_CACHE="$source_cache" "$HOLBUILD_BIN" export -o "$archive" --metadata-out "$metadata" ATheory) > "$export_log" 2>&1
require_file "$archive"
require_file "$metadata"
require_grep "exported 2 cache action" "$export_log"
python3 - "$metadata" "$archive" "$(sha256sum "$archive" | awk '{print $1}')" "$(holbuild_pinned_hol_rev)" <<'PY'
import json
import os
import sys

metadata_path, archive_path, sha256, hol_rev = sys.argv[1:]
with open(metadata_path, encoding="utf-8") as f:
    metadata = json.load(f)
assert metadata["format"] == "holbuild-hbx-metadata-v1"
assert metadata["archive_format"] == "holbuild-hbx-v1"
assert metadata["archive"] == os.path.basename(archive_path)
assert metadata["sha256"] == sha256
assert metadata["size"] == os.path.getsize(archive_path)
assert metadata["targets"] == ["ATheory"]
assert metadata["action_count"] == 2
assert metadata["hol_repo"] == "https://github.com/HOL-Theorem-Prover/HOL.git"
assert metadata["hol_rev"] == hol_rev
assert metadata["created_at"].endswith("Z")
PY

build_archive=$tmpdir/build.hbx
build_export_log=$tmpdir/export-build.log
(cd "$project" && HOLBUILD_CACHE="$source_cache" "$HOLBUILD_BIN" export --build -o "$build_archive" ATheory) > "$build_export_log" 2>&1
require_file "$build_archive"
require_grep "exported 2 cache action" "$build_export_log"

tar -tf "$archive" > "$tmpdir/archive.list"
require_grep '^holbuild-cache/project/manifest$' "$tmpdir/archive.list"
require_grep '^holbuild-cache/deps/dep-' "$tmpdir/archive.list"
require_grep '^holbuild-cache/actions/.*/manifest$' "$tmpdir/archive.list"

tar -xOf "$archive" holbuild-cache/manifest > "$tmpdir/archive.manifest"
require_grep '^holbuild-hbx-v1$' "$tmpdir/archive.manifest"
require_grep '^holbuild_version=' "$tmpdir/archive.manifest"
require_grep '^created_at=' "$tmpdir/archive.manifest"
require_grep '^hol_repo=https://github.com/HOL-Theorem-Prover/HOL.git$' "$tmpdir/archive.manifest"
require_grep "^hol_rev=$(holbuild_pinned_hol_rev)$" "$tmpdir/archive.manifest"
require_grep '^target ATheory$' "$tmpdir/archive.manifest"

import_log=$tmpdir/import.log
HOLBUILD_CACHE="$import_cache" "$HOLBUILD_BIN" import "$archive" > "$import_log" 2>&1
require_grep "imported 2 cache action" "$import_log"

rm -rf "$project/.holbuild"
restore_log=$tmpdir/restore.log
(cd "$project" && HOLBUILD_CACHE="$import_cache" HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build ATheory) > "$restore_log" 2>&1
require_grep "cache hit: BTheory" "$restore_log"
require_grep "cache hit: ATheory" "$restore_log"
require_grep "BTheory restored from cache" "$restore_log"
require_grep "ATheory restored from cache" "$restore_log"
require_file "$project/.holbuild/packages/dep/obj/src/BTheory.dat"
require_file "$project/.holbuild/obj/src/ATheory.dat"
