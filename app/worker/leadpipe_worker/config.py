"""All configuration comes from environment variables, with nothing hardcoded."""

from __future__ import annotations

import os
import socket
from collections.abc import Mapping
from dataclasses import dataclass, field

from psycopg.conninfo import make_conninfo

from .healthcheck import DEFAULT_HEARTBEAT_FILE, HEARTBEAT_MAX_AGE_SECONDS


class ConfigError(RuntimeError):
    """Required configuration is missing or invalid. Raised at startup so the pod fails fast."""


def _int(env: Mapping[str, str], name: str, default: int) -> int:
    raw = env.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer, got {raw!r}") from exc


@dataclass(frozen=True)
class Settings:
    db_host: str
    db_name: str
    db_user: str
    db_password: str = field(repr=False)
    redis_host: str
    db_port: int = 5432
    db_sslmode: str = "prefer"
    redis_port: int = 6379
    queue_stream: str = "leads:jobs"
    consumer_group: str = "scorers"
    consumer_name: str = "worker"
    block_ms: int = 2000
    # A job with no ack for this long belongs to a worker that died. Another worker takes it.
    reclaim_idle_ms: int = 60_000
    reclaim_interval_seconds: int = 15
    # How often to look for leads that never reached the queue, and how old they must be.
    sweep_interval_seconds: int = 30
    sweep_min_age_seconds: int = 60
    heartbeat_file: str = DEFAULT_HEARTBEAT_FILE
    heartbeat_max_age_seconds: int = HEARTBEAT_MAX_AGE_SECONDS
    log_level: str = "INFO"

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if env is None else env
        required = ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD", "REDIS_HOST")
        missing = [name for name in required if not env.get(name)]
        if missing:
            raise ConfigError(f"missing required environment variables: {', '.join(missing)}")
        return cls(
            db_host=env["DB_HOST"],
            db_name=env["DB_NAME"],
            db_user=env["DB_USER"],
            db_password=env["DB_PASSWORD"],
            redis_host=env["REDIS_HOST"],
            db_port=_int(env, "DB_PORT", 5432),
            db_sslmode=env.get("DB_SSLMODE") or "prefer",
            redis_port=_int(env, "REDIS_PORT", 6379),
            queue_stream=env.get("QUEUE_STREAM") or "leads:jobs",
            consumer_group=env.get("CONSUMER_GROUP") or "scorers",
            consumer_name=env.get("CONSUMER_NAME") or socket.gethostname(),
            heartbeat_file=env.get("HEARTBEAT_FILE") or cls.heartbeat_file,
            log_level=env.get("LOG_LEVEL") or "INFO",
        )

    def conninfo(self) -> str:
        return make_conninfo(
            host=self.db_host,
            port=self.db_port,
            dbname=self.db_name,
            user=self.db_user,
            password=self.db_password,
            sslmode=self.db_sslmode,
            connect_timeout=3,
        )
