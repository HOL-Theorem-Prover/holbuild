# holbuild design

`holbuild` is a project-level build model for HOL4. The goal is to make HOL
projects understandable to humans and agents: explicit manifests, logical
targets, deterministic dependency resolution, hidden implementation artifacts,
and cacheable builds that never require users to reason about the cache.

## Principles

- Build targets are logical names, not files: `FooTheory`, not `FooTheory.uo`.
- `.uo` and `.ui` are internal ML load artifacts. Users must never request them.
- Project mode is manifest based. `Holmakefile` semantics are not interpreted.
- The source tree is user-owned; build products live under project `.holbuild/`.
- Target build contexts should be produced by holbuild from declared sources,
  predecessor checkpoints, or validated shared dependency state. The external
  implementation currently starts child HOL actions from the project HOL declared
  by `[dependencies.hol]` and keys that base state in the toolchain; eliminating
  the prebuilt-base dependency is a root-HOL transition goal, not current behavior.
- The cache is an optional accelerator. Local `.holbuild/` is the authoritative
  materialized build view.
- When unsure, rebuild. A bad cache hit is worse than a missed cache hit.

## Packages and manifests

Every package in the resolved graph has a manifest. A source file can enter the
build graph only through a declared package root. Manifests are schema-checked:
unknown fields in recognized tables are rejected, and the schema marker is
required. The only supported schema is currently schema 2:

```toml
[holbuild]
schema = 2
```

Package roots are declared by one of:

- the current project's `holproject.toml`
- a dependency's own `holproject.toml`
- an explicit shim manifest supplied by the consumer
- the built-in/root HOL manifest

Committed manifests describe what dependency is required. They should not rely on
ambient search paths such as `HOLPATH`, `HOLDIR`, or user include paths. Schema 2
uses exact git commits plus explicit shim manifests for subtrees that do not have
their own `holproject.toml`:

```toml
[dependencies.foo]
git = "https://github.com/acme/foo"
rev = "0123456789abcdef0123456789abcdef01234567"

[dependencies.keccak]
from = "hol"
path = "examples/Crypto/Keccak"
manifest = "shims/keccak.toml"
```

Local dependency overrides and schema 1 path dependencies are intentionally not
part of the current model. `.holconfig.toml` remains schema-checked for local
build settings such as jobs, excludes, and tactic timeout.

## Dependency-managed mode

Schema 2 is the dependency-managed manifest format. It has intentionally no
solver: dependencies are exact git commits, and duplicate package names must
resolve to the same source or resolution fails. A resolved schema 2 graph must
contain exactly one package named `hol`.

```toml
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "0123456789abcdef0123456789abcdef01234567"

[dependencies.examples]
from = "hol"
path = "."
manifest = "holexamples.manifest.toml"
```

Supported dependency forms are deliberately narrow:

- `git` + `rev`, where `rev` is a lowercase 40-character commit hash
- `from` + `path` + `manifest`, where `from` names a direct git dependency in
  the same manifest, `path` selects a source subtree inside that checkout, and
  `manifest` is a shim manifest relative to the declaring package's manifest
  root. Both paths are relative and cannot contain `..`.

Schema 2 rejects path dependencies, local overrides, git manifests, branches,
tags, ranges, registry names, and multiple versions. `[holbuild].required_version`
is an optional `MAJOR.MINOR.PATCH` minimum holbuild version check.

For a root project, all dependency source checkouts are materialized once under:

```text
<root>/.holbuild/src/<package>
```

Dependency package build artifacts live separately under:

```text
<root>/.holbuild/packages/<package>
```

Nested dependency source checkouts use the root graph materialization directory,
not the parent package artifact directory, so resolving `a -> b` creates
`<root>/.holbuild/src/b`, never `<root>/.holbuild/packages/a/.holbuild/src/b`.
For `from` dependencies, the source root is under `.holbuild/src/<from>/<path>`,
but the shim manifest is read from the package that declares the dependency.

The reserved schema 2 `hol` package is the project HOL toolchain. It is
materialized and built at a canonical shared cache path
`$HOLBUILD_CACHE/hol-toolchains/<key>/hol`; upstream HOL does not need a
`holproject.toml`, because holbuild uses its built-in HOL manifest for package
metadata. `context` resolves the path but does not build HOL. Commands that need
HOL use the shared cached tree as the project HOL toolchain and build it on
demand with:

