#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# build --tool-cache NAME: what a theory child leaves in HOLBUILD_TOOL_CACHE_DIR
# on one worker, failed builds included, reaches the next action with the same
# dependencies on another worker, through the remote cache alone.

tmpdir=$(make_temp_dir)
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "tools"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML

# write_t VERSION WRITES [PROOF]: T prints what its tool cache's file `seen`
# held, writes WRITES there, and proves its theorem by PROOF.  VERSION names
# the theorem, so each version is a new action on the same dependencies.
write_t() {
  cat > "$project/src/TScript.sml" <<SML
Theory T
Ancestors A

val tool_dir = valOf (OS.Process.getEnv "HOLBUILD_TOOL_CACHE_DIR");
fun tool_put name text =
  let
    val tmp = OS.Path.concat (tool_dir, name ^ ".tmp")
    val out = TextIO.openOut tmp
  in
    TextIO.output (out, text); TextIO.closeOut out;
    OS.FileSys.rename {old = tmp, new = OS.Path.concat (tool_dir, name)}
  end;
val _ =
  print ("tool cache held: " ^
         (let val input = TextIO.openIn (OS.Path.concat (tool_dir, "seen"))
          in TextIO.inputAll input before TextIO.closeIn input end
          handle IO.Io _ => "nothing") ^ "\n");
$2

Theorem t_$1:
  T
Proof
  ${3:-simp[]}
QED
SML
}

field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }

# worker NAME SPEC [HOST]: exec-action of SPEC on a fresh cache root, as on
# another host, or on HOST's; the record goes to $tmpdir/NAME.result and HOL's
# log to $tmpdir/NAME.hol.
worker() {
  local name=$1 spec=$2 cache=$tmpdir/worker-${3:-$1}
  link_hol_toolchain_cache "$cache"
  set +e
  HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
    --cache-limit-gb 1000 --result "$tmpdir/$name.result" > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
  local log_sha
  log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/$name.result")
  [[ -n "$log_sha" ]] || { echo "worker $name uploaded no log" >&2; cat "$tmpdir/$name.log" >&2; exit 1; }
  curl -fsS "$remote_url/cas/$log_sha" > "$tmpdir/$name.hol"
}

# expect NAME STATUS HELD: the worker exited STATUS and T saw HELD.
expect() {
  if [[ "$worker_status" != "$2" ]]; then
    echo "worker $1 exited $worker_status, wanted $2" >&2
    cat "$tmpdir/$1.log" "$tmpdir/$1.result" "$tmpdir/$1.hol" >&2 || true
    exit 1
  fi
  grep -qxF "tool cache held: $3" "$tmpdir/$1.hol" || {
    echo "worker $1: T did not see '$3' in its tool cache" >&2
    cat "$tmpdir/$1.hol" "$tmpdir/$1.log" >&2
    exit 1
  }
}

# export VERSION [OPTION...]: T's spec, with A built first if it isn't cached.
export_t() {
  local version=$1
  shift
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload "$@" TTheory) \
    > "$tmpdir/batch-$version.txt"
  spec_t=$(field "$tmpdir/batch-$version.txt" tools:TTheory 4)
  local spec_a
  spec_a=$(field "$tmpdir/batch-$version.txt" tools:ATheory 4)
  if [[ -n "$spec_a" ]]; then
    worker "a-$version" "$spec_a"
    [[ "$worker_status" == 0 ]] || { cat "$tmpdir/a-$version.log" >&2; exit 1; }
  fi
  [[ -n "$spec_t" ]] || { cat "$tmpdir/batch-$version.txt" >&2; exit 1; }
}

write_t v1 'val _ = tool_put "seen" "v1";'

# The option names the tool cache in the spec and changes nothing else.
export_t plain
export_t v1 --tool-cache probe
specs=$project/.holbuild/action-specs
diff "$specs/$(field "$tmpdir/batch-plain.txt" tools:TTheory 4)" "$specs/$spec_t" > "$tmpdir/spec.diff" && {
  echo "the spec does not name the tool cache" >&2; exit 1; }
[[ "$(grep -c '^[<>]' "$tmpdir/spec.diff")" == 1 ]] && grep -qx '> option tool-cache=probe' "$tmpdir/spec.diff" || {
  echo "--tool-cache changed more of the spec than its option:" >&2; cat "$tmpdir/spec.diff" >&2; exit 1; }
[[ "$(field "$tmpdir/batch-plain.txt" tools:TTheory 3)" == "$(field "$tmpdir/batch-v1.txt" tools:TTheory 3)" ]] || {
  echo "--tool-cache changed the action's input key" >&2; exit 1; }
if (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --tool-cache ../x TTheory) \
     > "$tmpdir/bad-name.log" 2>&1; then
  echo "a tool cache name with a slash was accepted" >&2; exit 1
fi
require_grep "\-\-tool-cache NAME takes letters" "$tmpdir/bad-name.log"

# The first action starts empty and publishes what it wrote.
worker v1 "$spec_t"
expect v1 0 nothing
require_grep "published tool cache (1 files)" "$tmpdir/v1.log"
# It is published under the key the README gives.
spec_file=$specs/$spec_t
tool_key=$(printf 'holbuild-tool-cache-v1\nname=probe\ndeps_key=%s\ntoolchain=%s' \
  "$(sed -n 's/^deps-key=//p' "$spec_file")" "$(sed -n 's/^toolchain=//p' "$spec_file")" | sha256sum | cut -d' ' -f1)
tool_ac=$(printf 'holbuild-remote-ac-v1\n%s\n' "$tool_key" | sha256sum | cut -d' ' -f1)
[[ -f "$tmpdir/remote/ac/$tool_ac" ]] || { echo "no tool cache entry at the documented key" >&2; exit 1; }

