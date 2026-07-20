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

dep=$tmpdir/dep
project=$tmpdir/project
mkdir -p "$dep/src" "$project/src"

cat > "$dep/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "dep"

[build]
members = ["src"]
TOML
cat > "$dep/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.5); ACCEPT_TAC TRUTH g);
Theorem dep_slow_thm:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML

dep_rev=$(init_git_repo "$dep")
{
  write_schema2_prelude
  cat <<TOML
[project]
name = "consumer"

[build]
members = ["src"]

[dependencies.dep]
git = "$dep"
rev = "$dep_rev"
TOML
} > "$project/holproject.toml"
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
Theorem root_fast_thm:
  T
Proof
  ACCEPT_TAC ATheory.dep_slow_thm
QED
val _ = export_theory();
SML

build_log=$tmpdir/build.log
(cd "$project" && "$HOLBUILD_BIN" build --no-cache --trace-steps --tactic-timeout 0.1 BTheory) > "$build_log" 2>&1
require_file "$project/.holbuild/packages/dep/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"
if grep -q "tactic timed out while building ATheory" "$build_log"; then
  echo "dependency package used root tactic timeout" >&2
  exit 1
fi
if find "$project/.holbuild/checkpoints/dep" -type f -print -quit 2>/dev/null | grep -q .; then
  echo "dependency package created checkpoint artifacts" >&2
  find "$project/.holbuild/checkpoints/dep" -type f -print >&2
  exit 1
fi
if ! find "$project/.holbuild/checkpoints/consumer" -type f -name '*.save' -print -quit 2>/dev/null | grep -q .; then
  echo "root package did not retain its requested checkpoints" >&2
  exit 1
fi
if [[ -e "$project/.holbuild/logs/current/dep/ATheory/proof-trace.log" ]]; then
  echo "dependency package enabled proof-step tracing" >&2
  exit 1
fi
root_trace="$project/.holbuild/logs/current/consumer/BTheory/proof-trace.log"
require_file "$root_trace"
require_grep "holbuild proof-ir plan theorem=root_fast_thm steps=" "$root_trace"

passing_build_log=$tmpdir/passing-build.log
(cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 1.0 BTheory) > "$passing_build_log" 2>&1
require_file "$project/.holbuild/packages/dep/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"
if grep -q "tactic_timeout=\|proof_steps=\|goalfrag=" "$project/.holbuild/dep/dep/src/AScript.sml.key" "$project/.holbuild/dep/consumer/src/BScript.sml.key"; then
  echo "execution policy leaked into final action metadata" >&2
  exit 1
fi

changed_root_timeout_log=$tmpdir/changed-root-timeout.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build --tactic-timeout 2.0 BTheory) > "$changed_root_timeout_log" 2>&1
require_grep "ATheory is up to date" "$changed_root_timeout_log"
require_grep "BTheory is up to date" "$changed_root_timeout_log"
if grep -q "tactic_timeout=\|proof_steps=\|goalfrag=" "$project/.holbuild/dep/dep/src/AScript.sml.key" "$project/.holbuild/dep/consumer/src/BScript.sml.key"; then
  echo "changed root timeout leaked into final action metadata" >&2
  exit 1
fi

python3 - "$HOLBUILD_CACHE" <<'PY'
import pathlib
import sys
for manifest in pathlib.Path(sys.argv[1]).glob('actions/*/manifest'):
    lines = [line for line in manifest.read_text().splitlines() if not line.startswith('proof-timeout=')]
    manifest.write_text('\n'.join(lines) + '\n')
PY
rm -rf "$project/.holbuild"
legacy_cache_log=$tmpdir/legacy-cache.log
(cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build --tactic-timeout 180 BTheory) > "$legacy_cache_log" 2>&1
require_file "$project/.holbuild/packages/dep/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"
if grep -q "insufficient tactic-timeout contract" "$legacy_cache_log"; then
  echo "legacy cache manifest without proof-timeout did not satisfy larger timeout" >&2
  exit 1
fi

root_timeout_project=$tmpdir/root-timeout
mkdir -p "$root_timeout_project/src"
cat > "$root_timeout_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "root-timeout"

[build]
members = ["src"]
TOML
cat > "$root_timeout_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.5); ACCEPT_TAC TRUTH g);
Theorem root_slow_thm:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML

root_timeout_log=$tmpdir/root-timeout.log
if (cd "$root_timeout_project" && "$HOLBUILD_BIN" build --tactic-timeout 0.1 ATheory) > "$root_timeout_log" 2>&1; then
  echo "expected root project tactic to time out" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building ATheory: slow_tac" "$root_timeout_log"
require_grep "theorem: root_slow_thm (line " "$root_timeout_log"
require_grep "source: .*AScript.sml:" "$root_timeout_log"
require_grep "failed tactic top input goal:" "$root_timeout_log"
require_grep "failed tactic input goals: 1" "$root_timeout_log"

root_timeout_again_log=$tmpdir/root-timeout-again.log
if (cd "$root_timeout_project" && "$HOLBUILD_BIN" build --tactic-timeout 0.1 ATheory) > "$root_timeout_again_log" 2>&1; then
  echo "expected repeated root project tactic to time out" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in root_slow_thm" "$root_timeout_again_log"
require_grep "failed tactic top input goal:" "$root_timeout_again_log"
require_grep "failed tactic input goals: 1" "$root_timeout_again_log"

