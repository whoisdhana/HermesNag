"""Scoring replay — pure, injected clock, no penalties by design."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.models import Event, EventKind, Priority, Task
from app.scoring import (EARLY_BONUS, HABIT_DONE, MUST_BONUS, PERFECT_DAY,
                         STREAK_PER_DAY, TASK_BASE, compute)

UTC = timezone.utc
T0 = datetime(2026, 8, 13, 7, 0, tzinfo=UTC)  # 12:30 IST


def ev(kind, at, task_id=None, **meta):
    return Event(kind=kind, at=at, task_id=task_id, meta=meta or {})


def task(tid="t1", priority=Priority.normal, due=None):
    return Task(id=tid, title="t", priority=priority, due_at=due)


def test_task_completion_scores_base_plus_streak():
    card = compute([ev(EventKind.completed, T0, "t1")], {"t1": task()}, T0)
    assert card.today == TASK_BASE + STREAK_PER_DAY  # day 1 of a streak


def test_must_and_early_bonuses_stack():
    t = task(priority=Priority.must, due=T0 + timedelta(hours=2))
    card = compute([ev(EventKind.completed, T0, "t1")], {"t1": t}, T0)
    assert card.today == TASK_BASE + MUST_BONUS + EARLY_BONUS + STREAK_PER_DAY


def test_late_completion_gets_no_early_bonus_but_no_penalty():
    t = task(due=T0 - timedelta(hours=3))
    card = compute([ev(EventKind.completed, T0, "t1")], {"t1": t}, T0)
    assert card.today == TASK_BASE + STREAK_PER_DAY


def test_undo_takes_back_exactly_what_was_given():
    t = task(priority=Priority.must, due=T0 + timedelta(hours=1))
    events = [ev(EventKind.completed, T0, "t1"),
              ev(EventKind.reopened, T0 + timedelta(minutes=1), "t1")]
    card = compute(events, {"t1": t}, T0)
    # Only the streak day-bonus remains (a task WAS completed that day).
    assert card.today == STREAK_PER_DAY


def test_ignores_and_snoozes_cost_nothing():
    events = [ev(EventKind.completed, T0, "t1"),
              ev(EventKind.ignored, T0, "t1"),
              ev(EventKind.snoozed, T0, "t1"),
              ev(EventKind.panic, T0)]
    with_noise = compute(events, {"t1": task()}, T0)
    clean = compute([events[0]], {"t1": task()}, T0)
    assert with_noise.total == clean.total, "no penalties, ever"


def test_habit_dones_score_small():
    events = [ev(EventKind.completed, T0, habit_id="h1")]
    assert compute(events, {}, T0).today == HABIT_DONE


def test_three_distinct_habits_make_a_perfect_day():
    events = [ev(EventKind.completed, T0 + timedelta(minutes=i), habit_id=f"h{i}")
              for i in range(3)]
    card = compute(events, {}, T0)
    assert card.perfect_days == 1
    assert card.today == 3 * HABIT_DONE + PERFECT_DAY


def test_same_habit_thrice_is_not_a_perfect_day():
    events = [ev(EventKind.completed, T0 + timedelta(minutes=i), habit_id="h1")
              for i in range(3)]
    assert compute(events, {}, T0).perfect_days == 0


def test_streak_bonus_grows_daily_and_caps():
    events = [ev(EventKind.completed, T0 - timedelta(days=d), f"t{d}")
              for d in range(10)]
    tasks = {f"t{d}": task(f"t{d}") for d in range(10)}
    card = compute(events, tasks, T0)
    # Day 10 of the chain: bonus capped at 25, not 50.
    today_iso = T0.astimezone(timezone(timedelta(hours=5, minutes=30))).date().isoformat()
    assert card.by_day[today_iso] == TASK_BASE + 25


def test_levels_and_progress():
    events = [ev(EventKind.completed, T0, f"t{i}") for i in range(6)]
    tasks = {f"t{i}": task(f"t{i}") for i in range(6)}
    card = compute(events, tasks, T0)   # 6*10 + streak 5 = 65 pts
    assert card.total == 65
    assert card.level_name == "Sprout"  # 50..149
    assert card.next_level_at == 150
    assert 0 < card.progress < 1


def test_achievements_are_earned_facts():
    events = [ev(EventKind.completed, T0 - timedelta(days=d), f"t{d}")
              for d in range(7)]
    tasks = {f"t{d}": task(f"t{d}") for d in range(7)}
    ids = {a["id"] for a in compute(events, tasks, T0).achievements}
    assert {"first_done", "streak_3", "streak_7"} <= ids
    assert "streak_30" not in ids


def test_empty_ledger_is_level_one_zero_points():
    card = compute([], {}, T0)
    assert card.total == 0 and card.level == 1 and card.level_name == "Seed"
