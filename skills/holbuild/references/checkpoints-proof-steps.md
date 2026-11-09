# Checkpoints and proof steps

## Default proof-step execution

When proof steps are enabled (default), holbuild instruments modern theorem declarations at the AST level:

1. Parses source with `HOLSourceParser`
2. Identifies recovered `Theorem ... Proof ... QED` / `Resume ... QED` declarations and tactic/source spans
3. Rewrites source to insert theorem-boundary markers and load a runtime helper
4. Runs theorem proofs through the selected runtime with per-step timeout, failure diagnostics, and optional checkpoint saves

The runtime is **proof IR**. It lowers `HOLSourceAST.exp` directly and executes exact HOL tactic/list-tactic boundaries for recognized constructs. If the proof-IR planner cannot parse/decompose a recovered tactic expression, it falls back to a whole-tactic leaf so the proof still runs under the installed runtime. `--goalfrag` and `goalfrag-plan` have been removed. The old `--new-ir` flag is a deprecated no-op because proof IR is default.

Proof execution attributes (`Proof[...]` and attributed `Resume`) run through the
stepped proof engine inside HOL's native modifier scope. They retain leaf
diagnostics, timeouts and tracing, but never save or restore failed-prefix
checkpoints. Their theorem-context checkpoint is saved after the declaration
and modifier have completed, like an ordinary theorem.

This enables:
- Per-step tactic timeouts (`--tactic-timeout`)
- PolyML checkpoint saves at dependency/theorem/proof boundaries
- Failed proof diagnostics: theorem, source line/span, plan position, input-goal count/top goal
- Failed-prefix replay after proof edits

## What's NOT instrumented

Simple theorem forms are **not** theorem-checkpoint-instrumented in v1:
- `Theorem name = thm` (no proof body)
- `store_thm`, `save_thm`, `Q.store_thm` calls
- `Finalise` declarations

These still execute normally during build, just without theorem-context/failed-prefix proof checkpoints.

## Checkpoint classes and retention

During a theory build, checkpoints may be created at syntactic boundaries:

| Checkpoint | After | Purpose |
|------------|-------|---------|
| `deps_loaded.save` | All resolved ancestors loaded in topological order | Resume from dependency context |
| `<thm>_context.save` | Theorem stored in theory context | Resume before the next declaration |
| `<thm>_failed_prefix.save` | Failed proof after a reusable prefix | Fast rebuild after editing a failing suffix |

Export seals a theory in current HOL versions, so no state is saved after it: the source process exports and exits, and dependents load the generated theory through its manifest. A generated theory that fails to load fails its first dependent.

Successful source builds retain reusable deps/theorem-context checkpoints for future proof edits and clear stale failed-prefix checkpoints for that source. Failed/interrupted builds may leave failed-prefix and partial debug breadcrumbs. `holbuild gc` removes old checkpoint families and enforces the default 5GB project checkpoint budget.

## Checkpoint validity

`.ok` metadata contains schema/versioned fields such as:
- Checkpoint kind (`deps_loaded`, `theorem_context`, `failed_prefix`)
- Dependency context key (`deps_key`)
- Proof engine (`proof_ir_*`)
- Source prefix/header/checkpoint keys

Replay eligibility requires exact metadata match. Invalid selected checkpoints are discarded and retried from an earlier valid context instead of surfacing as proof failures. Parent/child checkpoint families are removed atomically: theorem descendants must not outlive their `deps_loaded.save` parent.

## `--skip-checkpoints`

Runs theorem proofs through proof steps without saving `.save`/`.ok` files. No `deps_loaded`, theorem-context or failed-prefix checkpoints are created.

## Target-only theorem checkpoints and `--all-checkpoints`