```sh
${HOLBUILD_POLY:-poly} --script tools/smart-configure.sml
bin/build --no-helpdocs
```

A built HOL checkout is expected to contain `bin/hol`, `bin/build`, and
`bin/hol.state`, and must be git-clean ignoring ignored build products. If a
shared cache entry is dirty or incomplete, holbuild refuses to use it until the
user removes it manually. The cache key includes the canonical HOL repository,
revision, Poly/ML command/version, build arguments, and cache format version.

## Main binary and project-HOL helper direction

The intended split is that `bin/holbuild` becomes a portable build coordinator,
not a HOL program. It should own manifest parsing, schema 2 resolution, cache
management, scheduling, artifact movement, and process orchestration. HOL-specific
source understanding should be supplied by the project HOL declared in
`[dependencies.hol]`.

The planned helper is a project-HOL-dependent executable built once per project
HOL/toolchain, for example with HOL heap/executable support after the shared HOL
cache entry exists. Its cache key should include the project HOL key, helper
source/protocol version, and holbuild version. The helper owns HOLSource parsing,
Holdep-compatible dependency extraction, theorem/resume boundary discovery,
`TacticParse` tactic decomposition, and proof-IR/GoalFrag plan generation. The
main binary communicates with it through a stable external protocol such as JSONL
or line records rather than shared SML datatypes.

This split lets the main binary shed compile-time dependencies on `TacticParse`,
`HOLSourceParser`, `HOLSourceAST`, `HOLSource.fileToReader`, `Holdep`, and HOL
load-plan metadata. It also aligns project analysis with schema 2: the HOL used
to understand project sources is the HOL declared by the project, not the HOL
checkout used to compile the holbuild executable.

## Root HOL

Root HOL should be built through holbuild's own model, using an in-tree or
default HOL manifest. HOL is not permanently treated as an opaque legacy build.
The current external implementation still requires a HOL checkout at compile time
so it can reuse HOL implementation pieces. That is a build-time host/tool
dependency, not a project semantic state model. During the transition, holbuild
starts target actions from the project HOL's `bin/hol.state` and includes that
heap in the toolchain key; it
does not copy it into a project-local `_base` checkpoint. The target model
replaces this configured seed with declared bootstrap contexts. Root HOL and user
dependencies should be ordinary manifest-resolved package nodes whose contexts
are produced by holbuild. The initial build context is a declared bootstrap
context; later actions start from predecessor checkpoints or validated shared
dependency state.

Target workflow: after `git pull` in a HOL checkout, `hol build` should be able
to rebuild any invalidated bootstrap/base context hermetically into the checkout's
own `.holbuild/` state, or restore a validated equivalent from the global cache.
It should not require the user to run a separate global HOL rebuild first, and it
should not silently depend on a stale configured heap from before the pull.

The root-HOL transition should be explicit rather than inferred from existing
Holmakefiles. The current prototype reserves package identity `hol` for the
built-in root-HOL manifest, enumerates major source roots as normal manifest
members, and declares bootstrap/tool phases as manifest concepts rather than as
ambient directory conventions. External HOL theory dependencies should
become normal resolved package nodes with the same action-key and cache rules as
user packages; they should not be satisfied by loading a configured full HOL heap.
Any HOL subtree that cannot yet be expressed by the manifest model should use an
explicit shim/adaptor package boundary, not Holmakefile interpretation in project
mode.

The default manifest must also preserve the duplicate-logical-name invariant:
root HOL cannot rely on load-path order to distinguish two `FooTheory` or `Foo`
modules. If historical layout contains such ambiguity, the transition has to make
that identity explicit or keep the subtree outside project mode until resolved.

A source audit of a HOL `src` tree with `HOLSourceParser` plus a
comment/string-aware token pass parsed all 1166 non-generated `.sml` files and
found 356 theory scripts. The scripts contain 23,179 modern
`Theorem ... Proof ... QED` declarations, 1,701 simple `Theorem name = thm`
declarations, 10 `Resume` declarations, and 7 `Finalise` declarations. Literal or
dynamic `load`/`use` calls did not appear in theory scripts; older theorem APIs
are present but much smaller in scripts (`store_thm`: 27 calls, `save_thm`: 23,
`Q.store_thm`: 1). This makes AST-derived modern-theorem checkpointing the
highest-value proof-navigation target for root HOL; simple theorem and
`store_thm`-style declarations should remain ordinary build replay until there is
an AST/proof-state model for them.

