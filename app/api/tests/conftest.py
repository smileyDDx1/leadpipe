from __future__ import annotations

from datetime import UTC, datetime
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient

from leadpipe_api.config import DatabaseSettings, Settings
from leadpipe_api.main import create_app
from leadpipe_api.schemas import LeadIn

API_KEY = "test-key"
HEADERS = {"X-API-Key": API_KEY}


class FakeStore:
    def __init__(self) -> None:
        self.leads: dict[UUID, dict] = {}
        self.ping_error: Exception | None = None
        self.insert_error: Exception | None = None

    def open(self) -> None: ...

    def close(self) -> None: ...

    def ping(self) -> None:
        if self.ping_error:
            raise self.ping_error

    def insert(self, lead: LeadIn) -> UUID:
        if self.insert_error:
            raise self.insert_error
        lead_id = uuid4()
        self.leads[lead_id] = {
            "id": lead_id,
            **lead.model_dump(mode="json"),
            "status": "pending",
            "score": None,
            "grade": None,
            "is_duplicate": False,
            "duplicate_of": None,
            "created_at": datetime.now(UTC),
            "scored_at": None,
        }
        return lead_id

    def get(self, lead_id: UUID) -> dict | None:
        return self.leads.get(lead_id)

    def stats(self) -> dict:
        return {
            "total": len(self.leads),
            "pending": len(self.leads),
            "scored": 0,
            "duplicates": 0,
            "hot": 0,
            "warm": 0,
            "cold": 0,
            "average_score": None,
        }


class FakeQueue:
    def __init__(self) -> None:
        self.jobs: list[UUID] = []
        self.ping_error: Exception | None = None
        self.enqueue_error: Exception | None = None

    def enqueue(self, lead_id: UUID) -> None:
        if self.enqueue_error:
            raise self.enqueue_error
        self.jobs.append(lead_id)

    def ping(self) -> None:
        if self.ping_error:
            raise self.ping_error

    def close(self) -> None: ...


@pytest.fixture
def store() -> FakeStore:
    return FakeStore()


@pytest.fixture
def queue() -> FakeQueue:
    return FakeQueue()


@pytest.fixture
def settings() -> Settings:
    return Settings(
        api_key=API_KEY,
        database=DatabaseSettings(host="db", name="leadpipe", user="u", password="p"),
        redis_host="redis",
    )


@pytest.fixture
def client(settings: Settings, store: FakeStore, queue: FakeQueue):
    with TestClient(create_app(settings, store, queue)) as test_client:
        yield test_client
