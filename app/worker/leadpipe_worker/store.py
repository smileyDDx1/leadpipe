"""PostgreSQL access for the worker."""

from __future__ import annotations

from enum import Enum
from uuid import UUID

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from .scoring import score_lead


class Outcome(Enum):
    SCORED = "scored"
    ALREADY_SCORED = "already_scored"
    NOT_FOUND = "not_found"


class LeadStore:
    def __init__(self, conninfo: str) -> None:
        self._pool = ConnectionPool(
            conninfo,
            min_size=1,
            max_size=2,
            timeout=5,
            open=False,
            check=ConnectionPool.check_connection,
            kwargs={"row_factory": dict_row},
        )

    def open(self) -> None:
        self._pool.open(wait=False)

    def close(self) -> None:
        self._pool.close()

    def score(self, lead_id: UUID) -> Outcome:
        """Score one lead and flag duplicates. Safe to repeat, since jobs can arrive twice."""
        with self._pool.connection() as conn:
            lead = conn.execute(
                """
                SELECT email, job_title, company_size, source, status, created_at
                FROM leads WHERE id = %s FOR UPDATE
                """,
                (lead_id,),
            ).fetchone()
            if lead is None:
                return Outcome.NOT_FOUND
            if lead["status"] != "pending":
                return Outcome.ALREADY_SCORED

            # The earliest lead with this email is the original, whether or not it is scored yet.
            original = conn.execute(
                """
                SELECT id FROM leads
                WHERE email = %s AND (created_at, id) < (%s, %s)
                ORDER BY created_at, id
                LIMIT 1
                """,
                (lead["email"], lead["created_at"], lead_id),
            ).fetchone()

            result = score_lead(lead["job_title"], lead["company_size"], lead["source"])
            conn.execute(
                """
                UPDATE leads
                SET status = 'scored', score = %s, grade = %s,
                    is_duplicate = %s, duplicate_of = %s, scored_at = now()
                WHERE id = %s
                """,
                (
                    result.score,
                    result.grade,
                    original is not None,
                    original["id"] if original else None,
                    lead_id,
                ),
            )
        return Outcome.SCORED

    def stale_pending(self, min_age_seconds: int, limit: int = 500) -> list[UUID]:
        with self._pool.connection() as conn:
            rows = conn.execute(
                """
                SELECT id FROM leads
                WHERE status = 'pending'
                  AND created_at < now() - make_interval(secs => %s)
                ORDER BY created_at
                LIMIT %s
                """,
                (min_age_seconds, limit),
            ).fetchall()
        return [row["id"] for row in rows]
