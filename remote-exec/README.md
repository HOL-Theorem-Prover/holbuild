# holbuild remote-exec coordinator and worker

Remote execution lets `holbuild` build a project's HOL theories on a fleet of
worker machines instead of the machine that asked for the build. The client
still plans the build; it uploads each uncached theory's inputs to the remote
cache (bazel-remote) and hands the coordinator a *batch*: the theories to build
and which of them depend on which. Workers ask the coordinator for work, build
one theory at a time with `holbuild exec-action`, and publish the result to the
same cache, where the client's normal cache restore picks it up. The client
side is `holbuild build --remote-exec` (see the top-level README).

This directory holds the coordinator, its Postgres schema, the worker loop and
a container image with both.

## Overview

- **Coordinator** (`remote_exec/app.py`, `remote_exec/coordinator.py`): a
  stateless FastAPI service over Postgres. Any number of replicas can run
  behind a load balancer; all shared state is in the database.
- **Postgres**: batches, their dependency edges, leases, failures, peak-memory
  hints and recent worker demand. It never holds a pointer to a result. An
  action is done when its key is in the cache's `/ac/`, so losing the database
  loses batch status and costs rebuilds, never a wrong build.
- **Worker loop** (`remote_exec/worker.py`): claims an action, runs `holbuild
  exec-action` on it with the holbuild release that exported it, heartbeats
  while it runs, and reports the result record.

## Running

The image (`docker build -t holbuild-remote-exec remote-exec`, on amd64 or
arm64) has Python with the coordinator's pinned dependencies, Poly/ML, and
what building holbuild and HOL takes. Its entrypoint takes `migrate`,
`coordinator` or `worker`:

```bash
docker run -e REMOTE_EXEC_DATABASE_URL=postgresql+asyncpg://user:pass@host/remote_exec holbuild-remote-exec migrate
docker run -p 8090:8090 -e REMOTE_EXEC_DATABASE_URL=... -e REMOTE_EXEC_CLIENT_TOKEN=... \
  -e REMOTE_EXEC_WORKER_TOKEN=... -e REMOTE_EXEC_CACHE_URL=https://user:pass@cache.example.org \
  holbuild-remote-exec coordinator [uvicorn options, default --host 0.0.0.0 --port 8090]
```

Without the image, from this directory: `uv sync`, then `uv run alembic
upgrade head` and `uv run uvicorn --factory remote_exec.app:app --port 8090`.

The coordinator reads its settings from the environment:

| Variable | Meaning | Default |
|---|---|---|
| `REMOTE_EXEC_DATABASE_URL` | the coordinator's database (`postgresql+asyncpg://…`) | required |
| `REMOTE_EXEC_CLIENT_TOKEN` | bearer token clients send | required |
| `REMOTE_EXEC_WORKER_TOKEN` | bearer token workers send | required |
| `REMOTE_EXEC_CACHE_URL` | remote cache base URL, for the `HEAD /ac/<ac-key>` readiness check; credentials go in its userinfo | required |
| `REMOTE_EXEC_LEASE_SECONDS` | lease length; a heartbeat renews it | 120 |
| `REMOTE_EXEC_MAX_ATTEMPTS` | claims of one action before a retryable failure becomes final | 3 |
| `REMOTE_EXEC_STANDARD_TIER_MB` | peak memory from which a theory goes to the high-memory tier | 16000 |
| `REMOTE_EXEC_RETENTION_HOURS` | age after which a finished batch is deleted | 168 |
| `REMOTE_EXEC_BATCH_DEADLINE_HOURS` | age at which a batch still running fails | 12 |
| `REMOTE_EXEC_HINT_TTL_DAYS` | age after which an unused peak hint is deleted | 30 |
| `REMOTE_EXEC_SWEEP_SECONDS` | period of the sweep (lease expiry, releases, retention, scaling) | 5 |
| `REMOTE_EXEC_WARM_WORKERS` | always-on standard-tier workers | 0 |
| `REMOTE_EXEC_MAX_BURST_WORKERS` | most burst workers to ask for | 0 |
| `REMOTE_EXEC_SCALE_DOWN_HOLD_S` | how long a higher burst worker count is kept after demand drops | 900 |
| `REMOTE_EXEC_SCALE_CMD` | command run as `<command> <burst workers>` when that count changes | none |

