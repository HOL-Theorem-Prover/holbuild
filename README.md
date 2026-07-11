# holbuild

`holbuild` is a build tool for HOL4 projects. It lets a project describe its
sources, HOL revision, and dependencies in a `holproject.toml` file, then builds
logical targets such as `MyTheory` without requiring users to manage `.uo`,
`.ui`, `.dat`, or Holmake state directly.

If you know HOL and Holmake, the main difference is that `holbuild` is
project-oriented: the project manifest selects the HOL checkout to use, build
outputs live under `.holbuild/`, and dependency projects can be fetched from
exact git revisions.

## Status

`holbuild` is usable but still experimental. It currently supports schema 2
manifests only. The manifest format and CLI may still change before any future
upstreaming into HOL.

`holbuild` reserves top-level SML identifiers beginning with `Holbuild` for its
own generated code and runtime support. User project code should not define
values, structures, signatures, or functors with that prefix.

## Install from source

You need Poly/ML. The small set of HOL source files needed to compile the
`holbuild` executable is vendored under `vendor/hol`.

```sh
make
```

Check the resulting binary:

```sh
bin/holbuild --version
```

Optional install:

```sh
make install
```

Maintainers can update the pinned HOL revision and refresh the vendored HOL
source files with:

```sh
tools/update-vendored-hol.sh [--from /path/to/HOL-checkout] <40-char-HOL-commit>
```

By default this installs to:

```text
$HOME/.local/bin/holbuild
```

You can override the destination with `PREFIX`, `BINDIR`, or `DESTDIR`.

## A minimal project

Create `holproject.toml` in the root of your HOL project:

```toml
[holbuild]
schema = 2
minimum_version = "<MAJOR.MINOR.PATCH>"  # optional; required_version is accepted as an alias

[project]
name = "example"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "0123456789abcdef0123456789abcdef01234567"

[build]
members = ["src"]
roots = ["src/ExampleScript.sml"]
```

Then run:

```sh
holbuild
```

With no explicit command, `holbuild` builds the default roots. You can also build
a specific logical target:

```sh
holbuild ExampleTheory
```

The target is the logical theory/module name, not an object filename. The
explicit `build` command remains accepted, for example `holbuild build` and
`holbuild build ExampleTheory`.

To inspect how the project is resolved, run:

```sh
holbuild context
```

## How HOL is selected

A project must declare exactly one HOL dependency:

```toml
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "0123456789abcdef0123456789abcdef01234567"
```

That revision is the HOL checkout used to analyse and build the project.
`holbuild` builds or reuses it under:

```text
$HOLBUILD_CACHE/hol-toolchains/<key>/hol
```

For schema 2 projects, the shared HOL toolchain is warmed with HOL's reduced
`upto-hol` build sequence rather than a full default HOL build:

```sh
bin/build --no-helpdocs --seq=tools/sequences/upto-hol
```

This produces the standard HOL executable, `hol.state`, Holmake, and the base
`sigobj` context needed by normal project builds. Source directories that would
be reached by HOL's default build after this reduced toolchain sequence are
exposed as an implicit package named `hol` and built by holbuild on demand. The
generated implicit HOL source manifest is cached next to the shared toolchain as
`hol-source.manifest.toml` with a companion `hol-source.members` file.

While HOL issue https://github.com/HOL-Theorem-Prover/HOL/issues/2021 remains
unfixed, holbuild uses a narrow temporary parser for Holmake `--json` target
lines when generating that manifest. This is intended to be replaced by proper
JSON parsing once the pinned HOL revision provides valid Holmake JSON output.

`--cache-dir PATH` overrides the global cache location for a command.
`HOLBUILD_CACHE` defaults to the platform cache directory, normally:

```text
$HOME/.cache/holbuild
```

Project builds do not use `HOLDIR`, `HOLBUILD_HOLDIR`, or `--holdir` to select
HOL. If a command needs HOL, it uses `[dependencies.hol]` from the manifest.

To build that HOL toolchain ahead of time, for example in CI, run:

```sh
holbuild buildhol
```

### Tracing-kernel toolchains

Proof-tracing builds use HOL's tracing kernel:

```sh
HOLBUILD_POLY=/path/to/tracing-poly holbuild buildhol --trknl
HOLBUILD_POLY=/path/to/tracing-poly holbuild build --trknl MyTheory
```

