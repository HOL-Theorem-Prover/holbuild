#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

fixture=$tmpdir/fixture
source_checkout=$tmpdir/HOL
mkdir -p "$fixture/tools" "$fixture/vendor/hol" "$source_checkout/tools-poly/poly" "$source_checkout/src/portableML"
cp "$HOLBUILD_ROOT/tools/update-vendored-hol.sh" "$fixture/tools/"
printf '%s\n' tools-poly/poly/Binaryset.sml src/portableML/Redblackmap.sml > "$fixture/vendor/hol/FILES"

# These are the upstream forms at the two patched sites.  A minimal source git
# checkout is enough to exercise refresh without changing this checkout.
printf '%s' $'fun concat E s = s\n  | concat s E = s\n  | concat (t1 as T{elt=v1,cnt=n1,left=l1,right=r1})\n           (t2 as T{elt=v2,cnt=n2,left=l2,right=r2}) =\n\t   if wt n1 < n2 then T\'(v2, concat t1 l2, r2)\n\t   else if wt n2 < n1 then T\'(v1, l1, concat r1 t2)\n  \t   else T\'(min t2,t1, delmin t2)\n' > "$source_checkout/tools-poly/poly/Binaryset.sml"
cat > "$source_checkout/src/portableML/Redblackmap.sml" <<'SML'
    fun insertList (m, pairs) =
        Portable.itlist (fn (k,x) => fn m' =>
                            insertWith (fn (x,y) => y) (m', k, x)) pairs m
SML

git -C "$source_checkout" init -q
git -C "$source_checkout" config user.email test@example.invalid
git -C "$source_checkout" config user.name test
git -C "$source_checkout" add .
git -C "$source_checkout" commit -qm fixture
rev=$(git -C "$source_checkout" rev-parse HEAD)

"$fixture/tools/update-vendored-hol.sh" --from "$source_checkout" "$rev"
binaryset=$fixture/vendor/hol/tools-poly/poly/Binaryset.sml
if ! grep -Fxq "           if wt n1 < n2 then T'(v2, concat t1 l2, r2)" "$binaryset"; then
  echo "vendored refresh did not apply Binaryset formatting patch" >&2
  exit 1
fi
if grep -q $'\t   if wt n1' "$binaryset"; then
  echo "vendored refresh retained upstream Binaryset indentation" >&2
  exit 1
fi
first_hash=$(sha1sum "$binaryset" | awk '{print $1}')
"$fixture/tools/update-vendored-hol.sh" --from "$source_checkout" "$rev"
second_hash=$(sha1sum "$binaryset" | awk '{print $1}')
if [[ "$first_hash" != "$second_hash" ]]; then
  echo "vendored refresh is not idempotent for Binaryset" >&2
  exit 1
fi

# Interrupt immediately after the old live tree is moved to its backup.  The
# EXIT cleanup must restore it rather than leaving vendor/hol absent.
interrupt_bin=$tmpdir/interrupt-bin
mkdir "$interrupt_bin"
cat > "$interrupt_bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
/bin/mv "$@"
last=${!#}
if [[ $last == */.update-vendored-hol-backup.* ]]; then
  kill -TERM "$PPID"
fi
SH
chmod +x "$interrupt_bin/mv"
if PATH="$interrupt_bin:$PATH" "$fixture/tools/update-vendored-hol.sh" --from "$source_checkout" "$rev"; then
  echo "interrupted vendored refresh unexpectedly succeeded" >&2
  exit 1
fi
if [[ "$(cat "$fixture/vendor/hol/REV")" != "$rev" ]]; then
  echo "interrupted vendored refresh did not restore REV" >&2
  exit 1
fi
if [[ "$(sha1sum "$binaryset" | awk '{print $1}')" != "$second_hash" ]]; then
  echo "interrupted vendored refresh did not restore the live vendor tree" >&2
  exit 1
fi

# A failed exact compatibility patch must leave the prior vendor tree and REV
# intact rather than publishing files from the incompatible upstream revision.
printf 'incompatible upstream form\n' > "$source_checkout/tools-poly/poly/Binaryset.sml"
git -C "$source_checkout" add tools-poly/poly/Binaryset.sml
git -C "$source_checkout" commit -qm incompatible-fixture
bad_rev=$(git -C "$source_checkout" rev-parse HEAD)
if "$fixture/tools/update-vendored-hol.sh" --from "$source_checkout" "$bad_rev"; then
  echo "vendored refresh accepted an incompatible compatibility patch" >&2
  exit 1
fi
if [[ "$(cat "$fixture/vendor/hol/REV")" != "$rev" ]]; then
  echo "failed vendored refresh changed REV" >&2
  exit 1
fi
if [[ "$(sha1sum "$binaryset" | awk '{print $1}')" != "$second_hash" ]]; then
  echo "failed vendored refresh changed the live vendor tree" >&2
  exit 1
fi
