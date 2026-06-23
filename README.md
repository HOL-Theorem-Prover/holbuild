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

That revision is the HOL toolchain used to analyse and build the project.
`holbuild` builds or reuses it under:

```text
$HOLBUILD_CACHE/hol-toolchains/<key>/hol
```

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
holbuild heap main
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
- Branches, tags, version ranges, registries, solvers, lockfiles, path
  dependencies, local overrides, and multiple versions of one package are not
  supported.
- Direct git dependencies use only `git` and `rev`.
- Subtree dependencies use `from`, `path`, and `manifest`.
- `path` and `manifest` must be relative and must not contain `..`.

### `[build]`

```toml
[build]
members = ["src", "lib"]
exclude = ["*/selftest.sml", "*/examples/*"]
roots = ["src/MainScript.sml"]
tactic_timeout = 10.0

[build.root_tactic_timeouts]
"src/SlowScript.sml" = 60.0
```

- `members` tells `holbuild` where to discover source files.
- `exclude` removes package-root-relative glob matches from discovery.
- `roots` are the default entry points when `holbuild build` is run with no
  target. Use `holbuild build --warn-unreachable` to report discoverable theory
  scripts that are outside the root dependency closure.
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

[run]
heap = "build/main.heap"
loads = ["MyLib"]
```

`holbuild heap main` builds the listed logical objects, loads generated theory
modules, and saves the heap. `holbuild run` and `holbuild repl` create a project
run context under `.holbuild/` before loading `[run].loads` and user arguments.

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
`Theory.sml`, and `Theory.dat` by action key. Cache hits materialise validated
artefacts into the local `.holbuild/` tree.

Clean old project and cache state with:

```sh
holbuild gc
holbuild gc --clean-only
holbuild --cache-dir /path/to/cache gc --cache-only
```

`gc --clean-only` skips the global cache. `gc --cache-only` skips project
locking/discovery and does not require a HOL toolchain.

## Local configuration

Local machine settings may go in `.holconfig.toml`:

```toml
[build]
jobs = 16
exclude = ["worktrees/*"]
tactic_timeout = 10.0
```

This is for workstation settings, not dependency overrides. Dependency locations
belong in `holproject.toml`.

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
