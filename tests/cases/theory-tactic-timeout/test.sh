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
tactic_timeout = 0.1

[build.theory_tactic_timeouts]
"src/SlowScript.sml" = 1.0
"src/AlternateScript.sml" = 0.01
TOML

cat > "$project/src/BaseScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Base";
val _ = export_theory();
SML
cat > "$project/src/SlowScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BaseTheory;
val _ = new_theory "Slow";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.35); ACCEPT_TAC TRUTH g);
Theorem slow_ok:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML
cat > "$project/src/AppScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open SlowTheory;
val _ = new_theory "App";
val _ = export_theory();
SML
cat > "$project/src/AlternateScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BaseTheory;
val _ = new_theory "Alternate";
val _ = export_theory();
SML
cat > "$project/src/Helper.sml" <<'SML'
val helper = 1
SML

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log"
require_grep "theory tactic_timeout: src/SlowScript.sml = 1" "$tmpdir/context.log"
(cd "$project" && "$HOLBUILD_BIN" build AppTheory) > "$tmpdir/build.log" 2>&1
require_grep "proof_timeout=0.1" "$project/.holbuild/dep/theory-tactic-timeout/src/BaseScript.sml.key"
require_grep "proof_timeout=1.0" "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"
require_grep "proof_timeout=0.1" "$project/.holbuild/dep/theory-tactic-timeout/src/AppScript.sml.key"

# An explicit CLI timeout replaces all manifest policy, including node-local policy.
(cd "$project" && "$HOLBUILD_BIN" build --force --tactic-timeout 2 AppTheory) > "$tmpdir/cli.log" 2>&1
require_grep "proof_timeout=2.0" "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"

# Zero disables only the named theory.
python3 - "$project/holproject.toml" <<'PY'
from pathlib import Path
p = Path(__import__('sys').argv[1])
p.write_text(p.read_text().replace('"src/SlowScript.sml" = 1.0', '"src/SlowScript.sml" = 0'))
PY
(cd "$project" && "$HOLBUILD_BIN" build --force AppTheory) > "$tmpdir/disabled.log" 2>&1
require_grep "proof_timeout=none" "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"
require_grep "proof_timeout=0.1" "$project/.holbuild/dep/theory-tactic-timeout/src/BaseScript.sml.key"

# Entries may name the theory instead of its script.
python3 - "$project/holproject.toml" <<'PY'
from pathlib import Path
p = Path(__import__('sys').argv[1])
p.write_text(p.read_text().replace('"src/SlowScript.sml" = 0', '"SlowTheory" = 1.0'))
PY
(cd "$project" && "$HOLBUILD_BIN" build --force AppTheory) > "$tmpdir/named.log" 2>&1
require_grep "proof_timeout=1.0" "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"

# Naming the same theory by path and by logical name is rejected.
duplicate=$tmpdir/duplicate
cp -R "$project" "$duplicate"
python3 - "$duplicate/holproject.toml" <<'PY'
from pathlib import Path
p = Path(__import__('sys').argv[1])
p.write_text(p.read_text().replace('"SlowTheory" = 1.0', '"SlowTheory" = 1.0\n"src/SlowScript.sml" = 2.0'))
PY
if (cd "$duplicate" && "$HOLBUILD_BIN" build AppTheory) > "$tmpdir/duplicate.log" 2>&1; then
  echo "duplicate theory_tactic_timeouts entries were accepted" >&2
  exit 1
fi
require_grep "build.theory_tactic_timeouts references SlowTheory more than once" "$tmpdir/duplicate.log"
rm -rf "$duplicate"

# Invalid entries receive focused diagnostics.
for path in src/MissingScript.sml src/Helper.sml @not-a-source MissingTheory Helper; do
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

# An absent build policy uses the default, while zero explicitly disables it.
# Remove node-local policies so these checks exercise the build-level setting.
python3 - "$project/holproject.toml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text().split('[build.theory_tactic_timeouts]')[0]
p.write_text(text.replace('tactic_timeout = 0.1\n', ''))
PY
(cd "$project" && "$HOLBUILD_BIN" build --force --skip-checkpoints --no-cache AppTheory) > "$tmpdir/default.log" 2>&1
require_grep '^proof_timeout=2.5$' "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"

printf 'tactic_timeout = 0\n' >> "$project/holproject.toml"
(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/manifest-zero-context.log"
require_grep '^build.tactic_timeout: none$' "$tmpdir/manifest-zero-context.log"
(cd "$project" && "$HOLBUILD_BIN" build --force --skip-checkpoints --no-cache AppTheory) > "$tmpdir/manifest-zero.log" 2>&1
require_grep '^proof_timeout=none$' "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"

# A local zero overrides a nonzero manifest value rather than inheriting it.
python3 - "$project/holproject.toml" <<'PY_EDIT'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('tactic_timeout = 0\n', 'tactic_timeout = 0.1\n'))
PY_EDIT
printf '[build]\ntactic_timeout = 0\n' > "$project/.holconfig.toml"
(cd "$project" && "$HOLBUILD_BIN" build --force --skip-checkpoints --no-cache AppTheory) > "$tmpdir/local-zero.log" 2>&1
require_grep '^proof_timeout=none$' "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"

# CLI zero still wins over both configured policies.
printf '[build]\ntactic_timeout = 0.1\n' > "$project/.holconfig.toml"
(cd "$project" && "$HOLBUILD_BIN" build --force --skip-checkpoints --no-cache --tactic-timeout 0 AppTheory) > "$tmpdir/cli-zero.log" 2>&1
require_grep '^proof_timeout=none$' "$project/.holbuild/dep/theory-tactic-timeout/src/SlowScript.sml.key"
