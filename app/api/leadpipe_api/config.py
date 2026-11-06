"""All configuration comes from environment variables, with nothing hardcoded."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, field

from psycopg.conninfo import make_conninfo


class ConfigError(RuntimeError):
    """Required configuration is missing or invalid. Raised at startup so the pod fails fast."""


def _require(env: Mapping[str, str], names: tuple[str, ...]) -> None:
    missing = [name for name in names if not env.get(name)]
    if missing:
        raise ConfigError(f"missing required environment variables: {', '.join(missing)}")


def _int(env: Mapping[str, str], name: str, default: int) -> int:
    raw = env.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer, got {raw!r}") from exc


@dataclass(frozen=True)
class DatabaseSettings:
    host: str
    name: str
    user: str
    password: str = field(repr=False)
    port: int = 5432
    sslmode: str = "prefer"
    pool_max: int = 5
    create_if_missing: bool = False

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> DatabaseSettings:
        env = os.environ if env is None else env
        _require(env, ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD"))
        return cls(
            host=env["DB_HOST"],
            name=env["DB_NAME"],
            user=env["DB_USER"],
            password=env["DB_PASSWORD"],
            port=_int(env, "DB_PORT", 5432),
            sslmode=env.get("DB_SSLMODE") or "prefer",
            pool_max=_int(env, "DB_POOL_MAX", 5),
            create_if_missing=(env.get("DB_CREATE_IF_MISSING") or "").lower() == "true",
        )

    def conninfo(self, dbname: str | None = None) -> str:
        return make_conninfo(
            host=self.host,
            port=self.port,
            dbname=dbname or self.name,
            user=self.user,
            password=self.password,
            sslmode=self.sslmode,
            connect_timeout=3,
        )


@dataclass(frozen=True)
class Settings:
    api_key: str = field(repr=False)
    database: DatabaseSettings
    redis_host: str
    redis_port: int = 6379
    queue_stream: str = "leads:jobs"
    log_level: str = "INFO"

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if env is None else env
        _require(env, ("API_KEY", "DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD", "REDIS_HOST"))
        return cls(
            api_key=env["API_KEY"],
            database=DatabaseSettings.from_env(env),
            redis_host=env["REDIS_HOST"],
            redis_port=_int(env, "REDIS_PORT", 6379),
            queue_stream=env.get("QUEUE_STREAM") or "leads:jobs",
            log_level=env.get("LOG_LEVEL") or "INFO",
        )
