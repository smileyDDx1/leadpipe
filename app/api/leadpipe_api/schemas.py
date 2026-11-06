"""Request and response models."""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator


class LeadSource(StrEnum):
    WEBSITE_FORM = "website_form"
    CRM = "crm"
    REFERRAL = "referral"
    EVENT = "event"
    PAID_ADS = "paid_ads"
    OTHER = "other"


class LeadIn(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    email: EmailStr
    name: str = Field(min_length=1, max_length=200)
    company: str | None = Field(default=None, max_length=200)
    job_title: str | None = Field(default=None, max_length=200)
    company_size: int | None = Field(default=None, ge=1)
    source: LeadSource = LeadSource.OTHER

    @field_validator("email")
    @classmethod
    def lowercase_email(cls, value: str) -> str:
        # Duplicate detection compares emails exactly, so store one canonical form.
        return value.lower()


class LeadAccepted(BaseModel):
    id: UUID
    status: str = "pending"


class LeadOut(BaseModel):
    id: UUID
    email: str
    name: str
    company: str | None
    job_title: str | None
    company_size: int | None
    source: str
    status: str
    score: int | None
    grade: str | None
    is_duplicate: bool
    duplicate_of: UUID | None
    created_at: datetime
    scored_at: datetime | None


class Stats(BaseModel):
    total: int
    pending: int
    scored: int
    duplicates: int
    hot: int
    warm: int
    cold: int
    average_score: float | None
