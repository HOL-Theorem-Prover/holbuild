# A modern, human- and agent-friendly build system for HOL4

`holbuild` is a project-aware build frontend for HOL4. The implementation is fairly stable; the `holproject.toml` format is still under active design while feature requests settle before eventual upstreaming into HOL.

This repository is the external development vehicle for the design in https://github.com/HOL-Theorem-Prover/HOL/issues/1916: `holproject.toml` as a project manifest, logical build targets, project-level artifacts, and a future in-tree `hol build` implementation.

## Current scope

The current implementation intentionally focuses on:

- reads and schema-checks the nearest `holproject.toml`
- establishes a shared project context for `build`, `run`, and `repl`
- currently reuses HOL's existing SML TOML parser at compile time
- accepts logical build targets such as `MyTheory`, not object filenames such as `MyTheory.uo`
- owns source discovery and maps outputs to project-level `.holbuild/`
- infers theory/module dependencies with HOL/Holdep machinery over the resolved project graph and orders build plans
- parses transitive schema 2 dependency manifests
- materializes dependency sources under project `.holbuild/src/<package>/` and package artifacts under `.holbuild/packages/<package>/`
- rejects duplicate logical theory/module names across the resolved graph; a same-package `.sig`/`.sml` pair is one module interface/implementation pair
- includes project `load "Module"` SML/SIG dependencies in build plans and internal load manifests
- records generated theory ML dependencies from HOL theory metadata in internal load manifests
- rejects source-level `use "file"` in project build actions; declare/load project modules instead
- supports per-action policy for explicit logical dependencies/loadable modules, extra dependencies, cache disabling, and always-rerun actions
- computes current-format source/resolved-dependency input keys for planned actions
- schedules build actions in DAG-ready parallel order with `-jN`, local `[build].jobs`, or a CPU-derived default
- executes simple theory-script builds into project `.holbuild/` without Holmake
- records local action metadata and skips unchanged actions
- publishes/restores simple theory semantic artifacts through the global cache
- includes the configured toolchain/base context in current action keys
- creates local theory checkpoints while building: dependencies-loaded and final-context checkpoints when checkpointing is enabled, plus theorem context/end-of-proof and failed-prefix proof-navigation checkpoints when theorem instrumentation is enabled; successful builds retain reusable checkpoints for incremental proof replay and clear stale failed-prefix checkpoints, while `holbuild gc` bounds old checkpoint families
- runs modern theorem proofs through holbuild's proof IR runtime by default, with tactic parsing/step planning, proof-history execution, checkpoint saves, timeout handling, and diagnostics kept out of generated per-theory source; the legacy HOL `goalFrag` runtime remains available with `--goalfrag`
- keeps proof instrumentation separate from checkpoint creation; `--skip-checkpoints` avoids theory `.save` files entirely, `--skip-goalfrag` opts out of theorem instrumentation but can still use non-theorem dependency/final-context checkpoints, and `--tactic-timeout SECONDS` controls the root-project per-tactic proof timeout (default 2.5s; `0` disables it)
- exports explicit project heap targets from `[[heap]]` entries using local SaveState
- exposes `holbuild gc` for project-local residue cleanup plus global-cache GC with a 7-day default retention policy
- does not delegate build semantics to Holmake
- treats `.uo`/`.ui` as internal ML artifacts, never user-requestable targets
- delegates project-context execution to the manifest-declared project HOL from `[dependencies.hol]`

Projects are schema 2 only and must declare exactly one `[dependencies.hol]` git
revision. Commands that need HOL build or reuse that declared HOL under
`$HOLBUILD_CACHE/hol-toolchains/<key>/hol`; `--holdir`, `HOLDIR`,
`HOLBUILD_HOLDIR`, schema 1, and `[dependencies.HOLDIR]` are no longer supported
as project/runtime configuration. The external implementation still needs a HOL
checkout via `make HOLDIR=...` to compile `bin/holbuild`; this is a temporary
build-time implementation dependency, not a runtime project selector. See
`DESIGN.md`.

## Current validation status

The codebase is stable and production-dogfooded beyond toy cases; the remaining
volatility is in the project-manifest format and related user-facing build model.
The full holbuild test suite passes against the local HOL checkout. The Vyper HOL
project worktree has passed rooted project builds with theorem instrumentation and
transient checkpoints enabled using `--no-cache --tactic-timeout 0`; focused
finite-timeout smoke testing for the large `instIdxIndepTheory` target passes at
`--tactic-timeout 60`. The default root timeout remains intentionally strict
(2.5s) for proof-debug feedback and is not expected to be a universal production
setting for all root projects.

