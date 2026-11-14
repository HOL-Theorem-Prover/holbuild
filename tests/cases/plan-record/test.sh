#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Each scenario changes one planning input after a build recorded its plan
# and checks which way the next build planned. Builds run in check mode, so a
# plan from the record that differs from full planning in any source, node,
# edge, fact or key fails the build.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"
export HOLBUILD_PLAN_RECORD=check

hol_rev=$(holbuild_pinned_hol_rev)

theory() {
  local file=$1 name=$2 parent=${3:-}
  {
    echo 'open HolKernel Parse boolLib bossLib;'
    [[ -z "$parent" ]] || echo "open ${parent}Theory;"
    echo "val _ = new_theory \"$name\";"
    echo "val ${name,,}_thm = store_thm(\"${name,,}_thm\", \`\`T\`\`, ACCEPT_TAC TRUTH);"
    echo 'val _ = export_theory();'
  } > "$file"
}

# A chain A <- B <- C <- D and a library; EXTRA goes into the manifest.
make_project() {
  local dir=$1 extra=${2:-}
  mkdir -p "$dir/src"
  cat > "$dir/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$hol_rev"

[project]
name = "record"

[build]
members = ["src"]
$extra
TOML
  theory "$dir/src/AScript.sml" A
  theory "$dir/src/BScript.sml" B A
  theory "$dir/src/CScript.sml" C B
  theory "$dir/src/DScript.sml" D C
  echo 'structure Lib = struct val x = 1 end' > "$dir/src/Lib.sml"
  # A stat taken within a second of its file's last change is rehashed by
  # the next build; let the project age past that.
  sleep 1.1
}

# Plans DIR with ARGS and prints the line saying how it planned.
plan() {
  local dir=$1
  shift
  local log=$tmpdir/plan.log
  if ! (cd "$dir" && "$HOLBUILD_BIN" --verbose build --dry-run "$@") > "$log" 2>&1; then
    cat "$log" >&2
    echo "build --dry-run $* failed in $dir" >&2
    exit 1
  fi
  grep -m1 '^holbuild: plan: ' "$log" | sed 's/^holbuild: plan: //'
}

expect_plan() {
  local expected=$1 dir=$2
  shift 2
  local got
  got=$(plan "$dir" "$@")
  if [[ "$got" != "$expected"* ]]; then
    echo "$dir: expected plan '$expected', got '$got'" >&2
    exit 1
  fi
}

recorded_project() {
  local dir=$1
  make_project "$@"
  expect_plan "full (no plan record for these inputs)" "$dir"
}

# Edits FILE in place, keeping its size and modification time.
same_stat_edit() {
  local file=$1 from=$2 to=$3
  local stamp=$tmpdir/stamp
  touch -r "$file" "$stamp"
  local text
  text=$(sed "s/$from/$to/" "$file")
  printf '%s\n' "$text" > "$file"
  touch -r "$stamp" "$file"
}

noop() {
  local p=$tmpdir/noop
  recorded_project "$p"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
}

racy_entries_are_rehashed() {
  local p=$tmpdir/racy
  mkdir -p "$p"
  make_project "$p"
  touch "$p/src/Lib.sml"
  expect_plan "full (no plan record" "$p"
  # Lib.sml was recorded within a second of its change: its stat proves
  # nothing, so the next build hashes it again.
  expect_plan "from record (1 files rehashed, 0 keys changed)" "$p"
}

edit_with_restored_mtime() {
  local p=$tmpdir/restored-mtime
  recorded_project "$p"
  same_stat_edit "$p/src/AScript.sml" a_thm b_thm
  expect_plan "from record (1 files rehashed, 4 keys changed)" "$p"
}

rename_over_edit() {
  local p=$tmpdir/rename-over
  recorded_project "$p"
  sed 's/x = 1/x = 2/' "$p/src/Lib.sml" > "$p/src/Lib.sml.new"
  touch -r "$p/src/Lib.sml" "$p/src/Lib.sml.new"
  mv "$p/src/Lib.sml.new" "$p/src/Lib.sml"
  expect_plan "from record (1 files rehashed, 1 keys changed)" "$p"
}

