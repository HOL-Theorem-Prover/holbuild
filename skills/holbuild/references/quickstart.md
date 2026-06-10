# holbuild quickstart

## Prerequisites

Projects must use `holproject.toml` schema 2 and declare the project HOL toolchain as `[dependencies.hol]`. Commands that need HOL build or reuse that declared HOL under `$HOLBUILD_CACHE/hol-toolchains/<key>/hol`.

Building the current external `holbuild` executable still requires a HOL checkout at compile time:

```sh
make HOLDIR=/path/to/HOL
make HOLDIR=/path/to/HOL test
```

That `HOLDIR` is only a temporary implementation input for compiling/testing `holbuild`; it is not a project/runtime configuration mechanism. `holbuild` commands no longer support `--holdir`, `HOLDIR`, or `HOLBUILD_HOLDIR`.

## Minimal project

```toml
# holproject.toml
[holbuild]
schema = 2

[project]
name = "myproject"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "<exact-40-character-commit>"

[build]
members = ["src"]
```

With `src/FooScript.sml` containing a standard theory script, build with:

```sh
holbuild build FooTheory
```

Use `holbuild buildhol` to warm the declared project-HOL cache explicitly, for example in CI. Normal HOL-using commands do this automatically.

## Core workflow

```sh
holbuild build FooTheory                 # build one target
holbuild build Foo BarTheory             # build multiple targets
holbuild build                           # build all, or roots if configured
holbuild build --dry-run FooTheory       # show plan
holbuild context                         # show manifest info/cache paths
holbuild buildhol                        # prebuild/reuse dependencies.hol
holbuild execution-plan FooTheory:thm    # static proof-IR plan
holbuild goalfrag-plan FooTheory:thm     # static legacy GoalFrag plan
holbuild build --force --goalfrag-trace FooTheory
holbuild --json build FooTheory          # bounded JSON events/errors for build output
holbuild --json build --retain-debug-artifacts FooTheory  # also retain/report failure logs
```

## Global flags

- `--source-dir PATH` — source tree for manifest discovery; `.holbuild/` artifacts are written under the shell cwd
- `--maxheap MB` / `--max-heap MB` — pass Poly/ML max heap to child HOL processes
- `-jN` / `--jobs N` — parallel workers. Default: `.holconfig.toml [build].jobs` or `max(1, nproc/2)`
- `--json` — newline-delimited streaming JSON `message`, `node_started`, `node_finished`, `node_failed`, `build_finished`, and `error` events on stdout (build only; no retained log paths by default; not dry-run/plan/trace/repl-on-failure)
- normal non-TTY output suppresses unchanged node lines
- `--quiet` / `--verbosity quiet` — suppress per-node success lines
- `--verbose` / `--verbosity verbose` — node starts plus all finishes, including unchanged nodes, with per-node elapsed times when the live TTY status line is disabled

## Build flags

- `--force=theory` / `--force-theory` — rebuild only requested/default target nodes from source; deps still use up-to-date/cache
- `--force=project` / `--force-project` — rebuild root-project nodes in the requested plan; dependency packages still use up-to-date/cache
- `--force=full` / `--force-full` / `--force` — rebuild the whole requested plan from source; forced nodes still publish cache unless `--no-cache`
- `--no-cache` — skip global cache restore/publish; local `.holbuild/` up-to-date checks still work
- `--skip-checkpoints` — no `.save`/`.ok` checkpoint files; theorem instrumentation still runs
- `--skip-goalfrag` — no theorem instrumentation/proof IR, hence no tactic timeout/plan/trace support
- `--goalfrag` — use the legacy HOL GoalFrag runtime instead of default proof IR
- `--tactic-timeout SECONDS` — per-step timeout for root package (default 2.5s, `0` disables)
- `--repl-on-failure` — serial build; on theory failure, start `hol repl` from failed-prefix or replay/deps checkpoint (requires checkpoints; no JSON)
- `--retain-debug-artifacts` — with `--json build`, retain durable failure logs and report `debug_artifacts.log`; logs may contain full goals/output, stage dirs are still cleaned

**Incompatible**: `--skip-goalfrag` + `--tactic-timeout`/`--goalfrag-plan`/`--goalfrag-trace`; `--json` + dry-run/plan/repl-on-failure.

Parser recovery policy: HOL source parse errors are build failures. holbuild may still use HOLSourceParser recovery internally to record warnings, recover theorem/resume boundaries where possible, and produce best-effort instrumentation diagnostics before HOL reports the failing script-play status.

## Maintenance

```sh
holbuild gc                                      # project clean + global cache GC; default 7-day retention
holbuild gc --retention-days 30                 # custom retention
holbuild gc --max-checkpoints-gb 10             # size cap for project checkpoints
holbuild gc --clean-only                        # project .holbuild residue only
holbuild gc --cache-only --cache-dir /path      # global cache only; no project HOL needed
holbuild cache gc                               # legacy cache-only form still exists
```

## Build output layout

```
.holbuild/
  obj/          local ML/theory artifacts, including adjacent Theory.sig/.sml/.dat bundles
  dep/          action metadata (.key files with input_key)
  checkpoints/  local PolyML replay/debug checkpoints, budgeted by gc
  heap/         exported heaps
  logs/         retained failure/trace logs
  stage/        temporary build staging
  locks/        project write/gc lock
  src/          materialized dependency sources
  packages/     dependency package artifacts
```

The declared project HOL is shared under `$HOLBUILD_CACHE/hol-toolchains/<key>/hol`.

Never request `.uo`/`.ui`/`.dat` as build targets — use logical names like `FooTheory`.

## Theory naming convention

`src/FooScript.sml` → logical target `FooTheory`

The `Script.sml` suffix is mandatory for theory scripts. Source discovery automatically ignores existing `*Theory.sml` / `*Theory.sig` in the tree and skips symlinked directories.
