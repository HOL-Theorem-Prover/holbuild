# .holconfig.toml local config

Uncommitted per-user build settings. Lives at the project root. Schema-checked — unknown fields are errors.

```toml
[build]
exclude = ["worktrees/*"]   # appends to manifest excludes
jobs = 16                   # default -j when not specified on CLI
tactic_timeout = 30.0       # root-package per-step timeout (overrides manifest [build].tactic_timeout)
```

Dependency overrides are no longer supported. Project/dependency locations are part of schema 2 manifests and are resolved through exact git revisions plus `from/path/manifest` shim dependencies.

## Build excludes

`[build].exclude` in `.holconfig.toml` is **appended** to the manifest `[build].exclude`, not a replacement. Use it for workstation-specific paths (worktrees, local scratch) that shouldn't affect the committed manifest.

## Build jobs and timeout

Jobs priority: CLI `-jN`/`--jobs N` > `.holconfig.toml [build].jobs` > `max(1, nproc/2)`.

Tactic-timeout priority for root-package theorem instrumentation: CLI `--tactic-timeout` > `.holconfig.toml [build].tactic_timeout` > manifest `[build].tactic_timeout` > default `2.5`. `0` disables the timeout. Dependency packages build with no tactic timeout.

## Not committed

`.holconfig.toml` is for local machine build preferences that don't belong in version control. Add to `.gitignore` when used.
