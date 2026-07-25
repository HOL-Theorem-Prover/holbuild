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

analyser_root=$tmpdir/analyser-root
mkdir -p "$analyser_root/sml" "$analyser_root/vendor"
cp "$HOLBUILD_ROOT"/sml/*.sml "$analyser_root/sml/"
cp -R "$HOLBUILD_ROOT/sml/analyser" "$analyser_root/sml/analyser"
cp -R "$HOLBUILD_ROOT/vendor/sml-sha256" "$analyser_root/vendor/sml-sha256"
printf '\n(* exit-zero incomplete analyser response regression fixture *)\n' >> "$analyser_root/sml/analyser/analysis_protocol.sml"

fake_polyc=$tmpdir/fake-polyc
cat > "$fake_polyc" <<'SH'
#!/usr/bin/env sh
set -eu
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$out" ]
cat > "$out" <<'ANALYSER'
#!/usr/bin/env sh
set -eu
request=
response=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request)
      request=$2
      shift 2
      ;;
    --response)
      response=$2
      shift 2
      ;;
    --version)
      printf 'holbuild-hol-analyser holbuild-hol-analyser-v1\n'
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$request" ]
[ -n "$response" ]
if grep -Eq 'boundaries|terminations' "$request"; then
  printf 'version 1\nok\nend\n' > "$response"
  exit 0
fi
{
  printf 'version 1\nok\n'
  while IFS=' ' read -r record id _; do
    if [ "$record" = file ]; then
      printf 'begin-file %s\nend-file %s\n' "$id" "$id"
    fi
  done < "$request"
  printf 'end\n'
} > "$response"
ANALYSER
chmod +x "$out"
SH
chmod +x "$fake_polyc"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "timeout-analyser-failure"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem analyser_failure_thm:
  T
Proof
  simp[]
QED
SML

failure_log=$tmpdir/failure.log
if (cd "$project" &&
    HOLBUILD_ANALYSER_SRC="$analyser_root/sml/analyser" \
    HOLBUILD_POLYC="$fake_polyc" \
    "$HOLBUILD_BIN" build --tactic-timeout 1 ATheory) > "$failure_log" 2>&1; then
  echo "finite-timeout build succeeded without theorem-boundary instrumentation" >&2
  cat "$failure_log" >&2
  exit 1
fi
require_grep "cannot enforce requested tactic timeout" "$failure_log"
if grep -R -q -E '^proof[-_]timeout=1\.0$' \
    "$project/.holbuild" "$HOLBUILD_CACHE/actions" 2>/dev/null; then
  echo "failed uninstrumented build persisted a finite timeout contract" >&2
  exit 1
fi
