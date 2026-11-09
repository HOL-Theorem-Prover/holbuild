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
Compiled initializer integration is also checked against the public HOL fork
revision in `tests/HOL_THEORY_MODULES_REV`, which includes the optional loader
API; the main and legacy jobs continue checking source-loader compatibility.

Compatibility boundaries select implementations by the installed HOL API,
not branch names or revision ordering. In particular, the analyser retains its
legacy planner when `ProofStepPlan` is absent and supports both shared-parser
constructor shapes, before and after HOL added combinator-token spans. Small
adapter tests cover both shapes without adding a third HOL toolchain to CI.
The new token annotations do not change existing proof-step labels or extents.

On HOL and Poly/ML versions supporting compiled theory initializers, holbuild
automatically caches their compiled code under `<cache root>/theory-modules`.
Loading a cached initializer still reads the theory data, registers its types,
constants and theorems, and runs its load hooks in the usual dependency order.
ML libraries retain their usual source-loading behavior. Older toolchains and
missing or incompatible module files use the source loader automatically.

These module files belong to one exact HOL saved state. They stay in the local
cache, including on remote workers, and do not change portable theory artifacts
or remote cache keys. Checkpoint-free builds also produce and use them. Cache
garbage collection and worker cache limits include the module files; deleting
them only causes source loading and regeneration.

