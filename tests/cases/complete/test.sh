#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
holder=
cleanup() {
  [[ -n $holder ]] && kill "$holder" 2>/dev/null || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT
unset HOLBUILD_OFFLINE HOLBUILD_SOURCE_DIR HOLBUILD_REMOTE_CACHE_URL HOLBUILD_REMOTE_CACHE_CURL_CONFIG

# The query must not create a cache, so this one stays absent throughout.
export HOLBUILD_CACHE=$tmpdir/cache

# Any git, curl or poly the query started would be logged here.
attempts=$tmpdir/attempts
: > "$attempts"
mkdir "$tmpdir/intercept"
for tool in git curl poly polyc; do
  cat > "$tmpdir/intercept/$tool" <<SH
#!/bin/sh
printf '$tool %s\n' "\$*" >> "$attempts"
exit 90
SH
done
chmod +x "$tmpdir/intercept/"*
export PATH=$tmpdir/intercept:$PATH

# complete DIR NAME WORD...: the candidates for the words, run in DIR, in
# $tmpdir/NAME.out; the query must exit 0 and print nothing on stderr.
complete() {
  local dir=$1 name=$2
  shift 2
  if ! (cd "$dir" && timeout 20 "$HOLBUILD_BIN" __complete "$@") \
       > "$tmpdir/$name.out" 2> "$tmpdir/$name.err"; then
    echo "__complete $* failed" >&2
    cat "$tmpdir/$name.err" >&2
    exit 1
  fi
  if [[ -s "$tmpdir/$name.err" ]]; then
    echo "__complete $* wrote to stderr:" >&2
    cat "$tmpdir/$name.err" >&2
    exit 1
  fi
}

# expect NAME LINE...: $tmpdir/NAME.out is exactly these lines.
expect() {
  local name=$1
  shift
  if ! diff <(printf '%s\n' "$@" | sed '/^$/d') "$tmpdir/$name.out"; then
    echo "unexpected candidates for $name" >&2
    exit 1
  fi
}

# Outside a project: commands and options only.
outside=$tmpdir/outside
mkdir "$outside"
complete "$outside" none ""
expect none action-spec build buildhol cache check clean context exec-action executable \
  execution-plan export gc heap import repl run run-action
complete "$outside" prefix b
expect prefix build buildhol
complete "$outside" global --v
expect global --verbose --verbosity --version
complete "$outside" option build --proof
expect option --proof-scope
complete "$outside" value build --proof-scope ""
expect value all root
complete "$outside" global-value --verbosity ""
expect global-value normal quiet verbose
complete "$outside" global-anywhere build --jobs 4 --verbosity q
expect global-anywhere quiet
complete "$outside" file-value build --tactic-timeout ""
expect file-value
complete "$outside" half-typed --source-dir
require_grep "^--source-dir$" "$tmpdir/half-typed.out"
complete "$outside" no-project build ""
expect no-project

# Every option offered for a command is in its --help (action-spec takes
# build's options), and every global one in holbuild --help.
"$HOLBUILD_BIN" --help > "$tmpdir/global.help"
complete "$outside" globals -
while read -r option; do
  [[ $option == --help ]] && continue
  grep -q -- "$option" "$tmpdir/global.help" || { echo "global $option not in holbuild --help" >&2; exit 1; }
done < "$tmpdir/globals.out"
"$HOLBUILD_BIN" build --help > "$tmpdir/build.help"
while read -r command; do
  "$HOLBUILD_BIN" "$command" --help > "$tmpdir/$command.help"
  complete "$outside" "options-$command" "$command" -
  own=$(grep -vxF -f "$tmpdir/globals.out" "$tmpdir/options-$command.out" || true)
  if [[ -z $own ]]; then
    case $command in
      execution-plan | clean | import | cache) ;;
      *) echo "$command offers no options of its own" >&2; exit 1 ;;
    esac
  fi
  for option in $own; do
    option=${option%%=*}
    if ! grep -q -- "$option\\b" "$tmpdir/$command.help" &&
       ! { [[ $command == action-spec ]] && grep -q -- "$option\\b" "$tmpdir/build.help"; }; then
      echo "$command offers $option, which its --help doesn't list" >&2
      exit 1
    fi
  done
done < "$tmpdir/none.out"

