"""Escalation ladder and recurrence.

`now` is injected everywhere — no sleeps (spec Rule 3). The whole file runs
in milliseconds because time is a parameter, not a thing we wait for.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.models import Priority, Status, Task
from app.scheduler import (
    escalation_level,
    is_ambient,
    is_due,
    next_occurrence,
    roll_recurrence,
)

UTC = timezone.utc
T0 = datetime(2026, 8, 12, 12, 0, 0, tzinfo=UTC)  # fixed reference instant


def task(**kw) -> Task:
    base = dict(title="test task", due_at=T0, priority=Priority.normal, status=Status.pending)
    base.update(kw)
    return Task(**base)


# --- due detection ------------------------------------------------------------

def test_not_due_before_due_at():
    assert is_due(task(), T0 - timedelta(seconds=1)) is False


def test_due_exactly_at_due_at():
    assert is_due(task(), T0) is True


def test_task_with_no_due_date_never_fires():
    assert is_due(task(due_at=None), T0) is False


def test_done_and_dropped_never_fire():
    assert is_due(task(status=Status.done), T0 + timedelta(hours=5)) is False
    assert is_due(task(status=Status.dropped), T0 + timedelta(hours=5)) is False


def test_snoozed_task_is_suppressed_until_snooze_expires():
    t = task(status=Status.snoozed, snooze_until=T0 + timedelta(minutes=10))
    assert is_due(t, T0 + timedelta(minutes=5)) is False
    assert is_due(t, T0 + timedelta(minutes=11)) is True


# --- L0 ambient ---------------------------------------------------------------

def test_ambient_within_15_minutes():
    assert is_ambient(task(), T0 - timedelta(minutes=10)) is True


def test_not_ambient_before_the_15_minute_window():
    assert is_ambient(task(), T0 - timedelta(minutes=20)) is False


def test_not_ambient_once_actually_due():
    assert is_ambient(task(), T0) is False


# --- L1 ---------------------------------------------------------------------

def test_l1_when_freshly_due_and_untouched():
    assert escalation_level(task(), T0) == 1


def test_level_0_before_due():
    assert escalation_level(task(), T0 - timedelta(minutes=5)) == 0


# --- L2 ---------------------------------------------------------------------

def test_l2_after_one_ignore():
    assert escalation_level(task(ignore_count=1), T0) == 2


def test_l2_after_two_snoozes():
    assert escalation_level(task(snooze_count=2), T0) == 2


def test_l2_when_30_minutes_overdue():
    assert escalation_level(task(), T0 + timedelta(minutes=30)) == 2


def test_still_l1_at_29_minutes_overdue():
    assert escalation_level(task(), T0 + timedelta(minutes=29)) == 1


# --- L3: the dangerous one ----------------------------------------------------

def test_l3_requires_must_priority_even_when_heavily_ignored():
    """A normal task must never take over the screen, however ignored."""
    t = task(priority=Priority.normal, ignore_count=99)
    assert escalation_level(t, T0 + timedelta(hours=48)) == 2


def test_l3_for_must_after_three_ignores():
    t = task(priority=Priority.must, ignore_count=3)
    assert escalation_level(t, T0) == 3


def test_l3_for_must_after_two_hours_overdue():
    t = task(priority=Priority.must)
    assert escalation_level(t, T0 + timedelta(hours=2)) == 3


def test_must_is_only_l2_at_one_hour_overdue_with_no_ignores():
    t = task(priority=Priority.must)
    assert escalation_level(t, T0 + timedelta(hours=1)) == 2


def test_no_escape_flag_forces_l3_immediately():
    t = task(priority=Priority.normal, no_escape=True)
    assert escalation_level(t, T0) == 3


def test_high_priority_still_cannot_reach_l3():
    t = task(priority=Priority.high, ignore_count=10)
    assert escalation_level(t, T0 + timedelta(hours=6)) == 2


# --- recurrence ---------------------------------------------------------------

def test_daily_recurrence_advances_one_day():
    t = task(recurrence="FREQ=DAILY")
    assert next_occurrence(t, T0) == T0 + timedelta(days=1)


def test_rrule_prefix_is_tolerated():
    t = task(recurrence="RRULE:FREQ=DAILY")
    assert next_occurrence(t, T0) == T0 + timedelta(days=1)


def test_weekly_recurrence_advances_seven_days():
    t = task(recurrence="FREQ=WEEKLY")
    assert next_occurrence(t, T0) == T0 + timedelta(days=7)


def test_non_recurring_task_has_no_next_occurrence():
    assert next_occurrence(task(), T0) is None


def test_malformed_rrule_degrades_instead_of_crashing():
    """A bad RRULE must not take down the whole due-detection tick."""
    assert next_occurrence(task(recurrence="TOTAL NONSENSE"), T0) is None


def test_completing_a_recurring_task_rolls_it_forward():
    t = task(recurrence="FREQ=DAILY", ignore_count=5, snooze_count=2)
    assert roll_recurrence(t, T0 + timedelta(minutes=5)) is True
    assert t.due_at == T0 + timedelta(days=1)
    assert t.status == Status.pending
    assert t.ignore_count == 0 and t.snooze_count == 0  # counters reset per occurrence


def test_completing_a_one_off_task_does_not_roll():
    assert roll_recurrence(task(), T0) is False
