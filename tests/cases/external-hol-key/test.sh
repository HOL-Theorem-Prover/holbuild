#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

unused_real_holdir=$HOLDIR

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
export HOLBUILD_CACHE="$tmpdir/cache"

fake_holdir=$tmpdir/fake-hol
mkdir -p "$fake_holdir/bin" "$fake_holdir/sigobj" "$fake_holdir/src/ext/.hol/objs"
printf 'fake hol executable\n' > "$fake_holdir/bin/hol"
printf 'fake hol state\n' > "$fake_holdir/bin/hol.state"
printf 'fake hol state0\n' > "$fake_holdir/bin/hol.state0"
chmod +x "$fake_holdir/bin/hol"

cat > "$fake_holdir/src/ext/ExtLib.sml" <<'SML'
val _ = load "ExtDepTheory";
fun ext_value () = 1;
SML
printf 'ext-lib-artifact-v1\n' > "$fake_holdir/src/ext/.hol/objs/ExtLib.uo"
ln -s "$fake_holdir/src/ext/.hol/objs/ExtLib.uo" "$fake_holdir/sigobj/ExtLib.uo"
printf 'ext-dep-theory-artifact-v1\n' > "$fake_holdir/src/ext/.hol/objs/ExtDepTheory.uo"
printf 'ext-dep-dat-v1\n' > "$fake_holdir/src/ext/.hol/objs/ExtDepTheory.dat"
printf 'ext-dep-cachekey-v1\n' > "$fake_holdir/src/ext/.hol/objs/ExtDepTheory.cachekey"
ln -s "$fake_holdir/src/ext/.hol/objs/ExtDepTheory.uo" "$fake_holdir/sigobj/ExtDepTheory.uo"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "external-key-test"

[build]
members = ["src"]

[actions.BTheory]
loads = ["ExtLib"]
TOML
cat > "$project/src/BScript.sml" <<'SML'
(* [bare] *)
open HolKernel Parse boolLib;
val _ = load "ExtLib";
val _ = new_theory "B";
val _ = export_theory();
SML

input_key_for() {
  local target=$1
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$fake_holdir" build --dry-run "$target") |
    awk '/input_key:/ {key=$2} END {print key}'
}

ext_key_v1=$(input_key_for ExtLib)
printf 'changed source\n' >> "$fake_holdir/src/ext/ExtLib.sml"
ext_key_v2=$(input_key_for ExtLib)
if [[ "$ext_key_v1" == "$ext_key_v2" ]]; then
  echo "implicit HOL source package key ignored source edit" >&2
  exit 1
fi

b_key_v1=$(input_key_for BTheory)
printf 'changed source again\n' >> "$fake_holdir/src/ext/ExtLib.sml"
b_key_v2=$(input_key_for BTheory)
if [[ "$b_key_v1" == "$b_key_v2" ]]; then
  echo "dependent key ignored implicit HOL source dependency edit" >&2
  exit 1
fi

printf 'changed theory compiled object bytes\n' > "$fake_holdir/src/ext/.hol/objs/ExtDepTheory.uo"
b_key_after_artifact_change=$(input_key_for BTheory)
if [[ "$b_key_after_artifact_change" != "$b_key_v2" ]]; then
  echo "source-mode implicit HOL key should not hash prebuilt .uo/.ui artifact bytes" >&2
  exit 1
fi
