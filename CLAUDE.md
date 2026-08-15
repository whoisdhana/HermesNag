# CLAUDE.md — HermesNag

Working notes for AI agents and contributors.

## Layout
- `server/` — FastAPI + SQLModel + SQLite (WAL), the source of truth. Deploys
  to a VPS via `make deploy`, binds 127.0.0.1:8787 only.
- `mac/` — SwiftPM app (NO Xcode needed): desktop widget, tunnel supervisor,
  reminder engine, panels. `make -C mac test|bundle|run`.
- `hermes-tool/` — stdlib-only stdio MCP server + agent skill + cron scripts.

## Hard rules
1. Store UTC only. Naive datetimes are rejected, never coerced — the display
   zone is configuration (`HERMESNAG_DISPLAY_TZ` / `displayTimeZone`).
2. Never DELETE rows. `dropped` is a status; the event table is append-only
   (it is both the agent's memory and the score ledger).
3. No sleeps in tests — inject the clock. `make check` is the gate; the
   pre-push hook runs it.
4. The reminder path never calls an LLM. Nag copy is pre-generated into a
   pool with static fallbacks.
5. Auto-created tasks are never `must` (takeover tier) — only the user
   promotes.
6. Run what you write: paste real output, not claims.

## Build gotchas
- CLT ships swift-testing but not XCTest; Testing.framework needs -rpath at
  link time (see mac/Makefile CLT_FLAGS) — DYLD_* is stripped by SIP.
- Launch the app via `open`, never the bare binary (single-instance).
- rsync strips execute bits if the repo copy isn't +x — keep scripts
  executable in git.
