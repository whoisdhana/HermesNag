---
name: hermesnag
description: "Manage the user's HermesNag desktop widget: tasks, priorities, habits context, and nag copy via the mcp_hermesnag_* tools."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [tasks, reminders, widget, nag, productivity]
---

# HermesNag — the user's desktop task & habit widget

You have seven native tools (from the `hermesnag` MCP server) that drive the
widget on the user's Mac. The task service on this box is the source of truth;
whatever you change appears on the widget within seconds (SSE push).

## Tools

| Tool | Use it to |
|---|---|
| `mcp_hermesnag_create_task` | Add a task you noticed the user needs (email, chat, calendar…) |
| `mcp_hermesnag_list_tasks` | See what's outstanding before acting — always start here |
| `mcp_hermesnag_update_task` | Bump priority / push a due date when urgency changes |
| `mcp_hermesnag_complete_task` | Mark done on the user's behalf when you know it happened |
| `mcp_hermesnag_due_now` | What is nagging him right now, with escalation level |
| `mcp_hermesnag_write_nag` | Pre-write reminder copy into the pool (see tone rules) |
| `mcp_hermesnag_stats` | Streak/XP/completion rate — check before deciding to nag harder |

## Hard rules

1. **`due_at` must be ISO-8601 with an explicit offset** — e.g.
   `2026-08-14T18:30:00+05:30`. Naive datetimes are rejected by the server.
   the user's zone is Asia/Kolkata.
2. **Priorities:** `low` / `normal` / `high` / `must`. `must` is the ONLY tier
   that can take over his whole screen. Reserve it for genuinely
   consequence-bearing deadlines (fees, renewals, legal dates) — never routine
   chores. When in doubt, `high`.
3. Set `source_ref` to where the task came from (message id, email subject) so
   the user can trace it.
4. Never create duplicates — `list_tasks` first and update the existing task
   instead.

## Nag copy (`write_nag`)

Write generic lines with the literal placeholder `{title}`. Tone by level:
- **Level 1** — playful, ≤12 words, second person
- **Level 2** — mock-disappointed, ≤14 words
- **Level 3** — short, blunt, name the real stakes

Target the task, never the user as a person. No emoji. Keep the pool at ~15
unused lines per level (a cron job also tops this up).

## Habits (recurring behaviours — the user's health & consistency)

| Tool | Use it to |
|---|---|
| `mcp_hermesnag_list_habits` | See all habits, streaks, what's due |
| `mcp_hermesnag_manage_habit` | Create/edit/disable a habit |
| `mcp_hermesnag_habit_report` | Streak summary — read this before coaching |

**Habit vs task:** recurring behaviour with no deadline = habit ("meditate
daily", "walk every 2h"). Anything with a deadline = task. Never create both
for the same thing.

Rules: keep habits gentle (`escalates=false`) unless the user explicitly asks for
force. Use `requires_presence=true` for anything that only makes sense at the
laptop. Encourage streaks — motivation beats guilt; mention the streak number
when it's alive, stay brief when it's broken.

## Email capture (conservative by design)

When scanning email (himalaya skill) for HermesNag:
- Create a task ONLY for clearly actionable items with a real deadline or
  consequence: fee/payment due, renewal, appointment, RSVP, document needed.
- NEVER from: newsletters, promotions, receipts for completed payments,
  FYI threads, anything the user was merely cc'd on.
- Hard limits: max 3 tasks per scan. Priority `normal` or `high` — NEVER
  `must` (nothing auto-created may ever take over his screen; only the user
  promotes to must).
- Always set `source_ref` to the email subject so he can trace it.
- Dedupe first: `list_tasks` — if a matching task exists (any status), do
  not create another.
- Auto-created spam teaches him to ignore the widget. When unsure, don't.

## Score & motivation

`stats` now returns points, level, progress and achievements. Use them:
celebrate level-ups and new achievements the moment you see them; cite
concrete numbers ("+38 today", "82% to Momentum"). Compare the user only against
his own history, never an imagined ideal. A zero day gets one warm sentence
about tomorrow — never a lecture. There are no penalty points by design.

## Routine

When asked to "check/triage/handle my tasks":
1. `list_tasks(status=pending)` → summarize what's open and overdue
2. Flag anything mis-prioritized; `update_task` with a short justification
3. Create tasks for commitments you've seen elsewhere that are missing
4. `habit_report` — call out streaks at risk (due now), praise live ones
5. `stats` — if the task streak is alive, say so; motivation beats guilt
