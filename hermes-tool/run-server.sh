#!/usr/bin/env bash
# Launcher for the HermesNag MCP server.
#
# Same shape as the box's existing local-tools/ilovepdf-mcp/run-server.sh —
# sources secrets from a file, then execs the server on stdio.
#
# The token is read from the task service's own .env rather than duplicated
# into Hermes's config, so rotating it in one place stays sufficient.
set -euo pipefail

APP_DIR="${HERMESNAG_APP_DIR:-$HOME/apps/hermes-nag}"
ENV_FILE="$APP_DIR/.env"
SERVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$ENV_FILE" ]]; then
  printf 'Missing HermesNag env file: %s\n' "$ENV_FILE" >&2
  exit 1
fi

# Export HERMESNAG_TOKEN / HERMESNAG_PORT from the service's env file.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

export HERMESNAG_URL="http://127.0.0.1:${HERMESNAG_PORT:-8787}"

exec python3 "$SERVER_DIR/server.py"
