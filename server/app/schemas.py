"""Request/response shapes.

Datetime fields are `datetime` so pydantic parses the offset, then validators
push them through ensure_utc — which *rejects* naive input rather than guessing
(correction C1). This is the boundary where a bad timestamp gets caught.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, field_validator

from .models import CreatedBy, Priority, Status
from .timeutil import ensure_utc


def _utc_validator(cls, v):
    return ensure_utc(v)


class TaskCreate(BaseModel):
    title: str | None = None
    raw: str | None = None  # natural language; parsed server-side
    notes: str | None = None
    due_at: datetime | None = None
    recurrence: str | None = None
    priority: Priority = Priority.normal
    tags: list[str] = []
    created_by: CreatedBy = CreatedBy.user
    source_ref: str | None = None
    no_escape: bool = False

    _v_due = field_validator("due_at")(_utc_validator)


class TaskUpdate(BaseModel):
    title: str | None = None
    notes: str | None = None
    due_at: datetime | None = None
    recurrence: str | None = None
    priority: Priority | None = None
    tags: list[str] | None = None
    status: Status | None = None
    no_escape: bool | None = None

    _v_due = field_validator("due_at")(_utc_validator)


class SnoozeRequest(BaseModel):
    minutes: int | None = None
    until: datetime | None = None

    _v_until = field_validator("until")(_utc_validator)


class AckRequest(BaseModel):
    level: int
    action: str  # "shown" | "ignored"


class ParseRequest(BaseModel):
    raw: str


class HabitCreate(BaseModel):
    """Create a habit. Either structured fields, or `raw` natural language
    ("meditate daily", "journal every 90m")."""
    name: str | None = None
    raw: str | None = None
    interval_minutes: int | None = None
    daily: bool = False                     # shorthand for interval 1440
    active_from_hour: int = 8
    active_to_hour: int = 22
    requires_presence: bool = False
    presence_minutes: int = 0
    escalates: bool = False                 # user habits default gentle


class HabitUpdate(BaseModel):
    name: str | None = None
    interval_minutes: int | None = None
    active_from_hour: int | None = None
    active_to_hour: int | None = None
    requires_presence: bool | None = None
    escalates: bool | None = None
    enabled: bool | None = None             # disable, never delete


class NagLinesRequest(BaseModel):
    """Pre-generated nag copy from Hermes. `task_id` omitted = generic lines
    usable by any task (they may contain a {title} placeholder)."""
    level: int
    lines: list[str]
    task_id: str | None = None


class CompleteResponse(BaseModel):
    task: dict[str, Any]
    xp_awarded: int
    streak: int
    mascot_mood: str
