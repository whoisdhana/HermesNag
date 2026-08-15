#!/usr/bin/env bash
# Nightly SQLite backup for HermesNag.
#
# The event ledger is Hermes's memory and the gamification history — before
# this script existed there was NO backup of it anywhere. Run by `hermes cron`
# (--no-agent); silent on success so the cron job doesn't spam.
#
# Uses Python's sqlite3 online backup (the box has no sqlite3 CLI). This is
# safe against a live WAL database — a plain `cp` can capture a torn state.
set -euo pipefail
umask 077

APP_DIR="${HERMESNAG_APP_DIR:-$HOME/apps/hermes-nag}"
DB="$APP_DIR/hermesnag.db"
DEST_DIR="${HERMESNAG_BACKUP_DIR:-$HOME/backups/hermes-nag}"
PY="$APP_DIR/.venv/bin/python"
KEEP=14

[[ -f "$DB" ]] || { echo "backup FAILED: no database at $DB" >&2; exit 1; }
mkdir -p "$DEST_DIR"

STAMP=$(date +%Y%m%d)
OUT="$DEST_DIR/hermesnag-$STAMP.db"

"$PY" - "$DB" "$OUT" <<'PYEOF'
import sqlite3, sys
src_path, out_path = sys.argv[1], sys.argv[2]
src = sqlite3.connect(src_path)
dst = sqlite3.connect(out_path)
with dst:
    src.backup(dst)          # online, WAL-safe
check = dst.execute("pragma integrity_check").fetchone()[0]
dst.close(); src.close()
if check != "ok":
    print(f"backup FAILED: integrity check on copy returned: {check}", file=sys.stderr)
    sys.exit(1)
PYEOF

gzip -f "$OUT"
chmod 600 "$OUT.gz"

# Rotate: keep the newest $KEEP.
ls -1t "$DEST_DIR"/hermesnag-*.db.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

# Silent success (empty stdout = quiet cron delivery).
exit 0
