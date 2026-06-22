#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../lib.sh"

HOLBUILD_BIN=$1

tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT

project=$tmpdir/project
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "watch-options"
TOML

check_reject() {
  local label=$1
  local expected=$2
  shift 2
  local log="$tmpdir/$label.log"
  if (cd "$project" && "$HOLBUILD_BIN" "$@") >"$log" 2>&1; then
    echo "expected $label to fail" >&2
    exit 1
  fi
  if ! grep -q -- "$expected" "$log"; then
    echo "missing expected rejection for $label: $expected" >&2
    cat "$log" >&2
    exit 1
  fi
}

check_reject watch-dry-run "--watch does not support --dry-run" build --watch --dry-run
check_reject watch-repl "--watch does not support --repl-on-failure" build --watch --repl-on-failure
check_reject watch-json "--json does not support build --watch yet" --json build --watch
