#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

source_cache=$tmpdir/source-cache
link_hol_toolchain_cache "$source_cache"

project=$tmpdir/project
mkdir -p "$project/src"
{ write_schema2_prelude; cat <<TOML
[project]
name = "capsule"
version = "1.2.3"

[build]
members = ["src"]
TOML
} > "$project/holproject.toml"
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

run_in() {
  local dir=$1 cache=$2
  shift 2
  (cd "$dir" && HOLBUILD_CACHE="$cache" "$HOLBUILD_BIN" "$@")
}

expect_failure() {
  local name=$1 pattern=$2
  shift 2
  if "$@" > "$tmpdir/$name.log" 2>&1; then
    echo "$name: command succeeded but should have failed" >&2
    exit 1
  fi
  require_grep "$pattern" "$tmpdir/$name.log"
}

tree() { (cd "$1" && find . | LC_ALL=C sort); }

archives=$tmpdir/archives
mkdir -p "$archives"
run_in "$project" "$source_cache" build --tactic-timeout 0 ATheory > "$tmpdir/build.log" 2>&1
run_in "$project" "$source_cache" export -o "$archives/capsule.hbx" ATheory > "$tmpdir/export.log" 2>&1
run_in "$project" "$source_cache" export --closure -o "$archives/closure.hbx" ATheory >> "$tmpdir/export.log" 2>&1
run_in "$project" "$source_cache" export --sources-only -o "$archives/sources.hbx" >> "$tmpdir/export.log" 2>&1

# Archives with one extra member, built by hand: the hostile ones carry it
# inside the source snapshot, where a plain extraction would write it.
cat > "$tmpdir/make-archive.py" <<'PY'
import io
import sys
import tarfile

base, out, kind = sys.argv[1:]
locked = {"lockedsource": "holbuild-package/source", "lockedcache": "holbuild-cache"}
with tarfile.open(base) as src, tarfile.open(out, "w", format=tarfile.PAX_FORMAT) as dst:
    for member in src.getmembers():
        if member.name == locked.get(kind):
            member.mode = 0
        dst.addfile(member, src.extractfile(member) if member.isfile() else None)
    if kind in locked:
        sys.exit(0)
    extra = tarfile.TarInfo()
    extra.mode = 0o644
    prefix = "holbuild-package/source/"
    if kind == "dotdot":
        extra.name = prefix + "../escape.txt"
    elif kind == "absolute":
        extra.name = "/tmp/holbuild-absolute-escape.txt"
    elif kind == "decoy":
        extra.name = "decoy/" + prefix + "decoy.txt"
    elif kind == "symlink":
        extra.name = prefix + "link"
        extra.type = tarfile.SYMTYPE
        extra.linkname = "/etc/passwd"
    elif kind == "hardlink":
        extra.name = prefix + "hard"
        extra.type = tarfile.LNKTYPE
        extra.linkname = "holbuild-package/source/holproject.toml"
    elif kind == "device":
        extra.name = prefix + "dev"
        extra.type = tarfile.CHRTYPE
        extra.devmajor, extra.devminor = 1, 3
    elif kind == "fifo":
        extra.name = prefix + "pipe"
        extra.type = tarfile.FIFOTYPE
    else:
        raise SystemExit("unknown kind " + kind)
    if extra.type == tarfile.REGTYPE:
        extra.size = 1
        dst.addfile(extra, io.BytesIO(b"x"))
    else:
        dst.addfile(extra)
PY
for kind in dotdot absolute symlink hardlink device fifo decoy lockedsource lockedcache; do
  python3 -I "$tmpdir/make-archive.py" "$archives/capsule.hbx" "$archives/$kind.hbx" "$kind"
done

# Import reads the cache part only: the tar it runs never names the source
# snapshot, and the working directory and the archive's directory stay as
# they were.
real_tar=$(command -v tar)
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/tar" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$tmpdir/tar-calls.log"
exec "$real_tar" "\$@"
SH
chmod +x "$tmpdir/bin/tar"