Remote execution isolates submitted HOL code from worker credentials and shared
writable caches. Worker hosts need Linux Landlock and libseccomp; see
[action isolation](remote-exec/README.md#action-isolation) for prerequisites,
the trust boundary and the client upgrade requirement.

## Install

### Download a release

Download the archive for your platform and `SHA256SUMS` from the
[GitHub Releases page](https://github.com/HOL-Theorem-Prover/holbuild/releases):

- `holbuild-vX.Y.Z-linux-x86_64.tar.gz`: Linux x86_64, glibc 2.35 or newer.
- `holbuild-vX.Y.Z-macos-arm64.tar.gz`: macOS 15 or newer, Apple Silicon.

Verify the archive against its line in `SHA256SUMS` (`shasum -a 256` works on
both platforms), then extract it:

```sh
tar -xzf holbuild-vX.Y.Z-linux-x86_64.tar.gz
export PATH="$PWD/holbuild-vX.Y.Z-linux-x86_64/bin:$PATH"
holbuild --version
```

Keep the extracted directory together: `bin/holbuild` loads runtime and
analyser sources from `share/holbuild`. You can move the directory or symlink
the executable into a directory already on `PATH`.

The executable includes the Poly/ML runtime, so running it does not require
an installed Poly/ML. Building HOL toolchains still requires `poly` and
`polyc`, plus HOL's other build dependencies. Archives include holbuild's
`LICENSE`, the SML/NJ notice, and Poly/ML's license in `share/holbuild`.
The same release also offers `polyml-v5.9.2-seq5-source.tar.gz`, the exact
Poly/ML sources used for both binaries. Poly/ML is built with
`--disable-shared --without-gmp`; the holbuild sources for rebuilding/relinking
are available at the release tag.

### Build from source

You need Poly/ML. The small set of HOL source files needed to compile the
`holbuild` executable is vendored under `vendor/hol`.

```sh
make
```

If `polyc` is not on `PATH`, select it at build time with `POLYC`:

```sh
make POLYC=/custom/polyml/bin/polyc
```

`POLYC` selects the compiler used to build the `holbuild` executable, and
`POLY` the `poly` it compiles with (by default the one next to `POLYC`, after links). They
are separate from `HOLBUILD_POLY`, which selects the `poly` executable used when
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
Installation also places runtime sources and notices in
`$PREFIX/share/holbuild`; keep that directory beside `$PREFIX/bin` when moving
an installation.
Custom `BINDIR`/`DATADIR` layouts are also supported: `make install` rebuilds
the executable with that data path. Keep custom data at the configured path;
use the standard layout for an installation that can move as a directory.

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
dependency packages are by default. Kernel inference checking and the `.tr.gz`
outputs are unaffected. An explicit debugging flag turns back on what it needs:
`--trace-steps`, `--tactic-timeout`, and `--proof-scope=all` enable proof steps, and
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
holbuild check MyTheory OtherTheory:my_theorem
holbuild check --fingerprint MyTheory OtherTheory
holbuild buildhol
holbuild buildhol --trknl
holbuild build --trknl MyTheory
holbuild heap main
holbuild executable runtests
holbuild export -o build-output.hbx MyTheory
holbuild import build-output.hbx
holbuild --remote-cache URL action-spec --upload MyTheory
holbuild --remote-cache URL run-action --export-only --script s.sml --output out MyTheory
holbuild --remote-cache URL run-action --remote-exec URL --outputs-dir out --script s.sml --output out MyTheory
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
holbuild clean MyTheory && holbuild build --force=theory MyTheory
```

`--force=theory` bypasses cached outputs for the requested targets, but still
reuses valid checkpoints, including failed proof prefixes. To execute a theory
from the beginning while retaining cache hits for its ancestors, run
`holbuild clean MyTheory` followed by `holbuild build --force=theory MyTheory`;
cleaning alone permits a global cache hit.

Common global options:

- `--source-dir PATH`: project source directory. Defaults to
  `HOLBUILD_SOURCE_DIR` or the current working directory.
- `--cache-dir PATH`: global cache directory. Overrides `HOLBUILD_CACHE` and the
  platform default cache location.
- `--offline`: disable holbuild-managed network access. Also enabled by
  `HOLBUILD_OFFLINE=1`; see [Offline builds](#offline-builds).
- `--remote-cache URL`: optional comma-separated Bazel-style HTTP remote cache endpoints. Also
  configurable with `HOLBUILD_REMOTE_CACHE_URL` or project-local
  `.holconfig.toml`.
- `--json`: emit newline-delimited JSON where supported.
- `--quiet`, `--verbose`, `--verbosity LEVEL`: adjust status output.
- `-j N`, `-jN`, `--jobs N`: build parallelism. When holbuild builds a HOL
  toolchain, it also passes `-j N` to HOL's `bin/build`; without it, `bin/build`
  uses HOL's own default.
- `--max-heap MB`: Poly/ML maximum heap size for child HOL processes, including
  remote workers. Without it, remote workers use their configured default
  (12000 MB by default). Do not
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
  the local cache at once, ahead of the build workers. Defaults to 50 or twice
  the build's jobs, whichever is larger; also limits remote-cache existence
  checks before batch export. Only used with a remote cache.

### Offline builds

Use `holbuild --offline build MyTheory` (or `HOLBUILD_OFFLINE=1`) to build
using only dependencies and HOL toolchains already available locally. First
prepare the same project and cache directory with offline mode unset:

```sh
holbuild buildhol
holbuild context
holbuild build MyTheory
holbuild --offline build MyTheory
```

A missing or wrong-revision dependency checkout fails before clone or fetch,
even if its commit is in a local bare mirror. A missing or invalid HOL
toolchain also fails before restore or replacement. The error names what needs
preparing; rerun without `--offline` and with `HOLBUILD_OFFLINE` unset. Valid
local toolchains can regenerate analyser and source metadata offline.
Local artifact caching stays enabled, including reads and writes.

Offline mode ignores remote-cache settings in the environment and
`.holconfig.toml`, including HTTP-client setup. Explicit `--remote-cache` or
`--remote-exec` conflicts with offline mode and fails before project work.
`action-spec` and `exec-action` require a remote cache; help, version and
other local commands remain available. Setting
`HOLBUILD_OFFLINE=0` leaves online behavior unchanged; `--offline` always
enables offline mode.

This policy covers holbuild-managed Git, remote-cache and coordinator access,
including Git's implicit fetching of missing objects. It is not a network
sandbox: user generators, build scripts and invoked programs can still access
the network themselves.

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
checks the tags and hypotheses of its stored theorems. It prints one line per
theorem whose tag carries an oracle other than `DISK_THM` (for instance
`MyTheory.my_theorem: cheat`) and one per axiom declared in the theory or its
ancestors outside HOL itself, that is, in the root package or a dependency
package (`DepTheory.my_axiom: axiom`). Each stored theorem with undischarged
hypotheses is also a finding (`MyTheory.my_theorem: undischarged hypotheses`),
even when it has no oracle tag. Theorems loaded from disk do not record
which axioms they use, so every such axiom in the ancestry is reported. It also
scans the sources the theory is built from outside HOL (theory scripts and the
SML libraries they load) for calls that can forge a theorem or change the
logical context without leaving an oracle or axiom in the built theory, such as
`Thm.disk_thm`, `Thm.mk_axiom_thm`, `TheoryReader` and `RunCall`, and prints one
line per use (`mypkg:src/MyScript.sml:12: kernel bypass: disk_thm`). Names in
comments and string literals don't count; the scan is a backstop, not a
sandbox. With findings it exits non-zero; otherwise it prints
`MyTheory: clean (N theorems)` and exits zero. `holbuild check MyTheory:my_theorem` checks one theorem.
Pass several selectors to share one build of the distinct targets and one HOL
session: `holbuild check MyTheory OtherTheory:my_theorem`. Each selector keeps
its own findings or clean line, in argument order (including repeated selectors).
Findings do not stop later checks; the command exits non-zero if any selector
has findings. Invalid selectors, missing theorems and load errors abort the
command.

`check` builds the theories, and any `[run].loads`, without proof steps or
checkpoints: it applies no step timeout (that is `build`'s check) and reuses
theories built by `holbuild build --skip-proof-steps`. The tags are those
recorded in the built theory, which may have been restored from a cache;
run `holbuild build --no-cache MyTheory` first to check a fresh build. HOL
starts from a valid dependency checkpoint or the toolchain's base state, never
from `[run].heap`, which may hold an older copy of a theory.

`holbuild check --fingerprint MyTheory` builds and loads the theory the same
way and prints one tab-separated line per axiom, definition and theorem stored
in it and in each of its ancestors, HOL's own theories included, sorted
bytewise so that two runs diff cleanly. Several theories can be passed together
(`holbuild check --fingerprint MyTheory OtherTheory`); their shared ancestors
and repeated target theories are emitted only once:

```text
fingerprint	DepTheory	axiom	my_axiom	9a02…(64 hex digits)	-
fingerprint	MyTheory	theorem	my_theorem	3f1c…	-
fingerprint	MyTheory	theorem	other_theorem	77d0…	cheat
```

Build progress and HOL's own messages share stdout, so keep the lines that
start with `fingerprint` and a tab (`grep '^fingerprint'`). After that column
come the theory, the kind (`axiom`, `definition` or `theorem`), the
name, the statement's fingerprint and the theorem's oracles other than
`DISK_THM`, comma-separated, or `-` for none. The fingerprint is the SHA-256 of
the statement's term structure, hypotheses included: constants and types by
theory and name, free variables by name and type, bound variables by de Bruijn
index. It doesn't depend on pretty-printing or on how the theory was built, and
alpha-equivalent statements get the same one. Comparing the output before and
after a change shows whether any existing statement or definition changed, an
axiom appeared, or an oracle was added or dropped. `[local]` theorems are not
stored in the theory and are not listed. The command exits zero; it reports,
and the comparison is the caller's.

Every HOL session holbuild starts, theory builds included, has the same
function as `HolbuildFingerprint.thm : thm -> string`, and
`HolbuildFingerprint.term : term -> string` for a statement not yet proved:
`HolbuildFingerprint.term t` equals the fingerprint of a theorem `|- t`.

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
- `loads` adds modules/libraries to load before the action. A name that is a
  project module is loaded from its object path, like an inferred dependency;
  any other name is loaded by name from HOL's load path.
- `extra_deps` adds package-root-relative filesystem inputs that are hashed
  into the action key and copied into the action's stage directory at their
  path relative to the script, so `data/table.txt` for `src/FooScript.sml` is
  read as `../data/table.txt` (the stage mirrors the package layout, so such
  copies stay inside it); absolute paths and `..` components are rejected. A
  directory or glob names the files under it, skipping any `.holbuild/`
  directory inside it. Before hashing or staging these files, holbuild runs
  the generators whose declared outputs match the file, directory, or glob,
  including outputs that do not exist yet. Unrelated generators stay idle.
- `cache = false` disables global cache restore/publish for the action.
- `always_reexecute = true` disables local up-to-date skipping for the action.

Cache keys hash sources, not built outputs, so a cached theory is reusable only
if its build is reproducible: a deterministic script, with its inputs declared
and the same HOL toolchain, must produce a byte-identical `Theory.dat` in any
project directory. holbuild sorts the exported parent list by theory name and
updates the data hash in `Theory.sml`, so parent load order does not change
these outputs for new exports. Existing valid cache bundles are not rewritten;
older parent orders can still conflict with new bundles during cache import.
A script that reads the clock, environment variables,
undeclared files, or host paths must declare those files in `extra_deps`, or set
`cache = false` for what can't be declared. Builds stay correct either way,
because holbuild rejects a restored theory whose parents' `.dat` files differ
from the local ones, but descendants of a nondeterministic theory then miss the
cache wherever the local build of it differs from the one their cache entries
were built against. A parent-incompatible local cache entry is removed, and
the remote cache's entry for the same key is tried before rebuilding; a rebuilt
child replaces the local entry, which does not change the remote cache's
conflict checks. An entry rejected only by the requested proof policy is retained until
a successful rebuild can publish its stronger contract.

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

When such an action needs source execution, holbuild reruns its script from the
start: script checkpoints retain ML state, not the files the script wrote.
The dependency-loaded checkpoint remains reusable, and proof checkpoints remain
available for diagnostics.

A theory may write SML sources (`.sml` or `.sig`) as extra outputs, as EmitML
code does. A plan made before the theory runs has no node for such a source, so
when a planned theory declares one, holbuild builds the planned theories that
declare SML outputs first and then plans again over the sources they wrote.
Only outputs that discovery would find count: a `.sml` or `.sig` file whose
name and directories don't start with `.` and that isn't under `_build`, so
SML written under a directory such as `.emit/` for another compiler doesn't.
A source that uses a generated structure names its theory in `deps`, so that a
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

For repeated commands and file families, share the arrays in a named template
and list the selected file stems once:

```toml
[generate_templates.packet]
command = ["python3", "tools/packet.py", "{file}.spec"]
inputs = ["tools/packet.py", "{file}.spec"]
outputs = ["{file}Script.sml"]

[[generate]]
name = "packet-batch"
template = "packet"
files = ["gen/Alpha", "gen/Beta"]

[[generate]]
name = "packet-with-library"
template = "packet"
files = ["gen/Gamma"]
inputs = ["tools/packet.py", "{file}.spec", "data/library.spec"]
```

Each `[[generate]]` still declares one invocation: the first runs the command
once with both `gen/Alpha.spec` and `gen/Beta.spec`. In `command`, `inputs`, and
`outputs`, each array element containing `{file}` expands in place into one
element per listed stem, in list order. Literal elements remain once; repeated
`{file}` occurrences within one element use the same stem. The stems are
explicit strings, with no globbing or filesystem discovery.

Templates accept only `command`, `inputs`, and `outputs`. An array supplied on
the generator replaces the template's entire array, so supporting inputs and
compiler options stay explicit. Templates do not inherit from other templates;
`name`, `files`, and `deps` belong to each generator. `files` can also be used
without a template and must contain at least one nonempty string. Without
`files`, all array strings remain literal, including `{file}`.

Expansion happens during manifest parsing, before normal path validation,
output ownership checks and source discovery. The expanded records determine
generator state and cache identities: replacing explicit arrays with an exactly
equivalent template preserves them. No generator runs during parsing.

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
`holbuild run` and `holbuild repl` build every target named by `[run].loads`
(on remote workers with `--remote-exec`; see
[Building on remote workers](#building-on-remote-workers)), create an
invocation-private project context under `.holbuild/`, and then load the
configured targets followed by user arguments. Like heap targets, these are
built without proof steps, so no tactic timeout applies and theories built by
`holbuild build --skip-proof-steps` are reused. Two kinds of argument never
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
without proof execution attributes also support failed-prefix checkpoints;
termination proofs currently replay from the preceding clean
definition/theorem/dependency checkpoint.

A failed termination proof reports its definition, proof source and termination
goal. Once the definition succeeds, that goal is cleared so a later error in the
theory is not attributed to the completed termination proof.

`Proof[...]` attributes such as `exclude_simps` and `exclude_frags`, including
those on `Resume`, remain active across the entire stepped proof. They retain
leaf diagnostics, timeouts and traces. Attributed proofs save theorem-context state
after the declaration is bound and the temporary modifier has unwound; they do not
save or restore failed-prefix checkpoints.

Theories in dependency packages build without proof-step instrumentation or checkpoints
by default. To audit their proofs too, select `--proof-scope=all`.

Useful commands and options:

```sh
holbuild execution-plan MyTheory:my_theorem
holbuild build --tactic-timeout 10 MyTheory
holbuild build --force=full --no-cache --proof-scope=all --tactic-timeout 5 MyTheory
holbuild build --trace-steps MyTheory
holbuild build --repl-on-failure MyTheory
holbuild build --skip-proof-steps MyTheory
holbuild build --skip-checkpoints MyTheory
holbuild build --all-checkpoints MyTheory
```

- `execution-plan THEORY:NAME` prints the proof-step plan for one theorem or
  explicit termination proof. If a theorem and terminating definition have the
  same name, the theorem takes precedence.
- `--tactic-timeout SECONDS` changes the per-step timeout; `0` disables it.
  A step that times out fails the build even inside `TRY` or an `ORELSE`
  alternative.
- `--proof-scope root|all` (also `--proof-scope=root|all`) selects which
  theories receive proof instrumentation and the invocation's timeout. `root`
  is the default. `all` includes dependency theories in the selected build
  plan; unselected theories and packages are untouched. Existing root-package
  timeout overrides keep their usual scope.
  Use `--force=full --no-cache` for a full audit. Otherwise holbuild warns that
  up-to-date and cache-restored actions are not checked. Scope and timeout
  do not change action keys; existing timeout compatibility checks still apply
  when reusing outputs. `all` conflicts with `--skip-proof-steps`.
- `--trace-steps` executes and records proof-step traces for theories covered by
  the selected proof scope, including up-to-date theories. It skips checkpoint
  replay so their trace covers every proof step.
- `--repl-on-failure` starts a HOL REPL from the newest useful checkpoint after a
  theory failure. It serialises the build and is not supported with `--json`.
- `HOLBUILD_FAILED_GOALS_LIMIT` sets the byte limit for the all-input-goals
  section of `instrumented-failure.log`; `HOLBUILD_GOAL_STATE_LIMIT` separately
  sets the top-goal preview limit in text and JSON diagnostics. Both default to
  `4096`. Set either environment variable to a nonnegative decimal integer to
  change its limit, or to `0` or `unlimited` to disable truncation. Invalid values
  fail the build with an error. For example,
  `HOLBUILD_FAILED_GOALS_LIMIT=65536 holbuild build MyTheory` keeps a larger goal
  log while retaining bounded summaries. These settings are read at runtime,
  including after checkpoint restores; no rebuild of holbuild is needed. For
  remote execution, the log limit uses the worker's environment.
- `--skip-proof-steps` opts out of proof-step execution.
- `--skip-checkpoints` disables checkpoint `.save`/`.ok` creation.
- `--all-checkpoints` saves theorem checkpoints in every theory included by
  `--proof-scope` (root-package theories by default) that
  the build runs. By default only the requested targets save them (the default
  targets when none are given, or every root-package theory when there are
  none); the other theories still save their `deps_loaded` checkpoint and run
  with proof steps and step timeouts, so a cold build writes far fewer `.save`
  files. An edit to such a theory starts from its `deps_loaded` checkpoint, and
  rebuilding it as a target (after an edit, or with `--force=theory`) saves its
  theorem checkpoints. `--repl-on-failure` saves them everywhere. Theory outputs and
  cache keys are the same either way. Under `--remote-exec`, the action specs
  carry the choice to the workers.

A theory's `deps_loaded` checkpoint, its dependencies loaded into the
toolchain's base state, is also kept once per host in
`$HOLBUILD_CACHE/checkpoint-store/`, keyed by the dependencies' input keys
and their theories' `.dat` and generated `.sml` files, the theory's loads (by path relative to the project), the toolchain and the
holbuild runtime. The project's directory isn't part of the key, so every
worktree or copy of a project that uses the cache (not with `--no-cache`,
nor for a theory with `cache = false`) shares one heap per
dependency set: a theory with no valid `deps_loaded` hard-links the stored
one (a copy across file systems) and resumes from it, and one it saves is
linked into the store. A stored heap whose parent isn't the build's base
state is ignored, and one HOL can't resume from is discarded and replaced by
the build's fresh heap. The heap is saved without the project's directories,
which HOL puts on `Meta.loadPath` when it starts, so a tree resuming from it
searches only its own. Each build removes stored heaps no tree links any
more (its checkpoint budget evicted them, or the tree was deleted) that no
build used for a day, and `holbuild gc` removes every store directory no
build used within the retention window, except a heap a tree still links. A heap keeps HOL's record of the directories
its files were loaded from, so in a theory resumed from another tree's heap
`Meta.fileDirMap()` names that tree's directories, as it names the old
ones after a project is moved. Loading is unaffected, but TacticToe
recording reads that map: its workers search those directories first
(`tttUnfold`'s includes) and it finds ancestor scripts there
(`tttManifest.find_script`). Run a local TacticToe recording in a tree
whose `deps_loaded` heaps weren't restored from the store (build it with
`--no-cache` from a clean checkout, say).

For source-executed theory builds, holbuild writes a live child log at
`.holbuild/logs/current/<package>/<logical>/build.log`. You can inspect it during
a long build with `tail -f`; after the child exits, the same path is kept as the
latest log.
In text mode, an instrumented build failure leaves its diagnostics in
`instrumented-failure.log` in the same directory. A later successful source execution removes
that failure log, including when execution resumes from a checkpoint.
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
.holbuild/plan/<fingerprint>          # plan records
$HOLBUILD_CACHE/hol-toolchains/       # built HOL toolchains and analysers
$HOLBUILD_CACHE/analysis/             # sources' dependency analyses
```

Planning analyses each source for its dependencies (its `load`s, `use`s,
Holdep mentions and declared extra inputs and outputs) and keeps the result in
`.holbuild/obj` and in the cache's `analysis/` directory. An entry there is
named after the source's content, the analyser's version and the HOL sources
the analyser is built against, so another checkout of the same sources on the
machine reads it instead of analysing again, and a different HOL pin never
uses it.

### The plan record

Planning a build discovers every source, analyses its dependencies and
computes every action key. After it plans, holbuild writes what it found to
a plan record in `.holbuild/plan/`, and the next build with the same
non-file inputs (holbuild version, working directory, command line, requested targets,
`HOLBUILD_*` environment, manifests and `.holconfig.toml`, package roots)
starts from it: it checks each recorded file and directory with `stat`,
hashes again only the files whose size, modification time, change time or
inode moved (and any recorded within a second of its last change), analyses
again the sources whose content changed, and recomputes the keys of those
nodes and everything that depends on them. A source or directory added,
removed, renamed or made readable, or a changed dependency, sends the build
back to full planning, except inside HOL and the git dependencies holbuild
checked out at their pinned revision: there only the files planning read are
checked, so edits to their content are still caught, but a change made by
hand to such a checkout's directories (an added source or `holproject.toml`,
a file replaced by a symlink) goes unnoticed. So does a build whose targets leave out a root with
its own tactic timeout, and a project with `[[generate]]` steps, for which
no record is kept; `--watch` always plans in full. With theories that write
SML sources, the record keeps the plan made once they are up to date, with
the sources they wrote, and a later build uses it only while every such
theory is still up to date and its sources are unchanged; then it builds
without running those theories first or planning again. The four newest records are kept.

`--verbose` prints which way a build planned and why, and the timing log has
a `plan.record` phase. `HOLBUILD_PLAN_RECORD=off` turns the record off;
`HOLBUILD_PLAN_RECORD=check` plans in full as well, and fails the build if
the two plans differ in any source, dependency edge, fact or key.

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
theory's `.dat` names each parent by a SHA-1 (HOL's format): the hash in the
parent's `Theory.sml`, which holbuild's exporter takes over the parent's data
without its proof-dependent parts, so a proof-only edit of the parent keeps
it (see `DESIGN.md`, early cutoff); holbuild checks those names. Git
dependency mirrors under the cache's `git/remotes/` keep their SHA-1-of-URL
names, so existing mirrors stay in use.

