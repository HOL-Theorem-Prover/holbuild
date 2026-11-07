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

cat > "$dep/src/UnusedScript.sml" <<'SML'
Theory Unused
Ancestors bool
val _ = raise Fail "unselected theory executed";
SML
dep_rev=$(init_git_repo "$dep")
unused=$tmpdir/unused
mkdir -p "$unused/src"
sed 's/name = "dep"/name = "unused"/' "$dep/holproject.toml" > "$unused/holproject.toml"
cat > "$unused/src/DormantScript.sml" <<'SML'
Theory Dormant
Ancestors bool
val _ = raise Fail "unselected package executed";
SML
unused_rev=$(init_git_repo "$unused")
{
  write_schema2_prelude
  cat <<TOML
[project]
name = "consumer"

[build]
members = ["src"]
tactic_timeout = 0.1

[dependencies.dep]
git = "$dep"
rev = "$dep_rev"

[dependencies.unused]
git = "$unused"
rev = "$unused_rev"
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

# Audit scope instruments selected dependencies, while ordinary consumer builds
# above leave them alone. The unused dependency theory must never execute.
dep_metadata=$project/.holbuild/dep/dep/src/AScript.sml.key
root_metadata=$project/.holbuild/dep/consumer/src/BScript.sml.key
grep '^input_key=' "$dep_metadata" > "$tmpdir/dep-root-input-key"
grep '^input_key=' "$root_metadata" > "$tmpdir/root-root-input-key"
audit_log=$tmpdir/audit.log
if (cd "$project" && "$HOLBUILD_BIN" build --force=full --no-cache --proof-scope=all --tactic-timeout 0.1 BTheory) > "$audit_log" 2>&1; then
  echo "expected dependency tactic to time out in audit scope" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building ATheory: slow_tac" "$audit_log"
require_grep "theorem: dep_slow_thm (line " "$audit_log"
require_grep "source: .*AScript.sml:" "$audit_log"
if grep -q "warning: proof-scope=all" "$audit_log"; then
  echo "full source audit printed an incomplete-audit warning" >&2
  exit 1
fi
audit_default_log=$tmpdir/audit-default.log
if (cd "$project" && "$HOLBUILD_BIN" build --force=full --no-cache --proof-scope all BTheory) > "$audit_default_log" 2>&1; then
  echo "expected dependency tactic to use the project default timeout" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building ATheory: slow_tac" "$audit_default_log"

audit_passing_log=$tmpdir/audit-passing.log
(cd "$project" && "$HOLBUILD_BIN" build --force=full --no-cache --proof-scope all --tactic-timeout 1 BTheory) > "$audit_passing_log" 2>&1
require_grep "ATheory built" "$audit_passing_log"
require_grep "BTheory built" "$audit_passing_log"
require_no_file "$project/.holbuild/packages/dep/obj/src/UnusedTheory.dat"
require_no_file "$project/.holbuild/packages/unused/obj/src/DormantTheory.dat"
if [[ -d "$project/.holbuild/checkpoints/unused" ]]; then
  echo "audit scope created checkpoints for an unselected package" >&2
  exit 1
fi
grep '^input_key=' "$dep_metadata" > "$tmpdir/dep-audit-input-key"
grep '^input_key=' "$root_metadata" > "$tmpdir/root-audit-input-key"
cmp "$tmpdir/dep-root-input-key" "$tmpdir/dep-audit-input-key"
cmp "$tmpdir/root-root-input-key" "$tmpdir/root-audit-input-key"

cp "$dep_metadata" "$tmpdir/dep-audit.key"
cp "$root_metadata" "$tmpdir/root-audit.key"
for scope in root all; do
  reuse_log=$tmpdir/reuse-$scope.log
  (cd "$project" && "$HOLBUILD_BIN" --verbose build --proof-scope "$scope" --tactic-timeout 2 BTheory) > "$reuse_log" 2>&1
  require_grep "ATheory is up to date" "$reuse_log"
  require_grep "BTheory is up to date" "$reuse_log"
  cmp "$dep_metadata" "$tmpdir/dep-audit.key"
  cmp "$root_metadata" "$tmpdir/root-audit.key"
done
require_grep "warning: proof-scope=all.*up-to-date.*cache-restored" "$tmpdir/reuse-all.log"
for flag in --force=full --no-cache; do
  warning_log=$tmpdir/warning.log
  (cd "$project" && "$HOLBUILD_BIN" build --dry-run --proof-scope=all "$flag" BTheory) > "$warning_log" 2>&1
  require_grep "warning: proof-scope=all.*up-to-date.*cache-restored" "$warning_log"
done

for args in '--proof-scope=invalid' '--proof-scope invalid'; do
  invalid_scope_log=$tmpdir/invalid-scope.log
  # Intentional word splitting exercises both option spellings.
  if (cd "$project" && "$HOLBUILD_BIN" build $args BTheory) > "$invalid_scope_log" 2>&1; then
    echo "invalid proof scope accepted: $args" >&2
    exit 1
  fi
  require_grep 'proof-scope.*root.*all' "$invalid_scope_log"
done
missing_scope_log=$tmpdir/missing-scope.log
if (cd "$project" && "$HOLBUILD_BIN" build BTheory --proof-scope) > "$missing_scope_log" 2>&1; then
  echo "missing proof scope accepted" >&2
  exit 1
fi
require_grep 'proof-scope.*root.*all' "$missing_scope_log"

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
    "malformed-syntax": ["proof_timeout 180.0"],
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

for invalid_mode in malformed malformed-syntax duplicate; do
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

for invalid_mode in malformed malformed-syntax duplicate; do
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
