#!/usr/bin/env bash
# HermesNag server installer — run ON the Oracle box.
#
# Idempotent and additive. It never touches the existing Hermes install,
# its config.yaml, or the 7 running hermes-gateway-* services.
set -euo pipefail
# Everything this script creates (db, logs, backups) is private by default.
umask 077

APP_DIR="$HOME/apps/hermes-nag"
ENV_FILE="$APP_DIR/.env"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="hermes-nag.service"

echo "==> HermesNag installer"
echo "    target: $APP_DIR"

mkdir -p "$APP_DIR" "$UNIT_DIR"

# --- venv -------------------------------------------------------------------
# Its own venv. Never reuse Hermes's — a dependency conflict there would take
# down the gateways.
if [ ! -d "$APP_DIR/.venv" ]; then
  echo "==> creating venv"
  python3 -m venv "$APP_DIR/.venv"
fi
"$APP_DIR/.venv/bin/pip" install -q --upgrade pip
echo "==> installing dependencies"
# Locked versions when present — a redeploy must never silently pull a
# breaking release. pyproject keeps ranges for development only.
if [ -f "$APP_DIR/requirements.lock" ]; then
  "$APP_DIR/.venv/bin/pip" install -q -r "$APP_DIR/requirements.lock"
  "$APP_DIR/.venv/bin/pip" install -q --no-deps -e "$APP_DIR"
else
  "$APP_DIR/.venv/bin/pip" install -q -e "$APP_DIR"
fi

# The db may predate umask 077 — it holds every task title; keep it private.
[ -f "$APP_DIR/hermesnag.db" ] && chmod 600 "$APP_DIR"/hermesnag.db*

# --- token ------------------------------------------------------------------
# Generated here, printed once. Never committed.
if [ ! -f "$ENV_FILE" ]; then
  echo "==> generating bearer token"
  TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  cat > "$ENV_FILE" <<EOF
HERMESNAG_TOKEN=$TOKEN
HERMESNAG_DB=$APP_DIR/hermesnag.db
HERMESNAG_HOST=127.0.0.1
HERMESNAG_PORT=8787
HERMES_BIN=$HOME/.hermes/hermes-agent/venv/bin/hermes
HERMESNAG_DISPLAY_TZ=Asia/Kolkata
EOF
  chmod 600 "$ENV_FILE"
  echo ""
  echo "    ┌──────────────────────────────────────────────────────────"
  echo "    │ BEARER TOKEN (shown once — store it in the Mac Keychain):"
  echo "    │ $TOKEN"
  echo "    └──────────────────────────────────────────────────────────"
  echo ""
  echo "    On the Mac:"
  echo "      security add-generic-password -a hermesnag -s hermesnag-token -w '$TOKEN'"
  echo ""
else
  echo "==> .env exists, keeping the current token"
fi

# --- service ----------------------------------------------------------------
echo "==> installing systemd --user unit"
cp "$APP_DIR/deploy/$UNIT" "$UNIT_DIR/$UNIT"
systemctl --user daemon-reload
systemctl --user enable "$UNIT" >/dev/null 2>&1 || true
systemctl --user restart "$UNIT"

sleep 2
if systemctl --user is-active --quiet "$UNIT"; then
  echo "==> $UNIT is active"
else
  echo "!! $UNIT failed to start:"
  journalctl --user -u "$UNIT" -n 30 --no-pager
  exit 1
fi

# --- verify -----------------------------------------------------------------
echo "==> verifying bind address"
if ss -tln | grep -q '127.0.0.1:8787'; then
  echo "    bound to 127.0.0.1:8787 (not exposed) ✓"
else
  echo "!! not listening on 127.0.0.1:8787"
  exit 1
fi

echo "==> health check"
curl -fsS http://127.0.0.1:8787/health && echo ""
echo "==> done"
