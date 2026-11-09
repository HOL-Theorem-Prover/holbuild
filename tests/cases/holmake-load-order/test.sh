#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A theory loads its dependencies in the order Holmake does: sorted by
# directory, then file name, HOL's directories first, then each package's
# by tier.  The header's order doesn't matter.  Load order is observable:
# a library that registers data when a theory loads (cv_compute's cv_rep
# theorems, say) keeps the last registration.  A worker restores the same
# order as the local build.

tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
unset HOLBUILD_REMOTE_CACHE_URL

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"

# sortingTheory is built from HOL's sources (package hol, src/sort) but sits
# in sigobj in a Holmake build, so it sorts with sumTheory by name.
#
# Package dep keeps its theory in a/, which sorts before HOL's sigobj but
# loads after it: dep is a package, HOL comes first.
dep=$tmpdir/dep
mkdir -p "$dep/a"
cat > "$dep/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "dep"

[build]
members = ["a"]
TOML
cat > "$dep/a/depScript.sml" <<'SML'
Theory dep

Theorem dep_thm:
  T
Proof
  simp[]
QED
SML

project=$tmpdir/project
mkdir -p "$project/src/a" "$project/src/b" "$project/src/top" "$project/shims"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "order"

[build]
members = ["src"]

[dependencies.dep]
git = "https://example.invalid/dep.git"
rev = "1111111111111111111111111111111111111111"

[dependencies.holexamples]
from = "hol"
path = "."
manifest = "shims/holexamples.toml"
TOML
cat > "$project/.holconfig.toml" <<'TOML'
[overrides.dep]
path = "../dep"
TOML
cat > "$project/shims/holexamples.toml" <<'TOML'
[holbuild]
minimum_version = "0.10.0"

[project]
name = "holexamples"

[build]
members = ["examples/countchars"]
TOML
cat > "$project/src/a/yScript.sml" <<'SML'
Theory y

Theorem y_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/b/bScript.sml" <<'SML'
Theory b

Theorem b_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/b/aLib.sml" <<'SML'
structure aLib =
struct
  val a = true
end
SML
# The header names its dependencies out of order.
header='Ancestors b countchars y sum dep sorting arithmetic
Libs aLib'
cat > "$project/src/top/useScript.sml" <<SML
Theory use
$header

val _ = aLib.a;

Theorem use_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/top/failScript.sml" <<SML
Theory fail
$header

val _ = raise Fail "keep the stage for preload inspection";
SML

expected='countcharsTheory
arithmeticTheory
sortingTheory
sumTheory
depTheory
yTheory
aLib
bTheory'

# The names a file's loads end in, in order, restricted to the expected ones.
loaded_names() {
  grep -oE "$1" "$2" | sed -E 's/.*"([^"]*)".*/\1/; s/.* //' | xargs -n1 basename |
    grep -xF -f <(printf '%s\n' "$expected") || true
}
check_order() {
  local what=$1 actual=$2 want=${3:-$expected}
  if [[ "$actual" != "$want" ]]; then
    echo "$what loads in the wrong order:" >&2
    echo "$actual" >&2
    exit 1
  fi
}
manifest_names() {
  xargs -n1 basename < "$1" | sed 's/\.sml$//' | grep -xF -f <(printf '%s\n' "$expected") || true
}

link_hol_toolchain_cache "$tmpdir/local"
(cd "$project" && HOLBUILD_CACHE=$tmpdir/local "$HOLBUILD_BIN" build useTheory) > "$tmpdir/local.log" 2>&1 ||
  { cat "$tmpdir/local.log" >&2; exit 1; }

# The object manifests: the script's direct loads, and the generated
# theory's parents (HOL drops the ones that are ancestors of others).
check_order "useScript.uo" "$(manifest_names "$project/.holbuild/obj/src/top/useScript.uo")"
theory_uo=$(manifest_names "$project/.holbuild/obj/src/top/useTheory.uo")
check_order "useTheory.uo" "$theory_uo" "$(grep -xF -f <(printf '%s\n' "$theory_uo") <<< "$expected")"

# The preload a theory's stage loads.
if (cd "$project" && HOLBUILD_CACHE=$tmpdir/local "$HOLBUILD_BIN" build --skip-checkpoints failTheory) \
     > "$tmpdir/fail.log" 2>&1; then
  echo "failTheory build unexpectedly succeeded" >&2
  exit 1
fi
preload=$(find "$project/.holbuild/stage" -name holbuild-preload.sml -print | head -n 1)
[[ -n "$preload" ]] || { echo "missing failTheory preload" >&2; cat "$tmpdir/fail.log" >&2; exit 1; }
check_order "the preload" "$(loaded_names 'HolbuildRuntime.load "[^"]*"' "$preload")"

# The worker gets the order: its spec's preload loads in it, and each
# dependency carries its order key, which the worker sorts restored
# manifests by.
link_hol_toolchain_cache "$tmpdir/client"
(cd "$project" && HOLBUILD_CACHE=$tmpdir/client "$HOLBUILD_BIN" --remote-cache "$remote_url" \
   action-spec --upload useTheory) > "$tmpdir/batch.txt"
spec=$(awk '$1 == "action" && $5 == "order:useTheory" { print $4 }' "$tmpdir/batch.txt")
spec_path=$project/.holbuild/action-specs/$spec
require_file "$spec_path"
check_order "the spec's preload" "$(loaded_names '^load [a-z]* .*' "$spec_path")"
require_grep '^order holexamples:countcharsTheory 0 \. examples/countchars$' "$spec_path"
require_grep '^order hol:sortingTheory 0 \. sigobj$' "$spec_path"
require_grep '^order dep:depTheory 1 dep a$' "$spec_path"
require_grep '^order order:bTheory 2 order src/b$' "$spec_path"
require_grep '^order order:aLib 2 order src/b$' "$spec_path"

# Each action the worker builds gives the local build's bytes.
link_hol_toolchain_cache "$tmpdir/worker"
mkdir -p "$tmpdir/cwd"
while read -r _ key _ spec target; do
  (cd "$tmpdir/cwd" && HOLBUILD_CACHE=$tmpdir/worker "$HOLBUILD_BIN" --remote-cache "$remote_url" \
     exec-action "$spec" --cache-limit-gb 1000 --result "$tmpdir/result") > "$tmpdir/worker.log" 2>&1 ||
    { echo "worker failed on $target" >&2; cat "$tmpdir/worker.log" "$tmpdir/result" >&2; exit 1; }
  require_grep '^status=built$' "$tmpdir/result"
  if ! diff <(grep '^blob ' "$tmpdir/worker/actions/$key/manifest") \
            <(grep '^blob ' "$tmpdir/local/actions/$key/manifest") >&2; then
    echo "$target: the worker's outputs (<) differ from the local build's (>)" >&2
    exit 1
  fi
done < <(grep '^action ' "$tmpdir/batch.txt")
