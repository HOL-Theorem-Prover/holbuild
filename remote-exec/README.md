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
  behind a load balancer; all shared state is in the database. A claim
  waiting for work is woken at once by its own process and rechecks every
  5 s for work another process made ready.
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

Migration `0005` adds the action class and its indexes; run migrations with
the coordinator stopped. To roll back to an image predating `0005`, first
pause run admission (`REMOTE_EXEC_RUN_SLOTS=0`, then restart), let running
runs finish and cancel queued run batches. Use the current image to run
`alembic downgrade 0004` before starting the older image, whose migration
code does not know revision `0005`.

Migration `0007` adds a nullable `batches.max_heap_mb` column. Old clients
leave it null; new workers use their default when an old coordinator omits
it from a claim. Before rolling back to an older image, use the current image
to run `alembic downgrade 0006`.

Migration `0006` adds a nullable column for each action's phase timings.
To roll back to an image predating `0006`, use the current image to run
`alembic downgrade 0005` first, then run the older image's `migrate` and
`coordinator`; that image's migration code does not know revision `0006`.

The coordinator reads its settings from the environment:

| Variable | Meaning | Default |
|---|---|---|
| `REMOTE_EXEC_DATABASE_URL` | the coordinator's database (`postgresql+asyncpg://…`) | required |
| `REMOTE_EXEC_CLIENT_TOKEN` | bearer token clients send | required |
| `REMOTE_EXEC_WORKER_TOKEN` | bearer token workers send | required |
| `REMOTE_EXEC_CACHE_URL` | remote cache base URL, for the readiness check of parents' entries; credentials go in its userinfo | required |
| `REMOTE_EXEC_LEASE_SECONDS` | lease length; a heartbeat renews it | 120 |
| `REMOTE_EXEC_MAX_ATTEMPTS` | claims of one action before a retryable failure becomes final | 3 |
| `REMOTE_EXEC_STANDARD_TIER_MB` | peak memory from which a theory goes to the high-memory tier | 16000 |
| `REMOTE_EXEC_RETENTION_HOURS` | age after which a finished batch is deleted | 168 |
| `REMOTE_EXEC_BATCH_DEADLINE_HOURS` | age at which a batch still running fails | 12 |
| `REMOTE_EXEC_HINT_TTL_DAYS` | age after which an unused peak hint is deleted | 30 |
| `REMOTE_EXEC_DATABASE_POOL_SIZE` | database connections the coordinator holds at most | 20 |
| `REMOTE_EXEC_DATABASE_POOL_TIMEOUT_S` | how long a request waits for a free connection before it fails | 10 |
| `REMOTE_EXEC_EVENTS_KEEPALIVE_SECONDS` | how long an event stream stays quiet before it sends an empty line | 15 |
| `REMOTE_EXEC_SWEEP_SECONDS` | period of the sweep (lease expiry, releases, retention, scaling) | 5 |
| `REMOTE_EXEC_RUN_SLOTS` | fleet-wide running run-action cap; 0 pauses new run claims | 30 |
| `REMOTE_EXEC_RUN_FLOOR` | running run actions allowed ahead of ready builds, clamped to `REMOTE_EXEC_RUN_SLOTS` | 0 |
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
  [--share-heaps] [--holbuild-releases-dir DIR] [--protection-cmd COMMAND] [--claim-wait-seconds 20] [--drain-seconds 20]
