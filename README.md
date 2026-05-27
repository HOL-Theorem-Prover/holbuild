# A modern, human- and agent-friendly build system for HOL4

`holbuild` is a project-aware build frontend for HOL4. The implementation is fairly stable; the `holproject.toml` format is still under active design while feature requests settle before eventual upstreaming into HOL.

This repository is the external development vehicle for the design in https://github.com/HOL-Theorem-Prover/HOL/issues/1916: `holproject.toml` as a project manifest, logical build targets, project-level artifacts, and a future in-tree `hol build` implementation.

## Current scope

The current implementation intentionally focuses on:

- reads and schema-checks the nearest `holproject.toml`
- establishes a shared project context for `build`, `run`, and `repl`
- reuses HOL's existing SML TOML parser from `$HOLDIR/tools/Holmake/toml`
- accepts logical build targets such as `MyTheory`, not object filenames such as `MyTheory.uo`
- owns source discovery and maps outputs to project-level `.holbuild/`
- infers theory/module dependencies with HOL/Holdep machinery over the resolved project graph and orders build plans
- parses transitive dependency manifests and local `.holconfig.toml` path overrides
- materializes dependency plans under project `.holbuild/deps/<package>/`
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
- delegates project-context execution to `$HOLDIR/bin/hol run` / `hol repl`

The external implementation requires a HOL checkout or installation via `HOLDIR` so it
can reuse HOL tooling. Current code still starts actions from `$HOLDIR/bin/hol.state`
and includes that heap in the toolchain key; it does not create a project-local
copy under `.holbuild/checkpoints/_base`. The target design replaces this
configured seed with bootstrap/checkpoint state that `hol build` can rebuild or
restore hermetically under `.holbuild/` after `git pull`. See `DESIGN.md`.

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
default. Override with `PREFIX`, `BINDIR`, or `DESTDIR` if needed. Runtime HOL
selection still uses `--holdir PATH`, `HOLBUILD_HOLDIR`, or `HOLDIR`.

The compiler loads HOL's existing SML TOML parser from `$(HOLDIR)` and embeds it
in `bin/holbuild`. Tests live under `tests/cases/*/test.sh` so they can move into
HOL's selftest layout with minimal reshaping; `tests/run.sh` is the repo-local
runner and can run cases in parallel with `HOLBUILD_TEST_JOBS`. Current cases
cover simple theory builds, package overrides, local build excludes, build roots,
cross-package SML load resolution, dependency cycle rejection, conservative
invalidation, checkpoint replay/recovery, process cleanup on interrupt,
logical-name conflict rejection, cache restoration/corruption/concurrency/GC,
parallel diamonds, same-project write locking, explicit heaps, object-target
rejection, manifest schema validation, status output, root/dependency tactic
timeout policy, and generated theory dependency/path stability.

## Usage

```sh
export HOLBUILD_HOLDIR=/path/to/HOL
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

`--holdir PATH` can be used instead of `HOLBUILD_HOLDIR` at runtime for HOL
commands. `--source-dir PATH` or `HOLBUILD_SOURCE_DIR` selects the project source
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
root-HOL migration through an explicit/default HOL manifest, and an optional
global cache that can share validated dependency state without changing build
semantics. A root-HOL manifest sketch lives under `examples/root-hol/`.

## Example `holproject.toml`

```toml
[holbuild]
schema = 1

[project]
name = "example"
version = "0.1.0"

[build]
members = ["src", "examples"]
roots = ["src/MainScript.sml"]
exclude = ["*/selftest.sml", "*/examples/*"]

[dependencies.foo]
git = "https://github.com/acme/foo"
rev = "abc123"

[actions.MyTheory]
deps = ["MyProjectLib"]
loads = ["SomeExternalLib"]
extra_deps = ["data/table.txt"]
cache = false

[run]
heap = "build/main.heap"
loads = ["MyProjectLib"]

[[heap]]
name = "main"
output = "build/main.heap"
objects = ["MyProjectLib"]
```

## Local dependency overrides

Use an uncommitted `.holconfig.toml` when a declared dependency lives at a
different local path on your machine or when a workstation needs local build
settings:

```toml
[overrides.foo]
path = "../foo-dev"

[build]
jobs = 16
exclude = ["worktrees/*"]
```

The override changes only where the package is found locally. The package still
needs its own `holproject.toml` or an explicit shim manifest from the consumer,
except for the reserved `[dependencies.HOLDIR]` package, which uses holbuild's
built-in root-HOL manifest and the runtime `--holdir`/`HOLBUILD_HOLDIR` path.
The built-in `HOLDIR` manifest intentionally models the root HOL sources only;
it excludes examples, tests, manuals, and non-default tool variants. If a project
needs a HOL example theory such as `keccakTheory` from
`$HOLDIR/examples/Crypto/Keccak`, declare that subtree as a separate dependency:

```toml
# holproject.toml
[dependencies.HOLDIR]

[dependencies.HOL_keccak]
path = "$HOLDIR/examples/Crypto/Keccak"
manifest = "shims/keccak.toml"
```

```toml
# shims/keccak.toml
[project]
name = "HOL_keccak"

[build]
members = ["."]

[dependencies.HOLDIR]
```

A downstream package can depend on `HOL_keccak` directly, or inherit it
transitively through another dependency's manifest. There is no `.holpath`,
ambient `HOLPATH`, or user-facing include-path schema in project mode;
dependency locations are resolved through manifests plus local overrides. An
`[overrides.foo].path` takes precedence over `[dependencies.foo].path`; when an
override exists, the manifest's `path` field is not env-expanded, so local
config can mask a committed `path = "$FOO"` even when `FOO` is unset. Explicit
`[dependencies.foo].manifest` entries are still used with an overridden path and
their env refs must expand. Path fields for dependency manifests/paths and local
override paths support only `$VAR` and `${VAR}` environment variable
substitution; unset variables are errors. `[build].roots` lists
package-root-relative source paths for default entry points when `holbuild build`
has no CLI target; root source paths must be
discoverable through `[build].members`. `[build].members` remains the source
discovery scope. When roots are configured, no-target `build` warns about
discoverable theory scripts outside the roots' dependency closure. Optional
`[build.root_tactic_timeouts]` entries are keyed by those same root source paths,
and set entry-point timeout contracts for each root's root-package dependency closure;
shared root-package closure nodes use the minimum timeout from all declared roots that can reach them.
`[build].exclude` may explicitly remove package-root-relative globbed
paths from source discovery; it is for keeping tests/tool variants out of a build
package, not for changing load resolution. Generated `*Theory.sml` and
`*Theory.sig` files are ignored automatically. Both `holproject.toml` and
`.holconfig.toml` reject unknown fields in recognized tables so typos fail early.

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
