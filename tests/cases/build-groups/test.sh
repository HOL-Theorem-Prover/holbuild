#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

require_no_grep() {
  local pattern=$1
  local path=$2
  if grep -q "$pattern" "$path"; then
    echo "unexpected pattern '$pattern' in $path" >&2
    exit 1
  fi
}

require_no_file() {
  local path=$1
  if [[ -e "$path" ]]; then
    echo "unexpected file exists: $path" >&2
    exit 1
  fi
}

write_manifest_prelude() {
  cat <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

TOML
}

write_theory() {
  local path=$1
  local name=$2
  cat > "$path" <<SML
Theory $name

Theorem ${name}_thm:
  T
Proof
  simp[]
QED

val _ = export_theory();
SML
}

# 1. Default build via root_groups: generated members are individual build nodes,
# and no synthetic aggregate theory artifact is created.
root_groups_project=$tmpdir/root-groups
mkdir -p "$root_groups_project/src" "$root_groups_project/gen"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "root-groups"

[build]
members = ["src", "gen"]
roots = ["src/MainScript.sml"]
root_groups = ["generated"]

[build.groups.generated]
include_globs = ["gen/*Script.sml"]
TOML
} > "$root_groups_project/holproject.toml"
write_theory "$root_groups_project/src/MainScript.sml" Main
write_theory "$root_groups_project/gen/AlphaScript.sml" Alpha
write_theory "$root_groups_project/gen/BetaScript.sml" Beta
(cd "$root_groups_project" && "$HOLBUILD_BIN" context) > "$tmpdir/root-groups.context"
require_grep "root_groups: generated" "$tmpdir/root-groups.context"
require_grep "group: generated" "$tmpdir/root-groups.context"
(cd "$root_groups_project" && "$HOLBUILD_BIN" --verbose build --dry-run) > "$tmpdir/root-groups.dry" 2>&1
require_grep "MainTheory (theory, package root-groups)" "$tmpdir/root-groups.dry"
require_grep "AlphaTheory (theory, package root-groups)" "$tmpdir/root-groups.dry"
require_grep "BetaTheory (theory, package root-groups)" "$tmpdir/root-groups.dry"
require_no_grep "[Gg]eneratedTheory" "$tmpdir/root-groups.dry"
(cd "$root_groups_project" && "$HOLBUILD_BIN" build) > "$tmpdir/root-groups.build" 2>&1
require_file "$root_groups_project/.holbuild/obj/src/MainTheory.dat"
require_file "$root_groups_project/.holbuild/obj/gen/AlphaTheory.dat"
require_file "$root_groups_project/.holbuild/obj/gen/BetaTheory.dat"
require_no_file "$root_groups_project/.holbuild/obj/GeneratedTheory.dat"
require_no_file "$root_groups_project/.holbuild/obj/generatedTheory.dat"
require_no_file "$root_groups_project/.holbuild/obj/gen/GeneratedTheory.dat"
require_no_file "$root_groups_project/.holbuild/obj/gen/generatedTheory.dat"

# 2. @group in build.roots has the same expansion behavior and creates no aggregate.
roots_project=$tmpdir/roots-group
mkdir -p "$roots_project/src" "$roots_project/gen"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "roots-group"

[build]
members = ["src", "gen"]
roots = ["src/MainScript.sml", "@generated"]

