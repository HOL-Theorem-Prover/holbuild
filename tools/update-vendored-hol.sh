#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: tools/update-vendored-hol.sh [--from PATH] REV

Refresh the vendored HOL source files from REV. If --from is supplied, PATH must
be a HOL git checkout containing REV. Otherwise a temporary clone is used.
EOF
  exit 2
}

source_checkout=
while [[ $# -gt 0 ]]; do
  case $1 in
    --from)
      [[ $# -ge 2 ]] || usage
      source_checkout=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --*)
      echo "unknown option: $1" >&2
      usage
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 1 ]] || usage
rev=$1

if [[ ! $rev =~ ^[0-9a-f]{40}$ ]]; then
  echo "HOL rev must be a full 40-character lowercase hex commit: $rev" >&2
  exit 1
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
files=$root/vendor/hol/FILES
[[ -f $files ]] || { echo "missing $files" >&2; exit 1; }

tmpdir=
cleanup() {
  [[ -z ${tmpdir:-} ]] || rm -rf "$tmpdir"
}
trap cleanup EXIT

if [[ -n $source_checkout ]]; then
  hol=$source_checkout
  [[ -d $hol/.git ]] || { echo "--from path is not a git checkout: $hol" >&2; exit 1; }
  git -C "$hol" cat-file -e "$rev^{commit}" 2>/dev/null || {
    echo "HOL checkout $hol does not contain commit $rev" >&2
    exit 1
  }
else
  tmpdir=$(mktemp -d)
  hol=$tmpdir/HOL
  git clone --filter=blob:none https://github.com/HOL-Theorem-Prover/HOL.git "$hol"
  git -C "$hol" fetch --quiet origin "$rev"
fi

while IFS= read -r rel || [[ -n $rel ]]; do
  [[ -z $rel || $rel = \#* ]] && continue
  case $rel in
    /*|*../*)
      echo "unsafe vendored HOL path in $files: $rel" >&2
      exit 1
      ;;
  esac
  mkdir -p "$(dirname "$root/vendor/hol/$rel")"
  git -C "$hol" show "$rev:$rel" > "$root/vendor/hol/$rel.tmp"
  mv "$root/vendor/hol/$rel.tmp" "$root/vendor/hol/$rel"
done < "$files"

printf '%s\n' "$rev" > "$root/vendor/hol/REV"
echo "updated vendored HOL files to $rev"
