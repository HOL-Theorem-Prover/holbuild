#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
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
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "autogcwiring"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Theorem a_thm: T
Proof ACCEPT_TAC TRUTH
QED
SML

# With a threshold of one, a build counted since the last GC makes every
# command that runs automatic GC collect; the residue is an abandoned staging
# directory older than the retention, which a collection removes.
write_config() {
  printf '[gc]\nproject_builds = 1\n%s\n' "${1:-}" > "$project/.holconfig.toml"
}
plant_residue() {
  mkdir -p "$project/.holbuild/stage/abandoned"
  : > "$project/.holbuild/stage/abandoned/leftover"
  touch -d '10 days ago' "$project/.holbuild/stage/abandoned"
  printf '1\n' > "$project/.holbuild/gc.state"
}
run_holbuild() {
  local log=$1
  shift
  (cd "$project" && "$HOLBUILD_BIN" "$@") > "$log" 2>&1 || { cat "$log" >&2; exit 1; }
}
require_collected() {
  local log=$1
  require_no_file "$project/.holbuild/stage/abandoned"
  require_grep "holbuild: automatic project gc: removed stage=1 " "$log"
  [[ $(grep -c "automatic project gc" "$log") -eq 1 ]] ||
    { echo "automatic gc ran more than once:" >&2; cat "$log" >&2; exit 1; }
}
require_untouched() {
  local log=$1
  require_file "$project/.holbuild/stage/abandoned/leftover"
  ! grep -q "automatic" "$log" || { echo "unexpected automatic gc:" >&2; cat "$log" >&2; exit 1; }
}

write_config
plant_residue
run_holbuild "$tmpdir/dry-run.log" build --dry-run ATheory
require_untouched "$tmpdir/dry-run.log"

run_holbuild "$tmpdir/build.log" build ATheory
require_collected "$tmpdir/build.log"
[[ $(cat "$project/.holbuild/gc.state") == 0 ]] || { echo "gc.state not reset" >&2; exit 1; }

plant_residue
run_holbuild "$tmpdir/check.log" check ATheory
require_untouched "$tmpdir/check.log"
printf 'val _ = print "ran\\n";\n' > "$project/run.sml"
run_holbuild "$tmpdir/run.log" run --from ATheory run.sml
require_untouched "$tmpdir/run.log"

# Work below the threshold is counted, not collected.
printf '[gc]\nproject_builds = 5\n' > "$project/.holconfig.toml"
echo "(* edit *)" >> "$project/src/AScript.sml"
run_holbuild "$tmpdir/counted.log" build ATheory
require_untouched "$tmpdir/counted.log"
# gc.state held the planted count of one, plus this build.
[[ $(cat "$project/.holbuild/gc.state") == 2 ]] || { echo "gc.state did not count the build" >&2; exit 1; }

write_config 'auto = false'
echo "(* edit *)" >> "$project/src/AScript.sml"
run_holbuild "$tmpdir/disabled.log" build ATheory
require_untouched "$tmpdir/disabled.log"

write_config
echo "(* edit *)" >> "$project/src/AScript.sml"
(cd "$project" && HOLBUILD_AUTO_GC=0 "$HOLBUILD_BIN" build ATheory) > "$tmpdir/env-disabled.log" 2>&1
require_untouched "$tmpdir/env-disabled.log"

run_holbuild "$tmpdir/export.log" export --build -o "$tmpdir/a.hbx" ATheory
require_collected "$tmpdir/export.log"

plant_residue
run_holbuild "$tmpdir/import.log" import "$tmpdir/a.hbx"
require_collected "$tmpdir/import.log"

# Staging directories within the retention survive a collection and are not
# counted, so with no new work the next command does not collect again.
mkdir -p "$project/.holbuild/stage/young"
run_holbuild "$tmpdir/reimport.log" import "$tmpdir/a.hbx"
[[ -d $project/.holbuild/stage/young ]] || { echo "young staging directory removed" >&2; exit 1; }
! grep -q "automatic" "$tmpdir/reimport.log" || { echo "automatic gc ran again without new work:" >&2; cat "$tmpdir/reimport.log" >&2; exit 1; }

# --quiet collects without the report.
plant_residue
echo "(* edit *)" >> "$project/src/AScript.sml"
run_holbuild "$tmpdir/quiet.log" --quiet build ATheory
require_no_file "$project/.holbuild/stage/abandoned"
! grep -q "automatic" "$tmpdir/quiet.log" || { echo "--quiet printed the gc report" >&2; exit 1; }

# A project whose configuration does not load skips automatic GC with a
# warning; the import itself still succeeds.
printf '[gc]\ncache_gb = 0\n' > "$project/.holconfig.toml"
run_holbuild "$tmpdir/bad-config.log" import "$tmpdir/a.hbx"
require_grep "holbuild: warning: automatic gc skipped: " "$tmpdir/bad-config.log"
