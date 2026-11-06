from __future__ import annotations

from uuid import UUID, uuid4

import psycopg
import pytest
import redis
from fastapi.testclient import TestClient
from psycopg_pool import PoolTimeout

from leadpipe_api.main import create_app

from .conftest import HEADERS

VALID_LEAD = {
    "email": "Asha.Rao@Example.com",
    "name": "Asha Rao",
    "company": "Example Ltd",
    "job_title": "VP of Sales",
    "company_size": 250,
    "source": "website_form",
}


def test_post_lead_saves_and_enqueues(client, store, queue):
    response = client.post("/leads", json=VALID_LEAD, headers=HEADERS)

    assert response.status_code == 202
    body = response.json()
    lead_id = UUID(body["id"])
    assert body["status"] == "pending"
    assert response.headers["Location"] == f"/leads/{lead_id}"
    assert lead_id in store.leads
    assert queue.jobs == [lead_id]


def test_post_lead_lowercases_email_for_duplicate_detection(client, store):
    lead_id = UUID(client.post("/leads", json=VALID_LEAD, headers=HEADERS).json()["id"])

    assert store.leads[lead_id]["email"] == "asha.rao@example.com"


def test_post_lead_needs_only_email_and_name(client):
    response = client.post("/leads", json={"email": "a@example.com", "name": "A"}, headers=HEADERS)

    assert response.status_code == 202


@pytest.mark.parametrize(
    "change",
    [
        {"email": "not-an-email"},
        {"name": ""},
        {"name": "   "},
        {"company_size": 0},
        {"company_size": -5},
        {"source": "carrier_pigeon"},
    ],
)
def test_post_lead_rejects_invalid_input(client, store, queue, change):
    response = client.post("/leads", json={**VALID_LEAD, **change}, headers=HEADERS)

    assert response.status_code == 422
    assert not store.leads
    assert not queue.jobs


def test_lead_is_kept_when_redis_is_down(client, store, queue):
    # The worker's sweep re-queues this lead later, so the webhook caller must not retry.
    queue.enqueue_error = redis.ConnectionError("down")

    response = client.post("/leads", json=VALID_LEAD, headers=HEADERS)

    assert response.status_code == 202
    assert len(store.leads) == 1


@pytest.mark.parametrize("error", [psycopg.OperationalError("down"), PoolTimeout("busy")])
def test_post_lead_returns_503_when_database_is_down(settings, store, queue, error):
    store.insert_error = error
    with TestClient(create_app(settings, store, queue), raise_server_exceptions=False) as client:
        response = client.post("/leads", json=VALID_LEAD, headers=HEADERS)

    assert response.status_code == 503
    assert response.headers["Retry-After"] == "5"
    assert not queue.jobs


@pytest.mark.parametrize(
    "headers",
    [{}, {"X-API-Key": "wrong"}, {"X-API-Key": ""}, {"X-API-Key": "café".encode("latin-1")}],
)
def test_lead_endpoints_require_the_api_key(client, headers):
    assert client.post("/leads", json=VALID_LEAD, headers=headers).status_code == 401
    assert client.get(f"/leads/{uuid4()}", headers=headers).status_code == 401
    assert client.get("/stats", headers=headers).status_code == 401


def test_get_lead_returns_the_saved_lead(client):
    lead_id = client.post("/leads", json=VALID_LEAD, headers=HEADERS).json()["id"]

    response = client.get(f"/leads/{lead_id}", headers=HEADERS)

    assert response.status_code == 200
    assert response.json()["job_title"] == "VP of Sales"
    assert response.json()["status"] == "pending"


def test_get_unknown_lead_returns_404(client):
    assert client.get(f"/leads/{uuid4()}", headers=HEADERS).status_code == 404


def test_get_lead_with_malformed_id_returns_422(client):
    assert client.get("/leads/not-a-uuid", headers=HEADERS).status_code == 422


def test_stats_returns_counts(client):
    client.post("/leads", json=VALID_LEAD, headers=HEADERS)

    response = client.get("/stats", headers=HEADERS)

    assert response.status_code == 200
    assert response.json()["total"] == 1


def test_healthz_stays_ok_when_dependencies_are_down(client, store, queue):
    # A failing liveness probe restarts the pod, which would not fix a database outage.
    store.ping_error = psycopg.OperationalError("down")
    queue.ping_error = redis.ConnectionError("down")

    response = client.get("/healthz")

    assert response.status_code == 200


def test_readyz_is_ok_when_dependencies_respond(client):
    response = client.get("/readyz")

    assert response.status_code == 200
    assert response.json()["checks"] == {"database": "ok", "redis": "ok"}


def test_readyz_fails_when_database_is_down(client, store):
    store.ping_error = psycopg.OperationalError("down")

    response = client.get("/readyz")

    assert response.status_code == 503
    assert response.json()["checks"] == {"database": "unavailable", "redis": "ok"}


def test_readyz_stays_ready_but_degraded_when_only_redis_is_down(client, queue):
    # Regression: failing here pulled every API pod out of the Service about 15 seconds into a
    # Redis outage, so webhooks got "connection refused" although leads could still be saved.
    queue.ping_error = redis.ConnectionError("down")

    response = client.get("/readyz")

    assert response.status_code == 200
    assert response.json()["status"] == "degraded"
    assert response.json()["checks"] == {"database": "ok", "redis": "unavailable"}


def test_readyz_fails_when_both_are_down(client, store, queue):
    store.ping_error = psycopg.OperationalError("down")
    queue.ping_error = redis.ConnectionError("down")

    assert client.get("/readyz").status_code == 503
