#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 HOL_REV" >&2
  exit 2
fi

rev=$1
git_url=${HOLBUILD_CANONICAL_HOL_GIT:-https://github.com/HOL-Theorem-Prover/HOL.git}
poly=${HOLBUILD_POLY:-poly}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
key=$(HOLBUILD_CANONICAL_HOL_GIT="$git_url" HOLBUILD_POLY="$poly" "$script_dir/hol-toolchain-key.sh" "$rev")

if [[ -n "${HOLBUILD_CACHE:-}" ]]; then
  cache_root=$HOLBUILD_CACHE
elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
  cache_root=$XDG_CACHE_HOME/holbuild
elif [[ -n "${HOME:-}" ]]; then
  cache_root=$HOME/.cache/holbuild
else
  echo "set HOME, XDG_CACHE_HOME, or HOLBUILD_CACHE" >&2
  exit 2
fi

entry=$cache_root/hol-toolchains/$key
holdir=$entry/hol
manifest=$entry/manifest
ok=$entry/build.ok

quote() { printf "%q" "$1"; }

valid_entry() {
  [[ -f "$ok" ]] || return 1
  [[ -x "$holdir/bin/hol" ]] || return 1
  [[ -x "$holdir/bin/build" ]] || return 1
  [[ -r "$holdir/bin/hol.state" ]] || return 1
  [[ -z "$(git -C "$holdir" status --porcelain --ignored=no 2>/dev/null)" ]] || return 1
}

key_material() {
  local poly_version
  poly_version=$("$poly" -v | awk '{$1=$1; print}')
  printf 'holbuild-hol-toolchain-v1\n'
  printf 'git=%s\n' "$git_url"
  printf 'rev=%s\n' "$rev"
  printf 'poly=%s\n' "$poly"
  printf 'poly_version=%s\n' "$poly_version"
  printf 'build_args=--no-helpdocs\n'
}

if valid_entry; then
  printf 'HOLDIR=%s\n' "$holdir"
  printf 'HOLBUILD_HOL_TOOLCHAIN_KEY=%s\n' "$key"
  exit 0
fi

if [[ -e "$entry" ]]; then
  echo "removing invalid HOL toolchain cache entry: $entry" >&2
  rm -rf "$entry"
fi

mkdir -p "$entry"
echo "building HOL toolchain cache entry: $entry" >&2

git clone "$git_url" "$holdir" >&2
git -C "$holdir" checkout --detach "$rev" >&2
(cd "$holdir" && "$poly" --script tools/smart-configure.sml) >&2
(cd "$holdir" && bin/build --no-helpdocs) >&2

if ! [[ -x "$holdir/bin/hol" && -x "$holdir/bin/build" && -r "$holdir/bin/hol.state" ]]; then
  echo "HOL build did not produce bin/hol, bin/build, and bin/hol.state in $holdir" >&2
  exit 1
fi

status=$(git -C "$holdir" status --porcelain --ignored=no)
if [[ -n "$status" ]]; then
  echo "HOL build left dirty checkout: $holdir" >&2
  echo "$status" >&2
  exit 1
fi

key_material > "$manifest"
printf 'key=%s\n' "$key" >> "$manifest"
printf 'ok\n' > "$ok"

printf 'HOLDIR=%s\n' "$holdir"
printf 'HOLBUILD_HOL_TOOLCHAIN_KEY=%s\n' "$key"
