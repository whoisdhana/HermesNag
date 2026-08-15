"""Timezone tests — correction C1.

The Oracle box runs Asia/Kolkata, not UTC as the spec assumed. Because the
server's local zone equals the client's display zone, a naive-datetime bug
would render *correct-looking* output everywhere we might casually look.

So these tests assert the rejection **explicitly**. They never infer correctness
from an observed value, because on this box the observed value would look fine
while being 5h30m wrong in the database.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlmodel import select

from app.models import Task
from app.timeutil import (
    DISPLAY_TZ,
    UTC,
    NaiveDatetimeError,
    ensure_utc,
    iso,
    now_utc,
    parse_iso,
    to_display,
)

IST = timezone(timedelta(hours=5, minutes=30))


# --- the load-bearing test ----------------------------------------------------

def test_naive_datetime_is_rejected():
    """A naive datetime must raise, not be silently assumed to be UTC or local."""
    naive = datetime(2026, 8, 12, 18, 30, 0)  # no tzinfo
    assert naive.tzinfo is None

    with pytest.raises(NaiveDatetimeError):
        ensure_utc(naive)


def test_naive_iso_string_is_rejected():
    with pytest.raises(NaiveDatetimeError):
        parse_iso("2026-08-12T18:30:00")  # no offset


def test_naive_datetime_rejected_at_the_model_boundary(session):
    """Persisting a naive datetime must fail rather than write a wrong instant."""
    task = Task(title="naive due date")
    task.due_at = datetime(2026, 8, 12, 18, 30, 0)  # naive
    session.add(task)

    with pytest.raises((NaiveDatetimeError, Exception)) as exc:
        session.commit()
    session.rollback()
    assert "naive" in str(exc.value).lower() or isinstance(exc.value, NaiveDatetimeError)


def test_naive_datetime_rejected_by_api(client):
    """The API returns 400, not a silently-shifted task."""
    resp = client.post("/tasks", json={"title": "bill", "due_at": "2026-08-12T18:30:00"})
    assert resp.status_code == 400, resp.text
    assert resp.json()["error"]["code"] == "invalid_request"
    assert "naive" in resp.json()["error"]["message"].lower()


# --- offset correctness -------------------------------------------------------

def test_fixed_instant_renders_as_ist_with_correct_offset():
    """Pin a UTC instant; assert the IST rendering is +05:30."""
    instant = datetime(2026, 8, 12, 13, 0, 0, tzinfo=UTC)  # 13:00Z
    local = to_display(instant)

    assert local.utcoffset() == timedelta(hours=5, minutes=30)
    assert (local.hour, local.minute) == (18, 30)  # 13:00Z -> 18:30 IST
    assert local.date() == instant.date()


def test_ist_input_is_stored_as_the_same_instant_in_utc():
    ist_time = datetime(2026, 8, 12, 18, 30, 0, tzinfo=IST)
    stored = ensure_utc(ist_time)

    assert stored.tzinfo is UTC
    assert (stored.hour, stored.minute) == (13, 0)
    assert stored == ist_time  # same instant, different representation


def test_wire_format_always_carries_an_offset():
    text = iso(datetime(2026, 8, 12, 13, 0, 0, tzinfo=UTC))
    assert text.endswith("+00:00") or text.endswith("Z")


def test_z_suffix_is_accepted():
    assert parse_iso("2026-08-12T13:00:00Z") == datetime(2026, 8, 12, 13, 0, tzinfo=UTC)


def test_now_utc_is_always_aware():
    now = now_utc()
    assert now.tzinfo is not None
    assert now.utcoffset() == timedelta(0)


# --- round-trip through SQLite ------------------------------------------------

def test_datetime_survives_sqlite_round_trip_as_aware_utc(session):
    """SQLite has no tz type; the TypeDecorator must re-attach UTC on read."""
    due = datetime(2026, 8, 12, 13, 0, 0, tzinfo=UTC)
    task = Task(title="round trip", due_at=due)
    session.add(task)
    session.commit()
    task_id = task.id
    session.expunge_all()

    loaded = session.exec(select(Task).where(Task.id == task_id)).one()

    assert loaded.due_at.tzinfo is not None, "read back naive — the IST bug"
    assert loaded.due_at == due
    assert to_display(loaded.due_at).hour == 18


def test_ist_input_round_trips_to_the_same_instant(session, client):
    """End-to-end: submit IST, read back the same moment in UTC."""
    resp = client.post("/tasks", json={"title": "pay bill", "due_at": "2026-08-12T18:30:00+05:30"})
    assert resp.status_code == 201, resp.text

    body = resp.json()
    assert body["due_at"] == "2026-08-12T13:00:00+00:00"
    assert "+05:30" in body["due_at_local"]
    assert parse_iso(body["due_at"]) == parse_iso(body["due_at_local"])


def test_display_zone_is_asia_kolkata():
    assert str(DISPLAY_TZ) == "Asia/Kolkata"