Completed theory artifacts are reused only when their recorded proof timeout
satisfies the requested timeout. `--allow-cache-timeout-discrepancy` waives that
check for project-local artifacts and all build-cache sources, including remote
and HBX-imported entries. It does not change source-execution watchdogs or
checkpoint compatibility. When this waiver permits reuse, project metadata
retains the artifact's recorded timeout, so a later build without the flag
applies the strict check.

A build can also consult and publish to Bazel-style HTTP remote caches:

```sh
holbuild --remote-cache https://cache.example.org build MyTheory
HOLBUILD_REMOTE_CACHE_URL=https://cache.example.org holbuild build MyTheory
# or in project-local .holconfig.toml:
# [remote_cache]
# url = "https://cache.example.org"
```

To spread the cache across replicas, give a comma-separated list of base URLs
in `--remote-cache`, `HOLBUILD_REMOTE_CACHE_URL`, or `.holconfig.toml`'s `url`.
Whitespace can also separate URLs. Trailing slashes and duplicate nodes are
removed. Node identity also excludes authority userinfo (`user:password@`),
so inline credentials and curl-config credentials give the same ranking;
the HTTP request retains its full URL. Every client and worker must use the same normalized URL spellings
and node set; different public/private hostnames give different rankings.

For each `/ac/<digest>` or `/cas/<digest>` request, nodes rank by descending
SHA256 of `node identity + ":" + digest` (ascending identity breaks a tie). Only the first two
nodes are tried. Reads try the second node after a 404, connection failure,
timeout, 429 or 5xx; writes do so after a connection failure, timeout, 429 or
5xx. A write whose nodes all failed without an HTTP response (an unresolvable
name, no connection, a timeout) goes on down the ranking until a node answers,
so one more healthy node takes it. A single-node list keeps the ordinary single-cache behavior. A successful
backup keeps the ring available; the circuit breaker below counts the final
outcome of a request. If neither node hits, a 404 from either node gives a miss, even if the
other node failed transiently; this allows a new action to build and publish
on the healthy node. Two transient failures remain unavailable. Replicas should share a backing store: the second
node covers handoff while a newly added node cannot yet see a recent upload.

