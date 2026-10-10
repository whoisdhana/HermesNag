# AGENTS.md: HermesNag

Agent-powered task, habit and reminder system: macOS desktop widget + iPhone web widget, self-hosted, MCP-integrated. Public repo, MIT.
Server: Python 3.12 FastAPI + SQLModel + SQLite (WAL). Mac app: SwiftPM (no Xcode). Agent tool: stdlib-only stdio MCP server.

## Layout

- `server/`: FastAPI app, the source of truth. Binds 127.0.0.1:8787 only.
- `mac/`: SwiftPM app (desktop widget, tunnel supervisor, reminder engine, panels). macOS only.
- `hermes-tool/`: MCP server (`server.py`), agent skill, cron scripts, Scriptable iPhone widget.
- `docs/`: `API.md`, `DEPLOYMENT.md`.

## Commands (run from repo root)

| Step | Command | Notes |
|---|---|---|
| Install | `make venv` | Creates `server/.venv`, installs `server[dev]`. CI uses Python 3.12. |
| Test (server) | `cd server && .venv/bin/python -m pytest -p no:warnings -q` | 133 tests. See Gotchas for the one time-dependent failure. |
| Test (MCP tool) | `cd hermes-tool && ../server/.venv/bin/python -m pytest test_server.py -p no:warnings -q` | 14 tests, pass. |
| Test (mac) | `make -C mac test` | macOS only (swift-testing). Cannot run on the Linux box. |
| Full gate | `make check` | All three suites; the `.githooks/pre-push` hook runs it. Linux: run the two Python suites. |
| Dev server | `cd server && .venv/bin/python -m app.main` | Needs `server/.env` (copy `.env.example`). |
| Whitespace | `git diff --check` | Must be clean. |

CI (`.github/workflows/tests.yml`) runs the two Python suites on PRs and pushes to `main`.

## Definition of done (before opening a PR)

1. Server and MCP suites pass (no new failures); mac suite on a Mac if `mac/` changed.
2. `git diff --check` is clean; the diff contains only the requested change.
3. Paste real test output in the handoff, not claims.
4. PR from a feature branch with CI green.

## Hard rules (from the original CLAUDE.md)

1. Store UTC only. Naive datetimes are rejected, never coerced. Display zone is config
   (`HERMESNAG_DISPLAY_TZ` / `displayTimeZone`).
2. Never DELETE rows. `dropped` is a status; the event table is append-only (agent memory + score ledger).
3. No sleeps in tests: inject the clock.
4. The reminder path never calls an LLM. Nag copy is pre-generated into a pool with static fallbacks.
5. Auto-created tasks are never `must` (takeover tier); only the user promotes.

## Accounts and deploy target

- GitHub: `whoisdhana/HermesNag` (PUBLIC), default branch `main`. Use `gx whoisdhana ...`
  (pinned by `.gx-account`). Commit author `whoisdhana <whoisdhana@gmail.com>` (gx sets it).
  No Vercel; no `.vercel-account`.
- The live service does NOT run from git. Three copies exist on Dhana's server (home dir):
  - `~/apps/hermes-nag`: LIVE server, plain directory (not git), user systemd unit
    `hermes-nag.service` (`.venv/bin/python -m app.main`, 127.0.0.1:8787, `.env` there).
    It has drifted ahead of GitHub (e.g. web push `app/push.py`, changed `main.py`, `mobile.py`).
  - `~/apps/hermes-nag-mcp`: live MCP tool + cron scripts (also not git, also drifted).
  - `~/apps/hermes-nag-staging`: local-only git repo (no GitHub remote) holding the iOS-style
    PWA rebuild (`app/mobile.py`, `app/views.py`), staging server on 127.0.0.1:9199.
- So: this repo is the public, scrubbed source. Before porting a change to or from live,
  diff the directories first; never assume they match.
- `make deploy` rsyncs `server/` with `--delete` and runs `install.sh`: it would overwrite the
  live drift. Do not run it.

## Needs Dhana's explicit yes

- Merging or pushing to `main` (public repo).
- Anything touching `~/apps/hermes-nag` or `~/apps/hermes-nag-mcp`: edits, copies, `make deploy`.
- Restarting or reinstalling `hermes-nag.service` (`make restart`, `systemctl --user restart`).
- Mac installs (`make install` / `make release` replace `/Applications/HermesNag.app`).
- Releases, tags, version bumps; sending push notifications to real devices.

Reading, tests, feature branches and draft PRs need no approval.

## Gotchas

- PUBLIC repo: no personal names, phone numbers, hostnames, tailnet URLs, tokens or task
  content in code, tests, docs or commits. Commit `dd7de80` scrubbed these once; keep it so.
- Never read or print `.env*` (only `server/.env.example`), `vapid_private.pem`,
  `staging_token.txt`, or any `hermesnag.db*` (real tasks and habits).
- `tests/test_habits.py::test_habits_due_reports_a_nag_line` depends on the wall clock: it
  failed at ~00:15 IST (132/133 pass). Not a regression from your change if it is the only one.
- Mac build: CLT ships swift-testing but not XCTest; Testing.framework needs `-rpath` at link
  time (see `mac/Makefile` CLT_FLAGS); DYLD_* is stripped by SIP.
- Launch the Mac app via `open`, never the bare binary (single-instance).
- rsync strips execute bits if the repo copy is not +x: keep scripts executable in git.

## Longer docs

- `README.md`: features, quickstart, configuration, hard-won gotchas.
- `docs/API.md`: HTTP API. `docs/DEPLOYMENT.md`: server, Mac app, iPhone, agent setup.
- `hermes-tool/skill/SKILL.md`: how agents use the MCP tool.
- `CONTRIBUTING.md`, `SECURITY.md`.