# An edit that adds or removes a module mention changes the edited source's
# dependencies: the plan is made again over the recorded sources, and check
# mode compares it with full planning.
mention_added() {
  local p=$tmpdir/mention-added
  recorded_project "$p"
  sed -i 's/^open BTheory;/open BTheory ATheory;/' "$p/src/CScript.sml"
  expect_plan "from record (1 files rehashed, 2 keys changed, dependencies re-resolved)" "$p"
  # CScript.sml changed within a second of that build, so it is hashed again.
  expect_plan "from record (1 files rehashed, 0 keys changed)" "$p"
}

mention_removed() {
  local p=$tmpdir/mention-removed
  recorded_project "$p"
  sed -i 's/^open BTheory;//' "$p/src/CScript.sml"
  expect_plan "from record (1 files rehashed, 2 keys changed, dependencies re-resolved)" "$p"
  expect_plan "from record (1 files rehashed, 0 keys changed)" "$p"
}

# A new mention selects a source the record's plan left out.
mention_selects_source() {
  local p=$tmpdir/mention-selects
  make_project "$p"
  expect_plan "full (no plan record for these inputs)" "$p" CTheory
  echo 'val _ = Lib.x;' >> "$p/src/CScript.sml"
  expect_plan "from record (1 files rehashed, 2 keys changed, dependencies re-resolved)" "$p" CTheory
  expect_plan "from record (1 files rehashed, 0 keys changed)" "$p" CTheory
}