```

On `SIGTERM`, a worker stops claiming and gives its running action up to
`--drain-seconds` (20 by default) to finish and report its result. At the
deadline it stops the action's process group and reports `unavailable`, so
the coordinator retries immediately without counting the interrupted attempt.
Waiting for work or preparing a release stops immediately. Repeated `SIGTERM`
does not extend the deadline; interactive Ctrl-C retains its usual behavior.
Leave at least 10 seconds between the drain window and the container's stop
timeout for process cleanup and result reporting. For example, a 120-second
container stop timeout allows `--drain-seconds 95`. An unreachable coordinator
can still prevent reporting before the container is forcibly killed; its lease
then expires normally. ECS protection is best effort, and a rejection in an
HTTP-success response is logged along with transport failures.

The coordinator's `REMOTE_EXEC_CACHE_URL` (or `HOLBUILD_REMOTE_CACHE_URL` as a
fallback) and the worker's `--remote-cache` (or `HOLBUILD_REMOTE_CACHE_URL`)
accept comma-separated cache nodes. Whitespace separators also work; trailing
slashes and duplicate nodes are removed. Inline credentials are excluded from
node identity, so they agree with curl-config authentication. Use the same
node hostnames and paths as the clients:
coordinator reads and worker bootstrap spec downloads use holbuild's digest
ranking and second-node fallback, including a read's 404 during handoff.
See the top-level README's remote-cache configuration for the routing contract.

Before enabling multiple cache nodes, upgrade the coordinator, workers and
submitting clients to a release that supports cache rings, and drain batches
whose specs name older holbuild releases. Workers run the release named in
each spec; an older release treats the entire list as one URL.

The remote cache's credentials are a curl config, as holbuild reads it from
the file `HOLBUILD_REMOTE_CACHE_CURL_CONFIG` names; the entrypoint writes
`HOLBUILD_REMOTE_CACHE_CURL_CONFIG_CONTENT` to such a file, readable only by
its user, so the credentials can come from the environment. `HOLBUILD_CACHE`
is `/var/cache/holbuild` in the image. It must be the worker's own cache root:
`exec-action --cache-limit-gb` sweeps the whole root before each action, so a
root shared with ordinary builds would lose their cache. `exec-action` runs
with the worker's `HOLBUILD_*` build settings, `PATH`, `HOME`, `TMPDIR`, the
locale, and curl's certificate and proxy settings. It excludes
`HOLBUILD_REMOTE_EXEC_*`, `HOLBUILD_REMOTE_CACHE_DISCOVERY_TOKEN` and inherited
discovery curl configs; with discovery enabled it receives only the worker's
generated read-only discovery config (see below). The worker token stays out
of the builds' environment and discovery files. A
build runs as the worker's user, so one that goes looking can still read the
token from the worker's `/proc/<pid>/environ`. Outside the image,
`python3 -m remote_exec.worker` runs the worker; it uses only the standard
library and `curl`. A batch can override the worker's `--max-heap` default
(12000 MB); `--also-claim standard` lets them take standard-tier work when no
high-tier action is ready. With `--cooperate-dir`, a worker claims only while
holbuild's memory admission in that directory would start one more child
there, so an action a busy host couldn't start yet stays at the coordinator
for a worker on another host.

Each claim and heartbeat also reports the worker's host: its id (the kernel's
`boot_id`, the same in every container on the host), the share of CPU time
idle since the worker's previous CPU sample (iowait counts as busy), its
memory as holbuild's admission sees it, and whether that admission would
hold a child back now or held the worker back since its last report. A
report is left out when the host can't be read at once, as while an
admission holds the cooperate dir's lock. `GET /v1/queue` lists them, so a
reader can tell whether hosts have CPU to spare or are short of memory.

Each claim also reports where the worker's time went since its previous
claim, in seconds per phase, so a reader of `GET /v1/queue` can tell what
workers do when they aren't running HOL:

- `memory_wait`: waiting for the host's memory before claiming;
- `claim`: in claim requests, waiting ones included;
- `idle`: sleeping after a claim that got nothing or failed, or after an
  action failed in the worker;
- `lease`: taking and giving up a claimed action's lease: setting and
  clearing scale-in protection, and stopping the heartbeat;
- `release`: finding and, on first use, building the action's holbuild release;
- `before_hol`, `hol`, `after_hol`: running `exec-action`, split at the start
  of its first HOL child and the end of its last (fetching and restoring
  inputs before, publishing outputs and checkpoints after). A HOL child is a
  descendant of `exec-action` holding a `--cooperate-dir` lease, which the
  worker looks for every second;
- `exec`: all of `exec-action`, for a worker without `--cooperate-dir`;
- `complete`: reporting the result.

## Action isolation

Workers require Linux on x86_64 or aarch64, Landlock ABI 1 or newer,
Python 3, and `libseccomp.so.2`. The supplied image includes the userspace
dependencies. The container's seccomp profile must permit Landlock and
stacking another seccomp filter. `holbuild sandbox-check` exercises these
requirements; workers reject a release whose check fails. Releases before
0.13.53 are rejected because their HOL launch path has no mandatory sandbox.
Upgrade submitting clients before replacing workers with this version.

The worker and `exec-action` remain trusted: they fetch inputs, manage memory
leases and publish results. Each HOL process runs with a Landlock filesystem
policy and a seccomp syscall filter. It receives read access to its selected
HOL toolchain, holbuild runtime, Poly/ML and system runtime files, and write
access to fresh action, checkpoint, home and temporary directories. Shared
cache files are copied into these directories. The directories are removed
after the action, including when shared heaps are disabled. The child receives
no cache credentials, worker token, inherited lease descriptors or Linux
capabilities. Cross-process inspection, signals to other processes, metadata
changes, links and special-file creation are denied. The supervisor kills
and reaps descendants before validating and harvesting regular, unlinked
output files. Unsupported confinement fails closed.

HOL toolchain bootstrap executes trusted source. Before using a toolchain,
workers require its revision to be a commit ancestor of an approved branch.
The default approves `develop` and `master` in the canonical HOL repository.
Administrators may replace these defaults with whitespace-separated
`HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES` entries of the form
`https://example.org/HOL.git=develop,master` for trusted mirrors or forks.
Only these branch refs are fetched, never pull-request refs or arbitrary
revision objects. Proven ancestry is reused from a worker-owned Git graph;
a branch history rewrite takes effect when the next unknown revision triggers
a refresh. Use protected branches for these trust roots.
Bootstrap compiler/build children also have credential settings removed from
their environment. This restriction is worker configuration, not an action
spec option. Administrators can grant additional read-only runtime directories
with colon-separated `HOLBUILD_ACTION_READ_DIRS`; do not include credentials
or shared writable state in these directories.