The same token pass found non-script examples and libraries with literal/dynamic
`load` calls, dynamic `use` calls, file writes, process calls, and other side
effects. A root-HOL manifest should classify such tooling/examples/tests
explicitly instead of treating them as pure cacheable theory-script actions.

A first root-HOL manifest should therefore start with the stable pure theory and
library package roots that already obey project-mode constraints, and push
non-build tooling/examples/tests behind explicit package/action boundaries.
`examples/root-hol/holproject.toml` is the current sketch: it enumerates HOL
`src/*` members, excludes selftests/examples/tool variants that collide on
logical names, and dry-run planned 1461 HOL package nodes in the audited checkout.
A follow-up regression test dry-runs that sketch against a HOL checkout. Attempting to
source-build core theories against an already-built `bin/hol.state` is intentionally wrong:
that state already contains those theories. Executable root-HOL bootstrap needs
manifest-level bootstrap/checkpoint phases that holbuild can rebuild or restore
on demand, not any preconfigured global HOL heap.
A smaller illustrative fragment:

```toml
[project]
name = "HOL"
version = "bootstrap"

[build]
members = [
  "src/bool", "src/num", "src/list", "src/coretypes",
  "src/pred_set", "src/finite_maps", "src/integer",
]
roots = ["src/hol/HolScript.sml"]
exclude = ["*/selftest.sml", "*/examples/*", "*/theory_tests/*"]

[actions.SomeGeneratedTheory]
loads = ["GeneratedSupportLib"]
extra_deps = ["path/to/generated-input"]
cache = false

[actions.SomeImpureSelftest]
impure = true
```

This is deliberately not a Holmakefile translation. Historical directories that
need dynamic `use`, generated files, external solvers, process/file-system side
effects, source files whose dependencies/loadable libraries are not declared in
the source, or platform-variant modules should either be modeled with explicit
action policy / package boundaries or stay outside the initial project-mode root
package until their inputs, dependencies, and outputs are declared.

## Source model

`[build].members` admits package-root-relative source files or directories.
`[build].roots` lists package-root-relative source paths for default entry
points when `holbuild build` has no CLI target; root source paths must be
included by `[build].members`. This defines the package/project entry point
inside the declared source discovery boundary. If `roots` is omitted, no-target
`build` falls back to all discovered members for transition compatibility. When
roots are configured, no-target `build` warns about discoverable theory scripts
that are outside the roots' dependency closure.
`[build].exclude` is an explicit package-root-relative
glob filter applied during source discovery. It is intended for excluding tests,
examples, or platform variants from a package boundary; it does not add search
paths or change dependency resolution. Generated theory artifacts matching
`*Theory.sml` and `*Theory.sig` are ignored by source discovery by default.

Standard theory convention:

```text
src/FooScript.sml -> FooTheory
```

A theory target owns the logical artifacts:

```text
.holbuild/obj/src/FooTheory.sml
.holbuild/obj/src/FooTheory.sig
.holbuild/obj/src/FooTheory.dat
.holbuild/obj/src/FooTheory.uo
.holbuild/obj/src/FooTheory.ui
```

Theory scripts are modeled as pure build actions by default in v1: no
user-specified side effects are part of the default contract. The manifest can
mark exceptions explicitly:

```toml
[actions.FooTheory]
deps = ["GeneratedSupportTheory"]
loads = ["GeneratedSupportLib"]
extra_deps = ["data/table.txt"]
cache = false
always_reexecute = true
impure = true
```

Source dependencies are inferred with HOL's existing `Holdep` machinery over the
resolved manifest package roots and the configured HOL toolchain objects, so
normal old-style `load`/`open` usage and HOLSource headers become graph edges
without user-facing include paths. `deps` names additional logical project
dependencies when source-level imports are insufficient or intentionally absent;
every listed dependency must resolve to a source in the manifest graph. `loads`
names additional loadable module/library stems for source-implicit predecessors;
matching project modules are resolved in the DAG, otherwise the name is loaded
from the configured HOL toolchain context. `extra_deps` are filesystem
dependencies whose expanded contents are hashed into the action key. Manifest
entries are package-root-relative; source files may also declare source-file-relative
extra dependencies with static literal `holbuild_extra_deps [...]` annotations.
Entries may name files, directories, or simple globs, and source-declared entries
are staged so matching relative filesystem reads work during the action.
`cache = false` disables global-cache restore/publish for the action.
`always_reexecute = true` disables local up-to-date skipping and any retained/debug
checkpoint replay for the action. `impure = true`
is a conservative shorthand for no cache and always re-execute. These fields are
intended for audited exceptions such as generated data, root-HOL SML modules with
explicit predecessor requirements, source-implicit external libraries, or
tool/example side effects; they are not include paths and do not make arbitrary
`use "file"` directives resolvable.

