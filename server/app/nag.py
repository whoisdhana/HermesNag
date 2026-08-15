"""Nag-line pool.

Hermes takes 14-17s per call (measured, docs/00-discovery.md §4), so the
reminder path never calls it. It reads a pre-generated line from the pool and,
if the pool is empty, falls back to a static line. The app is never mute.

Tone per the spec: target the task, never the user's character.
  L1 playful, <=12 words   L2 mock-disappointed   L3 blunt, real stakes
"""

from __future__ import annotations

import random
from datetime import datetime

from sqlmodel import Session, select

from .models import NagLine

FALLBACK_LINES: dict[int, list[str]] = {
    1: [
        "Psst — {title} is up. Two minutes, tops?",
        "{title} is ready when you are.",
        "Gentle nudge: {title}.",
        "{title} just came due. Fancy knocking it out?",
        "Tiny win available: {title}.",
        "Your move — {title} is waiting.",
        "{title}. Now's a good moment.",
        "Quick one: {title} is due.",
        "{title} would love some attention.",
        "Clock says it's time for {title}.",
        "{title} is on deck.",
        "Knock out {title} and feel smug about it.",
        "Here's your nudge for {title}.",
        "{title} — shall we?",
        "Small task, big relief: {title}.",
        "{title} is due. Future you says thanks.",
        "One thing: {title}.",
        "{title} is ripe for finishing.",
        "Ready when you are: {title}.",
        "{title} — quick win, right now.",
    ],
    2: [
        "Still {title}. We've been here before.",
        "{title} is getting lonely. Again.",
        "Second time asking about {title}.",
        "{title} hasn't moved. Neither have you.",
        "Look. {title}. Please.",
        "{title} is officially overdue now.",
        "That's twice for {title}.",
        "{title} remains stubbornly undone.",
        "You snoozed. {title} did not go away.",
        "{title}, still. This is the nagging part.",
        "Round two: {title}.",
        "{title} is starting to take it personally.",
        "Ignoring {title} isn't finishing {title}.",
        "{title} — overdue and unimpressed.",
        "Asking again: {title}.",
        "{title} is past due and counting.",
        "We both know about {title}.",
        "{title} didn't complete itself. Shocking.",
        "Overdue: {title}. Let's fix that.",
        "{title} is waiting. Pointedly.",
    ],
    3: [
        "{title}. Now. This one matters.",
        "Deal with {title}.",
        "{title} is critical and hours overdue.",
        "Stop. Do {title}.",
        "{title} — this is the one you can't skip.",
        "Two hours overdue: {title}.",
        "{title}. No more snoozing.",
        "This is {title}. It's important. Handle it.",
        "{title} has consequences. Go.",
        "Everything else can wait. {title} can't.",
        "{title} — you flagged this as must.",
        "Last call: {title}.",
        "{title}. Right now.",
        "You marked {title} as no-escape. Here we are.",
        "{title} is overdue and it counts.",
        "Finish {title}.",
        "{title} — this is why you set it to must.",
        "No escape until {title} is done.",
        "{title}. It's time.",
        "Do {title} before it costs you.",
    ],
}


def fallback_line(level: int, title: str, rng: random.Random | None = None) -> str:
    """A static line. Always available, never blocks."""
    level = max(1, min(3, level))
    pool = FALLBACK_LINES[level]
    chooser = rng or random
    return chooser.choice(pool).format(title=title)


def take_line(
    session: Session,
    task_id: str,
    level: int,
    title: str,
    now: datetime,
    rng: random.Random | None = None,
) -> str:
    """Pull an unused pooled line for this task+level, else fall back.

    Task-specific lines are preferred over generic pooled ones; a line is
    marked used so it isn't repeated.
    """
    level = max(1, min(3, level))

    stmt = (
        select(NagLine)
        .where(NagLine.level == level)
        .where(NagLine.used_at.is_(None))
        .where((NagLine.task_id == task_id) | (NagLine.task_id.is_(None)))
        .order_by(NagLine.task_id.is_(None))  # task-specific first
        .limit(1)
    )
    line = session.exec(stmt).first()

    if line is None:
        return fallback_line(level, title, rng=rng)

    line.used_at = now
    session.add(line)
    return line.text.format(title=title) if "{title}" in line.text else line.text


def pool_depth(session: Session, level: int | None = None) -> int:
    """How many unused lines remain — drives the top-up cron job."""
    stmt = select(NagLine).where(NagLine.used_at.is_(None))
    if level is not None:
        stmt = stmt.where(NagLine.level == level)
    return len(session.exec(stmt).all())
