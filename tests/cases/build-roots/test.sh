#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() {
  chmod u+rwx "$tmpdir/dot/noaccess" 2>/dev/null || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "build-roots"

[build]
members = ["src"]
roots = ["src/MainScript.sml"]
TOML
cat > "$project/src/DepScript.sml" <<'SML'
Theory Dep

Theorem dep_thm:
  T
Proof
  simp[]
QED

val _ = export_theory();
SML
cat > "$project/src/MainScript.sml" <<'SML'
Theory Main
Ancestors Dep

Theorem main_thm:
  T
Proof
  simp[DepTheory.dep_thm]
QED

val _ = export_theory();
SML
cat > "$project/src/ExtraScript.sml" <<'SML'
Theory Extra

val _ = raise Fail "default build should not build ExtraTheory";

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log"
require_grep "roots: src/MainScript.sml" "$tmpdir/context.log"

missing_root=$tmpdir/missing-root
mkdir -p "$missing_root/src"
cat > "$missing_root/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "missing-root"

[build]
members = ["src/DepScript.sml"]
roots = ["src/MainScript.sml"]
TOML
cp "$project/src/DepScript.sml" "$missing_root/src/DepScript.sml"
cp "$project/src/MainScript.sml" "$missing_root/src/MainScript.sml"
if (cd "$missing_root" && "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/missing-root.log" 2>&1; then
  echo "root outside members unexpectedly succeeded" >&2
  exit 1
fi
require_grep "unknown build root: missing-root:src/MainScript.sml" "$tmpdir/missing-root.log"

(cd "$project" && "$HOLBUILD_BIN" build) > "$tmpdir/default.log" 2> "$tmpdir/default.err"
require_grep "discoverable theory script(s) are not reachable from build.roots" "$tmpdir/default.err"
require_grep "unreachable: build-roots:src/ExtraScript.sml (ExtraTheory)" "$tmpdir/default.err"
require_file "$project/.holbuild/obj/src/DepTheory.dat"
require_file "$project/.holbuild/obj/src/MainTheory.dat"
if [[ -e "$project/.holbuild/obj/src/ExtraTheory.dat" ]]; then
  echo "default build ignored build.roots and built ExtraTheory" >&2
  exit 1
fi

if (cd "$project" && "$HOLBUILD_BIN" build ExtraTheory) > "$tmpdir/extra.log" 2>&1; then
  echo "explicit ExtraTheory unexpectedly succeeded" >&2
  exit 1
fi
require_grep "default build should not build ExtraTheory" "$tmpdir/extra.log"

# If [build] exists but omits members, members still defaults to ["."].
# Source discovery should skip hidden files/directories, unreadable dirs, and symlink dirs.
dot=$tmpdir/dot
symlink_target=$tmpdir/symlink-target
mkdir -p "$dot/.hidden" "$dot/noaccess" "$symlink_target"
ln -s "$symlink_target" "$dot/linked-dir"
chmod 000 "$dot/noaccess"
cat > "$dot/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "build-roots-dot"

[build]
roots = ["MainScript.sml"]
TOML
cat > "$dot/MainScript.sml" <<'SML'
Theory Main

Theorem main_thm:
  T
Proof
  simp[]
QED

val _ = export_theory();
SML
cat > "$dot/.HiddenScript.sml" <<'SML'
this hidden file should not be parsed
SML
cat > "$dot/.hidden/BadScript.sml" <<'SML'
this hidden directory should not be scanned
SML
cat > "$symlink_target/BadScript.sml" <<'SML'
this symlink directory should not be scanned
SML

(cd "$dot" && "$HOLBUILD_BIN" build) > "$tmpdir/dot.log"
require_file "$dot/.holbuild/obj/MainTheory.dat"
