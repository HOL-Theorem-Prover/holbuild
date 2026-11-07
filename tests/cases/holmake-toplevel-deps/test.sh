#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src" "$project/src/simp/src" "$project/tools/sequences" "$project/tools/build"
printf '#include sequences/upto-hol\nsrc\n' > "$project/tools/build/build-sequence"
printf 'src/simp/src\n' > "$project/tools/sequences/upto-hol"
cat > "$project/src/simp/src/BoolconvContextScript.sml" <<'SML'
open HolKernel Parse boolLib;
val _ = new_theory "BoolconvContext";
val _ = export_theory ();
SML
cat > "$project/src/simp/src/Traverse.sml" <<'SML'
structure Traverse = struct end
SML
cat > "$project/src/interface.sml" <<'SML'
signature DIFFERENT_NAME = sig val witness : bool end
SML
cat > "$project/src/factory.sml" <<'SML'
functor DifferentName () : DIFFERENT_NAME = struct val witness = true end
SML
cat > "$project/src/FixtureSyntax.sml" <<'SML'
structure FixtureSyntax = DifferentName ()
SML
printf 'structure BuildOnly = struct end\n' > "$project/src/BuildOnly.sml"
cat > "$project/src/ConsumerScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Consumer";
val _ = if FixtureSyntax.witness then () else raise Fail "functor did not load";
val witness = store_thm ("witness", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory ();
SML

# Export fields match Holmake's line-oriented format. The unrelated recipe
# deliberately contains unescaped quotes, as older HOL versions emitted them.
cat > "$tmpdir/graph" <<JSON
[
{
  "node_id" : 1,
  "target" : "$project/src/interface.uo",
  "dependencies" : [],
  "command" : "%%MOSCOWML_INDICATOR%% -c -toplevel interface.sml"
},
{
  "node_id" : 2,
  "target" : "$project/src/factory.uo",
  "dependencies" : [1],
  "command" : "%%MOSCOWML_INDICATOR%% -c -toplevel interface.ui factory.sml"
},
{
  "node_id" : 3,
  "target" : "$project/src/FixtureSyntax.uo",
  "dependencies" : [2, 6],
  "command" : "%%MOSCOWML_INDICATOR%% -toplevel -c interface.ui factory.ui FixtureSyntax.sml"
},
{
  "node_id" : 4,
  "target" : "$project/src/BuildOnly.uo",
  "dependencies" : [3],
  "command" : "echo "build-only dependency""
},
{
  "node_id" : 5,
  "target" : "$project/src/simp/src/BoolconvContextScript.sml",
  "dependencies" : []
},
{
  "node_id" : 6,
  "target" : "$project/src/simp/src/Traverse.uo",
  "dependencies" : [1],
  "command" : "%%MOSCOWML_INDICATOR%% -c -toplevel Traverse.sml"
}
]
JSON
cat > "$tmpdir/generate.sml" <<SML
use "$HOLBUILD_ROOT/vendor/hol/tools-poly/poly/Binarymap.sig";
use "$HOLBUILD_ROOT/vendor/hol/tools-poly/poly/Binarymap.sml";
structure HolbuildHash = struct fun quote s = "'" ^ s ^ "'" end;
structure HolbuildProcessGroup = struct exception Error of string end;
use "$HOLBUILD_ROOT/sml/hol_toolchain_config.sml";
use "$HOLBUILD_ROOT/sml/builtin_manifests.sml";
use "$HOLBUILD_ROOT/sml/hol_source_manifest.sml";
val input = TextIO.openIn "$tmpdir/graph";
val graph = TextIO.inputAll input before TextIO.closeIn input;
val _ = HolbuildHolSourceManifest.generate
  {holdir = "$project", manifest_path = "$project/holproject.toml",
   members_path = "$tmpdir/members",
   run_command = fn _ => {status = OS.Process.success, output = graph}};
SML
poly --script "$tmpdir/generate.sml" > "$tmpdir/generate.log" 2>&1
if grep -qx 'src/simp/src' "$tmpdir/members" || grep -q '"src/simp/src"' "$project/holproject.toml"; then
  echo 'included preloaded upto-hol directory in hol-source.manifest members' >&2
  exit 1
fi
if grep -q 'actions."Traverse"' "$project/holproject.toml"; then
  echo 'emitted action policy for preloaded upto-hol module' >&2
  exit 1
fi
require_grep '\[actions."factory"\]' "$project/holproject.toml"
require_grep 'loads = \["interface"\]' "$project/holproject.toml"
require_grep 'loads = \["factory", "Traverse"\]' "$project/holproject.toml"
if grep -q 'actions."BuildOnly"' "$project/holproject.toml"; then
  echo 'imported arbitrary recipe dependencies as loads' >&2
  exit 1
fi
sed -i 's/name = "hol"/name = "toplevel-fixture"/' "$project/holproject.toml"
cat >> "$project/holproject.toml" <<TOML
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"
TOML
(cd "$project" && "$HOLBUILD_BIN" build --skip-checkpoints --no-cache ConsumerTheory) > "$tmpdir/build.log" 2>&1
require_file "$project/.holbuild/obj/src/ConsumerTheory.dat"
require_grep 'Saved theorem.*witness' "$project/.holbuild/logs/current/toplevel-fixture/ConsumerTheory/build.log"
require_grep '/interface' "$project/.holbuild/obj/src/factory.uo"
require_grep '/factory' "$project/.holbuild/obj/src/FixtureSyntax.uo"
