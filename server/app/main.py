"""HermesNag API — source of truth, bound to 127.0.0.1 only.

Every route except /health requires a bearer token. Errors are
{"error": {"code", "message"}} with a real HTTP status.
"""

from __future__ import annotations

import asyncio
import os
from collections import defaultdict
from datetime import datetime, timedelta
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, StreamingResponse
from sqlmodel import Session, select

from . import habits, nag, scoring
from .auth import require_token
from .db import get_session, init_db
from .events import broadcaster, sse_format
from .hermes_bridge import HermesUnavailable, hermes_available, parse_natural
from .models import CreatedBy, Event, EventKind, Habit, NagLine, Priority, Status, Task
from .scheduler import escalation_level, is_due, roll_recurrence
from .schemas import (
    AckRequest,
    HabitCreate,
    HabitUpdate,
    NagLinesRequest,
    CompleteResponse,
    ParseRequest,
    SnoozeRequest,
    TaskCreate,
    TaskUpdate,
)
from .timeutil import DISPLAY_TZ, iso, iso_local, now_utc

VERSION = "0.1.0"

app = FastAPI(title="HermesNag", version=VERSION, docs_url=None, redoc_url=None)


@app.on_event("startup")
async def _startup() -> None:
    init_db()
    # Hand the broadcaster the main loop so sync endpoints can publish SSE
    # events from their worker threads (see Broadcaster.publish_soon).
    broadcaster.attach(asyncio.get_running_loop())


# --- error shape --------------------------------------------------------------

@app.exception_handler(HTTPException)
async def http_exception_handler(_request: Request, exc: HTTPException) -> JSONResponse:
    """Normalize to {"error": {code, message}}."""
    detail = exc.detail
    if isinstance(detail, dict) and "code" in detail:
        payload = {"error": detail}
    else:
        payload = {"error": {"code": _code_for(exc.status_code), "message": str(detail)}}
    return JSONResponse(status_code=exc.status_code, content=payload, headers=exc.headers)


@app.exception_handler(ValueError)
async def value_error_handler(_request: Request, exc: ValueError) -> JSONResponse:
    # Naive-datetime rejections land here as a clean 400 rather than a 500.
    return JSONResponse(
        status_code=status.HTTP_400_BAD_REQUEST,
        content={"error": {"code": "invalid_request", "message": str(exc)}},
    )


@app.exception_handler(RequestValidationError)
async def validation_handler(_request: Request, exc: RequestValidationError) -> JSONResponse:
    """Body validation failures use the spec's error shape too.

    Reported as 400: a naive datetime is a malformed request, and pydantic's
    default 422 would also leak its internal error structure to the client.
    """
    errors = exc.errors()
    message = "invalid request body"
    if errors:
        first = errors[0]
        field = ".".join(str(p) for p in first.get("loc", ()) if p != "body")
        raw = str(first.get("msg", message)).removeprefix("Value error, ")
        message = f"{field}: {raw}" if field else raw
    return JSONResponse(
        status_code=status.HTTP_400_BAD_REQUEST,
        content={"error": {"code": "invalid_request", "message": message}},
    )


def _code_for(code: int) -> str:
    return {
        400: "invalid_request", 401: "unauthorized", 404: "not_found",
        409: "conflict", 422: "invalid_request", 500: "internal_error",
    }.get(code, "error")


def _fail(code_str: str, message: str, http: int) -> HTTPException:
    return HTTPException(status_code=http, detail={"code": code_str, "message": message})


# --- serialization ------------------------------------------------------------

def serialize(task: Task, now: datetime | None = None) -> dict[str, Any]:
    now = now or now_utc()
    return {
        "id": task.id,
        "title": task.title,
        "notes": task.notes,
        "due_at": iso(task.due_at),
        "due_at_local": iso_local(task.due_at),
        "recurrence": task.recurrence,
        "priority": task.priority.value,
        "tags": task.tags or [],
        "status": task.status.value,
        "snooze_until": iso(task.snooze_until),
        "escalation_level": escalation_level(task, now),
        "stored_escalation_level": task.escalation_level,
        "ignore_count": task.ignore_count,
        "snooze_count": task.snooze_count,
        "created_by": task.created_by.value,
        "source_ref": task.source_ref,
        "no_escape": task.no_escape,
        "created_at": iso(task.created_at),
        "completed_at": iso(task.completed_at),
    }


