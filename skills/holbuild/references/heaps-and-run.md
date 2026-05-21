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
1. Build declared `objects` with the full build pipeline (default proof IR theorem instrumentation, checkpoints unless skipped by policy, default root timeout 2.5s)
2. Start from base `hol.state` context
3. Load external theories and generated theory modules in build-graph order
4. Save heap with `PolyML.SaveState.saveChild`
5. Output written to the declared `output` path

`-jN` controls parallelism for the object build phase. Heap export itself is serial. `heap` takes the project write lock.

`objects` must currently be theory targets — non-theory objects in heap targets is not yet supported.

## `holbuild run` / `holbuild repl` — prototype status

These commands generate `.holbuild/holbuild-run-context.sml`, add built project artifact object directories to HOL `loadPath`, and load `[run].loads` before user-supplied files/interactive input. Build requested targets first; `run`/`repl` do not trigger hidden rebuilds.

`holbuild repl` uses an interactive HOL process runner so stdin/stdout stay attached to the terminal.

Global flags apply: `--holdir`, `--source-dir`, and `--maxheap`/`--max-heap`.

For proof failures during builds, prefer `holbuild build --repl-on-failure TARGET`: it serializes the build and starts `hol repl` from the newest failed-prefix checkpoint, falling back to replay/deps-loaded checkpoint. It requires checkpoints and is not supported with `--json`.
