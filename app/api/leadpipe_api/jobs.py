"""The Redis stream that hands leads to the worker."""

from __future__ import annotations

from uuid import UUID

import redis
from redis.backoff import NoBackoff
from redis.retry import Retry


class JobQueue:
    def __init__(self, host: str, port: int, stream: str) -> None:
        self._stream = stream
        self._redis = redis.Redis(
            host=host,
            port=port,
            socket_connect_timeout=2,
            socket_timeout=2,
            decode_responses=True,
            # redis-py retries 10 times by default, which held every request for about 46
            # seconds during an outage. The lead is already saved, so fail fast instead.
            retry=Retry(NoBackoff(), 0),
        )

    def enqueue(self, lead_id: UUID) -> None:
        self._redis.xadd(self._stream, {"lead_id": str(lead_id)})

    def ping(self) -> None:
        self._redis.ping()

    def close(self) -> None:
        self._redis.close()