This boundary protects worker credentials and shared filesystem state. It
does not restrict network egress or replace authorization on the remote cache.
The trusted HOL parser and compiler used before execution remain part of the
worker's trusted code.

## Batches and actions

A batch is the text `holbuild action-spec --upload` prints:

```text
holbuild-action-batch-v1
action <input_key> <ac-key> <spec-sha256> <package>:<theory>
edge <input_key> <parent input_key>
```

The client sends its `--max-heap MB` as the optional positive integer query
parameter `max_heap_mb` on `POST /v1/batches`. The coordinator stores it with
the batch and returns it on `/v1/work/claim`; workers pass it to `exec-action`.
When absent or null, the worker uses its own `--max-heap` setting. This limit
is execution policy and does not change action keys.

A batch has one class: `build` (the default) or `run`, selected with
`POST /v1/batches?class=run`. Run actions execute submitted scripts in cached
HOL contexts through the same worker protocol. The coordinator stores the
class on every action and treats its `input_key` as opaque.
Run batches contain independent actions and accept no dependency edges;
submitting a run batch with an `edge` returns 400.

Each `action` line is one theory to build or one script to run; each `edge`
says a theory needs another theory of the same batch first. Parents that were already cached at
export have no edge.

An action moves through these states:

| State | Meaning |
|---|---|
| `waiting` | a parent isn't done, or its parents' keys haven't been checked in the cache yet |
| `ready` | claimable by a worker of its tier |
| `running` | leased to a worker |
| `done` | built, or found already cached |
| `failed` | failed finally; a build batch fails with it, while other actions of a run batch continue |
| `cancelled` | its batch was cancelled or failed |

A batch is `running` until every action is `done` (then `done`), one fails
finally (`failed`, with a `failure` message), or the client cancels it
(`cancelled`). A run batch instead finishes `done` once every action is
`done` or `failed`; each failed action retains its `last_failure` and log in
status and events. A batch-level `deadline` or `resubmit` failure still ends
a run batch and cancels its unfinished actions.

