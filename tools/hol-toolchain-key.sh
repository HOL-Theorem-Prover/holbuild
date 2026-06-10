#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 HOL_REV" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
poly=${HOLBUILD_POLY:-poly}
HOLBUILD_TOOLCHAIN_KEY_REV=$1 exec "$poly" --script "$script_dir/hol-toolchain-key.sml"