## Build

```sh
make HOLDIR=/path/to/HOL
make HOLDIR=/path/to/HOL test
HOLBUILD_TEST_JOBS=16 make HOLDIR=/path/to/HOL test
```

Optional install:

```sh
make HOLDIR=/path/to/HOL install
```

This installs only the `holbuild` executable to `$HOME/.local/bin/holbuild` by
default. Override with `PREFIX`, `BINDIR`, or `DESTDIR` if needed.

The `HOLDIR` passed to `make` is currently only for compiling/testing holbuild
itself. Project commands do not accept `--holdir` and never use `HOLDIR` or
`HOLBUILD_HOLDIR` to select a runtime HOL; they use manifest `dependencies.hol`.
The compiler loads HOL's existing SML TOML parser from `$(HOLDIR)` and embeds it
in `bin/holbuild`. Tests live under `tests/cases/*/test.sh` so they can move into
HOL's selftest layout with minimal reshaping; `tests/run.sh` is the repo-local
runner and can run cases in parallel with `HOLBUILD_TEST_JOBS`. Current cases
cover simple theory builds, schema 2 dependency resolution, local build excludes, build roots,
cross-package SML load resolution, dependency cycle rejection, conservative
invalidation, checkpoint replay/recovery, process cleanup on interrupt,
logical-name conflict rejection, cache restoration/corruption/concurrency/GC,
parallel diamonds, same-project write locking, explicit heaps, object-target
rejection, manifest schema validation, status output, root/dependency tactic
timeout policy, and generated theory dependency/path stability.

## Usage

```sh
bin/holbuild build MyTheory
bin/holbuild -j4 build MyTheory
bin/holbuild --maxheap 4096 build MyTheory
bin/holbuild --source-dir /path/to/project build MyTheory
bin/holbuild build --skip-checkpoints MyTheory
bin/holbuild build --tactic-timeout 5 MyTheory
bin/holbuild build --repl-on-failure MyTheory
bin/holbuild execution-plan MyTheory:my_theorem
bin/holbuild goalfrag-plan MyTheory:my_theorem
bin/holbuild build --force --goalfrag-trace MyTheory
bin/holbuild --json build MyTheory
bin/holbuild --json build --retain-debug-artifacts MyTheory
```

Useful inspection/maintenance commands:

```sh
bin/holbuild context
bin/holbuild build --dry-run MyTheory
bin/holbuild gc
```

Additional commands exist for project-context execution and explicit heap exports:

```sh
bin/holbuild run someScript.sml
bin/holbuild repl
bin/holbuild heap main
```

