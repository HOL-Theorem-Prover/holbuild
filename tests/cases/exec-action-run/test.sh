#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Export runs with run-action --export-only, then run them as a worker would,
# with only the remote cache as input: exec-action runs the script in the
# context's root and publishes its declared outputs as one kind=run entry.

tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
unset HOLBUILD_REMOTE_CACHE_URL

remote_root=$tmpdir/remote
start_remote_cache_server "$remote_root" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "run"

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
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors A

Theorem c_thm:
  T
Proof
  ACCEPT_TAC a_thm
QED
SML
cat > "$project/src/helperLib.sml" <<'SML'
structure helperLib = struct val helper_value = 42 end
SML

runner=$tmpdir/runner
mkdir -p "$runner/data"
echo conf > "$runner/data/conf.txt"
# Writes what it was given to its two outputs.
cat > "$runner/run.sml" <<'SML'
fun env name = valOf (OS.Process.getEnv name);
fun write name text =
  let val out = TextIO.openOut (OS.Path.concat (env "HOLBUILD_RUN_OUTPUT_DIR", name))
  in TextIO.output (out, text); TextIO.closeOut out end;
val _ = load "CTheory";
val conf = let val i = TextIO.openIn "data/conf.txt" in TextIO.inputAll i before TextIO.closeIn i end;
val scratch = OS.FileSys.isDir (env "HOLBUILD_RUN_SCRATCH");
val _ = write "first"
  (String.concatWith "\n"
     [env "HOLBUILD_RUN_CONTEXT", env "HOLBUILD_RUN_CONTEXT_KEY", env "HOLBUILD_RUN_SOURCE",
      env "HOLBUILD_RUN_ROOT", Bool.toString scratch] ^ "\n");
val _ = write "second"
  (conf ^ Int.toString helperLib.helper_value ^ "\n" ^ Int.toString (length (Thm.hyp CTheory.c_thm)) ^ "\n");
SML
cat > "$runner/hol.sml" <<'SML'
fun env name = valOf (OS.Process.getEnv name);
fun write name text =
  let val out = TextIO.openOut (OS.Path.concat (env "HOLBUILD_RUN_OUTPUT_DIR", name))
  in TextIO.output (out, text); TextIO.closeOut out end;
val _ = write "first"
  (String.concatWith "\n" [env "HOLBUILD_RUN_CONTEXT", env "HOLBUILD_RUN_CONTEXT_KEY", env "HOLBUILD_RUN_SOURCE"] ^ "\n");
val _ = write "second" (Int.toString (length (Thm.hyp boolTheory.TRUTH)) ^ "\n");
SML
echo 'val _ = raise Fail "boom";' > "$runner/raise.sml"
cat > "$runner/one.sml" <<'SML'
val out = TextIO.openOut (OS.Path.concat (valOf (OS.Process.getEnv "HOLBUILD_RUN_OUTPUT_DIR"), "first"));
val _ = (TextIO.output (out, "only\n"); TextIO.closeOut out);
SML
echo 'val _ = OS.Process.sleep (Time.fromSeconds 300);' > "$runner/sleep.sml"
cat > "$runner/fifo.sml" <<'SML'
val dir = valOf (OS.Process.getEnv "HOLBUILD_RUN_OUTPUT_DIR");
val _ = Posix.FileSys.mkfifo (OS.Path.concat (dir, "first"), Posix.FileSys.S.irwxu);
val out = TextIO.openOut (OS.Path.concat (dir, "second"));
val _ = (TextIO.output (out, "x\n"); TextIO.closeOut out);
SML

hb() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@")
}
# export SCRIPT [OPTION...] TARGET: prints "<run_key> <spec>".
export_run() {
  local script=$1
  shift
  hb run-action --export-only --script "$runner/$script" --output first --output second "$@" |
    awk '{ print $2, $3 }'
}

