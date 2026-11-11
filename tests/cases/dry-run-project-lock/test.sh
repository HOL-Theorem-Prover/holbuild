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
mkdir -p "$project/src" "$project/gen" "$project/scripts"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "dryrunlock"

[build]
members = ["src", "gen"]

[[generate]]
name = "make-theory"
command = ["sh", "-c", "echo ran >> gen.count; cp scripts/G.tmpl gen/GScript.sml"]
outputs = ["gen/GScript.sml"]
TOML
cat > "$project/scripts/G.tmpl" <<'SML'
Theory G
Theorem g_thm: T
Proof ACCEPT_TAC TRUTH
QED
SML

# A dry run runs generators, so it must not start while another holbuild
# holds the project lock.
mkdir -p "$project/.holbuild/locks"
ready=$tmpdir/holder.ready
python3 - "$project/.holbuild/locks/project.lock" "$ready" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "a+")
fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(sys.argv[2], "w").close()
time.sleep(25)
PY
holder=$!
for _ in $(seq 1 100); do
  [[ -f "$ready" ]] && break
  sleep 0.05
done
require_file "$ready"

dry_log=$tmpdir/dry.log
if (cd "$project" && "$HOLBUILD_BIN" build --dry-run GTheory) > "$dry_log" 2>&1; then
  kill "$holder" 2>/dev/null || true
  echo "dry run succeeded while the project lock was held" >&2
  cat "$dry_log" >&2
  exit 1
fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
require_grep "project is already being modified" "$dry_log"
require_no_file "$project/gen.count"

# With the lock free, the dry run still runs the generator.
(cd "$project" && "$HOLBUILD_BIN" build --dry-run GTheory) > "$tmpdir/free.log" 2>&1
require_file "$project/gen.count"