def log_event(session: Session, task_id: str | None, kind: EventKind,
              now: datetime, meta: dict | None = None) -> Event:
    """Append to the ledger. Never updated, never deleted."""
    ev = Event(task_id=task_id, kind=kind, at=now, meta=meta or {})
    session.add(ev)
    return ev


def _get_task(session: Session, task_id: str) -> Task:
    task = session.get(Task, task_id)
    if task is None:
        raise _fail("not_found", f"no task with id {task_id}", 404)
    return task


# --- health -------------------------------------------------------------------

@app.get("/health")
def health(session: Session = Depends(get_session)) -> dict[str, Any]:
    """The only unauthenticated route."""
    try:
        session.exec(select(Task).limit(1)).first()
        db_ok = True
    except Exception:
        db_ok = False
    return {
        "ok": db_ok,
        "version": VERSION,
        "db_ok": db_ok,
        "hermes_ok": hermes_available(),
        "now_utc": iso(now_utc()),
        "sse_subscribers": broadcaster.subscriber_count,
    }


# --- tasks --------------------------------------------------------------------

@app.get("/tasks", dependencies=[Depends(require_token)])
def list_tasks(
    status_filter: str | None = None,
    due_before: datetime | None = None,
    limit: int = 200,
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    from .timeutil import ensure_utc

    stmt = select(Task)
    if status_filter:
        try:
            stmt = stmt.where(Task.status == Status(status_filter))
        except ValueError:
            raise _fail("invalid_request", f"unknown status {status_filter!r}", 400)
    if due_before is not None:
        stmt = stmt.where(Task.due_at <= ensure_utc(due_before))

    stmt = stmt.order_by(Task.due_at.is_(None), Task.due_at).limit(min(limit, 1000))
    now = now_utc()
    return {"tasks": [serialize(t, now) for t in session.exec(stmt).all()]}


@app.post("/tasks", dependencies=[Depends(require_token)], status_code=201)
def create_task(body: TaskCreate, session: Session = Depends(get_session)) -> dict[str, Any]:
    now = now_utc()

    title, due_at, priority, tags = body.title, body.due_at, body.priority, list(body.tags)

    # `raw` is the quick-capture path: parse, but never override explicit fields.
    recurrence = body.recurrence
    if body.raw and not title:
        parsed = parse_natural(body.raw)
        title = parsed["title"]
        due_at = due_at or parsed["due_at"]
        if body.priority == Priority.normal:
            priority = Priority(parsed["priority"])
        tags = tags or parsed["tags"]
        recurrence = recurrence or parsed.get("recurrence")

    # A recurring task with no explicit time gets its first occurrence
    # computed from the rule (evaluated in UTC; 09:00 IST default anchor).
    if recurrence and due_at is None:
        from dateutil import rrule as rrule_mod
        anchor = now.astimezone(DISPLAY_TZ).replace(
            hour=9, minute=0, second=0, microsecond=0).astimezone(now.tzinfo)
        try:
            rule = rrule_mod.rrulestr(recurrence.removeprefix("RRULE:"),
                                      dtstart=anchor.replace(tzinfo=None))
            nxt = rule.after(now.replace(tzinfo=None), inc=True)
            if nxt is not None:
                due_at = nxt.replace(tzinfo=now.tzinfo)
        except (ValueError, TypeError):
            pass  # bad rule -> plain one-off task

    if not title:
        raise _fail("invalid_request", "either `title` or `raw` is required", 400)

    task = Task(
        title=title, notes=body.notes, due_at=due_at, recurrence=recurrence,
        priority=priority, tags=tags, created_by=body.created_by,
        source_ref=body.source_ref, no_escape=body.no_escape, created_at=now,
    )
    session.add(task)
    # Flush before logging: the event FK references task.id, which doesn't
    # exist in the DB until the insert lands.
    session.flush()
    log_event(session, task.id, EventKind.created, now,
              {"created_by": body.created_by.value, "raw": body.raw})
    session.commit()
    session.refresh(task)

    payload = serialize(task, now)
    broadcaster.publish_soon("task.created", payload)
    return payload


@app.get("/tasks/{task_id}", dependencies=[Depends(require_token)])
def get_task(task_id: str, session: Session = Depends(get_session)) -> dict[str, Any]:
    return serialize(_get_task(session, task_id))


@app.patch("/tasks/{task_id}", dependencies=[Depends(require_token)])
def patch_task(task_id: str, body: TaskUpdate,
               session: Session = Depends(get_session)) -> dict[str, Any]:
    task = _get_task(session, task_id)
    now = now_utc()

    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(task, field, value)

    session.add(task)
    session.commit()
    session.refresh(task)

    payload = serialize(task, now)
    broadcaster.publish_soon("task.changed", payload)
    return payload


# --- actions ------------------------------------------------------------------

def _streak_and_xp(session: Session, now: datetime) -> tuple[int, int]:
    """Streak = consecutive days (IST) with >=1 completion, counting back from today."""
    events = session.exec(
        select(Event).where(Event.kind == EventKind.completed)
    ).all()

    xp = len(events) * 10
    days = {e.at.astimezone(DISPLAY_TZ).date() for e in events}
    if not days:
        return 0, xp

    today = now.astimezone(DISPLAY_TZ).date()
    # Today not yet counted shouldn't break a streak earned yesterday.
    cursor = today if today in days else today - timedelta(days=1)
    streak = 0
    while cursor in days:
        streak += 1
        cursor -= timedelta(days=1)
    return streak, xp


@app.post("/tasks/{task_id}/complete", dependencies=[Depends(require_token)],
          response_model=CompleteResponse)
def complete_task(task_id: str, session: Session = Depends(get_session)) -> dict[str, Any]:
    task = _get_task(session, task_id)
    now = now_utc()

    if task.status == Status.done:
        raise _fail("conflict", "task is already done", 409)

    log_event(session, task.id, EventKind.completed, now,
              {"was_level": escalation_level(task, now)})

    # A recurring task rolls forward instead of closing.
    rolled = roll_recurrence(task, now)
    if not rolled:
        task.status = Status.done
        task.completed_at = now
        task.escalation_level = 0

    session.add(task)
    session.commit()
    session.refresh(task)

    streak, xp = _streak_and_xp(session, now)
    mood = "ecstatic" if streak >= 7 else "happy" if streak >= 3 else "pleased"

    payload = serialize(task, now)
    broadcaster.publish_soon("task.changed", payload)
    return {"task": payload, "xp_awarded": 10, "streak": streak, "mascot_mood": mood}


@app.post("/tasks/{task_id}/reopen", dependencies=[Depends(require_token)])
def reopen_task(task_id: str, session: Session = Depends(get_session)) -> dict[str, Any]:
    """Undo a completion. The completion event stays in the ledger (append-
    only); a `reopened` event records the reversal rather than erasing it."""
    task = _get_task(session, task_id)
    now = now_utc()

    if task.status != Status.done:
        raise _fail("conflict", "task is not done", 409)

    task.status = Status.pending
    task.completed_at = None
    log_event(session, task.id, EventKind.reopened, now)
    session.add(task)
    session.commit()
    session.refresh(task)

    payload = serialize(task, now)
    broadcaster.publish_soon("task.changed", payload)
    return payload


@app.post("/tasks/{task_id}/snooze", dependencies=[Depends(require_token)])
def snooze_task(task_id: str, body: SnoozeRequest,
                session: Session = Depends(get_session)) -> dict[str, Any]:
    task = _get_task(session, task_id)
    now = now_utc()

    if body.until is not None:
        until = body.until
    elif body.minutes is not None:
        if body.minutes <= 0:
            raise _fail("invalid_request", "minutes must be positive", 400)
        until = now + timedelta(minutes=body.minutes)
    else:
        raise _fail("invalid_request", "provide either `minutes` or `until`", 400)

    task.status = Status.snoozed
    task.snooze_until = until
    task.snooze_count += 1

    log_event(session, task.id, EventKind.snoozed, now,
              {"until": iso(until), "snooze_count": task.snooze_count})
    session.add(task)
    session.commit()
    session.refresh(task)

    payload = serialize(task, now)
    broadcaster.publish_soon("task.changed", payload)
    return payload


@app.post("/tasks/{task_id}/drop", dependencies=[Depends(require_token)])
def drop_task(task_id: str, session: Session = Depends(get_session)) -> dict[str, Any]:
    """'Not today'. A status change — never a DELETE."""
    task = _get_task(session, task_id)
    now = now_utc()

    task.status = Status.dropped
    task.escalation_level = 0

    log_event(session, task.id, EventKind.dropped, now)
    session.add(task)
    session.commit()
    session.refresh(task)

    payload = serialize(task, now)
    broadcaster.publish_soon("task.changed", payload)
    return payload


@app.post("/tasks/{task_id}/ack", dependencies=[Depends(require_token)])
def ack_task(task_id: str, body: AckRequest,
             session: Session = Depends(get_session)) -> dict[str, Any]:
    """Client reports what it actually displayed.

    'ignored' is what drives escalation, so the ladder reflects real popups
    rather than what the server merely intended to show.
    """
    task = _get_task(session, task_id)
    now = now_utc()

    if body.action not in ("shown", "ignored"):
        raise _fail("invalid_request", "action must be 'shown' or 'ignored'", 400)

    if body.action == "ignored":
        task.ignore_count += 1
        log_event(session, task.id, EventKind.ignored, now, {"level": body.level})
    else:
        log_event(session, task.id, EventKind.shown, now, {"level": body.level})

    new_level = escalation_level(task, now)
    if new_level != task.escalation_level:
        log_event(session, task.id, EventKind.escalated, now,
                  {"from": task.escalation_level, "to": new_level})
        task.escalation_level = new_level

    session.add(task)
    session.commit()
    session.refresh(task)
    return serialize(task, now)


# --- due / stats --------------------------------------------------------------

@app.get("/due", dependencies=[Depends(require_token)])
def get_due(session: Session = Depends(get_session)) -> dict[str, Any]:
    """Tasks that should fire right now, each with its nag line and level."""
    now = now_utc()
    candidates = session.exec(
        select(Task).where(Task.status.in_([Status.pending, Status.snoozed]))
    ).all()

    out = []
    for task in candidates:
        if not is_due(task, now):
            continue
        level = escalation_level(task, now)
        line = nag.take_line(session, task.id, level, task.title, now)
        item = serialize(task, now)
        item["nag_line"] = line
        item["level"] = level
        out.append(item)

    session.commit()  # persist used_at marks
    out.sort(key=lambda t: (-t["level"], t["due_at"] or ""))
    return {"due": out, "count": len(out), "now_utc": iso(now)}


@app.get("/stats", dependencies=[Depends(require_token)])
def get_stats(session: Session = Depends(get_session)) -> dict[str, Any]:
    now = now_utc()
    streak, xp = _streak_and_xp(session, now)

    completed = session.exec(select(Event).where(Event.kind == EventKind.completed)).all()
    today_local = now.astimezone(DISPLAY_TZ).date()

    completed_7d = sum(
        1 for e in completed
        if (today_local - e.at.astimezone(DISPLAY_TZ).date()).days < 7
    )

    heat: dict[str, int] = defaultdict(int)
    for e in completed:
        d = e.at.astimezone(DISPLAY_TZ).date()
        if (today_local - d).days < 365:
            heat[d.isoformat()] += 1

    shown = len(session.exec(select(Event).where(Event.kind == EventKind.shown)).all())
    ignored = len(session.exec(select(Event).where(Event.kind == EventKind.ignored)).all())
    denom = shown + ignored
    rate = round(len(completed) / denom, 3) if denom else None

    # Game layer: replay the ledger (append-only, so this is exact and
    # retroactive; nothing stored, nothing to drift).
    all_events = session.exec(select(Event)).all()
    tasks_by_id = {t.id: t for t in session.exec(select(Task)).all()}
    card = scoring.compute(all_events, tasks_by_id, now)

    return {
        "streak_days": streak,
        "xp": xp,
        "xp_level": xp // 100,
        "completed_7d": completed_7d,
        "completion_rate": rate,
        "heatmap": [{"date": d, "count": c} for d, c in sorted(heat.items())],
        "points_total": card.total,
        "points_today": card.today,
        "points_week": card.week,
        "level": card.level,
        "level_name": card.level_name,
        "next_level_at": card.next_level_at,
        "level_progress": card.progress,
        "perfect_days": card.perfect_days,
        "achievements": card.achievements,
        "points_by_day": [
            {"date": d, "points": p} for d, p in sorted(card.by_day.items())[-14:]
        ],
    }


# --- SSE ----------------------------------------------------------------------

@app.get("/events", dependencies=[Depends(require_token)])
async def sse_events(request: Request) -> StreamingResponse:
    """Primary push channel. Heartbeats keep the SSH tunnel from idling out."""
    queue = await broadcaster.subscribe()

    async def stream():
        try:
            yield sse_format("hello", {"version": VERSION, "now_utc": iso(now_utc())})
            while True:
                if await request.is_disconnected():
                    break
                try:
                    payload = await asyncio.wait_for(queue.get(), timeout=15.0)
                    yield sse_format(payload["event"], payload["data"])
                except asyncio.TimeoutError:
                    yield ": heartbeat\n\n"
        finally:
            await broadcaster.unsubscribe(queue)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                 "X-Accel-Buffering": "no"},
    )


