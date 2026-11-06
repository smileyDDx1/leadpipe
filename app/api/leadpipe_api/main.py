"""LeadPipe API: accepts leads by webhook and serves the scored results."""

from __future__ import annotations

import hmac
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Annotated
from uuid import UUID

import psycopg
import redis
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
from psycopg_pool import PoolTimeout

from .config import Settings
from .jobs import JobQueue
from .logs import configure_logging
from .schemas import LeadAccepted, LeadIn, LeadOut, Stats
from .store import LeadStore

logger = logging.getLogger("leadpipe.api")

_DATABASE_ERRORS = (psycopg.OperationalError, PoolTimeout)


def require_api_key(request: Request, x_api_key: Annotated[str | None, Header()] = None) -> None:
    expected = request.app.state.settings.api_key
    if x_api_key is None or not hmac.compare_digest(x_api_key.encode(), expected.encode()):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid or missing API key")


def create_app(
    settings: Settings | None = None,
    store: LeadStore | None = None,
    queue: JobQueue | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    configure_logging(settings.log_level)
    store = store or LeadStore(settings.database)
    queue = queue or JobQueue(settings.redis_host, settings.redis_port, settings.queue_stream)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        store.open()
        yield
        store.close()
        queue.close()

    app = FastAPI(title="LeadPipe API", version="1.0.0", lifespan=lifespan)
    app.state.settings = settings

    @app.exception_handler(psycopg.OperationalError)
    @app.exception_handler(PoolTimeout)
    def database_unavailable(_: Request, exc: Exception) -> JSONResponse:
        logger.error("database unavailable: %s", type(exc).__name__)
        return JSONResponse(
            {"detail": "database unavailable"},
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            headers={"Retry-After": "5"},
        )

    @app.post(
        "/leads",
        status_code=status.HTTP_202_ACCEPTED,
        response_model=LeadAccepted,
        dependencies=[Depends(require_api_key)],
    )
    def create_lead(lead: LeadIn, response: Response) -> LeadAccepted:
        # Commit first, then enqueue, so the worker can never see a job before its row exists.
        lead_id = store.insert(lead)
        try:
            queue.enqueue(lead_id)
        except redis.RedisError as exc:
            # The lead is safe in PostgreSQL. The worker's sweep re-queues it once Redis is back.
            logger.warning("enqueue failed for lead %s: %s", lead_id, type(exc).__name__)
        response.headers["Location"] = f"/leads/{lead_id}"
        logger.info("lead accepted: %s", lead_id)
        return LeadAccepted(id=lead_id)

    @app.get("/leads/{lead_id}", response_model=LeadOut, dependencies=[Depends(require_api_key)])
    def get_lead(lead_id: UUID) -> dict:
        lead = store.get(lead_id)
        if lead is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "lead not found")
        return lead

    @app.get("/stats", response_model=Stats, dependencies=[Depends(require_api_key)])
    def get_stats() -> dict:
        return store.stats()

    @app.get("/healthz", tags=["health"])
    def healthz() -> dict:
        # Liveness: the process can serve a request. It checks no dependencies on purpose,
        # because restarting API pods would not fix a database outage.
        return {"status": "ok"}

    @app.get("/readyz", tags=["health"])
    def readyz(response: Response) -> dict:
        # Readiness: stop sending traffic to this pod only if it cannot do its job. A lead cannot
        # be saved without PostgreSQL. It can be saved without Redis, because the worker's sweep
        # queues it later, so a Redis outage must not take the API out of service.
        checks = {"database": "ok", "redis": "ok"}
        try:
            store.ping()
        except _DATABASE_ERRORS:
            checks["database"] = "unavailable"
        try:
            queue.ping()
        except redis.RedisError:
            checks["redis"] = "unavailable"
        if checks["database"] != "ok":
            response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
            state = "not ready"
        elif checks["redis"] != "ok":
            state = "degraded"
        else:
            state = "ready"
        return {"status": state, "checks": checks}

    return app