## Dependency resolution

Resolution happens before cache lookup.

```text
manifest graph + source index + imports -> resolved dependency graph
```

The resolved graph must not depend on cache contents. The same project should
resolve the same way with an empty cache.

Important invariant:

```text
one logical theory/module name -> one resolved artifact in a build graph
```

This rejection is intentional. HOL/PolyML process state has global theory and ML
module names; two packages exporting different `FooTheory` or `Foo` modules
cannot safely coexist by relying on load-path order. `holbuild` should reject the
resolved graph before build execution instead of choosing whichever artifact
happens to appear first. A same-package `.sig`/`.sml` pair is one SML module
interface/implementation pair, not a cross-package ambiguity.

## Parallel builds

`holbuild` accepts global job control:

```text
holbuild -j4 build FooTheory
holbuild --jobs 4 heap main
```

The build scheduler runs over the resolved DAG inside one holbuild process.
Actions become ready only after all direct project dependencies complete. Each
action builds in a private staging directory and installs its own outputs/metadata;
dependents are scheduled after successful completion. The parallel scheduler must
not do a separate serial "all nodes up to date" preflight unless those results are
reused by the build phase: large incremental builds often have hundreds of
unchanged prefix nodes before the first dirty frontier, and duplicating those
checks defeats `-j` before workers start. The scheduler should precompute direct
and reverse dependency edges once, maintain ready nodes with remaining-dependency
counts, and treat up-to-date/cache/source outcomes uniformly as completed DAG
nodes. Separate holbuild processes must not concurrently mutate the same project
`.holbuild/`; build and heap commands take a coarse project write lock with an
owner file for diagnostics. If the lock owner is on the same host and its recorded
process no longer exists, holbuild removes the stale lock and retries. The default
job count may come from local config or CPU detection because HOL/PolyML heaps can
be memory-heavy and path-sensitive artifact installs need conservative discipline.
Heap targets use `-j` for their declared object build phase, then export the heap
serially from the resolved holbuild-produced base context.

## Artifacts and local materialization

Holmake and HOL tooling already use `.hol` conventions, especially `.hol/objs`
for `HOLFileSys` remapped object paths. To avoid top-level collisions with
Holmake-managed source trees, holbuild owns `.holbuild/` as its project-local
state directory. Any `.hol/objs` directories written by holbuild are nested inside
`.holbuild/` artifact directories as compatibility remap copies, not as the
project root convention.

Project `.holbuild/` is the complete local build view:

```text
project/.holbuild/
  obj/          local ML/theory artifacts, including theory .sig/.sml/.dat bundles
  dep/          action metadata and dependency facts
  heap/         project-local heaps
  checkpoints/  materialized PolyML SaveState checkpoints
```

Path-sensitive files are generated or rebased for this local layout. Older HOL
`Theory.sml` files may contain paths and are rebased when installed; newer HOL
`Theory.sml` files locate their adjacent `.dat` file and are copied unchanged.
Project SML/SIG modules are
built as internal load manifests: `load "Module"`, `open Module`, and qualified
module references are resolved through HOL's `Holdep` scanner against the project
graph plus the configured HOL toolchain objects, not against ambient include
paths. Generated theory modules also get internal load manifests from HOL's
recorded theory metadata (`Theory.current_ML_deps` /
`Theory.add_ML_dependency`), so legitimate generated
`local open ...` dependencies are preserved without parsing generated SML text.
Source-level `use "file"` is rejected in project build actions in v1 because it
is an arbitrary path/input outside the resolved package graph; declare a project
module and `load` it instead. Generated HOL source is modeled by manifest
`[[generate]]` steps that run before source discovery. Their package-root-relative
outputs are visible source-tree files (commonly under `gen/`), may be overwritten,
and are scanned/hashed as ordinary sources after generation. Generator keys decide
whether to rerun the generator; theory/action keys still use the actual generated
source bytes. `.sml` files get a `.uo` plus an empty companion `.ui` unless a real
`.sig` companion exists, and same-name signatures are implicit dependencies of
their implementation. HOL's current
`HOLFileSys` remaps `.uo`/`.ui` and files ending in
`Theory.dat`/`.sml`/`.sig` through `.hol/objs`, so a project-level layout may
need auxiliary internal load paths or rewritten non-semantic load copies while
preserving canonical artifacts.

