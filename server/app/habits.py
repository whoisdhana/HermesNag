"""Habit scheduling — recurring nudges rather than deadline tasks.

Pure functions of (habit, now, presence). No clock reads, no I/O, so every
firing rule is testable in microseconds (spec Rule 3).

Two things keep this from becoming noise:
  * an active-hours window, so nothing fires overnight
  * an optional presence requirement, so "stand up" only fires when you have
    actually been sitting there
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

from .models import Habit
from .timeutil import DISPLAY_TZ


@dataclass(frozen=True)
class Presence:
    """What the Mac reported about laptop use."""

    active: bool = True
    # Continuous minutes of use, reset by a long idle gap.
    continuous_minutes: int = 0
    screen_locked: bool = False

    @property
    def usable(self) -> bool:
        return self.active and not self.screen_locked


def in_active_hours(habit: Habit, now: datetime) -> bool:
    """Is `now` inside the habit's local active window?

    Hours are the user's (IST), not UTC — a 9-21 window has to mean 9am-9pm
    where the user is, or it drifts by 5h30m.
    """
    local_hour = now.astimezone(DISPLAY_TZ).hour

    if habit.active_from_hour <= habit.active_to_hour:
        return habit.active_from_hour <= local_hour < habit.active_to_hour
    # Window crossing midnight, e.g. 22 -> 6.
    return local_hour >= habit.active_from_hour or local_hour < habit.active_to_hour


def next_due(habit: Habit, now: datetime) -> datetime:
    """When this habit should next fire.

    Anchor on the LATER of completion/fire. The old `last_done_at or
    last_fired_at` preferred the completion even when the fire was newer —
    so once a habit had ever been done, a shown nudge no longer deferred it,
    the habit stayed permanently due, and the client re-notified every few
    minutes. Declining to tap Done means "next cycle", not "machine-gun me".
    """
    candidates = [t for t in (habit.last_done_at, habit.last_fired_at) if t is not None]
    if not candidates:
        return now
    return max(candidates) + timedelta(minutes=habit.interval_minutes)


def is_due(habit: Habit, now: datetime, presence: Presence | None = None) -> bool:
    """Should this habit fire right now?"""
    if not habit.enabled:
        return False
    if not in_active_hours(habit, now):
        return False

    presence = presence or Presence()
    if habit.requires_presence:
        if not presence.usable:
            return False
        if presence.continuous_minutes < habit.presence_minutes:
            return False

    return now >= next_due(habit, now)


def overdue_minutes(habit: Habit, now: datetime) -> int:
    due = next_due(habit, now)
    if now < due:
        return 0
    return int((now - due).total_seconds() // 60)


def escalation_level(habit: Habit, now: datetime, presence: Presence | None = None) -> int:
    """0-3 for a habit.

    Gentler than the task ladder by design: a habit fires many times a day, so
    it must stay dismissible. Only a habit explicitly marked `escalates` climbs
    past L1, and it tops out at L2 — a water reminder must never take over the
    screen, however long it's ignored.
    """
    if not is_due(habit, now, presence):
        return 0
    if not habit.escalates:
        return 1

    late = overdue_minutes(habit, now)
    # Half an interval late means it's been actively ignored.
    if late >= max(10, habit.interval_minutes // 2):
        return 2
    return 1


def seconds_until_due(habit: Habit, now: datetime) -> int:
    """For the widget's countdown."""
    delta = (next_due(habit, now) - now).total_seconds()
    return max(0, int(delta))


DEFAULT_HABITS = [
    {
        "name": "Drink water",
        "interval_minutes": 45,
        "active_from_hour": 8,
        "active_to_hour": 22,
        "requires_presence": False,
        "escalates": True,
    },
    {
        "name": "Stand up and stretch",
        "interval_minutes": 50,
        "active_from_hour": 8,
        "active_to_hour": 22,
        # Only after 45 continuous minutes at the machine — the whole point is
        # that you've been sitting, not that 50 minutes elapsed.
        "requires_presence": True,
        "presence_minutes": 45,
        "escalates": True,
    },
    {
        "name": "Rest your eyes (20-20-20)",
        "interval_minutes": 20,
        "active_from_hour": 8,
        "active_to_hour": 22,
        "requires_presence": True,
        "presence_minutes": 18,
        # Fires ~30x a day. Escalating that would be intolerable.
        "escalates": False,
    },
    {
        "name": "Daily wrap-up",
        "interval_minutes": 24 * 60,
        "active_from_hour": 20,
        "active_to_hour": 22,
        "requires_presence": False,
        "escalates": False,
    },
]
