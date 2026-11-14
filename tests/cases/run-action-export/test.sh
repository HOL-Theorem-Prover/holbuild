#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() {
  touch "$tmpdir/control/action-get-release" 2>/dev/null || true
  if [[ -n "${mutation_pid:-}" ]]; then
    kill "$mutation_pid" 2>/dev/null || true
    wait "$mutation_pid" 2>/dev/null || true
  fi
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
unset HOLBUILD_REMOTE_CACHE_URL

remote_root=$tmpdir/remote
control=$tmpdir/control
start_remote_cache_server "$remote_root" "$tmpdir/server" "$control" 2> "$tmpdir/server.err"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src" "$project/testdata"
printf 'input\n' > "$project/testdata/value.txt"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "spec"

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
cat > "$project/src/helperLib.sml" <<'SML'
structure helperLib = struct val helper_value = 1 end
SML
# Make repeated export hashing observable through the external hasher.
python3 - "$project/src/helperLib.sml" <<'PY'
import pathlib, sys
with pathlib.Path(sys.argv[1]).open("a") as out:
    out.write("(*" + " " * 70000 + "*)\n")
PY
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A
Libs helperLib

Theorem b_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors B

fun holbuild_extra_deps (_ : string list) = ()
val _ = holbuild_extra_deps ["../testdata"]

Theorem c_thm:
  T
Proof
  simp[]
QED
SML

runner=$tmpdir/runner
mkdir -p "$runner/data"
echo 'val _ = print "run\n";' > "$runner/run.sml"
echo conf > "$runner/data/conf.txt"
echo outside > "$tmpdir/outside.txt"

hb() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@")
}
run_export() {
  hb run-action --export-only --script "$runner/run.sml" "$@"
}

wait_for_availability() {
  local name=$1 status=0 child='still running'
  for _ in {1..1000}; do
    # Concurrent GETs truncate and rewrite the count. Its existence is
    # persistent and already means a request reached the gate.
    [[ -e "$control/action-get-count" ]] && return 0
    kill -0 "$mutation_pid" 2>/dev/null || break
    sleep 0.01
  done
  if ! kill -0 "$mutation_pid" 2>/dev/null; then
    wait "$mutation_pid" || status=$?
    mutation_pid=
    child="exited with status $status"
  fi
  echo "$name export never reached availability check (child $child)" >&2
  if kill -0 "$server_pid" 2>/dev/null; then
    echo 'remote cache server still running' >&2
  else
    echo 'remote cache server exited' >&2
  fi
  tail -n 40 "$tmpdir/$name.out" "$tmpdir/$name.err" "$tmpdir/server.err" "$request_log" >&2 || true
  return 1
}

# A delayed arrival remains observable even during a counter rewrite.
(
  sleep 0.05
  : > "$control/action-get-count"
  while [[ ! -e "$control/action-get-release" ]]; do sleep 0.01; done
) > "$tmpdir/wait-delayed.out" 2> "$tmpdir/wait-delayed.err" &
mutation_pid=$!
wait_for_availability wait-delayed
[[ ! -s "$control/action-get-count" ]]
touch "$control/action-get-release"
wait "$mutation_pid"
mutation_pid=
rm "$control/action-get-count" "$control/action-get-release"

# An exporter that dies before arrival reports its status and stderr.
(echo 'controlled export failure' >&2; exit 7) \
  > "$tmpdir/wait-failed.out" 2> "$tmpdir/wait-failed.err" &
mutation_pid=$!
if wait_for_availability wait-failed > "$tmpdir/wait-failed.log" 2>&1; then
  echo 'availability wait accepted a failed child' >&2
  exit 1
fi
require_grep 'child exited with status 7' "$tmpdir/wait-failed.log"
require_grep 'controlled export failure' "$tmpdir/wait-failed.log"

# The ActionSpec of C while nothing is built, for its context lines.
hb action-spec CTheory > "$tmpdir/batch.txt"
c_action_spec=$(awk '$1 == "action" && $5 == "spec:CTheory" { print $4 }' "$tmpdir/batch.txt")
[[ -n "$c_action_spec" ]] || { cat "$tmpdir/batch.txt" >&2; exit 1; }
cp "$project/.holbuild/action-specs/$c_action_spec" "$tmpdir/c-action-spec"