By default, theorem-context, declaration and failed-prefix checkpoints are saved only in the requested targets (the default targets when none are given, or every root-package theory when there are none). Every root-package theory still saves its `deps_loaded` checkpoint and runs with proof steps and step timeouts. An edit to a non-target starts from `deps_loaded`; rebuilding it as a target (after an edit, or with `--force=theory`) saves its theorem checkpoints. `--repl-on-failure` saves them everywhere. `--all-checkpoints` saves them in every root-package theory. Theory outputs and keys don't change either way. Under `--remote-exec`, a non-target's action spec says `option theorem-checkpoints=false` and the worker skips them too.

## Host deps heaps

Unless the build has `--no-cache` or the theory `cache = false`, every `deps_loaded.save` is also kept once per host in `$HOLBUILD_CACHE/checkpoint-store/`, keyed without the project directory, so worktrees of one project share it by hard link. A theory with no valid `deps_loaded` resumes from the stored one; a stored heap with the wrong parent is ignored, and one HOL can't resume from is replaced. Each build evicts stored heaps no tree links that no build used for a day, and `holbuild gc` evicts those unused within the retention window that no tree links. In a theory resumed from another tree's heap, `Meta.fileDirMap()` names that tree's directories. Loading is unaffected, but TacticToe recording (`tttUnfold`'s includes, `tttManifest.find_script`) reads them, so run a local recording in a tree whose heaps weren't restored from the store (a clean checkout built with `--no-cache`, say).

## `--skip-proof-steps`

Opts out of proof-step execution. Source is sent through the plain `hol run` path. There is no per-tactic timeout, trace-step trace, theorem-context/failed-prefix proof navigation, or instrumented goal diagnostics. The `deps_loaded` checkpoint may still be used when checkpoints are enabled.

**Incompatible**: `--skip-proof-steps` with `--tactic-timeout`, `--trace-steps`, or `--repl-on-failure`.

## `--trknl` defaults

A tracing-kernel build runs root-package theories as `--skip-checkpoints --skip-proof-steps` would; kernel checking and `.tr.gz` export are unchanged. `--trace-steps` or `--tactic-timeout` turns proof steps back on; `--repl-on-failure` turns on proof steps and checkpoints. Explicit `--skip-*` flags still conflict with them as above.

## Parser recovery

HOL source parse errors are build failures. When HOLSourceParser recovery occurs, holbuild may warn and keep recovered theorem/resume boundaries for best-effort instrumentation and diagnostics before HOL reports the failing script-play status. This avoids the old all-or-nothing fallback where one later parse recovery could disable proof IR/timeouts for the whole theory.

## Tactic timeout flow

```
--tactic-timeout 2.5   # default root-package timeout
--tactic-timeout 60    # slower smoke/debug runs
--tactic-timeout 0     # disables timeout entirely
```

The timeout applies only to the root package; dependency packages build with no tactic timeout.
A manifest `[build.theory_tactic_timeouts]` entry can replace the manifest/default
policy for one concrete theory (named by logical name or script path) without affecting its dependencies or
consumers. An explicit CLI `--tactic-timeout` takes precedence; `0` disables the
timeout for the named theory.

On timeout:
1. The step runs once more with half the timeout; if that finishes, the step passes and the build log gets a `holbuild tactic timeout retry passed: <step> (...)` line
2. Otherwise the runtime timeout wrapper raises the timeout marker/failure, with the full timeout
3. Child log records tactic label/plan position, source span, and input goal evidence where available
4. holbuild reports the timed-out tactic and **does not retry** through the plain non-instrumented fallback
5. Build fails

To list the steps that passed only on their retry in the last build: `grep -h "tactic timeout retry passed" .holbuild/logs/current/*/*/build.log`.

For full semantic production builds of large projects, use `--tactic-timeout 0`.

## Replay order

On a rebuild after source edit:
1. Compute theorem boundaries and dependency context from current source/project state
2. Find a valid failed-prefix checkpoint matching the theorem header/pre-theorem bytes and the newest valid context checkpoint matching the source prefix and dependency context
3. Use whichever has the later source boundary, preferring the failed prefix on a tie
4. Otherwise try a valid `deps_loaded.save`
5. Re-execute only the remaining suffix when replay succeeds

