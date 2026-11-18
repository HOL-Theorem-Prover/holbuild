#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT

export HOLBUILD_PROCESS_TEST_DIR="$tmpdir"
poly=$(command -v "${HOLBUILD_POLY:-poly}")
export HOLBUILD_PROCESS_TEST_PS
HOLBUILD_PROCESS_TEST_PS=$(command -v ps)
test_path=$PATH
if [[ -r /proc/self/stat ]]; then
  mkdir "$tmpdir/bin"
  session_tool=setsid
  command -v setsid >/dev/null || session_tool=perl
  for tool in sh sleep "$session_tool"; do
    ln -s "$(command -v "$tool")" "$tmpdir/bin/$tool"
  done
  export HOLBUILD_PROCESS_TEST_PS_CALLS="$tmpdir/ps-calls"
  cat > "$tmpdir/bin/ps" <<'SH'
#!/bin/sh
printf 'called\n' >> "$HOLBUILD_PROCESS_TEST_PS_CALLS"
exit 127
SH
  chmod +x "$tmpdir/bin/ps"
  test_path=$tmpdir/bin
fi
PATH="$test_path" "$poly" -q --error-exit --script "$SCRIPT_DIR/check.sml" \
  > "$tmpdir/check.log" 2>&1 || {
  cat "$tmpdir/check.log" >&2
  if [[ -f "$tmpdir/ps-calls" ]]; then
    echo "Linux watcher ps executions: $(wc -l < "$tmpdir/ps-calls")" >&2
  fi
  exit 1
}
require_grep "process-group cancellation tests passed" "$tmpdir/check.log"
if [[ -r /proc/self/stat ]]; then
  [[ ! -e "$tmpdir/ps-calls" ]] || { echo "Linux watcher invoked ps" >&2; exit 1; }
  echo "Linux watcher ps executions: 0"
fi
