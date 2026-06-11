# Dependency management

holbuild uses schema 2 dependency management only. A resolved project graph must contain exactly one package named `hol`; this package is the project HOL toolchain and is declared with an exact git revision.

## Project HOL

```toml
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "<exact-40-character-commit>"
```

The `hol` dependency is special:

- it must point at the canonical HOL repository
- it uses an exact commit hash, not a branch/tag/range
- upstream HOL does not need a `holproject.toml`; holbuild uses its built-in HOL manifest for package metadata
- built HOL trees are shared under `$HOLBUILD_CACHE/hol-toolchains/<key>/hol`
- `${HOLBUILD_POLY:-poly} --script tools/smart-configure.sml` and `bin/build --no-helpdocs` are used to build a missing shared entry
- dirty, broken, or incomplete shared HOL entries are rejected until removed manually

Use `holbuild buildhol` to warm this cache explicitly. Normal commands that need HOL build/reuse it automatically.

## Git dependencies

```toml
[dependencies.foo]
git = "https://github.com/acme/foo"
rev = "0123456789abcdef0123456789abcdef01234567"
```

A git dependency is materialized under:

```text
.holbuild/src/foo
```

and its package artifacts live under:

```text
.holbuild/packages/foo
```

Git dependencies must have their own `holproject.toml`; a `manifest` field is not allowed on a direct git dependency.

## From dependencies and shim manifests

Use `from` dependencies for source subtrees inside a direct git checkout, including subtrees of `hol` such as examples.

```toml
[dependencies.keccak]
from = "hol"
path = "examples/Crypto/Keccak"
manifest = "shims/keccak.toml"
```

```toml
# shims/keccak.toml
[holbuild]
schema = 2

[project]
name = "keccak"

[build]
members = ["."]
```

`from` must name a direct git dependency in the same manifest. `path` selects a package-root-relative subtree inside that checkout. `manifest` is relative to the declaring package's manifest directory. Both paths must be relative and contain no `..` components.

## Unsupported dependency forms

holbuild no longer supports:

- schema 1
- `[dependencies.HOLDIR]`
- `--holdir`, `HOLDIR`, or `HOLBUILD_HOLDIR` as project/runtime HOL selection
- path dependencies
- local dependency overrides in `.holconfig.toml`
- dependency path environment expansion
- branch/tag/range version specifications
- lockfiles, registries, solvers, or multiple versions of one package

`.holconfig.toml` still supports local build settings such as `[build].jobs`, `[build].exclude`, and `[build].tactic_timeout`, but not dependency overrides.

## Dependency resolution flow

1. Parse the root schema 2 `holproject.toml` and local `.holconfig.toml` build settings.
2. Validate that the resolved graph has exactly one `hol` dependency.
3. Materialize direct git dependencies under `.holbuild/src/<package>`; `hol` is resolved to the shared global HOL cache path.
4. Resolve `from/path/manifest` dependencies to subtrees of direct git dependencies.
5. Parse each dependency's manifest recursively.
6. Validate that dependency manifest `project.name`, when present, matches the dependency key name, except for the built-in `hol` manifest.
7. Assign dependency package artifacts under `.holbuild/packages/<package-name>`.
8. Build the full resolved graph.

## Transitive dependencies

Dependencies of dependencies are resolved automatically. No need to declare transitive deps in the root project — they're discovered through manifests.

## Duplicate name rejection

The resolved graph must have exactly one artifact per logical name. If two packages export the same `FooTheory` or `Foo` module, holbuild rejects the graph before building.

A same-package `.sig`/`.sml` pair is one SML module interface/implementation pair and is not a cross-package ambiguity.

## Source-level imports

`load "Foo"` and `open Foo` in source files are resolved against:

1. Project graph (matched by logical name)
2. The project HOL toolchain `sigobj/` (external HOL libraries)

If a `load` directive can't be resolved to either, it's an error. Unresolved `[actions.*].deps` entries are also errors.

## Dependency build policy

Dependencies build with default settings:

- theorem instrumentation/proof IR enabled unless globally skipped
- no tactic timeout inherited from the consumer
- checkpoints enabled unless `--skip-checkpoints` globally disables them

Dependency package artifacts are under the root project's `.holbuild/packages/<package>/`, not inside the dependency's source checkout.
