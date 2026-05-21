# holproject.toml manifest

## Schema

```toml
[holbuild]
schema = 1   # currently only schema 1

[project]
name = "myproject"     # required for dependencies; optional for root
version = "0.1.0"      # optional

[build]
members = ["src", "lib"]   # source dirs/files relative to package root. Default: ["."]
exclude = ["*/selftest.sml", "*/examples/*"]  # glob patterns, package-root-relative
roots = ["src/MainScript.sml"]  # default build roots when no CLI target given
tactic_timeout = 60.0            # root-package per-step timeout; CLI/local config override

[dependencies.depname]
git = "https://github.com/org/dep"
rev = "abc123"          # git commit
path = "../dep"         # local path (or use .holconfig.toml override)
manifest = "shim.toml"  # explicit manifest (if set, dep's own holproject.toml is not used)

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

Tables validated: `[holbuild]`, `[project]`, `[build]`, `[run]`, `[dependencies.*]`, `[actions.*]`, `[[generate]]`, `[[heap]]`.

## Dependency resolution

Each dependency must resolve to a manifest:
1. Reserved `[dependencies.HOLDIR]` with no `manifest` uses holbuild's built-in
   root-HOL manifest; the package root defaults to
   `--holdir`/`HOLBUILD_HOLDIR`/`HOLDIR` unless `path`/override is set. This
   built-in manifest excludes HOL examples/tests; model example subtrees such as
   `$HOLDIR/examples/Crypto/Keccak` as separate dependencies with shim manifests.
2. If `manifest` field is set, that file is used — dependency's own `holproject.toml` is **never consulted**. This remains true when `.holconfig.toml` overrides the dependency root path.
3. Otherwise, tries `holproject.toml` in the dependency's directory
4. If neither exists, build fails with a "no manifest" error

Dependency `name` in `[dependencies.X]` must match the `project.name` in the resolved manifest. Mismatch is an error.

## Path rules

- `build.members`, `build.exclude`, `build.roots`, `actions.*.extra_deps`, `generate.*.inputs`, `generate.*.outputs` — **package-root-relative**
- Absolute paths and `..` components are rejected in those package-relative fields
- Dependency `path` and `manifest` in `[dependencies.*]` are resolved relative to the *consumer's* manifest directory
- `.holconfig.toml [overrides.X].path` takes precedence over `[dependencies.X].path`; masked dependency paths are not env-expanded
- Dependency `path`/`manifest` and `.holconfig.toml` override paths support `$VAR` and `${VAR}` environment expansion; unset vars are errors

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

A `.sig`/`.sml` pair with the same base name in the same package is a companion pair (one module), not a conflict.

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

One logical name → one resolved artifact across the entire build graph. Two packages exporting `FooTheory` or `Foo` module is an error. The only exception: same-package `.sig`/`.sml` companion pair.

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
