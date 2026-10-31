#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Project state and cache entries left by a holbuild that keyed everything by
# SHA-1 must read as misses: the theories rebuild once, with no error, no
# warning and no wrong cache hit.

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
cache=$tmpdir/cache
use_case_cache "$cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "upgrade"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_def = new_definition("a_def", ``a_const = T``);
val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``a_const``, REWRITE_TAC [a_def]);
val _ = export_theory();
SML

first_log=$tmpdir/first.log
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$first_log" 2>&1
require_grep "BTheory built" "$first_log"

# Rewrite everything holbuild wrote, outside the toolchains, into the SHA-1
# form: 40-hex keys and digests (in file contents and in file names), the
# *-sha1 metadata fields and the previous stat cache version.
python3 - "$project/.holbuild" "$cache" <<'PY'
import pathlib
import re
import sys

hex64 = re.compile(rb"\b[0-9a-f]{64}\b")
names = re.compile(r"[0-9a-f]{64}")

def old_form(data):
    data = hex64.sub(lambda m: m.group(0)[:40], data)
    data = re.sub(rb"([-_])sha256=", rb"\1sha1=", data)
    return data.replace(b"holbuild-stat-cache-v4", b"holbuild-stat-cache-v3")

rewritten = 0
for root in map(pathlib.Path, sys.argv[1:]):
    paths = [p for p in root.rglob("*")
             if "hol-toolchains" not in p.parts and not p.is_symlink()]
    for path in paths:
        if path.is_file():
            data = path.read_bytes()
            new = old_form(data)
            if new != data:
                path.write_bytes(new)
                rewritten += 1
    # Deepest first, so a renamed directory doesn't move paths still to visit.
    for path in sorted(paths, key=lambda p: len(p.parts), reverse=True):
        new_name = names.sub(lambda m: m.group(0)[:40], path.name)
        if new_name != path.name:
            path.rename(path.with_name(new_name))
            rewritten += 1

if rewritten == 0:
    sys.exit("found no SHA-256 keys or digests to rewrite")
PY

upgrade_log=$tmpdir/upgrade.log
(cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build BTheory) > "$upgrade_log" 2>&1 || {
  cat "$upgrade_log" >&2
  echo "build over SHA-1 state failed" >&2
  exit 1
}
require_grep "ATheory built" "$upgrade_log"
require_grep "BTheory built" "$upgrade_log"
if grep -Eqi "restored from cache|cache hit|warning|unusable|corrupt|error" "$upgrade_log"; then
  cat "$upgrade_log" >&2
  echo "SHA-1 state was not a clean miss" >&2
  exit 1
fi

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$second_log" 2>&1
if grep -Eq "built|restored" "$second_log"; then
  cat "$second_log" >&2
  echo "build after the upgrade rebuild was not up to date" >&2
  exit 1
fi

# gc collects the SHA-1 entries once they age out, and keeps the new ones.
old_entries() { find "$cache/actions" "$cache/blobs" -mindepth 1 -maxdepth 1 -regextype egrep -regex '.*/[0-9a-f]{40}'; }
[ -n "$(old_entries)" ] || { echo "no SHA-1 cache entries to collect" >&2; exit 1; }
new_entries() { find "$cache/actions" "$cache/blobs" -mindepth 1 -maxdepth 1 -regextype egrep -regex '.*/[0-9a-f]{64}' | sort; }
new_before=$(new_entries)
[ -n "$new_before" ] || { echo "no SHA-256 cache entries" >&2; exit 1; }
old_entries | while read -r entry; do find "$entry" -exec touch -h -d '30 days ago' {} +; done
(cd "$project" && "$HOLBUILD_BIN" gc --cache-only) > "$tmpdir/gc.log" 2>&1 || {
  cat "$tmpdir/gc.log" >&2
  echo "cache gc failed over SHA-1 entries" >&2
  exit 1
}
if [ -n "$(old_entries)" ]; then
  old_entries >&2
  echo "cache gc left SHA-1 entries behind" >&2
  exit 1
fi
if [ "$(new_entries)" != "$new_before" ]; then
  echo "cache gc removed live entries" >&2
  exit 1
fi