HOL is resolved from the reserved `dependencies.hol` package, and built HOL
trees are shared under `$HOLBUILD_CACHE/hol-toolchains`. `${HOLBUILD_POLY:-poly}`
is used to configure/build HOL on demand. `holbuild buildhol` warms this cache
explicitly; normal HOL-using commands do this automatically. `holbuild context`
may materialize dependency sources but does not build HOL. `--source-dir PATH` or
`HOLBUILD_SOURCE_DIR` selects the project source
root for manifest discovery while `.holbuild` artifacts are written under the shell's
current directory. `-jN`, `-j N`, or `--jobs N` controls build parallelism for `build`
and for the build phase of `heap` targets; the default comes from local
`.holconfig.toml` `[build].jobs` when set, otherwise from CPU detection as
`max(1, nproc / 2)`. `--force=theory` rebuilds only the requested/default target
nodes from source, `--force=project` rebuilds root-project nodes in the requested
plan, and `--force=full` rebuilds the whole requested plan including dependency
packages; bare `--force` is kept as an alias for `--force=full`. Forced nodes skip
local up-to-date state and global cache restore but still publish cache unless
`--no-cache` is also set. `--no-cache` disables global cache restore/publish while
preserving local `.holbuild` up-to-date checks. Normal non-TTY output suppresses
unchanged node lines; use `--verbose` to show starts/all finishes with elapsed time,
or `--quiet` to suppress per-node success lines. `--maxheap MB` and
`--max-heap MB` pass Poly/ML's maximum heap size to child HOL processes before
`run`/`repl`, matching HOL's requirement that runtime options precede the
subcommand.
`--skip-checkpoints` disables theory checkpoint `.save`/`.ok` creation without
disabling proof instrumentation. By default, checkpoints may be created during
a build; successful builds retain reusable checkpoints for incremental proof
replay, clear stale failed-prefix checkpoints, and rely on `holbuild gc` to bound
old checkpoint families.
`--skip-goalfrag` opts out of modern theorem instrumentation.
The default theorem instrumentation engine is holbuild's proof IR: it parses tactic
syntax from `HOLSourceAST` directly instead of using HOL `goalFrag`, while preserving
exact tactic/list-tactic runtime boundaries for recognized constructs. `--goalfrag`
is deprecated and selects the legacy GoalFrag engine only for comparison/debugging.
The old `--new-ir` build flag is accepted as a deprecated no-op because proof IR is
now the default. holbuild may use HOL parser recovery to produce best-effort
instrumentation and diagnostics, but source parse errors remain build failures.
`--tactic-timeout SECONDS` overrides the per-tactic proof timeout for this invocation;
the default is 2.5 seconds, and `0` disables the timeout. Manifest entry points may
set `[build.root_tactic_timeouts]` by root source path. An entry-point timeout applies
to that entry point's root-package dependency closure; dependency packages still build
without inherited consumer timeouts. If several declared entry points can reach a root-package
script, the script uses the minimum effective timeout. `--tactic-timeout`
overrides entry-point settings for the root package only. `execution-plan THEORY:THEOREM` statically prints the proof-IR plan for one
theorem and exits without building. `goalfrag-plan THEORY:THEOREM` does the same for
the legacy GoalFrag step IR; `goalfrag-plan --new-ir THEORY:THEOREM` is a deprecated
alias for `execution-plan`. Each numbered line is one executable tactic/list-tactic operation;
indentation and body text are formatting only. `--goalfrag-trace`
runs a build, records runtime traces for all instrumented proofs in the child log,
and prints the failed theorem's trace excerpt on failure. Use `--goalfrag --goalfrag-trace`
for legacy GoalFrag traces; otherwise the trace follows the default proof IR engine. Use trace with `--force`
when you need to force source execution for proof-performance/debug inspection.
`--repl-on-failure` serializes the build and, after a theory failure, starts
`hol repl` from the newest failed-prefix checkpoint when available, falling back
to the replay/deps-loaded checkpoint; it requires checkpoints and is not
supported with `--json`.
Combining `--skip-goalfrag` with
`--tactic-timeout`, `--goalfrag-plan`, or `--goalfrag-trace` is an error because
they are implemented by the theorem instrumentation runtime. Proof-engine/checkpoint/timeout
policy affects execution and diagnostics, not final theory artifact action keys. `--json` emits newline-delimited
streaming JSON status/message/error events on stdout; node events include target/source metadata for demuxing parallel builds and do not expose retained log paths by default. `build --retain-debug-artifacts` may be combined with `--json` to retain durable failure logs and report them as `debug_artifacts.log`; these debug artifacts are for human/harness debugging and may contain full goals/output, while JSON failure evidence remains bounded. `--json --goalfrag-trace` is reserved until structured proof trace events exist. `gc` removes stale project-local
`.holbuild` stage/log/checkpoint residue and runs global cache GC using `$HOLBUILD_CACHE`,
`$XDG_CACHE_HOME/holbuild`, or `$HOME/.cache/holbuild`; `gc --clean-only` skips the
cache and `gc --cache-only` skips project discovery/locking and does not require a HOL
toolchain.

See `DESIGN.md` for the intended long-term model: manifest-based package
resolution, project-local `.holbuild/` materialization, action-key invalidation,
project-HOL resolution through the manifest-declared `dependencies.hol`, and an
optional global cache that can share validated dependency state without changing
build semantics. A historical root-HOL manifest sketch lives under
`examples/root-hol/`.

## Dependency-managed projects

holbuild supports schema 2 projects only. HOL itself is an exact git dependency.
Every resolved graph must contain exactly one package named `hol`; that dependency
is materialized and built under `$HOLBUILD_CACHE/hol-toolchains/<key>/hol` and
used as the project HOL toolchain. Upstream HOL does not need a
`holproject.toml`; holbuild uses a built-in manifest for the reserved `hol`
package.