# A project with a generator, groups, heaps, a dependency on disk (through a
# path override) and one that isn't (a git dependency never fetched).
lib=$tmpdir/lib
mkdir -p "$lib/src"
cat > "$lib/holproject.toml" <<'TOML'
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "lib"

[build]
members = ["src"]
TOML
echo 'Theory Lib' > "$lib/src/LibScript.sml"

project=$tmpdir/project
mkdir -p "$project/src/sub" "$project/gen"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "$tmpdir/no-such-hol"
rev = "1111111111111111111111111111111111111111"

[dependencies.lib]
git = "$tmpdir/no-such-lib"
rev = "2222222222222222222222222222222222222222"

[dependencies.remote]
git = "$tmpdir/no-such-remote"
rev = "3333333333333333333333333333333333333333"

[project]
name = "main"

[build]
members = ["src", "gen"]

[build.groups.subs]
include_globs = ["src/sub/*Script.sml"]

[[generate]]
name = "make-gen"
command = ["sh", "-c", "touch $tmpdir/generator-ran"]
outputs = ["gen/GenScript.sml"]

[[heap]]
name = "mainheap"
output = "main.save"
objects = ["AlphaTheory"]

[[executable]]
name = "runtests"
output = "runtests.exe"
objects = ["util"]
TOML
cat > "$project/.holconfig.toml" <<TOML
[overrides.lib]
path = "$lib"
TOML
for name in Alpha Alpine Beta; do echo "Theory $name" > "$project/src/${name}Script.sml"; done
echo 'Theory Sub' > "$project/src/sub/SubScript.sml"
echo 'structure util = struct end' > "$project/src/util.sml"
echo 'signature util = sig end' > "$project/src/util.sig"

complete "$project" top Al
expect top AlphaTheory AlpineTheory
complete "$project" build-targets build ""
expect build-targets @subs AlphaTheory AlpineTheory BetaTheory GenTheory LibTheory SubTheory util
complete "$project" bare-target AlphaTheory B
expect bare-target BetaTheory
complete "$project" group build @
expect group @subs
complete "$project" export export ""
expect export @subs AlphaTheory AlpineTheory BetaTheory GenTheory LibTheory SubTheory util
for command in clean execution-plan check; do
  complete "$project" "theories-$command" "$command" ""
  expect "theories-$command" AlphaTheory AlpineTheory BetaTheory GenTheory LibTheory SubTheory
done
complete "$project" from run --from A
expect from AlphaTheory AlpineTheory
complete "$project" heap heap ""
expect heap mainheap
complete "$project" executable executable ""
expect executable runtests
complete "$project" run-operand run ""
expect run-operand
complete "$project" theorem execution-plan AlphaTheory:
expect theorem

# --source-dir selects the project from elsewhere.
complete "$outside" source-dir --source-dir "$project" clean S
expect source-dir SubTheory
complete "$outside" source-dir-eq --source-dir="$project" clean S
expect source-dir-eq SubTheory

# At most 200, in order.
many=$tmpdir/many
mkdir -p "$many/src"
cat > "$many/holproject.toml" <<'TOML'
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "many"

[build]
members = ["src"]
TOML
for i in $(seq 100 350); do echo "Theory T$i" > "$many/src/T${i}Script.sml"; done
complete "$many" many clean T
[[ $(wc -l < "$tmpdir/many.out") -eq 200 ]] || { echo "expected 200 candidates" >&2; exit 1; }
LC_ALL=C sort -c "$tmpdir/many.out"
[[ $(head -n 1 "$tmpdir/many.out") == T100Theory ]]

# Nothing ran, was fetched or was written.
require_no_file "$tmpdir/generator-ran"
require_no_file "$HOLBUILD_CACHE"
require_no_file "$project/.holbuild"
require_no_file "$project/gen/GenScript.sml"
require_no_file "$lib/.holbuild"
if [[ -s "$attempts" ]]; then
  echo "the query started tools:" >&2
  cat "$attempts" >&2
  exit 1
fi

# A build holding the project lock doesn't hold up the query.
mkdir -p "$project/.holbuild/locks"
python3 - "$project/.holbuild/locks/project.lock" "$tmpdir/locked" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o666)
fcntl.lockf(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)
PY
holder=$!
for _ in $(seq 100); do [[ -e $tmpdir/locked ]] && break; sleep 0.1; done
require_file "$tmpdir/locked"
complete "$project" locked clean B
expect locked BetaTheory
