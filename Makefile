# HermesNag
# Set BOX to your server's ~/.ssh/config alias: make deploy BOX=my-box

BOX      ?= hermesnag-server
APP_DIR  ?= apps/hermes-nag
PORT     ?= 8787
PY       := server/.venv/bin/python

.PHONY: help venv test deploy tunnel health logs restart status check-gateways check install release

check: ## Quality gate: ALL three suites (server, mac, MCP). Pre-push runs this.
	@echo "── server (pytest) ──────────────────────"
	cd server && .venv/bin/python -m pytest -p no:warnings -q
	@echo "── mcp tool (pytest) ────────────────────"
	cd hermes-tool && ../server/.venv/bin/python -m pytest test_server.py -p no:warnings -q
	@echo "── mac (swift-testing) ──────────────────"
	$(MAKE) -C mac test
	@echo "✓ all suites green"

install: ## Build, bundle, and install HermesNag.app to /Applications
	$(MAKE) -C mac bundle
	@pkill -f 'HermesNag.app/Contents/MacOS' 2>/dev/null || true
	rm -rf /Applications/HermesNag.app
	cp -R mac/.build/HermesNag.app /Applications/
	@echo "==> installed; launching"
	open /Applications/HermesNag.app

release: ## Stamp VERSION into the app bundle and rebuild
	@V=$$(cat VERSION); \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$V" mac/Resources/Info.plist; \
	echo "==> stamped $$V"; \
	$(MAKE) install

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

venv: ## Create the local dev venv
	cd server && python3 -m venv .venv && .venv/bin/pip install -q -e ".[dev]"

test: ## Run the server test suite
	cd server && .venv/bin/python -m pytest -p no:warnings

deploy: ## rsync the server to the box and (re)install the service
	rsync -az --delete \
		--exclude '.venv' --exclude '__pycache__' --exclude '*.db*' \
		--exclude '.pytest_cache' --exclude '.env' \
		server/ $(BOX):$(APP_DIR)/
	ssh $(BOX) 'chmod +x $(APP_DIR)/deploy/install.sh && $(APP_DIR)/deploy/install.sh'

tunnel: ## Foreground SSH tunnel for local debugging
	ssh -N -T \
		-o ExitOnForwardFailure=yes \
		-o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
		-o StrictHostKeyChecking=accept-new \
		-L 127.0.0.1:$(PORT):127.0.0.1:$(PORT) $(BOX)

health: ## Health check (needs the tunnel up)
	@curl -fsS http://127.0.0.1:$(PORT)/health | python3 -m json.tool

logs: ## Tail the service log on the box
	ssh $(BOX) 'journalctl --user -u hermes-nag -f -n 50'

restart: ## Restart the service on the box
	ssh $(BOX) 'systemctl --user restart hermes-nag && systemctl --user status hermes-nag --no-pager | head -12'

status: ## Service status on the box
	ssh $(BOX) 'systemctl --user status hermes-nag --no-pager | head -20; echo; ss -tln | grep $(PORT) || echo "not listening"'

check-gateways: ## Confirm we disturbed nothing that was already running
	@ssh $(BOX) 'systemctl --user list-units --type=service --state=running | grep -E "hermes-(gateway|dashboard)" | wc -l | xargs -I{} echo "{} pre-existing Hermes services running"'
