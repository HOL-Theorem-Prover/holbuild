# Root HOL manifest sketch

This directory is a historical/root-HOL planning sketch. It shows how selected
HOL source roots might enter project mode without interpreting Holmakefiles.

Schema 1, `[dependencies.HOLDIR]`, `--holdir`, `HOLDIR`, and
`HOLBUILD_HOLDIR` are no longer supported project/runtime mechanisms. Current
projects declare HOL through schema 2 `[dependencies.hol]`; holbuild uses a
built-in manifest for that reserved `hol` package and builds/reuses the declared
HOL under `$HOLBUILD_CACHE/hol-toolchains/<key>/hol`.

The sketch manifest deliberately excludes HOL examples, tests, manuals, and
non-default tool variants. Example theories are separate package boundaries. For
example, code that needs `keccakTheory` should declare a schema 2 `from = "hol"`
dependency with a shim manifest:

```toml
# consumer holproject.toml
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "<exact-40-character-commit>"

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

Last audit result: with the exclude list in this sketch, dry-run planning over
an audited HOL checkout resolved 1461 HOL package nodes. Remaining work is to
turn this planning boundary into executable bootstrap/tool phases and explicit
action policies for generated, impure, or source-implicit dependency actions.
Use `[actions.<logical>].deps` for explicit logical predecessors; do not infer
Holmakefile ordering in project mode.
