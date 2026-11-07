#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/scripts" "$project/data"
printf 'alpha\n' > "$project/data/Alpha.txt"
printf 'beta\n' > "$project/data/Beta.txt"
printf 'support\n' > "$project/data/support.txt"
cat > "$project/scripts/generate.py" <<'PY'
from pathlib import Path
import sys

assert sys.argv[1:] == ['{literal}', 'Alpha:Alpha', 'Beta:Beta', 'Alpha', 'Beta']
with Path('calls').open('a') as calls:
    calls.write('batch\n')
for name in ['Alpha', 'Beta']:
    Path(f'gen/{name}.sml').write_text(f'val {name.lower()} = true;\n')
PY

cat > "$tmpdir/header" <<TOML
[project]
name = "generator-templates"
[build]
members = ["gen"]
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"
TOML
cat > "$tmpdir/explicit" <<'TOML'
[[generate]]
name = "packets"
command = ["python3", "scripts/generate.py", "{literal}", "Alpha:Alpha", "Beta:Beta", "Alpha", "Beta"]
inputs = ["scripts/generate.py", "data/Alpha.txt", "data/Beta.txt", "data/support.txt"]
outputs = ["gen/Alpha.sml", "gen/Beta.sml"]

[[generate]]
name = "single"
command = ["sh", "-c", "printf 'val gamma = true;' > gen/Gamma.sml"]
inputs = []
outputs = ["gen/Gamma.sml"]
deps = ["packets"]

[[generate]]
name = "unused"
command = ["tool-that-must-not-be-installed"]
outputs = ["gen/Unused.sml"]

[[generate]]
name = "literal"
command = ["tool-that-must-not-be-installed", "{file}"]
outputs = ["gen/Literal.sml"]
TOML
cat > "$tmpdir/compact" <<'TOML'
[[generate]]
name = "packets"
template = "packet"
files = ["Alpha", "Beta"]

[[generate]]
name = "single"
template = "packet"
files = ["Gamma"]
command = ["sh", "-c", "printf 'val gamma = true;' > gen/Gamma.sml"]
inputs = []
deps = ["packets"]

[[generate]]
name = "unused"
files = ["Unused"]
command = ["tool-that-must-not-be-installed"]
outputs = ["gen/{file}.sml"]

[[generate]]
name = "literal"
command = ["tool-that-must-not-be-installed", "{file}"]
outputs = ["gen/Literal.sml"]

[generate_templates.packet]
command = ["python3", "scripts/generate.py", "{literal}", "{file}:{file}", "{file}"]
inputs = ["scripts/generate.py", "data/{file}.txt", "data/support.txt"]
outputs = ["gen/{file}.sml"]
TOML

write_manifest() { cat "$tmpdir/header" "$1" > "$project/holproject.toml"; }
ids() {
  (cd "$project" && "$HOLBUILD_BIN" context) |
    grep -E '^(package-definition|generator-definition)-id:'
}
plan() { (cd "$project" && "$HOLBUILD_BIN" build --dry-run "$1"); }

write_manifest "$tmpdir/explicit"
ids > "$tmpdir/explicit.ids"
write_manifest "$tmpdir/compact"
ids > "$tmpdir/compact.ids"
cmp "$tmpdir/explicit.ids" "$tmpdir/compact.ids"
[[ ! -e "$project/gen" && ! -e "$project/calls" ]]

plan Gamma > "$tmpdir/first.log"
require_file "$project/gen/Alpha.sml"
require_file "$project/gen/Beta.sml"
require_file "$project/gen/Gamma.sml"
[[ $(wc -l < "$project/calls") = 1 ]]
[[ ! -e "$project/gen/Unused.sml" && ! -e "$project/gen/Literal.sml" ]]
plan Alpha > "$tmpdir/unchanged.log"
[[ $(wc -l < "$project/calls") = 1 ]]
printf 'changed support\n' > "$project/data/support.txt"
plan Alpha > "$tmpdir/support.log"
[[ $(wc -l < "$project/calls") = 2 ]]
rm "$project/gen/Beta.sml"
plan Alpha > "$tmpdir/missing.log"
require_file "$project/gen/Beta.sml"
[[ $(wc -l < "$project/calls") = 3 ]]

expect_error() {
  local expected=$1 command=${2:-context}
  local args=(context)
  if [[ $command == build ]]; then args=(build --dry-run Alpha); fi
  if (cd "$project" && "$HOLBUILD_BIN" "${args[@]}") > "$tmpdir/error.log" 2>&1; then
    echo "expected failure: $expected" >&2
    exit 1
  fi
  require_grep "$expected" "$tmpdir/error.log"
}
cat > "$tmpdir/invalid" <<'TOML'
[[generate]]
name = "unknown"
template = "missing"
TOML
write_manifest "$tmpdir/invalid"
expect_error "unknown generate template: missing"

for files in '[]' '[""]' '"Alpha"'; do
  cat > "$tmpdir/invalid" <<TOML
[[generate]]
name = "bad-files"
command = ["unused"]
outputs = ["gen/Alpha.sml"]
files = $files
TOML
  write_manifest "$tmpdir/invalid"
  expect_error "files.*must"
done

cat > "$tmpdir/invalid" <<'TOML'
[generate_templates.bad]
command = "not-an-array"
TOML
write_manifest "$tmpdir/invalid"
expect_error "command must be a string array"
cat > "$tmpdir/invalid" <<'TOML'
[generate_templates.bad]
template = "packet"
TOML
write_manifest "$tmpdir/invalid"
expect_error "unknown field in generate_templates.bad: template"

cat > "$tmpdir/invalid" <<'TOML'
[[generate]]
name = "escape"
files = ["../escape"]
command = ["unused"]
outputs = ["{file}.sml"]
TOML
write_manifest "$tmpdir/invalid"
expect_error "must be package-root-relative"

cat > "$tmpdir/invalid" <<'TOML'
[[generate]]
name = "duplicate"
files = ["Alpha", "Alpha"]
command = ["unused"]
outputs = ["gen/{file}.sml"]
TOML
write_manifest "$tmpdir/invalid"
expect_error "is produced by both duplicate and duplicate" build

cat > "$tmpdir/invalid" <<'TOML'
[[generate]]
name = "missing"
files = ["Absent"]
command = ["true"]
outputs = ["gen/{file}.sml"]
TOML
write_manifest "$tmpdir/invalid"
if (cd "$project" && "$HOLBUILD_BIN" build --dry-run Absent) > "$tmpdir/error.log" 2>&1; then
  echo "missing expanded output was accepted" >&2
  exit 1
fi
require_grep "did not produce declared output: gen/Absent.sml" "$tmpdir/error.log"
