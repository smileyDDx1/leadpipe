"""Reads jobs from the Redis stream, with at-least-once delivery.

Redis in this design is disposable. If it loses its data, every lead is still in PostgreSQL
with status 'pending', and the sweep puts those leads back on the queue.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from uuid import UUID

import psycopg
import redis
from psycopg_pool import PoolTimeout
from redis.backoff import NoBackoff
from redis.retry import Retry

from .config import Settings
from .store import LeadStore, Outcome

logger = logging.getLogger("leadpipe.worker")

Message = tuple[str, dict[str, str]]


def make_redis_client(settings: Settings) -> redis.Redis:
    return redis.Redis(
        host=settings.redis_host,
        port=settings.redis_port,
        socket_connect_timeout=2,
        # Must be longer than the blocking read, or every quiet period looks like a timeout.
        socket_timeout=(settings.block_ms / 1000) + 3,
        decode_responses=True,
        # The worker loop has its own backoff. redis-py's default of 10 retries stalled the
        # loop for about 48 seconds, long enough for the liveness probe to kill the pod.
        retry=Retry(NoBackoff(), 0),
    )


class Consumer:
    def __init__(
        self,
        settings: Settings,
        store: LeadStore,
        client: redis.Redis,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._settings = settings
        self._store = store
        self._redis = client
        self._clock = clock
        self._last_reclaim = clock()
        self._last_sweep = clock()

    def ensure_group(self) -> None:
        try:
            self._redis.xgroup_create(
                self._settings.queue_stream, self._settings.consumer_group, id="0", mkstream=True
            )
            logger.info("created consumer group %s", self._settings.consumer_group)
        except redis.ResponseError as exc:
            if "BUSYGROUP" not in str(exc):
                raise

    def run_once(self) -> None:
        now = self._clock()
        if now - self._last_reclaim >= self._settings.reclaim_interval_seconds:
            self._last_reclaim = now
            self._process(self._reclaim())
        if now - self._last_sweep >= self._settings.sweep_interval_seconds:
            self._last_sweep = now
            self._sweep()
        self._process(self._read_new())

    def _read_new(self) -> list[Message]:
        response = self._redis.xreadgroup(
            self._settings.consumer_group,
            self._settings.consumer_name,
            {self._settings.queue_stream: ">"},
            count=10,
            block=self._settings.block_ms,
        )
        return response[0][1] if response else []

    def _reclaim(self) -> list[Message]:
        """Take over jobs that a crashed worker read but never acknowledged."""
        response = self._redis.xautoclaim(
            self._settings.queue_stream,
            self._settings.consumer_group,
            self._settings.consumer_name,
            min_idle_time=self._settings.reclaim_idle_ms,
            start_id="0-0",
            count=10,
        )
        messages = response[1]
        if messages:
            logger.info("reclaimed %d unacknowledged jobs", len(messages))
        return messages

    def _sweep(self) -> None:
        """Re-queue leads that never reached the queue, such as after a Redis restart.

        This only runs when the stream is empty. A long backlog means the old leads are
        still queued, and adding them again would only make the backlog longer.
        """
        if self._redis.xlen(self._settings.queue_stream) > 0:
            return
        stale = self._store.stale_pending(self._settings.sweep_min_age_seconds)
        for lead_id in stale:
            self._redis.xadd(self._settings.queue_stream, {"lead_id": str(lead_id)})
        if stale:
            logger.warning("re-queued %d leads that were missing from the queue", len(stale))

    def _process(self, messages: list[Message]) -> None:
        for message_id, fields in messages:
            try:
                lead_id = UUID(fields["lead_id"])
            except (KeyError, ValueError):
                # Retrying can never fix a malformed job, so drop it rather than loop forever.
                logger.error("dropping malformed job %s", message_id)
                self._finish(message_id)
                continue
            try:
                outcome = self._store.score(lead_id)
            except (psycopg.Error, PoolTimeout) as exc:
                # No ack: the job stays pending and is reclaimed once the database recovers.
                logger.warning("could not score %s: %s", lead_id, type(exc).__name__)
                continue
            if outcome is Outcome.NOT_FOUND:
                logger.error("job %s points to unknown lead %s", message_id, lead_id)
            else:
                logger.info("lead %s: %s", lead_id, outcome.value)
            self._finish(message_id)

    def _finish(self, message_id: str) -> None:
        pipeline = self._redis.pipeline()
        pipeline.xack(self._settings.queue_stream, self._settings.consumer_group, message_id)
        # Deleting finished jobs keeps the stream short, and lets XLEN mean "work outstanding".
        pipeline.xdel(self._settings.queue_stream, message_id)
        pipeline.execute()