The database URL is read once, at start. When the database refuses the
coordinator's credentials, for instance after a password rotation, the
coordinator exits so that its supervisor restarts it with the current ones.

A worker:

```bash
docker run -e REMOTE_EXEC_WORKER_TOKEN=... -e HOLBUILD_REMOTE_CACHE_CURL_CONFIG_CONTENT='user = "user:pass"' \
  holbuild-remote-exec worker --coordinator https://exec.example.org --remote-cache https://cache.example.org \
  --cache-limit-gb 200 [--tier standard|high] [--also-claim standard] [--max-heap MB] [--cooperate-dir DIR] \
  [--share-heaps] [--holbuild-releases-dir DIR] [--protection-cmd COMMAND]
```

The remote cache's credentials are a curl config, as holbuild reads it from
the file `HOLBUILD_REMOTE_CACHE_CURL_CONFIG` names; the entrypoint writes
`HOLBUILD_REMOTE_CACHE_CURL_CONFIG_CONTENT` to such a file, readable only by
its user, so the credentials can come from the environment. `HOLBUILD_CACHE`
is `/var/cache/holbuild` in the image. It must be the worker's own cache root:
`exec-action --cache-limit-gb` sweeps the whole root before each action, so a
root shared with ordinary builds would lose their cache. Outside the image,
`python3 -m remote_exec.worker` runs the worker; it uses only the standard
library and `curl`. High-tier workers run with a larger `--max-heap` on bigger
machines; `--also-claim standard` lets them take standard-tier work when no
high-tier action is ready.

## Batches and actions

A batch is the text `holbuild action-spec --upload` prints:

```text
holbuild-action-batch-v1
action <input_key> <ac-key> <spec-sha256> <package>:<theory>
edge <input_key> <parent input_key>
```

Each `action` line is one theory to build; each `edge` says a theory needs
another theory of the same batch first. Parents that were already cached at
export have no edge.

An action moves through these states:

| State | Meaning |
|---|---|
| `waiting` | a parent isn't done, or its parents' keys haven't been checked in the cache yet |
| `ready` | claimable by a worker of its tier |
| `running` | leased to a worker |
| `done` | built, or found already cached |
| `failed` | failed finally; the batch failed with it |
| `cancelled` | its batch was cancelled or failed |

A batch is `running` until every action is `done` (then `done`), one fails
finally (`failed`, with a `failure` message), or the client cancels it
(`cancelled`).

## Scheduling rules

- **Release.** When all of an action's parents are done, the coordinator sends
  `HEAD /ac/<ac-key>` for each parent and makes the action ready only when
  every one answers 200. A parent the cache doesn't hold (404) is built again.
  When the cache can't be reached, the action waits for the next sweep. This
  is only a readiness hint; `exec-action` validates its inputs itself.
- **Claims** take the oldest batch's ready action of the worker's tier (or,
  when it has none, of its `also_claim` tiers, in order) with
  `FOR UPDATE SKIP LOCKED`, write a lease with an expiry and commit; no
  transaction stays open while the worker builds. An expired lease returns the
  action to waiting (see Retries), or fails it once it has been claimed `MAX_ATTEMPTS` times.
  A heartbeat or completion with an expired or revoked token is refused, and
  the completion is dropped. Since a worker may run an action twice after a
  network partition, nothing depends on exactly-once execution: a second run
  finds the result cached.