Remote cache misses or errors fall back to the local cache/source build path.
A request waits at most 5 s for its connection. After three requests in a row
get no response at all (no connection, or a timeout), holbuild warns and
skips remote requests for 60 seconds. After that cooldown, one request probes
the cache while other requests are skipped. A failed probe starts another
60-second cooldown, bounding the cost of an unreachable cache. Any HTTP
response, including an error status, resets the failure count and reopens the
cache; holbuild reports when the cache is available again. In the status line
and `--json`'s `build_finished` event, `from_cache` counts every theory restored
from a cache, and `from_remote` the ones among them whose entries this run
copied from the remote cache.
While a build runs, `--prefetch-concurrency` background threads (by default 50
or twice `-j`, whichever is larger) also copy the remote entries of the plan's
out-of-date theories into the local cache in build order, so a theory's restore
usually finds its entry already local. This prefetch is best-effort and silent;
whatever it misses is fetched when the theory is reached, as before.
`HOLBUILD_CACHE_TRACE=1` shows the prefetch thread count as
`remote cache prefetch threads: <n>` and each prefetched entry as
`remote cache prefetched: <key>`.
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
that HTTPS connections trust. With libcurl 7.87 or later, holbuild drops
libcurl's built-in default CA directory (not one `SSL_CERT_DIR` names), so that
libcurl parses the CA bundle once per connection handle instead of on every
new connection; if a server's certificate then fails to verify, holbuild goes
back to libcurl's default for the rest of the run and retries the request.

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
as strict as the one requested, and every blob it names still in the cache
(`HEAD /cas/<sha256>` answering anything but 404), since a cache may expire
an entry's blobs before the entry. The command takes `build`'s cache and proof
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
and says which and why: one with `cache = false` or `always_reexecute`,
one whose script or extra input lies outside its package root, one that loads a HOL theory or library by path, one with a path
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
order <package>:<logical> <tier> <package-or-.> <dir-or-.>
load theory|library|object <name-or-stem>
output sig|sml|dat <relpath>
output extra <declaration>
option proof-steps=<bool>
option tactic-timeout=<seconds|none>
option new-ir=<bool>
option theorem-checkpoints=false   (only for a theory that saves none)
option skip-checkpoints=true      (when checkpoint reuse is disabled)
option force=true                 (only for a forced theory)
option trace-steps=true            (only for a traced theory)
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
- `order` lines give each `dep theory` and `lib` target's load-order key (see
  "Artifacts and local materialization" in DESIGN.md); a worker sorts the `.uo`
  manifests it writes for restored theories by them. `.` stands for an empty
  package or directory. `load` lines and a `lib` line's loads are already in
  that order.