# worker NAME SPEC: exec-action in its own cache root and cwd, as a worker
# container would; the record goes to $tmpdir/NAME.result.
worker() {
  local name=$1 spec=$2
  local cache=$tmpdir/worker-$name
  link_hol_toolchain_cache "$cache"
  mkdir -p "$tmpdir/cwd-$name"
  set +e
  (cd "$tmpdir/cwd-$name" &&
     HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
       --cache-limit-gb 1000 --result "$tmpdir/$name.result") > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
}

# expect NAME EXIT LINE...: the worker's exit code and result lines.
expect() {
  local name=$1 code=$2
  shift 2
  if [[ "$worker_status" != "$code" ]]; then
    echo "worker $name exited $worker_status, wanted $code" >&2
    cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2 || true
    exit 1
  fi
  for line in "$@"; do
    grep -qxF -- "$line" "$tmpdir/$name.result" || {
      echo "worker $name result lacks '$line':" >&2
      cat "$tmpdir/$name.result" "$tmpdir/$name.log" >&2
      exit 1
    }
  done
}

ac_file() {
  printf '%s/ac/%s' "$remote_root" \
    "$(printf 'holbuild-remote-ac-v1\n%s\n' "$1" | sha256sum | awk '{ print $1 }')"
}
# output_blob RUN_KEY NAME: the CAS file of a run's output.
output_blob() {
  local hash
  hash=$(awk -v role="output:$2" '$1 == "blob" && $2 == role { print $3 }' "$(ac_file "$1")")
  [[ -n "$hash" ]] || { echo "no output $2 in the entry of $1" >&2; cat "$(ac_file "$1")" >&2; exit 1; }
  printf '%s/cas/%s' "$remote_root" "$hash"
}

hb build CTheory > /dev/null
hb build --dry-run CTheory > "$tmpdir/plan.txt"
key_c=$(awk '/^[^ ]/ { name = $1 } $1 == "input_key:" && name == "CTheory" { print $2 }' "$tmpdir/plan.txt")
[[ -n "$key_c" ]] || { cat "$tmpdir/plan.txt" >&2; exit 1; }

# A run in a project context: its entry names the context as its parent and
# holds both outputs, which hold what the script saw.
read -r run_key spec < <(export_run run.sml --support "$runner/data/conf.txt" --load helperLib run:CTheory)
worker run "$spec"
expect run 0 status=built "input-key=$run_key"
require_grep '^log=[0-9a-f]\{64\} [0-9]*$' "$tmpdir/run.result"
log_hash=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/run.result")
require_file "$remote_root/cas/$log_hash"
entry=$(ac_file "$run_key")
require_grep '^kind=run$' "$entry"
require_grep "^input_key=$run_key\$" "$entry"
require_grep "^parent $key_c\$" "$entry"
[[ $(grep -c '^blob output:' "$entry") -eq 2 ]] || { cat "$entry" >&2; exit 1; }
first=$(output_blob "$run_key" first)
second=$(output_blob "$run_key" second)
[[ $(sed -n 1p "$first") == run:CTheory ]] || { cat "$first" >&2; exit 1; }
[[ $(sed -n 2p "$first") == "$key_c" ]] || { cat "$first" >&2; exit 1; }
[[ $(sed -n 3p "$first") == "$tmpdir/worker-run/action/.holbuild/action-src/run/src/CScript.sml" ]] ||
  { cat "$first" >&2; exit 1; }
[[ $(sed -n 4p "$first") == "$tmpdir/worker-run/action" ]] || { cat "$first" >&2; exit 1; }
[[ $(sed -n 5p "$first") == true ]] || { cat "$first" >&2; exit 1; }
printf 'conf\n42\n0\n' | cmp - "$second"

# Run again, it is cached: no HOL, so no log.
worker run "$spec"
expect run 0 status=cached "input-key=$run_key"
if grep -q '^log=' "$tmpdir/run.result"; then
  echo "a cached run uploaded a log" >&2
  exit 1