## Invalidation and action keys

Each build action has an input key derived from resolved facts, not raw paths:

```text
input_key = hash(
  holbuild action schema version,
  action kind,
  logical target,
  source package id + relative path,
  source content hash,
  resolved dependency input keys,
  relevant manifest action policy, declared action deps/loads, and extra dependency hashes,
  toolchain/base-context key,
  platform/ML-system facts where relevant
)
```

HOL's existing `Holmake --cachekey` work is a useful precedent: it avoids raw
path ordering, ignores path-sensitive `.uo`/`.ui` files, substitutes theory
`.uo`/`.ui` dependencies with the corresponding `.dat`, and sorts by filename
plus content hash. That points at an important distinction for `holbuild`:

```text
input key   = can I reuse a cached build for these sources and resolved deps?
output key  = what semantic artifact did this build actually produce?
```

For v1, downstream invalidation also uses dependency input keys. A target's
input key is effectively the hash of its own source content plus the DAG heads
(input keys) of its resolved dependencies, along with toolchain/config facts.
Therefore any source byte change — including proof edits or comments — changes
that action's input key and changes the input keys of dependents. This is
conservative and avoids relying on semantic equivalence of generated theory
outputs.

A build may record output hashes, such as `FooTheory.dat`, generated theory
interface/source hashes, or checkpoint byte hashes, for diagnostics and future
cache analysis. V1 must not use output hashes to skip rebuilding dependents.

Different absolute paths under the same declared root may normalize to the same
root-relative identity. Arbitrary outside-root paths are rejected or treated as
uncacheable.

If the same input key produces different output keys, that indicates
nondeterminism or undeclared inputs; the safe response is to warn and disable
cache use for that action.

## Global cache

The global cache is optional and immutable:

```text
~/.cache/holbuild/
  actions/<action-key>/manifest
  blobs/<content-hash>
  tmp/
  locks/
```

Cache lookup happens only after resolution and action-key computation.

```text
if exact action key validates:
  materialize into local .holbuild/
else:
  build from source into local .holbuild/
  optionally publish bundle to cache
```

The cache should store semantic bundles, shareable state bundles, and metadata.
Local path-sensitive files are regenerated or rebased during materialization. The
prototype currently publishes simple theory bundles containing adjacent
`Theory.sig`, `Theory.sml`, and `Theory.dat` files. The target model also
publishes validated successor-ready checkpoint state for shareable dependencies.
On a cache hit, holbuild copies blobs into local `.holbuild/`, writes local
`.uo/.ui` load manifests plus `HOLFileSys` remap copies, and materializes the checkpoint/state
needed by downstream actions. Missing or corrupt cache entries warn and fall back
to source build. Cache manifests that contain transient `.holbuild/stage` mldeps
are removed under the per-action cache lock as soon as restore detects them, so
an interrupted fallback rebuild should not warn repeatedly about the same known-bad
entry. A successful cache hit refreshes the action manifest mtime for retention;
this avoids relying on filesystem atime policy.

Materialization preference for v1:

```text
1. reflink / copy-on-write clone
2. copy
```

Avoid hardlinking cache blobs into project `.holbuild/`: even if cache blobs are meant
to be immutable, project outputs are the local materialized build view and should
not be able to mutate global cache contents by accident. Build actions must never
mutate installed cache-derived outputs in place. Write
to staging locations and atomically install validated outputs. Concurrent source
builds for the same action key serialize cache publication with a per-action
cache lock; losing publishers skip publication because the local source build has
already succeeded. Cache materialization still treats any missing, locked, or
corrupt entry as a cache miss and falls back to source.

Shared dependency state is keyed by the same resolved action key and
base-context key as the semantic artifacts, not by raw `.save` bytes. Two
projects depending on the same package revision/toolchain can therefore
materialize the same dependency final-context state into their own `.holbuild/`
views. The state bundle is still only an accelerator: if validation, relocation,
or toolchain checks fail, holbuild rebuilds the dependency from source or earlier
validated state.

## GC / local-state cleanup

Project-local residue and global cache retention should be bounded by default. Initial policy:

```text
retain project-local residue and global cache entries for 7 days by default
```

Expose one user-facing maintenance command:

