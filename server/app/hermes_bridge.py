"""Adapter for talking *to* Hermes (shape B: headless CLI).

Shape A (Hermes calling us via MCP) is the inbound direction and lives in
hermes-tool/ — that's M5. This module is the outbound direction: generating
nag copy and parsing natural language.

Measured latency is 14-17s per call, so nothing here may sit in a request path.
Callers are the nag-pool top-up job (via `hermes cron`) and /parse, which
degrades to regex when Hermes is slow or unavailable.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from datetime import timedelta

from .timeutil import now_utc

# hermes is NOT on PATH for non-interactive shells (discovery §2).
HERMES_BIN = os.getenv("HERMES_BIN", "/home/ubuntu/.hermes/hermes-agent/venv/bin/hermes")

DEFAULT_TIMEOUT = 90  # generous: a trivial prompt measured 17s


class HermesUnavailable(RuntimeError):
    """Hermes could not be reached or timed out. Callers must degrade."""


def hermes_available() -> bool:
    return os.path.isfile(HERMES_BIN) and os.access(HERMES_BIN, os.X_OK)


def run_prompt(prompt: str, timeout: int = DEFAULT_TIMEOUT) -> str:
    """One headless call. Returns stdout text."""
    if not hermes_available():
        raise HermesUnavailable(f"hermes binary not found at {HERMES_BIN}")
    try:
        proc = subprocess.run(
            [HERMES_BIN, "-z", prompt],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise HermesUnavailable(f"hermes timed out after {timeout}s") from exc
    except OSError as exc:
        raise HermesUnavailable(f"could not execute hermes: {exc}") from exc

    if proc.returncode != 0:
        raise HermesUnavailable(f"hermes exited {proc.returncode}: {proc.stderr[:400]}")
    return proc.stdout.strip()


def _extract_json(text: str) -> object | None:
    """Pull the first JSON value out of a reply, tolerating prose around it."""
    text = text.strip()
    fenced = re.search(r"```(?:json)?\s*(.+?)\s*```", text, re.S)
    if fenced:
        text = fenced.group(1).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    match = re.search(r"(\[.*\]|\{.*\})", text, re.S)
    if match:
        try:
            return json.loads(match.group(1))
        except json.JSONDecodeError:
            return None
    return None


LEVEL_GUIDANCE = {
    1: "playful and cheeky, at most 12 words, second person, no emoji",
    2: "mock-disappointed, at most 14 words, second person, no emoji",
    3: "short and blunt, naming the real stakes, at most 14 words, no emoji",
}


def generate_nag_lines(title: str, level: int, count: int = 5) -> list[str]:
    """Ask Hermes for nag copy. Raises HermesUnavailable — callers fall back."""
    level = max(1, min(3, level))
    prompt = (
        f'Write {count} reminder lines for the task "{title}". '
        f"Tone: {LEVEL_GUIDANCE[level]}. "
        "Target the task, never insult the person. "
        "Output ONLY a JSON array of strings, no commentary."
    )
    parsed = _extract_json(run_prompt(prompt))
    if not isinstance(parsed, list):
        raise HermesUnavailable("hermes did not return a JSON array")
    return [str(x).strip() for x in parsed if str(x).strip()][:count]


# --- Natural-language parsing -------------------------------------------------

_PRIORITY_WORDS = {
    "must": "must", "critical": "must", "urgent": "must", "important": "high",
    "high": "high", "asap": "must", "low": "low", "whenever": "low", "someday": "low",
}

_RECUR_PATTERNS = [
    # order matters: most specific first
    (re.compile(r"\b(?:every\s+month\s+(?:on\s+)?(\d{1,2})(?:st|nd|rd|th)?|(\d{1,2})(?:st|nd|rd|th)?\s+of\s+every\s+month)\b", re.I),
     lambda m: f"FREQ=MONTHLY;BYMONTHDAY={m.group(1) or m.group(2)}"),
    (re.compile(r"\bevery\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b", re.I),
     lambda m: "FREQ=WEEKLY;BYDAY=" + m.group(1)[:2].upper()),
    (re.compile(r"\b(?:every\s+month|monthly)\b", re.I), lambda m: "FREQ=MONTHLY"),
    (re.compile(r"\b(?:every\s+week|weekly)\b", re.I), lambda m: "FREQ=WEEKLY"),
    (re.compile(r"\b(?:every\s+day|daily)\b", re.I), lambda m: "FREQ=DAILY"),
    (re.compile(r"\b(?:every\s+year|yearly|annually)\b", re.I), lambda m: "FREQ=YEARLY"),
]


def _extract_recurrence(text: str) -> tuple[str | None, str]:
    """Pull an RRULE out of phrases like 'every month 5th'. Returns
    (rrule_or_none, text_with_phrase_removed)."""
    for pattern, build in _RECUR_PATTERNS:
        m = pattern.search(text)
        if m:
            return build(m), (text[:m.start()] + " " + text[m.end():])
    return None, text


_TIME_RE = re.compile(r"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b", re.I)
_IN_RE = re.compile(r"\bin\s+(\d+)\s*(min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)\b", re.I)


def parse_natural(raw: str) -> dict:
    """Regex parse of a quick-capture string. Always succeeds, never blocks.

    Deliberately conservative: it extracts what it's confident about and leaves
    the rest alone. /parse tries Hermes first and falls back to this.
    """
    text = raw.strip()
    recurrence, text = _extract_recurrence(text)
    low = text.lower()
    now = now_utc()
    due = None

    m = _IN_RE.search(low)
    if m:
        n, unit = int(m.group(1)), m.group(2)
        if unit.startswith(("min", "m")) and not unit.startswith("mo"):
            due = now + timedelta(minutes=n)
        elif unit.startswith(("h", "hr")):
            due = now + timedelta(hours=n)
        elif unit.startswith("d"):
            due = now + timedelta(days=n)

    if due is None:
        from .timeutil import DISPLAY_TZ  # user speaks in local time

        local = now.astimezone(DISPLAY_TZ)
        base = None
        if "tomorrow" in low:
            base = local + timedelta(days=1)
        elif "today" in low or "tonight" in low:
            base = local

        tm = _TIME_RE.search(low)
        if tm:
            hour = int(tm.group(1)) % 12
            minute = int(tm.group(2) or 0)
            if tm.group(3).lower() == "pm":
                hour += 12
            base = base or local
            cand = base.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if cand <= local and "tomorrow" not in low:
                cand += timedelta(days=1)  # a past time today means tomorrow
            due = cand
        elif base is not None:
            due = base.replace(hour=9, minute=0, second=0, microsecond=0)

    priority = "normal"
    for word, level in _PRIORITY_WORDS.items():
        if re.search(rf"\b{word}\b", low):
            priority = level
            break

    tags = re.findall(r"#(\w+)", text)

    title = re.sub(r"#\w+", "", text)
    title = _IN_RE.sub("", title)
    title = _TIME_RE.sub("", title)
    title = re.sub(
        r"\b(tomorrow|today|tonight|urgent|critical|asap|must|important|someday|whenever)\b",
        "", title, flags=re.I,
    )
    title = re.sub(r"\s{2,}", " ", title).strip(" ,.-:;")

    return {
        "title": title or text.strip() or raw.strip(),
        "due_at": due.astimezone(now.tzinfo) if due else None,
        "priority": priority,
        "tags": tags,
        "recurrence": recurrence,
    }
