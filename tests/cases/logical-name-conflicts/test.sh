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
export HOLBUILD_CACHE="$tmpdir/cache"

expect_dry_run_failure() {
  local project=$1
  local pattern=$2
  local log=$tmpdir/$project.log
  if (cd "$tmpdir/$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run Foo) > "$log" 2>&1; then
    echo "duplicate logical-name graph unexpectedly accepted: $project" >&2
    exit 1
  fi
  require_grep "$pattern" "$log"
}

make_root_manifest() {
  local project=$1
  cat > "$tmpdir/$project/holproject.toml" <<'TOML'
[project]
name = "root"

[build]
members = ["src"]
TOML
}

make_dep_manifest() {
  local depdir=$1
  cat > "$depdir/holproject.toml" <<'TOML'
[project]
name = "dep"

[build]
members = ["src"]
TOML
}

mkdir -p "$tmpdir/companion/src"
make_root_manifest companion
cat > "$tmpdir/companion/src/Foo.sig" <<'SML'
signature Foo = sig val x : int end
SML
cat > "$tmpdir/companion/src/Foo.sml" <<'SML'
structure Foo = struct val x = 1 end
SML
(cd "$tmpdir/companion" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run Foo) > "$tmpdir/companion.log"
require_grep "Foo (sig, package root)" "$tmpdir/companion.log"
require_grep "Foo (sml, package root)" "$tmpdir/companion.log"

mkdir -p "$tmpdir/duplicate_module/src" "$tmpdir/dep_module/src"
cat > "$tmpdir/duplicate_module/holproject.toml" <<'TOML'
[project]
name = "root"

[build]
members = ["src"]

[dependencies.dep]
path = "../dep_module"
TOML
make_dep_manifest "$tmpdir/dep_module"
cat > "$tmpdir/duplicate_module/src/Foo.sml" <<'SML'
structure Foo = struct val x = 1 end
SML
cat > "$tmpdir/dep_module/src/Foo.sml" <<'SML'
structure Foo = struct val x = 2 end
SML
expect_dry_run_failure duplicate_module "duplicate logical name Foo"

mkdir -p "$tmpdir/remote_companion_root/src" "$tmpdir/remote_companion_dep/src"
cat > "$tmpdir/remote_companion_root/holproject.toml" <<'TOML'
[project]
name = "root"

[build]
members = ["src"]

[dependencies.dep]
path = "../remote_companion_dep"
TOML
make_dep_manifest "$tmpdir/remote_companion_dep"
cat > "$tmpdir/remote_companion_root/src/Foo.sig" <<'SML'
signature Foo = sig val x : int end
SML
cat > "$tmpdir/remote_companion_dep/src/Foo.sml" <<'SML'
structure Foo = struct val x = 1 end
SML
expect_dry_run_failure remote_companion_root "duplicate logical name Foo"

mkdir -p "$tmpdir/duplicate_theory/src" "$tmpdir/dep_theory/src"
cat > "$tmpdir/duplicate_theory/holproject.toml" <<'TOML'
[project]
name = "root"

[build]
members = ["src"]

[dependencies.dep]
path = "../dep_theory"
TOML
make_dep_manifest "$tmpdir/dep_theory"
cat > "$tmpdir/duplicate_theory/src/FooScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Foo";
val _ = export_theory();
SML
cat > "$tmpdir/dep_theory/src/FooScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Foo";
val _ = export_theory();
SML
expect_dry_run_failure duplicate_theory "duplicate logical name FooTheory"

mkdir -p "$tmpdir/duplicate_source_path/src"
make_root_manifest duplicate_source_path
cat > "$tmpdir/duplicate_source_path/holproject.toml" <<'TOML'
[project]
name = "root"

[build]
members = ["src", "src/Foo.sml"]
TOML
cat > "$tmpdir/duplicate_source_path/src/Foo.sml" <<'SML'
structure Foo = struct val x = 1 end
SML
expect_dry_run_failure duplicate_source_path "source path appears in multiple package members"
