#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "refresh"

[build]
members = ["src"]

[actions.ATheory]
extra_deps = ["gen/provenance.txt", "gen/copied.txt"]

[actions.BTheory]
extra_deps = ["gen/provenance.txt"]

[[generate]]
name = "provenance"
command = ["sh", "-c", "cat ambient.txt > gen/provenance.txt; echo run >> refresh.count"]
outputs = ["gen/provenance.txt"]
always_reexecute = true

[[generate]]
name = "copy"
deps = ["provenance"]
command = ["sh", "-c", "cp gen/provenance.txt gen/copied.txt; echo run >> copy.count"]
outputs = ["gen/copied.txt"]
TOML
# ambient.txt deliberately isn't a declared input: it represents state a
# provenance collector discovers itself, outside portable file dependencies.
printf 'first\n' > "$project/ambient.txt"
for name in A B Unrelated; do
  cat > "$project/src/${name}Script.sml" <<SML
Theory $name
Theorem trivial: T
Proof ACCEPT_TAC TRUTH
QED
SML
done

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log"
(cd "$project" && "$HOLBUILD_BIN" build UnrelatedTheory) > "$tmpdir/unrelated.log"
[[ ! -e "$project/refresh.count" ]] || { echo "unreachable collector ran" >&2; exit 1; }

(cd "$project" && "$HOLBUILD_BIN" build ATheory BTheory) > "$tmpdir/first.log"
key=$(grep '^input_key=' "$project/.holbuild/dep/refresh/src/AScript.sml.key")
[[ $(wc -l < "$project/refresh.count") -eq 1 ]] || { echo "collector ran more than once for overlapping demands" >&2; exit 1; }
[[ $(wc -l < "$project/copy.count") -eq 1 ]] || { echo "dependent generator did not run once" >&2; exit 1; }

(cd "$project" && "$HOLBUILD_BIN" --verbose build ATheory BTheory) > "$tmpdir/unchanged.log"
require_grep 'ATheory is up to date' "$tmpdir/unchanged.log"
require_grep 'BTheory is up to date' "$tmpdir/unchanged.log"
[[ $(grep '^input_key=' "$project/.holbuild/dep/refresh/src/AScript.sml.key") == "$key" ]] || { echo "unchanged collector output invalidated consumer key" >&2; exit 1; }
[[ $(wc -l < "$project/refresh.count") -eq 2 ]] || { echo "demanded collector was not refreshed once" >&2; exit 1; }
[[ $(wc -l < "$project/copy.count") -eq 1 ]] || { echo "unchanged collector output reran dependent generator" >&2; exit 1; }

printf 'second\n' > "$project/ambient.txt"
(cd "$project" && "$HOLBUILD_BIN" build ATheory BTheory) > "$tmpdir/changed.log"
[[ $(grep '^input_key=' "$project/.holbuild/dep/refresh/src/AScript.sml.key") != "$key" ]] || { echo "changed collector output did not invalidate consumer key" >&2; exit 1; }
[[ $(cat "$project/gen/copied.txt") == second ]] || { echo "dependent generator saw stale collector output" >&2; exit 1; }
[[ $(wc -l < "$project/refresh.count") -eq 3 ]] || { echo "changed collector was not refreshed once" >&2; exit 1; }
[[ $(wc -l < "$project/copy.count") -eq 2 ]] || { echo "changed collector output did not rerun dependent generator" >&2; exit 1; }

(cd "$project" && "$HOLBUILD_BIN" build UnrelatedTheory) > "$tmpdir/unrelated-again.log"
[[ $(wc -l < "$project/refresh.count") -eq 3 ]] || { echo "unrelated target refreshed collector" >&2; exit 1; }

# False and absent have the same semantic definition and ordinary skip policy.
sed -i 's/always_reexecute = true/always_reexecute = false/' "$project/holproject.toml"
(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/false.log"
sed -i '/always_reexecute = false/d' "$project/holproject.toml"
(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/absent.log"
cmp "$tmpdir/false.log" "$tmpdir/absent.log"
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/default.log"
[[ $(wc -l < "$project/refresh.count") -eq 3 ]] || { echo "default policy changed generator metadata keys" >&2; exit 1; }