```text
holbuild gc
holbuild gc --retention-days 7
holbuild gc --cache-dir /path/to/cache
holbuild gc --clean-only
holbuild gc --cache-only
```

By default `holbuild gc` takes the project lock, removes stale project-local
`.holbuild/stage`, `.holbuild/logs`, and checkpoint artifacts, then runs global
cache GC. `--clean-only` skips cache GC. `--cache-only` skips project discovery
and locking, so it works without a HOL toolchain. The cache root is
`$HOLBUILD_CACHE`, else `$XDG_CACHE_HOME/holbuild`, else `$HOME/.cache/holbuild`.

Future in-tree spelling may be:

```text
hol build --gc
```

GC should remove stale tmp dirs, remove old action manifests by refreshed mtime,
mark blobs still reachable from non-expired manifests, and sweep old unreferenced
blobs. Races with builds should degrade to cache misses and source rebuilds. The prototype
uses a cache-local `locks/gc.lock` directory to avoid concurrent GC runs.

## Heaps and checkpoints

PolyML heap checkpoints and `.save` files are materialized as local project
artifacts:

```text
.holbuild/heap/          optional user-requested exported heaps
.holbuild/checkpoints/   local PolyML replay checkpoints
```

Explicit heap targets are requested with `holbuild heap NAME` from `[[heap]]`
manifest entries. They are exported artifacts, not the normal incremental-build
primitive: holbuild first builds the declared logical objects, then starts from
the resolved holbuild-produced base context, loads generated theory modules in
resolved build-graph order, and saves the requested heap with PolyML SaveState.

Heaps requested by users remain project-local exported artifacts. Checkpoints are
transient build/debug state. Normal successful theory builds may create them
while running, but remove them after logical artifacts and metadata are written.
Raw checkpoint bytes are never the semantic identity; they are local replay/debug
breadcrumbs for an already-resolved graph, not retained outputs.

`holbuild` should not use `hol buildheap` as the normal incremental-build
primitive. `buildheap` snapshots a process after loading a closure of `.uo`
modules. In holbuild, loading ancestors in resolved topological order naturally
constructs the same dependency context inside the build process; any checkpoint
after that load is just another syntactic checkpoint, not a separate closure
cache concept.

The relevant checkpointing model is the `Holmake --dumpheap` design: while a
theory script executes, the prover/runtime saves PolyML states at syntactic
boundaries such as:

```text
deps_loaded.save         after resolved ancestors are loaded in topological order
<thm>_context.save       after the theorem has been stored in the theory context
<thm>_end_of_proof.save  after goal-fragment proof replay, for navigation
final_context.save       after the script is successor-ready
```

`final_context.save` must mean successor-ready, not merely immediately after
`export_theory()`. The generated `FooTheory.sig/sml` module must be loaded before
saving so dependents can open/use `FooTheory` when starting from the checkpoint.

Those checkpoints answer a different question from action keys:

```text
action key/cache:        can this whole script action be skipped?
syntactic checkpoint:    if the action changed, where can replay resume?
```

A retained/debug checkpoint is replay-eligible only under the same resolved
dependency context, toolchain/base context, and checkpoint schema. Raw `.save`
bytes are diagnostic only and must not be used as stable semantic keys. The
default build does not retain successful checkpoints or materialize checkpoints
from the global cache; cache restore recreates only logical theory artifacts and
internal load manifests.

Proof-edit incrementality should not key failed-prefix checkpoints by the full
proof body hash. That would invalidate exactly the state a proof author needs
after editing a failing suffix. Instead, a failed goalfrag proof may retain a
proof-navigation checkpoint plus metadata containing the raw source bytes from
the theorem/proof start through the last successful fragment boundary, the number
of successful goalfrag history steps, and the initial theorem goal/statement
fingerprint. On the next rebuild, holbuild compares the retained raw byte prefix
with the current theorem source, chooses the last current fragment boundary whose
raw bytes still match, loads the failed-prefix checkpoint, calls goalfrag
`backup_n` for the difference between saved and current common-prefix step
counts, and replays the edited suffix. Hashes remain guardrails for dependency
context and initial goal compatibility; raw byte-prefix comparison decides the
usable proof prefix.