# --- parse --------------------------------------------------------------------

# --- mobile web widget ----------------------------------------------------------

@app.get("/m/icon.png", include_in_schema=False)
def mobile_icon() -> "FileResponse":
    """Home-screen icon — the same 'Nagging' artwork as the Mac Dock."""
    from pathlib import Path
    return FileResponse(Path(__file__).parent / "static" / "apple-touch-icon.png",
                        media_type="image/png")


@app.get("/m", include_in_schema=False)
def mobile_page() -> "HTMLResponse":
    """The iPhone page. Unauthenticated shell — every data call it makes
    carries the bearer token — and reachable only inside the tailnet via
    `tailscale serve`, so the localhost binding is unchanged."""
    from .mobile import MOBILE_HTML
    return HTMLResponse(MOBILE_HTML)


# --- habits (recurring nudges) ------------------------------------------------

def serialize_habit(habit: Habit, now: datetime, presence: habits.Presence) -> dict[str, Any]:
    return {
        "id": habit.id,
        "name": habit.name,
        "interval_minutes": habit.interval_minutes,
        "active_hours": [habit.active_from_hour, habit.active_to_hour],
        "requires_presence": habit.requires_presence,
        "presence_minutes": habit.presence_minutes,
        "escalates": habit.escalates,
        "enabled": habit.enabled,
        "streak": habit.streak,
        "last_done_at": iso(habit.last_done_at),
        "next_due_at": iso(habits.next_due(habit, now)),
        "seconds_until_due": habits.seconds_until_due(habit, now),
        "is_due": habits.is_due(habit, now, presence),
        "level": habits.escalation_level(habit, now, presence),
        "in_active_hours": habits.in_active_hours(habit, now),
    }


