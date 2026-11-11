#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../lib.sh"
HOLBUILD_BIN=$1

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "unchecked"
TOML
cat > "$project/AScript.sml" <<'SML'
Theory A
Ancestors bool
Theorem checked: T
Proof
  simp[]
QED
SML
build() {
  (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$1" 2>&1 ||
    { cat "$1" >&2; exit 1; }
}
build "$tmpdir/first.log"
metadata=$project/.holbuild/dep/unchecked/AScript.sml.key
key=$(sed -n 's/^input_key=//p' "$metadata")
# Model an upgrade from the removed mode: installed outputs are marked
# unchecked, and the only cache entry is under its isolated historical key.
old_key=$(printf 'holbuild-cached-proofs-action-v1\n%s\n' "$key" | sha256sum | cut -d' ' -f1)
mv "$HOLBUILD_CACHE/actions/$key" "$HOLBUILD_CACHE/actions/$old_key"
sed -i "s/input_key=$key/input_key=$old_key/" "$HOLBUILD_CACHE/actions/$old_key/manifest"
printf 'proofs=cached\n' >> "$metadata"
build "$tmpdir/upgrade.log"
require_grep 'ATheory built' "$tmpdir/upgrade.log"
if grep -q '^proofs=cached$' "$metadata"; then
  echo 'upgrade accepted unchecked installed outputs' >&2
  exit 1
fi
require_file "$HOLBUILD_CACHE/actions/$key/manifest"
require_file "$HOLBUILD_CACHE/actions/$old_key/manifest"
