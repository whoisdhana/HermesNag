"""Scoring — derived by replaying the append-only event ledger.

Nothing is stored: the score is a pure function of history, so it can never
drift out of sync, it's retroactive over everything already done, and an
undo naturally takes back exactly what the completion gave.

Design rules (the user's choices):
  * Game-y: levels, achievements, celebrations.
  * NO penalties, ever. Ignores and snoozes cost nothing; a bad day is a
    flat day, not a hole. The only subtraction is undo, which is neutral
    bookkeeping, not punishment.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from .models import Event, EventKind, Priority, Task
from .timeutil import DISPLAY_TZ

# --- point table ---------------------------------------------------------------

TASK_BASE = 10
MUST_BONUS = 5          # force tasks weigh more
EARLY_BONUS = 5         # done before it was due
HABIT_DONE = 3          # frequent -> smaller, so habits can't dwarf tasks
PERFECT_DAY = 15        # >=3 distinct habits honoured in one (IST) day
STREAK_PER_DAY = 5      # daily task-completion chain
STREAK_CAP = 25

LEVELS = [
    (0, "Seed"), (50, "Sprout"), (150, "Steady"), (300, "Groove"),
    (500, "Momentum"), (750, "Flow"), (1050, "Charged"),
    (1400, "Blazing"), (1800, "Unstoppable"),
]
# Beyond the table: +450 per level, name sticks at the last one.
LEVEL_STEP_AFTER_TABLE = 450


@dataclass
class ScoreCard:
    total: int = 0
    today: int = 0
    week: int = 0
    level: int = 1
    level_name: str = "Seed"
    next_level_at: int = 50
    progress: float = 0.0            # 0..1 toward the next level
    perfect_days: int = 0
    achievements: list[dict] = field(default_factory=list)
    by_day: dict[str, int] = field(default_factory=dict)   # ISO date -> points


def _award_for_task(task: Task | None, completed_at: datetime) -> int:
    points = TASK_BASE
    if task is not None:
        if task.priority == Priority.must:
            points += MUST_BONUS
        if task.due_at is not None and completed_at <= task.due_at:
            points += EARLY_BONUS
    return points


def compute(events: list[Event], tasks_by_id: dict[str, Task],
            now: datetime) -> ScoreCard:
    """Replay the ledger chronologically. Pure — `now` is injected."""
    card = ScoreCard()
    day_points: dict[str, int] = defaultdict(int)
    # Last award per task, so a reopen takes back exactly what was given.
    last_award: dict[str, int] = {}
    habit_days: dict[str, set[str]] = defaultdict(set)   # day -> habit ids
    task_days: set[str] = set()

    for event in sorted(events, key=lambda e: e.at):
        day = event.at.astimezone(DISPLAY_TZ).date().isoformat()

        if event.kind == EventKind.completed:
            habit_id = (event.meta or {}).get("habit_id")
            if habit_id:
                day_points[day] += HABIT_DONE
                habit_days[day].add(habit_id)
            elif event.task_id:
                award = _award_for_task(tasks_by_id.get(event.task_id), event.at)
                day_points[day] += award
                last_award[event.task_id] = award
                task_days.add(day)

        elif event.kind == EventKind.reopened and event.task_id:
            # Undo: neutral bookkeeping — subtract what the completion gave.
            day_points[day] -= last_award.pop(event.task_id, TASK_BASE)

    # Perfect days: three or more distinct habits honoured.
    perfect = {day for day, ids in habit_days.items() if len(ids) >= 3}
    for day in perfect:
        day_points[day] += PERFECT_DAY
    card.perfect_days = len(perfect)

    # Streak bonus: consecutive task-completion days (IST), +5/day capped.
    for day in sorted(task_days):
        prev = (datetime.fromisoformat(day) - timedelta(days=1)).date().isoformat()
        streak_len = 1
        cursor = prev
        while cursor in task_days:
            streak_len += 1
            cursor = (datetime.fromisoformat(cursor) - timedelta(days=1)).date().isoformat()
        day_points[day] += min(STREAK_PER_DAY * streak_len, STREAK_CAP)

    # Roll up.
    card.by_day = dict(day_points)
    card.total = max(0, sum(day_points.values()))
    today = now.astimezone(DISPLAY_TZ).date()
    card.today = max(0, day_points.get(today.isoformat(), 0))
    card.week = max(0, sum(
        pts for day, pts in day_points.items()
        if (today - datetime.fromisoformat(day).date()).days < 7))

    # Level.
    level_num, level_name, floor_pts = 1, LEVELS[0][1], 0
    next_at = LEVELS[1][0] if len(LEVELS) > 1 else LEVEL_STEP_AFTER_TABLE
    for i, (threshold, name) in enumerate(LEVELS):
        if card.total >= threshold:
            level_num, level_name, floor_pts = i + 1, name, threshold
            next_at = (LEVELS[i + 1][0] if i + 1 < len(LEVELS)
                       else threshold + LEVEL_STEP_AFTER_TABLE)
    while card.total >= next_at:
        level_num += 1
        floor_pts = next_at
        next_at += LEVEL_STEP_AFTER_TABLE
    card.level = level_num
    card.level_name = level_name
    card.next_level_at = next_at
    span = max(1, next_at - floor_pts)
    card.progress = round((card.total - floor_pts) / span, 3)

    # Achievements — earned facts, never revoked.
    total_completions = sum(1 for e in events
                            if e.kind == EventKind.completed and e.task_id
                            and not (e.meta or {}).get("habit_id"))
    longest = _longest_chain(task_days)
    defs = [
        ("first_done", "First task done", total_completions >= 1),
        ("ten_done", "10 tasks done", total_completions >= 10),
        ("fifty_done", "50 tasks done", total_completions >= 50),
        ("perfect_day", "First perfect day", card.perfect_days >= 1),
        ("perfect_week", "7 perfect days", card.perfect_days >= 7),
        ("streak_3", "3-day streak", longest >= 3),
        ("streak_7", "7-day streak", longest >= 7),
        ("streak_30", "30-day streak", longest >= 30),
    ]
    card.achievements = [{"id": aid, "name": name}
                         for aid, name, earned in defs if earned]
    return card


def _longest_chain(days: set[str]) -> int:
    best = 0
    for day in days:
        prev = (datetime.fromisoformat(day) - timedelta(days=1)).date().isoformat()
        if prev in days:
            continue  # not a chain start
        length, cursor = 1, day
        while True:
            nxt = (datetime.fromisoformat(cursor) + timedelta(days=1)).date().isoformat()
            if nxt not in days:
                break
            length += 1
            cursor = nxt
        best = max(best, length)
    return best
