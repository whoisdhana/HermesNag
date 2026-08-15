"""Habit scheduling — recurring nudges.

Injected clock throughout, so the whole file runs in milliseconds. The rules
that matter here are the *restraints*: not firing overnight, and not firing
when you aren't at the machine. A habit that nags wrongly gets ignored, and an
ignored habit is worse than no habit.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.habits import (
    DEFAULT_HABITS,
    Presence,
    escalation_level,
    in_active_hours,
    is_due,
    next_due,
    overdue_minutes,
    seconds_until_due,
)
from app.models import Habit

UTC = timezone.utc
# 2026-08-12 07:30 UTC == 13:00 IST — comfortably inside a 9-21 window.
T0 = datetime(2026, 8, 12, 7, 30, tzinfo=UTC)


def habit(**kw) -> Habit:
    base = dict(name="Drink water", interval_minutes=45,
                active_from_hour=8, active_to_hour=22)
    base.update(kw)
    return Habit(**base)


# --- active hours -------------------------------------------------------------

def test_fires_inside_active_hours():
    assert in_active_hours(habit(), T0) is True


def test_silent_overnight():
    # 22:00 UTC == 03:30 IST. Nobody wants a water reminder at 3:30am.
    night = datetime(2026, 8, 12, 22, 0, tzinfo=UTC)
    assert in_active_hours(habit(), night) is False


def test_active_hours_use_ist_not_utc():
    """The window is the user's local one.

    04:00 UTC == 09:30 IST, which is inside a 9-21 window. Judged in UTC it
    would be 4am and wrongly suppressed — this test fails if anyone drops the
    timezone conversion.
    """
    morning_ist = datetime(2026, 8, 12, 4, 0, tzinfo=UTC)
    assert in_active_hours(habit(active_from_hour=9, active_to_hour=21), morning_ist) is True


def test_window_crossing_midnight():
    h = habit(active_from_hour=22, active_to_hour=6)
    # 20:00 UTC == 01:30 IST, inside a 22->6 window.
    assert in_active_hours(h, datetime(2026, 8, 12, 20, 0, tzinfo=UTC)) is True
    # 07:30 UTC == 13:00 IST, outside it.
    assert in_active_hours(h, T0) is False


# --- interval -----------------------------------------------------------------

def test_new_habit_is_due_immediately():
    assert is_due(habit(), T0) is True


def test_not_due_before_the_interval_elapses():
    h = habit(last_done_at=T0 - timedelta(minutes=10))
    assert is_due(h, T0) is False


def test_due_once_the_interval_elapses():
    h = habit(last_done_at=T0 - timedelta(minutes=46))
    assert is_due(h, T0) is True


def test_next_due_follows_last_done():
    h = habit(last_done_at=T0)
    assert next_due(h, T0) == T0 + timedelta(minutes=45)


def test_firing_delays_the_next_nudge():
    """Showing a nudge must reset the clock, or it would re-fire every tick."""
    h = habit(last_fired_at=T0 - timedelta(minutes=5))
    assert is_due(h, T0) is False


def test_disabled_habit_never_fires():
    assert is_due(habit(enabled=False), T0) is False


def test_countdown_for_the_widget():
    h = habit(last_done_at=T0 - timedelta(minutes=15))
    assert seconds_until_due(h, T0) == 30 * 60


# --- presence -----------------------------------------------------------------

def test_presence_habit_waits_for_real_sitting_time():
    """'Stand up' only makes sense if you've been sitting."""
    h = habit(name="Stand up", requires_presence=True, presence_minutes=45)
    assert is_due(h, T0, Presence(active=True, continuous_minutes=10)) is False
    assert is_due(h, T0, Presence(active=True, continuous_minutes=50)) is True


def test_presence_habit_silent_when_away():
    h = habit(requires_presence=True, presence_minutes=10)
    assert is_due(h, T0, Presence(active=False, continuous_minutes=99)) is False


def test_presence_habit_silent_when_screen_locked():
    h = habit(requires_presence=True, presence_minutes=10)
    away = Presence(active=True, continuous_minutes=99, screen_locked=True)
    assert is_due(h, T0, away) is False


def test_non_presence_habit_fires_regardless():
    # Water doesn't care whether you're at the laptop.
    assert is_due(habit(requires_presence=False), T0, Presence(active=False)) is True


# --- escalation ---------------------------------------------------------------

def test_level_zero_when_not_due():
    assert escalation_level(habit(last_done_at=T0), T0) == 0


def test_starts_at_level_one():
    assert escalation_level(habit(), T0) == 1


def test_escalates_when_ignored():
    h = habit(last_fired_at=T0 - timedelta(minutes=45 + 30))
    assert escalation_level(h, T0) == 2


def test_habits_never_reach_takeover():
    """A water reminder must never seize the screen, however long ignored."""
    h = habit(last_fired_at=T0 - timedelta(days=2))
    assert escalation_level(h, T0) == 2


def test_non_escalating_habit_stays_gentle():
    # Eye rest fires ~30x a day; escalating it would be intolerable.
    h = habit(escalates=False, last_fired_at=T0 - timedelta(hours=5))
    assert escalation_level(h, T0) == 1


def test_overdue_minutes():
    h = habit(last_done_at=T0 - timedelta(minutes=60))
    assert overdue_minutes(h, T0) == 15


# --- defaults -----------------------------------------------------------------

def test_default_habits_cover_what_was_asked_for():
    names = " ".join(h["name"].lower() for h in DEFAULT_HABITS)
    assert "water" in names
    assert "stand" in names
    assert "eyes" in names


