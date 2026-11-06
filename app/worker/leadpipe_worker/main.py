"""Worker entry point: runs the consumer loop until Kubernetes asks it to stop."""

from __future__ import annotations

import json
import logging
import signal
import sys
import threading
from datetime import UTC, datetime
from pathlib import Path

import psycopg
import redis
from psycopg_pool import PoolTimeout

from .config import ConfigError, Settings
from .consumer import Consumer, make_redis_client
from .store import LeadStore

logger = logging.getLogger("leadpipe.worker")

# Must stay under the heartbeat limit, or waiting out an outage would fail the liveness probe.
MAX_BACKOFF_SECONDS = 15


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "time": datetime.fromtimestamp(record.created, UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry)


def configure_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logging.basicConfig(level=level.upper(), handlers=[handler], force=True)


def run(settings: Settings, consumer: Consumer, stop: threading.Event) -> None:
    heartbeat = Path(settings.heartbeat_file)
    backoff = 1
    group_ready = False
    while not stop.is_set():
        # The heartbeat proves the loop is turning, even during an outage. A restart would not
        # fix Redis or the database, so only a truly stuck process should fail its probe.
        heartbeat.touch()
        try:
            if not group_ready:
                consumer.ensure_group()
                group_ready = True
            consumer.run_once()
            backoff = 1
        except redis.ResponseError as exc:
            if "NOGROUP" in str(exc):
                # Redis restarted and lost the stream. Recreate the group on the next turn.
                logger.warning("consumer group missing, recreating it")
                group_ready = False
                continue
            logger.error("redis error: %s", exc)
            stop.wait(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF_SECONDS)
        except (redis.ConnectionError, redis.TimeoutError, psycopg.Error, PoolTimeout) as exc:
            logger.warning(
                "dependency unavailable (%s), retrying in %ds", type(exc).__name__, backoff
            )
            group_ready = False
            stop.wait(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF_SECONDS)


def main() -> int:
    try:
        settings = Settings.from_env()
    except ConfigError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2
    configure_logging(settings.log_level)

    stop = threading.Event()

    def request_stop(signum: int, _frame: object) -> None:
        logger.info("received signal %d, finishing the current batch", signum)
        stop.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    store = LeadStore(settings.conninfo())
    store.open()
    client = make_redis_client(settings)
    logger.info("worker %s started", settings.consumer_name)
    try:
        run(settings, Consumer(settings, store, client), stop)
    finally:
        store.close()
        client.close()
        logger.info("worker stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
