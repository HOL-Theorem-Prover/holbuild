#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

"$HOLBUILD_BIN" --version > "$tmpdir/version.log"
holbuild_version=$(awk '/^holbuild / { print $2; exit }' "$tmpdir/version.log")
[[ "$holbuild_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid holbuild version: $holbuild_version" >&2; exit 1; }
require_grep "^holbuild $holbuild_version$" "$tmpdir/version.log"

make_project() {
  local name=$1
  mkdir -p "$tmpdir/$name/src"
}

write_manifest() {
  local name=$1
  shift
  {
    write_schema2_prelude
    cat <<TOML
[project]
name = "$name"
TOML
    cat
  } > "$tmpdir/$name/holproject.toml"
}

expect_context_failure() {
  local project=$1
  local pattern=$2
  local log=$tmpdir/$project.log
  if (cd "$tmpdir/$project" && "$HOLBUILD_BIN" context) > "$log" 2>&1; then
    echo "manifest unexpectedly accepted: $project" >&2
    exit 1
  fi
  require_grep "$pattern" "$log"
}

make_project valid
write_manifest valid <<'TOML'

[build]
members = ["src"]
roots = ["src/MainScript.sml"]
TOML
(cd "$tmpdir/valid" && "$HOLBUILD_BIN" context) > "$tmpdir/valid.log"
require_grep "name: valid" "$tmpdir/valid.log"
require_grep "roots: src/MainScript.sml" "$tmpdir/valid.log"

make_project schema1_rejected
cat > "$tmpdir/schema1_rejected/holproject.toml" <<'TOML'
[holbuild]
schema = 1

[project]
name = "schema1_rejected"
TOML
expect_context_failure schema1_rejected "only holproject schema 2 is supported"

make_project missing_schema_rejected
cat > "$tmpdir/missing_schema_rejected/holproject.toml" <<'TOML'
[project]
name = "missing_schema_rejected"
TOML
expect_context_failure missing_schema_rejected "holproject.toml must declare \[holbuild\] schema = 2"

schema2_repo=$tmpdir/schema2-repo
mkdir -p "$schema2_repo"
{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "hol"
TOML
} > "$schema2_repo/holproject.toml"
schema2_rev=$(init_git_repo "$schema2_repo")
export HOLBUILD_CANONICAL_HOL_GIT="$schema2_repo"

make_project valid_schema2_git
cat > "$tmpdir/valid_schema2_git/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "valid_schema2_git"

[dependencies.hol]
git = "$schema2_repo"
rev = "$schema2_rev"
TOML
(cd "$tmpdir/valid_schema2_git" && "$HOLBUILD_BIN" context) > "$tmpdir/valid_schema2_git.log"
require_grep "dependency: hol \[git=$schema2_repo, rev=$schema2_rev" "$tmpdir/valid_schema2_git.log"

make_project valid_schema2_from
cat > "$tmpdir/valid_schema2_from/holexamples.manifest.toml" <<'TOML'
[holbuild]
schema = 2

[project]
name = "holexamples"
TOML
cat > "$tmpdir/valid_schema2_from/holproject.toml" <<TOML
[holbuild]
schema = 2

[project]
name = "valid_schema2_from"

[dependencies.hol]
git = "$schema2_repo"
rev = "$schema2_rev"

[dependencies.holexamples]
from = "hol"
path = "."
manifest = "holexamples.manifest.toml"
TOML
(cd "$tmpdir/valid_schema2_from" && "$HOLBUILD_BIN" context) > "$tmpdir/valid_schema2_from.log"
require_grep "dependency: holexamples \[from=hol, path=., manifest=holexamples.manifest.toml" "$tmpdir/valid_schema2_from.log"

for case in unknown_top typo_build bad_exclude_type bad_exclude_globs_type bad_exclude_trailing_slash bad_exclude_dot bad_roots_type bad_root_timeout absolute_member parent_exclude no_paths_includes bad_type bad_project_name bad_action_field bad_action_type bad_action_deps_type bad_action_loads_type bad_action_abs_input bad_action_abs_dep bad_generate_field bad_generate_command_type bad_generate_abs_output; do
  make_project "$case"
done

write_manifest unknown_top <<'TOML'

[mystery]
value = "nope"
TOML
expect_context_failure unknown_top "unknown field in holproject.toml: mystery"

write_manifest typo_build <<'TOML'

[build]
member = ["src"]
TOML
expect_context_failure typo_build "unknown field in build: member"

write_manifest bad_exclude_type <<'TOML'

[build]
exclude = "selftest.sml"
TOML
expect_context_failure bad_exclude_type "exclude must be a string array"

write_manifest bad_exclude_globs_type <<'TOML'

[build]
exclude_globs = "selftest.sml"
TOML
expect_context_failure bad_exclude_globs_type "exclude_globs must be a string array"

write_manifest bad_exclude_trailing_slash <<'TOML'

[build]
exclude = ["src/generated/"]
TOML
expect_context_failure bad_exclude_trailing_slash "build.exclude must not have a trailing slash: src/generated/"

write_manifest bad_exclude_dot <<'TOML'

[build]
exclude = ["src/./generated"]
TOML
expect_context_failure bad_exclude_dot "build.exclude must not contain . components: src/./generated"

write_manifest bad_roots_type <<'TOML'

[build]
roots = "MainTheory"
TOML
expect_context_failure bad_roots_type "roots must be a string array"

write_manifest bad_root_timeout <<'TOML'

[build]
roots = ["src/MainScript.sml"]

[build.root_tactic_timeouts]
"src/OtherScript.sml" = 10
TOML
expect_context_failure bad_root_timeout "build.root_tactic_timeouts references unknown root: src/OtherScript.sml"

write_manifest absolute_member <<'TOML'

[build]
members = ["/tmp/src"]
TOML
expect_context_failure absolute_member "build.members must be package-root-relative: /tmp/src"

write_manifest parent_exclude <<'TOML'

[build]
exclude = ["../generated/*"]
TOML
expect_context_failure parent_exclude "build.exclude must be package-root-relative: ../generated/\*"

write_manifest no_paths_includes <<'TOML'

[paths]
includes = ["src"]
TOML
expect_context_failure no_paths_includes "unknown field in holproject.toml: paths"

cat > "$tmpdir/bad_type/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = 123
TOML
expect_context_failure bad_type "name must be a string"

cat > "$tmpdir/bad_project_name/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "../bad"
TOML
expect_context_failure bad_project_name "project.name must be a safe dependency name"

make_project bad_dependency
write_manifest bad_dependency <<'TOML'

[dependencies.dep]
git = "https://example.com/dep.git"
rev = "abcdef"
branch = "main"
TOML
expect_context_failure bad_dependency "unknown field in dependencies.dep: branch"

make_project minimum_version_current
cat > "$tmpdir/minimum_version_current/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "$holbuild_version"

[dependencies.hol]
git = "$schema2_repo"
rev = "$schema2_rev"

[project]
name = "minimum_version_current"
TOML
(cd "$tmpdir/minimum_version_current" && "$HOLBUILD_BIN" context) > "$tmpdir/minimum_version_current.log"

make_project required_version_current
cat > "$tmpdir/required_version_current/holproject.toml" <<TOML
[holbuild]
schema = 2
required_version = "$holbuild_version"

[dependencies.hol]
git = "$schema2_repo"
rev = "$schema2_rev"

[project]
name = "required_version_current"
TOML
(cd "$tmpdir/required_version_current" && "$HOLBUILD_BIN" context) > "$tmpdir/required_version_current.log"

future_holbuild_version=999.0.0
make_project minimum_version_future
cat > "$tmpdir/minimum_version_future/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "$future_holbuild_version"

[dependencies.hol]
git = "$schema2_repo"
rev = "$schema2_rev"

[project]
name = "minimum_version_future"
TOML
expect_context_failure minimum_version_future "project requires holbuild >= $future_holbuild_version, but this is holbuild $holbuild_version"

make_project required_version_future
cat > "$tmpdir/required_version_future/holproject.toml" <<TOML
[holbuild]
schema = 2
required_version = "$future_holbuild_version"

[dependencies.hol]
git = "$schema2_repo"
rev = "$schema2_rev"

[project]
name = "required_version_future"
TOML
expect_context_failure required_version_future "project requires holbuild >= $future_holbuild_version, but this is holbuild $holbuild_version"

make_project minimum_version_invalid
cat > "$tmpdir/minimum_version_invalid/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = ">=0.2"

[dependencies.hol]
git = "$schema2_repo"
rev = "$schema2_rev"

[project]
name = "minimum_version_invalid"
TOML
expect_context_failure minimum_version_invalid "invalid holbuild.minimum_version: expected MAJOR.MINOR.PATCH, got '>=0.2'"

make_project required_version_invalid
cat > "$tmpdir/required_version_invalid/holproject.toml" <<TOML
[holbuild]
schema = 2
required_version = ">=0.2"

[dependencies.hol]
git = "$schema2_repo"
rev = "$schema2_rev"

[project]
name = "required_version_invalid"
TOML
expect_context_failure required_version_invalid "invalid holbuild.required_version: expected MAJOR.MINOR.PATCH, got '>=0.2'"

make_project required_version_both_set
cat > "$tmpdir/required_version_both_set/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "$holbuild_version"
required_version = "$holbuild_version"

[dependencies.hol]
git = "$schema2_repo"
rev = "$schema2_rev"

[project]
name = "required_version_both_set"
TOML
expect_context_failure required_version_both_set "holbuild.minimum_version and holbuild.required_version may not both be set"

make_project schema2_missing_rev
write_manifest schema2_missing_rev <<'TOML'

[dependencies.dep]
git = "https://example.com/dep.git"
TOML
expect_context_failure schema2_missing_rev "dependencies.dep with git requires rev"

make_project schema2_path_dep
write_manifest schema2_path_dep <<'TOML'

[dependencies.dep]
path = "../dep"
TOML
expect_context_failure schema2_path_dep "dependencies.dep path dependencies are not supported"

make_project schema2_git_manifest
write_manifest schema2_git_manifest <<'TOML'

[dependencies.dep]
git = "https://example.com/dep.git"
rev = "abcdef"
manifest = "dep.manifest.toml"
TOML
expect_context_failure schema2_git_manifest "dependencies.dep git dependency may only contain git and rev"

make_project schema2_hol_override
write_manifest schema2_hol_override <<'TOML'
TOML
cat > "$tmpdir/schema2_hol_override/.holconfig.toml" <<'TOML'
[overrides.hol]
path = "../hol"
TOML
expect_context_failure schema2_hol_override "dependencies.hol cannot be overridden"

write_manifest bad_action_field <<'TOML'

[actions.FooTheory]
extra_input = ["foo.dat"]
TOML
expect_context_failure bad_action_field "unknown field in actions.FooTheory: extra_input"

write_manifest bad_action_type <<'TOML'

[actions.FooTheory]
cache = "no"
TOML
expect_context_failure bad_action_type "cache must be a boolean"

write_manifest bad_action_deps_type <<'TOML'

[actions.FooTheory]
deps = "Foo"
TOML
expect_context_failure bad_action_deps_type "deps must be a string array"

write_manifest bad_action_loads_type <<'TOML'

[actions.FooTheory]
loads = "FooLib"
TOML
expect_context_failure bad_action_loads_type "loads must be a string array"

write_manifest bad_action_abs_input <<'TOML'

[actions.FooTheory]
extra_inputs = ["/tmp/generated.dat"]
TOML
expect_context_failure bad_action_abs_input "extra_inputs must be package-root-relative"

write_manifest bad_action_abs_dep <<'TOML'

[actions.FooTheory]
extra_deps = ["/tmp/generated.dat"]
TOML
expect_context_failure bad_action_abs_dep "extra_deps must be package-root-relative"

write_manifest bad_generate_field <<'TOML'

[[generate]]
name = "gen"
command = ["python3", "gen.py"]
outputs = ["gen/AScript.sml"]
extra = true
TOML
expect_context_failure bad_generate_field "unknown field in generate: extra"

write_manifest bad_generate_command_type <<'TOML'

[[generate]]
name = "gen"
command = "python3 gen.py"
outputs = ["gen/AScript.sml"]
TOML
expect_context_failure bad_generate_command_type "generate.gen.command must be a string array"

write_manifest bad_generate_abs_output <<'TOML'

[[generate]]
name = "gen"
command = ["python3", "gen.py"]
outputs = ["/tmp/AScript.sml"]
TOML
expect_context_failure bad_generate_abs_output "generate.gen.outputs must be package-root-relative"

make_project bad_local_build
write_manifest bad_local_build <<'TOML'
TOML
cat > "$tmpdir/bad_local_build/.holconfig.toml" <<'TOML'
[build]
members = ["local"]
TOML
expect_context_failure bad_local_build "unknown field in .holconfig.toml build: members"

make_project bad_local_jobs_type
write_manifest bad_local_jobs_type <<'TOML'
TOML
cat > "$tmpdir/bad_local_jobs_type/.holconfig.toml" <<'TOML'
[build]
jobs = "many"
TOML
expect_context_failure bad_local_jobs_type "jobs must be an integer"

make_project bad_local_jobs_value
write_manifest bad_local_jobs_value <<'TOML'
TOML
cat > "$tmpdir/bad_local_jobs_value/.holconfig.toml" <<'TOML'
[build]
jobs = 0
TOML
expect_context_failure bad_local_jobs_value ".holconfig.toml build.jobs must be a positive integer"

make_project bad_local_remote_cache_field
write_manifest bad_local_remote_cache_field <<'TOML'
TOML
cat > "$tmpdir/bad_local_remote_cache_field/.holconfig.toml" <<'TOML'
[remote_cache]
endpoint = "https://cache.example.org"
TOML
expect_context_failure bad_local_remote_cache_field "unknown field in .holconfig.toml remote_cache: endpoint"

make_project bad_local_remote_cache_url_type
write_manifest bad_local_remote_cache_url_type <<'TOML'
TOML
cat > "$tmpdir/bad_local_remote_cache_url_type/.holconfig.toml" <<'TOML'
[remote_cache]
url = 7
TOML
expect_context_failure bad_local_remote_cache_url_type "url must be a string"