def test_sitting_habits_require_presence():
    for spec in DEFAULT_HABITS:
        if "stand" in spec["name"].lower() or "eyes" in spec["name"].lower():
            assert spec["requires_presence"] is True, spec["name"]


def test_frequent_habits_do_not_escalate():
    for spec in DEFAULT_HABITS:
        if spec["interval_minutes"] <= 20:
            assert spec["escalates"] is False, f"{spec['name']} fires too often to escalate"


def test_no_habit_is_active_overnight():
    for spec in DEFAULT_HABITS:
        assert spec["active_from_hour"] >= 6, spec["name"]
        assert spec["active_to_hour"] <= 23, spec["name"]


# --- API ----------------------------------------------------------------------

def test_seed_creates_defaults(client):
    body = client.post("/habits/seed").json()
    assert body["count"] == len(DEFAULT_HABITS)

    habits_list = client.get("/habits").json()["habits"]
    assert len(habits_list) == len(DEFAULT_HABITS)


def test_seed_is_idempotent(client):
    client.post("/habits/seed")
    assert client.post("/habits/seed").json()["count"] == 0


def test_habits_due_reports_a_nag_line(client):
    client.post("/habits/seed")
    body = client.get("/habits/due", params={"continuous_minutes": 60}).json()
    assert body["count"] >= 1
    assert body["due"][0]["nag_line"]


def test_marking_a_habit_done_resets_and_bumps_streak(client):
    client.post("/habits/seed")
    habit_id = client.get("/habits").json()["habits"][0]["id"]

    body = client.post(f"/habits/{habit_id}/done").json()
    assert body["streak"] == 1
    assert body["is_due"] is False       # interval restarted
    assert body["seconds_until_due"] > 0


def test_unknown_habit_is_404(client):
    assert client.post("/habits/nope/done").status_code == 404


def test_presence_query_suppresses_sitting_habits(client):
    client.post("/habits/seed")
    # Away from the machine: only the non-presence habits may fire.
    due = client.get("/habits/due", params={"active": False}).json()["due"]
    assert all(not h["requires_presence"] for h in due)


# --- mobile page ---------------------------------------------------------------

def test_mobile_page_serves_without_auth(anon_client):
    """The shell is public (tailnet-gated in deployment); data calls are not."""
    r = anon_client.get("/m")
    assert r.status_code == 200
    assert "HermesNag" in r.text


def test_mobile_page_does_not_leak_the_token(anon_client):
    assert "HERMESNAG_TOKEN" not in anon_client.get("/m").text


def test_api_still_requires_auth_alongside_mobile_page(anon_client):
    assert anon_client.get("/tasks").status_code == 401


# --- habit CRUD (the brief's "create my own habits") ---------------------------

def test_create_habit_from_raw_daily(client):
    body = client.post("/habits", json={"raw": "meditate daily"}).json()
    assert body["name"] == "meditate"
    assert body["interval_minutes"] == 1440


def test_create_habit_from_raw_interval(client):
    body = client.post("/habits", json={"raw": "journal every 90m"}).json()
    assert body["name"] == "journal"
    assert body["interval_minutes"] == 90


def test_create_habit_hourly_interval(client):
    assert client.post("/habits", json={"raw": "walk every 2h"}).json()["interval_minutes"] == 120


def test_create_habit_defaults_to_daily(client):
    assert client.post("/habits", json={"name": "read a book"}).json()["interval_minutes"] == 1440


def test_duplicate_habit_is_409(client):
    client.post("/habits", json={"name": "yoga"})
    assert client.post("/habits", json={"name": "yoga"}).status_code == 409


def test_absurdly_short_interval_is_coerced(client):
    # every 1m would be spam, not a habit
    assert client.post("/habits", json={"name": "x", "interval_minutes": 1}).json()["interval_minutes"] == 1440


def test_disable_habit_keeps_the_row(client):
    hid = client.post("/habits", json={"name": "swim"}).json()["id"]
    body = client.patch(f"/habits/{hid}", json={"enabled": False}).json()
    assert body["enabled"] is False
    # still listed — disable, never delete
    assert any(h["id"] == hid for h in client.get("/habits").json()["habits"])


def test_edit_habit_interval(client):
    hid = client.post("/habits", json={"name": "stretch neck"}).json()["id"]
    assert client.patch(f"/habits/{hid}", json={"interval_minutes": 60}).json()["interval_minutes"] == 60


def test_habit_requires_name_or_raw(client):
    assert client.post("/habits", json={}).status_code == 400


# --- the 5-minute machine-gun bug ----------------------------------------------

def test_firing_defers_even_after_a_past_completion():
    """The exact bug Dhana reported as 'notified me every 5 mins'.

    `anchor = last_done_at or last_fired_at` preferred the completion even
    when the fire was NEWER — so once a habit had ever been done, showing a
    nudge no longer deferred it. It stayed permanently due, and the client's
    re-nudge guard turned that into a notification every 5 minutes.
    """
    h = habit(
        last_done_at=T0 - timedelta(minutes=60),   # completed an hour ago
        last_fired_at=T0 - timedelta(minutes=5),   # nudged 5 minutes ago
    )
    assert is_due(h, T0) is False, "a fresh nudge must defer the habit"
    assert next_due(h, T0) == T0 + timedelta(minutes=40)  # 5m ago + 45m


def test_completion_after_fire_also_anchors_correctly():
    # Inverse ordering: done AFTER the last fire — completion wins.
    h = habit(
        last_fired_at=T0 - timedelta(minutes=60),
        last_done_at=T0 - timedelta(minutes=10),
    )
    assert next_due(h, T0) == T0 + timedelta(minutes=35)
    assert is_due(h, T0) is False
