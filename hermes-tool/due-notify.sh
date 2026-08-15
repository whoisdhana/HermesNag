#!/usr/bin/env bash
# Push due HermesNag tasks to the phone via Telegram.
#
# This IS the mobile notification channel: the web page can't push (iOS web
# push needs a service-worker build-out), but the box already has a Telegram
# gateway, so `hermes send` reaches the phone with no LLM in the path.
#
# Run by `hermes cron` every 15 minutes. Silent unless something is due, and
# a state hash stops it re-sending the same alert every tick — a nag channel
# that repeats itself gets muted, and a muted channel is worthless.
set -euo pipefail

APP_DIR="${HERMESNAG_APP_DIR:-$HOME/apps/hermes-nag}"
HERMES="${HERMES_BIN:-$HOME/.hermes/hermes-agent/venv/bin/hermes}"

# shellcheck disable=SC1090
set -a; . "$APP_DIR/.env"; set +a
API="http://127.0.0.1:${HERMESNAG_PORT:-8787}"

RESP=$(curl -fsS --max-time 10 "$API/due" -H "Authorization: Bearer ${HERMESNAG_TOKEN}")

MSG=$(RESP="$RESP" "$APP_DIR/.venv/bin/python" - <<'PY'
import json, os, sys, hashlib

data = json.loads(os.environ["RESP"])
due = data.get("due", [])
if not due:
    sys.exit(0)

# Fingerprint of what's due at which level — resend only when it changes.
fingerprint = hashlib.sha1(
    "|".join(f"{t['id']}:{t['level']}" for t in due).encode()).hexdigest()
state_path = os.path.expanduser("~/.hermes/scripts/.hermesnag_due_notify.state")
previous = open(state_path).read().strip() if os.path.exists(state_path) else ""
if fingerprint == previous:
    sys.exit(0)
open(state_path, "w").write(fingerprint)

icons = {1: "🔔", 2: "⚠️", 3: "🚨"}
lines = [f"{icons.get(t['level'], '🔔')} {t['title']} — {t['nag_line']}" for t in due[:5]]
if len(due) > 5:
    lines.append(f"…and {len(due) - 5} more")
print("\n".join(lines))
PY
)

if [[ -n "$MSG" ]]; then
  printf '%s\n' "$MSG" | "$HERMES" send -t telegram -q
  echo "notified: $(printf '%s' "$MSG" | head -1)"
fi
