from __future__ import annotations

import socket
import subprocess
import sys
import threading
from dataclasses import replace
from pathlib import Path

import pytest
import redis

from leadpipe_worker.config import ConfigError, Settings
from leadpipe_worker.consumer import make_redis_client
from leadpipe_worker.healthcheck import is_healthy
from leadpipe_worker.main import MAX_BACKOFF_SECONDS, run

ENV = {
    "DB_HOST": "db",
    "DB_NAME": "leadpipe",
    "DB_USER": "app",
    "DB_PASSWORD": "secret-password",
    "REDIS_HOST": "redis",
}


def test_settings_load_from_environment():
    settings = Settings.from_env({**ENV, "CONSUMER_NAME": "pod-1"})

    assert settings.consumer_name == "pod-1"
    assert settings.queue_stream == "leads:jobs"


def test_missing_settings_are_all_reported_at_once():
    with pytest.raises(ConfigError) as error:
        Settings.from_env({})

    for name in ENV:
        assert name in str(error.value)


def test_password_never_appears_in_repr():
    assert "secret-password" not in repr(Settings.from_env(ENV))


def test_heartbeat_is_healthy_when_recent(tmp_path):
    heartbeat = tmp_path / "heartbeat"
    heartbeat.touch()

    assert is_healthy(str(heartbeat), max_age_seconds=30)


def test_heartbeat_is_unhealthy_when_old(tmp_path):
    heartbeat = tmp_path / "heartbeat"
    heartbeat.touch()
    future = heartbeat.stat().st_mtime + 31

    assert not is_healthy(str(heartbeat), max_age_seconds=30, now=future)


def test_heartbeat_is_unhealthy_when_missing(tmp_path):
    assert not is_healthy(str(tmp_path / "missing"), max_age_seconds=30)


class ScriptedConsumer:
    """Plays back a list of errors from run_once, then asks the loop to stop."""

    def __init__(self, stop: threading.Event, errors: list[Exception]) -> None:
        self.stop = stop
        self.errors = errors
        self.ensure_group_calls = 0
        self.run_once_calls = 0

    def ensure_group(self) -> None:
        self.ensure_group_calls += 1

    def run_once(self) -> None:
        self.run_once_calls += 1
        if self.errors:
            raise self.errors.pop(0)
        self.stop.set()


def test_loop_recreates_the_group_after_redis_restarts(tmp_path):
    stop = threading.Event()
    consumer = ScriptedConsumer(stop, [redis.ResponseError("NOGROUP No such key")])
    settings = replace(Settings.from_env(ENV), heartbeat_file=str(tmp_path / "beat"))

    run(settings, consumer, stop)

    assert consumer.ensure_group_calls == 2
    assert consumer.run_once_calls == 2


def test_loop_survives_a_redis_outage_and_keeps_its_heartbeat(tmp_path):
    stop = threading.Event()
    consumer = ScriptedConsumer(stop, [redis.ConnectionError("down")])
    settings = replace(Settings.from_env(ENV), heartbeat_file=str(tmp_path / "beat"))

    run(settings, consumer, stop)

    assert consumer.run_once_calls == 2
    assert (tmp_path / "beat").exists()


def test_redis_outage_fails_on_the_first_attempt(monkeypatch):
    # Regression: redis-py's default of 10 retries stalled the loop for about 48 seconds, longer
    # than the 30 second heartbeat limit, so an outage would have restarted a healthy pod.
    attempts = []
    real_getaddrinfo = socket.getaddrinfo

    def counting_getaddrinfo(*args, **kwargs):
        attempts.append(args)
        return real_getaddrinfo(*args, **kwargs)

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    monkeypatch.setattr(socket, "getaddrinfo", counting_getaddrinfo)
    settings = replace(Settings.from_env(ENV), redis_host="127.0.0.1", redis_port=port)

    with pytest.raises(redis.RedisError):
        make_redis_client(settings).ping()

    assert len(attempts) == 1


def test_longest_backoff_stays_inside_the_heartbeat_limit():
    # The loop only touches the heartbeat between waits. A longer wait would fail the probe.
    assert Settings.heartbeat_max_age_seconds > MAX_BACKOFF_SECONDS


def test_health_probe_imports_only_the_standard_library():
    # Regression: importing psycopg cost 0.92 CPU seconds per probe, about 120m CPU on an idle
    # worker, and took 3.7 seconds against the probe's 5 second timeout.
    code = (
        "import sys, leadpipe_worker.healthcheck; "
        "sys.exit(any(name in sys.modules for name in ('psycopg', 'redis', 'psycopg_pool')))"
    )

    result = subprocess.run(  # noqa: S603 - fixed command
        [sys.executable, "-c", code], cwd=Path(__file__).parents[1], check=False
    )

    assert result.returncode == 0
