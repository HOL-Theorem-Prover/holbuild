# Checkpoints, proof IR, and GoalFrag

## Default theorem instrumentation

When theorem instrumentation is enabled (default), holbuild instruments modern theorem declarations at the AST level:

1. Parses source with `HOLSourceParser`
2. Identifies recovered `Theorem ... Proof ... QED` / `Resume ... QED` declarations and tactic/source spans
3. Rewrites source to insert theorem-boundary markers and load a runtime helper
4. Runs theorem proofs through the selected runtime with per-step timeout, failure diagnostics, and optional checkpoint saves

The default runtime is **proof IR**. It lowers `HOLSourceAST.exp` directly and executes exact HOL tactic/list-tactic boundaries for recognized constructs. If the proof-IR planner cannot parse/decompose a recovered tactic expression, it falls back to a whole-tactic `StepPlain` so the proof still runs under the installed runtime. Use `--goalfrag` only to select the legacy HOL GoalFrag/proof-manager runtime for comparison/debugging. The old `--new-ir` flag is a deprecated no-op because proof IR is default.

This enables:
- Per-step tactic timeouts (`--tactic-timeout`)
- PolyML checkpoint saves at dependency/theorem/proof boundaries
- Failed proof diagnostics: theorem, source line/span, plan position, input-goal count/top goal
- Failed-prefix replay after proof edits

## What's NOT instrumented

Simple theorem forms are **not** theorem-checkpoint-instrumented in v1:
- `Theorem name = thm` (no proof body)
- `store_thm`, `save_thm`, `Q.store_thm` calls
- `Resume` / `Finalise` declarations

These still execute normally during build, just without theorem-context/end-of-proof/failed-prefix proof checkpoints.

## Checkpoint classes and retention

During a theory build, checkpoints may be created at syntactic boundaries:

| Checkpoint | After | Purpose |
|------------|-------|---------|
| `deps_loaded.save` | All resolved ancestors loaded in topological order | Resume from dependency context |
| `<thm>_context.save` | Theorem stored in theory context | Resume before the next declaration |
| `<thm>_end_of_proof.save` | Instrumented proof replay complete, before `drop_all` | Proof navigation/debug state, not successor-ready |
| `<thm>_failed_prefix.save` | Failed proof after a reusable prefix | Fast rebuild after editing a failing suffix |
| `final_context.save` | Generated theory sig/sml loaded; successor-ready | Debug/successor breadcrumb |

Successful source builds retain reusable deps/theorem-context checkpoints for future proof edits and clear stale failed-prefix checkpoints for that source. Failed/interrupted builds may leave failed-prefix and partial debug breadcrumbs. `holbuild gc` removes old checkpoint families and enforces the default 5GB project checkpoint budget.

## Checkpoint validity

`.ok` metadata contains schema/versioned fields such as:
- Checkpoint kind (`deps_loaded`, `theorem_context`, `end_of_proof`, `failed_prefix`, `final_context`)
- Dependency context key (`deps_key`)
- Proof engine (`proof_ir_*` or legacy GoalFrag engine key)
- Source prefix/header/checkpoint keys

Replay eligibility requires exact metadata match. Invalid selected checkpoints are discarded and retried from an earlier valid context instead of surfacing as proof failures. Parent/child checkpoint families are removed atomically: theorem descendants must not outlive their `deps_loaded.save` parent.

## `--skip-checkpoints`

Runs theorem proofs through the selected instrumentation runtime without saving `.save`/`.ok` files. No `deps_loaded`, `final_context`, theorem-context, end-of-proof, or failed-prefix checkpoints are created. Theory artifacts are still built normally.

## `--skip-goalfrag`

Opts out of theorem instrumentation/proof IR. Source is sent through the plain `hol run` path. There is no per-tactic timeout, execution plan, trace, theorem-context/end-of-proof/failed-prefix proof navigation, or instrumented goal diagnostics. Non-theorem dependency/final-context checkpoint machinery may still be used when checkpoints are enabled.

**Incompatible**: `--skip-goalfrag` with `--tactic-timeout`, `--goalfrag-plan`, or `--goalfrag-trace`.

## Parser recovery and `--strict-parse`

