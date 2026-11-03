# Heap exports

## Declaring heaps

```toml
[[heap]]
name = "main"
output = "build/main.heap"   # path relative to project root
objects = ["MainTheory", "UtilTheory"]  # logical targets (must be theory scripts)
```

## Building a heap

```sh
holbuild heap main
```

Heap export flow:
1. Build declared `objects` without proof steps, as `holbuild build --skip-proof-steps` does: no tactic timeout applies, and theories cached by either kind of build are reused. Use `holbuild build` to check proof-step timeouts.
2. Start from base `hol.state` context
3. Load external theories and generated theory modules in build-graph order
4. Save heap with `PolyML.SaveState.saveChild`
5. Output written to the declared `output` path

`-jN` controls parallelism for the object build phase. Heap export itself is serial. `heap` takes the project write lock.

`objects` must currently be theory targets — non-theory objects in heap targets is not yet supported.

## `holbuild run` / `holbuild repl` — prototype status

These commands generate an invocation-private run context under `.holbuild/`, add built project artifact object directories to HOL `loadPath`, and load `[run].loads` before user-supplied files or interactive input. Before starting HOL, `run` and `repl` resolve every configured load as a build target and build its dependency closure using normal cache and up-to-date behavior. Unknown configured targets are errors.

`holbuild repl` uses an interactive HOL process runner so stdin/stdout stay attached to the terminal.

`run --from THEORY` / `repl --from THEORY` (before any HOL arguments) start from `THEORY`'s build checkpoint instead of `[run].heap` or the base state: `final_context` (THEORY loaded) when it matches THEORY's current input key and its parent state is in place, else `deps_loaded` (ancestors loaded) when it matches the current dependency key (e.g. only THEORY changed, or the project moved), else `[run].heap` or the base state with a one-line reason (no checkpoint: cache hit without a local build, `--skip-checkpoints`, gc, never built, stale dependencies or toolchain, or a dependency-package theory). A usable checkpoint takes precedence over `[run].heap`. `--from` does not build THEORY; `holbuild build --force --no-cache THEORY` refreshes its checkpoints. Unknown theories are errors. Without `--from`, `run`/`repl` given `.sml` scripts infer THEORY: of the root-package theories the scripts depend on (`load` calls and Holdep module mentions, as for build sources), the one with the most ancestors; the line says it was inferred. Scripts using no root-package theory, and bare `repl`, start from `[run].heap` or the base state. An explicit `--from` overrides.

Global flags apply: `--source-dir` and `--max-heap`. `heap`, `run`, and `repl` use the manifest-declared project HOL from `[dependencies.hol]`; use `holbuild buildhol` to warm that shared cache explicitly if desired.

For proof failures during builds, prefer `holbuild build --repl-on-failure TARGET`: it serializes the build and starts `hol repl` from the newest failed-prefix checkpoint, falling back to replay/deps-loaded checkpoint. It requires checkpoints and is not supported with `--json`.