# Without --export-only, a run needs a coordinator: runs never execute here.
if hb run-action --script "$runner/run.sml" --output o spec:CTheory > "$tmpdir/no-export.out" 2> "$tmpdir/no-export.err"; then
  echo "run-action without --export-only or --remote-exec succeeded" >&2
  exit 1
fi
require_grep 'pass --remote-exec URL' "$tmpdir/no-export.err"
require_grep 'usage: holbuild run-action' "$tmpdir/no-export.err"
hb run-action --help > "$tmpdir/help.out"
require_grep 'run-action --export-only --script S' "$tmpdir/help.out"
"$HOLBUILD_BIN" --help | grep -q '^  run-action '

# Support files must lie under the script's directory.
if run_export --support "$tmpdir/outside.txt" --output o hol:bool > /dev/null 2> "$tmpdir/outside.err"; then
  echo "a support file outside the script's directory was accepted" >&2
  exit 1
fi
require_grep "is not under the script's directory" "$tmpdir/outside.err"

# A support file is named as given, a symbolic link included, and contained
# by that name.
ln -s conf.txt "$runner/data/alias.txt"
ln -s ../outside.txt "$runner/outer.txt"
run_export --support "$runner/data/alias.txt" --support "$runner/outer.txt" --output o hol:bool > "$tmpdir/links.txt"
links_spec=$project/.holbuild/run-specs/$(awk '{ print $3 }' "$tmpdir/links.txt")
grep -q '^file support data/alias.txt ' "$links_spec"
grep -q '^file support outer.txt ' "$links_spec"
sed -n '/^run-text$/,$p' "$links_spec" | grep -q '^support=data/alias.txt@'
if run_export --support "$runner/../outside.txt" --output o hol:bool > /dev/null 2>&1; then
  echo "a support file reached through .. was accepted" >&2
  exit 1
fi

# An unbuilt context is refused, while the others are still exported.
if run_export --output o spec:CTheory hol:bool > "$tmpdir/unbuilt.out" 2> "$tmpdir/unbuilt.err"; then
  echo "an unbuilt context was exported" >&2
  exit 1
fi
require_grep 'spec:CTheory is not in the local or remote cache for its current inputs; build it first' "$tmpdir/unbuilt.err"
grep -q '^HOL:boolTheory ' "$tmpdir/unbuilt.out"
if grep -q '^spec:CTheory ' "$tmpdir/unbuilt.out"; then
  echo "the unbuilt context was printed" >&2
  exit 1
fi

hb build --skip-proof-steps CTheory > /dev/null
metadata=$project/.holbuild/dep/spec/src/CScript.sml.key
require_grep '^proof_timeout=none$' "$metadata"
hb build --dry-run CTheory > "$tmpdir/plan.txt"
plan_key() {
  awk -v want="$1" '/^[^ ]/ { name = $1 } $1 == "input_key:" && name == want { print $2 }' "$tmpdir/plan.txt"
}
key_c=$(plan_key CTheory)
key_helper=$(plan_key helperLib)
[[ -n "$key_c" && -n "$key_helper" ]] || { cat "$tmpdir/plan.txt" >&2; exit 1; }
require_grep "^input_key=$key_c$" "$metadata"

run_export --support "$runner/data/conf.txt" --load helperLib --load bossLib \
  --output result --output manifest --option timeout=60 spec:CTheory hol:arithmetic \
  > "$tmpdir/export1.txt"
require_grep '^proof_timeout=none$' "$metadata"