- `deps-key` identifies the target's dependency context with the toolchain's
  semantic identity, for naming a saved dependency heap.
- The `option` lines are how the theory is run, which the action key leaves
  out; the entry built under them carries the timeout contract the exporting
  build will ask for. Optional `force`, `trace-steps` and `skip-checkpoints`
  default to false. `force` or `trace-steps` disables whole-action cache reuse
  and early cutoff on the worker; `trace-steps` also enables proof-step tracing
  and requires `proof-steps=true`. `skip-checkpoints` disables checkpoint reuse
  and saving, including shared heaps.

### Exporting script runs for remote execution

A *run* is an SML script run in the context of a built theory: HOL started
from the toolchain, the theory's ancestry restorable, libraries loaded, and
the script's declared output files kept. Its result is keyed by what it
reads, so the same run is done once. `run-action --export-only` writes and
uploads the run spec of each target, which a worker runs with `exec-action`
(below); `run-action --remote-exec` also submits them and fetches their
outputs (see "Running scripts on remote workers").

```sh
holbuild --remote-cache https://cache.example.org run-action --export-only \
  --script run.sml [--support F]... [--load L]... --output N... \
  [--option timeout=SECONDS] TARGET...
```

A TARGET is a project theory (a logical name as `build` takes it, or
`<package>:<logical>`), a theory of the HOL toolchain (`hol:bool` or
`hol:boolTheory`), or `hol:*` for every theory in the toolchain's `sigobj`.
`--closure` adds, after the targets, every theory a project target depends
on. The worker restores a project context, the theories it depends on and
those the `--load` libraries need from the remote cache, so each must be
there or in the local cache for its current inputs, from where it is
published to the remote cache first. A target with one in neither is
refused with `build it first`, the others are still exported, and the
command exits 1. A fetched run's directory holds `KEY`, `CONTEXT` and `LOG`, so
those aren't output names. `--support` files must lie under the
script's directory and are named by their given path relative to it, without
resolving symbolic links. `--load` names a library: one
in the toolchain's `sigobj`, or a source the project plans (including the
implicit `hol` package's libraries). The command takes `build`'s cache
options, reuses timed and untimed contexts without checking proof-step
timing, and prints one line per exported target:

```text
<context> <run_key> <spec-sha256>
```

The spec is written to `.holbuild/run-specs/<spec-sha256>` and uploaded to
`/cas/` with every file it names. The run key is the SHA-256 of the run text:

```text
holbuild-run-v1
toolchain=<semantic toolchain key>
context=<package>:<logical>@<input_key>   (or context=HOL:<logical>)
context-input-layout=package-v1          (only contexts declaring extra inputs)
script=<sha256>
support=<relpath>@<sha256>                  (sorted)
load=<package>:<logical>@<input_key>        (a project library; in order)
load=<name>                                 (a toolchain or hol package library)
output=<name>                               (sorted)
```

The toolchain key fixes HOL's own theories and libraries, so they carry no
key of their own. Options such as the timeout stay out of the key: a longer
timeout doesn't make a new run. The input-layout marker distinguishes runs
with staged declared inputs from earlier runs that could not read those files.
Input-free and HOL context run keys are unchanged. A run's result is stored, like a theory's,
under `ac-key = sha256("holbuild-remote-ac-v1\n" ^ run_key ^ "\n")`.

A run spec names no path on the exporting machine:

```text
holbuild-run-spec-v1
holbuild-version=<version>
holbuild-runtime=<sha256 of the holbuild sources a theory child loads>
toolchain git=<url> rev=<rev> kernel=<variant>
run-key=<run_key>
context <package>:<logical> <stem> <input_key>   (or context HOL:<logical>)
file library <relpath> <sha256> <size>
dep theory <package>:<logical> <stem> <input_key>
lib <package>:<logical> <stem> <suffix> <load>...
order <package>:<logical> <tier> <package-or-.> <dir-or-.>
load theory|library|object <name-or-stem>
file context-script <relpath> <sha256> <size>
file input <relpath> <sha256> <size>
script <sha256> <size>
file support <relpath> <sha256> <size>
run-load <package>:<logical>|HOLLIB:<name>
output <name>
option timeout=<seconds>                         (only when given)
run-text
<the run text, verbatim to the end of the blob>
```

- For a project context, the `toolchain`, `file library`, `dep theory`, `lib`
  and `load` lines are the context theory's ActionSpec lines, followed by the
  `file library`, `lib` and `dep theory` lines of what the `--load` libraries
  need beyond them. A HOL context has only the latter.
- `context` names the theory to restore, as a `dep theory` line does, and
  an `order` line gives its load-order key.
- `file context-script` lines are the scripts of the context theory and of
  every theory it depends on, under `.holbuild/action-src/<package>/`, for
  scripts that read their ancestry's sources. For a project context the
  first is the context theory's own.
- `file input` lines carry the context theory's declared runtime files
  (`holbuild_extra_deps` and manifest `extra_inputs`) under that same
  package-relative source tree. A script replaying the context can run from
  the directory of `HOLBUILD_RUN_SOURCE` so source-relative reads resolve.
  Ancestors are restored as objects; their runtime inputs are not inherited.
  Undeclared files are not copied, and inputs outside the package are refused.
  These contents already contribute to the context input key and run key.
- `run-load` lines are the libraries to load, in order: a project library by
  its `lib` line's name, a toolchain library as `HOLLIB:<name>`.
- `output` lines are the file names the script must write.

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
each action. Dependency heaps and checkpoints in `<cache root>/checkpoints`
are private to the action and are also emptied before and after it; reuse
across worker actions requires `--share-heaps` (below). A saved heap records the absolute paths it was
built at, so every worker should use the same cache root. One `exec-action`
runs per cache root at a time; a second waits for the first. The cache root
is the worker's own: other holbuild commands shouldn't share it, since the
cache cap below sweeps it.