`--trknl` requires a Poly/ML build that provides the tracing-kernel export
support used by HOL. CI tracks the `exportSmall` branch of
https://github.com/digama0/polyml; local users should set `HOLBUILD_POLY` to the
corresponding `poly` executable when warming or using a tracing toolchain.
Standard and tracing HOL builds have distinct toolchain identities and are
cached separately under `$HOLBUILD_CACHE/hol-toolchains/`.

A tracing build records the aggregate proof trace for each theory as
`MyTheory.tr.gz`. The trace is a normal build output: holbuild requires it for
up-to-date checks, includes it in output metadata, and publishes and restores it
through the action cache. Standard-kernel builds do not require trace outputs.
Tracing is a property of the selected bootstrapped HOL kernel; holbuild does not
pass `--trknl` to each child HOL process.

## Common commands

`build` is the default command, so it can usually be omitted:

```sh
holbuild                 # build default roots
holbuild MyTheory        # build one logical target
holbuild build MyTheory  # equivalent explicit form
```

Other useful commands:

```sh
holbuild --version
holbuild --help
holbuild repl
holbuild run script.sml
holbuild context
holbuild execution-plan MyTheory:my_theorem
holbuild buildhol
holbuild buildhol --trknl
holbuild build --trknl MyTheory
holbuild heap main
holbuild executable runtests
holbuild export -o build-output.hbx MyTheory
holbuild import build-output.hbx
holbuild clean MyTheory
holbuild gc
```

Global options go before the command, or before the target list when using the
default build command:

```sh
holbuild -j4 MyTheory
holbuild --maxheap 4096 MyTheory
holbuild --source-dir /path/to/project MyTheory
holbuild --cache-dir /path/to/cache MyTheory
holbuild --remote-cache http://cache.example.org MyTheory
holbuild --json MyTheory
```

Build-specific options follow the `build` command. If you omit `build`, put the
option before the targets:

```sh
holbuild build --force=project MyTheory
holbuild --no-cache MyTheory
holbuild --tactic-timeout 5 MyTheory
holbuild --watch MyTheory
holbuild --dry-run MyTheory
holbuild clean MyTheory && holbuild --no-cache MyTheory
```

Common global options:

- `--source-dir PATH`: project source directory. Defaults to
  `HOLBUILD_SOURCE_DIR` or the current working directory.
- `--cache-dir PATH`: global cache directory. Overrides `HOLBUILD_CACHE` and the
  platform default cache location.
- `--remote-cache URL`: optional Bazel-style HTTP remote cache endpoint. Also
  configurable with `HOLBUILD_REMOTE_CACHE_URL` or project-local
  `.holconfig.toml`.
- `--json`: emit newline-delimited JSON where supported.
- `--quiet`, `--verbose`, `--verbosity LEVEL`: adjust status output.
- `-j N`, `-jN`, `--jobs N`: build parallelism.
- `--maxheap MB`, `--max-heap MB`: Poly/ML maximum heap size for child HOL
  processes.

`holbuild build --watch MyTheory` runs an initial build, then watches project
inputs with `inotifywait` and rebuilds after changes. Watch mode currently
requires `inotifywait` from `inotify-tools` and does not support `--json`,
`--dry-run`, or `--repl-on-failure`.

`holbuild clean MyTheory` removes project-local generated artifacts, dependency
metadata, and checkpoints for the named theory target. This is primarily a
recovery/debugging command for suspect local state; normal builds should not
require it. Clean does not remove global cache entries, so use
`holbuild build --no-cache MyTheory` afterwards if you also want to avoid
restoring the target from the global cache.

`--source-dir PATH` or `HOLBUILD_SOURCE_DIR` chooses where to look for
`holproject.toml`. Build output is written under `.holbuild/` in the current
working directory.

## Manifest guide

### `[holbuild]`

```toml
[holbuild]
schema = 2
minimum_version = "<MAJOR.MINOR.PATCH>"
```

`schema = 2` is required. `minimum_version` is optional; `required_version` is
accepted as an alias for compatibility. Set only one of them. If present, it
must be a semantic version `MAJOR.MINOR.PATCH` and means "this project requires
at least this holbuild version".

### `[project]`

```toml
[project]
name = "example"
```

The project name is used when the project is consumed as a dependency.

### `[dependencies.*]`

Direct git dependencies use exact commit hashes:

```toml
[dependencies.foo]
git = "https://github.com/acme/foo"
rev = "0123456789abcdef0123456789abcdef01234567"
```

A dependency may also refer to a subdirectory of another direct dependency, using
a shim manifest:

```toml
[dependencies.keccak]
from = "hol"
path = "examples/Crypto/Keccak"
manifest = "shims/keccak.toml"
```

Current dependency limits:

