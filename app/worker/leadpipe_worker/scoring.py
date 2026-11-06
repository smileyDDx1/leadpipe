"""Scores a lead from 0 to 100 using simple rules for job title, company size and source."""

from __future__ import annotations

import re
from dataclasses import dataclass

# Whole-word matching matters: a plain substring check finds "cto" inside "director".
# The lookbehind stops "Vice President" from scoring as a president.
_TITLE_RULES: tuple[tuple[re.Pattern[str], int], ...] = (
    (
        re.compile(
            r"\b(ceo|cto|cfo|coo|cmo|cio|chief|founder|co-?founder|owner|(?<!vice )president)\b",
            re.I,
        ),
        40,
    ),
    (re.compile(r"\b(vp|svp|evp|vice president|head|director)\b", re.I), 30),
    (re.compile(r"\b(manager|lead|principal)\b", re.I), 20),
)
_OTHER_TITLE_POINTS = 10

_SIZE_BANDS: tuple[tuple[int, int], ...] = ((1000, 30), (200, 25), (50, 20), (10, 10), (1, 5))

_SOURCE_POINTS = {
    "referral": 30,
    "website_form": 20,
    "event": 20,
    "crm": 15,
    "paid_ads": 10,
}
_OTHER_SOURCE_POINTS = 5

HOT_THRESHOLD = 70
WARM_THRESHOLD = 40


@dataclass(frozen=True)
class ScoreResult:
    score: int
    grade: str


def _title_points(job_title: str | None) -> int:
    if not job_title or not job_title.strip():
        return 0
    for pattern, points in _TITLE_RULES:
        if pattern.search(job_title):
            return points
    return _OTHER_TITLE_POINTS


def _size_points(company_size: int | None) -> int:
    if company_size is None:
        return 0
    for minimum, points in _SIZE_BANDS:
        if company_size >= minimum:
            return points
    return 0


def score_lead(job_title: str | None, company_size: int | None, source: str) -> ScoreResult:
    score = (
        _title_points(job_title)
        + _size_points(company_size)
        + _SOURCE_POINTS.get(source, _OTHER_SOURCE_POINTS)
    )
    if score >= HOT_THRESHOLD:
        grade = "hot"
    elif score >= WARM_THRESHOLD:
        grade = "warm"
    else:
        grade = "cold"
    return ScoreResult(score=score, grade=grade)
