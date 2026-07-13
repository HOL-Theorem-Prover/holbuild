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
vendor=$root/vendor/hol
files=$vendor/FILES
[[ -f $files ]] || { echo "missing $files" >&2; exit 1; }

# Build a complete replacement beside the live tree.  In particular, do not
# let a compatibility-patch failure leave a mixture of old and new files.
tmpdir=$(mktemp -d "$root/vendor/.update-vendored-hol.XXXXXX")
stage=$tmpdir/hol
backup=
mkdir -p "$stage"
cleanup() {
  # Once the live tree has been moved aside, EXIT can be reached from a signal
  # between either publish rename.  Put the old tree back unless the staged
  # tree was already installed; in the latter case it is safe to discard it.
  if [[ -n $backup && -d $backup ]]; then
    if [[ ! -e $vendor ]]; then
      mv "$backup" "$vendor" ||
        echo "could not restore vendored HOL tree from $backup" >&2
    else
      rm -rf "$backup"
    fi
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n $source_checkout ]]; then
  hol=$source_checkout
  [[ -d $hol/.git ]] || { echo "--from path is not a git checkout: $hol" >&2; exit 1; }
  git -C "$hol" cat-file -e "$rev^{commit}" 2>/dev/null || {
    echo "HOL checkout $hol does not contain commit $rev" >&2
    exit 1
  }
else
  hol=$tmpdir/HOL
  git clone --filter=blob:none https://github.com/HOL-Theorem-Prover/HOL.git "$hol"
  git -C "$hol" fetch --quiet origin "$rev"
fi

cp "$files" "$stage/FILES"
while IFS= read -r rel || [[ -n $rel ]]; do
  [[ -z $rel || $rel = \#* ]] && continue
  case $rel in
    /*|*../*)
      echo "unsafe vendored HOL path in $files: $rel" >&2
      exit 1
      ;;
  esac
  mkdir -p "$(dirname "$stage/$rel")"
  git -C "$hol" show "$rev:$rel" > "$stage/$rel.tmp"
  mv "$stage/$rel.tmp" "$stage/$rel"
done < "$files"

# HOL's Redblackmap refers to Portable.itlist, but the vendored compilation
# unit deliberately does not load Portable.  Keep the compatibility change in
# this refresh path so a subsequent update is reproducible rather than silently
# restoring an unbuildable upstream file.
redblackmap=src/portableML/Redblackmap.sml
grep -Fxq "$redblackmap" "$files" || {
  echo "missing required vendored compatibility file: $redblackmap" >&2
  exit 1
}
python3 - "$stage/$redblackmap" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = '''    fun insertList (m, pairs) =
        Portable.itlist (fn (k,x) => fn m' =>
                            insertWith (fn (x,y) => y) (m', k, x)) pairs m
'''
new = '''    fun insertList (m, pairs) =
        List.foldr
          (fn ((k,x), m') => insertWith (fn (x,y) => y) (m', k, x))
          m
          pairs
'''
text = path.read_text()
if text.count(old) != 1:
    raise SystemExit(f"could not apply Redblackmap compatibility patch to {path}")
path.write_text(text.replace(old, new))
PY

# Keep the checked-in whitespace normalization too.  This is deliberately an
# exact patch: if HOL changes this portion, a refresh must be updated rather
# than silently producing a vendor tree that differs from the checked-in form.
binaryset=tools-poly/poly/Binaryset.sml
grep -Fxq "$binaryset" "$files" || {
  echo "missing required vendored formatting file: $binaryset" >&2
  exit 1
}
python3 - "$stage/$binaryset" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = '''\t   if wt n1 < n2 then T'(v2, concat t1 l2, r2)
\t   else if wt n2 < n1 then T'(v1, l1, concat r1 t2)
  \t   else T'(min t2,t1, delmin t2)
'''
new = '''           if wt n1 < n2 then T'(v2, concat t1 l2, r2)
           else if wt n2 < n1 then T'(v1, l1, concat r1 t2)
           else T'(min t2,t1, delmin t2)
'''
text = path.read_text()
if text.count(old) != 1:
    raise SystemExit(f"could not apply Binaryset formatting patch to {path}")
path.write_text(text.replace(old, new))
PY

printf '%s\n' "$rev" > "$stage/REV"

# Both directories are under vendor/, so these renames stay on one filesystem.
# Every fetch and exact compatibility patch has succeeded before the live tree
# is replaced.  Restore it if publishing the replacement itself fails.
backup=$(mktemp -d "$root/vendor/.update-vendored-hol-backup.XXXXXX")
rmdir "$backup"
mv "$vendor" "$backup"
if mv "$stage" "$vendor"; then
  rm -rf "$backup"
  backup=
else
  mv "$backup" "$vendor"
  backup=
  echo "could not publish refreshed vendored HOL tree" >&2
  exit 1
fi

echo "updated vendored HOL files to $rev"
