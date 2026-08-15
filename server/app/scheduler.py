"""Due detection, escalation policy, and recurrence.

Every function here is pure: `now` is passed in, never read from the clock.
That's what lets the tests cover time-based behaviour without sleeping
(spec Rule 3 — any test over 2s is a design smell).

The server computes the *authoritative* escalation level; the Mac client
enforces presentation and safety valves (screen capture, Focus, lock state),
which it can only judge locally.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from dateutil import rrule as rrule_mod

from .models import Priority, Status, Task

# Spec's ladder thresholds.
L0_LEAD = timedelta(minutes=15)   # ambient: due within 15 min
L2_OVERDUE = timedelta(minutes=30)
L3_OVERDUE = timedelta(hours=2)


def is_due(task: Task, now: datetime) -> bool:
    """Should this task be firing right now?"""
    if task.status in (Status.done, Status.dropped):
        return False
    if task.due_at is None:
        return False
    if task.status == Status.snoozed and task.snooze_until is not None:
        if now < task.snooze_until:
            return False
    return now >= task.due_at


def is_ambient(task: Task, now: datetime) -> bool:
    """L0: approaching, not yet due."""
    if task.status in (Status.done, Status.dropped) or task.due_at is None:
        return False
    if is_due(task, now):
        return False
    return (task.due_at - now) <= L0_LEAD


def escalation_level(task: Task, now: datetime) -> int:
    """Authoritative level 0–3 for a task at time `now`.

    L3 is deliberately hard to reach: `must` priority only (or an explicit
    no_escape flag). Any other priority tops out at L2 no matter how long
    it's been ignored — a low-priority task must never take over the screen.
    """
    if not is_due(task, now):
        return 0 if is_ambient(task, now) else 0

    overdue = now - task.due_at if task.due_at else timedelta(0)

    # --- L3: takeover ---
    if task.priority == Priority.must or task.no_escape:
        if task.no_escape or task.ignore_count >= 3 or overdue >= L3_OVERDUE:
            return 3

    # --- L2: annoyed ---
    if task.ignore_count >= 1 or task.snooze_count >= 2 or overdue >= L2_OVERDUE:
        return 2

    # --- L1: due, playful ---
    return 1


def next_occurrence(task: Task, after: datetime) -> datetime | None:
    """Next due instant for a recurring task, or None if it doesn't recur.

    RRULE is evaluated in UTC. dateutil needs a naive dtstart to avoid mixing
    aware/naive internally, so we strip tzinfo going in and re-attach it on the
    way out — the value stays UTC throughout.
    """
    if not task.recurrence or task.due_at is None:
        return None

    text = task.recurrence.strip()
    if text.upper().startswith("RRULE:"):
        text = text[6:]

    dtstart_naive = task.due_at.astimezone(after.tzinfo).replace(tzinfo=None)
    after_naive = after.replace(tzinfo=None)

    try:
        rule = rrule_mod.rrulestr(text, dtstart=dtstart_naive)
    except (ValueError, TypeError):
        return None  # malformed RRULE: treat as non-recurring, don't crash the tick

    nxt = rule.after(after_naive, inc=False)
    if nxt is None:
        return None
    return nxt.replace(tzinfo=after.tzinfo)


def roll_recurrence(task: Task, now: datetime) -> bool:
    """On completion, advance a recurring task instead of closing it.

    Returns True if the task was rolled forward (and so stays pending).
    """
    # Anchor past the occurrence being completed: finishing tomorrow's
    # occurrence early must advance to the one after, not re-offer the same
    # date and invite a double-complete.
    anchor = max(now, task.due_at) if task.due_at else now
    nxt = next_occurrence(task, anchor)
    if nxt is None:
        return False

    task.due_at = nxt
    task.status = Status.pending
    task.completed_at = None
    task.escalation_level = 0
    task.ignore_count = 0
    task.snooze_count = 0
    task.snooze_until = None
    return True