- `rev` must be an exact lowercase 40-character commit hash.
- Branches, tags, version ranges, registries, solvers, lockfiles, manifest path
  dependencies, and multiple versions of one package are not supported.
- Direct git dependencies use only `git` and `rev`.
- Subtree dependencies use `from`, `path`, and `manifest`.
- `path` and `manifest` must be relative and must not contain `..`.

### `[build]`

```toml
[build]
members = ["src", "lib", "gen"]
exclude = ["src/generated", "src/OneOff.sml"]
exclude_globs = ["*/selftest.sml", "*/examples/*"]
roots = ["src/MainScript.sml"]
root_groups = ["@generated"]
tactic_timeout = 10.0

[build.groups.generated]
include = ["gen/fixtures"]
include_globs = ["gen/*Script.sml"]
exclude = ["gen/fixtures/known-broken"]
exclude_globs = ["gen/*ExperimentalScript.sml"]
allow_empty = false

[build.root_tactic_timeouts]
"src/SlowScript.sml" = 60.0
```

- `members` tells `holbuild` where to discover source files. Membership makes a
  source available as a logical target and as a dependency of other targets, but
  does not by itself make the source part of the default build.
- `exclude` removes concrete package-root-relative paths from discovery; a
  directory entry excludes its subtree, and a file entry excludes just that file.
- `exclude_globs` removes package-root-relative glob matches from discovery.
  Deprecated glob patterns in `exclude` are still accepted with a warning.
- `roots` are the default entry points when `holbuild build` is run with no
  target. Entries may be package-root-relative source paths or `@name` build
  group references. Source-path roots must name sources discovered through
  `members` and not removed by `exclude` or `exclude_globs`; the `.sml` suffix
  may be omitted. If no package in the dependency graph declares roots or root
  groups, `holbuild build` defaults to all discovered sources in the root project
  package only. Dependency packages, including the implicit `hol` package, are
  not default-built merely because they have members. Use `holbuild build
  --warn-unreachable` to report discoverable theory scripts that are outside the
  root dependency closure.
- `root_groups` adds build groups to the default build. Group names may use the
  uniform `@name` form (`"@generated"`) or the bare form (`"generated"`).
- `[build.groups.NAME]` defines a build-system-only group; `NAME` is the group
  name used by `@NAME`. `include` and
  `exclude` are concrete package-root-relative paths; a directory entry matches
  its whole subtree. `include_globs` and `exclude_globs` use the same glob
  dialect as `build.exclude_globs`: `*` and `?` only, `*` crosses `/`, no `**`,
  and no character classes. `allow_empty` is optional and defaults to `false`.
- `@name` is the group-reference syntax (`@` followed by a group name) accepted
  by `holbuild build @name`, `[build].roots`, `[build].root_groups`,
  `[[heap]].objects`, and `[[executable]].objects`. It is not accepted in
  `[actions.*].deps` or `[actions.*].loads`, which remain real dependency/load
  edges.
- A build group has phony-target semantics: it expands after generation and
  source discovery into ordinary logical targets, builds those targets only, and
  creates no aggregate HOL theory to load or export.
- `tactic_timeout` sets the default root-project proof-step timeout in seconds.
  The built-in default is `2.5`; `0` disables the timeout.
- `root_tactic_timeouts` lets individual root source files set timeout contracts
  for their dependency closures.

### Action overrides

Most source dependencies are inferred automatically. Use `[actions.NAME]` when a
logical target needs extra information:

```toml
[actions.MyTheory]
deps = ["MyProjectLib"]
loads = ["SomeExternalLib"]
extra_deps = ["data/table.txt"]
cache = false
always_reexecute = true
```

- `deps` adds logical project dependencies.
- `loads` adds modules/libraries to load before the action.
- `extra_deps` adds filesystem inputs that should be hashed into the action key.
- `cache = false` disables global cache restore/publish for the action.
- `always_reexecute = true` disables local up-to-date skipping for the action.

Source files may also declare source-file-relative extra dependencies:

```sml
val () = holbuild_extra_deps ["../data/table.txt"];
```

### Generated source

Generated HOL source can be declared with `[[generate]]` entries:

```toml
[build]
members = ["src", "gen"]

[[generate]]
name = "opcodes"
command = ["python3", "scripts/gen_opcodes.py", "data/opcodes.toml", "-o", "gen/OpcodeScript.sml"]
inputs = ["scripts/gen_opcodes.py", "data/opcodes.toml"]
outputs = ["gen/OpcodeScript.sml"]
deps = []
```