def _presence_from_query(active: bool, continuous_minutes: int,
                         screen_locked: bool) -> habits.Presence:
    return habits.Presence(active=active, continuous_minutes=continuous_minutes,
                           screen_locked=screen_locked)


@app.get("/habits", dependencies=[Depends(require_token)])
def list_habits(active: bool = True, continuous_minutes: int = 0,
                screen_locked: bool = False,
                session: Session = Depends(get_session)) -> dict[str, Any]:
    """All habits with their live due state.

    Presence comes from the client as query params: only the Mac knows whether
    the user is actually at the machine.
    """
    now = now_utc()
    presence = _presence_from_query(active, continuous_minutes, screen_locked)
    rows = session.exec(select(Habit).order_by(Habit.interval_minutes)).all()
    return {"habits": [serialize_habit(h, now, presence) for h in rows]}


@app.get("/habits/due", dependencies=[Depends(require_token)])
def habits_due(active: bool = True, continuous_minutes: int = 0,
               screen_locked: bool = False,
               session: Session = Depends(get_session)) -> dict[str, Any]:
    """Habits that should nudge right now, with their nag line."""
    now = now_utc()
    presence = _presence_from_query(active, continuous_minutes, screen_locked)

    out = []
    for habit in session.exec(select(Habit)).all():
        if not habits.is_due(habit, now, presence):
            continue
        level = habits.escalation_level(habit, now, presence)
        item = serialize_habit(habit, now, presence)
        # Generic pool only (task_id=None): nag_line.task_id is a foreign key
        # into `task`, and a habit id would violate it.
        item["nag_line"] = nag.take_line(session, None, level, habit.name, now)
        out.append(item)

    session.commit()
    return {"due": out, "count": len(out)}


