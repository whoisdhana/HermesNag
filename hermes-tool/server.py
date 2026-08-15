#!/usr/bin/env python3
"""HermesNag MCP server — the inbound half of the Hermes integration.

Shape (A) from docs/00-discovery.md: Hermes consumes local stdio MCP servers
natively (`ilovepdf` on the box is the same pattern). This exposes the task
service to Hermes as tools, so Hermes can create and reprioritize tasks on its
own schedule rather than us polling it.

Deliberately **stdlib only** — no `mcp` SDK, no `requests`. The box is
production with 8 live Hermes services; adding a dependency to a venv near
them is risk for no benefit when MCP stdio is a few hundred lines of JSON-RPC.

Protocol: JSON-RPC 2.0 over stdio, one JSON object per line.
  initialize -> tools/list -> tools/call

Everything is proxied to the FastAPI service on 127.0.0.1:8787, which stays the
single source of truth. This server holds no state.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

BASE_URL = os.environ.get("HERMESNAG_URL", "http://127.0.0.1:8787")
TOKEN = os.environ.get("HERMESNAG_TOKEN", "")
TIMEOUT = float(os.environ.get("HERMESNAG_TIMEOUT", "15"))

SERVER_NAME = "hermesnag"
SERVER_VERSION = "0.1.0"
FALLBACK_PROTOCOL = "2025-11-25"


def log(message: str) -> None:
    """stderr only — stdout is the JSON-RPC channel and must stay clean."""
    print(f"[hermesnag-mcp] {message}", file=sys.stderr, flush=True)


# --- HTTP to the task service ------------------------------------------------

class APIError(Exception):
    """The task service refused. Message is safe to show the model."""


def api(method: str, path: str, body: dict | None = None) -> dict:
    url = f"{BASE_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None

    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if TOKEN:
        req.add_header("Authorization", f"Bearer {TOKEN}")

    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        try:
            parsed = json.loads(detail)
            message = parsed.get("error", {}).get("message", detail)
        except json.JSONDecodeError:
            message = detail
        raise APIError(f"HTTP {exc.code}: {message}") from exc
    except urllib.error.URLError as exc:
        # Usually means the service is down or the token is missing.
        raise APIError(f"cannot reach task service at {BASE_URL}: {exc.reason}") from exc


# --- Tool implementations ----------------------------------------------------

def tool_create_task(args: dict) -> str:
    body = {
        "title": args.get("title"),
        "raw": args.get("raw"),
        "notes": args.get("notes"),
        "due_at": args.get("due_at"),
        "priority": args.get("priority", "normal"),
        "tags": args.get("tags", []),
        "recurrence": args.get("recurrence"),
        "source_ref": args.get("source_ref"),
        # Attribution matters: the event ledger is Hermes's own memory, and
        # "did I create this or did the user?" is the first thing it needs to know.
        "created_by": "hermes",
    }
    body = {k: v for k, v in body.items() if v is not None}
    task = api("POST", "/tasks", body)
    return (
        f"Created task {task['id']}: {task['title']!r} "
        f"(priority={task['priority']}, due={task.get('due_at_local') or 'unset'})"
    )


def tool_list_tasks(args: dict) -> str:
    query = []
    if status := args.get("status"):
        query.append(f"status_filter={status}")
    query.append(f"limit={int(args.get('limit', 50))}")
    payload = api("GET", "/tasks?" + "&".join(query))

    tasks = payload.get("tasks", [])
    if not tasks:
        return "No tasks match."

    lines = []
    for t in tasks:
        due = t.get("due_at_local") or "no due date"
        lines.append(
            f"- [{t['status']}] {t['title']} (id={t['id'][:8]}, "
            f"priority={t['priority']}, due={due}, ignored={t['ignore_count']}x)"
        )
    return f"{len(tasks)} task(s):\n" + "\n".join(lines)


def tool_update_task(args: dict) -> str:
    task_id = args["task_id"]
    body = {k: args[k] for k in ("title", "notes", "due_at", "priority", "recurrence")
            if args.get(k) is not None}
    if not body:
        return "Nothing to update — supply at least one field."
    task = api("PATCH", f"/tasks/{task_id}", body)
    return f"Updated {task['id'][:8]}: {task['title']!r} priority={task['priority']}"


def tool_complete_task(args: dict) -> str:
    result = api("POST", f"/tasks/{args['task_id']}/complete")
    task = result.get("task", {})
    return (
        f"Completed {task.get('title')!r}. "
        f"XP +{result.get('xp_awarded', 0)}, streak {result.get('streak', 0)} day(s)."
    )


def tool_due_now(args: dict) -> str:
    payload = api("GET", "/due")
    items = payload.get("due", [])
    if not items:
        return "Nothing is due right now."
    return f"{len(items)} due:\n" + "\n".join(
        f"- L{i['level']} {i['title']} — {i['nag_line']}" for i in items
    )


def tool_write_nag(args: dict) -> str:
    """Store Hermes-written nag copy in the pool.

    This is the outbound half: Hermes writes lines *ahead of time* so the
    reminder path never blocks on a 14-17s model call.
    """
    lines = args.get("lines") or []
    if isinstance(lines, str):
        lines = [lines]
    if not lines:
        return "No lines supplied."

    body = {
        "level": int(args.get("level", 1)),
        "lines": lines,
        "task_id": args.get("task_id"),
    }
    result = api("POST", "/nag-lines", body)
    return f"Stored {result.get('stored', len(lines))} nag line(s) at level {body['level']}."


def tool_list_habits(args: dict) -> str:
    payload = api("GET", "/habits")
    rows = payload.get("habits", [])
    if not rows:
        return "No habits configured."
    lines = []
    for h in rows:
        state = "due NOW" if h["is_due"] else f"next in {h['seconds_until_due']//60}m"
        flags = []
        if not h["enabled"]:
            flags.append("disabled")
        if h["requires_presence"]:
            flags.append("needs-presence")
        lines.append(
            f"- {h['name']} (id={h['id'][:8]}): every {h['interval_minutes']}m, "
            f"streak {h['streak']}, {state}"
            + (f" [{', '.join(flags)}]" if flags else ""))
    return f"{len(rows)} habit(s):\n" + "\n".join(lines)


def tool_manage_habit(args: dict) -> str:
    """Create, edit or disable a habit."""
    action = args.get("action", "create")
    if action == "create":
        body = {k: v for k, v in args.items()
                if k in ("name", "raw", "interval_minutes", "daily",
                         "active_from_hour", "active_to_hour",
                         "requires_presence", "escalates") and v is not None}
        h = api("POST", "/habits", body)
        return f"Created habit {h['name']!r} (every {h['interval_minutes']}m, id={h['id'][:8]})"
    habit_id = args.get("habit_id")
    if not habit_id:
        return "habit_id is required for edit/disable/enable."
    if action in ("disable", "enable"):
        h = api("PATCH", f"/habits/{habit_id}", {"enabled": action == "enable"})
        return f"{h['name']!r} is now {'enabled' if h['enabled'] else 'disabled'}."
    body = {k: v for k, v in args.items()
            if k in ("name", "interval_minutes", "active_from_hour",
                     "active_to_hour", "requires_presence", "escalates")
            and v is not None}
    h = api("PATCH", f"/habits/{habit_id}", body)
    return f"Updated {h['name']!r}: every {h['interval_minutes']}m."


def tool_habit_report(args: dict) -> str:
    """Streak-focused summary for consistency coaching."""
    rows = api("GET", "/habits").get("habits", [])
    active = [h for h in rows if h["enabled"]]
    if not active:
        return "No active habits."
    best = max(active, key=lambda h: h["streak"])
    at_risk = [h["name"] for h in active if h["is_due"]]
    lines = [f"- {h['name']}: streak {h['streak']}"
             + (f", last done {h['last_done_at'][:16]}" if h.get("last_done_at") else ", never done")
             for h in sorted(active, key=lambda h: -h["streak"])]
    summary = f"Best streak: {best['name']} ({best['streak']})."
    if at_risk:
        summary += f" Due right now: {', '.join(at_risk)}."
    return summary + "\n" + "\n".join(lines)


def tool_stats(args: dict) -> str:
    s = api("GET", "/stats")
    ach = ", ".join(a["name"] for a in s.get("achievements", [])[-3:]) or "none yet"
    return (
        f"Level {s.get('level')} {s.get('level_name')} — {s.get('points_total')} pts "
        f"(+{s.get('points_today')} today, {s.get('points_week')} this week, "
        f"{int((s.get('level_progress') or 0) * 100)}% to next level)\n"
        f"Task streak {s['streak_days']}d · {s['completed_7d']} done in 7d · "
        f"perfect days {s.get('perfect_days')} · recent achievements: {ach}\n"
        "points by day (last 14): "
        + ", ".join(f"{d['date'][5:]}:{d['points']}" for d in s.get("points_by_day", []))
    )


TOOLS = [
    {
        "name": "create_task",
        "description": (
            "Create a task for the user in HermesNag. Use this whenever you notice "
            "something he needs to do. Either pass a structured `title` (+ optional "
            "due_at) or a natural-language `raw` string to be parsed. "
            "IMPORTANT: due_at must be ISO-8601 WITH an explicit offset "
            "(e.g. 2026-08-13T18:30:00+05:30). Naive datetimes are rejected."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Task title"},
                "raw": {"type": "string", "description": "Natural language, parsed server-side"},
                "notes": {"type": "string"},
                "due_at": {"type": "string", "description": "ISO-8601 with offset"},
                "priority": {"type": "string", "enum": ["low", "normal", "high", "must"],
                             "description": "'must' is the only one that can take over the screen"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "recurrence": {"type": "string", "description": "RRULE, e.g. FREQ=DAILY"},
                "source_ref": {"type": "string",
                               "description": "Where this came from (email id, message link)"},
            },
        },
    },
    {
        "name": "list_tasks",
        "description": "List the user's tasks. Filter by status to see what's outstanding.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {"type": "string", "enum": ["pending", "snoozed", "done", "dropped"]},
                "limit": {"type": "integer", "default": 50},
            },
        },
    },
    {
        "name": "update_task",
        "description": (
            "Update a task — most usefully to bump priority when something has "
            "become urgent, or to push a due date."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "string"},
                "title": {"type": "string"},
                "notes": {"type": "string"},
                "due_at": {"type": "string", "description": "ISO-8601 with offset"},
                "priority": {"type": "string", "enum": ["low", "normal", "high", "must"]},
                "recurrence": {"type": "string"},
            },
            "required": ["task_id"],
        },
    },
    {
        "name": "complete_task",
        "description": "Mark a task done. Recurring tasks roll forward to their next occurrence.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "string"}},
            "required": ["task_id"],
        },
    },
    {
        "name": "due_now",
        "description": "What should be nagging the user right now, with escalation level and nag line.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "write_nag",
        "description": (
            "Pre-generate nag copy into the pool. The reminder path never calls a "
            "model (too slow), so lines must be written ahead of time. "
            "Tone by level: 1 = playful, <=12 words. 2 = mock-disappointed. "
            "3 = blunt, names the real stakes. Target the task, never insult the user. "
            "Use {title} as a placeholder for the task title in generic lines."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "level": {"type": "integer", "enum": [1, 2, 3]},
                "lines": {"type": "array", "items": {"type": "string"}},
                "task_id": {"type": "string",
                            "description": "Omit for generic lines usable by any task"},
            },
            "required": ["level", "lines"],
        },
    },
    {
        "name": "habit_report",
        "description": "Streaks and consistency summary — use before encouraging or nagging about habits.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_habits",
        "description": "the user's recurring habits (water, stand up, eye rest, plus his own) with streaks and next-due times.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "manage_habit",
        "description": (
            "Create, edit, disable or enable a habit. A habit is a recurring "
            "behaviour with no deadline (meditate daily, walk every 2h) — if it "
            "has a deadline, use create_task instead. Keep habits gentle: "
            "escalates=false unless the user explicitly wants force."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["create", "edit", "disable", "enable"],
                           "default": "create"},
                "habit_id": {"type": "string", "description": "Required for edit/disable/enable"},
                "name": {"type": "string"},
                "raw": {"type": "string", "description": "Natural language, e.g. 'journal every 90m'"},
                "interval_minutes": {"type": "integer"},
                "daily": {"type": "boolean", "description": "Shorthand for once a day"},
                "active_from_hour": {"type": "integer", "description": "IST hour, default 8"},
                "active_to_hour": {"type": "integer", "description": "IST hour, default 22"},
                "requires_presence": {"type": "boolean",
                                      "description": "Only fire when the user is actually at the laptop"},
                "escalates": {"type": "boolean"},
            },
        },
    },
    {
        "name": "stats",
        "description": "the user's streak, XP and completion rate — useful context before nagging.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]

HANDLERS = {
    "create_task": tool_create_task,
    "list_tasks": tool_list_tasks,
    "update_task": tool_update_task,
    "complete_task": tool_complete_task,
    "due_now": tool_due_now,
    "write_nag": tool_write_nag,
    "stats": tool_stats,
    "list_habits": tool_list_habits,
    "manage_habit": tool_manage_habit,
    "habit_report": tool_habit_report,
}


# --- JSON-RPC plumbing -------------------------------------------------------

def result(request_id, payload) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "result": payload}


def error(request_id, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def handle(request: dict) -> dict | None:
    method = request.get("method")
    request_id = request.get("id")

    # Notifications have no id and must not be answered.
    if request_id is None:
        return None

    if method == "initialize":
        # Echo the client's protocol version when we can speak it, so a newer
        # or older Hermes still negotiates successfully.
        client_version = (request.get("params") or {}).get("protocolVersion")
        return result(request_id, {
            "protocolVersion": client_version or FALLBACK_PROTOCOL,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })

    if method == "tools/list":
        return result(request_id, {"tools": TOOLS})

    if method == "tools/call":
        params = request.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}

        handler = HANDLERS.get(name)
        if handler is None:
            return error(request_id, -32602, f"unknown tool: {name}")

        try:
            text = handler(args)
            return result(request_id, {"content": [{"type": "text", "text": text}]})
        except APIError as exc:
            # Report as tool-level failure, not transport failure: the model
            # can read it and retry sensibly.
            return result(request_id, {
                "content": [{"type": "text", "text": f"Error: {exc}"}],
                "isError": True,
            })
        except KeyError as exc:
            return result(request_id, {
                "content": [{"type": "text", "text": f"Missing required argument: {exc}"}],
                "isError": True,
            })
        except Exception as exc:  # noqa: BLE001 - never kill the server on one bad call
            log(f"unexpected error in {name}: {exc!r}")
            return result(request_id, {
                "content": [{"type": "text", "text": f"Unexpected error: {exc}"}],
                "isError": True,
            })

    if method in ("ping", "shutdown"):
        return result(request_id, {})

    return error(request_id, -32601, f"method not found: {method}")


def main() -> None:
    log(f"starting, task service at {BASE_URL}, token {'set' if TOKEN else 'MISSING'}")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            log(f"bad JSON: {exc}")
            continue

        response = handle(request)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()

    log("stdin closed, exiting")


if __name__ == "__main__":
    main()
