#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 HOL_REV" >&2
  exit 2
fi

rev=$1
git_url=${HOLBUILD_CANONICAL_HOL_GIT:-https://github.com/HOL-Theorem-Prover/HOL.git}
poly=${HOLBUILD_POLY:-poly}
poly_version=$("$poly" -v | awk '{$1=$1; print}')

{
  printf 'holbuild-hol-toolchain-v1\n'
  printf 'git=%s\n' "$git_url"
  printf 'rev=%s\n' "$rev"
  printf 'poly=%s\n' "$poly"
  printf 'poly_version=%s\n' "$poly_version"
  printf 'build_args=\n'
} | sha1sum | awk '{print $1}'
