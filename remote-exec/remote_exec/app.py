"""HTTP interface of the remote-exec coordinator. Run with ``uvicorn --factory remote_exec.app:app``."""

import asyncio
import contextlib
import hmac
import json
import logging
import os
import time
from collections import Counter
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from dataclasses import asdict
from datetime import UTC, datetime
from typing import Literal
from uuid import UUID

import sqlalchemy as sa
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field, SecretStr
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from remote_exec.auth import cache_discovery_token
from remote_exec.coordinator import (
    DATABASE_UNAVAILABLE,
    ActionStatus,
    Coordinator,
    HostReport,
    PhaseReport,
    ResultMismatch,
    Settings,
    is_auth_failure,
)
from remote_exec.formats import Batch, FormatError, parse_batch, parse_result

logger = logging.getLogger(__name__)
# Under uvicorn's own logger, which uvicorn sends to stderr at INFO; this module's would show only warnings.
summary_logger = logging.getLogger("uvicorn.requests")
SUMMARY_SECONDS = 60.0
SUBMIT_SLOW_SECONDS = 10.0  # a POST /v1/batches that takes this long is logged

Tier = Literal["standard", "high"]


class ClaimRequest(BaseModel):
    tier: Tier
    also_claim: list[Tier] = Field(default_factory=list)  # tried in order once `tier` has nothing ready
    worker: str
    wait_s: float = Field(default=0, ge=0, le=50)  # how long to wait for an action when none is ready
    host: HostReport | None = None
    phases: PhaseReport | None = None  # where the worker's time went since its last claim
    ahead: bool = False  # the worker can run an action claimed ahead of its parents


class HeartbeatRequest(BaseModel):
    host: HostReport | None = None


class ReportRequest(BaseModel):
    """A worker's report of its host while it doesn't claim, as while it waits for disk space."""

    tier: Tier
    also_claim: list[Tier] = Field(default_factory=list)
    worker: str
    host: HostReport | None = None


def exit_on_auth_failure(error: BaseException) -> None:
    """Exit when the database refused the coordinator's credentials, so its supervisor restarts it with the
    current ones; the database URL is read only at start."""
    if is_auth_failure(error):
        logger.critical("the database refused the coordinator's credentials; exiting: %s", error)
        os._exit(1)


def bearer(token: SecretStr) -> Callable[[str | None], Awaitable[None]]:
    expected = f"Bearer {token.get_secret_value()}".encode()

    # Async, as is cache_reader: FastAPI runs a plain function dependency in a thread, a hop on every request.
    async def check(authorization: str | None = Header(default=None)) -> None:
        if not hmac.compare_digest((authorization or "").encode(), expected):
            raise HTTPException(401, "bad or missing bearer token")

    return check


async def text_body(request: Request) -> str:
    try:
        return (await request.body()).decode()
    except UnicodeDecodeError as error:
        raise HTTPException(400, f"body is not UTF-8: {error}") from error


# Requests by method, route and status since the last summary line, which totals what uvicorn's access log lists line by
# line.
type ResponseCounts = Counter[tuple[str, str, int]]


class CountResponses:
    """ASGI middleware adding each response to ``counts``, by method, route template (``-`` for no route) and status;
    a request that raised counts as a 500, which the outer error handler answers."""

    def __init__(self, app: ASGIApp, counts: ResponseCounts) -> None:
        self.app = app
        self.counts = counts

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        started = False

        async def counted(message: Message) -> None:
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
                self.counts[_response_key(scope, message["status"])] += 1
            await send(message)

        try:
            await self.app(scope, receive, counted)
        except Exception:
            if not started:
                self.counts[_response_key(scope, 500)] += 1
            raise


def _response_key(scope: Scope, status: int) -> tuple[str, str, int]:
    route = scope.get("route")
    return scope["method"], getattr(route, "path", "-"), status


def summary_line(counts: ResponseCounts, seconds: float, cpu_seconds: float) -> str:
    """One log line of the responses in ``counts`` over the last ``seconds``, most frequent first, and the CPU the
    process used meanwhile."""
    total = sum(counts.values())
    per_request = f", {1000 * cpu_seconds / total:.1f} ms each" if total else ""
    responses = ", ".join(f"{method} {route} {status} {n}" for (method, route, status), n in counts.most_common())
    return f"{total} responses in {seconds:.0f} s, {cpu_seconds:.1f} CPU-s{per_request}: {responses}"


