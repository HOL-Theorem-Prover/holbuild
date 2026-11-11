#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

mkdir -p "$tmpdir/project/src"
cat > "$tmpdir/project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"
[project]
name = "slow"
[build]
members = ["src"]
tactic_timeout = 1.0
TOML
cat > "$tmpdir/project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.7); ALL_TAC g);
Theorem slow_success:
  T
Proof
  slow_tac >> simp[]
QED
val _ = export_theory();
SML

(cd "$tmpdir/project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/build.log" 2>&1 ||
  { cat "$tmpdir/build.log" >&2; exit 1; }
log=$tmpdir/project/.holbuild/logs/current/slow/ATheory/build.log
collector=$HOLBUILD_ROOT/tools/slow-proof-steps.py
python3 "$collector" "$log" > "$tmpdir/steps.tsv" 2> "$tmpdir/coverage.log"
require_grep $'slow_success\t0\tstep\tok\t[0-9.]*\t1000.000\tslow_tac' "$tmpdir/steps.tsv"
require_grep '1/1 logs instrumented' "$tmpdir/coverage.log"

# Old build logs and restored actions without a retained original log are
# unknown coverage, not evidence of zero near-limit steps.
printf 'Saved theorem "old"\n' > "$tmpdir/old.log"
cat > "$tmpdir/batch.json" <<'JSON'
{"state":"done","actions":[{"theory":"slow:ATheory","input_key":"old","log_sha256":null}]}
JSON
python3 "$collector" "$tmpdir/old.log" --batch "$tmpdir/batch.json" \
  --cache-url https://unused.example.org > "$tmpdir/old.tsv" 2> "$tmpdir/old-coverage.log"
[[ $(wc -l < "$tmpdir/old.tsv") -eq 1 ]]
require_grep 'timings unavailable: slow:ATheory@old' "$tmpdir/old-coverage.log"
require_grep '0/2 logs instrumented' "$tmpdir/old-coverage.log"

# An evicted log blob must not discard earlier rows or skip later actions.
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=
url=
while [[ $# -gt 0 ]]; do
  case $1 in
    --output) out=$2; shift 2 ;;
    *) url=$1; shift ;;
  esac
done
if [[ $url == */cas/000* ]]; then
  echo 'curl: (22) The requested URL returned error: 404' >&2
  exit 22
fi
cp "$HOLBUILD_TEST_STEP_LOG" "$out"
SH
chmod +x "$tmpdir/bin/curl"
python3 - "$tmpdir/batch-fetch.json" <<'PY'
import json
import sys
actions = [dict(theory=name, input_key=name, log_sha256=sha)
           for name, sha in (("before", "1" * 64), ("missing", "0" * 64),
                             ("cached", None), ("after", "2" * 64))]
with open(sys.argv[1], "w") as output:
    json.dump(dict(state="done", actions=actions), output)
PY
PATH="$tmpdir/bin:$PATH" HOLBUILD_TEST_STEP_LOG="$log" python3 "$collector" \
  --batch "$tmpdir/batch-fetch.json" --cache-url https://unused.example.org \
  > "$tmpdir/fetched.tsv" 2> "$tmpdir/fetched-coverage.log"
require_grep '^before@before' "$tmpdir/fetched.tsv"
require_grep '^after@after' "$tmpdir/fetched.tsv"
require_grep 'timings unavailable: missing@missing (curl exited 22:' "$tmpdir/fetched-coverage.log"
require_grep 'timings unavailable: cached@cached' "$tmpdir/fetched-coverage.log"
require_grep '2/4 logs instrumented' "$tmpdir/fetched-coverage.log"