# Another worker restores it into its own action root.
write_t v2 'val _ = tool_put "seen" "v2";'
export_t v2 --tool-cache probe
worker v2 "$spec_t"
expect v2 0 v1
require_grep "restored tool cache (1 files)" "$tmpdir/v2.log"

# A failed build's files are published too.
write_t v3 'val _ = tool_put "seen" "v3";' 'FAIL_TAC "no proof"'
export_t v3 --tool-cache probe
worker v3 "$spec_t"
expect v3 1 v2
require_grep "published tool cache (1 files)" "$tmpdir/v3.log"

# More files than the limit are not published, and the action still builds.
write_t v4 'val _ = tool_put "seen" "v4"; val _ = List.app (fn n => tool_put ("f" ^ Int.toString n) "") (List.tabulate (16, fn n => n));'
export_t v4 --tool-cache probe
worker v4 "$spec_t"
expect v4 0 v3
require_grep "not publishing the tool cache: 17 files" "$tmpdir/v4.log"

# Files equal to the restored ones are not published again.
write_t v5 'val _ = tool_put "seen" "v3";'
export_t v5 --tool-cache probe
worker v5 "$spec_t"
expect v5 0 v3
if grep -q "published tool cache" "$tmpdir/v5.log"; then
  echo "unchanged tool cache files were published again" >&2; exit 1
fi

# A worker without the option gives HOL no tool cache.
write_t v6 'val _ = tool_put "seen" "v6";'
export_t v6
worker v6 "$spec_t"
[[ "$worker_status" != 0 ]] && ! grep -q "tool cache held" "$tmpdir/v6.hol" || {
  echo "T found a tool cache without --tool-cache" >&2; exit 1; }

# A worker keeps the files in its host store: it restores them there after
# the remote cache has lost them.
write_t v7 'val _ = tool_put "seen" "v7";'
export_t v7 --tool-cache probe
worker v7 "$spec_t"
expect v7 0 v3
v7_blob=$tmpdir/remote/cas/$(printf v7 | sha256sum | cut -d' ' -f1)
[[ -f "$v7_blob" ]] || { echo "v7's file is not in the remote cache" >&2; exit 1; }
rm "$v7_blob"
write_t v8 'val _ = tool_put "seen" "v8";'
export_t v8 --tool-cache probe
worker v8 "$spec_t" v7
expect v8 0 v7
require_grep "restored tool cache (1 files)" "$tmpdir/v8.log"
cp "$tmpdir/remote/ac/$tool_ac" "$tmpdir/entry-v8"

# A directory or a symbolic link is not published, and the entry stays as it
# was.  The sandbox may refuse the link; the directory it allows.
write_t v9 'val _ = tool_put "seen" "v9"; val _ = OS.FileSys.mkDir (OS.Path.concat (tool_dir, "sub")); val _ = Posix.FileSys.symlink {old = "seen", new = OS.Path.concat (tool_dir, "link")} handle OS.SysErr _ => ();'
export_t v9 --tool-cache probe
worker v9 "$spec_t"
expect v9 0 v8
require_grep "not publishing the tool cache: not a plain file" "$tmpdir/v9.log"
cmp -s "$tmpdir/entry-v8" "$tmpdir/remote/ac/$tool_ac" || { echo "the v9 action changed the entry" >&2; exit 1; }

# Nor are files over the size limit.
write_t v10 'val _ = tool_put "seen" "v10"; val _ = tool_put "big" (CharVector.tabulate (64 * 1024 * 1024, fn _ => #"x"));'
export_t v10 --tool-cache probe
worker v10 "$spec_t"
expect v10 0 v8
require_grep "not publishing the tool cache: 2 files of 67108867 bytes exceed" "$tmpdir/v10.log"
cmp -s "$tmpdir/entry-v8" "$tmpdir/remote/ac/$tool_ac" || { echo "the v10 action changed the entry" >&2; exit 1; }

# The option leaves checkpoint reuse alone: a worker sharing heaps resumes a
# --tool-cache build of U from the theorem context a build without it shared.
write_u() {
  cat > "$project/src/UScript.sml" <<SML
Theory U
Ancestors A

Theorem u1:
  T
Proof
  simp[]
QED

Theorem u2:
  T
Proof
  $1
QED
SML
}
shared=$tmpdir/worker-shared
share_worker() {
  local name=$1 spec=$2
  link_hol_toolchain_cache "$shared"
  rm -rf "$shared/checkpoints" "$shared/checkpoint-store"
  HOLBUILD_CACHE=$shared "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
    --cache-limit-gb 1000 --share-heaps --result "$tmpdir/$name.result" > "$tmpdir/$name.log" 2>&1 || {
    echo "worker $name failed" >&2; cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2; exit 1; }
  grep -qx "status=built" "$tmpdir/$name.result" || { cat "$tmpdir/$name.result" >&2; exit 1; }
}
write_u 'simp[]'
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload UTheory) > "$tmpdir/batch-u1.txt"
share_worker u1 "$(field "$tmpdir/batch-u1.txt" tools:UTheory 4)"
write_u 'ACCEPT_TAC TRUTH'
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload --tool-cache probe UTheory) \
  > "$tmpdir/batch-u2.txt"
share_worker u2 "$(field "$tmpdir/batch-u2.txt" tools:UTheory 4)"
require_grep "restored shared theorem_context checkpoint" "$tmpdir/u2.log"
require_grep "from: theorem-context checkpoint after u1" "$tmpdir/u2.log"