def create_app(coordinator: Coordinator, settings: Settings) -> FastAPI:
    """The coordinator's routes over ``coordinator``; the lifespan runs the periodic sweep and closes it."""

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        async def sweep_forever() -> None:
            while True:
                try:
                    await coordinator.sweep()
                except Exception as error:
                    exit_on_auth_failure(error)
                    logger.exception("sweep failed")
                await asyncio.sleep(settings.sweep_seconds)

        async def cache_pool_forever() -> None:
            while True:
                try:
                    if coordinator.cache_pool is not None:
                        await coordinator.cache_pool.reconcile(coordinator.clock())
                except Exception as error:
                    exit_on_auth_failure(error)
                    logger.exception("cache pool reconciliation failed; keeping lifecycle ownership")
                await asyncio.sleep(settings.sweep_seconds)

        async def summarize_forever() -> None:
            at, cpu = time.monotonic(), time.process_time()
            try:
                while True:
                    await asyncio.sleep(SUMMARY_SECONDS)
                    now, now_cpu = time.monotonic(), time.process_time()
                    summary_logger.info(summary_line(counts, now - at, now_cpu - cpu))
                    counts.clear()
                    at, cpu = now, now_cpu
            finally:  # the part of a minute before a shutdown, so a restart loses none of its counts
                summary_logger.info(summary_line(counts, time.monotonic() - at, time.process_time() - cpu))

        pool_controller = asyncio.create_task(cache_pool_forever()) if coordinator.cache_pool is not None else None
        sweeper = asyncio.create_task(sweep_forever())
        summarizer = asyncio.create_task(summarize_forever())
        try:
            yield
        finally:
            summarizer.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await summarizer
            sweeper.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await sweeper
            if pool_controller is not None:
                pool_controller.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await pool_controller
            await coordinator.aclose()

    counts: ResponseCounts = Counter()
    app = FastAPI(title="holbuild remote-exec coordinator", lifespan=lifespan)
    app.add_middleware(CountResponses, counts=counts)
    app.state.response_counts = counts
    client = [Depends(bearer(settings.client_token))]
    worker = [Depends(bearer(settings.worker_token))]
    discovery_token = cache_discovery_token(settings.worker_token.get_secret_value())

    async def cache_reader(authorization: str | None = Header(default=None)) -> None:
        supplied = (authorization or "").encode()
        valid = [hmac.compare_digest(supplied, f"Bearer {token}".encode())
                 for token in (settings.client_token.get_secret_value(), settings.worker_token.get_secret_value(),
                               discovery_token)]
        if not any(valid):
            raise HTTPException(401, "bad or missing bearer token")

    @app.get("/v1/cache/members", dependencies=[Depends(cache_reader)], response_class=Response)
    async def cache_members() -> Response:
        urls = await coordinator.cache_members()
        return Response("holbuild-cache-members-v1\n" + "\n".join(urls) + "\n", media_type="text/plain",
                        headers={"Cache-Control": "no-store"})

    @app.get("/v1/cache/slots", dependencies=client)
    async def cache_slots() -> list[dict[str, object]]:
        return [asdict(slot) for slot in await coordinator.cache_pool.status()] if coordinator.cache_pool else []

    # A refused login reaches requests as asyncpg's own error when a new connection opens, so check every error.
    @app.exception_handler(Exception)
    async def unhandled(request: Request, error: Exception) -> JSONResponse:
        exit_on_auth_failure(error)
        logger.exception("%s %s failed", request.method, request.url.path)
        return JSONResponse({"detail": "internal error"}, status_code=500)

    # Every pooled connection stayed busy for database_pool_timeout_s: the coordinator is overloaded, not broken.
    @app.exception_handler(sa.exc.TimeoutError)
    async def database_busy(request: Request, error: Exception) -> JSONResponse:
        logger.warning("%s %s: no database connection came free: %s", request.method, request.url.path, error)
        return JSONResponse({"detail": "database busy"}, status_code=503, headers={"Retry-After": "5"})

    @app.post("/v1/batches", status_code=201, dependencies=client)
    async def submit(
        request: Request,
        profile: str = "default",
        max_heap_mb: int | None = Query(default=None, gt=0, le=2147483647),
        fail_fast: bool = False,
        priority: int = Query(default=0, ge=0, le=2147483647),
        action_class: Literal["build", "run"] = Query(default="build", alias="class"),
        speculative_loading: int | None = Query(default=None, ge=1, le=64),
        batch_id: UUID | None = Header(default=None, alias="Holbuild-Batch-Id"),
    ) -> dict[str, UUID]:
        started = time.monotonic()
        batch: Batch | None = None
        try:
            try:
                batch = parse_batch(await text_body(request))
            except FormatError as error:
                raise HTTPException(400, str(error)) from error
            if action_class == "run" and batch.edges:
                raise HTTPException(400, "run batches require independent actions: dependency edges are not allowed")
            if action_class == "run" and speculative_loading is not None:
                raise HTTPException(
                    400, "run batches have no parents to load ahead of: speculative_loading is not allowed"
                )
            return {"batch_id": await coordinator.submit(
                batch, profile, action_class, max_heap_mb, fail_fast=fail_fast, priority=priority,
                ahead_cap=speculative_loading, batch_id=batch_id,
            )}
        finally:
            # Timed from before the body is read, so a slow upload or parse shows too.
            if (seconds := time.monotonic() - started) >= SUBMIT_SLOW_SECONDS:
                shape = "unparsed" if batch is None else f"{len(batch.actions)} actions, {len(batch.edges)} edges"
                logger.warning(
                    "POST /v1/batches of %s bytes (%s; batch id %s) took %.1f s",
                    request.headers.get("content-length", "?"), shape, batch_id or "new", seconds,
                )

    @app.get("/v1/batches/{batch_id}", dependencies=client)
    async def status(batch_id: UUID) -> dict[str, object]:
        batch = await coordinator.get(batch_id)
        if batch is None:
            raise HTTPException(404, f"no batch {batch_id}")
        # Shallow: asdict deep-copies every action, which a big batch's status paid for in CPU.
        return {**vars(batch), "actions": [vars(action) for action in batch.actions]}

    @app.post("/v1/batches/{batch_id}/cancel", dependencies=client)
    async def cancel(batch_id: UUID) -> dict[str, str]:
        state = await coordinator.cancel(batch_id)
        if state is None:
            raise HTTPException(404, f"no batch {batch_id}")
        return {"state": state}

    @app.get("/v1/batches/{batch_id}/events", dependencies=client)
    async def events(batch_id: UUID) -> StreamingResponse:
        first = await coordinator.changes(batch_id, 0)
        if first is None:
            raise HTTPException(404, f"no batch {batch_id}")

        async def lines() -> AsyncIterator[str]:
            # Each read gets only the actions written since the last one, maybe some again, so `seen` drops repeats.
            seen: dict[str, ActionStatus] = {}
            batch, since = first
            actions = batch.actions
            last_line = last_read = time.monotonic()
            # Reads in hand, a token bucket: it refills one every events_poll_seconds, up to events_burst.
            credit = settings.events_burst - 1.0
            with coordinator.watch(batch_id) as written:
                while True:
                    for action in actions:
                        if seen.get(action.input_key) != action:
                            seen[action.input_key] = action
                            yield json.dumps(jsonable_encoder({"type": "action", **vars(action)})) + "\n"
                            last_line = time.monotonic()
                    if batch.state != "running":
                        yield json.dumps({"type": "batch", "state": batch.state, "failure": batch.failure}) + "\n"
                        return
                    # Read again once this process wrote to the batch, as soon as the bucket holds a read, or after
                    # events_fallback_seconds, for other processes' writes.
                    while True:
                        now = time.monotonic()
                        # A blank line, which clients skip, keeps a proxy from closing a quiet stream as idle; also
                        # between reads that take longer than the keepalive, such as failing ones.
                        if now - last_line >= settings.events_keepalive_seconds:
                            yield "\n"
                            last_line = now
                        read_at = last_read + (
                            max(settings.events_burst_spacing_seconds, (1.0 - credit) * settings.events_poll_seconds)
                            if written.is_set() else settings.events_fallback_seconds
                        )
                        if now >= read_at:
                            break
                        wait = min(read_at, last_line + settings.events_keepalive_seconds) - now
                        if written.is_set():
                            await asyncio.sleep(wait)
                        else:
                            with contextlib.suppress(TimeoutError):
                                await asyncio.wait_for(written.wait(), wait)
                    written.clear()
                    now = time.monotonic()
                    credit = max(0.0, min(float(settings.events_burst),
                                          credit + (now - last_read) / settings.events_poll_seconds) - 1.0)
                    last_read = now
                    try:
                        changed = await coordinator.changes(batch_id, since)
                    except DATABASE_UNAVAILABLE as error:
                        # Ending the stream would make its client follow the batch again from the start; the next
                        # read from the same `since` gets what this one missed.
                        exit_on_auth_failure(error)
                        logger.warning("reading the events of batch %s failed; retrying: %s", batch_id, error)
                        actions = []
                        continue
                    if changed is None:
                        return
                    batch, since = changed
                    actions = batch.actions

        return StreamingResponse(lines(), media_type="application/x-ndjson")

    @app.get("/v1/queue", dependencies=client)
    async def queue() -> dict[str, object]:
        status = await coordinator.queue()
        return {
            **{k: v for k, v in asdict(status.counts).items() if k not in ("high_run", "ready_high_run", "claimable_standard", "claimable_high")},
            "run_slots": settings.run_slots,
            "run_floor": min(settings.run_floor, settings.run_slots),
            "priority_cap": settings.priority_cap,
            "desired_burst_workers": status.desired_burst_workers,
            "max_burst_workers": settings.max_burst_workers,
            "hosts": [
                {**asdict(host.report), "age_s": host.age_s, "quarantined": host.quarantined, "workers": host.workers}
                for host in status.hosts
            ],
            "phases": asdict(status.phases),
            "scaler": None if status.scaler is None else {**asdict(status.scaler), "at": status.scaler.at.isoformat()},
            "locality": asdict(status.locality),
        }

    @app.post("/v1/work/claim", dependencies=worker, response_model=None)
    async def claim(body: ClaimRequest, request: Request) -> dict[str, object] | Response:
        arrived = datetime.now(UTC)
        tiers = [body.tier, *(t for t in body.also_claim if t != body.tier)]
        if body.host is not None:
            coordinator.report_host(body.host)
            coordinator.report_worker(body.host.id, body.worker, tiers, idle=True, ahead=body.ahead)
        if body.phases is not None:
            coordinator.report_phases(body.phases)
        claimed = await coordinator.claim(
            tiers, body.worker, body.wait_s, request.is_disconnected,
            host_id=None if body.host is None else body.host.id,
            host_rank=0 if body.host is None else body.host.rank,
            ahead=body.ahead,
        )
        if claimed is None and body.host is not None and not await request.is_disconnected():
            # Seen again as the wait ends, so until its next claim the worker still counts as a free slot on the
            # scale-in line (see Coordinator._kept_hosts), as it did while it waited. Not idle: a claim its worker gave
            # up on can end after the worker's next claim took a lease, whose bookkeeping must stay.
            coordinator.report_worker(body.host.id, body.worker, tiers, ahead=body.ahead)
        # After the claim, so claims arriving together still share their reads. Its worker's next claim comes 30 s
        # after this one arrived at the soonest, which dwarfs any skew between this clock and the database's.
        await coordinator.release_unheld(body.worker, None if claimed is None else str(claimed.attempt_token), arrived)
        if await request.is_disconnected():
            # The worker went as the claim returned: nobody gets the answer.
            if claimed is not None:
                await coordinator.give_back(claimed)
            return Response(status_code=204)
        if claimed is None:
            # A burst worker on a host claims fill after Spot exits at once rather than after its idle time, so the
            # host empties (see worker.py).
            spilled = body.host is not None and tiers[0] != "standard" and coordinator.spilled(body.host.id)
            return Response(status_code=204, headers={"Holbuild-Spilled": "1"} if spilled else None)
        return asdict(claimed)

    @app.post("/v1/work/report", status_code=204, dependencies=worker)
    async def report(body: ReportRequest) -> None:
        if body.host is not None:
            coordinator.report_host(body.host)
            coordinator.report_worker(body.host.id, body.worker, [body.tier, *body.also_claim], idle=True)

    @app.post("/v1/work/{attempt_token}/heartbeat", dependencies=worker)
    async def heartbeat(attempt_token: UUID, body: HeartbeatRequest | None = None) -> dict[str, int]:
        if body is not None and body.host is not None:
            coordinator.report_host(body.host)
        if not await coordinator.heartbeat(attempt_token):
            raise HTTPException(409, "lease expired or revoked; stop the action")
        return {"lease_s": settings.lease_seconds}

    @app.post("/v1/work/{attempt_token}/outlined", status_code=204, dependencies=worker)
    async def outlined(attempt_token: UUID) -> None:
        await coordinator.outlined(attempt_token)

    @app.post("/v1/work/{attempt_token}/complete", dependencies=worker)
    async def complete(attempt_token: UUID, request: Request) -> dict[str, bool]:
        try:
            result = parse_result(await text_body(request))
            accepted = await coordinator.complete(attempt_token, result)
        except (FormatError, ResultMismatch) as error:
            raise HTTPException(400, str(error)) from error
        if not accepted:
            raise HTTPException(409, "stale attempt token; result dropped")
        return {"accepted": True}

    return app


def app() -> FastAPI:
    # httpx logs every request's URL at INFO, and the cache URL may carry credentials.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    settings = Settings()  # pyright: ignore[reportCallIssue]  # fields come from the environment
    return create_app(Coordinator.from_settings(settings), settings)
