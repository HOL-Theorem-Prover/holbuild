# holbuild

`holbuild` is a build tool for HOL4 projects. It lets a project describe its
sources, HOL revision, and dependencies in a `holproject.toml` file (or a
`holbuild.toml`, see [Manifest discovery](#manifest-discovery)), then builds
logical targets such as `MyTheory` without requiring users to manage `.uo`,
`.ui`, `.dat`, or Holmake state directly.

If you know HOL and Holmake, the main difference is that `holbuild` is
project-oriented: the project manifest selects the HOL checkout to use, build
outputs live under `.holbuild/`, and dependency projects can be fetched from
exact git revisions.

## Status

`holbuild` is usable but still experimental. It supports only the current
manifest language, with an optional legacy `schema = 2` marker. The manifest
format and CLI may still change before any future
upstreaming into HOL.

`holbuild` reserves top-level SML identifiers beginning with `Holbuild` for its
own generated code and runtime support. User project code should not define
values, structures, signatures, or functors with that prefix.

### HOL revision compatibility

The same holbuild executable supports the current HOL pin in `vendor/hol/REV`
and the legacy compatibility floor recorded in `tests/HOL_LEGACY_TACTICS_REV`
(`e395eb6e69054ff6f7cef9d1107fd1a04dd5848f`). CI covers those two revisions;
this is not a guarantee for every intervening or future HOL commit.

Compatibility boundaries select implementations by the installed HOL API,
not branch names or revision ordering. In particular, the analyser retains its
legacy planner when `ProofStepPlan` is absent and supports both shared-parser
constructor shapes, before and after HOL added combinator-token spans. Small
adapter tests cover both shapes without adding a third HOL toolchain to CI.
The new token annotations do not change existing proof-step labels or extents.

## Install from source

You need Poly/ML. The small set of HOL source files needed to compile the
`holbuild` executable is vendored under `vendor/hol`.

```sh
make
```

If `polyc` is not on `PATH`, select it at build time with `POLYC`:

```sh
make POLYC=/custom/polyml/bin/polyc
```

`POLYC` selects the compiler used to build the `holbuild` executable. It is
separate from `HOLBUILD_POLY`, which selects the `poly` executable used when
holbuild builds or runs project HOL toolchains.

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

Create `holproject.toml` in the root of your HOL project (`holbuild.toml`
works too; see [Manifest discovery](#manifest-discovery)):

```toml
[holbuild]
schema = 2
minimum_version = "<MAJOR.MINOR.PATCH>"  # optional version floor

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

The target is the logical theory/module name, not an object filename. A target
that looks like a source path (it contains `/` or ends in `.sml`/`.sig`) is
resolved relative to the current directory instead, so `holbuild
src/ExampleScript.sml` builds the same target. The explicit `build` command
remains accepted, for example `holbuild build` and `holbuild build
ExampleTheory`.

To inspect how the project is resolved, run:

```sh
holbuild context
holbuild context --trknl  # inspect the tracing-kernel context
```

`context` resolves metadata for the selected kernel variant without building the
HOL toolchain.

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

Only one holbuild process builds or restores a given toolchain at a time.
Another process that needs the same toolchain waits for it, however long that
takes, and reports the owning process on stderr when the wait starts and every
30 s.

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

`build --trknl` collects traces, not proof-development artifacts, so it builds
root-package theories as `--skip-checkpoints --skip-proof-steps` would, as
dependency packages always are. Kernel inference checking and the `.tr.gz`
outputs are unaffected. An explicit debugging flag turns back on what it needs:
`--trace-steps` and `--tactic-timeout` enable proof steps, and
`--repl-on-failure` enables proof steps and checkpoints. Explicit
`--skip-proof-steps` or `--skip-checkpoints` still conflicts with those flags.

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
holbuild repl --from MyTheory
holbuild context
holbuild context --trknl
holbuild execution-plan MyTheory:my_theorem
holbuild check MyTheory
holbuild buildhol
holbuild buildhol --trknl
holbuild build --trknl MyTheory
holbuild heap main
holbuild executable runtests
holbuild export -o build-output.hbx MyTheory
holbuild import build-output.hbx
holbuild --remote-cache URL action-spec --upload MyTheory
holbuild clean MyTheory
holbuild gc
```

When a command, target, heap or executable, or an `execution-plan` theory or
theorem isn't found, the error is followed by a line of up to three of the
nearest known names, nearest first, ignoring case:

```text
holbuild: unknown build target: listLemasTheory
did you mean listLemmasTheory?
```

The line is left out when no name is close.

Global options go before the command, or before the target list when using the
default build command:

```sh
holbuild -j4 MyTheory
holbuild --max-heap 4096 MyTheory
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
holbuild --allow-cache-timeout-discrepancy --tactic-timeout 5 MyTheory
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
- `-j N`, `-jN`, `--jobs N`: build parallelism. When holbuild builds a HOL
  toolchain, it also passes `-j N` to HOL's `bin/build`; without it, `bin/build`
  uses HOL's own default.
- `--max-heap MB`: Poly/ML maximum heap size for child HOL processes. Do not
  use `--maxheap`: holbuild is itself a Poly/ML program, and its runtime takes
  `--maxheap MB` as the cap on holbuild's own heap, so the option never reaches
  holbuild and child HOL processes run uncapped. holbuild rejects `--maxheap`
  where it can detect it (Linux), so there it cannot be used to cap holbuild's
  own heap either.
- `--cooperate-dir DIR` (or `HOLBUILD_COOPERATE_DIR`): share a machine memory
  budget with every holbuild process using `DIR`. See below.
- `--machine-max-mem MB`: the budget to record in `DIR/budget` when that file
  does not exist yet; a value that differs from the file at this process's
  first admission is an error.
- `--child-charge MB`: what each child reserves against that budget. Defaults
  to `--max-heap`, but at most 3072 (3072 without `--max-heap`); where
  `MemAvailable` can't be read, to `--max-heap` + 1024, and then `--max-heap`
  or `--child-charge` is required.
- `--prefetch-concurrency N`: how many remote cache entries a build copies into
  the local cache at once, ahead of the build workers. Defaults to twice the
  build's jobs; only used with a remote cache.

### Sharing a machine's memory between holbuild processes

`-j` limits children within one holbuild process. Independent processes on one
machine (several users, CI jobs, containers with a shared bind mount) can share
a memory budget instead: with `--cooperate-dir DIR`, every theory, generator and
heap-export child reserves `--child-charge`, and starts only while the
reservations of all processes using `DIR` fit the budget, and `MemAvailable`
covers the charge plus a margin kept free. The reserve is a quarter of
`MemTotal`, at least 1 GiB and at most 30 GiB; the default budget is
`MemTotal` less the reserve, and the margin is the reserve, or what the budget
leaves out of `MemTotal` if that is less (at least 1 GiB), so a budget set
above the default can be used. Children admitted in the last 30 seconds,
which have not allocated yet, count against `MemAvailable` by their charge.
The charge is an expected size, not a ceiling: `--max-heap` caps each child,
and the `MemAvailable` check holds new children back when running ones, or
anything else on the machine, grow. While no reservation is held in `DIR`, a
child that fits the budget starts whatever `MemAvailable` says, so a build
never waits on memory none of its children use. Where `/proc/meminfo` has no
`MemAvailable` (outside Linux), only the reservations count, and the default
charge is `--max-heap` + 1 GiB, what a child can reach. `/proc/meminfo` shows
the whole machine, not a container's memory limit, so inside a
memory-limited container set `--child-charge` to what a child can reach. A child
that waits shows as `(waiting for memory)` in the status line, as a
`waiting for machine memory` line otherwise, and as a `waiting_for_memory`
event with `--json`. A charge larger than the whole budget fails at once.

This bounds admission; it does not enforce RSS: children already running can
still grow together, up to their `--max-heap`, past what the machine has left,
since nothing re-checks a child once it has started. It covers neither HOL
toolchain builds nor `check`, `run` or `repl`.

- The budget is the byte count in `DIR/budget`, which `--machine-max-mem`
  creates on first use. Without that file, it is the default, recomputed from
  `MemTotal` at each admission. To set or resize it, write the file while
  holding `DIR/lock`:
  `flock DIR/lock sh -c 'echo BYTES > DIR/budget.new && mv DIR/budget.new DIR/budget'`.
  Running children keep their reservations; new ones use the new value. To
  return to the default, remove it: `flock DIR/lock rm DIR/budget`. A
  `DIR/budget` that an older holbuild wrote with its default counts as set
  this way, since nothing tells the two apart.
- Each running child has a file `DIR/lease-*` holding its byte charge,
  `flock`ed by holbuild and inherited by the child, so a killed holbuild's
  reservation ends with its children, with no timeout. A lease nobody holds no
  longer counts and is removed by the next process that scans `DIR`.
- Each admission scans `DIR` while holding `DIR/lock`. A child waits for that
  lock while another process holds it, printing
  `holbuild: waiting Ns for machine-memory lock DIR/lock` every 30 s, for up
  to `HOLBUILD_COOPERATE_LOCK_TIMEOUT` seconds (default 600; `0` waits with no
  limit), and then the build fails. If `flock` itself fails (a filesystem
  without it), the build fails at once.
- For several users, create `DIR` writable by all of them (for example mode
  `1777`, or `2775` with a shared group) on a local filesystem. holbuild makes
  its files readable by everyone.

`holbuild build --watch MyTheory` runs an initial build, then watches project
inputs with `inotifywait` and rebuilds after changes. The directory of each
manifest in use is watched as well (not recursively), so a `holbuild.toml` or
`.holconfig.toml` appearing beside the manifest triggers a rebuild. Watch mode
currently requires `inotifywait` from `inotify-tools` and does not support
`--json`, `--dry-run`, or `--repl-on-failure`.

`holbuild check MyTheory` builds the theory if needed, loads it in HOL and
checks the tags of its stored theorems. It prints one line per
theorem whose tag carries an oracle other than `DISK_THM` (for instance
`MyTheory.my_theorem: cheat`) and one per axiom declared in the theory or its
ancestors outside HOL itself, that is, in the root package or a dependency
package (`DepTheory.my_axiom: axiom`). Theorems loaded from disk do not record
which axioms they use, so every such axiom in the ancestry is reported. With
findings it exits non-zero; otherwise it prints `MyTheory: clean (N theorems)`
and exits zero. `holbuild check MyTheory:my_theorem` checks one theorem.
`check` builds the theory, and any `[run].loads`, without proof steps or
checkpoints: it applies no step timeout (that is `build`'s check) and reuses
theories built by `holbuild build --skip-proof-steps`. The tags are those
recorded in the built theory, which may have been restored from a cache;
run `holbuild build --no-cache MyTheory` first to check a fresh build. HOL
always starts from the toolchain's base state here, not from `[run].heap`,
which may hold an older copy of the theory.

`holbuild clean MyTheory` removes project-local generated artifacts, dependency
metadata, and checkpoints for the named theory target. This is primarily a
recovery/debugging command for suspect local state; normal builds should not
require it. Clean does not remove global cache entries, so use
`holbuild build --no-cache MyTheory` afterwards if you also want to avoid
restoring the target from the global cache.

`--source-dir PATH` or `HOLBUILD_SOURCE_DIR` chooses where to look for
the project manifest. Build output is written under `.holbuild/` in the current
working directory.

### Manifest discovery

holbuild looks for the manifest in the source directory and then in each
parent. In each directory it selects `holbuild.toml` if present, otherwise
`holproject.toml`, and moves to the parent only when neither exists. So the
nearest directory with a manifest wins, and within that directory
`holbuild.toml` wins; a nearer `holproject.toml` still beats an ancestor's
`holbuild.toml`. Only the selected file is parsed, with the same schema
whichever name it has. The files are never merged, and an invalid
`holbuild.toml` is an error even when a valid `holproject.toml` sits beside it.

Dependencies discovered on disk (git dependencies and `.holconfig.toml` path
overrides) use the same preference. An explicit shim `manifest` path is used as
declared. A nested directory containing either file is a separate project and
is excluded from its parent's automatic source discovery.

`holbuild.toml` exists so that a project can also carry a `holproject.toml`
written for another tool: Holmake reads `holproject.toml` with its own schema,
which holbuild's validator rejects. Such a project keeps that file for Holmake
and adds `holbuild.toml` for holbuild. This is a compatibility measure; the
shared-schema and workspace design questions of issue #110 are not settled by it.

## Manifest guide

### `[holbuild]`

```toml
[holbuild]
schema = 2
minimum_version = "<MAJOR.MINOR.PATCH>"
```

`[holbuild].minimum_version` is an optional `MAJOR.MINOR.PATCH` version floor.
When present, the running holbuild version must be at least that version; when
omitted, holbuild performs no minimum-version check. The legacy `schema = 2`
marker is optional. Other schema values and `required_version` are rejected.

### `[project]`

```toml
[project]
name = "example"
```

`project.name` is required and identifies the logical package. A dependency
manifest's name must match its dependency key.

Holbuild parses committed semantics into separate metadata, source, entrypoint,
dependency, runtime, action-input, action-dependency, action-execution, and
generator layers. `holbuild context` reports canonical IDs for the package and
independently reusable policy layers; TOML formatting and table order do not
affect these IDs. It also reports typed package provenance: authoritative source
snapshot, definition and retrieval origins, logical/source roots, and implicit
HOL toolchain origin. Retrieval and materialization paths are excluded from
semantic package identities. Package declarations are resolved into one typed
project graph per kernel variant; context, source discovery, watching, and HOL
selection reuse its stable package instances rather than reparsing manifests.
Commands that need sources then run an explicit impure generator-preparation
phase before read-only source discovery; metadata-only context does not execute
generators. Source-requiring commands use one layered pipeline:

```text
package definitions -> resolved package instances -> generator preparation
-> canonical source inventories -> package components -> resolution context
-> reachable source analysis -> resolved selected graph -> ordered build plan
-> action keys and execution
```

Canonical resolution-context, selected-graph, structural selected-plan, and
combined resolved-plan identities exclude machine paths. Hashing and dependency extraction remain limited to the selected
reachable frontier.

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

[build.theory_tactic_timeouts]
"SlowTheory" = 30.0

[build.root_tactic_timeouts]
"src/SlowScript.sml" = 60.0
```

- `members` tells `holbuild` where to discover source files. Membership makes a
  source available as a logical target and as a dependency of other targets, but
  does not by itself make the source part of the default build.
- `exclude` removes concrete package-root-relative paths from discovery; a
  directory entry excludes its subtree, and a file entry excludes just that file.
- `exclude_globs` removes package-root-relative glob matches from discovery.
  For backwards compatibility, glob patterns in `exclude` are accepted with a
  deprecation warning and treated as `exclude_globs`; new manifests should use
  the explicit field.
- `roots` are the default entry points when `holbuild build` is run with no
  target. Entries may be logical names (`MainTheory`), package-root-relative
  source paths, or `@name` build group references. Logical-name and source-path
  roots must name sources of this package discovered through `members` and not
  removed by `exclude` or `exclude_globs`; the `.sml` suffix of a path may be
  omitted. If no package in the dependency graph declares roots or root
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
- `theory_tactic_timeouts` sets a timeout for exactly the named theory, given as
  a logical name (`SlowTheory`) or a package-root-relative script path
  (`src/SlowScript.sml`); it does not affect dependencies or consumers. Naming
  the same theory twice is an error. `0` disables the timeout for
  that theory. An explicit CLI `--tactic-timeout` overrides this table.
- `root_tactic_timeouts` lets individual root source files set timeout contracts
  for their dependency closures. Keys must spell the root exactly as it appears
  in `roots` (or, for a group root, as the member's package-root-relative path).

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
- `extra_deps` adds package-root-relative filesystem inputs that are hashed
  into the action key and copied into the action's stage directory at their
  path relative to the script, so `data/table.txt` for `src/FooScript.sml` is
  read as `../data/table.txt` (the stage mirrors the package layout, so such
  copies stay inside it); absolute paths and `..` components are rejected. A
  directory or glob names the files under it, skipping any `.holbuild/`
  directory inside it.
- `cache = false` disables global cache restore/publish for the action.
- `always_reexecute = true` disables local up-to-date skipping for the action.

Cache keys hash sources, not built outputs, so a cached theory is reusable only
if its build is reproducible: a deterministic script, with its inputs declared
and the same HOL toolchain, must produce a byte-identical `Theory.dat` in any
project directory. A script that reads the clock, environment variables,
undeclared files, or host paths must declare those files in `extra_deps`, or set
`cache = false` for what can't be declared. Builds stay correct either way,
because holbuild rejects a restored theory whose parents' `.dat` files differ
from the local ones, but descendants of a nondeterministic theory then miss the
cache wherever the local build of it differs from the one their cache entries
were built against, and their rebuilt entries can't be published.

Source files may also declare source-file-relative extra dependencies:

```sml
val () = holbuild_extra_deps ["../data/table.txt"];
```

Theory scripts may declare deterministic extra output files:

```sml
val () = holbuild_extra_outputs ["results/test.nsv"];
```

Each path is relative to the declaring source file and must be a fixed file path
inside the package: absolute paths, `.`/`..` components, trailing slashes, and
glob syntax are rejected. The action must produce every declaration. Extra
outputs participate in up-to-date checks and cache publication/restoration, and
`holbuild clean TARGET` removes them. Holbuild records ownership lazily and
rejects another action that attempts to materialize the same path. As with
ordinary outputs, cleaning followed
by a normal build may restore them from cache; use existing no-cache or impure /
always-reexecute controls when source execution is required.

A theory may write SML sources (`.sml` or `.sig`) as extra outputs, as EmitML
code does. A plan made before the theory runs has no node for such a source, so
when a planned theory declares one, holbuild builds the planned theories that
declare SML outputs first and then plans again over the sources they wrote. A
source that uses a generated structure names its theory in `deps`, so that a
fresh checkout plans the theory:

```toml
[actions.UseLib]
deps = ["GenTheory"]
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

Declared outputs participate in source discovery as virtual entries. A generator
runs only when a selected source reaches one of its outputs, either as HOL/SML
source or through a manifest/inline `extra_deps` declaration. Its transitive
`deps` run first, and all declared outputs are then checked. Unreachable
generators do not require their command-line tools to be installed. Broad groups
and default roots still demand every generated output they select.

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
and executable objects may also include signature targets. Heap and executable
targets build their objects without proof steps, so no tactic timeout applies
and they reuse theories built by `holbuild build --skip-proof-steps`; use
`holbuild build` to check proof-step timeouts. Before starting HOL,
`holbuild run` and `holbuild repl` build every target named by `[run].loads`,
create an invocation-private project context under `.holbuild/`, and then load
the configured targets followed by user arguments. Two kinds of argument never
reach HOL this way, wherever they appear: holbuild's global options and
`-h`/`--help`, which holbuild takes itself, and Poly/ML runtime options
(`--gcthreads`, `--maxheap`, `-H`, ...), which holbuild's own Poly/ML runtime
removes from its command line, so holbuild rejects them where it can detect
them (Linux).

`holbuild run --from THEORY` and `holbuild repl --from THEORY` start HOL from a
checkpoint that building `THEORY` left behind, instead of loading its ancestry
again. `THEORY` is a logical name or source path; only root-package theories
have checkpoints. `--from` must come before the arguments passed to HOL. The
starting state is:

| Condition | State |
| --- | --- |
| Its `deps_loaded` checkpoint matches its current dependencies and `THEORY` is built for its current source | ancestors loaded from the checkpoint, then `THEORY` loaded |
| Only `THEORY` changed since it was built, or the project directory moved (`THEORY`'s objects name the old directory, so loading it fails with a warning): its `deps_loaded` checkpoint matches its current dependencies | ancestors loaded, `THEORY` not loaded |
| Otherwise: not built yet, restored from the cache without a local build, built with `--skip-checkpoints`, checkpoints removed by `gc`, a dependency or the HOL toolchain changed, or `THEORY` is in a dependency package | `[run].heap` if configured, else the HOL base state |

A usable checkpoint takes precedence over `[run].heap`. holbuild prints one
line naming the state it chose and, on fallback, why. `--from` does not build
`THEORY` itself. To refresh its checkpoints when `THEORY` is up to date or a
cache hit, run `holbuild build --force --no-cache THEORY`.
`[run].loads` are still built first and loaded on top of the chosen state.
Checkpoints are saved with `TheoryPP.include_docs` and
`TheoryPP.include_html_docs` off, so a session started from one resets both to
their defaults; under `repl` this also overrides a value set in your HOL
config. An unknown `THEORY` is an error.

Without `--from`, `holbuild run script.sml` and `holbuild repl script.sml`
choose `THEORY` themselves. holbuild finds the root-package theories the `.sml`
scripts among the HOL arguments depend on (their `load` calls and the modules
Holdep finds, as for build sources), takes the one with the most ancestors
(when one has all the others as ancestors, that one), and starts from it as
`--from` would. Its line names the theory and says it was inferred. Scripts
that use no root-package theory, and a `repl` without scripts, start from
`[run].heap` or the HOL base state as before; so do scripts whose analysis
fails, with a line saying why. An explicit `--from` overrides the inferred
theory.

## Proof steps and checkpoints

By default, `holbuild` instruments modern theorem and explicit termination
proofs in the root package and executes them as proof steps. This gives better
failure locations, per-step tactic timeouts, and optional traces. Theorem proofs
also support failed-prefix checkpoints; termination proofs currently replay from
the preceding clean definition/theorem/dependency checkpoint. Theories in
dependency packages build without proof-step instrumentation or checkpoints;
to debug a dependency's proofs, build that package as the root project.

Useful commands and options:

```sh
holbuild execution-plan MyTheory:my_theorem
holbuild build --tactic-timeout 10 MyTheory
holbuild build --trace-steps --force MyTheory
holbuild build --repl-on-failure MyTheory
holbuild build --skip-proof-steps MyTheory
holbuild build --skip-checkpoints MyTheory
```

- `execution-plan THEORY:NAME` prints the proof-step plan for one theorem or
  explicit termination proof. If a theorem and terminating definition have the
  same name, the theorem takes precedence.
- `--tactic-timeout SECONDS` changes the per-step timeout; `0` disables it.
  A step that times out fails the build even inside `TRY` or an `ORELSE`
  alternative.
- `--trace-steps` records proof-step traces in child logs.
- `--repl-on-failure` starts a HOL REPL from the newest useful checkpoint after a
  theory failure. It serialises the build and is not supported with `--json`.
- `--skip-proof-steps` opts out of proof-step execution.
- `--skip-checkpoints` disables checkpoint `.save`/`.ok` creation.

For source-executed theory builds, holbuild writes a live child log at
`.holbuild/logs/current/<package>/<logical>/build.log`. You can inspect it during
a long build with `tail -f`; after the child exits, the same path is kept as the
latest log.
Up-to-date and cache-restored targets do not produce a new log; use
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

Source, action and toolchain keys and cache blobs are SHA-256 digests, the
digest Bazel-style remote caches use for `/cas/`. holbuild 0.13.0 switched
them from SHA-1, so it reads none of the local cache entries, remote cache
entries or HOL toolchains that earlier releases wrote: its first build of a
project builds the toolchain and every theory again (or restores what other
0.13.0 builds have published), and is never served an old entry. `holbuild gc`
removes the old entries once they age out. Two uses of SHA-1 remain. A
theory's `.dat` names each parent by the SHA-1 of the parent's `.dat` (HOL's
format), and holbuild checks those names. Git dependency mirrors under the
cache's `git/remotes/` keep their SHA-1-of-URL names, so existing mirrors
stay in use.

Completed theory artifacts are reused only when their recorded proof timeout
satisfies the requested timeout. `--allow-cache-timeout-discrepancy` waives that
check for project-local artifacts and all build-cache sources, including remote
and HBX-imported entries. It does not change source-execution watchdogs or
checkpoint compatibility. When this waiver permits reuse, project metadata
retains the artifact's recorded timeout, so a later build without the flag
applies the strict check.

A build can also consult and publish to one Bazel-style HTTP remote cache:

```sh
holbuild --remote-cache https://cache.example.org build MyTheory
HOLBUILD_REMOTE_CACHE_URL=https://cache.example.org holbuild build MyTheory
# or in project-local .holconfig.toml:
# [remote_cache]
# url = "https://cache.example.org"
```

Remote cache misses or errors fall back to the local cache/source build path.
A request waits at most 5 s for its connection. After three requests in a row
get no response at all (no connection, or a timeout), holbuild warns once and
leaves the remote cache alone for the rest of the run, so an unreachable cache
costs a build a bounded amount of time; an HTTP error status doesn't count
towards the three, and any response resets the count. In the status line and
`--json`'s `build_finished` event, `from_cache` counts every theory restored
from a cache, and `from_remote` the ones among them whose entries this run
copied from the remote cache.
While a build runs, `--prefetch-concurrency` background threads (twice `-j` by
default) also copy the remote entries of the plan's out-of-date theories into
the local cache in build order, so a theory's restore usually finds its entry
already local. This prefetch is best-effort and silent; whatever it misses is
fetched when the theory is reached, as before. `HOLBUILD_CACHE_TRACE=1` shows
the prefetch thread count as `remote cache prefetch threads: <n>` and each
prefetched entry as `remote cache prefetched: <key>`.
A missing HOL toolchain is restored from the same remote cache when its HOL
commit, build arguments other than `-j`, installation path (with symlinks
resolved, as HOL's build records it), platform, C library, Poly/ML runtime
(release and architecture variant, as `poly -v` reports them) and resolved
`poly` executable path match. The source-analysis helper is not archived; holbuild
rebuilds it against the restored toolchain. After a remote miss, a successful
local toolchain build is published automatically unless another builder
published it meanwhile; an archive that is missing its blob or fails to extract
or validate is replaced by the local build (a failed download is not). Local and remote hits are not re-uploaded, and publication
failure is only a warning.

The remote endpoint stores content blobs under `/cas/<sha256>` and holbuild
cache metadata under `/ac/<sha256>`; a blob's CAS digest is the same one
holbuild uses locally. CAS transfers use zstd compression when
supported by the server; action metadata stays small and is sent uncompressed.
This is a live accelerator, not remote execution and not an immutable release
registry. Remote cache contents are trusted build inputs: cache hits can load
Poly/ML objects, and restored toolchains execute cached binaries. Use an
authenticated HTTPS endpoint with trusted writers. Content hashes detect
corruption but do not authenticate the cache publisher.

holbuild talks to the remote cache through libcurl (7.66 or later, with an
asynchronous DNS resolver), loaded at run time: `libcurl.so.4` on Linux, the
system `/usr/lib/libcurl.4.dylib` on macOS. If it can't be loaded or lacks
those, holbuild says why once and runs the `curl` command for each request
instead, as it did before it used libcurl. As with the curl command,
`CURL_CA_BUNDLE`, `SSL_CERT_FILE` and `SSL_CERT_DIR` select the CA certificates
that HTTPS connections trust.

For private caches, put credentials in local/CI configuration, not in
the project manifest. CLI `--remote-cache` overrides `HOLBUILD_REMOTE_CACHE_URL`,
which overrides `.holconfig.toml`'s `[remote_cache].url`. `bazel-remote`
supports HTTP Basic Auth; the safest holbuild path is a credentials file in
curl's config syntax:

```sh
cat > "$RUNNER_TEMP/holbuild-remote-cache.curl" <<'EOF'
user = "build-user:secret-password"
EOF
chmod 600 "$RUNNER_TEMP/holbuild-remote-cache.curl"
HOLBUILD_REMOTE_CACHE_CURL_CONFIG="$RUNNER_TEMP/holbuild-remote-cache.curl" \
  holbuild --remote-cache https://cache.example.org build MyTheory
```

`HOLBUILD_REMOTE_CACHE_CURL_CONFIG` overrides `.holconfig.toml`'s
`[remote_cache].curl_config`. Through libcurl, holbuild reads only the `user`
option from this file (`user = "name:password"`, `user name:password` or
`--user name:password`; `#` starts a comment line). A file with any other
option (`proxy`, `cacert`, `netrc`, ...) makes holbuild say so once and use the
`curl` command, which reads the whole file.

The URL form `https://user:password@cache.example.org` also works, but can
expose credentials via process listings or shell history; prefer the config
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
materialises outputs through the normal cache-restore path. Import HBX archives
only from trusted publishers because those cached build outputs may later be
loaded by Poly/ML.

Use `holbuild export --metadata-out MyTheory.hbx.json` to write a registry
metadata sidecar for static hosting or GitHub Releases; see
[`docs/hbx-registry.md`](docs/hbx-registry.md).

### Exporting theory actions for remote execution

`action-spec` plans targets as `build` would, without building, and exports
each theory the remote cache can't yet satisfy as an ActionSpec: a text blob
with everything another machine needs to build that one theory from the remote
cache alone. A theory counts as satisfied only if its remote entry would
restore for this build: a usable manifest whose timeout contract is at least
as strict as the one requested. The command takes `build`'s cache and proof
options (`--tactic-timeout`, `--skip-proof-steps`, ...) and needs a remote
cache:

```sh
holbuild --remote-cache https://cache.example.org action-spec --upload MyTheory
```

Each spec is written to `.holbuild/action-specs/<sha256>`, named by its
SHA-256. With `--upload`, the specs and every source file they name are also
uploaded to the remote cache's `/cas/`. The command prints the batch, the
uncached theories with the uncached theories each waits for:

```text
holbuild-action-batch-v1
action <input_key> <ac-key> <spec-sha256> <package>:<logical>
edge <input_key> <parent input_key>
```

A theory is ready to build once all its `edge` parents' results are in the
remote cache, that is once `/ac/<ac-key>` exists for each;
`ac-key = sha256("holbuild-remote-ac-v1\n" ^ input_key ^ "\n")` is where
holbuild stores a theory's entry. An edge names the nearest uncached theories
a theory depends on, looking through libraries and cached theories.

`action-spec` refuses a closure containing a theory that can't run remotely,
and says which and why: one with `cache = false` or `always_reexecute`, a
forced one (`--force`), one whose script or extra input lies outside its
package root, one that loads a HOL theory or library by path, one with a path
containing whitespace, and any theory with `--trknl`. Such a closure builds
locally.

An ActionSpec names no path on the exporting machine:

```text
holbuild-action-spec-v1
holbuild-version=<version>
holbuild-runtime=<sha256 of the holbuild sources a theory child loads>
toolchain git=<url> rev=<rev> kernel=<variant>
input-key=<input_key>
action-text-sha256=<sha256 of the action text below>
deps-key=<dependency context key>
target <package>:<logical>
source <package> <relpath> <sha256> <size>
file input <relpath> <sha256> <size>
file library <relpath> <sha256> <size>
dep theory <package>:<logical> <stem> <input_key>
lib <package>:<logical> <stem> <suffix> <load>...
load theory|library|object <name-or-stem>
output sig|sml|dat <relpath>
output extra <declaration>
option proof-steps=<bool>
option tactic-timeout=<seconds|none>
option new-ir=<bool>
action-text
<the action text, verbatim to the end of the blob>
```

- The action text is the one whose SHA-256 is `input-key`, so a reader can
  check the spec against the key it claims. It names the source's SHA-256 and
  the keys of the direct dependencies.
- `source` is the theory's script, by its path in its package. `file input`
  lines are its extra inputs, relative to the package root. `file library`
  lines are the sources of the project libraries it loads, and `lib` lines are
  those libraries' `.uo`/`.ui` manifests, with their loads in order.
- Every other path (`file library`, a `dep theory` or `lib` object stem, a
  `load object`, an `output`) is relative to the action root, the directory
  that holds the `.holbuild/` tree. In a `lib` line, a load containing `/` is
  such a path; any other load is a HOL name. Library sources are placed under
  `.holbuild/action-src/<package>/`.
- `dep theory` lines list every theory the target depends on, directly or not,
  with the object stem its outputs restore to.
- `deps-key` identifies the target's dependency context with the toolchain's
  semantic identity, for naming a saved dependency heap.
- The `option` lines are how the theory is run, which the action key leaves
  out; the entry built under them carries the timeout contract the exporting
  build will ask for.

### Running one theory action as a remote worker

`exec-action` builds the ActionSpec stored in the remote cache under
`SPEC-SHA256`, with nothing but the remote cache as input, publishes the
result there, and exits:

```sh
HOLBUILD_CACHE=/var/cache/holbuild holbuild --remote-cache https://cache.example.org \
  --max-heap 32000 --cooperate-dir /var/lib/holbuild/memory \
  exec-action SPEC-SHA256 --result result.txt --cache-limit-gb 200 [--share-heaps]
```

It runs in `<cache root>/action`, which it locks and empties before and after
each action, and, without `--share-heaps` (below), keeps the theory's
dependency heap and checkpoints in `<cache root>/checkpoints`, so a later run
of an edited theory resumes from them as a local build does. A saved heap records the absolute paths it was
built at, so every worker should use the same cache root. One `exec-action`
runs per cache root at a time; a second waits for the first. The cache root
is the worker's own: other holbuild commands shouldn't share it, since the
cache cap below sweeps it.

In order, it checks the spec (its holbuild version and runtime must equal the
worker's, and its action text must hash to its input key and agree with its
source and direct dependencies), ensures the HOL toolchain (restoring the
remote toolchain archive, or building one, and when another worker's archive
was published first, switching to that archive), fetches the sources by
SHA-256, restores every dependency through the normal cache restore and its
checks, and reports `cached` if the theory's own entry already restores.
Otherwise it builds the theory as a local build would, with the spec's proof
options, and checks that the remote cache then holds an entry for it whose
outputs equal the build's. A missing dependency fails the action; the worker
never builds one.

It writes this record to `--result FILE`, or to stdout:

```text
holbuild-action-result-v1
spec=<sha256>
input-key=<input_key>
status=built|cached|failed
failure=proof|tactic-timeout|memory|input-missing|publish|toolchain|disk|spec-rejected|internal
missing=theory <input_key> | blob <sha256>
peak-rss-mb=<n>
wall-ms=<n>
log=<sha256> <size>
```

`failure` appears on failure, and `missing` with `input-missing`.
`peak-rss-mb` is the HOL process's peak resident memory on a successful build.
`log` is the build log, uploaded to `/cas/`. `memory` means Poly/ML ran out
of heap or the container's cgroup `memory.events` counted an OOM kill during
the run; `disk` means the disk filled. The exit status summarizes the record:

| Exit | Meaning |
|---|---|
| 0 | built or cached |
| 1 | `proof` or `tactic-timeout`: final, retrying won't help |
| 2 | `memory`: retry with more memory |
| 3 | `input-missing`, `publish`, `toolchain`, `disk` or `internal`: retry or resubmit |
| 4 | `spec-rejected` |

The required `--cache-limit-gb N` caps what the worker keeps between actions: its
checkpoints, its HOL toolchains with their analysers, and its local cache.
Before each action, it evicts the least recently used until they fit in `N`
GB minus a reserve for the action itself (`--cache-reserve-gb`, by default a
tenth of `N`). A theory's checkpoints go together, a toolchain goes with its
analysers, and a toolchain another holbuild process is using is kept.

With `--share-heaps`, workers share dependency heaps and checkpoints through
the remote cache. Before the build, the worker restores the latest checkpoint
another worker published for the theory's source, the way a local build
picks one: the last theorem or definition context whose source prefix is
unchanged, or a failed proof's prefix, with a timeout at least as strict as
the spec's. If there's none, it restores the dependency heap; if there's no
heap either, it loads the dependencies cold. After the build, successful or
not, it publishes its heap if no other worker's is, and then, when the heap
under them is the published one, the checkpoints it saved. A heap is shared
only between workers with the same toolchain bytes, cache root, action root
and platform, which is why every worker should use the same cache root.

The checkpoint tree is then the action's own, emptied before and after it;
the host store `<cache root>/checkpoint-store` keeps the shared files, one
directory per heap, which the cache cap evicts as a unit, unless an action
on the host is using it. Worker containers on one host can share
`checkpoint-store/` and `hol-toolchains/`, mounted from host directories, and
keep the rest of the cache root to themselves. A restored file is hard-linked
from the store when the store and `checkpoints/` are on one mount, and copied
otherwise. A bind mount counts as another mount even on the same filesystem,
so in that layout restores copy: the store still saves downloads, not disk.

### Building on remote workers

`build --remote-exec URL` hands the theories the remote cache lacks to a
remote-execution coordinator, which runs them on its workers with
`exec-action`, then restores them as an ordinary build would:

```sh
holbuild --remote-cache https://cache.example.org build --remote-exec https://exec.example.org MyTheory
```

It exports and uploads the batch as `action-spec --upload` does, submits it
with `POST URL/v1/batches`, and follows `GET URL/v1/batches/<id>/events`,
printing each theory's state as it changes. When the batch is done, the build
restores every theory from the remote cache. The coordinator's credentials go
in a curl config file named by `HOLBUILD_REMOTE_EXEC_CURL_CONFIG`, such as
`header = "Authorization: Bearer <token>"`, so they stay off the command line.

When the batch ends, one line says how many of its theories the remote
workers finished, built or found cached (`holbuild: remote execution: remote
workers finished 3 of 3 theories`), or, when the build falls back, why and
how many they finished.

The build never waits on remote execution alone. If the closure can't run
remotely (see `action-spec`), the coordinator can't be reached or refuses the
batch, or the batch fails, it warns and builds locally. An event stream that
breaks is reattached; one that stays unreachable through four reattaches
(about 15 seconds of backoff) is given up on. When the build stops following
a batch that may still run (the stream was given up on, or the coordinator
won't stream it), it cancels the batch before building locally. With
`--remote-only` it fails instead, and it never builds HOL or a theory
locally: a HOL toolchain or a theory that doesn't restore from a cache is an
error. With nothing to build remotely it says so and goes straight to the
local build.

`--detach` submits the batch, prints its id (`holbuild: remote batch <id>`)
and exits; if the batch can't be submitted, it fails rather than building
locally. `--attach <id>` follows that batch and then builds as above. A
`--remote-only` build that loses the event stream says how to reattach.

[`remote-exec/`](remote-exec/README.md) has a coordinator and a worker loop
that speak this protocol, and a container image with both.

The coordinator's protocol, in what holbuild uses of it:

- `POST /v1/batches` with the batch text as the body answers 201 and
  `{"batch_id": "<id>"}`; any other status refuses the batch.
- `GET /v1/batches/<id>/events` streams one JSON object per line: an
  `{"type": "action", "input_key", "theory", "state", "last_failure",
  "log_sha256", ...}` when an action changes, and last `{"type": "batch",
  "state": "done"|"failed"|"cancelled", "failure"}`. A failed action's log is
  at `/cas/<log_sha256>` in the remote cache. A stream may start over: it
  sends every action's current state first.
- `POST /v1/batches/<id>/cancel` cancels a running batch.

Clean old project and cache state with:

```sh
holbuild gc
holbuild gc --clean-only
holbuild --cache-dir /path/to/cache gc --cache-only
holbuild gc --toolchains-only
```

Long cache GC stages report scanned and removed counts on stderr while they
run, unless `--quiet` is given. Progress never goes to stdout, which keeps the
`project clean: removed ...` and `cache gc: removed ...` summaries.

`gc --clean-only` skips the global cache. `gc --cache-only` skips project
locking/discovery and does not require a HOL toolchain. Project checkpoint GC
uses `.holconfig.toml`'s `[build].checkpoint_limit_gb` unless overridden with
`--max-checkpoints-gb`.

Cache GC also removes installed HOL toolchains under `hol-toolchains/` that no
holbuild command has used within the retention period; a removed toolchain is
rebuilt, or restored from a remote cache, the next time a project needs it.
Toolchains being built, restored, or used by a running holbuild process
(including `build --watch`) are skipped. Project checkpoints saved against a
removed toolchain are discarded and rebuilt automatically, but heaps exported
with `holbuild heap` or `holbuild executable` must be re-exported before they
are used outside holbuild.

`gc --toolchains-only` removes only such stale toolchains, skipping project
cleanup and the action/blob scan, which can take minutes on a large cache. Like
`--cache-only`, it needs no project or HOL toolchain. `--clean-only`,
`--cache-only`, and `--toolchains-only` are mutually exclusive.
`--max-checkpoints-gb` applies only to project cleanup and is ignored with
`--cache-only` or `--toolchains-only`.

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
default is 5. Local `exclude` and `exclude_globs` apply only to the root package.
Dependency discovery is controlled by each dependency's committed manifest.

`[overrides.NAME]` maps a declared dependency to local workstation source. Use
`path` to read an existing checkout directly, or `git` to replace the dependency
git source while still checking out the manifest's exact `rev`. Override values
may use environment variables. Local relative paths are resolved from the project
root; URL-like git remotes are left unchanged. Overrides apply during recursive
dependency resolution too, so a dependency declared by another dependency can be
supplied from disk. Overridden dependencies still need a matching `project.name`
in their manifest; `dependencies.hol` cannot be overridden this way.
A `from/path/manifest` shim cannot be overridden directly; override the direct
source dependency named by `from` instead.

Unknown fields in recognised manifest and `.holconfig.toml` tables are
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

- `$HOLBUILD_CACHE/hol-toolchains`, keyed by the project HOL revision, HOL build
  arguments, Poly/ML runtime and resolved `poly` path.

## Running holbuild's own tests

Repository tests resolve the schema 2 HOL toolchain cache automatically:

```sh
make test
```

To reuse an explicit checkout instead, pass `HOLDIR=/path/to/built/HOL`. By
default the checkout must be at the revision recorded in `vendor/hol/REV`.

To test against another immutable HOL commit without changing the vendor pin,
leave `HOLDIR` unset and override the test revision. The runner provisions and
reuses the corresponding revision-keyed toolchain through `holbuild buildhol`,
and generated test manifests use the same revision:

```sh
env -u HOLDIR -u HOLBUILD_HOLDIR \
  HOLBUILD_TEST_HOL_REV=<full-40-character-commit> make test
```

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
