# Root HOL source package sketch

HOL itself is implicit in project mode. The selected checkout is chosen by
`--holdir`, `HOLBUILD_HOLDIR`, or `HOLDIR`; users do not declare
`[dependencies.HOLDIR]`.

The intended implicit package is deliberately simple:

```toml
[project]
name = "HOL"

[build]
members = ["src", "examples"]
# no roots
# default excludes: selftests and developer throwaway examples
```

`holproject.toml` in this directory is an older audit artifact showing one way to
index a subset of root HOL. It is useful historical data, but it is not the final
user-facing model. The final model makes normal `$HOLDIR/src` and
`$HOLDIR/examples` sources visible for dependency resolution while excluding
selftests and developer throwaway examples that are not intended downstream
library dependencies.

Semantic bootstrap starts from `bin/hol.state0` via `hol --bare`. Bare-provided
modules/theories are treated as already available. Non-bare scripts receive the
standard HOL environment from a holbuild-managed checkpoint constructed from
source-built `bossLib` and `holTheory`, then `open bossLib`.

Probe shape:

```sh
tmp=$(mktemp -d)
cat > "$tmp/holproject.toml" <<EOF
[project]
name = "probe"

[build]
members = []
EOF

(cd "$tmp" && /path/to/holbuild --holdir "$HOLDIR" build --dry-run)
```
