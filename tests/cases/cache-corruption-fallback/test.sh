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

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "cachebad"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build ATheory)
manifest=$(find "$HOLBUILD_CACHE/actions" -mindepth 2 -maxdepth 2 -name manifest | head -n 1)
require_file "$manifest"
dat_blob=$(awk '/^blob dat / {print $3}' "$manifest")
[[ -n "$dat_blob" ]] || { echo "could not find dat blob in cache manifest" >&2; exit 1; }
clean_dat_blob=$tmpdir/clean-dat.blob
cp "$HOLBUILD_CACHE/blobs/$dat_blob" "$clean_dat_blob"

printf 'corrupt dat blob\n' > "$HOLBUILD_CACHE/blobs/$dat_blob"
rm -rf "$project/.holbuild"
default_corrupt_blob_log=$tmpdir/default-corrupt-blob.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$default_corrupt_blob_log" 2>&1
require_grep "cache entry unusable" "$default_corrupt_blob_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"
cmp "$clean_dat_blob" "$HOLBUILD_CACHE/blobs/$dat_blob" || {
  echo "default cache verification did not repair the corrupt cache blob" >&2
  exit 1
}

cp "$clean_dat_blob" "$HOLBUILD_CACHE/blobs/$dat_blob"
rm -rf "$project/.holbuild"
repaired_blob_log=$tmpdir/repaired-blob.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$repaired_blob_log" 2>&1
require_grep "ATheory restored from cache" "$repaired_blob_log"
cmp "$project/.holbuild/obj/src/ATheory.dat" "$HOLBUILD_CACHE/blobs/$dat_blob" || {
  echo "repaired cache restore did not produce byte-identical dat output" >&2
  exit 1
}

noop_log=$tmpdir/noop.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$noop_log" 2>&1
if grep -q "ATheory built\|ATheory restored from cache" "$noop_log"; then
  echo "no-op build rebuilt or restored ATheory" >&2
  exit 1
fi

printf 'not a holbuild cache manifest\n' > "$manifest"
rm -rf "$project/.holbuild"
corrupt_manifest_log=$tmpdir/corrupt-manifest.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$corrupt_manifest_log" 2>&1
require_grep "cache entry unusable" "$corrupt_manifest_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"

awk '{ if ($1 == "blob" && $2 == "sig") print "blob sig not-a-sha1"; else print }' "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
rm -rf "$project/.holbuild"
invalid_hash_log=$tmpdir/invalid-hash.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$invalid_hash_log" 2>&1
require_grep "invalid sig blob hash" "$invalid_hash_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"

rm -rf "$project/.holbuild"
repaired_manifest_log=$tmpdir/repaired-manifest.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$repaired_manifest_log" 2>&1
require_grep "ATheory restored from cache" "$repaired_manifest_log"