```toml
[holbuild]
schema = 2

[project]
name = "example"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "0123456789abcdef0123456789abcdef01234567"

[dependencies.verifereum]
git = "https://github.com/example/verifereum.git"
rev = "89abcdef0123456789abcdef0123456789abcdef"

[dependencies.holexamples]
from = "hol"
path = "."
manifest = "holexamples.manifest.toml"
```

Dependency management currently supports only exact lowercase 40-character git commit hashes.
There are no branches, tags, version ranges, registry, solver, lockfile, local
overrides, path dependencies, or multiple versions of one package yet. Git dependencies use `git` +
`rev`; `manifest` is not allowed on git dependencies. `from` dependencies use
`from` + `path` + `manifest`; `from` must refer to a direct git dependency in the
same manifest. The `path` selects a source subtree inside the `from` checkout,
while `manifest` is a shim manifest path relative to the declaring package's
manifest root. Both paths must be relative and contain no `..`.

For each root project graph, sources and build artifacts are separated:

```text
.holbuild/src/<package>       # materialized source checkout
.holbuild/packages/<package>  # package build artifacts
```

The reserved `hol` source checkout is special in v1: it is shared globally under
`$HOLBUILD_CACHE/hol-toolchains/<key>/hol` and built there by running
`${HOLBUILD_POLY:-poly} --script tools/smart-configure.sml` and then `bin/build --no-helpdocs`.
A dirty or incomplete cached HOL checkout is rejected until the user removes that
cache entry. Use `holbuild buildhol` to warm this cache explicitly, for example in
CI; normal HOL-using commands do this automatically.

`[holbuild].required_version` is recognized but not implemented; non-empty values
are currently rejected.

## Local configuration and source selection

Local `.holconfig.toml` may set workstation build settings such as jobs, excludes,
and tactic timeout:

```toml
[build]
jobs = 16
exclude = ["worktrees/*"]
tactic_timeout = 10.0
```

Local dependency overrides are no longer supported. Dependency locations are part
of schema 2 manifests and are resolved through exact git revisions plus
`from/path/manifest` shim dependencies. There is no `.holpath`, ambient
`HOLPATH`, user-facing include-path schema, `[dependencies.HOLDIR]`, or runtime
`--holdir` selection in project mode.

For HOL example theories such as `keccakTheory`, declare a `from = "hol"`
dependency with a shim manifest:

```toml
[dependencies.keccak]
from = "hol"
path = "examples/Crypto/Keccak"
manifest = "shims/keccak.toml"
```

`[build].roots` lists package-root-relative source paths for default entry points
when `holbuild build` has no CLI target; root source paths must be discoverable
through `[build].members`. `[build].members` remains the source discovery scope.
When roots are configured, no-target `build` warns about discoverable theory
scripts outside the roots' dependency closure. Optional
`[build.root_tactic_timeouts]` entries are keyed by those same root source paths,
and set entry-point timeout contracts for each root's root-package dependency
closure; shared root-package closure nodes use the minimum timeout from all
declared roots that can reach them. `[build].exclude` may explicitly remove
package-root-relative globbed paths from source discovery; it is for keeping
tests/tool variants out of a build package, not for changing load resolution.
Generated `*Theory.sml` and `*Theory.sig` files are ignored automatically. Both
`holproject.toml` and `.holconfig.toml` reject unknown fields in recognized tables
so typos fail early.

## Notes

The user-facing model should not expose `.uo`, `.ui`, `.dat`, or other HOL
object filenames as targets. `holbuild build MyTheory` is the intended shape.

`holbuild` should produce the same logical artifacts as Holmake (`.uo`, `.ui`,
`.dat`, generated theory files, etc.) while allowing their physical storage to
move under a project-level `.holbuild/` directory. The top-level directory is not
`.hol/` because Holmake/HOL tooling already uses `.hol` conventions. Any
`.hol/objs` directories written by holbuild are nested compatibility remap copies
inside `.holbuild/`, not the project state root. `.uo` and `.ui` files are internal
ML artifacts; users should request logical targets only. The current implementation rejects
ambiguous graphs where two sources export the same logical theory/module name;
a same-package `.sig`/`.sml` pair is one module interface/implementation pair. The
current implementation also writes auxiliary `HOLFileSys` remap copies under `.hol/objs` for
path-sensitive internal loads while preserving canonical artifacts in the project
layout.

Theory scripts are modeled as pure build actions by default: no user-specified
side effects are part of the default v1 contract. If a real action has declared
non-source inputs or must not be cached/skipped, make that explicit:

```toml
[actions.MyTheory]
deps = ["MyProjectLib"]
loads = ["SomeExternalLib"]
extra_deps = ["data/table.txt"]
cache = false
always_reexecute = true
# impure = true is shorthand for no cache and always re-execute
```

`holbuild` uses HOL's `Holdep` machinery to infer normal source dependencies
from old-style `load`/`open` usage and HOLSource headers. `deps` names additional
logical project dependencies when source-level imports are insufficient or
intentionally absent; every listed name must resolve in the manifest/source
graph. `loads` names additional loadable module/library stems for source-implicit
predecessors; matching project modules are resolved in the DAG, otherwise the
name is loaded from the configured HOL toolchain context. `extra_deps` are
package-root-relative filesystem dependencies, such as files, directories, or
simple globs, whose expanded contents are hashed into the action key. Source
files may also declare source-file-relative extra dependencies with a static
literal annotation:

```sml
val () = holbuild_extra_deps ["../data/table.txt"];
```

Source-declared extra dependencies are staged so matching relative filesystem
reads work during the action. `cache = false` disables global-cache
restore/publish for that action. `always_reexecute = true` prevents local
up-to-date skipping and any retained/debug checkpoint replay for that action.
These are escape hatches, not ambient include/search paths. Compatibility:
manifest field `extra_inputs` is accepted as a deprecated alias for `extra_deps`.

Generated HOL source can be declared with pre-discovery generator steps. Generated
outputs are ordinary visible source files, typically under a project `gen/`
directory that is also listed in `[build].members`:

```toml
[build]
members = ["src", "gen"]

[[generate]]
name = "opcodes"
command = ["python3", "scripts/gen_opcodes.py", "data/opcodes.toml", "-o", "gen/opcodeClassScript.sml"]
inputs = ["scripts/gen_opcodes.py", "data/opcodes.toml"]
outputs = ["gen/opcodeClassScript.sml"]
```

Generator `deps` may name earlier `[[generate]]` steps. Holbuild topologically
runs stale or missing generators before source discovery, verifies declared
outputs exist, and then scans/hashes the actual generated source bytes. Declared
outputs may be overwritten; use VCS for review/recovery of user-visible
`gen/` files.

Incremental correctness is action-key based. `holbuild` does not use
`hol buildheap` as its default build primitive; it builds contexts directly by
loading resolved ancestors and, unless `--skip-checkpoints` is set, saving
transient PolyML checkpoints at syntactic boundaries: dependencies loaded,
AST-derived theorem end-of-proof/context boundaries and failed-prefix
proof-navigation state for modern `Theorem ... Proof ... QED` declarations when
goalfrag instrumentation is enabled, and a final post-export context. Successful
builds remove those checkpoint files after writing artifacts and metadata;
failed/interrupted builds may leave them as debug breadcrumbs. `--skip-goalfrag`
removes the theorem proof-navigation checkpoints and tactic timeout path, not the
non-theorem dependency/final-context checkpoint machinery. If a modern theorem
fails after some goalfrag steps, the retained failed-prefix checkpoint can be
reused on the next rebuild by comparing raw proof-body bytes, backing up to the
longest matching current fragment boundary, and replaying the edited suffix.
Simple
theorem-producing forms such as `Theorem name = thm` still build normally but are
not theorem checkpoint boundaries in v1. Explicit `holbuild heap NAME` targets
build their declared logical objects, load the generated theory modules, and save
the requested heap with PolyML SaveState.

The optional global cache stores simple theory semantic artifacts by action key:
`Theory.sig`, `Theory.sml`, and `Theory.dat`. For newer HOL toolchains the cached
`Theory.sml` is the upstream relocatable file; for older toolchains holbuild
rebases its `.dat` reference when publishing. On a cache hit, holbuild materializes
artifacts into local `.holbuild/`, writes local load manifests, and validates hashes before dependents use them. It does not restore
successful-build checkpoint files by default. Successful cache hits refresh the
action manifest mtime for retention, rather than relying on filesystem atime.
`holbuild gc` removes stale project-local build residue and stale global-cache
temporary entries, action manifests, and old unreferenced blobs after 7 days by default.

`holbuild run` and `holbuild repl` generate `.holbuild/holbuild-run-context.sml`
in the project root before loading `[run].loads` and user-supplied arguments.

`hol debug` is deliberately out of scope for the current implementation.