Generators run before source discovery. Declared outputs are checked and then
scanned as normal source files.

### Heaps and run contexts

```toml
[[heap]]
name = "main"
output = "build/main.heap"
objects = ["MainTheory"]

[[executable]]
name = "runtests"
output = "tests/runtests.exe"
objects = ["runtests"]
main = "main"

[run]
heap = "build/main.heap"
loads = ["MyLib"]
```

`holbuild heap main` builds the listed logical objects and uses HOL `buildheap`
to save the heap. `[[heap]].objects` may name theory and SML logical targets.
`holbuild executable runtests` builds the listed logical objects and uses HOL
`buildheap --exe=<main>` to produce an executable; `main` defaults to `"main"`
and executable objects may also include signature targets. `holbuild run` and
`holbuild repl` create a project run context under `.holbuild/` before loading
`[run].loads` and user arguments.

## Proof steps and checkpoints

By default, `holbuild` instruments modern theorem proofs and executes them as
proof steps. This gives better failure locations, per-step tactic timeouts,
failed-prefix checkpoints, and optional traces.

Useful commands and options:

```sh
holbuild execution-plan MyTheory:my_theorem
holbuild build --tactic-timeout 10 MyTheory
holbuild build --trace-steps --force MyTheory
holbuild build --repl-on-failure MyTheory
holbuild build --skip-proof-steps MyTheory
holbuild build --skip-checkpoints MyTheory
```

- `execution-plan THEORY:THEOREM` prints the proof-step plan for one theorem.
- `--tactic-timeout SECONDS` changes the per-step timeout; `0` disables it.
- `--trace-steps` records proof-step traces in child logs.
- `--repl-on-failure` starts a HOL REPL from the newest useful checkpoint after a
  theory failure. It serialises the build and is not supported with `--json`.
- `--skip-proof-steps` opts out of proof-step execution.
- `--skip-checkpoints` disables checkpoint `.save`/`.ok` creation.

For source-executed theory builds, holbuild writes a live child log at
`.holbuild/logs/current/<package>/<logical>/build.log`. You can inspect it during
a long build with `tail -f`; after the child exits, the same path is kept as the
latest log. Up-to-date and cache-restored targets do not produce a new log; use
`--force --no-cache` to regenerate one.

Compatibility aliases:

- `--skip-goalfrag` warns and behaves like `--skip-proof-steps`.
- `--goalfrag-trace` warns and behaves like `--trace-steps`.
- `--new-ir` is accepted as a deprecated no-op.

Removed legacy interfaces:

- `goalfrag-plan`
- `--goalfrag`
- `--goalfrag-plan`

## Caches and cleanup

Important paths:

```text
.holbuild/src/<package>               # dependency source checkouts
.holbuild/packages/<package>          # package build artefacts
$HOLBUILD_CACHE/hol-toolchains/       # built HOL toolchains and analysers
```

The global build cache stores selected semantic artefacts such as `Theory.sig`,
`Theory.sml`, `Theory.dat`, and tracing-kernel `Theory.tr.gz` files by action
key. Cache hits materialise validated artefacts into the local `.holbuild/`
tree. Standard cache entries do not require a trace blob.

A build can also consult and publish to one Bazel-style HTTP remote cache:

```sh
holbuild --remote-cache http://cache.example.org build MyTheory
HOLBUILD_REMOTE_CACHE_URL=http://cache.example.org holbuild build MyTheory
# or in project-local .holconfig.toml:
# [remote_cache]
# url = "http://cache.example.org"
```

Remote cache misses or errors fall back to the local cache/source build path.
The remote endpoint stores content blobs under `/cas/<sha256>` and holbuild
cache metadata under `/ac/<action-key>`. CAS transfers use zstd compression when
supported by the server; action metadata stays small and is sent uncompressed.
This is a live accelerator, not remote execution and not an immutable release
registry.

For private caches, put credentials in local/CI configuration, not in
`holproject.toml`. CLI `--remote-cache` overrides `HOLBUILD_REMOTE_CACHE_URL`,
which overrides `.holconfig.toml`'s `[remote_cache].url`. `bazel-remote`
supports HTTP Basic Auth; the safest holbuild path is to pass curl a config
file:

```sh
cat > "$RUNNER_TEMP/holbuild-remote-cache.curl" <<'EOF'
user = "build-user:secret-password"
EOF
chmod 600 "$RUNNER_TEMP/holbuild-remote-cache.curl"
HOLBUILD_REMOTE_CACHE_CURL_CONFIG="$RUNNER_TEMP/holbuild-remote-cache.curl" \
  holbuild --remote-cache https://cache.example.org build MyTheory
```

