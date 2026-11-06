#!/usr/bin/env python3
"""End-to-end check against a running stack (Compose or Kubernetes). Standard library only.

Usage: python scripts/e2e_check.py [base_url]
Reads API_KEY from the environment, and defaults to the local Compose values.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

BASE_URL = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000").rstrip("/")
API_KEY = os.environ.get("API_KEY", "local-dev-key")
SCORING_TIMEOUT_SECONDS = 30


def call(method: str, path: str, body: dict | None = None, key: str | None = API_KEY):
    headers = {"Content-Type": "application/json"}
    if key:
        headers["X-API-Key"] = key
    request = urllib.request.Request(  # noqa: S310 - the URL is supplied by the operator
        BASE_URL + path,
        method=method,
        headers=headers,
        data=json.dumps(body).encode() if body is not None else None,
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:  # noqa: S310
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def check(name: str, condition: bool, detail: object = "") -> None:
    print(f"{'PASS' if condition else 'FAIL'}  {name}{f'  ({detail})' if detail else ''}")
    if not condition:
        sys.exit(1)


def wait_until_scored(lead_id: str) -> dict:
    deadline = time.monotonic() + SCORING_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        _, lead = call("GET", f"/leads/{lead_id}")
        if lead["status"] == "scored":
            return lead
        time.sleep(0.5)
    print(f"FAIL  lead {lead_id} was not scored within {SCORING_TIMEOUT_SECONDS}s")
    sys.exit(1)


def main() -> None:
    status, _ = call("GET", "/healthz", key=None)
    check("GET /healthz returns 200 without a key", status == 200)
    status, body = call("GET", "/readyz", key=None)
    ready = status == 200 and body.get("status") == "ready"
    check("GET /readyz reports database and redis ok", ready, body.get("checks"))

    # The unique address keeps repeat runs from colliding with earlier data.
    email = f"e2e-{uuid.uuid4().hex[:12]}@example.com"
    lead = {
        "email": email,
        "name": "E2E Check",
        "company": "Example Ltd",
        "job_title": "VP of Sales",
        "company_size": 250,
        "source": "website_form",
    }

    status, _ = call("POST", "/leads", lead, key="wrong-key")
    check("POST /leads rejects a wrong API key", status == 401, status)
    status, _ = call("POST", "/leads", {**lead, "email": "not-an-email"})
    check("POST /leads rejects an invalid email", status == 422, status)

    status, first = call("POST", "/leads", lead)
    check("POST /leads accepts a valid lead", status == 202, status)
    scored = wait_until_scored(first["id"])
    # VP = 30, 250 employees = 25, website form = 20.
    check("worker scored the lead", scored["score"] == 75, scored["score"])
    check("worker graded the lead", scored["grade"] == "hot", scored["grade"])
    check("first lead is not a duplicate", scored["is_duplicate"] is False)

    status, second = call("POST", "/leads", {**lead, "email": email.upper()})
    check("POST /leads accepts the same person again", status == 202, status)
    duplicate = wait_until_scored(second["id"])
    check("worker flagged the duplicate", duplicate["is_duplicate"] is True)
    check("duplicate points to the original", duplicate["duplicate_of"] == first["id"])

    status, _ = call("GET", f"/leads/{uuid.uuid4()}")
    check("GET /leads/{id} returns 404 for an unknown lead", status == 404, status)

    status, stats = call("GET", "/stats")
    check("GET /stats counts the leads", status == 200 and stats["total"] >= 2, stats)

    print("All end-to-end checks passed.")


if __name__ == "__main__":
    main()