import_into() {
  local name=$1 archive=$2 cache=$3
  : > "$tmpdir/tar-calls.log"
  mkdir -p "$tmpdir/work-$name"
  tree "$tmpdir/work-$name" > "$tmpdir/work-$name.before"
  tree "$archives" > "$tmpdir/archives-$name.before"
  (cd "$tmpdir/work-$name" && PATH="$tmpdir/bin:$PATH" HOLBUILD_CACHE="$cache" \
     "$HOLBUILD_BIN" import "$archive") > "$tmpdir/import-$name.log" 2>&1 || {
    cat "$tmpdir/import-$name.log" >&2
    exit 1
  }
  tree "$tmpdir/work-$name" | diff -u "$tmpdir/work-$name.before" -
  tree "$archives" | diff -u "$tmpdir/archives-$name.before" -
  if grep -q 'holbuild-package/source' "$tmpdir/tar-calls.log"; then
    echo "import of $name named the source snapshot to tar:" >&2
    cat "$tmpdir/tar-calls.log" >&2
    exit 1
  fi
}

import_cache=$tmpdir/import-cache
link_hol_toolchain_cache "$import_cache"
import_into capsule "$archives/capsule.hbx" "$import_cache"
require_grep "imported 1 cache action(s) from" "$tmpdir/import-capsule.log"
require_grep 'holbuild-cache' "$tmpdir/tar-calls.log"

# The imported entry restores the theory offline.
rm -rf "$project/.holbuild/obj" "$project/.holbuild/checkpoints"
run_in "$project" "$import_cache" --offline build --tactic-timeout 0 ATheory > "$tmpdir/restore.log" 2>&1
require_grep "ATheory restored" "$tmpdir/restore.log"

import_into closure "$archives/closure.hbx" "$tmpdir/import-closure-cache"
require_grep "imported 1 cache action(s) from" "$tmpdir/import-closure.log"

# A capsule without a cache part imports nothing, and that is no error.
import_into sources "$archives/sources.hbx" "$tmpdir/import-sources-cache"
require_grep "imported 0 cache action(s) from" "$tmpdir/import-sources.log"

# Hostile members fail the import too, naming the member.
member_pattern() {
  case $1 in
    dotdot) echo 'unsafe tar member.*source/\.\./escape\.txt.*\.\.' ;;
    absolute) echo 'unsafe tar member.*/tmp/holbuild-absolute-escape\.txt.*absolute path' ;;
    symlink) echo 'unsafe tar member.*source/link.*symbolic link' ;;
    hardlink) echo 'unsafe tar member.*source/hard.*hard link' ;;
    device) echo 'unsafe tar member.*source/dev.*device' ;;
    fifo) echo 'unsafe tar member.*source/pipe.*FIFO' ;;
  esac
}
for kind in dotdot absolute symlink hardlink device fifo; do
  mkdir -p "$tmpdir/work-$kind"
  tree "$tmpdir/work-$kind" > "$tmpdir/work-$kind.before"
  tree "$archives" > "$tmpdir/archives-$kind.before"
  expect_failure "import-$kind" "$(member_pattern "$kind")" \
    env -C "$tmpdir/work-$kind" HOLBUILD_CACHE="$tmpdir/import-$kind-cache" \
      "$HOLBUILD_BIN" import "$archives/$kind.hbx"
  tree "$tmpdir/work-$kind" | diff -u "$tmpdir/work-$kind.before" -
  tree "$archives" | diff -u "$tmpdir/archives-$kind.before" -
done

# A directory without owner access must not outlive the failure: the cache
# part unreadable fails the import, and the staging tree is still removed.
mkdir -p "$tmpdir/work-lockedcache"
tree "$tmpdir/work-lockedcache" > "$tmpdir/work-lockedcache.before"
tree "$archives" > "$tmpdir/archives-lockedcache.before"
expect_failure import-lockedcache "could not read cache archive manifest" \
  env -C "$tmpdir/work-lockedcache" HOLBUILD_CACHE="$tmpdir/import-lockedcache-cache" \
    "$HOLBUILD_BIN" import "$archives/lockedcache.hbx"
tree "$tmpdir/work-lockedcache" | diff -u "$tmpdir/work-lockedcache.before" -
tree "$archives" | diff -u "$tmpdir/archives-lockedcache.before" -

# extract_sources, called directly: the module is internal.
cat > "$tmpdir/extract-test.sml" <<'SML'
fun env name =
  case OS.Process.getEnv name of
      SOME value => value
    | NONE => raise Fail (name ^ " not set");