root_default_project=$tmpdir/root-default
mkdir -p "$root_default_project/src"
cp "$root_timeout_project/holproject.toml" "$root_default_project/holproject.toml"
cat > "$root_default_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem root_default_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
(cd "$root_default_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/root-default.log" 2>&1
require_file "$root_default_project/.holbuild/obj/src/ATheory.dat"
if grep -q "tactic_timeout=\|proof_steps=\|goalfrag=" "$root_default_project/.holbuild/dep/root-timeout/src/AScript.sml.key"; then
  echo "default root execution policy leaked into final action metadata" >&2
  exit 1
fi

mutate_timeout_field() {
  local path=$1
  local mode=$2
  python3 - "$path" "$mode" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
prefix = "proof_timeout="
lines = path.read_text().splitlines()
if not any(line.startswith(prefix) for line in lines):
    raise SystemExit(f"missing {prefix} field in {path}")

replacement = {
    "absent": [],
    "malformed": ["proof_timeout=180.0junk"],
    "duplicate": ["proof_timeout=1.0", "proof_timeout=180.0"],
}[mode]
result = []
inserted = False
for line in lines:
    if line.startswith(prefix):
        if not inserted:
            result.extend(replacement)
            inserted = True
    else:
        result.append(line)
path.write_text("\n".join(result) + "\n")
PY
}

contract_project=$tmpdir/timeout-contract-hardening
mkdir -p "$contract_project/src"
cat > "$contract_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "timeout-contract-hardening"

[build]
members = ["src"]
TOML
cat > "$contract_project/src/ContractScript.sml" <<'SML'
Theory Contract
Ancestors bool

Theorem first_contract_thm:
  T
Proof
  simp[]
QED

Theorem second_contract_thm:
  T
Proof
  simp[]
QED
SML

contract_initial_log=$tmpdir/contract-initial.log
(cd "$contract_project" && "$HOLBUILD_BIN" build --no-cache --tactic-timeout 180 ContractTheory) > "$contract_initial_log" 2>&1
require_grep "ContractTheory built" "$contract_initial_log"
contract_metadata="$contract_project/.holbuild/dep/timeout-contract-hardening/src/ContractScript.sml.key"
require_grep '^proof_timeout=180.0$' "$contract_metadata"
contract_metadata_valid=$tmpdir/contract-metadata.valid
cp "$contract_metadata" "$contract_metadata_valid"
contract_checkpoints_valid=$tmpdir/contract-checkpoints.valid
cp -R "$contract_project/.holbuild/checkpoints" "$contract_checkpoints_valid"
mapfile -t contract_checkpoint_ok_files < <(
  grep -rl '^proof_timeout=180.0$' "$contract_project/.holbuild/checkpoints" --include='*.ok'
)
if [[ ${#contract_checkpoint_ok_files[@]} -eq 0 ]]; then
  echo "initial finite build produced no timeout-bearing theorem checkpoints" >&2
  exit 1
fi

mutate_timeout_field "$contract_metadata" absent
metadata_absent_log=$tmpdir/metadata-absent.log
(cd "$contract_project" && "$HOLBUILD_BIN" --verbose build --no-cache --tactic-timeout 60 ContractTheory) > "$metadata_absent_log" 2>&1
require_grep "ContractTheory is up to date" "$metadata_absent_log"

for invalid_mode in malformed duplicate; do
  cp "$contract_metadata_valid" "$contract_metadata"
  mutate_timeout_field "$contract_metadata" "$invalid_mode"
  invalid_metadata_log=$tmpdir/metadata-$invalid_mode.log
  (cd "$contract_project" && "$HOLBUILD_BIN" --verbose build --no-cache --tactic-timeout 60 ContractTheory) > "$invalid_metadata_log" 2>&1
  require_grep "ContractTheory built" "$invalid_metadata_log"
  if grep -q "ContractTheory is up to date" "$invalid_metadata_log"; then
    echo "$invalid_mode proof_timeout metadata satisfied a finite timeout request" >&2
    cat "$invalid_metadata_log" >&2
    exit 1
  fi
done

restore_contract_checkpoints() {
  rm -rf "$contract_project/.holbuild/checkpoints"
  cp -R "$contract_checkpoints_valid" "$contract_project/.holbuild/checkpoints"
  cp "$contract_metadata_valid" "$contract_metadata"
}

restore_contract_checkpoints
mapfile -t contract_checkpoint_ok_files < <(
  grep -rl '^proof_timeout=180.0$' "$contract_project/.holbuild/checkpoints" --include='*.ok'
)
for checkpoint_ok in "${contract_checkpoint_ok_files[@]}"; do
  mutate_timeout_field "$checkpoint_ok" absent
done
checkpoint_absent_log=$tmpdir/checkpoint-absent.log
(cd "$contract_project" && "$HOLBUILD_BIN" build --no-cache --tactic-timeout 60 ContractTheory) > "$checkpoint_absent_log" 2>&1
require_grep "from: theorem-context checkpoint after" "$checkpoint_absent_log"
require_grep "ContractTheory built" "$checkpoint_absent_log"

for invalid_mode in malformed duplicate; do
  restore_contract_checkpoints
  mapfile -t contract_checkpoint_ok_files < <(
    grep -rl '^proof_timeout=180.0$' "$contract_project/.holbuild/checkpoints" --include='*.ok'
  )
  for checkpoint_ok in "${contract_checkpoint_ok_files[@]}"; do
    mutate_timeout_field "$checkpoint_ok" "$invalid_mode"
  done
  invalid_checkpoint_log=$tmpdir/checkpoint-$invalid_mode.log
  (cd "$contract_project" && "$HOLBUILD_BIN" build --no-cache --tactic-timeout 60 ContractTheory) > "$invalid_checkpoint_log" 2>&1
  require_grep "ContractTheory built" "$invalid_checkpoint_log"
  if grep -q "from: theorem-context checkpoint after" "$invalid_checkpoint_log"; then
    echo "$invalid_mode proof_timeout checkpoint satisfied a finite timeout request" >&2
    cat "$invalid_checkpoint_log" >&2
    exit 1
  fi
done