# Checks the export's specs: each is in the remote CAS under its hash, with
# every file it names; its run text hashes to its run key, and is the one
# expected.  Prints "<context> <run_key>" per line.
check_export() {
  python3 - "$project" "$remote_root/cas" "$tmpdir/c-action-spec" "$1" "$key_c" "$key_helper" "$runner" <<'PY'
import hashlib, pathlib, sys
project, cas, c_action, export, key_c, key_helper, runner = map(pathlib.Path, sys.argv[1:])
key_c, key_helper = str(key_c), str(key_helper)
sha = lambda data: hashlib.sha256(data).hexdigest()
context_prefixes = ("toolchain ", "dep theory ", "lib ", "file library ", "load ")
action_head, action_text = c_action.read_bytes().split(b"\naction-text\n", 1)
action_lines = action_head.decode().splitlines()
toolchain_key = [l for l in action_text.decode().splitlines() if l.startswith("toolchain=")][0]
script_sha = sha((runner / "run.sml").read_bytes())
conf_sha = sha((runner / "data/conf.txt").read_bytes())
lines = export.read_text().splitlines()
for line in lines:
    context, run_key, spec_sha = line.split()
    data = (cas / spec_sha).read_bytes()
    assert sha(data) == spec_sha, line
    assert data == (project / ".holbuild/run-specs" / spec_sha).read_bytes(), line
    head, run_text = data.split(b"\nrun-text\n", 1)
    head = head.decode().splitlines()
    assert head[0] == "holbuild-run-spec-v1", head[0]
    assert sha(run_text) == run_key, context
    assert f"run-key={run_key}" in head, context
    for l in head:
        if l.startswith("file "):
            assert (cas / l.split()[3]).exists(), (context, l)
        if l.startswith("script "):
            assert l.split()[1] == script_sha, l
            assert (cas / script_sha).exists(), context
    if context == "spec:CTheory":
        expected = ["holbuild-run-v1", toolchain_key, f"context=spec:CTheory@{key_c}",
                    "context-input-layout=package-v1",
                    f"script={script_sha}", f"support=data/conf.txt@{conf_sha}",
                    f"load=spec:helperLib@{key_helper}", "load=bossLib",
                    "output=manifest", "output=result"]
        assert run_text.decode() == "\n".join(expected) + "\n", run_text
        ctx = [l for l in head if l.startswith(context_prefixes)]
        assert ctx == [l for l in action_lines if l.startswith(context_prefixes)], (ctx, action_lines)
        assert any(l.startswith("context spec:CTheory ") and l.endswith(" " + key_c) for l in head), head
        scripts = sorted(l.split()[2] for l in head if l.startswith("file context-script "))
        assert scripts == [f".holbuild/action-src/spec/src/{t}Script.sml" for t in "ABC"], scripts
        assert ["run-load spec:helperLib", "run-load HOLLIB:bossLib"] == \
            [l for l in head if l.startswith("run-load ")], head
        assert ["output manifest", "output result"] == [l for l in head if l.startswith("output ")], head
        assert "file support data/conf.txt " + conf_sha + " 5" in head, head
    elif context == "HOL:arithmeticTheory":
        assert "context HOL:arithmeticTheory" in head, head
        assert run_text.decode().splitlines()[2] == "context=HOL:arithmeticTheory", run_text
        assert not any(l.startswith(("dep theory ", "file context-script ")) for l in head), head
    else:
        raise AssertionError(line)
    print(context, run_key)
PY
}
check_export "$tmpdir/export1.txt" > "$tmpdir/keys1.txt"
[[ $(wc -l < "$tmpdir/keys1.txt") -eq 2 ]] || { cat "$tmpdir/keys1.txt" >&2; exit 1; }
grep -q 'option timeout=60' "$project/.holbuild/run-specs/$(awk '$1 == "spec:CTheory" { print $3 }' "$tmpdir/export1.txt")"

key_of() { awk -v want="$1" '$1 == want { print $2 }' "$2"; }
c_run_key=$(key_of spec:CTheory "$tmpdir/keys1.txt")

# Input-free project contexts keep the complete pre-staging run text.
run_export --output result spec:ATheory > "$tmpdir/no-inputs.txt"
python3 - "$project/.holbuild/run-specs/$(awk '{print $3}' "$tmpdir/no-inputs.txt")" <<'PY'
import pathlib, sys
head, text = pathlib.Path(sys.argv[1]).read_text().split("\nrun-text\n", 1)
context = next(line.split() for line in head.splitlines() if line.startswith("context "))
script = next(line.split()[1] for line in head.splitlines() if line.startswith("script "))
expected = ["holbuild-run-v1", text.splitlines()[1],
            f"context={context[1]}@{context[3]}", f"script={script}", "output=result"]
