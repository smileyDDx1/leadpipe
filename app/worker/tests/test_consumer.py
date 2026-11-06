"""Consumer tests against fakeredis, so stream and consumer-group behaviour is realistic."""

from __future__ import annotations

from uuid import UUID, uuid4

import fakeredis
import psycopg
import pytest

from leadpipe_worker.config import Settings
from leadpipe_worker.consumer import Consumer
from leadpipe_worker.store import Outcome

STREAM = "leads:jobs"
GROUP = "scorers"


class FakeStore:
    def __init__(self) -> None:
        self.scored: list[UUID] = []
        self.error: Exception | None = None
        self.outcome = Outcome.SCORED
        self.stale: list[UUID] = []

    def score(self, lead_id: UUID) -> Outcome:
        if self.error:
            raise self.error
        self.scored.append(lead_id)
        return self.outcome

    def stale_pending(self, min_age_seconds: int, limit: int = 500) -> list[UUID]:
        return self.stale


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def make_settings(**overrides) -> Settings:
    defaults = {
        "db_host": "db",
        "db_name": "leadpipe",
        "db_user": "u",
        "db_password": "p",
        "redis_host": "redis",
        "consumer_name": "worker-1",
        "block_ms": 1,
    }
    return Settings(**{**defaults, **overrides})


@pytest.fixture
def client():
    return fakeredis.FakeRedis(decode_responses=True)


@pytest.fixture
def store():
    return FakeStore()


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def consumer(client, store, clock):
    instance = Consumer(make_settings(), store, client, clock)
    instance.ensure_group()
    return instance


def pending_count(client) -> int:
    return client.xpending(STREAM, GROUP)["pending"]


def test_job_is_scored_then_acknowledged_and_removed(consumer, client, store):
    lead_id = uuid4()
    client.xadd(STREAM, {"lead_id": str(lead_id)})

    consumer.run_once()

    assert store.scored == [lead_id]
    assert pending_count(client) == 0
    assert client.xlen(STREAM) == 0


def test_job_stays_pending_when_the_database_fails(consumer, client, store):
    store.error = psycopg.OperationalError("down")
    client.xadd(STREAM, {"lead_id": str(uuid4())})

    consumer.run_once()

    assert pending_count(client) == 1
    assert client.xlen(STREAM) == 1


def test_malformed_job_is_dropped_instead_of_retried_forever(consumer, client, store):
    client.xadd(STREAM, {"lead_id": "not-a-uuid"})
    client.xadd(STREAM, {"something": "else"})

    consumer.run_once()

    assert store.scored == []
    assert pending_count(client) == 0
    assert client.xlen(STREAM) == 0


def test_job_for_an_unknown_lead_is_acknowledged(consumer, client, store):
    store.outcome = Outcome.NOT_FOUND
    client.xadd(STREAM, {"lead_id": str(uuid4())})

    consumer.run_once()

    assert pending_count(client) == 0


def test_jobs_from_a_crashed_worker_are_reclaimed(client, store, clock):
    settings = make_settings(reclaim_idle_ms=0, reclaim_interval_seconds=15)
    lead_id = uuid4()
    consumer = Consumer(settings, store, client, clock)
    consumer.ensure_group()
    client.xadd(STREAM, {"lead_id": str(lead_id)})
    # Another worker reads the job, then dies before acknowledging it.
    client.xreadgroup(GROUP, "crashed-worker", {STREAM: ">"}, count=1)

    consumer.run_once()
    assert store.scored == []  # not due yet

    clock.now = 15
    consumer.run_once()

    assert store.scored == [lead_id]
    assert pending_count(client) == 0


def test_sweep_requeues_stale_leads_when_the_stream_is_empty(consumer, client, store, clock):
    lost_lead = uuid4()
    store.stale = [lost_lead]
    clock.now = 30

    consumer.run_once()

    # The sweep runs before the read, so the job is picked up in the same turn.
    assert store.scored == [lost_lead]


def test_sweep_waits_while_the_queue_has_a_backlog(client, store, clock):
    consumer = Consumer(make_settings(), store, client, clock)
    consumer.ensure_group()
    client.xadd(STREAM, {"lead_id": str(uuid4())})
    # Another worker holds this job, so the stream is not empty during the sweep.
    client.xreadgroup(GROUP, "other-worker", {STREAM: ">"}, count=1)
    store.stale = [uuid4()]
    clock.now = 30

    consumer.run_once()

    assert store.scored == []
    assert client.xlen(STREAM) == 1


def test_sweep_does_not_run_before_its_interval(consumer, store, clock):
    store.stale = [uuid4()]
    clock.now = 29

    consumer.run_once()

    assert store.scored == []


def test_ensure_group_is_safe_to_repeat(consumer):
    consumer.ensure_group()
    consumer.ensure_group()


def test_group_can_be_recreated_after_redis_loses_its_data(consumer, client, store):
    client.flushall()
    lead_id = uuid4()
    # The API enqueues on the fresh Redis before any worker has recreated the group.
    client.xadd(STREAM, {"lead_id": str(lead_id)})

    consumer.ensure_group()
    consumer.run_once()

    # The group starts at id 0, so jobs added before it existed are not lost.
    assert store.scored == [lead_id]
