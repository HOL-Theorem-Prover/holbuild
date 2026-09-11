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
name = "theory-tactic-timeout"

[build]
members = ["src"]
tactic_timeout = 1.0

[build.theory_tactic_timeouts]
"src/SlowScript.sml" = 3.0
"src/AlternateScript.sml" = 0.1
TOML

cat > "$project/src/BaseScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Base";
Theorem base_ok: T Proof simp[] QED
val _ = export_theory();
SML
cat > "$project/src/SlowScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BaseTheory;
val _ = new_theory "Slow";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 1.5); ACCEPT_TAC TRUTH g);
Theorem slow_ok: T Proof slow_tac QED
val _ = export_theory();
SML
cat > "$project/src/AppScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open SlowTheory;
val _ = new_theory "App";
Theorem app_ok: T Proof simp[] QED
val _ = export_theory();
SML
cat > "$project/src/AlternateScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BaseTheory;
val _ = new_theory "Alternate";
Theorem alternate_ok: T Proof simp[] QED
val _ = export_theory();
SML
cat > "$project/src/Helper.sml" <<'SML'
val helper = 1
SML

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log"
require_grep "theory tactic_timeout: src/SlowScript.sml = 3" "$tmpdir/context.log"
(cd "$project" && "$HOLBUILD_BIN" build AppTheory) > "$tmpdir/build.log" 2>&1
require_grep "proof_timeout=1.0" "$project/.holbuild/dep/theory-tactic-timeout/src/BaseScript.sml.key"
require_grep "proof_timeout=3.0" "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"
require_grep "proof_timeout=1.0" "$project/.holbuild/dep/theory-tactic-timeout/src/AppScript.sml.key"

# An explicit CLI timeout replaces all manifest policy, including node-local policy.
(cd "$project" && "$HOLBUILD_BIN" build --force --tactic-timeout 4 AppTheory) > "$tmpdir/cli.log" 2>&1
require_grep "proof_timeout=4.0" "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"

# Zero disables only the named theory.
python3 - "$project/holproject.toml" <<'PY'
from pathlib import Path
p = Path(__import__('sys').argv[1])
p.write_text(p.read_text().replace('"src/SlowScript.sml" = 3.0', '"src/SlowScript.sml" = 0'))
PY
(cd "$project" && "$HOLBUILD_BIN" build --force AppTheory) > "$tmpdir/disabled.log" 2>&1
require_grep "proof_timeout=none" "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"
require_grep "proof_timeout=1.0" "$project/.holbuild/dep/theory-tactic-timeout/src/BaseScript.sml.key"

# Invalid entries receive focused diagnostics.
for path in src/MissingScript.sml src/Helper.sml @not-a-source; do
  invalid=$tmpdir/invalid
  cp -R "$project" "$invalid"
  python3 - "$invalid/holproject.toml" "$path" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
start = text.index('[build.theory_tactic_timeouts]')
text = text[:start] + '[build.theory_tactic_timeouts]\n"' + sys.argv[2] + '" = 1\n'
p.write_text(text)
PY
  if (cd "$invalid" && "$HOLBUILD_BIN" build AppTheory) > "$tmpdir/invalid.log" 2>&1; then
    echo "invalid theory_tactic_timeouts entry was accepted" >&2
    exit 1
  fi
  require_grep "theory_tactic_timeouts" "$tmpdir/invalid.log"
  rm -rf "$invalid"
done