The prototype currently instruments AST `HOLTheoremDecl` declarations, i.e.
modern goal/proof forms such as `Theorem ... Proof ... QED`. It parses the HOL
source AST before expansion to ML, uses theorem/tactic spans to insert a theorem
marker before expansion, then runs ordinary proof bodies through a shared SML
goalfrag runtime helper. That helper owns tactic parsing, step planning,
proof-manager/`goalFrag` execution, timeout wrappers, checkpoint saves, prover
hook state, and failure diagnostics. Generated per-theory source contains only
loads, runtime installation/configuration, theorem boundary calls, and original
source slices.

GoalFrag is the executable stepping IR. Holbuild does not maintain a second
semantic tactic AST for proof execution. The runtime lowers HOL's `TacticParse`
AST through `TacticParse.linearize` into a thin, holbuild-owned `goalfrag_step`
list: open/mid/close structural operations, ordinary tactic `expand`, list-tactic
`expand_list`, and temporary select markers that are merged into the surrounding
branch shape. Each step carries the raw source label and source end position used
for timeout messages, failed-fragment source context, and failed-prefix replay.
Execution then dispatches directly to `goalFrag.open_*`, `goalFrag.next_*`,
`goalFrag.close_*`, `goalFrag.expand`, or `goalFrag.expand_list`. Normal tactic
chains such as `A >> B >> C` should stay as independent `expand` steps; ordinary
branch/list/select syntax should introduce GoalFrag structure. Avoid name-based
tactic heuristics for atomicity: opaque tactic calls are leaves, and
shape-specific merging should be justified by the parsed branch/list/select form.
Current compatibility exceptions are `REVERSE` combined with branch/list forms
and `THENL`/`TACS_TO_LT` list tacticals, which are still kept grouped because
fully structural replay can trip GoalFrag validation shape accounting even when
all goals are solved; treat these as narrow runtime limitations to remove, not as
precedent for broad branch-body atomicity.

Attributed proofs and declarations with no parsed tactic body use a conservative
whole-tactic prover path. Normal theorem bodies should not fall back to timing the
entire theorem as one coarse tactic; if they need coarser treatment for a
validation-shape bug, the runtime should merge the specific branch/list/select
shape rather than hide the whole theorem inside `TAC_PROOF`. The
`<thm>_end_of_proof.save` checkpoint is saved before `drop_all`, so it preserves
proof-manager history for navigation; `<thm>_context.save` is saved after the
expanded theorem declaration stores the theorem in the theory context. If a later
source edit leaves an earlier retained theorem prefix byte-identical and the
resolved dependency context still matches, a dirty/debug rebuild can load the
nearest valid theorem-context checkpoint and replay only the suffix to
`export_theory()`. End-of-proof checkpoints are proof-navigation states, not
successor-ready contexts, and are not used for dependency replay.

Proof instrumentation is separable from PolyML checkpoint creation and
retention. By default, holbuild may create several local checkpoint classes while
executing a theory action, then removes them after successful artifact/metadata
writes: `deps_loaded` after loading resolved dependencies, theorem proof states
for modern AST `Theorem ... Proof ... QED` declarations, failed-prefix
proof-navigation state after instrumented proof failures, and a final post-export context.
`--skip-checkpoints` disables all `.save`/`.ok` creation while still running
modern theorem proofs through the selected instrumentation runtime. `--skip-proof-steps`
opts out of theorem instrumentation: with checkpoints still enabled, the build can
still save and consult `deps_loaded` and save the final context, but there are no
theorem-context/end-of-proof/failed-prefix proof-navigation checkpoints and no tactic
timeout enforcement for that build. The final context is currently a transient
debug/successor breadcrumb, not a downstream canonical load context.