[build.groups.generated]
include_globs = ["gen/*Script.sml"]
TOML
} > "$roots_project/holproject.toml"
write_theory "$roots_project/src/MainScript.sml" Main
write_theory "$roots_project/gen/GammaScript.sml" Gamma
write_theory "$roots_project/gen/DeltaScript.sml" Delta
(cd "$roots_project" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/roots-group.dry" 2>&1
require_grep "MainTheory (theory, package roots-group)" "$tmpdir/roots-group.dry"
require_grep "GammaTheory (theory, package roots-group)" "$tmpdir/roots-group.dry"
require_grep "DeltaTheory (theory, package roots-group)" "$tmpdir/roots-group.dry"
require_no_grep "[Gg]eneratedTheory" "$tmpdir/roots-group.dry"
(cd "$roots_project" && "$HOLBUILD_BIN" build) > "$tmpdir/roots-group.build" 2>&1
require_file "$roots_project/.holbuild/obj/src/MainTheory.dat"
require_file "$roots_project/.holbuild/obj/gen/GammaTheory.dat"
require_file "$roots_project/.holbuild/obj/gen/DeltaTheory.dat"
require_no_file "$roots_project/.holbuild/obj/GeneratedTheory.dat"
require_no_file "$roots_project/.holbuild/obj/gen/GeneratedTheory.dat"

# 3. @group on the CLI builds exactly the group members; extra CLI targets are added.
cli_project=$tmpdir/cli-group
mkdir -p "$cli_project/src" "$cli_project/gen"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "cli-group"

[build]
members = ["src", "gen"]

[build.groups.generated]
include_globs = ["gen/*Script.sml"]
TOML
} > "$cli_project/holproject.toml"
write_theory "$cli_project/gen/CliOneScript.sml" CliOne
write_theory "$cli_project/gen/CliTwoScript.sml" CliTwo
cat > "$cli_project/src/Extra.sml" <<'SML'
val extra_value = 42;
SML
(cd "$cli_project" && "$HOLBUILD_BIN" build @generated) > "$tmpdir/cli-group.only" 2>&1
require_file "$cli_project/.holbuild/obj/gen/CliOneTheory.dat"
require_file "$cli_project/.holbuild/obj/gen/CliTwoTheory.dat"
require_no_file "$cli_project/.holbuild/obj/src/Extra.uo"
(cd "$cli_project" && "$HOLBUILD_BIN" build @generated Extra) > "$tmpdir/cli-group.extra" 2>&1
require_file "$cli_project/.holbuild/obj/src/Extra.uo"

# 4. include_globs, exclude_globs, and concrete exclude directories interact in the group plan.
exclude_project=$tmpdir/exclude-group
mkdir -p "$exclude_project/gen/excluded"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "exclude-group"

[build]
members = ["gen"]

[build.groups.generated]
include_globs = ["gen/*Script.sml"]
exclude_globs = ["gen/*BrokenScript.sml"]
exclude = ["gen/excluded"]
TOML
} > "$exclude_project/holproject.toml"
write_theory "$exclude_project/gen/KeepScript.sml" Keep
write_theory "$exclude_project/gen/AlsoKeepScript.sml" AlsoKeep
cat > "$exclude_project/gen/BrokenScript.sml" <<'SML'
this excluded file must not be scheduled
SML
cat > "$exclude_project/gen/excluded/SkippedScript.sml" <<'SML'
this excluded directory must not be scheduled
SML
(cd "$exclude_project" && "$HOLBUILD_BIN" build --dry-run @generated) > "$tmpdir/exclude-group.dry" 2>&1
require_grep "KeepTheory (theory, package exclude-group)" "$tmpdir/exclude-group.dry"
require_grep "AlsoKeepTheory (theory, package exclude-group)" "$tmpdir/exclude-group.dry"
require_no_grep "Broken" "$tmpdir/exclude-group.dry"
require_no_grep "Skipped" "$tmpdir/exclude-group.dry"

# 5. Groups may contain any source kind, not only theory scripts.
any_source_project=$tmpdir/any-source-group
mkdir -p "$any_source_project/gen"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "any-source-group"

[build]
members = ["gen"]

[build.groups.mixed]
include_globs = ["gen/*.sml"]
TOML
} > "$any_source_project/holproject.toml"
write_theory "$any_source_project/gen/MixedScript.sml" Mixed
cat > "$any_source_project/gen/Helper.sml" <<'SML'
val helper_value = 7;
SML
(cd "$any_source_project" && "$HOLBUILD_BIN" build --dry-run @mixed) > "$tmpdir/any-source-group.dry" 2>&1
require_grep "MixedTheory (theory, package any-source-group)" "$tmpdir/any-source-group.dry"
require_grep "Helper (sml, package any-source-group)" "$tmpdir/any-source-group.dry"

# 6. Empty groups error by default, but allow_empty = true succeeds with no work.
empty_bad=$tmpdir/empty-bad
mkdir -p "$empty_bad"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "empty-bad"

[build]
members = []
root_groups = ["empty"]

