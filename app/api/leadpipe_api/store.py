"""PostgreSQL access for the API."""

from __future__ import annotations

from uuid import UUID

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from .config import DatabaseSettings
from .schemas import LeadIn

_LEAD_COLUMNS = (
    "id, email, name, company, job_title, company_size, source, status, score, grade, "
    "is_duplicate, duplicate_of, created_at, scored_at"
)


class LeadStore:
    def __init__(self, settings: DatabaseSettings) -> None:
        # open=False: the API must start and report "not ready" while the database is down,
        # rather than crash-looping and hiding the real problem.
        self._pool = ConnectionPool(
            settings.conninfo(),
            min_size=1,
            max_size=settings.pool_max,
            timeout=5,
            open=False,
            check=ConnectionPool.check_connection,
            kwargs={"row_factory": dict_row},
        )

    def open(self) -> None:
        self._pool.open(wait=False)

    def close(self) -> None:
        self._pool.close()

    def ping(self) -> None:
        with self._pool.connection() as conn:
            conn.execute("SELECT 1")

    def insert(self, lead: LeadIn) -> UUID:
        with self._pool.connection() as conn:
            row = conn.execute(
                """
                INSERT INTO leads (email, name, company, job_title, company_size, source)
                VALUES (%s, %s, %s, %s, %s, %s)
                RETURNING id
                """,
                (
                    lead.email,
                    lead.name,
                    lead.company,
                    lead.job_title,
                    lead.company_size,
                    lead.source.value,
                ),
            ).fetchone()
        return row["id"]

    def get(self, lead_id: UUID) -> dict | None:
        with self._pool.connection() as conn:
            return conn.execute(
                f"SELECT {_LEAD_COLUMNS} FROM leads WHERE id = %s",  # noqa: S608 - constant columns
                (lead_id,),
            ).fetchone()

    def stats(self) -> dict:
        with self._pool.connection() as conn:
            return conn.execute(
                """
                SELECT count(*) AS total,
                       count(*) FILTER (WHERE status = 'pending') AS pending,
                       count(*) FILTER (WHERE status = 'scored') AS scored,
                       count(*) FILTER (WHERE is_duplicate) AS duplicates,
                       count(*) FILTER (WHERE grade = 'hot') AS hot,
                       count(*) FILTER (WHERE grade = 'warm') AS warm,
                       count(*) FILTER (WHERE grade = 'cold') AS cold,
                       round(avg(score), 1)::float AS average_score
                FROM leads
                """
            ).fetchone()