fi

# A changed context is a new run.
cat >> "$project/src/CScript.sml" <<'SML'

Theorem c_thm2:
  T
Proof
  simp[]
QED
SML
hb build CTheory > /dev/null
read -r run_key2 spec2 < <(export_run run.sml --support "$runner/data/conf.txt" --load helperLib run:CTheory)
[[ "$run_key2" != "$run_key" ]]
worker run2 "$spec2"
expect run2 0 status=built "input-key=$run_key2"
require_file "$(ac_file "$run_key2")"

# A run in a toolchain theory's context has no parent.
read -r hol_key hol_spec < <(export_run hol.sml hol:bool)
worker hol "$hol_spec"
expect hol 0 status=built "input-key=$hol_key"
if grep -q '^parent ' "$(ac_file "$hol_key")"; then
  echo "a toolchain context's entry has a parent" >&2
  cat "$(ac_file "$hol_key")" >&2
  exit 1
fi
hol_first=$(output_blob "$hol_key" first)
[[ $(sed -n 1p "$hol_first") == HOL:boolTheory ]] || { cat "$hol_first" >&2; exit 1; }
[[ $(sed -n 3p "$hol_first") == */boolScript.sml ]] || { cat "$hol_first" >&2; exit 1; }
printf '0\n' | cmp - "$(output_blob "$hol_key" second)"

# A script that raises, or leaves an output unwritten, fails as script, a
# final failure, and nothing is cached.
for script in raise one; do
  read -r key spec < <(export_run "$script.sml" hol:bool)
  worker "$script" "$spec"
  expect "$script" 1 status=failed failure=script
  require_no_file "$(ac_file "$key")"
done
require_grep 'did not write its declared output second' "$tmpdir/one.log"

# An output that is not a regular file fails as script rather than blocking
# the worker on it.
read -r key spec < <(export_run fifo.sml hol:bool)
worker fifo "$spec"
expect fifo 1 status=failed failure=script
require_no_file "$(ac_file "$key")"

# A spec whose run-loads differ from its run text's is rejected: the run key
# covers the loads.
read -r key spec < <(export_run run.sml --support "$runner/data/conf.txt" --load helperLib run:CTheory)
grep -v '^run-load ' "$remote_root/cas/$spec" > "$tmpdir/tampered-spec"
tampered=$(sha256sum "$tmpdir/tampered-spec" | awk '{ print $1 }')
cp "$tmpdir/tampered-spec" "$remote_root/cas/$tampered"
worker tampered "$tampered"
expect tampered 4 status=failed failure=spec-rejected
require_grep 'the run-loads do not match the run text' "$tmpdir/tampered.log"

# A script past its timeout is killed with its process group.
read -r key spec < <(export_run sleep.sml --option timeout=5 hol:bool)
started=$SECONDS
( worker sleep "$spec"; echo "$worker_status" > "$tmpdir/sleep.status" ) &
sleeper=$!
# Its processes are seen while it runs, so their absence below means
# something.
for _ in {1..150}; do
  pgrep -f "$tmpdir/worker-sleep/action" > /dev/null && break
  sleep 0.1
done
pgrep -f "$tmpdir/worker-sleep/action" > /dev/null || { echo "the sleeping run was never seen" >&2; exit 1; }
wait "$sleeper"
worker_status=$(< "$tmpdir/sleep.status")
expect sleep 1 status=failed failure=timeout
(( SECONDS - started < 120 )) || { echo "the timeout took $((SECONDS - started)) s" >&2; exit 1; }
require_no_file "$(ac_file "$key")"
for _ in {1..50}; do
  pgrep -f "$tmpdir/worker-sleep/action" > /dev/null || break
  sleep 0.1
done
if pgrep -af "$tmpdir/worker-sleep/action"; then
  echo "the timed-out run left processes behind" >&2
  exit 1
fi
