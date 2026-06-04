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
export HOLBUILD_CACHE="$tmpdir/cache"

make_project() {
  local name=$1
  mkdir -p "$tmpdir/$name/src"
}

expect_context_failure() {
  local project=$1
  local pattern=$2
  local log=$tmpdir/$project.log
  if (cd "$tmpdir/$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$log" 2>&1; then
    echo "manifest unexpectedly accepted: $project" >&2
    exit 1
  fi
  require_grep "$pattern" "$log"
}

make_project valid
cat > "$tmpdir/valid/holproject.toml" <<'TOML'
[holbuild]
schema = 1

[project]
name = "valid"

[build]
members = ["src"]
roots = ["src/MainScript.sml"]
TOML
(cd "$tmpdir/valid" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/valid.log"
require_grep "name: valid" "$tmpdir/valid.log"
require_grep "roots: src/MainScript.sml" "$tmpdir/valid.log"

schema2_repo=$tmpdir/schema2-repo
mkdir -p "$schema2_repo"
git -C "$schema2_repo" init -q
git -C "$schema2_repo" config user.email test@example.com
git -C "$schema2_repo" config user.name 'Holbuild Test'
git -C "$schema2_repo" config commit.gpgsign false
cat > "$schema2_repo/holproject.toml" <<'TOML'
[project]
name = "hol"
TOML
git -C "$schema2_repo" add .
git -C "$schema2_repo" commit -q -m initial
schema2_rev=$(git -C "$schema2_repo" rev-parse HEAD)
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

make_project unknown_top
cat > "$tmpdir/unknown_top/holproject.toml" <<'TOML'
[project]
name = "unknown_top"

[mystery]
value = "nope"
TOML
expect_context_failure unknown_top "unknown field in holproject.toml: mystery"

make_project typo_build
cat > "$tmpdir/typo_build/holproject.toml" <<'TOML'
[project]
name = "typo_build"

[build]
member = ["src"]
TOML
expect_context_failure typo_build "unknown field in build: member"

make_project bad_exclude_type
cat > "$tmpdir/bad_exclude_type/holproject.toml" <<'TOML'
[project]
name = "bad_exclude_type"

[build]
exclude = "selftest.sml"
TOML
expect_context_failure bad_exclude_type "exclude must be a string array"

make_project bad_roots_type
cat > "$tmpdir/bad_roots_type/holproject.toml" <<'TOML'
[project]
name = "bad_roots_type"

[build]
roots = "MainTheory"
TOML
expect_context_failure bad_roots_type "roots must be a string array"

make_project bad_root_timeout
cat > "$tmpdir/bad_root_timeout/holproject.toml" <<'TOML'
[project]
name = "bad_root_timeout"

[build]
roots = ["src/MainScript.sml"]

[build.root_tactic_timeouts]
"src/OtherScript.sml" = 10
TOML
expect_context_failure bad_root_timeout "build.root_tactic_timeouts references unknown root: src/OtherScript.sml"

make_project absolute_member
cat > "$tmpdir/absolute_member/holproject.toml" <<'TOML'
[project]
name = "absolute_member"

[build]
members = ["/tmp/src"]
TOML
expect_context_failure absolute_member "build.members must be package-root-relative: /tmp/src"

make_project parent_exclude
cat > "$tmpdir/parent_exclude/holproject.toml" <<'TOML'
[project]
name = "parent_exclude"

[build]
exclude = ["../generated/*"]
TOML
expect_context_failure parent_exclude "build.exclude must be package-root-relative: ../generated/\*"

make_project no_paths_includes
cat > "$tmpdir/no_paths_includes/holproject.toml" <<'TOML'
[project]
name = "no_paths_includes"

[paths]
includes = ["src"]
TOML
expect_context_failure no_paths_includes "unknown field in holproject.toml: paths"

make_project bad_type
cat > "$tmpdir/bad_type/holproject.toml" <<'TOML'
[project]
name = 123
TOML
expect_context_failure bad_type "name must be a string"

make_project bad_dependency
cat > "$tmpdir/bad_dependency/holproject.toml" <<'TOML'
[project]
name = "bad_dependency"

[dependencies.dep]
path = "../dep"
branch = "main"
TOML
expect_context_failure bad_dependency "unknown field in dependencies.dep: branch"

make_project required_version_unimplemented
cat > "$tmpdir/required_version_unimplemented/holproject.toml" <<'TOML'
[holbuild]
schema = 2
required_version = ">=0.2"

[project]
name = "required_version_unimplemented"
TOML
expect_context_failure required_version_unimplemented "holbuild.required_version is recognized but not implemented yet"

make_project schema2_missing_rev
cat > "$tmpdir/schema2_missing_rev/holproject.toml" <<'TOML'
[holbuild]
schema = 2

[project]
name = "schema2_missing_rev"

[dependencies.dep]
git = "https://example.com/dep.git"
TOML
expect_context_failure schema2_missing_rev "dependencies.dep with git requires rev"

make_project schema2_path_dep
cat > "$tmpdir/schema2_path_dep/holproject.toml" <<'TOML'
[holbuild]
schema = 2

[project]
name = "schema2_path_dep"

[dependencies.dep]
path = "../dep"
TOML
expect_context_failure schema2_path_dep "dependencies.dep path dependencies are not supported in schema 2"

make_project schema2_git_manifest
cat > "$tmpdir/schema2_git_manifest/holproject.toml" <<'TOML'
[holbuild]
schema = 2

[project]
name = "schema2_git_manifest"

[dependencies.dep]
git = "https://example.com/dep.git"
rev = "abcdef"
manifest = "dep.manifest.toml"
TOML
expect_context_failure schema2_git_manifest "dependencies.dep git dependency may only contain git and rev"

make_project schema2_override
cat > "$tmpdir/schema2_override/holproject.toml" <<'TOML'
[holbuild]
schema = 2

[project]
name = "schema2_override"
TOML
cat > "$tmpdir/schema2_override/.holconfig.toml" <<'TOML'
[overrides.dep]
path = "../dep"
TOML
expect_context_failure schema2_override "local dependency overrides are not supported in schema 2"

make_project bad_action_field
cat > "$tmpdir/bad_action_field/holproject.toml" <<'TOML'
[project]
name = "bad_action_field"

[actions.FooTheory]
extra_input = ["foo.dat"]
TOML
expect_context_failure bad_action_field "unknown field in actions.FooTheory: extra_input"

make_project bad_action_type
cat > "$tmpdir/bad_action_type/holproject.toml" <<'TOML'
[project]
name = "bad_action_type"

[actions.FooTheory]
cache = "no"
TOML
expect_context_failure bad_action_type "cache must be a boolean"

make_project bad_action_deps_type
cat > "$tmpdir/bad_action_deps_type/holproject.toml" <<'TOML'
[project]
name = "bad_action_deps_type"

[actions.FooTheory]
deps = "Foo"
TOML
expect_context_failure bad_action_deps_type "deps must be a string array"

make_project bad_action_loads_type
cat > "$tmpdir/bad_action_loads_type/holproject.toml" <<'TOML'
[project]
name = "bad_action_loads_type"

[actions.FooTheory]
loads = "FooLib"
TOML
expect_context_failure bad_action_loads_type "loads must be a string array"

make_project bad_action_abs_input
cat > "$tmpdir/bad_action_abs_input/holproject.toml" <<'TOML'
[project]
name = "bad_action_abs_input"

[actions.FooTheory]
extra_inputs = ["/tmp/generated.dat"]
TOML
expect_context_failure bad_action_abs_input "extra_inputs must be package-root-relative"

make_project bad_action_abs_dep
cat > "$tmpdir/bad_action_abs_dep/holproject.toml" <<'TOML'
[project]
name = "bad_action_abs_dep"

[actions.FooTheory]
extra_deps = ["/tmp/generated.dat"]
TOML
expect_context_failure bad_action_abs_dep "extra_deps must be package-root-relative"

make_project bad_generate_field
cat > "$tmpdir/bad_generate_field/holproject.toml" <<'TOML'
[project]
name = "bad_generate_field"

[[generate]]
name = "gen"
command = ["python3", "gen.py"]
outputs = ["gen/AScript.sml"]
extra = true
TOML
expect_context_failure bad_generate_field "unknown field in generate: extra"

make_project bad_generate_command_type
cat > "$tmpdir/bad_generate_command_type/holproject.toml" <<'TOML'
[project]
name = "bad_generate_command_type"

[[generate]]
name = "gen"
command = "python3 gen.py"
outputs = ["gen/AScript.sml"]
TOML
expect_context_failure bad_generate_command_type "generate.gen.command must be a string array"

make_project bad_generate_abs_output
cat > "$tmpdir/bad_generate_abs_output/holproject.toml" <<'TOML'
[project]
name = "bad_generate_abs_output"

[[generate]]
name = "gen"
command = ["python3", "gen.py"]
outputs = ["/tmp/AScript.sml"]
TOML
expect_context_failure bad_generate_abs_output "generate.gen.outputs must be package-root-relative"

make_project bad_config
cat > "$tmpdir/bad_config/holproject.toml" <<'TOML'
[project]
name = "bad_config"
TOML
cat > "$tmpdir/bad_config/.holconfig.toml" <<'TOML'
[overrides.dep]
path = "../dep"
branch = "main"
TOML
expect_context_failure bad_config "unknown field in overrides.dep: branch"

make_project bad_local_build
cat > "$tmpdir/bad_local_build/holproject.toml" <<'TOML'
[project]
name = "bad_local_build"
TOML
cat > "$tmpdir/bad_local_build/.holconfig.toml" <<'TOML'
[build]
members = ["local"]
TOML
expect_context_failure bad_local_build "unknown field in .holconfig.toml build: members"

make_project bad_local_jobs_type
cat > "$tmpdir/bad_local_jobs_type/holproject.toml" <<'TOML'
[project]
name = "bad_local_jobs_type"
TOML
cat > "$tmpdir/bad_local_jobs_type/.holconfig.toml" <<'TOML'
[build]
jobs = "many"
TOML
expect_context_failure bad_local_jobs_type "jobs must be an integer"

make_project bad_local_jobs_value
cat > "$tmpdir/bad_local_jobs_value/holproject.toml" <<'TOML'
[project]
name = "bad_local_jobs_value"
TOML
cat > "$tmpdir/bad_local_jobs_value/.holconfig.toml" <<'TOML'
[build]
jobs = 0
TOML
expect_context_failure bad_local_jobs_value ".holconfig.toml build.jobs must be a positive integer"