@app.post("/habits/{habit_id}/done", dependencies=[Depends(require_token)])
def complete_habit(habit_id: str, session: Session = Depends(get_session)) -> dict[str, Any]:
    """Acknowledge a habit — resets its interval and bumps the streak."""
    habit = session.get(Habit, habit_id)
    if habit is None:
        raise _fail("not_found", f"no habit with id {habit_id}", 404)

    now = now_utc()
    # Same-interval double-taps shouldn't inflate the streak.
    if habit.last_done_at is None or (now - habit.last_done_at) > timedelta(minutes=1):
        habit.streak += 1
    habit.last_done_at = now

    log_event(session, None, EventKind.completed, now,
              {"habit_id": habit.id, "habit": habit.name})
    session.add(habit)
    session.commit()
    session.refresh(habit)

    return serialize_habit(habit, now, habits.Presence())


@app.post("/habits/{habit_id}/fired", dependencies=[Depends(require_token)])
def habit_fired(habit_id: str, session: Session = Depends(get_session)) -> dict[str, Any]:
    """Client reports it showed this nudge — prevents immediate re-firing."""
    habit = session.get(Habit, habit_id)
    if habit is None:
        raise _fail("not_found", f"no habit with id {habit_id}", 404)

    now = now_utc()
    habit.last_fired_at = now
    log_event(session, None, EventKind.shown, now,
              {"habit_id": habit.id, "habit": habit.name})
    session.add(habit)
    session.commit()
    session.refresh(habit)
    return serialize_habit(habit, now, habits.Presence())