assert text == "\n".join(expected) + "\n", text
PY

# The timeout is no part of the key.
run_export --support "$runner/data/conf.txt" --load helperLib --load bossLib \
  --output result --output manifest --option timeout=7200 spec:CTheory > "$tmpdir/export2.txt"
[[ $(key_of spec:CTheory "$tmpdir/export2.txt") == "$c_run_key" ]]
[[ $(awk '{ print $3 }' "$tmpdir/export2.txt") != $(awk '$1 == "spec:CTheory" { print $3 }' "$tmpdir/export1.txt") ]]

# Fetch-only computes identities without export-only library hashes. An
# export hashes the shared library once across all contexts and uploads.
real_sha256sum=$(command -v sha256sum)
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/sha256sum" <<SH
#!/bin/sh
if [ "\$#" = 1 ] && [ "\$1" = "$project/src/helperLib.sml" ]; then
  echo hash >> "$tmpdir/library-hashes"
fi
exec "$real_sha256sum" "\$@"
SH
chmod +x "$tmpdir/bin/sha256sum"
: > "$tmpdir/library-hashes"
PATH="$tmpdir/bin:$PATH" hb run-action --fetch-only --closure \
  --script "$runner/run.sml" --load helperLib --output result \
  --outputs-dir "$tmpdir/fetched" spec:CTheory spec:BTheory spec:CTheory spec:ATheory \
  > "$tmpdir/fetch.txt"
[[ ! -s "$tmpdir/library-hashes" ]] || { echo 'fetch-only hashed export libraries' >&2; exit 1; }
awk '{print $1}' "$tmpdir/fetch.txt" > "$tmpdir/order.txt"
printf '%s\n' spec:CTheory spec:BTheory spec:ATheory > "$tmpdir/expected-order.txt"
cmp "$tmpdir/expected-order.txt" "$tmpdir/order.txt"
PATH="$tmpdir/bin:$PATH" run_export --closure --load helperLib --output result \
  spec:CTheory spec:BTheory spec:CTheory spec:ATheory > "$tmpdir/shared.txt"
[[ $(wc -l < "$tmpdir/library-hashes") -eq 1 ]] || {
  echo 'shared library was hashed more than once during export' >&2; exit 1;
}
awk '{print $1}' "$tmpdir/shared.txt" > "$tmpdir/order.txt"
cmp "$tmpdir/expected-order.txt" "$tmpdir/order.txt"

# A renamed output is a different run.
run_export --support "$runner/data/conf.txt" --load helperLib --load bossLib \
  --output result --output status spec:CTheory > "$tmpdir/export3.txt"
[[ $(key_of spec:CTheory "$tmpdir/export3.txt") != "$c_run_key" ]]

# So is a run in a changed context.
cat >> "$project/src/CScript.sml" <<'SML'

Theorem c_thm2:
  T
Proof
  simp[]
QED
SML
hb build CTheory > /dev/null
run_export --support "$runner/data/conf.txt" --load helperLib --load bossLib \
  --output result --output manifest spec:CTheory > "$tmpdir/export4.txt"
[[ $(key_of spec:CTheory "$tmpdir/export4.txt") != "$c_run_key" ]]

# hol:* is every theory of the toolchain.
hb run-action --export-only --script "$runner/run.sml" \
  --output o 'hol:*' > "$tmpdir/all.txt"
grep -q '^HOL:boolTheory ' "$tmpdir/all.txt"
grep -q '^HOL:arithmeticTheory ' "$tmpdir/all.txt"
if grep -q '^HOL:Theory ' "$tmpdir/all.txt"; then
  echo "hol:* took the Theory structure for a theory" >&2
  exit 1
fi

