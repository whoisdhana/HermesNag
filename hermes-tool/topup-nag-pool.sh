#!/usr/bin/env bash
# Top up the nag-line pool by asking Hermes to write fresh copy.
#
# Run by `hermes cron` (discovery C5: the box already has a durable scheduler
# with retry history and a per-job notepad — no reason to build another).
#
# This is the *only* place a model call touches nag copy. The reminder path
# reads the pool and never blocks: a Hermes call measured 14-17s, which would
# be an eternity for a popup that's meant to appear the moment a task is due.
#
# Silent unless something is wrong, so the cron job doesn't spam Telegram.
set -euo pipefail

APP_DIR="${HERMESNAG_APP_DIR:-$HOME/apps/hermes-nag}"
HERMES="${HERMES_BIN:-$HOME/.hermes/hermes-agent/venv/bin/hermes}"
TARGET_PER_LEVEL="${NAG_POOL_TARGET:-15}"

# shellcheck disable=SC1090
set -a; . "$APP_DIR/.env"; set +a
API="http://127.0.0.1:${HERMESNAG_PORT:-8787}"
AUTH="Authorization: Bearer ${HERMESNAG_TOKEN}"

depth_for() {
  curl -fsS "$API/nag-lines/depth" -H "$AUTH" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['by_level'].get('$1',0))"
}

tone_for() {
  case "$1" in
    1) echo "playful and cheeky, at most 12 words, second person" ;;
    2) echo "mock-disappointed and a bit exasperated, at most 14 words, second person" ;;
    3) echo "short and blunt, naming the real stakes, at most 14 words" ;;
  esac
}

generated_total=0

for level in 1 2 3; do
  current=$(depth_for "$level")
  if [[ "$current" -ge "$TARGET_PER_LEVEL" ]]; then
    continue
  fi
  want=$(( TARGET_PER_LEVEL - current ))

  prompt="Write ${want} reminder lines for a to-do app, tone: $(tone_for "$level").
Use the literal placeholder {title} where the task name should appear.
Target the task, never insult the person reading it. No emoji. No numbering.
Output ONLY a JSON array of strings."

  # Never let one slow/failed generation abort the whole job — the pool
  # degrades to static fallbacks, which is the designed safety net.
  if ! raw=$(timeout 180 "$HERMES" -z "$prompt" 2>/dev/null); then
    echo "level $level: hermes call failed or timed out" >&2
    continue
  fi

  stored=$(python3 - "$level" <<PY || true
import json, re, sys, urllib.request

level = int(sys.argv[1])
raw = """$raw"""

text = raw.strip()
fenced = re.search(r"\`\`\`(?:json)?\s*(.+?)\s*\`\`\`", text, re.S)
if fenced:
    text = fenced.group(1).strip()
match = re.search(r"\[.*\]", text, re.S)
if not match:
    sys.exit(0)

try:
    lines = [str(x).strip() for x in json.loads(match.group(0)) if str(x).strip()]
except json.JSONDecodeError:
    sys.exit(0)

if not lines:
    sys.exit(0)

body = json.dumps({"level": level, "lines": lines}).encode()
req = urllib.request.Request("$API/nag-lines", data=body, method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("Authorization", "Bearer ${HERMESNAG_TOKEN}")
with urllib.request.urlopen(req, timeout=15) as resp:
    print(json.load(resp)["stored"])
PY
)
  stored=${stored:-0}
  generated_total=$(( generated_total + stored ))
  [[ "$stored" -gt 0 ]] && echo "level $level: +$stored lines (was $current)"
done

if [[ "$generated_total" -eq 0 ]]; then
  # Silence keeps the cron job quiet on a normal no-op run.
  exit 0
fi

echo "nag pool topped up: $generated_total new line(s)"