When proof steps are enabled, holbuild applies a tactic timeout to each
executable proof step, and to the conservative whole-tactic path used for
attributed/opaque proof cases. The proof-step engine is holbuild's proof IR: it still
uses HOLSource parser recovery, but lowers `HOLSourceAST.exp` directly.
`--goalfrag` and `goalfrag-plan` have been removed. The old `--new-ir` build flag is
accepted as a deprecated no-op because proof IR is now the default. The CLI default is
2.5 seconds per tactic step;
`--tactic-timeout SECONDS` overrides all manifest timeout policy for the invocation, and
`--tactic-timeout 0` disables it. Without a CLI override, `[build].tactic_timeout` sets
the package default and `[build.root_tactic_timeouts]` may set per-entry-point timeout
contracts keyed by `[build].roots` source paths. Entry-point contracts apply to the
root-package portion of the build dependency closure; dependency packages do not inherit a
consumer's proof-debug timeout. If multiple declared entry points can reach the same
root-package script, the script uses the minimum effective timeout. This timeout is a
property of the declared entry point graph, not of the current request, except that
`--tactic-timeout` overrides root-package entry point timeouts for the invocation. Timeout policy is not part of final artifact action keys,
but local metadata/cache records the timeout a successful build satisfied; a success under
60s may satisfy a later 180s request, while a success under 180s does not satisfy a later
60s request.
`execution-plan THEORY:THEOREM` and `--trace-steps` are debugging/inspection paths.
`holbuild execution-plan THEORY:THEOREM` is static inspection for proof steps: it
discovers sources, finds the named theorem in the named theory script, pretty-prints
the executable proof-IR step plan, and exits without acquiring the project build lock,
planning dependencies, consulting cache/up-to-date state, or executing the proof.
The pretty form must remain faithful to the IR: each numbered line is one executable tactic/list-tactic operation; indentation
and parenthesized body text are formatting only. For example, a `>>~-` source
fragment may display as one numbered `list_tac Q.SELECT_GOALS_LT_THEN1 ...` step
when that is what the runtime executes, not as an ordinary `>-` branch. The goal
is that a developer can debug a divergence by inspecting the plan and knowing the
HOL tactic combinator semantics.

`--trace-steps` executes the build and records runtime plans plus before/after
trace lines for all instrumented proofs in the child log. On failure, holbuild
prints the failed theorem's trace excerpt with per-fragment elapsed time and
open-goal counts. Use `--force` with trace when the artifact is already up to date
and you need source execution; `--force` bypasses local up-to-date checks and
global cache restore without disabling cache publication. `--repl-on-failure`
serializes the build and starts `hol repl` from the newest failed-prefix
checkpoint when a theory action fails, falling back to the replay/deps-loaded
checkpoint if no failed-prefix state is available; it requires checkpoints and is
not an action-key input. Planning/tracing are not action-key inputs. Because
timeouts and tracing only exist in the proof-step runtime,
`--skip-proof-steps --tactic-timeout ...`, `--skip-proof-steps --trace-steps ...`, and
`--skip-proof-steps --repl-on-failure ...` are rejected instead of silently ignoring
the request. In JSON mode, failure evidence is structured and bounded for agent/tool
consumers by default; `build --retain-debug-artifacts` is an explicit human/harness
debugging mode that retains durable failure logs and reports them as
`debug_artifacts.log`, without retaining internal stage directories. Proof engine, checkpoint creation, tactic timeout, planning, and tracing are execution/debug policy,
not final artifact semantics. They must not be included in the final theory
action key or local metadata comparison for `.uo/.ui/.dat`: switching
`--skip-proof-steps`, `--skip-checkpoints`, or root tactic timeout should not rebuild
an otherwise up-to-date semantic artifact. If goalfrag execution and plain source
execution produce different final artifacts or success/failure behavior, that is
an instrumentation bug to fix, not a separate artifact identity. Checkpoint
validity remains separate and is represented by checkpoint paths plus `.ok`
metadata keyed by dependency context and source prefix. On timeout, holbuild
reports the timed-out tactic and does not retry the script through the plain
non-goalfrag fallback, since that would remove the only timeout guard. Current
production dogfooding has shown that some legitimate root-project simplification
steps exceed 30s; use `--tactic-timeout 0` for full semantic production builds
and a larger finite timeout such as 60s for root timeout smoke testing when
appropriate.

Other theorem-producing syntax, such as simple `Theorem name = thm` declarations,
`store_thm` calls, `Resume`, or `Finalise`, is not checkpoint-instrumented in v1.
Those declarations still execute during normal source builds/replays, but they do
not produce theorem-context/end-of-proof checkpoints unless later modeled from the
AST with correct proof-manager state. Do not add ad hoc text-scanned wrappers for
these forms.

## Legacy transition

Existing projects can keep using Holmake until they opt into project mode. In
project mode:

```text
- no `.holpath`
- no `HOLPATH` ambient dependency search
- no user-facing INCLUDES
- no Holmakefile interpretation
- dependencies require manifests or explicit shims
- user-specific dependency locations go in uncommitted `.holconfig.toml`
```

A minimal legacy-standard project manifest can be as small as:

```toml
[project]
name = "foo"

[build]
members = ["."]
```

If a project relies on custom Holmakefile behavior, it should either stay on
legacy Holmake during the transition or provide manifest-level declarations for
those behaviors when the schema grows them.
