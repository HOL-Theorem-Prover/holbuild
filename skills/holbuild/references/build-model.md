# holbuild build model

## Source generation

Before source discovery, holbuild runs stale `[[generate]]` steps in dependency order. Each step is keyed by command, declared inputs, declared generator deps, and declared output hashes. Declared outputs are verified after execution, then scanned/hashed as ordinary source files under `[build].members`.

## Dependency inference

holbuild infers source dependencies from the resolved project graph:

1. **Holdep scanning** — `load "X"` / `open X` in source, plus `HOLSource` headers (e.g. `Theory Foo` / `Ancestors Bar`), resolved against the project graph + HOL toolchain `sigobj/`
2. **Action `deps`** — explicit logical dependencies declared in `[actions.*]`
3. **Action `loads`** — explicit loadable module stems; resolved in project DAG first, then HOL toolchain
4. **Companion signatures** — `Foo.sml` implicitly depends on same-package `Foo.sig`

Unresolved `load` directives or `deps` entries → build error.

## Source `use "file"` is rejected

Project build actions cannot use `use "file"`. It's an arbitrary path input outside the resolved package graph. Declare a project module and `load` it instead.

## Build plan

Topological sort of the resolved dependency DAG. Cycle detection with full path reported.

Build order: dependencies loaded first, then dependents. Parallel-ready: `-jN` workers pull from the ready frontier. Nodes with retained failed-prefix checkpoints are prioritized so proof-fix feedback starts earlier.

## Source kinds & artifacts

| Source | Logical name | Generated | Objects | Data |
|--------|-------------|-----------|---------|------|
| `FooScript.sml` | `FooTheory` | `FooTheory.sig`, `FooTheory.sml` | `FooScript.uo`, `FooTheory.ui`, `FooTheory.uo` | `FooTheory.dat` |
| `Foo.sml` (no sig) | `Foo` | — | `Foo.ui`, `Foo.uo` | — |
| `Foo.sig` | `Foo` | — | `Foo.ui` | — |
| `Foo.sml` + `Foo.sig` | `Foo` (companion pair) | — | `Foo.ui`, `Foo.uo` | — |

All artifact paths are under `.holbuild/`, with `HOLFileSys` remap copies under nested `.hol/objs/`.

## Action keys (invalidation)

Each action has an input key derived from:

```
hash(
  schema version,
  action kind (theory/sml/sig),
  logical target name,
  source package + relative path,
  source content SHA-1,
  dependency input keys (recursively),
  declared action policy (deps, loads, extra_deps, cache, always_reexecute),
  extra dependency hashes,
  toolchain key (hol binary + hol.state hashes)
)
```

**Any source byte change** (including comments/proof edits) changes the action key and cascades to all dependents. This is conservative — v1 does not attempt semantic equivalence of generated outputs.

Proof engine/checkpoint/timeout/trace flags are intentionally not final artifact action-key inputs. Switching `--skip-checkpoints`, `--skip-goalfrag`, `--goalfrag`, `--strict-parse`, or root tactic timeout should not rebuild an otherwise up-to-date semantic artifact. Note: `--strict-parse` is still checked before up-to-date/cache restore and can fail early if HOLSourceParser reports recovery.

`extra_deps` are filesystem dependencies outside the normal HOL dependency graph. Manifest entries are package-root-relative; source annotations of the form `holbuild_extra_deps ["../data/table.txt"]` are source-file-relative. Entries may name files, directories, or simple globs. Expanded contents are hashed into the action key, and source-declared entries are staged so matching relative filesystem reads work during the action.

## Up-to-date check

A node is up-to-date when:
1. All output files exist and are non-empty (for theory scripts)
2. Local metadata `.key` file has matching `input_key`

The check is intentionally cheap — does not recompute dependency-context closures for unchanged nodes.

## Cache

Global cache path: `$HOLBUILD_CACHE` > `$XDG_CACHE_HOME/holbuild` > `~/.cache/holbuild/`

Layout:
```
actions/<action-key>/manifest   # cache manifest (sig/sml/dat blob hashes + mldeps)
blobs/<content-hash>            # content-addressed storage
tmp/                            # temporary files
locks/                          # publish + GC locks
```

Cache publish: after a source build, theory artifacts (sig, sml, dat) are stored as blobs. New HOL `Theory.sml` files are relocatable and copied unchanged; old HOL `Theory.sml` files are rebased to the local adjacent `.dat` path before publishing.

Cache restore: on action-key or parent-output key match, blobs are materialized into local `.holbuild/`, `HOLFileSys` remap copies are created, and `.uo/.ui` load manifests are written.

**A bad cache hit is worse than a missed cache hit.** Validation:
- Action key must match
- All referenced blobs must exist with correct content hashes
- Manifest must have no transient stage paths in mldeps
- On any validation failure: warn, delete local outputs, rebuild from source

`--no-cache` disables both restore and publish but preserves local `.holbuild/` up-to-date checks. Force levels skip local up-to-date and cache restore only for the selected node set, and still publish cache unless `--no-cache` is also set: `--force=theory` (or `--force-theory`) forces requested/default target nodes, `--force=project` forces root-project nodes in the requested plan, and `--force=full`/bare `--force` forces the whole requested plan including dependency packages.

GC:
- `holbuild gc [--retention-days N] [--max-checkpoints-gb GB] [--cache-dir PATH] [--clean-only|--cache-only]`
- Default: project clean + global cache GC, 7-day retention, 5GB checkpoint budget
- Project clean removes stale `.holbuild/stage`, `.holbuild/logs`, checkpoint families, and evicts oldest checkpoint families above the size cap
- Cache GC removes stale tmp, expired action manifests, and unreachable blobs, serialized with a POSIX file lock at `locks/gc.lock`
- Interrupted cache GC does not leave a stale lock; older directory-style `locks/gc.lock` entries are removed/replaced automatically
- Legacy `holbuild cache gc` remains cache-only

## Build root/dependency tactic timeout

`--tactic-timeout` applies only to the **root package**. Dependency packages build with no tactic timeout. This prevents a consumer's proof-debug timeout from breaking dependency builds.

## Project write lock

`build`, `heap`, and project-clean `gc` take a coarse project write lock at `.holbuild/locks/project.lock`. Concurrent holbuild processes mutating the same `.holbuild/` are serialized. Stale locks (same host, dead PID) are auto-removed. Permission errors report the lock path.