# A library of the hol package is fixed by the toolchain, so its load line
# carries no key; the spec ships its sources like a project library's, and
# restores the hol package theories it needs, which must be built first.
if run_export --load sortingSyntax --output o hol:bool > /dev/null 2> "$tmpdir/sorting-unbuilt.err"; then
  echo "a load whose theory isn't built was exported" >&2
  exit 1
fi
require_grep 'HOL:boolTheory needs hol:sortingTheory, which is not in the local or remote cache' "$tmpdir/sorting-unbuilt.err"
hb build sortingTheory > /dev/null
run_export --load sortingSyntax --output o hol:bool > "$tmpdir/sorting.txt"
sorting_spec=$project/.holbuild/run-specs/$(awk '{ print $3 }' "$tmpdir/sorting.txt")
sed -n '/^run-text$/,$p' "$sorting_spec" | grep -qx 'load=sortingSyntax'
grep -qx 'run-load hol:sortingSyntax' "$sorting_spec"
grep -q '^lib hol:sortingSyntax .* \.uo ' "$sorting_spec"
grep -q '^file library \.holbuild/action-src/hol/src/sort/sortingSyntax\.sml ' "$sorting_spec"
grep -q '^dep theory hol:sortingTheory ' "$sorting_spec"
grep -q '^file context-script \.holbuild/action-src/hol/src/sort/sortingScript\.sml ' "$sorting_spec"

# Proof-only options name the caller's mistake, not the implicit plain policy.
for option in --tactic-timeout=5 --proof-scope=all --new-ir; do
  if run_export "$option" --output o hol:bool > /dev/null 2> "$tmpdir/proof-option.err"; then
    echo "run-action accepted $option" >&2
    exit 1
  fi
  require_grep 'run-action does not check proof steps' "$tmpdir/proof-option.err"
done

# Declared runtime files must still have the contents used by the plan.
touch "$control/action-get-enable"
(cd "$project" && exec "$HOLBUILD_BIN" --remote-cache "$remote_url" \
  run-action --export-only --script "$runner/run.sml" --output input-mutation spec:CTheory) \
  > "$tmpdir/input-mutation.out" 2> "$tmpdir/input-mutation.err" &
mutation_pid=$!
wait_for_availability input-mutation
printf 'other\n' > "$project/testdata/value.txt"
touch "$control/action-get-release"
if wait "$mutation_pid"; then
  echo 'export accepted a runtime input changed after planning' >&2
  exit 1
fi
mutation_pid=
require_grep 'extra input changed since the build was planned' "$tmpdir/input-mutation.err"
printf 'input\n' > "$project/testdata/value.txt"
rm "$control/action-get-enable" "$control/action-get-release" "$control/action-get-count"

# A same-size edit with restored mtime between planning and spec writing
# must still be rejected. Gate the availability lookup after planning.
touch "$control/action-get-enable"
(cd "$project" && exec "$HOLBUILD_BIN" --remote-cache "$remote_url" \
  run-action --export-only --script "$runner/run.sml" --output mutation spec:CTheory) \
  > "$tmpdir/mutation.out" 2> "$tmpdir/mutation.err" &
mutation_pid=$!
wait_for_availability mutation
python3 - "$project/src/AScript.sml" <<'PY'
import os, pathlib, sys
path = pathlib.Path(sys.argv[1])
before = path.stat()
data = path.read_bytes()
changed = data.replace(b"a_thm", b"z_thm")
assert changed != data and len(changed) == len(data)
path.write_bytes(changed)
os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
PY
touch "$control/action-get-release"
if wait "$mutation_pid"; then
  echo 'export accepted a context script changed after planning' >&2
  exit 1
fi
mutation_pid=
require_grep 'theory script changed since the build was planned' "$tmpdir/mutation.err"

# Fetched metadata names cannot be declared script outputs.
if run_export --output LOG hol:bool > /dev/null 2> "$tmpdir/log-output.err"; then
  echo 'run-action accepted reserved output LOG' >&2
  exit 1
fi
require_grep 'KEY, CONTEXT and LOG are not output names' "$tmpdir/log-output.err"
