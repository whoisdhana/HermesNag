# Deployment

## Server (any Linux VPS)

```bash
make deploy BOX=<your-ssh-alias>   # rsync + install.sh: venv, token, systemd --user unit
```

`install.sh` generates the bearer token (printed once), writes `.env`, and
installs a hardened `systemd --user` unit bound to `127.0.0.1:8787`. Enable
lingering so it survives logout: `sudo loginctl enable-linger $USER`.
Nightly backups: register `deploy/backup-db.sh` with your scheduler.

Set `HERMESNAG_DISPLAY_TZ` in `.env` to your IANA zone (e.g. `Asia/Kolkata`).
Storage is always UTC; this only controls day boundaries and rendering.

## Mac app

```bash
security add-generic-password -a hermesnag -s hermesnag-token -w '<TOKEN>' -U
make install        # build, sign (ad-hoc), copy to /Applications, launch
```

Then Settings (gear in the widget footer): set **SSH host alias** to your
`~/.ssh/config` entry for the server. Enable *Start at login*.

## iPhone (optional)

Install Tailscale on the server and phone, then on the server:
`tailscale serve --bg --https=10003 http://127.0.0.1:8787` (tailnet-only
HTTPS). Set the resulting URL as **Phone base URL** in Settings and scan the
QR. See the README for the Scriptable home-screen widget and Siri shortcut.

## Agent integration (optional)

Any MCP-capable agent can drive the task list. Register
`hermes-tool/run-server.sh` as a local stdio MCP server (10 tools) and adapt
`hermes-tool/skill/SKILL.md` as its instructions. Schedule
`topup-nag-pool.sh` (nag copy), `due-notify.sh` (push channel) and the
morning/evening/weekly brief prompts with your agent's scheduler.
