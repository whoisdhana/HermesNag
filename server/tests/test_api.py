"""API contract: auth, CRUD, the action endpoints, and the append-only ledger."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlmodel import select

from app.models import Event, EventKind, Status, Task

UTC = timezone.utc


# --- auth ---------------------------------------------------------------------

def test_health_needs_no_token(anon_client):
    resp = anon_client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["db_ok"] is True
    assert "hermes_ok" in body


def test_tasks_without_token_is_401(anon_client):
    resp = anon_client.get("/tasks")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"


def test_wrong_token_is_401(anon_client):
    resp = anon_client.get("/tasks", headers={"Authorization": "Bearer wrong"})
    assert resp.status_code == 401


def test_malformed_auth_header_is_401(anon_client):
    resp = anon_client.get("/tasks", headers={"Authorization": "Basic abc"})
    assert resp.status_code == 401


# --- errors -------------------------------------------------------------------

def test_missing_task_is_404_with_error_shape(client):
    resp = client.get("/tasks/does-not-exist")
    assert resp.status_code == 404
    assert set(resp.json()["error"]) >= {"code", "message"}
    assert resp.json()["error"]["code"] == "not_found"


def test_task_requires_title_or_raw(client):
    resp = client.post("/tasks", json={"notes": "orphan"})
    assert resp.status_code == 400


# --- CRUD ---------------------------------------------------------------------

def test_create_and_fetch(client):
    created = client.post("/tasks", json={
        "title": "Pay electricity bill",
        "due_at": "2026-08-12T18:30:00+05:30",
        "priority": "must",
        "tags": ["home", "money"],
    })
    assert created.status_code == 201
    body = created.json()
    assert body["title"] == "Pay electricity bill"
    assert body["priority"] == "must"
    assert body["tags"] == ["home", "money"]
    assert body["status"] == "pending"

    fetched = client.get(f"/tasks/{body['id']}")
    assert fetched.status_code == 200
    assert fetched.json()["id"] == body["id"]


def test_create_from_raw_natural_language(client):
    resp = client.post("/tasks", json={"raw": "pay the water bill tomorrow 6pm #home urgent"})
    assert resp.status_code == 201
    body = resp.json()
    assert "water bill" in body["title"].lower()
    assert body["due_at"] is not None
    assert body["priority"] == "must"   # "urgent"
    assert "home" in body["tags"]
    assert "#home" not in body["title"]  # tag stripped from the title


def test_patch_updates_fields(client):
    task_id = client.post("/tasks", json={"title": "old"}).json()["id"]
    resp = client.patch(f"/tasks/{task_id}", json={"title": "new", "priority": "high"})
    assert resp.status_code == 200
    assert resp.json()["title"] == "new"
    assert resp.json()["priority"] == "high"


def test_list_filters_by_status(client):
    a = client.post("/tasks", json={"title": "keep"}).json()["id"]
    client.post("/tasks", json={"title": "drop me"})
    client.post(f"/tasks/{a}/drop")

    dropped = client.get("/tasks", params={"status_filter": "dropped"}).json()["tasks"]
    assert len(dropped) == 1
    assert dropped[0]["title"] == "keep"


def test_unknown_status_filter_is_400(client):
    assert client.get("/tasks", params={"status_filter": "banana"}).status_code == 400


# --- actions ------------------------------------------------------------------

def test_complete_awards_xp_and_streak(client):
    task_id = client.post("/tasks", json={"title": "done soon"}).json()["id"]
    resp = client.post(f"/tasks/{task_id}/complete")
    assert resp.status_code == 200

    body = resp.json()
    assert body["task"]["status"] == "done"
    assert body["task"]["completed_at"] is not None
    assert body["xp_awarded"] == 10
    assert body["streak"] == 1
    assert body["mascot_mood"] in ("pleased", "happy", "ecstatic")


def test_completing_twice_is_409(client):
    task_id = client.post("/tasks", json={"title": "once"}).json()["id"]
    client.post(f"/tasks/{task_id}/complete")
    assert client.post(f"/tasks/{task_id}/complete").status_code == 409


def test_snooze_by_minutes(client):
    task_id = client.post("/tasks", json={
        "title": "later", "due_at": "2026-08-12T13:00:00+00:00"}).json()["id"]

    body = client.post(f"/tasks/{task_id}/snooze", json={"minutes": 10}).json()
    assert body["status"] == "snoozed"
    assert body["snooze_count"] == 1
    assert body["snooze_until"] is not None


def test_snooze_requires_a_parameter(client):
    task_id = client.post("/tasks", json={"title": "x"}).json()["id"]
    assert client.post(f"/tasks/{task_id}/snooze", json={}).status_code == 400


def test_negative_snooze_is_rejected(client):
    task_id = client.post("/tasks", json={"title": "x"}).json()["id"]
    assert client.post(f"/tasks/{task_id}/snooze", json={"minutes": -5}).status_code == 400


def test_drop_sets_status_and_does_not_delete(client, session):
    task_id = client.post("/tasks", json={"title": "not today"}).json()["id"]
    assert client.post(f"/tasks/{task_id}/drop").json()["status"] == "dropped"

    # The row must still exist — 'dropped' is a status, never a DELETE.
    assert session.get(Task, task_id) is not None


def test_ack_ignored_increments_and_escalates(client):
    task_id = client.post("/tasks", json={
        "title": "ignore me", "due_at": "2020-01-01T00:00:00+00:00"}).json()["id"]

    body = client.post(f"/tasks/{task_id}/ack", json={"level": 1, "action": "ignored"}).json()
    assert body["ignore_count"] == 1
    assert body["escalation_level"] >= 2  # one ignore is enough for L2


def test_ack_shown_does_not_increment_ignores(client):
    task_id = client.post("/tasks", json={"title": "seen"}).json()["id"]
    body = client.post(f"/tasks/{task_id}/ack", json={"level": 1, "action": "shown"}).json()
    assert body["ignore_count"] == 0


def test_ack_rejects_unknown_action(client):
    task_id = client.post("/tasks", json={"title": "x"}).json()["id"]
    resp = client.post(f"/tasks/{task_id}/ack", json={"level": 1, "action": "yelled"})
    assert resp.status_code == 400


# --- /due ---------------------------------------------------------------------

def test_due_returns_overdue_tasks_with_a_nag_line(client):
    client.post("/tasks", json={"title": "Pay rent", "due_at": "2020-01-01T00:00:00+00:00"})
    body = client.get("/due").json()

    assert body["count"] == 1
    item = body["due"][0]
    assert item["level"] >= 1
    assert item["nag_line"]                      # never mute
    assert "Pay rent" in item["nag_line"] or len(item["nag_line"]) > 0


def test_future_tasks_are_not_due(client):
    client.post("/tasks", json={"title": "later", "due_at": "2099-01-01T00:00:00+00:00"})
    assert client.get("/due").json()["count"] == 0


def test_due_sorts_most_urgent_first(client):
    client.post("/tasks", json={"title": "normal", "due_at": "2026-01-01T00:00:00+00:00"})
    client.post("/tasks", json={"title": "critical", "priority": "must",
                                "due_at": "2020-01-01T00:00:00+00:00"})
    due = client.get("/due").json()["due"]
    assert due[0]["title"] == "critical"
    assert due[0]["level"] == 3


# --- ledger -------------------------------------------------------------------

def test_events_are_appended_for_the_lifecycle(client, session):
    task_id = client.post("/tasks", json={"title": "tracked"}).json()["id"]
    client.post(f"/tasks/{task_id}/snooze", json={"minutes": 5})
    client.post(f"/tasks/{task_id}/complete")

    kinds = [e.kind for e in session.exec(
        select(Event).where(Event.task_id == task_id)).all()]

    assert EventKind.created in kinds
    assert EventKind.snoozed in kinds
    assert EventKind.completed in kinds


# --- stats --------------------------------------------------------------------

def test_stats_shape(client):
    task_id = client.post("/tasks", json={"title": "one"}).json()["id"]
    client.post(f"/tasks/{task_id}/complete")

    body = client.get("/stats").json()
    assert body["streak_days"] == 1
    assert body["xp"] == 10
    assert body["completed_7d"] == 1
    assert isinstance(body["heatmap"], list)


def test_stats_on_empty_db(client):
    body = client.get("/stats").json()
    assert body["streak_days"] == 0
    assert body["xp"] == 0


# --- parse --------------------------------------------------------------------

def test_parse_extracts_structure(client):
    body = client.post("/parse", json={"raw": "call the dentist tomorrow 3pm #health"}).json()
    assert "dentist" in body["title"].lower()
    assert body["due_at"] is not None
    assert "health" in body["tags"]
    assert body["parsed_by"] == "regex"


def test_parse_relative_time(client):
    body = client.post("/parse", json={"raw": "stretch in 30 minutes"}).json()
    assert body["due_at"] is not None
    assert "stretch" in body["title"].lower()


def test_parse_never_returns_an_empty_title(client):
    body = client.post("/parse", json={"raw": "urgent"}).json()
    assert body["title"].strip()


# --- recurrence through the API ----------------------------------------------

def test_completing_a_recurring_task_rolls_it_forward(client):
    created = client.post("/tasks", json={
        "title": "Daily standup",
        "due_at": "2026-08-12T09:00:00+05:30",
        "recurrence": "FREQ=DAILY",
    }).json()

    body = client.post(f"/tasks/{created['id']}/complete").json()

    # Recurring tasks stay pending and move to the next occurrence.
    assert body["task"]["status"] == "pending"
    assert body["task"]["due_at"] > created["due_at"]


# --- reopen (undo) --------------------------------------------------------------

def test_reopen_undoes_a_completion(client, session):
    task_id = client.post("/tasks", json={"title": "oops"}).json()["id"]
    client.post(f"/tasks/{task_id}/complete")

    body = client.post(f"/tasks/{task_id}/reopen").json()
    assert body["status"] == "pending"
    assert body["completed_at"] is None

    # Ledger keeps BOTH events — append-only, the undo is recorded not erased.
    kinds = [e.kind for e in session.exec(
        select(Event).where(Event.task_id == task_id)).all()]
    assert EventKind.completed in kinds
    assert EventKind.reopened in kinds


def test_reopen_requires_a_done_task(client):
    task_id = client.post("/tasks", json={"title": "still open"}).json()["id"]
    assert client.post(f"/tasks/{task_id}/reopen").status_code == 409


# --- recurring tasks from natural language --------------------------------------

def test_raw_every_month_5th_builds_a_monthly_rule(client):
    body = client.post("/tasks", json={"raw": "pay van fee every month 5th"}).json()
    assert body["recurrence"] == "FREQ=MONTHLY;BYMONTHDAY=5"
    assert "van fee" in body["title"].lower()
    assert "every month" not in body["title"].lower()
    assert body["due_at"] is not None            # first occurrence derived


def test_raw_every_monday_builds_weekly_byday(client):
    body = client.post("/tasks", json={"raw": "team review every monday"}).json()
    assert body["recurrence"] == "FREQ=WEEKLY;BYDAY=MO"


def test_raw_monthly_keyword(client):
    body = client.post("/tasks", json={"raw": "pay rent monthly"}).json()
    assert body["recurrence"] == "FREQ=MONTHLY"


def test_completing_nl_recurring_task_rolls_forward(client):
    created = client.post("/tasks", json={"raw": "water plants every day"}).json()
    assert created["recurrence"] == "FREQ=DAILY"
    done = client.post(f"/tasks/{created['id']}/complete").json()
    assert done["task"]["status"] == "pending"   # rolled, not closed
    assert done["task"]["due_at"] > created["due_at"]


def test_non_recurring_raw_still_plain(client):
    body = client.post("/tasks", json={"raw": "call the dentist tomorrow 3pm"}).json()
    assert body["recurrence"] is None