# A removed mention drops sources from the plan, and with them their inputs:
# the record written then is byte for byte what full planning writes.
mention_drops_sources() {
  local p=$tmpdir/mention-drops
  mkdir -p "$p/data"
  echo one > "$p/data/a.txt"
  make_project "$p" '
[actions.BTheory]
extra_inputs = ["data"]'
  expect_plan "full (no plan record for these inputs)" "$p" DTheory
  sed -i 's/^open CTheory;//' "$p/src/DScript.sml"
  sleep 1.1
  expect_plan "from record (1 files rehashed, 1 keys changed, dependencies re-resolved)" "$p" DTheory
  local record
  record=$(ls "$p"/.holbuild/plan/*)
  mv "$record" "$tmpdir/reresolved-record"
  expect_plan "full (no plan record for these inputs)" "$p" DTheory
  if ! cmp "$record" "$tmpdir/reresolved-record"; then
    echo "the record written from a re-resolved plan differs from full planning's" >&2
    exit 1
  fi
}

source_added() {
  local p=$tmpdir/source-added
  recorded_project "$p"
  theory "$p/src/EScript.sml" E D
  expect_plan "full (sources added, removed or renamed in $p/src)" "$p"
}

source_removed() {
  local p=$tmpdir/source-removed
  recorded_project "$p"
  rm "$p/src/DScript.sml"
  expect_plan "full (sources added, removed or renamed in $p/src)" "$p"
}

source_renamed() {
  local p=$tmpdir/source-renamed
  recorded_project "$p"
  mv "$p/src/Lib.sml" "$p/src/Lib2.sml"
  expect_plan "full (sources added, removed or renamed in $p/src)" "$p"
}

backup_file_in_source_dir() {
  local p=$tmpdir/backup-file
  recorded_project "$p"
  cp "$p/src/AScript.sml" "$p/src/AScript.sml~"
  cp "$p/src/AScript.sml" "$p/src/.AScript.sml.swp"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
}

extra_output_in_source_dir() {
  local p=$tmpdir/extra-output
  recorded_project "$p"
  echo output > "$p/src/report.txt"
  mkdir "$p/src/_build"
  echo output > "$p/src/_build/AScript.sml"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
}

# SML files a theory writes where discovery never looks, as under a
# dot-directory, are not sources: the plan can be recorded before it runs.
hidden_sml_outputs() {
  local p=$tmpdir/hidden-outputs
  make_project "$p"
  cat >> "$p/src/AScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs [".emit/RunML.sml", ".emit/json/T.sig", "_build/X.sml", ".Y.sml"]
SML
  sleep 1.1
  expect_plan "full (no plan record for these inputs)" "$p"
  if grep -q "plan record not written" "$tmpdir/plan.log"; then
    cat "$tmpdir/plan.log" >&2
    exit 1
  fi
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
}

extra_inputs() {
  local p=$tmpdir/extra-inputs
  mkdir -p "$p/data/dir" "$tmpdir/shared"
  echo one > "$p/data/a.txt"
  echo one > "$p/data/dir/one.txt"
  echo one > "$tmpdir/shared/one.txt"
  make_project "$p" '
[actions.ATheory]
extra_inputs = ["data/a.txt", "data/dir", "data/*.cfg"]'
  # A script may also declare inputs outside its package.
  cat >> "$p/src/AScript.sml" <<'SML'
fun holbuild_extra_deps (_ : string list) = ()
val _ = holbuild_extra_deps ["../../shared"]
SML
  sleep 1.1
  expect_plan "full (no plan record for these inputs)" "$p"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
  echo two > "$p/data/a.txt"
  expect_plan "from record (1 files rehashed, 4 keys changed)" "$p"
  sleep 1.1
  echo two > "$p/data/dir/two.txt"
  expect_plan "from record (" "$p"
  require_grep "keys changed" "$tmpdir/plan.log"
  if grep -q "0 keys changed" "$tmpdir/plan.log"; then
    echo "a new file in a declared input directory changed no key" >&2
    exit 1
  fi
  sleep 1.1
  echo two > "$p/data/two.cfg"
  expect_plan "from record (" "$p"
  if grep -q "0 keys changed" "$tmpdir/plan.log"; then
    echo "a new file matching a declared input glob changed no key" >&2
    exit 1
  fi
  # A file in a declared directory that becomes readable is an input.
  echo hidden > "$p/data/dir/hidden.txt"
  chmod 000 "$p/data/dir/hidden.txt"
  sleep 1.1
  expect_plan "from record (" "$p"
  sleep 1.1
  expect_plan "from record (" "$p"
  if [[ ! -r "$p/data/dir/hidden.txt" ]]; then
    chmod 644 "$p/data/dir/hidden.txt"
    expect_plan "from record (" "$p"
    if grep -q "0 keys changed" "$tmpdir/plan.log"; then
      echo "a declared input that became readable changed no key" >&2
      exit 1
    fi
  fi
  sleep 1.1
  echo two > "$tmpdir/shared/two.txt"
  expect_plan "from record (" "$p"
  if grep -q "0 keys changed" "$tmpdir/plan.log"; then
    echo "a new file in a declared input directory outside the package changed no key" >&2
    exit 1
  fi
  # An editor's lock link that leads nowhere skips the record, not the build.
  ln -s nowhere "$p/data/dir/.#one.txt"
  sleep 1.1
  plan "$p" > /dev/null
  require_grep "plan record not written: cannot stat" "$tmpdir/plan.log"
}

manifest_edit() {
  local p=$tmpdir/manifest-edit
  recorded_project "$p"
  echo '# edited' >> "$p/holproject.toml"
  expect_plan "full (no plan record for these inputs)" "$p"
}

holconfig_edit() {
  local p=$tmpdir/holconfig
  recorded_project "$p"
  printf '[build]\njobs = 2\n' > "$p/.holconfig.toml"
  expect_plan "full (no plan record for these inputs)" "$p"
}

holbuild_env_var() {
  local p=$tmpdir/env-var
  recorded_project "$p"
  HOLBUILD_TEST_PLAN_RECORD_UNUSED=1 expect_plan "full (no plan record for these inputs)" "$p"
  # Timing logs don't change planning.
  HOLBUILD_TIMING_LOG=$tmpdir/timing.log expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
  require_grep 'name=plan.record' "$tmpdir/timing.log"
}

targets_on_argv() {
  local p=$tmpdir/targets
  recorded_project "$p"
  expect_plan "full (no plan record for these inputs)" "$p" BTheory
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p" BTheory
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
  # A path target names the file its links lead to: once the link leads
  # elsewhere, full planning decides (here, that it names no source).
  mkdir "$p/aliases"
  ln -s ../src/AScript.sml "$p/aliases/AScript.sml"
  expect_plan "full (no plan record for these inputs)" "$p" aliases/AScript.sml
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p" aliases/AScript.sml
  ln -sfn ../src/BScript.sml "$p/aliases/AScript.sml"
  (cd "$p" && "$HOLBUILD_BIN" --verbose build --dry-run aliases/AScript.sml) > "$tmpdir/retarget.log" 2>&1 || true
  require_grep "holbuild: plan: full (no plan record for these inputs)" "$tmpdir/retarget.log"
}

deep_downstream_edit() {
  local p=$tmpdir/deep
  recorded_project "$p"
  printf '\n(* comment *)\n' >> "$p/src/AScript.sml"
  expect_plan "from record (1 files rehashed, 4 keys changed)" "$p"
  # That build recorded AScript.sml within a second of its change, so the
  # next one hashes it again; once it has aged, the stat suffices.
  sleep 1.1
  expect_plan "from record (1 files rehashed, 0 keys changed)" "$p"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
}

corrupt_records() {
  local p=$tmpdir/corrupt
  recorded_project "$p"
  local record
  record=$(ls "$p"/.holbuild/plan/*)
  head -c 1000 "$record" > "$record.part"
  mv "$record.part" "$record"
  expect_plan "full (malformed plan record: " "$p"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
  printf 'garbage\n' > "$record"
  expect_plan "full (malformed plan record: format" "$p"
  sed -i '1s/.*/holbuild-plan-record-v0/' "$record"
  expect_plan "full (malformed plan record: format" "$p"
  : > "$record"
  expect_plan "full (malformed plan record: " "$p"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
  # A record that cannot be written leaves the build as it was.
  chmod 555 "$p/.holbuild/plan"
  if [[ ! -w "$p/.holbuild/plan" ]]; then
    expect_plan "full (no plan record for these inputs)" "$p" CTheory
    require_grep "plan record not written: cannot write" "$tmpdir/plan.log"
  fi
  chmod 755 "$p/.holbuild/plan"
}

record_off() {
  local p=$tmpdir/off
  make_project "$p"
  HOLBUILD_PLAN_RECORD=off expect_plan "full (plan record is off)" "$p"
  require_no_file "$p/.holbuild/plan"
  if (cd "$p" && HOLBUILD_PLAN_RECORD=maybe "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/bad-mode.log" 2>&1; then
    echo "an unknown HOLBUILD_PLAN_RECORD value was accepted" >&2
    exit 1
  fi
  require_grep "HOLBUILD_PLAN_RECORD" "$tmpdir/bad-mode.log"
}

package_manifest() {
  local dir=$1 name=$2
  mkdir -p "$dir/src"
  cat > "$dir/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$hol_rev"

[project]
name = "$name"

[build]
members = ["src"]
TOML
}

# A root package whose UseScript.sml uses the library of package NAME, got
# from DEPENDENCY (manifest lines).
using_project() {
  local dir=$1 name=$2 structure=$3 dependency=$4
  package_manifest "$dir" root
  printf '\n[dependencies.%s]\n%s\n' "$name" "$dependency" >> "$dir/holproject.toml"
  cat > "$dir/src/UseScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Use";
val _ = $structure.value;
val _ = export_theory();
SML
}

library_package() {
  local dir=$1 name=$2 structure=$3
  package_manifest "$dir" "$name"
  echo "structure $structure = struct val value = 1 end" > "$dir/src/$structure.sml"
}

path_dependency() {
  local p=$tmpdir/path-dep
  library_package "$tmpdir/leaf" leaf Leaf
  cp -r "$tmpdir/leaf" "$tmpdir/leaf-copy"
  using_project "$p" leaf Leaf 'git = "https://example.invalid/leaf.git"
rev = "1111111111111111111111111111111111111111"'
  printf '[overrides.leaf]\npath = "$LEAF_DIR"\n' > "$p/.holconfig.toml"
  sleep 1.1
  export LEAF_DIR=$tmpdir/leaf
  expect_plan "full (no plan record for these inputs)" "$p"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
  printf '\n(* edited *)\n' >> "$tmpdir/leaf/src/Leaf.sml"
  expect_plan "from record (1 files rehashed, 2 keys changed)" "$p"
  # The manifest's $LEAF_DIR now names another package root.
  LEAF_DIR=$tmpdir/leaf-copy expect_plan "full (no plan record for these inputs)" "$p"
  unset LEAF_DIR
}

git_dependency() {
  local p=$tmpdir/git-dep
  library_package "$tmpdir/gitleaf" gitleaf GitLeaf
  local rev
  rev=$(init_git_repo "$tmpdir/gitleaf")
  using_project "$p" gitleaf GitLeaf "git = \"$tmpdir/gitleaf\"
rev = \"$rev\""
  sleep 1.1
  # The first build checks the dependency out, so the build after it hashes
  # its files again if the checkout came within a second of planning.
  expect_plan "full (no plan record for these inputs)" "$p"
  sleep 1.1
  expect_plan "from record (" "$p"
  require_grep "files rehashed, 0 keys changed" "$tmpdir/plan.log"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
  printf '\n(* edited by hand *)\n' >> "$p/.holbuild/src/gitleaf/src/GitLeaf.sml"
  expect_plan "from record (1 files rehashed, 2 keys changed)" "$p"
}

generator_project() {
  local p=$tmpdir/generator
  make_project "$p" '
[[generate]]
name = "copy"
command = ["cp", "data/G.sml", "gen/G.sml"]
inputs = ["data/G.sml"]
outputs = ["gen/G.sml"]'
  mkdir -p "$p/data" "$p/gen"
  echo 'structure G = struct end' > "$p/data/G.sml"
  sed -i 's/^members = \["src"\]/members = ["src", "gen"]/' "$p/holproject.toml"
  expect_plan "full (no plan record for these inputs)" "$p"
  require_grep "plan record not written: the project has generators" "$tmpdir/plan.log"
  expect_plan "full (no plan record for these inputs)" "$p"
}

# A toolchain whose stamp moved is hashed again rather than trusted. The
# toolchain is shared, so the record's stamp of bin/hol moves instead, and
# its toolchain key is spoilt: a build that kept it would change every key.
toolchain_stamp() {
  local p=$tmpdir/toolchain
  recorded_project "$p"
  local records=("$p"/.holbuild/plan/*)
  python3 - "${records[@]}" <<'PY'
import sys
path, = sys.argv[1:]
lines = open(path, encoding="latin-1").read().split("\n")
for i, line in enumerate(lines):
    if line.startswith("T"):
        hol, state, racy, key = line[1:].split("\x01")
        stamp = hol.split("\x03")
        stamp[3] = str(int(stamp[3]) + 1)
        lines[i] = "T" + "\x01".join(["\x03".join(stamp), state, racy, "0" * 64])
open(path, "w", encoding="latin-1").write("\n".join(lines))
PY
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
  if grep -q "$(printf '\001')0\{64\}$" "${records[0]}"; then
    echo "the rewritten record kept the spoilt toolchain key" >&2
    exit 1
  fi
}

# A directory's entries count by kind and readability, not only by name, and
# in any order.
entry_kinds() {
  local p=$tmpdir/entry-kinds
  make_project "$p"
  mkdir -p "$p/src/nested"
  theory "$p/src/nested/NScript.sml" N
  echo 'structure Unused = struct end' > "$p/src/Unused.sml"
  echo 'structure Hidden = struct end' > "$p/src/Hidden.sml"
  chmod 000 "$p/src/Hidden.sml"
  sleep 1.1
  expect_plan "full (no plan record for these inputs)" "$p"
  # A linked manifest makes a subdirectory a package of its own.
  ln -s ../../holproject.toml "$p/src/nested/holproject.toml"
  expect_plan "full (sources added, removed or renamed in $p/src/nested)" "$p"
  rm "$p/src/nested/holproject.toml"
  sleep 1.1
  expect_plan "full (sources added, removed or renamed in $p/src/nested)" "$p"
  # A source replaced by a directory of the same name, which discovery walks.
  rm "$p/src/Unused.sml"
  mkdir "$p/src/Unused.sml"
  echo 'structure Inner = struct end' > "$p/src/Unused.sml/Inner.sml"
  expect_plan "full (sources added, removed or renamed in $p/src)" "$p"
  sleep 1.1
  expect_plan "from record (" "$p"
  # A source discovery could not read becomes readable, or one the plan does
  # not select becomes unreadable; no directory changes.
  if [[ ! -r "$p/src/Hidden.sml" ]]; then
    chmod 644 "$p/src/Hidden.sml"
    expect_plan "full (an unreadable entry became readable in $p/src)" "$p"
    expect_plan "full (no plan record for these inputs)" "$p" ATheory
    chmod 000 "$p/src/DScript.sml"
    expect_plan "full (a source became unreadable in $p/src)" "$p" ATheory
    chmod 644 "$p/src/DScript.sml"
  fi
}

# Full planning lists a node's incoming edges in the order it found its
# dependents, which the record does not keep: here it reaches A, which Z
# declares, before B, which Z mentions, while the selected order is the
# reverse.
incoming_edge_order() {
  local p=$tmpdir/incoming
  make_project "$p" 'roots = ["src/ZScript.sml"]

[actions.ZTheory]
deps = ["ATheory"]'
  theory "$p/src/SScript.sml" S
  for name in A B; do
    cat > "$p/src/${name}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "$name";
val ${name,,}_thm = save_thm("${name,,}_thm", STheory.s_thm);
val _ = export_theory();
SML
  done
  cat > "$p/src/ZScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Z";
val z_thm = save_thm("z_thm", BTheory.b_thm);
val _ = export_theory();
SML
  sleep 1.1
  expect_plan "full (no plan record for these inputs)" "$p"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p"
}

# Records that builds from a record rewrite are read back like any other.
default_mode_rewrites() {
  local p=$tmpdir/rewrites
  make_project "$p"
  HOLBUILD_PLAN_RECORD=on expect_plan "full (no plan record for these inputs)" "$p"
  printf '\n(* one *)\n' >> "$p/src/BScript.sml"
  HOLBUILD_PLAN_RECORD=on expect_plan "from record (1 files rehashed, 3 keys changed)" "$p"
  sleep 1.1
  printf '\n(* two *)\n' >> "$p/src/CScript.sml"
  HOLBUILD_PLAN_RECORD=on expect_plan "from record (" "$p"
  sleep 1.1
  expect_plan "from record (" "$p"
}

# The record lives in the project's .holbuild wherever holbuild runs from,
# and reads the project's .holconfig.toml.
from_subdirectory() {
  local p=$tmpdir/subdir
  make_project "$p"
  expect_plan "full (no plan record for these inputs)" "$p/src"
  expect_plan "from record (0 files rehashed, 0 keys changed)" "$p/src"
  require_no_file "$p/src/.holbuild"
  printf '[build]\njobs = 2\n' > "$p/.holconfig.toml"
  expect_plan "full (no plan record for these inputs)" "$p/src"
}

# A package with the default members ["."] names its sources by plain paths
# under its root, so the record leaves them out of S lines, and a source
# that is also an extra input of its own directory is one file to the record.
default_members() {
  local p=$tmpdir/default-members
  mkdir -p "$p"
  cat > "$p/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$hol_rev"

[project]
name = "default-members"
TOML
  theory "$p/AScript.sml" A
  cat >> "$p/AScript.sml" <<'SML'
fun holbuild_extra_deps (_ : string list) = ()
val _ = holbuild_extra_deps ["."]
SML
  sleep 1.1
  expect_plan "full (no plan record for these inputs)" "$p"
  local records=("$p"/.holbuild/plan/*)
  python3 - "${records[@]}" <<'PY'
import sys
path, = sys.argv[1:]
for line in open(path, encoding="latin-1").read().split("\n"):
    if line.startswith("S") and line[1:].split("\x01")[4] != "":
        sys.exit("S line names a default path: " + repr(line))
PY
  printf '\n(* edited *)\n' >> "$p/AScript.sml"
  expect_plan "from record (1 files rehashed, 1 keys changed)" "$p"
}

# A build planned from the record rewrites it from the record it read; the
# result is byte for byte what full planning writes for the same tree.
restored_write_matches_full() {
  local p=$tmpdir/restored-write
  mkdir -p "$p/data"
  echo one > "$p/data/a.txt"
  make_project "$p" '
[actions.BTheory]
extra_inputs = ["data"]'
  expect_plan "full (no plan record for these inputs)" "$p"
  printf '\n(* edited *)\n' >> "$p/src/DScript.sml"
  echo two > "$p/data/b.txt"
  # Let both edits age past the racy window, so both writes see the same
  # stamps.
  sleep 1.1
  expect_plan "from record (" "$p"
  local record
  record=$(ls "$p"/.holbuild/plan/*)
  mv "$record" "$tmpdir/restored-record"
  expect_plan "full (no plan record for these inputs)" "$p"
  if ! cmp "$record" "$tmpdir/restored-record"; then
    echo "the record written from a restored plan differs from full planning's" >&2
    exit 1
  fi
}

# A path override inside a pinned checkout is still watched, also below a
# shim of that checkout rooted inside the override, and a shim at "." of the
# checkout names the checkout's root itself.
package_in_pinned_checkout() {
  local p=$tmpdir/in-pinned
  library_package "$tmpdir/outer" outer Outer
  mkdir -p "$tmpdir/outer/lib"
  echo "structure OuterLib = struct val value = 1 end" > "$tmpdir/outer/lib/OuterLib.sml"
  local rev
  rev=$(init_git_repo "$tmpdir/outer")
  using_project "$p" outer Outer "git = \"$tmpdir/outer\"
rev = \"$rev\""
  expect_plan "full (no plan record for these inputs)" "$p"
  local inner=$p/.holbuild/src/outer/inner
  library_package "$inner" inner Inner
  mkdir -p "$p/shims" "$inner/src/lib"
  cat > "$p/shims/innerlib.toml" <<'TOML'
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "innerlib"

[build]
members = ["lib"]
TOML
  cat > "$p/shims/outerlib.toml" <<'TOML'
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "outerlib"

[build]
members = ["lib"]
TOML
  cat >> "$p/holproject.toml" <<'TOML'

[dependencies.inner]
git = "https://example.invalid/inner.git"
rev = "1111111111111111111111111111111111111111"

[dependencies.outerlib]
from = "outer"
path = "."
manifest = "shims/outerlib.toml"

[dependencies.innerlib]
from = "outer"
path = "inner/src"
manifest = "shims/innerlib.toml"
TOML
  printf '[overrides.inner]\npath = "%s"\n' "$inner" > "$p/.holconfig.toml"
  sleep 1.1
  expect_plan "full (no plan record for these inputs)" "$p"
  expect_plan "from record (" "$p"
  if grep -q '/\./' "$p"/.holbuild/plan/*; then
    echo "the record names a path through /./" >&2
    exit 1
  fi
  echo "structure Inner2 = struct end" > "$inner/src/Inner2.sml"
  expect_plan "full (sources added, removed or renamed in $inner/src)" "$p"
}

noop
racy_entries_are_rehashed
edit_with_restored_mtime
rename_over_edit
mention_added
mention_removed
mention_selects_source
mention_drops_sources
source_added
source_removed
source_renamed
backup_file_in_source_dir
extra_output_in_source_dir
hidden_sml_outputs
extra_inputs
manifest_edit
holconfig_edit
holbuild_env_var
targets_on_argv
deep_downstream_edit
corrupt_records
record_off
path_dependency
git_dependency
generator_project
toolchain_stamp
entry_kinds
incoming_edge_order
default_mode_rewrites
from_subdirectory
default_members
restored_write_matches_full
package_in_pinned_checkout
