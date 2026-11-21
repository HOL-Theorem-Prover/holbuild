#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# When check's preload loads a theory module from a file and reaches the
# threshold, its transient save is saveChildWithModules without a share
# pass, as a deps heap's would be; the theory still checks clean and
# nothing saved is left behind.

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
module_cache=$HOLBUILD_CACHE/theory-modules
project=$tmpdir/project
mkdir -p "$project/src"
write_schema2_prelude > "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'
[project]
name = "promote-modules"
[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Definition a_value_def:
  a_value = T
End
SML
write_b() {
  cat > "$project/src/BScript.sml" <<SML
Theory B
Ancestors A

Theorem b_thm:
  a_value
Proof
  $1
QED
SML
}
b_log=$project/.holbuild/logs/current/promote-modules/BTheory/build.log
check_b() {
  (cd "$project" && HOLBUILD_PIPELINE=off HOLBUILD_PROMOTE_PRELOAD_BYTES=0 "$HOLBUILD_BIN" -j1 check BTheory) > "$1" 2>&1 ||
    { cat "$1" >&2; return 1; }
  require_grep '^BTheory: clean (1 theorem)$' "$1"
  if find "$project/.holbuild" -name '*.save' -print -quit | grep -q .; then
    echo "check left a promoted preload's heap behind" >&2
    exit 1
  fi
}

# B's first preload loads A from its .dat and writes A's module.
write_b 'simp[a_value_def]'
check_b "$tmpdir/first.log"
if grep -q 'module-cache unsupported' "$b_log" ||
   [[ -z "$(find "$module_cache" -name '*-A-*.pmo' 2>/dev/null)" ]]; then
  if [[ ${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-0} == 1 ]]; then
    echo 'promoting a preload with modules needs theory module support' >&2
    exit 1
  fi
  echo 'promoting a preload with modules unsupported: no theory module support'
  exit 0
fi
# The next preload loads A's module, so the promotion saves with modules.
write_b 'rw[a_value_def]'
check_b "$tmpdir/second.log"
require_grep '^holbuild preload in_use=[0-9]* threshold=0 promoted share=false ' "$b_log"
