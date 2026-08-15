"""UTC-only time handling.

Correction C1 (docs/00-discovery.md): the Oracle box's clock is Asia/Kolkata,
NOT UTC as the spec assumed. Because the server's local zone equals the client's
display zone, a naive-datetime bug renders *correct-looking* output in testing
and would only surface later, in a way that's hard to trace.

So naive datetimes are rejected loudly at the boundary rather than coerced.
Never call datetime.now() without a tz, and never utcnow() (naive by design).
"""

from __future__ import annotations

from datetime import datetime, timezone
from zoneinfo import ZoneInfo

UTC = timezone.utc
# Client rendering only; storage is UTC. Configurable because day boundaries
# ("due today", streaks, active hours) must mean the USER'S day.
import os
DISPLAY_TZ = ZoneInfo(os.getenv("HERMESNAG_DISPLAY_TZ", "UTC"))


class NaiveDatetimeError(ValueError):
    """A datetime arrived without tzinfo. Refuse to guess what it meant."""


def now_utc() -> datetime:
    """Current time, always aware. The only clock source in the app."""
    return datetime.now(UTC)


def ensure_utc(dt: datetime | None) -> datetime | None:
    """Normalize an aware datetime to UTC. Reject naive ones.

    Rejecting rather than assuming is the entire point: on this box, assuming
    would silently produce values that look right for 5h30m worth of wrongness.
    """
    if dt is None:
        return None
    if not isinstance(dt, datetime):
        raise TypeError(f"expected datetime, got {type(dt).__name__}")
    if dt.tzinfo is None or dt.tzinfo.utcoffset(dt) is None:
        raise NaiveDatetimeError(
            "naive datetime rejected: supply an explicit timezone offset "
            "(ISO-8601 like 2026-08-12T18:30:00+05:30 or ...Z). "
            "Server local time is IST, so guessing would corrupt data silently."
        )
    return dt.astimezone(UTC)


def to_display(dt: datetime | None) -> datetime | None:
    """Render an instant in the user's zone (Asia/Kolkata). Display only."""
    if dt is None:
        return None
    return ensure_utc(dt).astimezone(DISPLAY_TZ)


def iso(dt: datetime | None) -> str | None:
    """Wire format: ISO-8601 with an explicit offset, always UTC-normalized."""
    if dt is None:
        return None
    return ensure_utc(dt).isoformat()


def iso_local(dt: datetime | None) -> str | None:
    """Same instant rendered in the display zone, keeping its +05:30 offset.

    Distinct from iso(): that one normalizes to UTC, which would silently strip
    the offset this is meant to show.
    """
    if dt is None:
        return None
    return to_display(dt).isoformat()


def parse_iso(value: str) -> datetime:
    """Parse an ISO-8601 string, requiring an explicit offset.

    Accepts a trailing 'Z'. A bare '2026-08-12T18:30:00' is rejected.
    """
    if not isinstance(value, str):
        raise TypeError(f"expected str, got {type(value).__name__}")
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError as exc:
        raise ValueError(f"not a valid ISO-8601 datetime: {value!r}") from exc
    return ensure_utc(dt)