## Scheduling rules

- **Release.** When all of an action's parents are done, the coordinator
  fetches each parent's entry, `GET /ac/<ac-key>`, and makes the action ready
  when every one answers 200. A parent whose entry the cache doesn't hold
  (404) is built again. When the cache can't be reached, the action waits for
  the next sweep. This is only a readiness hint; `exec-action` validates its
  inputs itself. The entry's blobs aren't asked about: holbuild uploads them
  before the entry, and one that expires before it makes the child that
  restores the parent report `input-missing` for that parent, which is then
  built again (see Retries); the child spends one attempt on it. An entry
  found is trusted for 60 s without asking again, so a child released on it
  after the cache evicted it reports `input-missing` the same way; any
  `input-missing` result makes the coordinator process that gets it forget
  every entry it found, so its next release asks again.
- **Claims** take builds before runs across all tiers the worker accepts
  by default. To prevent runs from starving behind a continuously ready
  build queue, set `REMOTE_EXEC_RUN_FLOOR` above 0: while fewer than that
  many runs are running fleet-wide, a ready run in the worker's accepted
  tiers takes priority. The floor is clamped to `REMOTE_EXEC_RUN_SLOTS`;
  above it, builds take priority and runs use idle capacity up to the cap.
  Within the selected class, claims prefer the worker's tier over its
  `also_claim` tiers, in order.
  Within each coordinator process, waiting claims prefer standard-primary
  workers for standard work, then hosts in ascending host-id order, with
  FIFO ties. Claims without a host report follow known hosts of the same
  primary tier. Polling claims defer each tier to better-ranked waiters;
  a waiting standard-only worker still leaves high work available to burst
  workers. This packs work so excess tail hosts can drain for scale-in.
  Packing is best effort among that process's waiting claims; it neither
  moves running actions nor coordinates host preference across replicas.
  Run admission is serialized across coordinator replicas and permits at
  most `REMOTE_EXEC_RUN_SLOTS` running run actions fleet-wide; 0 pauses new
  runs without stopping actions already running. An unlocked precheck
  bypasses run admission when the floor is full or no compatible run is
  ready, keeping build claims concurrent. Capacity is checked again under
  the admission lock. Set the floor back to 0 and restart the coordinator
  to restore strict build priority. Claims select with `FOR UPDATE SKIP LOCKED`,
  write a lease with an expiry and commit; no transaction stays open while
  the worker builds. Among the running batches, the claim picks the one with
  the fewest running actions, then the one that least recently had an action
  claimed (one that never had goes first), then the oldest: a new batch gets
  the next free worker even while a wide one holds the rest, and batches
  take turns when there are more of them than workers. Within the batch, it
  picks the action with the longest chain of dependents in the batch, then
  the one with the most dependents, then by theory name, so the critical
  path starts first and the ready frontier widens fastest. An expired lease returns the
  action to waiting (see Retries), or fails it once it has been claimed `MAX_ATTEMPTS` times.
  A heartbeat or completion with an expired or revoked token is refused, and
  the completion is dropped. Since a worker may run an action twice after a
  network partition, nothing depends on exactly-once execution: a second run
  finds the result cached.