def _parse_habit_raw(raw: str) -> dict[str, Any]:
    """'meditate daily' / 'journal every 90m' / 'walk every 2h' → fields."""
    import re

    text = raw.strip()
    fields: dict[str, Any] = {"interval_minutes": 24 * 60}  # default daily

    m = re.search(r"\bevery\s+(\d+)\s*(m|min|mins|minutes|h|hr|hrs|hours)\b", text, re.I)
    if m:
        n, unit = int(m.group(1)), m.group(2).lower()
        fields["interval_minutes"] = n * (60 if unit.startswith("h") else 1)
        text = text[:m.start()] + text[m.end():]
    elif re.search(r"\bdaily\b", text, re.I):
        text = re.sub(r"\bdaily\b", "", text, flags=re.I)

    fields["name"] = re.sub(r"\s{2,}", " ", text).strip(" ,.-:;") or raw.strip()
    return fields


@app.post("/habits", dependencies=[Depends(require_token)], status_code=201)
def create_habit(body: HabitCreate, session: Session = Depends(get_session)) -> dict[str, Any]:
    """Create a user habit — the brief's 'create and track simple daily habits'."""
    now = now_utc()

    name, interval = body.name, body.interval_minutes
    if body.raw and not name:
        parsed = _parse_habit_raw(body.raw)
        name = parsed["name"]
        interval = interval or parsed["interval_minutes"]

    if not name:
        raise _fail("invalid_request", "either `name` or `raw` is required", 400)
    if body.daily:
        interval = 24 * 60
    if not interval or interval < 5:
        interval = 24 * 60  # default: a daily habit; <5m would be spam

    existing = session.exec(select(Habit).where(Habit.name == name)).first()
    if existing is not None:
        raise _fail("conflict", f"habit {name!r} already exists", 409)

    habit = Habit(
        name=name, interval_minutes=interval,
        active_from_hour=body.active_from_hour, active_to_hour=body.active_to_hour,
        requires_presence=body.requires_presence, presence_minutes=body.presence_minutes,
        escalates=body.escalates, created_at=now,
    )
    session.add(habit)
    log_event(session, None, EventKind.created, now, {"habit": name, "interval": interval})
    session.commit()
    session.refresh(habit)

    payload = serialize_habit(habit, now, habits.Presence())
    broadcaster.publish_soon("habit.changed", payload)
    return payload


