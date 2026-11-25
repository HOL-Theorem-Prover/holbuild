#!/usr/bin/env bash
# The worker's module writer reads the headers of generated Theory.sml
# files that HOL's printer breaks over lines (a theory name of 55
# characters or more) or that follow more than 4 KiB of opens, and a
# theory whose header it can't read is reported and skipped without
# stopping the writer for the others.
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

if [[ ${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-0} != 1 ]]; then
  echo 'SKIP theory-module-headers: needs a HOL with theory modules (HOLBUILD_TEST_REQUIRE_THEORY_MODULES=1)'
  exit 0
fi

tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "headers"

[build]
members = ["src"]
TOML
# Forty parents with 100-character names, each of whose headers HOL's
# printer breaks, and whose names Opens's Theory.sml opens in some 4 KiB
# before its own header.
parent=ParentOfTheHeaderTestWithANameLongEnoughForThePrinterToBreakItsHeaderLineAndForItsChildsOpens
parents=()
for i in $(seq -w 1 40); do
  parents+=("$parent$i")
  cat > "$project/src/$parent${i}Script.sml" <<SML
Theory $parent$i
Ancestors bool

Theorem parent_thm:
  T
Proof
  simp[]
QED
SML
done
cat > "$project/src/OpensScript.sml" <<SML
Theory Opens
Ancestors ${parents[*]}

Theorem opens_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors Opens

Theorem c_thm:
  T
Proof
  ACCEPT_TAC opens_thm
QED
SML

hb() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@")
}

hb build OpensTheory > "$tmpdir/build.log" 2>&1 || { cat "$tmpdir/build.log" >&2; exit 1; }
generated=$project/.holbuild/obj/src
# The header is broken over lines, or comes after 4 KiB.
grep -Pzq 'thyname =\n\s*"'"${parents[0]}"'"' "$generated/${parents[0]}Theory.sml" || {
  echo "${parents[0]}Theory.sml has its header on one line:" >&2; head -30 "$generated/${parents[0]}Theory.sml" >&2; exit 1; }
opens_prefix=$(grep -bo 'structure TDB' "$generated/OpensTheory.sml" | head -1 | cut -d: -f1)
[[ $opens_prefix -gt 4096 ]] || { echo "OpensTheory.sml's header starts at byte $opens_prefix" >&2; exit 1; }

hb action-spec --upload CTheory > "$tmpdir/batch.txt"
spec_c=$(awk '$1 == "action" && $5 == "headers:CTheory" { print $4 }' "$tmpdir/batch.txt")
[[ -n $spec_c ]] || { cat "$tmpdir/batch.txt" >&2; exit 1; }

# A file with no theory header, put first in the writer's list.
printf 'structure brokenTheory = struct end\n' > "$tmpdir/brokenTheory.sml"

cache=$tmpdir/worker
link_hol_toolchain_cache "$cache"
mkdir -p "$tmpdir/cwd"
(cd "$tmpdir/cwd" &&
   HOLBUILD_CACHE=$cache HOLBUILD_TEST_WRITER_THEORY=$tmpdir/brokenTheory.sml \
     "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec_c" \
     --cache-limit-gb 1000 --result "$tmpdir/c.result") > "$tmpdir/c.log" 2>&1 ||
  { cat "$tmpdir/c.log" "$tmpdir/c.result" >&2; exit 1; }
require_grep '^status=built$' "$tmpdir/c.result"
# The writer ran past the unreadable header and wrote every project
# theory's module.
require_grep 'modules_writer=ran,.*error:1' "$tmpdir/c.log"
require_grep 'modules_examples=.*error:brokenTheory(no_theory_header)' "$tmpdir/c.log"
for theory in "${parents[@]}" Opens; do
  compgen -G "$cache/theory-modules/*/*-$theory-*.pmo" > /dev/null || {
    echo "the writer wrote no module for $theory" >&2; cat "$tmpdir/c.log" >&2; exit 1; }
done