- **Retries** by the result's failure class:

  | `failure` | What happens |
  |---|---|
  | `memory` | on the standard tier, retried on the high-memory tier; on the high tier, retried there, until the action has been claimed `MAX_ATTEMPTS` times |
  | `publish`, `toolchain`, `internal` | retried, until the action has been claimed `MAX_ATTEMPTS` times |
  | `disk` | retried once; a second `disk` in a row, or `MAX_ATTEMPTS` claims, is final |
  | `input-missing` naming a theory of the batch other than the action itself or one that depends on it | that theory is built again and the action waits for it, until the action has been claimed `MAX_ATTEMPTS` times |
  | any other `input-missing` (a blob, a theory cached at export, or one that can't be the action's input) | retried, since a restore that fails on a network error reports its input missing too; after `MAX_ATTEMPTS` claims the batch fails with `resubmit: …`, naming the theory as `theory <input_key>`; the client resubmits once with that theory and every theory that depends on it, and otherwise the next build exports a new batch |
  | `unavailable` | retried without counting the claim |
  | `proof`, `tactic-timeout`, `spec-rejected`, `script`, `timeout` | final; `script` means the script failed or omitted an output, `timeout` means it exceeded its time limit |

  A worker that gets no answer from the cache for the action's spec, 429,
  5xx or a transfer cut short, as while the cache restarts, reports
  `unavailable`, as `exec-action` does when the cache fails it so while
  fetching the action's inputs or publishing its result. Any other error
  in the worker (`exec-action` ended without a result record because it
  crashed or was killed, the release didn't build, the cache doesn't have the
  spec) is reported as `internal`, so the action is retried at once rather
  than when its lease expires. After either, the worker waits before it
  claims again, so a cache outage doesn't run it through the ready actions.

  A retried action waits again like a child, so it runs only once the cache
  holds its parents again, or held them within the 60 s above (one may have
  been rebuilt meanwhile); an expired lease is retried the same way. A final failure fails
  a build batch and cancels its unfinished actions; a final run-action
  failure affects only that action. Exhausted leases record `internal` on
  the failed run action.
- **Placement.** Each built result's `peak-rss-mb` raises the hint for
  `(package, theory, profile)`, and a memory failure on the standard tier
  raises it to `STANDARD_TIER_MB`; a run that takes less never lowers it,
  since on a host without hard per-container memory limits a quiet run says
  little. A theory moved to the high-memory tier so stays there while it is
  built at least every `HINT_TTL_DAYS`; a memory failure on the high tier is
  retried, so one caused by a neighbour doesn't fail the batch. A theory whose hint reaches `STANDARD_TIER_MB` starts on
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
which an external scaler starts and stops. On batch intake and every sweep,
the coordinator works out how many burst workers the queue needs: every ready or running
action beyond the warm workers, but at least one per ready or running
high-tier action, since warm workers take only standard-tier work, and at
most `REMOTE_EXEC_MAX_BURST_WORKERS`. Runs contribute only up to
`REMOTE_EXEC_RUN_SLOTS` in both the total and high-tier demand terms;
high-tier builds remain uncapped except by `MAX_BURST_WORKERS`:

```text
active = ready_build + running_build + min(RUN_SLOTS, ready_run + running_run)
high = ready_high_build + running_high_build + min(RUN_SLOTS, ready_high_run + running_high_run)
demand = min(MAX_BURST_WORKERS, max(0, active - WARM_WORKERS, high))
```

A build's dependency graph narrows and widens: a few theories everything else
waits on run alone, then many become ready together. Following the queue
exactly would stop burst workers at every narrow point and start them again
seconds later. So the target is the highest demand of the last
`REMOTE_EXEC_SCALE_DOWN_HOLD_S` seconds: it rises at once and falls only after
demand has stayed lower for that long. Each scale check records its demand
in the database, so a restarted coordinator keeps holding the target.

Nonempty batch submissions request a background scale check immediately after
making root actions ready. Concurrent requests are coalesced, and intake and
sweep checks share a lock so scale commands never overlap within a coordinator.

`GET /v1/queue` reports the counts and the target. With `REMOTE_EXEC_SCALE_CMD`
set, the coordinator also runs `<command> <target>` after a start and whenever
the target changes; a command that fails or runs over 60 seconds is logged
and run again on the next sweep, and never stops the sweep's other work.
`GET /v1/queue`'s `scaler` shows the command's last run in that process. With
several coordinator replicas, give the command to one of them.

## Workers

### holbuild releases