In order, it checks the spec (its holbuild version and runtime must equal the
worker's, and its action text must hash to its input key and agree with its
source and direct dependencies), ensures the HOL toolchain (restoring the
remote toolchain archive, or building one, and when another worker's archive
was published first, switching to that archive), fetches the sources by
SHA-256 (keeping them in the cache root's blob store, so it fetches each
once), restores every dependency through the normal cache restore and its
checks, and reports `cached` if the theory's own entry already restores, or
if an earlier build of the same action text on byte-identical dependency
outputs left one, which it then publishes under the action's input key (early
cutoff, DESIGN.md). Forced and traced actions bypass both reuse checks.
Otherwise it builds the theory as a local build would,
with the spec's proof options, publishes it to the remote cache (a local
build would publish it at once; the worker waits for the checks below), and
checks that the remote cache then holds an entry for it whose outputs equal
the build's. An entry there with other outputs is replaced only when it records parents other than the restored
ones, each restored from an entry with the remote cache's outputs, since no
build against them can use it. The worker's local copy of an entry goes out
of date when the remote cache's entry changes. So before it checks for the
theory's own entry, the worker replaces its copies that differ from the
remote cache's entries with those: the copies of the theories the build
loads directly or through project libraries, and, when a restored
dependency doesn't match its parents, all of them. It does the same for the
theory's own entry when that doesn't match the restored parents. A theory
still built against local copies of its parents that differ from the remote
cache's (an entry replaced during the build) is not published but fails as a
`publish` failure, and the worker drops those copies for the action's retry.
A missing dependency fails the action; the worker never builds one. When the
remote cache gives no answer, answers 429 or 5xx, or is in its 60-second
cooldown after requests got no response, whatever the worker was fetching or
publishing, the action fails as `unavailable` rather than reading that as a
miss or a conflict: the cache failed, not the action.

