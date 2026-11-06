"""Applies numbered SQL migrations. Runs as a Helm pre-upgrade Job and a Compose one-shot service.

Migrations are forward-only and must stay compatible with the previous release, because
`helm rollback` restores old pods without undoing the schema.
"""

from __future__ import annotations

import logging
import sys
import time
from pathlib import Path

import psycopg
from psycopg import sql

from .config import ConfigError, DatabaseSettings
from .logs import configure_logging

logger = logging.getLogger("leadpipe.migrate")

MIGRATIONS_DIR = Path(__file__).parent / "migrations"
# Any fixed number works. Holding this lock stops two migration Jobs from racing each other.
ADVISORY_LOCK_ID = 7274421


def discover_migrations(directory: Path = MIGRATIONS_DIR) -> list[Path]:
    return sorted(directory.glob("*.sql"), key=lambda path: path.name)


def connect_with_retry(conninfo: str, attempts: int = 30, delay: float = 2.0) -> psycopg.Connection:
    for attempt in range(1, attempts + 1):
        try:
            return psycopg.connect(conninfo)
        except psycopg.OperationalError as exc:
            if attempt == attempts:
                raise
            logger.info("database not reachable (attempt %d/%d): %s", attempt, attempts, exc)
            time.sleep(delay)
    raise AssertionError("unreachable")


def ensure_database(settings: DatabaseSettings) -> None:
    """Create the environment's database. One RDS instance holds both staging and production."""
    with connect_with_retry(settings.conninfo("postgres")) as conn:
        conn.autocommit = True  # CREATE DATABASE cannot run inside a transaction.
        exists = conn.execute(
            "SELECT 1 FROM pg_database WHERE datname = %s", (settings.name,)
        ).fetchone()
        if exists is None:
            logger.info("creating database %s", settings.name)
            conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(settings.name)))


def apply_migrations(conn: psycopg.Connection, migrations: list[Path]) -> list[str]:
    conn.autocommit = True
    conn.execute("SELECT pg_advisory_lock(%s)", (ADVISORY_LOCK_ID,))
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version text PRIMARY KEY,
            applied_at timestamptz NOT NULL DEFAULT now()
        )
        """
    )
    applied = {row[0] for row in conn.execute("SELECT version FROM schema_migrations")}
    newly_applied = []
    for migration in migrations:
        if migration.name in applied:
            continue
        logger.info("applying %s", migration.name)
        with conn.transaction():
            conn.execute(migration.read_text(encoding="utf-8").encode())
            conn.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (migration.name,))
        newly_applied.append(migration.name)
    return newly_applied


def main() -> int:
    configure_logging("INFO")
    try:
        settings = DatabaseSettings.from_env()
    except ConfigError as exc:
        logger.error("%s", exc)
        return 2
    if settings.create_if_missing:
        ensure_database(settings)
    with connect_with_retry(settings.conninfo()) as conn:
        applied = apply_migrations(conn, discover_migrations())
    logger.info("migrations complete: %d applied", len(applied))
    return 0


if __name__ == "__main__":
    sys.exit(main())
