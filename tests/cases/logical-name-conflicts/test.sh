#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

expect_dry_run_failure() {
  local project=$1
  local pattern=$2
  local log=$tmpdir/$project.log
  if (cd "$tmpdir/$project" && "$HOLBUILD_BIN" build --dry-run Foo) > "$log" 2>&1; then
    echo "duplicate logical-name graph unexpectedly accepted: $project" >&2
    exit 1
  fi
  require_grep "$pattern" "$log"
}

write_root_manifest() {
  local dir=$1
  {
    write_schema2_prelude
    cat <<'TOML'
[project]
name = "root"

[build]
members = ["src"]
TOML
  } > "$dir/holproject.toml"
}

write_dep_manifest() {
  local dir=$1
  {
    write_schema2_prelude
    cat <<'TOML'
[project]
name = "dep"

[build]
members = ["src"]
TOML
  } > "$dir/holproject.toml"
}

write_root_with_dep() {
  local dir=$1 depdir=$2 deprev=$3
  {
    write_schema2_prelude
    cat <<TOML
[project]
name = "root"

[build]
members = ["src"]

[dependencies.dep]
git = "$depdir"
rev = "$deprev"
TOML
  } > "$dir/holproject.toml"
}

mkdir -p "$tmpdir/companion/src"
write_root_manifest "$tmpdir/companion"
cat > "$tmpdir/companion/src/Foo.sig" <<'SML'
signature Foo = sig val x : int end
SML
cat > "$tmpdir/companion/src/Foo.sml" <<'SML'
structure Foo = struct val x = 1 end
SML
(cd "$tmpdir/companion" && "$HOLBUILD_BIN" build --dry-run Foo) > "$tmpdir/companion.log"
require_grep "Foo (sig, package root)" "$tmpdir/companion.log"
require_grep "Foo (sml, package root)" "$tmpdir/companion.log"

mkdir -p "$tmpdir/duplicate_module/src" "$tmpdir/dep_module/src"
write_dep_manifest "$tmpdir/dep_module"
cat > "$tmpdir/duplicate_module/src/Foo.sml" <<'SML'
structure Foo = struct val x = 1 end
SML
cat > "$tmpdir/dep_module/src/Foo.sml" <<'SML'
structure Foo = struct val x = 2 end
SML
dep_rev=$(init_git_repo "$tmpdir/dep_module")
write_root_with_dep "$tmpdir/duplicate_module" "$tmpdir/dep_module" "$dep_rev"
expect_dry_run_failure duplicate_module "duplicate logical name Foo"

mkdir -p "$tmpdir/remote_companion_root/src" "$tmpdir/remote_companion_dep/src"
write_dep_manifest "$tmpdir/remote_companion_dep"
cat > "$tmpdir/remote_companion_root/src/Foo.sig" <<'SML'
signature Foo = sig val x : int end
SML
cat > "$tmpdir/remote_companion_dep/src/Foo.sml" <<'SML'
structure Foo = struct val x = 1 end
SML
dep_rev=$(init_git_repo "$tmpdir/remote_companion_dep")
write_root_with_dep "$tmpdir/remote_companion_root" "$tmpdir/remote_companion_dep" "$dep_rev"
expect_dry_run_failure remote_companion_root "duplicate logical name Foo"

mkdir -p "$tmpdir/duplicate_theory/src" "$tmpdir/dep_theory/src"
write_dep_manifest "$tmpdir/dep_theory"
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
dep_rev=$(init_git_repo "$tmpdir/dep_theory")
write_root_with_dep "$tmpdir/duplicate_theory" "$tmpdir/dep_theory" "$dep_rev"
expect_dry_run_failure duplicate_theory "duplicate logical name FooTheory"

# A selected root must not change the key order of same-package signature and
# implementation dependencies that are also selected by an umbrella root.
mkdir -p "$tmpdir/root-stability/src"
write_root_manifest "$tmpdir/root-stability"
cat > "$tmpdir/root-stability/src/Shared.sig" <<'SML'
signature Shared = sig val value : bool end
SML
cat > "$tmpdir/root-stability/src/Shared.sml" <<'SML'
structure Shared = struct val value = true end
SML
cat > "$tmpdir/root-stability/src/RootScript.sml" <<'SML'
Theory Root
Libs Shared


val _ = export_theory();
SML
(cd "$tmpdir/root-stability" &&
  HOLBUILD_DUMP_KEYS="$tmpdir/root.keys" \
  HOLBUILD_DUMP_KEYS_TOOLCHAIN_KEY=root-stability-v1 \
  "$HOLBUILD_BIN" build RootTheory) > "$tmpdir/root.log"

cat > "$tmpdir/root-stability/src/AardvarkScript.sml" <<'SML'
Theory Aardvark
Ancestors Root

val _ = export_theory();
SML
rm -rf "$tmpdir/root-stability/.holbuild"
(cd "$tmpdir/root-stability" &&
  HOLBUILD_DUMP_KEYS="$tmpdir/umbrella.keys" \
  HOLBUILD_DUMP_KEYS_TOOLCHAIN_KEY=root-stability-v1 \
  "$HOLBUILD_BIN" build AardvarkTheory) > "$tmpdir/umbrella.log"
grep -v 'AardvarkScript.sml' "$tmpdir/umbrella.keys" > "$tmpdir/umbrella-common.keys"
if ! cmp -s "$tmpdir/root.keys" "$tmpdir/umbrella-common.keys"; then
  echo "selected roots changed common action keys for signature companions" >&2
  diff -u "$tmpdir/root.keys" "$tmpdir/umbrella-common.keys" >&2 || true
  exit 1
fi
