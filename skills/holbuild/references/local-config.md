# .holconfig.toml local config

Uncommitted per-user build settings. Lives at the project root. Schema-checked — unknown fields are errors.

```toml
[build]
exclude = ["worktrees"]       # appends to manifest path/subtree excludes
exclude_globs = ["scratch/*"] # appends to manifest glob excludes
jobs = 16                     # default -j when not specified on CLI
tactic_timeout = 30.0       # root-package per-step timeout (overrides manifest [build].tactic_timeout)

[overrides.foo]
path = "../foo"             # local dependency source directory

[overrides.bar]
git = "$BAR_REPO"           # local/alternate git source; manifest rev is retained
```

Dependency overrides are local-only source substitutions. The committed manifest still declares the dependency with exact `git`/`rev`. `.holconfig.toml [overrides.NAME].path` makes holbuild read that dependency from the given directory instead of materializing it from git. `.holconfig.toml [overrides.NAME].git` replaces the dependency git source while retaining the manifest `rev`. Environment variables are expanded; local relative paths are resolved from the project root; URL-like git remotes are left unchanged. Overrides are carried through recursive dependency resolution. `dependencies.hol` cannot be overridden this way.

## Build excludes

`[build].exclude` in `.holconfig.toml` is **appended** to the manifest `[build].exclude`, not a replacement. Use it for workstation-specific concrete paths/subtrees (worktrees, local scratch) that shouldn't affect the committed manifest. Entries must be concrete paths; use `[build].exclude_globs` for glob filters.

## Build jobs and timeout

Jobs priority: CLI `-jN`/`--jobs N` > `.holconfig.toml [build].jobs` > `max(1, nproc/2)`.

Tactic-timeout priority for root-package theorem instrumentation: CLI `--tactic-timeout` > `.holconfig.toml [build].tactic_timeout` > manifest `[build].tactic_timeout` > default `2.5`. `0` disables the timeout. Dependency packages build with no tactic timeout.

## Not committed

`.holconfig.toml` is for local machine build preferences that don't belong in version control. Add to `.gitignore` when used.
