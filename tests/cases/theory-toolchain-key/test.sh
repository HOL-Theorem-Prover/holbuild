#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Two builds of one HOL recipe under different cache roots give different
# binaries and heaps, as real HOL builds do; theory action keys must not depend
# on them. Uses the fake HOL toolchain from lib.sh.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
project=$tmpdir/project
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
# Like a real HOL build, embed the install path and a per-build value in the
# executable, the heap and sigobj/Systeml.uo.
cat >> "$hol/bin/build" <<'SH'
printf '# built in %s by %s\n' "$(pwd)" "$$" >> bin/hol
printf '%s %s\n' "$(pwd)" "$$" >> bin/hol.state
printf '%s/sigobj/Systeml.sml\n' "$(pwd)" > sigobj/Systeml.uo
SH
hol_rev=$(init_git_repo "$hol")
write_fake_poly "$fakebin"
# An analyser that reports a load of the toolchain's Systeml for every file.
cat > "$fakebin/polyc" <<'SH'
#!/usr/bin/env sh
set -eu
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ]
cat > "$out" <<'ANALYSER'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = --version ]; then
  printf 'holbuild-hol-analyser holbuild-hol-analyser-v2\n'
  exit 0
fi
request=
response=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) request=$2; shift 2 ;;
    --response) response=$2; shift 2 ;;
    *) shift ;;
  esac
done
{
  printf 'version 1\nok\n'
  awk '$1 == "file" { print "begin-file " $2; print "load Systeml"; print "end-file " $2 }' "$request"
  printf 'end\n'
} > "$response"
ANALYSER
chmod +x "$out"
SH
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "theory-toolchain-key-test"

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML

unset HOLDIR HOLBUILD_HOLDIR HOLBUILD_REMOTE_CACHE_URL
export HOLBUILD_CANONICAL_HOL_GIT=$hol
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count

builds() { wc -l < "$build_count" | tr -d ' '; }

holdir_for_root() {
  (cd "$project" && HOLBUILD_CACHE=$1 "$HOLBUILD_BIN" buildhol "${@:2}") > "$tmpdir/buildhol.log" 2>&1 ||
    { cat "$tmpdir/buildhol.log" >&2; exit 1; }
  tail -n 1 "$tmpdir/buildhol.log"
}

theory_toolchain_key() {
  awk -F= '$1 == "key" {print $2}' "$(dirname "$1")/theory-toolchain"
}

input_key_for_root() {
  (cd "$project" && HOLBUILD_CACHE=$1 "$HOLBUILD_BIN" build "${@:2}" --dry-run ATheory) > "$tmpdir/dry-run.log" 2>&1 ||
    { cat "$tmpdir/dry-run.log" >&2; exit 1; }
  awk '/input_key:/ {print $2; exit}' "$tmpdir/dry-run.log"
}

root_a=$tmpdir/a
root_b=$tmpdir/cache-root-with-a-longer-path-b
holdir_a=$(holdir_for_root "$root_a")
holdir_b=$(holdir_for_root "$root_b")
if [[ "$(builds)" != 2 ]]; then
  echo "expected one toolchain build per cache root, got $(builds)" >&2
  exit 1
fi
if cmp -s "$holdir_a/bin/hol.state" "$holdir_b/bin/hol.state" ||
   cmp -s "$holdir_a/sigobj/Systeml.uo" "$holdir_b/sigobj/Systeml.uo"; then
  echo "fake toolchain builds did not differ; the test would prove nothing" >&2
  exit 1
fi

key_a=$(theory_toolchain_key "$holdir_a")
key_b=$(theory_toolchain_key "$holdir_b")
if [[ ! "$key_a" =~ ^[0-9a-f]{40}$ || "$key_a" != "$key_b" ]]; then
  echo "theory toolchain keys differ across cache roots: '$key_a' vs '$key_b'" >&2
  exit 1
fi

input_a=$(input_key_for_root "$root_a")
input_b=$(input_key_for_root "$root_b")
if [[ -z "$input_a" || "$input_a" != "$input_b" ]]; then
  echo "ATheory input keys differ across cache roots: '$input_a' vs '$input_b'" >&2
  exit 1
fi

# An entry from before the identity existed gets it from its checkout, after
# the build has added outputs to the tree, and it must agree with the identity
# taken right after the fetch.
rm "$(dirname "$holdir_a")/theory-toolchain"
if [[ "$(input_key_for_root "$root_a")" != "$input_a" ]]; then
  echo "theory toolchain identity recovered for an existing entry differs" >&2
  exit 1
fi
if [[ "$(theory_toolchain_key "$holdir_a")" != "$key_a" ]]; then
  echo "recovered theory toolchain file differs from the original" >&2
  exit 1
fi
if [[ "$(builds)" != 2 ]]; then
  echo "recovering the theory toolchain identity rebuilt the toolchain" >&2
  exit 1
fi

# A tracing kernel's theory actions also publish .tr.gz traces, which are
# Poly/ML exports, so there the keys follow the exact toolchain build.
holdir_for_root "$root_a" --trknl > /dev/null
holdir_for_root "$root_b" --trknl > /dev/null
if [[ "$(input_key_for_root "$root_a" --trknl)" == "$(input_key_for_root "$root_b" --trknl)" ]]; then
  echo "tracing-kernel ATheory input keys agree across different toolchain builds" >&2
  exit 1
fi

# A different HOL source gives a different identity, and so different keys.
printf '(* changed *)\n' >> "$hol/src/runtime/Runtime.sml"
git -C "$hol" commit -qam change
sed -i "s/^rev = .*/rev = \"$(git -C "$hol" rev-parse HEAD)\"/" "$project/holproject.toml"
holdir_c=$(holdir_for_root "$root_a")
if [[ "$(theory_toolchain_key "$holdir_c")" == "$key_a" ]]; then
  echo "theory toolchain key did not change with the HOL source" >&2
  exit 1
fi
if [[ "$(input_key_for_root "$root_a")" == "$input_a" ]]; then
  echo "ATheory input key did not change with the HOL source" >&2
  exit 1
fi

# The recovery reads the legacy entry's git checkout only; an entry whose tree
# is not a git checkout is rebuilt from source instead.
key_c=$(theory_toolchain_key "$holdir_c")
input_c=$(input_key_for_root "$root_a")
rm "$(dirname "$holdir_c")/theory-toolchain"
rm -rf "$holdir_c/.git"
builds_before=$(builds)
if [[ "$(input_key_for_root "$root_a")" != "$input_c" ]]; then
  echo "rebuilt legacy entry gives a different ATheory input key" >&2
  exit 1
fi
if [[ "$(builds)" != $((builds_before + 1)) ]]; then
  echo "legacy entry without a git checkout was not rebuilt" >&2
  exit 1
fi
if [[ "$(theory_toolchain_key "$holdir_c")" != "$key_c" ]]; then
  echo "rebuilt legacy entry has a different theory toolchain identity" >&2
  exit 1
fi
