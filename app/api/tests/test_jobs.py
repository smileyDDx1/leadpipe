from __future__ import annotations

import socket
from uuid import uuid4

import pytest
import redis

from leadpipe_api.jobs import JobQueue


def unused_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@pytest.mark.parametrize("call", ["enqueue", "ping"])
def test_redis_outage_fails_on_the_first_attempt(monkeypatch, call):
    # Regression: redis-py's default of 10 retries held each request for about 46 seconds. A
    # webhook caller would time out and resend a lead that was already saved.
    attempts = []
    real_getaddrinfo = socket.getaddrinfo

    def counting_getaddrinfo(*args, **kwargs):
        attempts.append(args)
        return real_getaddrinfo(*args, **kwargs)

    monkeypatch.setattr(socket, "getaddrinfo", counting_getaddrinfo)
    queue = JobQueue("127.0.0.1", unused_port(), "leads:jobs")

    with pytest.raises(redis.RedisError):
        getattr(queue, call)(*((uuid4(),) if call == "enqueue" else ()))

    assert len(attempts) == 1
