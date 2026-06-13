#!/usr/bin/env bash

require_file() {
  local path=$1
  [[ -f "$path" ]] || { echo "missing expected file: $path" >&2; exit 1; }
}

require_grep() {
  local pattern=$1
  local path=$2
  grep -q "$pattern" "$path" || {
    echo "missing expected pattern '$pattern' in $path" >&2
    exit 1
  }
}

make_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/holbuild-test.XXXXXX"
}

holbuild_pinned_hol_rev() {
  tr -d '[:space:]' < "${HOLBUILD_ROOT:?HOLBUILD_ROOT not set}/PINS/hol.txt"
}

write_schema2_prelude() {
  cat <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

TOML
}

init_git_repo() {
  local dir=$1
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "holbuild test"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add .
  git -C "$dir" commit -q --no-gpg-sign -m init
  git -C "$dir" rev-parse HEAD
}

link_hol_toolchain_cache() {
  local cache=$1
  mkdir -p "$cache"
  if [[ -n "${HOLBUILD_TEST_GLOBAL_CACHE:-}" && -d "$HOLBUILD_TEST_GLOBAL_CACHE/hol-toolchains" && ! -e "$cache/hol-toolchains" ]]; then
    ln -s "$HOLBUILD_TEST_GLOBAL_CACHE/hol-toolchains" "$cache/hol-toolchains"
  fi
}

use_case_cache() {
  local cache=$1
  link_hol_toolchain_cache "$cache"
  export HOLBUILD_CACHE="$cache"
}
