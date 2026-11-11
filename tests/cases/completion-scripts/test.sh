#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT
unset HOLBUILD_SOURCE_DIR
export HOLBUILD_CACHE=$tmpdir/cache
completions=$HOLBUILD_ROOT/completions

# shellcheck source=../../../completions/holbuild.bash
source "$completions/holbuild.bash"
complete -p holbuild | grep -q -- '-o default' ||
  { echo "bash completion must fall back to file names" >&2; exit 1; }

# bash_complete DIR LINE WORD...: COMPREPLY for LINE, typed in DIR, where
# WORD... is how bash splits it (COMP_WORDS); joined by spaces as one line.
bash_complete() {
  local dir=$1 line=$2
  shift 2
  COMP_LINE=$line COMP_POINT=${#line} COMP_WORDS=("$@") COMP_CWORD=$(($# - 1))
  COMPREPLY=()
  (cd "$dir" && _holbuild "$HOLBUILD_BIN" && printf '%s\n' "${COMPREPLY[@]}")
}

# expect_lines ACTUAL LINE...: ACTUAL is exactly these lines.
expect_lines() {
  local actual=$1
  shift
  if [[ $actual != "$(printf '%s\n' "$@" | sed '/^$/d')" ]]; then
    printf 'expected:\n%s\ngot:\n%s\n' "$*" "$actual" >&2
    exit 1
  fi
}

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "main"

[build]
members = ["src"]
TOML
for name in Alpha Alpine Beta; do echo "Theory $name" > "$project/src/${name}Script.sml"; done

expect_lines "$(bash_complete "$project" "holbuild b" holbuild b)" build buildhol
expect_lines "$(bash_complete "$project" "holbuild B" holbuild B)" BetaTheory
expect_lines "$(bash_complete "$project" "holbuild clean " holbuild clean "")" \
  AlphaTheory AlpineTheory BetaTheory
expect_lines "$(bash_complete "$project" "holbuild --verbosity q" holbuild --verbosity q)" quiet
# Bash splits `--from=Al` at the `=`; the candidates replace only `Al`.
expect_lines "$(bash_complete "$project" "holbuild repl --from=Al" holbuild repl --from = Al)" \
  AlphaTheory AlpineTheory
expect_lines "$(bash_complete "$project" "holbuild repl --from=" holbuild repl --from =)" \
  =AlphaTheory =AlpineTheory =BetaTheory
# Quoted and escaped words reach holbuild as the shell would pass them.
spaced=$tmpdir/my\ project
cp -R "$project" "$tmpdir/my project"
expect_lines "$(bash_complete "$tmpdir" "holbuild --source-dir \"$tmpdir/my project\" clean A" \
                 holbuild --source-dir "\"$tmpdir/my project\"" clean A)" AlphaTheory AlpineTheory
expect_lines "$(bash_complete "$tmpdir" "holbuild --source-dir $spaced clean A" \
                 holbuild --source-dir "$spaced" clean A)" AlphaTheory AlpineTheory
expect_lines "$(bash_complete "$tmpdir" "holbuild --source-dir='$tmpdir/my project' clean 'Al" \
                 holbuild --source-dir = "'$tmpdir/my project'" clean "'Al")" AlphaTheory AlpineTheory
# Nothing to offer: bash completes file names instead.
expect_lines "$(bash_complete "$project" "holbuild build --tactic-timeout " holbuild build --tactic-timeout "")"
require_no_file "$HOLBUILD_CACHE"
require_no_file "$project/.holbuild"

# zsh_complete DIR WORD...: what the Zsh function offers for WORD..., the
# last being the one under the cursor, typed in DIR; compadd and _files are
# stubbed to print what they were given.
zsh_complete() {
  local dir=$1
  shift
  (cd "$dir" && zsh -f -c '
    fpath=("$1" $fpath)
    autoload -Uz _holbuild
    compadd() { shift; print -l -- "$@"; }
    compset() { IPREFIX=${PREFIX%%=*}=; PREFIX=${PREFIX#*=}; }
    _files() { print "<files${IPREFIX:+ after $IPREFIX} for $PREFIX>"; }
    shift
    words=("$@")
    CURRENT=$#
    PREFIX=${words[CURRENT]}
    _holbuild' zsh "$completions" "$HOLBUILD_BIN" "$@")
}

if command -v zsh > /dev/null; then
  zsh -n "$completions/_holbuild"
  expect_lines "$(zsh_complete "$project" clean A)" AlphaTheory AlpineTheory
  expect_lines "$(zsh_complete "$project" repl --from=Al)" --from=AlphaTheory --from=AlpineTheory
  expect_lines "$(zsh_complete "$tmpdir" --source-dir "\"$tmpdir/my project\"" clean A)" \
    AlphaTheory AlpineTheory
  expect_lines "$(zsh_complete "$tmpdir" --source-dir="$spaced" clean A)" AlphaTheory AlpineTheory
  expect_lines "$(zsh_complete "$project" build --tactic-timeout "")" "<files for >"
  expect_lines "$(zsh_complete "$project" --source-dir=sr)" "<files after --source-dir= for sr>"
else
  echo "zsh not installed; skipping its checks" >&2
fi
# fish_complete DIR LINE: what Fish offers for LINE, typed in DIR.
fish_complete() {
  (cd "$1" && PATH=$tmpdir/fish-bin:$PATH fish --no-config -c \
     'source $argv[1]; complete -C $argv[2]' "$completions/holbuild.fish" "$2")
}

if command -v fish > /dev/null; then
  fish -n "$completions/holbuild.fish"
  mkdir "$tmpdir/fish-bin" "$project/srcdir"
  ln -s "$HOLBUILD_BIN" "$tmpdir/fish-bin/holbuild"
  expect_lines "$(fish_complete "$project" "holbuild clean A")" AlphaTheory AlpineTheory
  expect_lines "$(fish_complete "$tmpdir" "holbuild --source-dir \"$tmpdir/my project\" clean A")" \
    AlphaTheory AlpineTheory
  expect_lines "$(fish_complete "$project" "holbuild repl --from=Alp")" \
    --from=AlphaTheory --from=AlpineTheory
  expect_lines "$(fish_complete "$project" "holbuild --source-dir=srcd")" --source-dir=srcdir/
  expect_lines "$(fish_complete "$project" "holbuild clean 'Al")" AlphaTheory AlpineTheory
  expect_lines "$(fish_complete "$project" "holbuild repl --from='Alp")" \
    --from=AlphaTheory --from=AlpineTheory
else
  echo "fish not installed; skipping its checks" >&2
fi
