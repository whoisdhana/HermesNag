"""Data model — exactly the tables in the spec.

Two invariants that everything else depends on:
  * Rows are never deleted. `dropped` is a status; `event` is append-only.
  * Datetimes are stored as UTC. SQLite has no native tz type, so we round-trip
    through a TypeDecorator that re-attaches UTC on read (correction C1).
"""

from __future__ import annotations

import uuid
from datetime import datetime
from enum import Enum
from typing import Any

from sqlalchemy import JSON, Column, DateTime, TypeDecorator
from sqlmodel import Field, SQLModel

from .timeutil import UTC, ensure_utc, now_utc


class UTCDateTime(TypeDecorator):
    """Store aware UTC; read back aware UTC.

    Without this, SQLite returns naive datetimes and every downstream
    comparison silently drifts by the IST offset.
    """

    impl = DateTime
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect) -> datetime | None:
        # ensure_utc raises on naive input rather than guessing.
        return ensure_utc(value)

    def process_result_value(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None
        return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _utc_column(**kw: Any) -> Column:
    return Column(UTCDateTime, **kw)


def new_uuid() -> str:
    return str(uuid.uuid4())


class Priority(str, Enum):
    low = "low"
    normal = "normal"
    high = "high"
    must = "must"  # the only priority allowed to reach L3 takeover


class Status(str, Enum):
    pending = "pending"
    snoozed = "snoozed"
    done = "done"
    dropped = "dropped"  # a status, never a DELETE


class CreatedBy(str, Enum):
    user = "user"
    hermes = "hermes"


class EventKind(str, Enum):
    created = "created"
    shown = "shown"
    snoozed = "snoozed"
    ignored = "ignored"
    completed = "completed"
    dropped = "dropped"
    escalated = "escalated"
    panic = "panic"  # panic-exit hotkey; spec wants these counted
    reopened = "reopened"  # undo of a completion — the ledger stays append-only


class Task(SQLModel, table=True):
    __tablename__ = "task"

    id: str = Field(default_factory=new_uuid, primary_key=True)
    title: str
    notes: str | None = None

    due_at: datetime | None = Field(default=None, sa_column=_utc_column(index=True))
    recurrence: str | None = None  # RRULE string, RFC 5545 subset

    priority: Priority = Field(default=Priority.normal, index=True)
    tags: list[str] = Field(default_factory=list, sa_column=Column(JSON))

    status: Status = Field(default=Status.pending, index=True)
    snooze_until: datetime | None = Field(default=None, sa_column=_utc_column())

    escalation_level: int = Field(default=0)  # 0–3
    ignore_count: int = Field(default=0)      # popups shown with no interaction
    snooze_count: int = Field(default=0)

    created_by: CreatedBy = Field(default=CreatedBy.user)
    source_ref: str | None = None  # e.g. the email Hermes derived this from

    created_at: datetime = Field(default_factory=now_utc, sa_column=_utc_column(nullable=False))
    completed_at: datetime | None = Field(default=None, sa_column=_utc_column())

    # Set by the user to force L3 regardless of ignore_count ("no escape").
    no_escape: bool = Field(default=False)


class Event(SQLModel, table=True):
    """Append-only. Hermes's memory and the gamification ledger."""

    __tablename__ = "event"

    id: str = Field(default_factory=new_uuid, primary_key=True)
    task_id: str | None = Field(default=None, foreign_key="task.id", index=True)
    kind: EventKind = Field(index=True)
    at: datetime = Field(default_factory=now_utc, sa_column=_utc_column(nullable=False, index=True))
    meta: dict[str, Any] = Field(default_factory=dict, sa_column=Column(JSON))


class Habit(SQLModel, table=True):
    """A recurring nudge — drink water, stand up, rest your eyes.

    Distinct from Task: a habit has no deadline and is never "done", it just
    comes round again. Firing is interval-based within active hours, so it
    doesn't nag at 3am.
    """

    __tablename__ = "habit"

    id: str = Field(default_factory=new_uuid, primary_key=True)
    name: str
    interval_minutes: int

    # Active window in the user's local zone (IST). 9 -> 21 means 09:00-21:00.
    active_from_hour: int = Field(default=9)
    active_to_hour: int = Field(default=21)

    # Only fire if the laptop has actually been in use — a "stand up" nudge
    # while you're out for lunch is noise that teaches you to ignore it.
    requires_presence: bool = Field(default=False)
    # Minimum continuous minutes at the machine before this may fire.
    presence_minutes: int = Field(default=0)

    escalates: bool = Field(default=True)
    enabled: bool = Field(default=True)

    last_fired_at: datetime | None = Field(default=None, sa_column=_utc_column())
    last_done_at: datetime | None = Field(default=None, sa_column=_utc_column())
    streak: int = Field(default=0)

    created_at: datetime = Field(default_factory=now_utc, sa_column=_utc_column(nullable=False))


class NagLine(SQLModel, table=True):
    """Pre-generated pool. Hermes takes 14–17s per call, so the reminder path
    reads from here and never blocks on an LLM."""

    __tablename__ = "nag_line"

    id: str = Field(default_factory=new_uuid, primary_key=True)
    task_id: str | None = Field(default=None, foreign_key="task.id", index=True)
    level: int = Field(index=True)  # 1–3
    text: str
    used_at: datetime | None = Field(default=None, sa_column=_utc_column())
    created_at: datetime = Field(default_factory=now_utc, sa_column=_utc_column(nullable=False))
