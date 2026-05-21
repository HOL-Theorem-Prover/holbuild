---
name: holbuild
Build HOL4 projects with holbuild. Use when working with holproject.toml manifests, building theory targets like FooTheory, managing dependencies, configuring proof IR/GoalFrag or checkpoint behavior, using the holbuild CLI, generated source, JSON output, tactic timeouts, cache/gc, or heap exports.
---

# holbuild

Project-aware build frontend for HOL4. Logical targets, not object files.

## Core workflow

```sh
holbuild build FooTheory                 # build a theory target
holbuild build Foo BarTheory             # multiple targets
holbuild build                           # all, or [build].roots closure if configured
holbuild build --dry-run FooTheory       # show plan without building
holbuild context                         # show manifest info
holbuild execution-plan FooTheory:thm    # static proof-IR plan for one theorem
holbuild build --force --goalfrag-trace FooTheory
holbuild gc                              # clean project residue + global cache
```

Never request `.uo`/`.ui`/`.dat` — use logical names like `FooTheory`.

## Minimal project

```toml
[project]
name = "myproject"

[build]
members = ["src"]
```

`src/FooScript.sml` → target `FooTheory`. `Script.sml` suffix is mandatory for theory scripts.

## Key flags

| Flag | Effect |
|------|--------|
| `--holdir PATH` | HOL checkout/install; fallback envs: `HOLBUILD_HOLDIR`, `HOLDIR` |
| `--source-dir PATH` | Source tree for manifest discovery; artifacts still under the shell cwd `.holbuild/` |
| `-jN` / `--jobs N` | Parallel workers (default: `.holconfig.toml [build].jobs` or `max(1, nproc/2)`) |
| `--force=theory` / `--force-theory` | Rebuild only requested/default target nodes from source; deps still use up-to-date/cache |
| `--force=project` / `--force-project` | Rebuild root-project nodes in the requested plan; dependency packages still use up-to-date/cache |
| `--force=full` / `--force-full` / `--force` | Rebuild the whole requested plan from source; forced nodes still publish cache unless `--no-cache` |
| `--no-cache` | Skip global cache restore/publish; local up-to-date checks still work |
| `--skip-checkpoints` | No `.save`/`.ok` checkpoint files; theorem instrumentation still runs |
| `--skip-goalfrag` | No theorem instrumentation/proof IR; incompatible with timeout/plan/trace flags |
| `--goalfrag` | Use legacy HOL GoalFrag runtime instead of default proof IR |
| `--strict-parse` | Reject HOLSourceParser recovery before running HOL; default preserves HOL compatibility and instruments recovered proof boundaries where possible |
| `--tactic-timeout SECONDS` | Root-package per-step timeout (default 2.5s, `0` disables); also manifest/local-config settable |
| `--json` | Newline-delimited streaming JSON build events/errors on stdout; no retained log paths by default; not supported for dry-run/plan/trace/repl-on-failure |
| `--retain-debug-artifacts` | With `--json build`, retain durable failure logs and expose `debug_artifacts.log`; stage dirs still cleaned |
| `--quiet` / `--verbosity quiet` | Suppress per-node success lines in non-TTY output |
| `--verbose` / `--verbosity verbose` | Node starts plus all finishes, including unchanged nodes, with per-node elapsed times in non-TTY output |

## Output layout

All under `.holbuild/`: `gen/` (generated theory files), `obj/` (artifacts), `dep/` (metadata), `checkpoints/` (local replay/debug state), `heap/`, `logs/`, `stage/` (temporary), `locks/`.

## Key constraints

- `use "file"` rejected in project builds — declare a module and `load` it
- Duplicate logical names across packages → error (except same-package `.sig`/`.sml` companion)
- Unknown manifest/local-config fields → error (schema-checked)
- `--tactic-timeout` applies only to root package; dependencies build with no timeout
- Default parser policy is HOL-compatible recovery: keep recovered theorem instrumentation and pass unknown/recovered source through; use `--strict-parse` only when parser recovery should be fatal
- Proof engine/checkpoint/timeout/trace flags are execution/debug policy, not final artifact action-key inputs
- Reserved dependency `[dependencies.HOLDIR]` uses holbuild's built-in root-HOL manifest; no shim needed for core HOL sources
- HOL examples/tests are intentionally outside built-in `HOLDIR`; declare example subtrees (e.g. `keccakTheory`) as separate shimmed dependencies
- `.holconfig.toml [overrides.X].path` masks `[dependencies.X].path`; masked env vars are not expanded. Explicit `manifest` fields still apply.

## References

- [quickstart.md](references/quickstart.md) — setup, full command/flag reference, theory naming
- [manifest.md](references/manifest.md) — `holproject.toml` schema, source discovery, generators, action policies, HOLSource headers
- [local-config.md](references/local-config.md) — `.holconfig.toml` overrides, excludes, jobs, timeout
- [build-model.md](references/build-model.md) — dependency inference, action keys, invalidation, cache, write locks, gc
- [checkpoints-goalfrag.md](references/checkpoints-goalfrag.md) — proof IR/GoalFrag, checkpoint lifecycle, tactic timeouts, replay, env vars
- [dependencies.md](references/dependencies.md) — declaring deps, built-in HOLDIR, shim manifests, transitive resolution
- [heaps-and-run.md](references/heaps-and-run.md) — `[[heap]]` exports; `run`/`repl` prototype status