[build.groups.empty]
include_globs = ["gen/*Script.sml"]
TOML
} > "$empty_bad/holproject.toml"
if (cd "$empty_bad" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/empty-bad.log" 2>&1; then
  echo "empty group without allow_empty unexpectedly succeeded" >&2
  exit 1
fi
require_grep "matched no sources" "$tmpdir/empty-bad.log"
empty_ok=$tmpdir/empty-ok
mkdir -p "$empty_ok"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "empty-ok"

[build]
members = []
root_groups = ["empty"]

[build.groups.empty]
include_globs = ["gen/*Script.sml"]
allow_empty = true
TOML
} > "$empty_ok/holproject.toml"
(cd "$empty_ok" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/empty-ok.dry" 2>&1
require_no_grep "(theory, package empty-ok)" "$tmpdir/empty-ok.dry"
(cd "$empty_ok" && "$HOLBUILD_BIN" build) > "$tmpdir/empty-ok.build" 2>&1
if [[ -d "$empty_ok/.holbuild/obj" ]] && find "$empty_ok/.holbuild/obj" -type f | grep -q .; then
  echo "allow_empty group unexpectedly built object files" >&2
  exit 1
fi
empty_with_sources=$tmpdir/empty-with-sources
mkdir -p "$empty_with_sources/src"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "empty-with-sources"

[build]
members = ["src"]
root_groups = ["empty"]

[build.groups.empty]
include_globs = ["gen/*Script.sml"]
allow_empty = true
TOML
} > "$empty_with_sources/holproject.toml"
write_theory "$empty_with_sources/src/SurpriseScript.sml" Surprise
(cd "$empty_with_sources" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/empty-with-sources.dry" 2>&1
require_no_grep "SurpriseTheory (theory, package empty-with-sources)" "$tmpdir/empty-with-sources.dry"
(cd "$empty_with_sources" && "$HOLBUILD_BIN" build --dry-run @empty) > "$tmpdir/empty-with-sources-cli.dry" 2>&1
require_no_grep "SurpriseTheory (theory, package empty-with-sources)" "$tmpdir/empty-with-sources-cli.dry"
(cd "$empty_with_sources" && "$HOLBUILD_BIN" build) > "$tmpdir/empty-with-sources.build" 2>&1
require_no_file "$empty_with_sources/.holbuild/obj/src/SurpriseTheory.dat"

# 7. Undefined group references are rejected in root_groups, CLI targets, and heap objects.
undefined_root=$tmpdir/undefined-root
mkdir -p "$undefined_root"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "undefined-root"

[build]
members = []
root_groups = ["nope"]
TOML
} > "$undefined_root/holproject.toml"
if (cd "$undefined_root" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/undefined-root.log" 2>&1; then
  echo "undefined build.root_groups entry unexpectedly succeeded" >&2
  exit 1
fi
require_grep "unknown group" "$tmpdir/undefined-root.log"
undefined_cli=$tmpdir/undefined-cli
mkdir -p "$undefined_cli"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "undefined-cli"

[build]
members = []
TOML
} > "$undefined_cli/holproject.toml"
if (cd "$undefined_cli" && "$HOLBUILD_BIN" build --dry-run @nope) > "$tmpdir/undefined-cli.log" 2>&1; then
  echo "undefined CLI group unexpectedly succeeded" >&2
  exit 1
fi
require_grep "unknown group" "$tmpdir/undefined-cli.log"
undefined_heap=$tmpdir/undefined-heap
mkdir -p "$undefined_heap"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "undefined-heap"

[build]
members = []

[[heap]]
name = "main"
output = ".holbuild/heap/main.save"
objects = ["@nope"]
TOML
} > "$undefined_heap/holproject.toml"
if (cd "$undefined_heap" && "$HOLBUILD_BIN" heap main) > "$tmpdir/undefined-heap.log" 2>&1; then
  echo "undefined heap object group unexpectedly succeeded" >&2
  exit 1
fi
require_grep "unknown group" "$tmpdir/undefined-heap.log"

# 8. @group expands inside [[heap]] and [[executable]] objects.
image_project=$tmpdir/image-group
mkdir -p "$image_project/gen"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "image-group"

[build]
members = ["gen"]

[build.groups.generated]
include_globs = ["gen/*.sml"]

[[heap]]
name = "main"
output = ".holbuild/heap/main.save"
objects = ["@generated"]

[[executable]]
name = "runtests"
output = "runtests.exe"
objects = ["@generated"]
TOML
} > "$image_project/holproject.toml"
write_theory "$image_project/gen/HeapOneScript.sml" HeapOne
write_theory "$image_project/gen/HeapTwoScript.sml" HeapTwo
cat > "$image_project/gen/runner.sml" <<'SML'
fun main () = print "group executable ok\n";
SML
(cd "$image_project" && "$HOLBUILD_BIN" heap main) > "$tmpdir/image-group.heap" 2>&1
require_file "$image_project/.holbuild/heap/main.save"
require_file "$image_project/.holbuild/obj/gen/HeapOneTheory.dat"
require_file "$image_project/.holbuild/obj/gen/HeapTwoTheory.dat"
require_file "$image_project/.holbuild/obj/gen/runner.uo"
(cd "$image_project" && "$HOLBUILD_BIN" executable runtests) > "$tmpdir/image-group.exe" 2>&1
require_file "$image_project/runtests.exe"
"$image_project/runtests.exe" > "$tmpdir/image-group.exe.out"
require_grep "group executable ok" "$tmpdir/image-group.exe.out"