`exec-action` accepts only actions exported by its own holbuild version and
runtime sources, and clients move to new releases on their own schedule, so a
worker can't run one fixed holbuild. Before each action it reads the
`holbuild-version` line of the action's spec (from `/cas/<spec_sha256>` in the
remote cache) and runs that release. It first checks
`/opt/holbuild-baked/v<version>/bin/holbuild` for an executable file; override
the root with `--baked-releases DIR` or `REMOTE_EXEC_BAKED_RELEASES`. Derived
images can preinstall releases here to avoid downloading and compiling them
on first use. Keep each release's runtime sources with its executable: use
an installed tree (`bin/holbuild` plus `share/holbuild`) or a source tree built
at that exact path. A hit needs no writable release cache or lock.

If the baked executable is absent or not executable, the worker automatically
uses the existing on-demand path, from
`<--holbuild-releases-dir>/v<version>/bin/holbuild` (by default
`/opt/holbuild-releases`). A release the directory doesn't have yet is built
there on first use: the worker downloads its source tarball
(`--holbuild-source-url`, by default the GitHub archive of tag `v<version>`),
runs `make bin/holbuild` in place, since holbuild finds its runtime sources
where it was built, and marks the directory complete. Workers on one host can
share the directory: they build a release under an `flock` on its
`v<version>.lock`, so it is built once and the others wait for it, while
other versions build alongside.

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

`POST /v1/batches?profile=<name>&class=build|run` with the batch text as the body
(`text/plain`). `profile` defaults to `default`; `class` defaults to `build`.
An unknown class returns 422.

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
        "log_sha256": "<sha256 of the last run's build log in /cas/>|null",
        "timings": {"<phase>": <ms>, ..., "wall": <ms>}|null
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
  fields changes, and ends with one batch line when the batch finishes. A
  stream with nothing to send for `REMOTE_EXEC_EVENTS_KEEPALIVE_SECONDS` sends
  an empty line, which clients skip, so a proxy doesn't close it as idle:
  ```json
  {"type": "action", "input_key": "…", "theory": "…", "state": "…", "tier": "…", "attempts": 1, "last_failure": null, "log_sha256": null, "timings": null}
  {"type": "batch", "state": "done|failed|cancelled", "failure": "<message>|null"}
  ```
  A client detaches by closing the connection and reattaches by opening the
  stream again with the same `batch_id`.
- 404 when there is no such batch

`GET /v1/queue`

- 200 `{"waiting": 0, "ready_standard": 0, "ready_high": 0, "running_standard": 0, "running_high": 0, "ready_run": 0, "running_run": 0, "run_slots": 30, "run_floor": 0, "desired_burst_workers": 0, "hosts": [<host>, …], "phases": <phases>, "scaler": <scaler>}`:
  the unfinished actions of running batches, the configured run cap (`run_slots`)
  and effective reserved floor (`run_floor`, clamped to that cap), the burst worker target, the
  hosts whose workers reported to this coordinator process in the last 2
  minutes, by id, the sums of the phase reports it got in the last 10
  minutes (see "Running"), and the last run of `REMOTE_EXEC_SCALE_CMD` in
  this process (`null` before its first), with the burst worker target it
  got and its error (`null` when it exited 0):
  ```json
  {"workers": 8, "at": "2026-01-01T12:00:00+00:00", "error": "scale 8 exited 1"}
  ```
  The phases:
  ```json
  {"window_s": 600, "reports": 4210, "seconds": {"memory_wait": 0.0, "claim": 812.4, "idle": 0.0, "lease": 12.5, "release": 31.0, "before_hol": 40210.7, "hol": 52300.2, "after_hol": 44102.9, "exec": 0.0, "complete": 950.3}}
  ```
  Tier counts include both classes; `ready_run` and `running_run` are the
  run subsets across tiers. A phase's share of the workers' time is its
  seconds over the sum of all. A host is its workers' latest report,
  `age_s` seconds old,
  except that `cpu_idle_pct` is the latest one measured:
  ```json
  {"id": "<boot_id>", "cpu_idle_pct": 31.5, "mem_total": 133680000000, "mem_available": 61200000000, "budget": 120800000000, "reserved": 92300000000, "leases": 29, "memory_short": false, "age_s": 1.2}
  ```
  Memory is in bytes: `MemTotal` and `MemAvailable`, the `--cooperate-dir`
  budget, the charges of the leases held there and their number;
  `memory_short` is true when admission would hold back a child of the
  worker's `--max-heap` now, or held the worker back from claiming since its
  previous report.

