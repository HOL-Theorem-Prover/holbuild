#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# HOL reports a theory's CPU time from new_theory to export_theory.  A build
# that resumes from a checkpoint saved after new_theory reports the time the
# theory took in every process, not its own clock less the saving process's
# (which printed negative times such as ~16.8s).  The script spends 8s of CPU
# before new_theory, which no report counts, and 1.5s within the theory before
# its first checkpoint, which every report does.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

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
name = "resumed-theory-time"

[build]
members = ["src"]

[actions.ATheory]
cache = false
TOML

cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
fun spin_cpu seconds =
  let val timer = Timer.startCPUTimer ()
      fun loop () =
        if Time.< (#usr (Timer.checkCPUTimer timer), Time.fromReal seconds) then loop () else ()
  in loop () end;
val _ = spin_cpu 8.0;
val _ = new_theory "A";
val _ = spin_cpu 1.5;
Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem second:
  T
Proof
  SECOND_TAC
QED
val _ = TAIL;
val _ = export_theory();
SML

edit() {
  python3 - "$project/src/AScript.sml" "$1" "$2" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
assert text.count(sys.argv[2]) == 1, sys.argv[2]
path.write_text(text.replace(sys.argv[2], sys.argv[3]))
PY
}

build_log=$project/.holbuild/logs/current/resumed-theory-time/ATheory/build.log

build() {
  local log=$1
  if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$log" 2>&1; then
    cat "$log" >&2
    echo "expected the build to succeed" >&2
    exit 1
  fi
}

# The build's one report of the theory's time, in seconds, is at least the
# CPU spent within the theory and less than MAX.
theory_time=
check_theory_time() {
  local what=$1 max=$2 reports seconds
  reports=$(grep -c '^Theory "A" took .* to build$' "$build_log" || true)
  if [[ "$reports" != 1 ]]; then
    cat "$build_log" >&2
    echo "$what: expected one theory time report, found $reports" >&2
    exit 1
  fi
  seconds=$(sed -n 's/^Theory "A" took \([0-9.]*\)s to build$/\1/p' "$build_log")
  if [[ -z "$seconds" ]] || ! python3 -c 'import sys; t = float(sys.argv[1]); sys.exit(not (1.5 <= t < float(sys.argv[2])))' "$seconds" "$max"; then
    grep '^Theory "A" took' "$build_log" >&2
    echo "$what: expected a theory time from 1.5s to below ${max}s" >&2
    exit 1
  fi
  echo "$what: theory took ${seconds}s"
  theory_time=$seconds
}

# A build from the start: HOL's own report.
edit SECOND_TAC 'ACCEPT_TAC first'
edit TAIL '()'
build "$tmpdir/fresh.log"
check_theory_time "fresh build" 9.5
# A resumed build's time counts no more than the fresh build's did, but for
# the processes it adds: well under the CPU spent before new_theory.
resumed_max=$(python3 -c 'import sys; print(float(sys.argv[1]) + 4)' "$theory_time")

# A failure in the second proof resumes from the first theorem's checkpoint
# and saves a failed-prefix checkpoint.
edit 'ACCEPT_TAC first' 'FAIL_TAC "seed failure"'
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$tmpdir/seed.log" 2>&1; then
  cat "$tmpdir/seed.log" >&2
  echo "expected the seed build to fail" >&2
  exit 1
fi
require_grep "checkpoint after first" "$tmpdir/seed.log"
require_grep "seed failure" "$tmpdir/seed.log"

# Resumed from the failed-prefix checkpoint, a process whose clock started
# after the theory began.
edit 'FAIL_TAC "seed failure"' 'ACCEPT_TAC first'
build "$tmpdir/failed-prefix.log"
require_grep "from: failed-prefix checkpoint in second" "$tmpdir/failed-prefix.log"
check_theory_time "failed-prefix resume" "$resumed_max"

# Resumed from the last theorem's checkpoint, with no checkpoint left to save.
edit 'val _ = ();' 'val _ = ignore 1;'
build "$tmpdir/context.log"
require_grep "checkpoint after second" "$tmpdir/context.log"
check_theory_time "theorem checkpoint resume" "$resumed_max"