# 9. Explicit heap/executable object order is preserved when no group token is present.
order_project=$tmpdir/order-image
mkdir -p "$order_project/src"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "order-image"

[build]
members = ["src"]

[[executable]]
name = "ordered"
output = "ordered.exe"
objects = ["State", "InitB", "InitA", "ordered_runner"]
TOML
} > "$order_project/holproject.toml"
cat > "$order_project/src/State.sml" <<'SML'
structure OrderState = struct
  val events = ref ([] : string list);
end;
SML
cat > "$order_project/src/InitB.sml" <<'SML'
val _ = OrderState.events := !OrderState.events @ ["B"];
SML
cat > "$order_project/src/InitA.sml" <<'SML'
val _ = OrderState.events := !OrderState.events @ ["A"];
SML
cat > "$order_project/src/ordered_runner.sml" <<'SML'
fun main () = print (String.concat (!OrderState.events) ^ "\n");
SML
(cd "$order_project" && "$HOLBUILD_BIN" executable ordered) > "$tmpdir/order-image.exe" 2>&1
"$order_project/ordered.exe" > "$tmpdir/order-image.out"
require_grep "^BA$" "$tmpdir/order-image.out"

# 10. warn-unreachable treats root_groups as roots: omitted scripts warn, group members do not.
warn_project=$tmpdir/warn-group
mkdir -p "$warn_project/gen" "$warn_project/src"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "warn-group"

[build]
members = ["gen", "src"]
root_groups = ["generated"]

[build.groups.generated]
include_globs = ["gen/*Script.sml"]
TOML
} > "$warn_project/holproject.toml"
write_theory "$warn_project/gen/WarnOneScript.sml" WarnOne
write_theory "$warn_project/gen/WarnTwoScript.sml" WarnTwo
write_theory "$warn_project/src/OmittedScript.sml" Omitted
(cd "$warn_project" && "$HOLBUILD_BIN" build --dry-run --warn-unreachable) > "$tmpdir/warn-group.out" 2> "$tmpdir/warn-group.err"
require_grep "discoverable theory script(s) are not reachable from build.roots" "$tmpdir/warn-group.err"
require_grep "unreachable: warn-group:src/OmittedScript.sml (OmittedTheory)" "$tmpdir/warn-group.err"
require_no_grep "WarnOne" "$tmpdir/warn-group.err"
require_no_grep "WarnTwo" "$tmpdir/warn-group.err"

empty_warn_project=$tmpdir/empty-warn-group
mkdir -p "$empty_warn_project/gen" "$empty_warn_project/src"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "empty-warn-group"

[build]
members = ["gen", "src"]
root_groups = ["generated"]

[build.groups.generated]
include_globs = ["gen/*Script.sml"]
allow_empty = true
TOML
} > "$empty_warn_project/holproject.toml"
write_theory "$empty_warn_project/src/OmittedScript.sml" Omitted
(cd "$empty_warn_project" && "$HOLBUILD_BIN" build --dry-run --warn-unreachable) > "$tmpdir/empty-warn-group.out" 2> "$tmpdir/empty-warn-group.err"
require_grep "discoverable theory script(s) are not reachable from build.roots" "$tmpdir/empty-warn-group.err"
require_grep "unreachable: empty-warn-group:src/OmittedScript.sml (OmittedTheory)" "$tmpdir/empty-warn-group.err"

# 11. Group expansion happens after generators run, so newly generated sources are included.
generate_project=$tmpdir/generate-group
mkdir -p "$generate_project/scripts"
{
  write_manifest_prelude
  cat <<'TOML'
[project]
name = "generate-group"

[build]
members = ["gen"]
root_groups = ["generated"]

[build.groups.generated]
include_globs = ["gen/*Script.sml"]

[[generate]]
name = "new-theory"
command = ["python3", "scripts/gen_new.py", "gen/NewScript.sml"]
outputs = ["gen/NewScript.sml"]
TOML
} > "$generate_project/holproject.toml"
cat > "$generate_project/scripts/gen_new.py" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text('''Theory New

Theorem new_thm:
  T
Proof
  simp[]
QED

val _ = export_theory();
''')
PY
(cd "$generate_project" && "$HOLBUILD_BIN" build) > "$tmpdir/generate-group.build" 2>&1
require_file "$generate_project/gen/NewScript.sml"
require_file "$generate_project/.holbuild/obj/gen/NewTheory.dat"
