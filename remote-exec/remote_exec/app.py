"""HTTP interface of the remote-exec coordinator. Run with ``uvicorn --factory remote_exec.app:app``."""

import asyncio
import contextlib
import hmac
import json
import logging
import os
import time
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from dataclasses import asdict
from typing import Literal
from uuid import UUID

import sqlalchemy as sa
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field, SecretStr

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
from remote_exec.formats import FormatError, parse_batch, parse_result

logger = logging.getLogger(__name__)

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


def exit_on_auth_failure(error: BaseException) -> None:
    """Exit when the database refused the coordinator's credentials, so its supervisor restarts it with the
    current ones; the database URL is read only at start."""
    if is_auth_failure(error):
        logger.critical("the database refused the coordinator's credentials; exiting: %s", error)
        os._exit(1)


def bearer(token: SecretStr) -> Callable[[str | None], None]:
    expected = f"Bearer {token.get_secret_value()}".encode()

    def check(authorization: str | None = Header(default=None)) -> None:
        if not hmac.compare_digest((authorization or "").encode(), expected):
            raise HTTPException(401, "bad or missing bearer token")

    return check


async def text_body(request: Request) -> str:
    try:
        return (await request.body()).decode()
    except UnicodeDecodeError as error:
        raise HTTPException(400, f"body is not UTF-8: {error}") from error


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

        pool_controller = asyncio.create_task(cache_pool_forever()) if coordinator.cache_pool is not None else None
        sweeper = asyncio.create_task(sweep_forever())
        try:
            yield
        finally:
            sweeper.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await sweeper
            if pool_controller is not None:
                pool_controller.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await pool_controller
            await coordinator.aclose()

    app = FastAPI(title="holbuild remote-exec coordinator", lifespan=lifespan)
    client = [Depends(bearer(settings.client_token))]
    worker = [Depends(bearer(settings.worker_token))]
    discovery_token = cache_discovery_token(settings.worker_token.get_secret_value())

    def cache_reader(authorization: str | None = Header(default=None)) -> None:
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
        speculative_loading: int | None = Query(default=None, ge=1, le=16),
    ) -> dict[str, UUID]:
        try:
            batch = parse_batch(await text_body(request))
        except FormatError as error:
            raise HTTPException(400, str(error)) from error
        if action_class == "run" and batch.edges:
            raise HTTPException(400, "run batches require independent actions: dependency edges are not allowed")
        if action_class == "run" and speculative_loading is not None:
            raise HTTPException(400, "run batches have no parents to load ahead of: speculative_loading is not allowed")
        return {"batch_id": await coordinator.submit(
            batch, profile, action_class, max_heap_mb, fail_fast=fail_fast, priority=priority,
            ahead_cap=speculative_loading,
        )}

    @app.get("/v1/batches/{batch_id}", dependencies=client)
    async def status(batch_id: UUID) -> dict[str, object]:
        batch = await coordinator.get(batch_id)
        if batch is None:
            raise HTTPException(404, f"no batch {batch_id}")
        return asdict(batch)

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
                            yield json.dumps({"type": "action", **asdict(action)}) + "\n"
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
            **{k: v for k, v in asdict(status.counts).items() if k != "high_run"},
            "run_slots": settings.run_slots,
            "run_floor": min(settings.run_floor, settings.run_slots),
            "desired_burst_workers": status.desired_burst_workers,
            "max_burst_workers": settings.max_burst_workers,
            "hosts": [{**asdict(host.report), "age_s": host.age_s} for host in status.hosts],
            "phases": asdict(status.phases),
            "scaler": None if status.scaler is None else {**asdict(status.scaler), "at": status.scaler.at.isoformat()},
        }

    @app.post("/v1/work/claim", dependencies=worker, response_model=None)
    async def claim(body: ClaimRequest, request: Request) -> dict[str, object] | Response:
        if body.host is not None:
            coordinator.report_host(body.host)
        if body.phases is not None:
            coordinator.report_phases(body.phases)
        tiers = [body.tier, *(t for t in body.also_claim if t != body.tier)]
        claimed = await coordinator.claim(
            tiers, body.worker, body.wait_s, request.is_disconnected,
            host_id=None if body.host is None else body.host.id,
            host_rank=0 if body.host is None else body.host.rank,
            ahead=body.ahead,
        )
        if claimed is None:
            return Response(status_code=204)
        return asdict(claimed)

    @app.post("/v1/work/{attempt_token}/heartbeat", dependencies=worker)
    async def heartbeat(attempt_token: UUID, body: HeartbeatRequest | None = None) -> dict[str, int]:
        if body is not None and body.host is not None:
            coordinator.report_host(body.host)
        if not await coordinator.heartbeat(attempt_token):
            raise HTTPException(409, "lease expired or revoked; stop the action")
        return {"lease_s": settings.lease_seconds}

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