- **Retries** by the result's failure class:

  | `failure` | What happens |
  |---|---|
  | `memory` | on the standard tier, once more on the high-memory tier; on the high tier, final |
  | `publish`, `toolchain`, `internal` | retried, until the action has been claimed `MAX_ATTEMPTS` times |
  | `disk` | retried once; a second `disk` in a row, or `MAX_ATTEMPTS` claims, is final |
  | `input-missing` naming a theory of the batch | that theory is built again and the action waits for it, until the action has been claimed `MAX_ATTEMPTS` times |
  | any other `input-missing` (a blob, or a theory cached at export) | retried, since a restore that fails on a network error reports its input missing too; after `MAX_ATTEMPTS` claims the batch fails with `resubmit: …`; the next build exports a new batch |
  | `proof`, `tactic-timeout`, `spec-rejected` | final |

  A worker whose `exec-action` ends without a result record (it crashed or
  was killed) reports `internal` for it, so it is retried at once rather
  than when its lease expires.

  A retried action waits again like a child, so it runs only once its
  parents' keys answer `HEAD /ac/` again (one may have been rebuilt
  meanwhile); an expired lease is retried the same way. A final failure fails
  the batch and cancels its unfinished actions.
- **Placement.** Each built result's `peak-rss-mb` is stored as a hint for
  `(package, theory, profile)`; a memory failure on the standard tier stores
  `STANDARD_TIER_MB`. A theory whose hint reaches `STANDARD_TIER_MB` starts on
  the high-memory tier; with no hint it starts on the standard one. `profile`
  is the client's name for the run options it submitted the batch with, since
  they change how much memory a build takes.
- **Deadline.** A batch still running `BATCH_DEADLINE_HOURS` after its
  submission fails with `deadline: …`, so one that can't finish (a high-tier
  action with no high-tier worker, a parent check the cache keeps refusing,
  a client that went away) neither runs nor keeps workers busy forever.
- **Retention.** The sweep deletes finished batches older than
  `RETENTION_HOURS`, at most 100 per statement, never a running one, and peak
  hints not used for `HINT_TTL_DAYS`.

## Scaling

Workers come in two kinds: `REMOTE_EXEC_WARM_WORKERS` warm workers, always
running on the standard tier so a build starts at once, and burst workers,
which an external scaler starts and stops. On every sweep the coordinator
works out how many burst workers the queue needs: every ready or running
action beyond the warm workers, but at least one per ready or running
high-tier action, since warm workers take only standard-tier work, and at
most `REMOTE_EXEC_MAX_BURST_WORKERS`.

A build's dependency graph narrows and widens: a few theories everything else
waits on run alone, then many become ready together. Following the queue
exactly would stop burst workers at every narrow point and start them again
seconds later. So the target is the highest demand of the last
`REMOTE_EXEC_SCALE_DOWN_HOLD_S` seconds: it rises at once and falls only after
demand has stayed lower for that long. Each sweep records its demand in the
database, so a restarted coordinator keeps holding the target.

`GET /v1/queue` reports the counts and the target. With `REMOTE_EXEC_SCALE_CMD`
set, the coordinator also runs `<command> <target>` after a start and whenever
the target changes; a command that fails or runs over 60 seconds is logged
and run again on the next sweep, and never stops the sweep's other work. With
several coordinator replicas, give the command to one of them.

## Workers

### holbuild releases

`exec-action` accepts only actions exported by its own holbuild version and
runtime sources, and clients move to new releases on their own schedule, so a
worker can't run one fixed holbuild. Before each action it reads the
`holbuild-version` line of the action's spec (from `/cas/<spec_sha256>` in the
remote cache) and runs that release, from
`<--holbuild-releases-dir>/v<version>/bin/holbuild` (by default
`/opt/holbuild-releases`). A release the directory doesn't have yet is built
there on first use: the worker downloads its source tarball
(`--holbuild-source-url`, by default the GitHub archive of tag `v<version>`),
runs `make bin/holbuild` in place, since holbuild finds its runtime sources
where it was built, and marks the directory complete. Workers on one host can
share the directory: they build under an `flock` on its `.lock`, so a release
is built once and the others wait for it.

