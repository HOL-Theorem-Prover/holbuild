# Dependency management

## Declaring ordinary dependencies

```toml
# holproject.toml
[dependencies.foo]
git = "https://github.com/acme/foo"
rev = "abc123"
path = "../foo"
```

Fields per dependency:

| Field | Required | Purpose |
|-------|----------|---------|
| `git` | No | Source repository URL (informational in v1) |
| `rev` | No | Git commit (informational in v1) |
| `path` | No | Local path to dependency root (relative to manifest dir; `$VAR`/`${VAR}` expanded only when no override masks it) |
| `manifest` | No | Explicit manifest file path when dep lacks `holproject.toml` (relative to consumer manifest dir; env expanded when present) |

Ordinary dependencies need a local `path` or `.holconfig.toml` override and must
resolve to a manifest. HOL itself is the implicit exception described below.

## Implicit HOL checkout

HOL itself is not an ordinary manifest dependency that users must declare. Every
project is parameterized by a selected HOL checkout:

1. `--holdir PATH`
2. `HOLBUILD_HOLDIR`
3. `HOLDIR`

That checkout supplies both the HOL executable/toolchain and an implicit source
package. The implicit package exposes:

```toml
[project]
name = "HOL"

[build]
members = ["src", "examples"]
# no roots
# default excludes: selftests and developer throwaway examples
```

The implicit package excludes selftests and developer throwaway examples by
default, since those files are not intended downstream dependencies and otherwise
clutter the logical namespace.

The bootstrap boundary is `hol.state0`, used through `hol --bare`. The bare heap
provides the primitive theory base (`minTheory`, `boolTheory`) and the SML modules
reported by `Meta.loaded ()` in a bare session. Other HOL sources should be
available as normal holbuild targets.

For non-bare theory scripts, holbuild reconstructs the normal full HOL environment
from source-built dependencies rather than starting from `hol.state`:

```sml
load "bossLib";
load "holTheory";
open bossLib;
```

from a bare session reproduces the loaded-module set and theory ancestry of a
normal full HOL session. Thus `bossLib` plus `holTheory` are the source-built
standard-environment roots for non-bare theories. Holbuild stores this as a
managed checkpoint keyed by their action keys plus the bare toolchain key so
repeated non-bare builds do not pay the full startup cost repeatedly.

## Local overrides

```toml
# .holconfig.toml (not committed)
[overrides.foo]
path = "../foo-dev"   # $VAR/${VAR} allowed
```

Override takes priority over `path` in the manifest. When an override exists,
`[dependencies.foo].path` is not expanded, so unset env vars in the masked path
are ignored. The override path must still validate as package `foo` (manifest
with matching `project.name`). Env vars in override paths are expanded; unset
variables are errors.

An override does not mask `[dependencies.foo].manifest`. If an explicit manifest
is declared, holbuild still uses it relative to the consumer manifest directory,
and any env vars in that manifest path must be set.

## Shim manifests

Use `manifest = "shim.toml"` when a dependency subtree does not carry its own
`holproject.toml` yet.

```toml
[dependencies.foo]
path = "../legacy-foo"
manifest = "shims/foo.toml"
```

The shim manifest is resolved relative to the consumer manifest; the dependency
root remains `../legacy-foo`.

## Resolution order

Intended model:

1. Discover the root project manifest.
2. Add the implicit HOL package selected by `--holdir` / env.
3. Resolve ordinary dependency roots and manifests.
4. Build one global source index from the root project, ordinary dependencies,
   and the implicit HOL package.
5. Treat bare-heap-provided HOL theories/modules as already available; build all
   other reachable HOL sources normally.

## Duplicate logical names

One logical name must resolve to one artifact in a requested build graph. If the
implicit HOL package and a user package define the same logical theory/module,
holbuild should report a clear conflict unless a future explicit opt-out/exclude
mechanism removes one side.
