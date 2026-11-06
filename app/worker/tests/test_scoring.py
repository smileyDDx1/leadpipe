from __future__ import annotations

import pytest

from leadpipe_worker.scoring import score_lead


@pytest.mark.parametrize(
    ("job_title", "expected_points"),
    [
        ("CEO", 40),
        ("Chief Revenue Officer", 40),
        ("Co-Founder", 40),
        ("President", 40),
        ("cofounder", 40),
        ("VP of Sales", 30),
        ("Vice President, Marketing", 30),
        ("Head of Growth", 30),
        ("Director of Sales", 30),
        ("Marketing Manager", 20),
        ("Tech Lead", 20),
        ("Analyst", 10),
        ("", 0),
        ("   ", 0),
        (None, 0),
    ],
)
def test_title_points(job_title, expected_points):
    # Source "unknown" adds 5 points, and an unknown company size adds none.
    assert score_lead(job_title, None, "unknown").score == expected_points + 5


@pytest.mark.parametrize(
    ("job_title", "expected_points"),
    [
        # These contain "cto", "coo", "owner" or "lead" inside a longer word.
        ("Sector Analyst", 10),
        ("Cook", 10),
        ("Pet Groomer", 10),
        ("Leadership Coach", 10),
    ],
)
def test_title_rules_match_whole_words_only(job_title, expected_points):
    assert score_lead(job_title, None, "unknown").score == expected_points + 5


def test_director_is_not_mistaken_for_cto():
    # "director" contains the letters "cto". It must score as a director (30), not a CTO (40).
    assert score_lead("Director", None, "unknown").score == 35


@pytest.mark.parametrize(
    ("company_size", "expected_points"),
    [
        (5000, 30),
        (1000, 30),
        (999, 25),
        (200, 25),
        (199, 20),
        (50, 20),
        (49, 10),
        (10, 10),
        (9, 5),
        (1, 5),
        (None, 0),
    ],
)
def test_company_size_points(company_size, expected_points):
    assert score_lead(None, company_size, "unknown").score == expected_points + 5


@pytest.mark.parametrize(
    ("source", "expected_points"),
    [
        ("referral", 30),
        ("website_form", 20),
        ("event", 20),
        ("crm", 15),
        ("paid_ads", 10),
        ("other", 5),
        ("anything_new", 5),
    ],
)
def test_source_points(source, expected_points):
    assert score_lead(None, None, source).score == expected_points


@pytest.mark.parametrize(
    ("job_title", "company_size", "source", "score", "grade"),
    [
        ("CEO", 5000, "referral", 100, "hot"),  # the maximum
        ("VP Sales", 200, "crm", 70, "hot"),  # exactly on the hot threshold
        ("Manager", 200, "crm", 60, "warm"),
        ("Manager", 10, "paid_ads", 40, "warm"),  # exactly on the warm threshold
        ("Analyst", 10, "crm", 35, "cold"),
        (None, None, "other", 5, "cold"),  # the minimum
    ],
)
def test_total_score_and_grade(job_title, company_size, source, score, grade):
    result = score_lead(job_title, company_size, source)

    assert (result.score, result.grade) == (score, grade)