### Worker

`POST /v1/work/claim` with `{"tier": "standard|high", "also_claim": ["standard|high", …], "worker": "<name>", "wait_s": 20, "host": <report>, "phases": {"<phase>": <seconds>, …}}`
(`also_claim`, `wait_s`, `host` and `phases` are optional; `phases` gives the
seconds the worker spent in each phase since its previous claim, each
non-negative, a missing phase 0; `wait_s` is how long the coordinator
holds the request open for an action to become ready, 0 by default and at
most 50, so that a proxy's usual 60 s idle timeout doesn't cut it; `host` is
the worker's report of its host, a host of `GET /v1/queue` without `age_s`,
with `cpu_idle_pct` measured since the worker's previous CPU sample, or null
when that is under a second old)

- 200 `{"attempt_token": "<uuid>", "spec_sha256": "<sha256>", "input_key": "<sha256>", "theory": "<package>:<theory>", "lease_s": 120}`
- 204 when nothing became ready for the tier within `wait_s`

`POST /v1/work/<attempt_token>/heartbeat`, with no body or `{"host": <report>}`

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

A worker that can't reach the coordinator or gets a 5xx, as while the
coordinator restarts, retries a `complete` until the action's lease would run
out.

## Tests

The tests need a Postgres role that may create databases:

```bash
REMOTE_EXEC_TEST_DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost/postgres uv run pytest
```

## Temporary cache members

The coordinator can keep a stable permanent cache ring while adding temporary
members with worker demand. `GET /v1/cache/members` accepts the client, worker,
or derived read-only discovery bearer token and returns `text/plain`:

```text
holbuild-cache-members-v1
https://cache-a.example
https://cache-b.example
https://cache-c.example
```

The permanent configured URLs are always present. The API carries canonical
identities without credentials. A temporary member appears only after its
adapter has verified DNS, TLS and authenticated CAS write/read readiness.
`GET /v1/cache/slots` (client token) lists each assigned slot, owner, lifecycle
phase and last operation error; it omits provider operation tokens. A successful
heartbeat clears a transient error even while a member is serving or waiting
for its drain interval.

Clients refresh membership every 30 seconds when the deployment sets
`HOLBUILD_REMOTE_CACHE_DISCOVERY_URL`. Set `HOLBUILD_REMOTE_CACHE_ALLOWED_URLS`
to the comma-separated identities allowed to receive the cache credential,
including the permanent pair and every reserved temporary identity. Discovery
can only select from that list. A response containing credentials, an unknown
endpoint or an omitted permanent member is rejected. Existing inline cache
credentials and `HOLBUILD_REMOTE_CACHE_CURL_CONFIG` continue to authenticate
cache requests. Discovery uses `HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG`
(or `HOLBUILD_REMOTE_EXEC_CURL_CONFIG`), a curl config holding the coordinator
bearer header. With credentials, inline or from a cache curl config, every
allowed endpoint must be `https://`: otherwise clients skip discovery and
workers refuse to start.
Workers instead write a derived read-only token to a temporary
curl configuration file for the child: HMAC-SHA256 of `holbuild-cache-members-v1`
keyed by the worker token, encoded as lowercase hex. Only the membership
endpoint accepts this token; it cannot claim work, heartbeat, report results,
submit batches or inspect the queue. The worker bearer is never written to
this file, and `HOLBUILD_REMOTE_EXEC_*` settings are excluded from the child
environment. Cache credentials remain separate and stay in trusted worker and
`exec-action` processes; the HOL sandbox does not receive them.

