# holproject.toml manifest

## Schema

holbuild currently supports schema 2 only. The schema marker is required.

```toml
[holbuild]
schema = 2
minimum_version = "0.6.0"  # optional minimum holbuild version

[project]
name = "myproject"     # required for dependencies; optional for root
version = "0.1.0"      # optional

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "<exact-40-character-commit>"

[build]
members = ["src", "lib"]   # source dirs/files relative to package root. Default: ["."]
exclude = ["*/selftest.sml", "*/examples/*"]  # glob patterns, package-root-relative
roots = ["src/MainScript.sml"]  # default build roots when no CLI target given; use build --warn-unreachable to audit omitted scripts
tactic_timeout = 60.0            # root-package per-step timeout; CLI/local config override

[dependencies.depname]
git = "https://github.com/org/dep"
rev = "0123456789abcdef0123456789abcdef01234567"

[dependencies.subtree]
from = "hol"
path = "examples/Crypto/Keccak"
manifest = "shims/keccak.toml"

# [run] — prototype, not yet functional for consumers
# heap = "build/main.heap"
# loads = ["MyLib"]

[[generate]]
name = "opcodes"
command = ["python3", "scripts/gen_opcodes.py", "data/opcodes.toml", "-o", "gen/OpcodeScript.sml"]
inputs = ["scripts/gen_opcodes.py", "data/opcodes.toml"]
outputs = ["gen/OpcodeScript.sml"]
deps = []  # optional names of earlier [[generate]] steps

[[heap]]
name = "main"
output = "build/main.heap"  # heap output path, package-root-relative
objects = ["MainTheory"]    # logical targets to build before saving heap

[actions.TargetName]
deps = ["OtherTheory"]            # extra logical project dependencies
loads = ["ExternalLib"]           # extra loadable modules (project or HOL toolchain)
extra_deps = ["data/table.txt"]   # package-root-relative filesystem deps
cache = false                     # disable global cache for this action
always_reexecute = true           # never skip, never replay checkpoints
impure = true                     # shorthand: cache=false + always_reexecute=true
```

## Schema validation

Unknown fields in recognized tables are **errors**, not silently ignored. This catches typos early.

`[holbuild].minimum_version`, when present, must be a semantic version `MAJOR.MINOR.PATCH` and requires the running holbuild version to be at least that version.

Tables validated: `[holbuild]`, `[project]`, `[build]`, `[run]`, `[dependencies.*]`, `[actions.*]`, `[[generate]]`, `[[heap]]`.

## Dependency resolution

Every resolved graph must contain exactly one package named `hol`, declared as an exact git dependency. Upstream HOL does not need a manifest; holbuild uses a built-in manifest for package metadata and builds/reuses the declared HOL under `$HOLBUILD_CACHE/hol-toolchains/<key>/hol`.

Schema 2 dependency forms:

1. Direct git dependencies:
   ```toml
   [dependencies.foo]
   git = "https://github.com/acme/foo"
   rev = "0123456789abcdef0123456789abcdef01234567"
   ```
   Direct git dependencies must have their own `holproject.toml`; `manifest` is not allowed here.

2. Subtree/shim dependencies:
   ```toml
   [dependencies.keccak]
   from = "hol"
   path = "examples/Crypto/Keccak"
   manifest = "shims/keccak.toml"
   ```
   `from` names a direct git dependency in the same manifest, `path` selects a subtree inside that checkout, and `manifest` is relative to the declaring package's manifest directory.

Dependency `name` in `[dependencies.X]` must match `project.name` in the resolved manifest when the manifest declares a name. Mismatch is an error, except for the built-in `hol` manifest.

Unsupported: schema 1, `[dependencies.HOLDIR]`, path dependencies, local dependency overrides, dependency path environment expansion, branches/tags/ranges, registries, lockfiles, solvers, and multiple versions of one package.

## Path rules

- `build.members`, `build.exclude`, `build.roots`, `actions.*.extra_deps`, `generate.*.inputs`, `generate.*.outputs` — **package-root-relative**
- Absolute paths and `..` components are rejected in those package-relative fields
- `dependencies.*.path` and `dependencies.*.manifest` are allowed only in `from/path/manifest` dependencies
- `from` dependency `path` and `manifest` fields must be relative and contain no `..`
- Direct git dependencies cannot specify `path` or `manifest`

## Source discovery

Members can be files or directories. Directories are walked recursively, skipping:
- Names starting with `.`
- Names equal to `_build`
- Symlinked directories/files
- Files/folders matching `build.exclude` globs
- Files matching `*Theory.sml` or `*Theory.sig` (generated artifacts)

Recognized source files:
- `*Script.sml` → theory script, logical name = prefix + "Theory" (e.g. `FooScript.sml` → `FooTheory`)
- `*.sml` → SML module, logical name = filename minus `.sml`
- `*.sig` → signature, logical name = filename minus `.sig`

A `.sig`/`.sml` pair with the same base name in the same package is one SML module interface/implementation pair, not a conflict.

## HOLSource headers

Theory scripts can use HOLSource headers for explicit dependency declaration:

```sml
Theory Foo
Ancestors Bar
```

These are picked up by the Holdep scanner alongside `load`/`open` for dependency inference. `Ancestors` declares direct theory predecessors; `Theory` declares the theory name (redundant with `new_theory` but used by Holdep).

## `[[generate]]` source generation

Generators run before source discovery. Holbuild keys each step by its command, declared inputs, declared generator dependencies, and declared output hashes.

Rules:
- `name` must be unique and non-empty
- `command` is argv, not shell text; it runs from the package root
- `inputs` and `outputs` are package-root-relative paths; `outputs` is required
- `deps` names earlier generator steps; cycles/unknown deps are errors
- If an output is missing or its content changed from the generator metadata, holbuild reruns the step
- After running, every declared output must exist
- Generated files are normal visible source-tree files; include their directory in `[build].members`

## Duplicate logical names

One logical name → one resolved artifact across the entire build graph. Two packages exporting `FooTheory` or `Foo` module is an error. A same-package `.sig`/`.sml` pair is one SML module interface/implementation pair and is not a cross-package conflict.

## Action policies

Default policy for any target: `cache = true`, `always_reexecute = false`, `impure = false`, no extra deps/loads.

| Field | Default | Effect |
|-------|---------|--------|
| `deps` | `[]` | Additional logical project dependencies |
| `loads` | `[]` | Additional loadable module stems |
| `extra_deps` | `[]` | Extra filesystem dependencies hashed into action key; files, directories, or simple globs |
| `cache` | `true` | Enable/disable global cache |
| `always_reexecute` | `false` | Never skip up-to-date check or checkpoint replay |
| `impure` | `false` | Shorthand for `cache=false, always_reexecute=true` |

`impure = true` overrides both `cache` and `always_reexecute` — don't set them separately when using `impure`.

Source files can also declare source-file-relative extra dependencies with a static literal annotation:

```sml
val () = holbuild_extra_deps ["../data/table.txt"];
```

Source-declared extra dependencies are staged so matching relative filesystem reads work during the action.

Action policy names must resolve to sources in the package. An `[actions.FooTheory]` entry for a target that doesn't exist in the package is an error.