`HOLBUILD_REMOTE_CACHE_CURL_CONFIG` overrides `.holconfig.toml`'s
`[remote_cache].curl_config`.

The URL form `https://user:password@cache.example.org` also works with curl, but
can expose credentials via process listings or shell history; prefer the config
file form for CI and shared machines. holbuild redacts URL userinfo in its own
remote-cache diagnostics, but it cannot hide secrets from the operating system if
they are passed as command-line arguments.

Portable build-output archives use the same cache representation:

```sh
holbuild build MyTheory
holbuild export -o my-build.hbx MyTheory
holbuild --cache-dir /path/to/other/cache import my-build.hbx
```

`export` includes the selected target closure by default and does not run a
build unless `--build` is passed. The archive stores a global deduplicated blob
area plus `project/` and `deps/<package>/` package views for the exported action
manifests. `import` hydrates the global cache; a later `holbuild build MyTheory`
materialises outputs through the normal cache-restore path.

Use `holbuild export --metadata-out MyTheory.hbx.json` to write a registry
metadata sidecar for static hosting or GitHub Releases; see
[`docs/hbx-registry.md`](docs/hbx-registry.md).

Clean old project and cache state with:

```sh
holbuild gc
holbuild gc --clean-only
holbuild --cache-dir /path/to/cache gc --cache-only
```

`gc --clean-only` skips the global cache. `gc --cache-only` skips project
locking/discovery and does not require a HOL toolchain. Project checkpoint GC
uses `.holconfig.toml`'s `[build].checkpoint_limit_gb` unless overridden with
`--max-checkpoints-gb`.

## Local configuration

Local machine settings may go in `.holconfig.toml`:

```toml
[build]
jobs = 16
checkpoint_limit_gb = 20
exclude = ["worktrees"]
exclude_globs = ["scratch/*"]
tactic_timeout = 10.0

[remote_cache]
url = "https://cache.example.org"
curl_config = "/path/to/holbuild-remote-cache.curl"

[overrides.foo]
path = "../foo"

[overrides.bar]
git = "$BAR_REPO"
```

`build.jobs` sets local default parallelism, and `build.checkpoint_limit_gb`
sets the local checkpoint storage budget in GiB; the built-in checkpoint budget
default is 5.

`[overrides.NAME]` maps a declared dependency to local workstation source. Use
`path` to read an existing checkout directly, or `git` to replace the dependency
git source while still checking out the manifest's exact `rev`. Override values
may use environment variables. Local relative paths are resolved from the project
root; URL-like git remotes are left unchanged. Overrides apply during recursive
dependency resolution too, so a dependency declared by another dependency can be
supplied from disk. Overridden dependencies still need a matching `project.name`
in their `holproject.toml`; `dependencies.hol` cannot be overridden this way.

Unknown fields in recognised `holproject.toml` and `.holconfig.toml` tables are
errors.

## CI guidance

A project CI job should normally install or build `holbuild`, then run:

```sh
holbuild buildhol   # optional warm-up
holbuild build
```

Do not pass `HOLDIR` to choose the project HOL. The project HOL is selected by
`[dependencies.hol]`.

If CI builds `holbuild` from source, no separate HOL source checkout is needed;
run `make`. The pinned HOL revision is recorded in `vendor/hol/REV`.

Useful caches:

- `$HOLBUILD_CACHE/hol-toolchains`, keyed by the project HOL revision and Poly/ML
  version.

## Running holbuild's own tests

Repository tests resolve the schema 2 HOL toolchain cache automatically:

```sh
make test
```

To reuse an explicit checkout instead, pass `HOLDIR=/path/to/built/HOL`. The
checkout must be at the revision recorded in `vendor/hol/REV`.

## Release process

Maintainer checklist:

1. Ensure CI is green on `master`.
2. Bump `HolbuildVersion.version` in `sml/version.sml` if needed.
3. Create and push an annotated tag:

   ```sh
   version=X.Y.Z
   git tag -a "v$version" -m "holbuild v$version"
   git push origin "v$version"
   ```

4. Create a GitHub Release from that tag:
   - GitHub repository → Releases → Draft a new release.
   - Select the tag, for example `vX.Y.Z`.
   - Use the tag as the title.
   - Summarise user-visible changes.

There is currently no workflow that automatically publishes a GitHub Release
from a pushed tag.

## More detail

See `DESIGN.md` for design notes on project layout, dependency resolution,
action-key invalidation, analyser separation, and cache semantics.