Upgrade the coordinator before workers so it accepts derived discovery tokens.
Older coordinators reject them, leaving child discovery on the permanent cache
ring; workers never fall back to exposing their bearer. Existing clients and
workers remain compatible with the upgraded coordinator. Workers keep passing
the permanent ring as `--remote-cache`: it is the child's validation and stale
fallback baseline, while live discovery updates the effective ring throughout
an action. Python independently refreshes the ring for release-spec downloads.
Discovery never follows redirects. If it fails, the last complete ring remains
usable for 60 seconds, after which requests use the permanent configuration.
Recovery from permanent fallback counts as a new join.
For 60 seconds after observing a joined member, GET/HEAD can try every ready
member to find an object whose former owner has not uploaded it yet. Outside
that join grace, a miss tries at most two nodes. If both nodes fail with
transport errors, 429 or 5xx, reads can continue through the snapshot so stale
readers can bypass concurrent drains. Writes always keep the two-node bound.

### Capacity adapter

`REMOTE_EXEC_CACHE_POOL_CMD` is a deployment-owned executable, not a shell
snippet. The coordinator sends one JSON request on stdin, reads one JSON
response from stdout, and limits each invocation to 20 seconds. Keep cloud
SDKs and permissions in the deployment layer. The adapter protocol's typed
request and response are `AdapterRequest` and `AdapterResponse` in
`remote_exec/cache_pool.py`. Long operations return a token and are polled;
commands must be idempotent across retries and coordinator crashes. Opaque
provider ownership data is persisted separately from operation tokens, before
any DNS publication.

Configure one to four `REMOTE_EXEC_CACHE_SLOTS` as a JSON list of
`{"name":"slot-c","url":"https://cache-c.example"}`. A slot URL may be
`http://` only for a credential-free cache on a private network: the
coordinator then requires `REMOTE_EXEC_CACHE_URL` to be `http://` and carry no
credentials, since discovery hands those to every slot. The existing Postgres
database stores ownership; a dedicated advisory lock elects one controller,
without holding a database transaction open during provider calls. The
controller keeps reconciling and heartbeating hooks when capacity is disabled,
so disabling scale-out can still drain existing instances.

`REMOTE_EXEC_CACHE_WORKERS_PER_NODE` maps the existing held burst-worker target
to cache capacity by ceiling division, capped at the number of slots. Each
controller rereads shared held demand while holding the capacity writer lock;
a delayed replica cannot overwrite it with a local snapshot. The
default is 15 worker tasks per added cache; zero requests no temporary capacity.
This counts worker tasks rather than their hosts. Validate the configured ratio
with deployment load before enabling it. Provider CPU scale-out recommendations
are combined with the worker floor by the same capacity writer and held for
`REMOTE_EXEC_SCALE_DOWN_HOLD_S`; they cannot lower the worker target.

A retiring member leaves discovery, then its ingress stops gracefully. The
adapter records when ingress actually finished stopping. Only after at least
`REMOTE_EXEC_CACHE_DRAIN_SECONDS` (minimum and default 60) may the controller
ask for durability verification. It stops the backend, withdraws only that
owner's DNS, and completes termination only after positive durability proof.
A timer alone is insufficient. Failed operations retain the slot and hook and
are reported through the slot endpoint and coordinator logs. A finite provider
hook timeout or a host crash remains a failure boundary, not a successful
drain. Slot reuse waits for authoritative termination confirmation and DNS
cleanup; missing inventory alone is not confirmation.

Deploy the discovery-capable release to clients and every worker-selected
release before enabling capacity. Exercise concurrent claims, failed boots,
failed drains, stale readers, DNS ownership and a real scale-out/scale-in cycle
in the deployment environment. Rollback requests zero temporary capacity and
uses the same drain path while retaining the permanent ring and registry.

Launch assignment time is persisted. `REMOTE_EXEC_CACHE_LAUNCH_TIMEOUT_SECONDS`
(default 900) bounds configuration/readiness retries across coordinator restarts.
An explicit adapter launch error or an expired deadline starts the same verified
drain path, then the adapter abandons the unadmitted launch after backend stop
and DNS withdrawal. Heartbeats continue during cleanup; a failed launch cannot
become a serving member. A provider hook deadline remains a failure boundary.

If provider inventory confirms that a launch was admitted but its acknowledgement
was lost, reconciliation resumes admission even after the launch deadline.