`always_reexecute = true` disables local up-to-date skipping and checkpoint replay for that action.

`--force=theory` bypasses cached outputs for the targets while retaining this
checkpoint replay order. For a fresh source execution while retaining cache hits
for ancestors, use `holbuild clean FooTheory` followed by `holbuild build
--force=theory FooTheory`. Cleaning alone can restore the theory from the global
cache.

## Plan and trace inspection

```sh
holbuild execution-plan FooTheory:thm          # static, no build lock/proof execution
holbuild build --force --trace-steps FooTheory
```

Plan lines are executable tactic/list-tactic operations. Indentation/body text is formatting only; if a source construct executes as one HOL combinator boundary, it should display as one numbered step.

`--trace-steps` executes a build and records runtime before/after goal counts and elapsed times in the child log. Use `--force` when an up-to-date artifact would otherwise skip source execution.

## REPL on failure

`build --repl-on-failure` serializes the build and, after a theory action fails, starts `hol repl` from the newest failed-prefix checkpoint when available, falling back to the replay/deps-loaded checkpoint. It requires checkpoints and is not supported with `--json`.

## Checkpoint paths

```
.holbuild/checkpoints/<package>/<relative-path>.deps/<deps_key>/deps_loaded.save[.ok]
.holbuild/checkpoints/<package>/<relative-path>.theorems/<deps_key>/<proof_engine>/<prefix_key>/
  <safe_name>_context.save[.ok]
.holbuild/checkpoints/<package>/<relative-path>.theorems/<deps_key>/<proof_engine>/.failed/
  <safe_name>_failed_prefix.save[.ok]
  <safe_name>_failed_prefix.save.meta
  <safe_name>_failed_prefix.save.prefix
```

These are local project state, never the semantic identity of a build.

## JSON failure evidence

With `--json`, failures are emitted as structured `error`/`node_failed` JSONL events on stdout. Events carry `target`, `key`, `package`, and `source` where applicable so consumers can demux parallel builds by theory without separate log files. JSON mode does not retain or expose child/instrumented log paths by default. `build --retain-debug-artifacts` retains durable failure logs for human/harness debugging and reports them as `debug_artifacts.log`; these logs may contain full goals/output and are not bounded agent evidence. Internal stage directories are still cleaned. `node_failed.failure` may include:

- `kind`: `proof_failure`, `tactic_timeout`, `termination_failure`, `parse_error`, `type_error`, `child_failure`, or `unknown`
- `theorem`, `source_file`, `source_line`
- `plan_position`
- `input_goal_count`
- `top_goal_truncated`
- `top_goal_preview_bytes`, `evidence_mode = "preview_only"` when goal evidence is truncated

## Environment variables

| Variable | Effect |
|----------|--------|
| `HOLBUILD_SHARE_COMMON_DATA` | Override `PolyML.shareCommonData` default for checkpoint saves |
| `HOLBUILD_CHECKPOINT_TIMING` | `1`/`true` = print checkpoint save timing to stderr |
| `HOLBUILD_ECHO_CHILD_LOGS` | `1`/`true` = echo child `hol run` log to stdout |
| `HOLBUILD_CACHE_TRACE` | `1`/`true` = print cache decision trace, one timing line per remote-cache request and zstd compression, and the machine-wide Linux CPU-pressure (PSI) delta over the build |
| `HOLBUILD_STATUS` | `1`/`true` = enable status display, `0`/`false` = disable |
| `HOLBUILD_TIMING_LOG` | Path for structured timing data (tool + coarse phase lines, including `build.keys` action-key computation) |
| `HOLBUILD_TIMING_DETAIL` | Optional timing coarseness: unset/`coarse` logs coarse phases only; `fine` adds aggregate subphase lines; `trace` is reserved for future per-item detail |
