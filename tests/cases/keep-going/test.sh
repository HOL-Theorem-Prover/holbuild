#!/usr/bin/env bash
set -euo pipefail
HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"

for jobs in 1 3; do
  project=$tmpdir/project-$jobs
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[project]
name = "keep_going_$jobs"
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"
[build]
members = ["src"]
TOML
  for name in BadA BadB; do
    cat > "$project/src/${name}Script.sml" <<SML
Theory $name
Ancestors bool
val _ = raise Fail "independent failure $name";
SML
  done
  cat > "$project/src/GoodScript.sml" <<'SML'
Theory Good
Ancestors bool
val _ = OS.Process.sleep (Time.fromReal 0.5);
Theorem good: T
Proof
  ACCEPT_TAC TRUTH
QED
SML
  cat > "$project/src/BlockedScript.sml" <<'SML'
Theory Blocked
Ancestors BadA
val _ = raise Fail "BLOCKED_MUST_NOT_RUN";
SML
  cat > "$project/src/TransitiveScript.sml" <<'SML'
Theory Transitive
Ancestors Blocked
val _ = raise Fail "TRANSITIVE_MUST_NOT_RUN";
SML
  if (cd "$project" && "$HOLBUILD_BIN" -j"$jobs" build BadATheory BadBTheory GoodTheory TransitiveTheory) \
      > "$tmpdir/build-$jobs.log" 2>&1; then
    echo 'expected independent build failures' >&2
    exit 1
  fi
  require_grep 'independent failure BadA' "$tmpdir/build-$jobs.log"
  require_grep 'independent failure BadB' "$tmpdir/build-$jobs.log"
  require_grep '2 build failures:' "$tmpdir/build-$jobs.log"
  require_grep 'BlockedTheory skipped because of BadATheory' "$tmpdir/build-$jobs.log"
  require_grep 'TransitiveTheory skipped because of BadATheory' "$tmpdir/build-$jobs.log"
  require_grep 'GoodTheory built' "$tmpdir/build-$jobs.log"
  require_file "$project/.holbuild/obj/src/GoodTheory.dat"
  if grep -q 'BLOCKED_MUST_NOT_RUN\|TRANSITIVE_MUST_NOT_RUN' "$tmpdir/build-$jobs.log"; then
    cat "$tmpdir/build-$jobs.log" >&2
    exit 1
  fi
  for name in BadA BadB Blocked Transitive; do
    [[ ! -e "$project/.holbuild/obj/src/${name}Theory.dat" ]]
  done
  (cd "$project" && "$HOLBUILD_BIN" build GoodTheory) > "$tmpdir/good-$jobs.log" 2>&1
  if grep -q 'GoodTheory built' "$tmpdir/good-$jobs.log"; then
    cat "$tmpdir/good-$jobs.log" >&2
    exit 1
  fi
done