@app.patch("/habits/{habit_id}", dependencies=[Depends(require_token)])
def update_habit(habit_id: str, body: HabitUpdate,
                 session: Session = Depends(get_session)) -> dict[str, Any]:
    """Edit or disable. Never a DELETE — history stays in the ledger."""
    habit = session.get(Habit, habit_id)
    if habit is None:
        raise _fail("not_found", f"no habit with id {habit_id}", 404)

    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(habit, field, value)

    session.add(habit)
    session.commit()
    session.refresh(habit)

    payload = serialize_habit(habit, now_utc(), habits.Presence())
    broadcaster.publish_soon("habit.changed", payload)
    return payload


@app.post("/habits/seed", dependencies=[Depends(require_token)], status_code=201)
def seed_habits(session: Session = Depends(get_session)) -> dict[str, Any]:
    """Create the default habit set. Idempotent — skips ones already present."""
    now = now_utc()
    created = []
    for spec in habits.DEFAULT_HABITS:
        existing = session.exec(select(Habit).where(Habit.name == spec["name"])).first()
        if existing is not None:
            continue
        habit = Habit(created_at=now, **spec)
        session.add(habit)
        created.append(spec["name"])
    session.commit()
    return {"created": created, "count": len(created)}


@app.post("/nag-lines", dependencies=[Depends(require_token)], status_code=201)
def add_nag_lines(body: NagLinesRequest,
                  session: Session = Depends(get_session)) -> dict[str, Any]:
    """Store pre-generated nag copy (M5 — written by Hermes via MCP).

    The reminder path reads from this pool. Hermes takes 14-17s per call, so
    lines must exist *before* a task is due — never generated on demand.
    """
    now = now_utc()
    if body.level not in (1, 2, 3):
        raise _fail("invalid_request", "level must be 1, 2 or 3", 400)

    if body.task_id is not None and session.get(Task, body.task_id) is None:
        raise _fail("not_found", f"no task with id {body.task_id}", 404)

    stored = 0
    for text in body.lines:
        text = text.strip()
        if not text:
            continue
        session.add(NagLine(task_id=body.task_id, level=body.level,
                            text=text, created_at=now))
        stored += 1

    session.commit()
    return {"stored": stored, "level": body.level,
            "pool_depth": nag.pool_depth(session, body.level)}


@app.get("/nag-lines/depth", dependencies=[Depends(require_token)])
def nag_line_depth(session: Session = Depends(get_session)) -> dict[str, Any]:
    """Unused lines per level — drives the top-up cron job."""
    return {
        "total": nag.pool_depth(session),
        "by_level": {str(level): nag.pool_depth(session, level) for level in (1, 2, 3)},
    }


@app.post("/parse", dependencies=[Depends(require_token)])
def parse(body: ParseRequest) -> dict[str, Any]:
    """Natural language -> structured task.

    Regex-first: it's instant and good enough for quick capture. Hermes is
    14-17s, which would make the global-hotkey capture feel broken.
    """
    parsed = parse_natural(body.raw)
    return {
        "title": parsed["title"],
        "due_at": iso(parsed["due_at"]),
        "priority": parsed["priority"],
        "tags": parsed["tags"],
        "parsed_by": "regex",
    }


def main() -> None:
    import uvicorn

    uvicorn.run(
        app,
        host=os.getenv("HERMESNAG_HOST", "127.0.0.1"),  # never 0.0.0.0
        port=int(os.getenv("HERMESNAG_PORT", "8787")),
        log_level="info",
    )


if __name__ == "__main__":
    main()
