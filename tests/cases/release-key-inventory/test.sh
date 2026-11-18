#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"
inventory="$HOLBUILD_ROOT/tools/release-key-inventory.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT

cat > "$tmpdir/old" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'action-spec --remote-only SomeTheory' ]] || exit 99
echo holbuild-action-batch-v1
case ${0##*/} in
  old) printf '%s' "$OLD_BATCH"; exit "$OLD_STATUS" ;;
  new) printf '%s' "$NEW_BATCH"; exit "$NEW_STATUS" ;;
esac
SH
cp "$tmpdir/old" "$tmpdir/new"
chmod +x "$tmpdir/old" "$tmpdir/new"
export OLD_STATUS=0 NEW_STATUS=0 OLD_BATCH= NEW_BATCH=

expect() {
  local want=$1 status=0
  "$inventory" "$tmpdir/old" "$tmpdir/new" --remote-only SomeTheory \
    > "$tmpdir/output" 2>&1 || status=$?
  if [[ $status -ne $want ]]; then
    cat "$tmpdir/output" >&2
    echo "inventory exited $status, wanted $want" >&2
    exit 1
  fi
}

# Both planner failures are errors, never reports of lost theories.
for code in 1 2 3 75; do
  want=$code
  [[ $code -ne 1 ]] || want=2
  OLD_STATUS=$code NEW_STATUS=0 expect "$want"
  OLD_STATUS=0 NEW_STATUS=$code expect "$want"
done

OLD_BATCH=$'action key-a ac-a spec-a consumer:ATheory\n'
NEW_BATCH=$OLD_BATCH
expect 0
require_grep '^no theory restorable' "$tmpdir/output"

# B was restorable before, but the new planner now exports it as uncached.
NEW_BATCH+=$'action key-b ac-b spec-b consumer:BTheory\n'
expect 1
require_grep '^1 theories restore' "$tmpdir/output"
require_grep '^consumer:BTheory$' "$tmpdir/output"