A run spec (`holbuild-run-spec-v1`, see "Exporting script runs for remote
execution") is checked the same way, its run text against its `run-key`,
and reported `cached`, without installing the toolchain or starting HOL, if
the remote cache holds the run's entry with every output. Otherwise the
worker fetches the context and ancestry scripts, library sources and the
script with its support files, restores the dependencies, and a project
context theory like one of them (a HOL context's objects and script come
with the toolchain), and runs, in the script's directory,

```sh
hol run --noconfig --holstate <toolchain>/bin/hol.state <prelude> <script>
```

where the prelude puts the action root's object directories on `loadPath`
and loads the `run-load` libraries in order (a project or `hol` package
library compiles from source as it loads). The script loads the context
theory itself, and is given:

| Variable | Value |
|---|---|
| `HOLBUILD_RUN_ROOT` | the action root, holding the restored context under `.holbuild/` |
| `HOLBUILD_RUN_CONTEXT` | `<package>:<logical>`, or `HOL:<logical>` |
| `HOLBUILD_RUN_CONTEXT_KEY` | the context theory's input key; for a HOL context, the semantic toolchain key |
| `HOLBUILD_RUN_SOURCE` | the context theory's script: under the root, or for a HOL context in the toolchain's source tree (empty if it has none) |
| `HOLBUILD_RUN_OUTPUT_DIR` | the directory to write each declared output in |
| `HOLBUILD_RUN_SCRATCH` | an empty directory of its own, removed with the root |

Its support files are beside it, under the names they were exported with.
If HOL exits 0 having written every declared output as a file, the worker
uploads the outputs to `/cas/` and puts the run's entry at its key:

```text
holbuild-cache-action-v4
input_key=<run_key>
kind=run
parent <input_key>              (a project context's; none for a HOL context)
blob output:<name> <sha256>     (one per output, sorted by name)
```

and checks that the remote cache then holds an entry with these outputs, as
for a theory. A script that fails, or leaves a declared output unwritten,
fails as `script`; one still running when its `option timeout` elapses is
killed with its process group and fails as `timeout`. Neither publishes
anything, and both are final: rerunning the same script on the same
context does the same.

It writes this record to `--result FILE`, or to stdout:

```text
holbuild-action-result-v1
spec=<sha256>
input-key=<input_key>
status=built|cached|failed
failure=proof|tactic-timeout|script|timeout|memory|input-missing|publish|toolchain|disk|spec-rejected|internal|unavailable
missing=theory <input_key> | blob <sha256>
detail=<message>
peak-rss-mb=<n>
wall-ms=<n>
phase-ms=<phase>:<n>,...
log=<sha256> <size>
```

`failure` appears on failure, and `missing` with `input-missing`. A failure
with no `log` (a spec rejected before any HOL ran, say) gives its message in
`detail`, on one line of printable ASCII of at most 500 characters.
For a run, `input-key` is its run key and `built` means it ran.
`phase-ms` gives the wall time of each phase that ran, in order: `cap` (the
cache cap sweep), `spec`, `toolchain`, `hydrate` (sources, libraries and
dependencies), `cutoff` (whether an earlier build stands), `restore` (shared
checkpoints), `hol`, `publish` (shared checkpoints), `check` (the
publication checks) and `log`; stderr ends with the same times and `wall`.
`peak-rss-mb` is the HOL process's peak resident memory, reported once the
theory has been exported.
`log` is the build log, or the run's HOL output, uploaded to `/cas/`. `memory` means Poly/ML ran out
of heap or the container's cgroup `memory.events` counted an OOM kill during
a failed run, whether the OOM killer took the HOL process or a process it
started (a nested HOL whose failure it caught, say); `disk` means the disk
filled. When the HOL process dies by a signal or the OOM killer's count
rose, the log's last lines say which, and the largest resident set of any
child process of the action so far. The exit status summarizes the record:

| Exit | Meaning |
|---|---|
| 0 | built or cached |
| 1 | `proof`, `tactic-timeout`, `script` or `timeout`: final, retrying won't help |
| 2 | `memory`: retry with more memory |
| 3 | `input-missing`, `publish`, `toolchain`, `disk`, `internal` or `unavailable`: retry or resubmit |
| 4 | `spec-rejected` |

The required `--cache-limit-gb N` caps what the worker keeps between actions: its
checkpoints, its HOL toolchains with their analysers, and its local cache.
Before each action, it evicts the least recently used until they fit in `N`
GB minus a reserve for the action itself (`--cache-reserve-gb`, by default a
tenth of `N`). A theory's checkpoints go together, a toolchain goes with its
analysers, and a toolchain another holbuild process is using is kept.

Workers sharing a host coordinate sweeps through `<cache root>/locks/gc.lock`;
share `locks/` along with the cache directories. Private checkpoints and theory modules are sized
on every action. With a positive reserve and a target of at least 64 GiB,
shared sizes can be reused for up to 60 seconds when the last measurement plus
current private sizes fit under the target. Smaller targets and zero-reserve
runs are scanned live. This is a housekeeping limit: shared growth during
that interval is accounted for at the next scan, rather than reserved on each
write. Each cached root's device and inode must match the measurement; roots
that differ are sized live, so partial directory sharing remains safe without
repeatedly replacing a sibling's measurement. Eviction lists are built only
when the measured cache exceeds its target.
Unreferenced blobs younger than five minutes are evicted after other families,
and are still removable if needed to reach the target.

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
directory per heap, which the cache cap and `holbuild gc` evict as a unit,
unless an action on the host is using it. Worker containers on one host can share
`checkpoint-store/` and `hol-toolchains/`, mounted from host directories, and
keep the rest of the cache root to themselves. Restored Poly/ML states and
their records are copied into the private checkpoint tree, so submitted HOL
code cannot change the shared files through a link. Files published back to
the store are also copied, after cleanup and output validation.

### Building on remote workers

Before exporting a batch, remote-cache existence checks run concurrently using
`--prefetch-concurrency` (the same limit as restore prefetch). Progress on stderr
reports `checking remote cache: N/M theories`, unless `--quiet` is given.
The batch keeps the plan's theory order and includes entries with missing blobs.
Its specs and sources are then uploaded the same way, `--prefetch-concurrency`
at a time, reporting `uploading to remote cache: N/M files`; after the first
upload that fails, the rest are skipped and the build falls back (below).
Before compressing and uploading a file, it checks the CAS and skips the file
only when the cache confirms it is already present.

`build --remote-exec URL` hands the theories the remote cache lacks, and
that aren't already built here, to a remote-execution coordinator, which runs them on its workers with
`exec-action`, then restores them as an ordinary build would:

```sh
holbuild --remote-cache https://cache.example.org build --remote-exec https://exec.example.org MyTheory
```

`--force`, `--force=theory`, `--force=project` and `--force=full` also run
on the workers, including with `--remote-only`. Forced theories go into the
batch even when their outputs are already built locally or cached remotely.
`--force=theory` forces only the requested targets; their ancestors reuse the
cache as usual. Valid proof checkpoints remain reusable.

`--trace-steps` (also the deprecated `--goalfrag-trace`) sends every theory
whose proof policy enables tracing to the workers even if it is cached.
The worker executes its proof steps without theorem-checkpoint replay.

Completed actions' build logs are fetched into
`.holbuild/logs/current/<package>/<theory>/build.log`. Traced theories also
write `proof-trace.log` there and print a trace summary and its log path.
A forced or traced build falls back locally if its required log cannot be
returned; with `--remote-only` it fails with status 75. It never reports
success with an old or absent log. The client restores the
finished outputs without forcing a second build locally. Detached builds
return their logs when attached.

It exports and uploads the batch as `action-spec --upload` does, submits it
with `POST URL/v1/batches`, and follows `GET URL/v1/batches/<id>/events`,
printing each theory's state as it changes. While it follows the batch, it
copies into the local cache the remote cache entry of each theory as the batch
finishes it, and those of the theories outside a submitted batch that the
remote cache already holds, `--prefetch-concurrency` at a time. When the batch is done,
the build restores those theories from the local cache, or from the remote cache
whatever is not there yet. The coordinator's credentials go
in a curl config file named by `HOLBUILD_REMOTE_EXEC_CURL_CONFIG`, such as
`header = "Authorization: Bearer <token>"`, so they stay off the command line.

If a local cache entry has a weaker tactic-timeout contract than requested,
restore refreshes it from the remote cache once. This picks up a stronger
contract published by a worker without discarding the older entry when the
remote has no usable replacement.

When the batch ends, one line says how many of its theories the remote
workers finished, built or found cached (`holbuild: remote execution: remote
workers finished 3 of 3 theories`), or, when the build falls back, why and
how many they finished.

A theory built here for its current inputs (the worktree's `.holbuild/dep`
metadata holds its current input key, under a timeout contract at least as
strict as the one requested), or with a valid entry and intact blobs in the
local cache, needs no worker, so it isn't checked
against the remote cache and stays out of the batch, even when the remote
cache lacks it, as when its publish after a local build failed. The workers
restore from the remote cache what the batch's theories depend on, so when a
theory in the batch depends on one, holbuild publishes its local cache entry
there first; it goes in the batch only when it has no usable local entry or
the publish fails. `--detach` follows no local build, so it checks and
submits such theories like any other. What these checks and the source
uploads find the remote cache to hold is kept in `.holbuild/remote-ledger/`,
so a later build doesn't ask again.

The build never waits on remote execution alone. If the closure can't run
remotely (see `action-spec`), the coordinator can't be reached or refuses the
batch, or the batch fails other than by a failed proof (below), it warns and
builds locally. A theory the remote cache holds may not fit the parents it
holds, as when a nondeterministic theory was built twice; the workers can't
use it, and the coordinator fails the batch for resubmission naming it
(`resubmit: ... theory <input_key>`). Such a batch is resubmitted once first,
with that theory and every theory that depends on it, for the workers to
rebuild or recheck against the cached parents. The remote cache may also have
lost a theory or source the remote ledger says it holds: on a resubmission
for either, the build forgets the ledger, and a batch missing a blob
(`resubmit: ... blob <sha256>`) is resubmitted once too, uploading it again. A submission
answered 5xx, as a proxy in front of the coordinator answers while it
restarts or the coordinator itself answers while it's overloaded, or 429,
is retried, and an event stream that breaks is reattached; either is given up on once the coordinator stays unavailable for
almost six minutes (retries back off to 8 seconds apart). With
`--remote-only` or `--detach`, which have no local build to fall back to, a
submission that can't reach the coordinator at all is retried the same way;
otherwise it builds locally at once. A
reattached stream that breaks again before any action changes state counts
as unavailable too, since it only repeats what the build already knows. When the build stops following
a batch that may still run (the stream was given up on, or the coordinator
won't stream it), it cancels the batch before building locally; one
interrupted (SIGINT or SIGTERM) while it follows a batch cancels it too. With
`--remote-only` it cancels a batch the coordinator won't stream, or an
interrupted build's, the same way but then fails instead of building locally,
and it never builds HOL or a theory
locally: a HOL toolchain or a theory that doesn't restore from a cache is an
error. Such a `--remote-only` build exits with status 75 (`EX_TEMPFAIL`),
whenever it stops where a build without `--remote-only` would go on locally,
so that a caller can tell this from an error and build locally itself. An
error on the command line or in the project, a batch someone cancelled, or an
interrupt exits with status 1, though a HOL toolchain that doesn't restore is
found first, before the command line is checked. With nothing to build remotely it says so and goes straight to the
local build. A build that includes a theory writing SML sources (see
`holbuild_extra_outputs`) builds locally too, since those theories have to
run before the rest of the build can be planned; with `--remote-only` it
only restores from the cache, and with `--detach` it fails.

A batch that fails because a theory's proof failed on a worker (failure
`proof` or `tactic-timeout`) isn't built locally, since a local build would
fail the same way. The build restores what the cache holds, as `--remote-only`
does, fetches the worker's build log from the remote cache into
`.holbuild/logs/current/<package>/<theory>/build.log`, prints the diagnostic a
local build would, and exits with status 1, with or without `--remote-only`.
If that log can't be fetched, the build builds just the failed theory locally,
for its diagnostic; with `--remote-only` it fails with status 75 instead.

`--detach` submits the batch, prints its id (`holbuild: remote batch <id>`)
and exits; if the batch can't be submitted, it fails rather than building
locally. `--attach <id>` follows that batch and then builds as above. A
`--remote-only` build that loses the event stream says how to reattach.

`run` and `repl` take `--remote-exec URL` and `--remote-only` too, before the
arguments passed to HOL, and build their `[run].loads` targets, and any
`--from` or inferred theory, this way (without proof steps) before they start
HOL locally (they don't take `--detach` or `--attach`):

```sh
holbuild --remote-cache https://cache.example.org run --remote-exec https://exec.example.org script.sml
```

[`remote-exec/`](remote-exec/README.md) has a coordinator and a worker loop
that speak this protocol, and a container image with both.

The coordinator's protocol, in what holbuild uses of it:

- `POST /v1/batches` with the batch text as the body answers 201 and
  `{"batch_id": "<id>"}`; any other status refuses the batch.
- `GET /v1/batches/<id>/events` streams one JSON object per line: an
  `{"type": "action", "input_key", "theory", "state", "last_failure",
  "log_sha256", "failure_detail", ...}` when an action changes, and last
  `{"type": "batch", "state": "done"|"failed"|"cancelled", "failure"}`. A
  failed action's log is at `/cas/<log_sha256>` in the remote cache. The log
  includes the action's failure diagnostic even when it failed before starting
  HOL, provided the worker can write and upload the log; a failure with no
  log, such as a spec the worker rejects, says why in `failure_detail`, which
  holbuild prints with the failure. A stream may start over: it
  sends every action's current state first.
- `POST /v1/batches/<id>/cancel` cancels a running batch and answers
  `{"state": "<state>"}`: `cancelled`, or the end a batch that already
  ended reached.

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

Cache GC removes the dependency analyses under `analysis/` that no build has
read or written within the retention period. A build that finds its analyses
in `.holbuild/obj` doesn't count as a use, so such an entry can go while a
checkout still uses the project's copy; the next fresh checkout analyses that
source again.

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

### Running scripts on remote workers

`run-action --remote-exec URL` runs a script in the context of each target on
a coordinator's workers, once per set of inputs, and fetches what the script
writes:

```sh
holbuild --remote-cache https://cache.example.org run-action \
  --remote-exec https://exec.example.org [--remote-only] --outputs-dir out \
  [--profile P] --script run.sml [--support F]... [--load L]... --output N... \
  [--option timeout=SECONDS] [--closure] TARGET...
```

The project write lock covers planning, cache checks, and spec export. It
is released before submitting or following the batch and fetching outputs,
so another command can build the same project while the remote run is in flight.

Contexts reuse artifacts built with any proof-step timeout, including
`build --skip-proof-steps`, in remote, fetch-only and export-only modes.
`run-action` consumes these artifacts without rechecking proof-step timing;
ordinary `build` still checks its requested timeout contract.

The targets, the script, its support files, `--load` libraries, outputs,
timeout and `--closure` are those of `run-action --export-only` (see
"Exporting script runs for remote execution"), as is the run key: the
SHA-256 of the run text, which names the toolchain, the context theory and
its input key, the script's and support files' hashes, the loads and the
output names, so the same run is done once. The command:

1. Plans the targets and computes each run's key; it reads no build output
   and builds nothing.
2. Checks the remote cache for each run's entry (`/ac/<ac-key>`, `kind=run`,
   with every declared output in `/cas/`); a run that has one is `cached`.
3. Exports the others' specs, publishing first the theories they need that
   only the local cache holds, and refusing a run that needs one neither
   cache holds with `build it first`.
4. Submits them as one batch with `POST URL/v1/batches?class=run` (and
   `&profile=P` with `--profile`, the coordinator's memory profile), and
   follows its events, printing each run's state as it changes, as
   `build --remote-exec` does. A run batch has no edges, and an action that
   fails fails only itself.
5. Fetches each `done` or `cached` run's entry and outputs into
   `D/<package>/<theory>/` (`D/HOL/<theory>/` for a toolchain theory),
   replacing what was there: `KEY` holds the run key, `CONTEXT` the run
   text's context (`<package>:<theory>@<input_key>` or `HOL:<theory>`), and
   each declared output its file. For a `failed` run, replaces the same
   directory with `KEY`, `CONTEXT` and, when available, `LOG` containing the
   worker's diagnostic. If a reported log cannot be fetched, warns on stderr
   and leaves `LOG` absent; the run stays `failed` and still counts toward
   exit status 0. Successful and cached runs have no `LOG`.
6. Prints one line per run on stdout, in the targets' order:

   ```text
   <context> <run_key> done|cached|failed <class>|missing
   ```

   `failed` gives the run's failure class: `script` (the script raised or
   left a declared output unwritten), `timeout` (it outlived
   `--option timeout`) or another of `exec-action`'s classes. `missing` is a
   run that didn't end (refused, or left in a batch that stopped), or whose
   entry or outputs couldn't be fetched.

What the script gets on the worker is in "Running one theory action as a
remote worker": the `HOLBUILD_RUN_*` variables, among them
`HOLBUILD_RUN_OUTPUT_DIR`, where it writes each declared output. Only a
script that exits normally with every output written caches a result; a
failed run caches nothing, so it runs again next time.

`--fetch-only` fetches what the remote cache already holds and prints
`cached` or `missing` for each run, without exporting, publishing or
submitting anything, so it needs no `--remote-exec`. Runs never execute
locally: without `--remote-exec` or one of `--fetch-only` and
`--export-only`, the command is a usage error.

Exit status:

- 0 when every run ended `done`, `cached` or `failed` (a failed script is a
  result); with `--fetch-only`, also when some are `missing`.
- 75 (`EX_TEMPFAIL`) when the coordinator can't take or finish the batch:
  the export or upload fails, the submission is refused or the coordinator
  unreachable, the event stream is lost (the batch is left running, so its
  results reach the cache for the next try), the coordinator won't stream it
  (it's cancelled), the batch fails as a whole, a theory a run needs that
  only the local cache holds fails to publish, or a run that ended can't be
  fetched; and with `--remote-only` when no `--remote-exec` is given.
- 1 for errors on the command line or in the project, a batch someone
  cancelled, an interrupt (which cancels the batch), or a target refused
  with `build it first` (after the others ran).

Once the runs are planned, the per-run lines are printed whatever the exit
status, except on an interrupt, so a caller can keep what did end.

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

The runner sets `HOLBUILD_PLAN_RECORD=check` unless it is already set, so
every build in the suite that plans from a plan record is also checked
against full planning.

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

The focused `theory-modules` CI job selects the public HOL fork with
`HOLBUILD_TEST_HOL_GIT` and the commit in `tests/HOL_THEORY_MODULES_REV`.
It sets `HOLBUILD_TEST_REQUIRE_THEORY_MODULES=1` so an unsupported toolchain
fails this job instead of checking only the source fallback. The ordinary
suite also runs the same case on its default HOL revision, where the source
fallback remains valid.

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

4. The **Release binaries** workflow builds Linux x86_64 and macOS arm64
   archives, then tests downloaded copies on fresh runners without Poly/ML.
   Only after both platforms pass does it attach the archives and
   `SHA256SUMS`, plus the shared Poly/ML source archive, to the release. It
   creates a release with generated notes if none exists for the tag; an existing release (including a draft) retains
   its notes and publication state. Summarise user-visible changes in those
   notes, and publish the draft if you prepared one.

The workflow also checks packaging on relevant pull requests without
publishing anything. To rebuild assets, rerun the tag's workflow; uploads
replace assets with the same names. A manual workflow run only builds and
tests; publication requires a version-tag push.

## More detail

See `DESIGN.md` for design notes on project layout, dependency resolution,
action-key invalidation, analyser separation, and cache semantics.