val _ = OS.FileSys.chDir (env "HOLBUILD_ROOT");
use "sml/holbuild-script.sml";

val archives = env "ARCHIVES";
val work = env "WORK";
fun extract name destination =
  let
    val {name = package, version, toolchain_key} =
      HolbuildCacheArchive.extract_sources
        {archive_path = archives ^ "/" ^ name ^ ".hbx", destination = work ^ "/" ^ destination}
  in
    print ("ok " ^ name ^ " " ^ package ^ " " ^ Option.getOpt (version, "-") ^ " " ^
           Int.toString (size toolchain_key) ^ "\n")
  end
  handle HolbuildCacheArchive.Error msg => print ("error " ^ name ^ ": " ^ msg ^ "\n");
val _ = OS.FileSys.mkDir (work ^ "/empty");
val _ = OS.FileSys.mkDir (work ^ "/populated");
val _ = TextIO.closeOut (TextIO.openOut (work ^ "/populated/keep"));
val _ = extract "capsule" "fresh";
val _ = extract "sources" "sources-only";
val _ = extract "decoy" "decoy";
val _ = extract "capsule" "empty";
val _ = extract "capsule" "populated";
val _ = extract "capsule" "nested/parent/fresh";
val _ = extract "closure" "closure";
val _ = List.app (fn kind => extract kind kind)
  ["dotdot", "absolute", "symlink", "hardlink", "device", "fifo"];
val _ = extract "lockedsource" "lockedsource";
val _ = print "== done\n";
SML
work=$tmpdir/extract
mkdir -p "$work"
tree "$archives" > "$tmpdir/archives.before"
ARCHIVES=$archives WORK=$work "${HOLBUILD_POLY:-poly}" -q --error-exit \
  < "$tmpdir/extract-test.sml" > "$tmpdir/extract.log" 2>&1 || {
  cat "$tmpdir/extract.log" >&2
  exit 1
}
require_grep '^== done$' "$tmpdir/extract.log"

# The snapshot, and only the snapshot, lands in the destination.
expected_files=$(cd "$project" && find holproject.toml src -type f | LC_ALL=C sort)
for dest in fresh sources-only decoy empty nested/parent/fresh; do
  actual_files=$(cd "$work/$dest" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
  if [[ "$actual_files" != "$expected_files" ]]; then
    echo "extracted $dest holds unexpected files:" >&2
    echo "$actual_files" >&2
    exit 1
  fi
  cmp "$work/$dest/holproject.toml" "$project/holproject.toml"
  cmp "$work/$dest/src/AScript.sml" "$project/src/AScript.sml"
done
require_grep '^ok capsule capsule 1\.2\.3 64$' "$tmpdir/extract.log"
require_grep '^ok sources capsule 1\.2\.3 64$' "$tmpdir/extract.log"
require_grep '^ok decoy capsule 1\.2\.3 64$' "$tmpdir/extract.log"

# A populated destination is never written into, and a closure archive has no
# source snapshot.
require_grep "^error capsule: capsule source destination is not empty: $work/populated\$" "$tmpdir/extract.log"
[[ $(tree "$work/populated") == $'.\n./keep' ]] || { echo "populated destination changed" >&2; exit 1; }
require_grep "^error closure: archive has no source snapshot: " "$tmpdir/extract.log"
require_no_file "$work/closure"

# Each hostile archive fails naming the member, and leaves nothing behind: no
# destination, no temporary directory, nothing written beside the archive.
for kind in dotdot absolute symlink hardlink device fifo; do
  require_grep "^error $kind: $(member_pattern "$kind")" "$tmpdir/extract.log"
  require_no_file "$work/$kind"
done
require_grep "^error lockedsource: could not install capsule source at " "$tmpdir/extract.log"
require_no_file "$work/lockedsource"
require_no_file /tmp/holbuild-absolute-escape.txt
require_no_file "$work/escape.txt"
tree "$archives" | diff -u "$tmpdir/archives.before" -
if find "$work" -name '.*' | grep -q .; then
  echo "extraction left a temporary directory beside a destination" >&2
  find "$work" -name '.*' >&2
  exit 1
fi

echo "hbx-capsule-import ok"