An action from a version with no release (a development build, or a tarball
that doesn't exist) is refused: the worker reports a `spec-rejected` result,
which fails the batch, and the client builds locally. A development build that
reuses a release's version number is refused by `exec-action` itself, since
its runtime sources differ.

### Scale-in protection

A scaler that removes idle workers mustn't stop one in the middle of an
action. With `--protection-cmd COMMAND`, the worker runs `COMMAND on` when it
takes an action and on each heartbeat, and `COMMAND off` when the action ends.
Without it, when `ECS_AGENT_URI` is set (as on Amazon ECS), it sets the task's
scale-in protection through the agent's `task-protection/v1/state` endpoint,
for 10 minutes at a time, so a worker that dies loses it. Failures are logged
and the action carries on.

## Wire format

Every request carries `Authorization: Bearer <token>`: the client token for
`/v1/batches…` and `/v1/queue`, the worker token for `/v1/work…`. A wrong or missing token
gets 401. Errors are JSON `{"detail": "<message>"}`.

### Client

`POST /v1/batches?profile=<name>` with the batch text as the body
(`text/plain`). `profile` defaults to `default`.

- 201 `{"batch_id": "<uuid>"}`
- 400 when the batch is malformed (bad header or line, duplicate action, an
  edge to a theory outside the batch)

`GET /v1/batches/<batch_id>`

- 200
  ```json
  {
    "batch_id": "<uuid>",
    "state": "running|done|failed|cancelled",
    "failure": "<message>|null",
    "actions": [
      {
        "input_key": "<sha256>",
        "theory": "<package>:<theory>",
        "state": "waiting|ready|running|done|failed|cancelled",
        "tier": "standard|high",
        "attempts": 1,
        "last_failure": "<failure class>|null",
        "log_sha256": "<sha256 of the last run's build log in /cas/>|null"
      }
    ]
  }
  ```
- 404 when there is no such batch (or it was deleted by retention)

`POST /v1/batches/<batch_id>/cancel`

- 200 `{"state": "<the batch's state after the call>"}`; cancelling a finished
  batch leaves it as it is
- 404 when there is no such batch

`GET /v1/batches/<batch_id>/events`

- 200, `application/x-ndjson`: one JSON object per line. It starts with every
  action's current state, then sends an action again whenever any of its
  fields changes, and ends with one batch line when the batch finishes:
  ```json
  {"type": "action", "input_key": "…", "theory": "…", "state": "…", "tier": "…", "attempts": 1, "last_failure": null, "log_sha256": null}
  {"type": "batch", "state": "done|failed|cancelled", "failure": "<message>|null"}
  ```
  A client detaches by closing the connection and reattaches by opening the
  stream again with the same `batch_id`.
- 404 when there is no such batch

`GET /v1/queue`

- 200 `{"waiting": 0, "ready_standard": 0, "ready_high": 0, "running_standard": 0, "running_high": 0, "desired_burst_workers": 0}`:
  the unfinished actions of running batches, and the burst worker target

### Worker

`POST /v1/work/claim` with `{"tier": "standard|high", "also_claim": ["standard|high", …], "worker": "<name>"}`
(`also_claim` is optional)

- 200 `{"attempt_token": "<uuid>", "spec_sha256": "<sha256>", "input_key": "<sha256>", "theory": "<package>:<theory>", "lease_s": 120}`
- 204 when nothing is ready for the tier

`POST /v1/work/<attempt_token>/heartbeat`, no body

- 200 `{"lease_s": 120}`: the lease now runs `lease_s` seconds from now
- 409 when the lease expired or was revoked (the batch was cancelled or
  failed); the worker stops the action

`POST /v1/work/<attempt_token>/complete` with the `holbuild-action-result-v1`
record `exec-action --result` wrote as the body (`text/plain`)

- 200 `{"accepted": true}`
- 400 when the record is malformed or is for another action than the lease's
  (a record with an empty `input-key`, which `exec-action` writes when it
  couldn't read the spec, is matched by its spec alone)
- 409 when the token is stale; the result is dropped

## Tests

The tests need a Postgres role that may create databases:

```bash
REMOTE_EXEC_TEST_DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost/postgres uv run pytest
```