Default build mode preserves HOL compatibility: HOLSourceParser recovery is not a build gate. When parser recovery occurs, holbuild warns, keeps recovered theorem/resume boundaries for instrumentation, and lets unknown/recovered source regions pass through to HOL. This avoids the old all-or-nothing fallback where one later parse recovery could disable proof IR/timeouts for the whole theory.

Use `--strict-parse` when parser recovery itself should be fatal. In strict mode, holbuild runs strict HOLSourceParser boundary discovery before up-to-date/cache restore or HOL execution and reports the parse error immediately.

## Tactic timeout flow

```
--tactic-timeout 2.5   # default root-package timeout
--tactic-timeout 60    # slower smoke/debug runs
--tactic-timeout 0     # disables timeout entirely
```

The timeout applies only to the root package; dependency packages build with no tactic timeout.

On timeout:
1. Runtime timeout wrapper raises the timeout marker/failure
2. Child log records tactic label/plan position, source span, and input goal evidence where available
3. holbuild reports the timed-out tactic and **does not retry** through the plain non-instrumented fallback
4. Build fails

For full semantic production builds of large projects, use `--tactic-timeout 0`.

## Replay order

On a rebuild after source edit:
1. Compute theorem boundaries and dependency context from current source/project state
2. Try a valid failed-prefix checkpoint first when one matches the theorem header/pre-theorem bytes
3. Otherwise try the newest valid theorem-context checkpoint whose source prefix and dependency context match
4. Otherwise try a valid `deps_loaded.save`
5. Re-execute only the remaining suffix when replay succeeds

`always_reexecute = true` disables local up-to-date skipping and checkpoint replay for that action.

## Plan and trace inspection

```sh
holbuild execution-plan FooTheory:thm          # proof IR, static, no build lock/proof execution
holbuild goalfrag-plan FooTheory:thm           # legacy GoalFrag static plan
holbuild goalfrag-plan --new-ir FooTheory:thm  # deprecated alias for execution-plan
holbuild build --force --goalfrag-trace FooTheory
holbuild build --goalfrag --goalfrag-trace FooTheory  # legacy trace shape
```

Plan lines are executable tactic/list-tactic operations. Indentation/body text is formatting only; if a source construct executes as one HOL combinator boundary, it should display as one numbered step.

`--goalfrag-trace` executes a build and records runtime before/after goal counts and elapsed times in the child log. Use `--force` when an up-to-date artifact would otherwise skip source execution.

## REPL on failure

`build --repl-on-failure` serializes the build and, after a theory action fails, starts `hol repl` from the newest failed-prefix checkpoint when available, falling back to the replay/deps-loaded checkpoint. It requires checkpoints and is not supported with `--json`.

## Checkpoint paths

```
.holbuild/checkpoints/<package>/<relative-path>.deps/<deps_key>/deps_loaded.save[.ok]
.holbuild/checkpoints/<package>/<relative-path>.theorems/<deps_key>/<proof_engine>/<prefix_key>/
  <safe_name>_context.save[.ok]
  <safe_name>_end_of_proof.save[.ok]
.holbuild/checkpoints/<package>/<relative-path>.theorems/<deps_key>/<proof_engine>/.failed/
  <safe_name>_failed_prefix.save[.ok]
  <safe_name>_failed_prefix.save.meta
  <safe_name>_failed_prefix.save.prefix
.holbuild/checkpoints/<package>/<relative-path>.final_context.save[.ok]
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
| `HOLBUILD_CACHE_TRACE` | `1`/`true` = print cache decision trace |
| `HOLBUILD_STATUS` | `1`/`true` = enable status display, `0`/`false` = disable |
| `HOLBUILD_TIMING_LOG` | Path for structured timing data (tool + coarse phase lines, including `build.keys` action-key computation) |
| `HOLBUILD_TIMING_DETAIL` | Optional timing coarseness: unset/`coarse` logs coarse phases only; `fine` adds aggregate subphase lines such as external HOL key hashing/cache reads; `trace` is reserved for future per-item detail |
| `HOLBUILD_GOALFRAG_RUNTIME` | Override path to legacy `goalfrag_runtime.sml` |
