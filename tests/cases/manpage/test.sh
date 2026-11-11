#!/usr/bin/env bash
# man/holbuild.1 documents every command, every option the command-line parser
# accepts and every HOLBUILD_* variable the help texts name.
set -euo pipefail

HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${HOLBUILD_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

manpage=$ROOT/man/holbuild.1
require_file "$manpage"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT

# The page's text with roff escapes removed, so `\-\-flag` reads as `--flag`.
sed -e 's/\\&//g' -e 's/\\-/-/g' -e 's/\\fB//g' -e 's/\\fI//g' -e 's/\\fR//g' "$manpage" > "$tmpdir/page.txt"

# Everything the help texts and the parser source name.
commands=$(sed -n '/^val command_names =/,/\]/p' "$ROOT/sml/commands.sml" | grep -o '"[a-z-]*"' | tr -d '"')
[[ -n "$commands" ]] || { echo "no commands found in sml/commands.sml" >&2; exit 1; }

{
  "$HOLBUILD_BIN" --help
  for command in $commands; do "$HOLBUILD_BIN" "$command" --help; done
} > "$tmpdir/help.txt" 2>&1

{
  grep -Eo -- '(^|[^-A-Za-z0-9])--[a-z][a-z-]*' "$tmpdir/help.txt" | sed -E 's/^[^-]*//'
  grep -o '"--[a-z][a-z-]*"' "$ROOT/sml/commands.sml" | tr -d '"'
  printf '%s\n' -j -o -h
} | sort -u > "$tmpdir/flags.txt"
grep -Eo 'HOLBUILD_[A-Z_]+' "$tmpdir/help.txt" | sort -u > "$tmpdir/env.txt"

# A flag counts as documented only as a whole word: `--force` is not
# documented by `--force-theory`.
word_in_page() {
  grep -Eq -- "(^|[^-A-Za-z0-9_])$1([^-A-Za-z0-9_]|\$)" "$tmpdir/page.txt"
}

missing=0
for name in $commands; do
  word_in_page "$name" || { echo "man/holbuild.1 lacks command: $name" >&2; missing=1; }
done
while IFS= read -r flag; do
  word_in_page "$flag" || { echo "man/holbuild.1 lacks option: $flag" >&2; missing=1; }
done < "$tmpdir/flags.txt"
while IFS= read -r var; do
  word_in_page "$var" || { echo "man/holbuild.1 lacks variable: $var" >&2; missing=1; }
done < "$tmpdir/env.txt"
if [[ $missing -ne 0 ]]; then
  echo "add the missing names to man/holbuild.1" >&2
  exit 1
fi

# Every command's help points at the page.
for command in $commands; do
  "$HOLBUILD_BIN" "$command" --help | grep -q 'man holbuild' ||
    { echo "holbuild $command --help does not mention man holbuild" >&2; exit 1; }
done

# The page is well-formed roff.
if command -v groff >/dev/null 2>&1; then
  warnings=$(groff -man -ww -z "$manpage" 2>&1 || true)
  if [[ -n "$warnings" ]]; then
    printf '%s\n' "$warnings" >&2
    exit 1
  fi
fi
