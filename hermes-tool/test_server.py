"""MCP protocol tests — driven over real stdio, the way Hermes will drive it.

These deliberately spawn the server as a subprocess and speak JSON-RPC to it,
rather than importing and calling `handle()` directly. The failure mode that
matters is "Hermes can't talk to it", and only a real stdio round-trip proves
that. In-process tests would pass happily while the wire format was wrong.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

SERVER = Path(__file__).parent / "server.py"


class MCPClient:
    """Minimal MCP client: writes a request line, reads a response line."""

    def __init__(self, env: dict | None = None):
        full_env = {**os.environ, "HERMESNAG_URL": "http://127.0.0.1:59999", **(env or {})}
        self.proc = subprocess.Popen(
            [sys.executable, str(SERVER)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=full_env,
        )
        self._id = 0

    def call(self, method: str, params: dict | None = None) -> dict:
        self._id += 1
        request = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            request["params"] = params
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        assert line, "server closed stdout without responding"
        return json.loads(line)

    def notify(self, method: str) -> None:
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.proc.stdin.flush()

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


@pytest.fixture
def client():
    c = MCPClient()
    yield c
    c.close()


# --- handshake ---------------------------------------------------------------

def test_initialize_returns_server_info(client):
    resp = client.call("initialize", {
        "protocolVersion": "2025-11-25",
        "capabilities": {},
        "clientInfo": {"name": "test", "version": "1"},
    })
    result = resp["result"]
    assert result["serverInfo"]["name"] == "hermesnag"
    assert "tools" in result["capabilities"]


def test_initialize_echoes_client_protocol_version(client):
    """A newer or older Hermes must still negotiate successfully."""
    resp = client.call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}})
    assert resp["result"]["protocolVersion"] == "2024-11-05"


def test_notifications_get_no_response(client):
    """A notification has no id; replying to one corrupts the stream."""
    client.call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}})
    client.notify("notifications/initialized")
    # The next request must still line up correctly.
    resp = client.call("tools/list")
    assert "result" in resp


# --- tools -------------------------------------------------------------------

def test_tools_list_exposes_the_spec_tools(client):
    tools = {t["name"] for t in client.call("tools/list")["result"]["tools"]}
    # The spec names these explicitly.
    assert {"create_task", "list_tasks", "update_task", "complete_task", "write_nag"} <= tools


def test_every_tool_has_a_description_and_schema(client):
    for tool in client.call("tools/list")["result"]["tools"]:
        assert tool["description"].strip(), f"{tool['name']} has no description"
        assert tool["inputSchema"]["type"] == "object"


def test_create_task_schema_warns_about_naive_datetimes(client):
    """Correction C1 is the easiest thing for a model to get wrong, so the
    tool description has to spell it out."""
    tools = {t["name"]: t for t in client.call("tools/list")["result"]["tools"]}
    description = tools["create_task"]["description"].lower()
    assert "offset" in description
    assert "iso-8601" in description


def test_write_nag_documents_the_tone_per_level(client):
    tools = {t["name"]: t for t in client.call("tools/list")["result"]["tools"]}
    description = tools["write_nag"]["description"].lower()
    assert "playful" in description
    assert "never insult" in description


def test_unknown_tool_is_an_error(client):
    resp = client.call("tools/call", {"name": "nope", "arguments": {}})
    assert resp["error"]["code"] == -32602


def test_unknown_method_is_an_error(client):
    assert client.call("totally/unknown")["error"]["code"] == -32601


# --- failure handling --------------------------------------------------------

def test_unreachable_service_reports_a_tool_error_not_a_crash(client):
    """The fixture points at a dead port. A down task service must produce a
    readable tool error — if it killed the server, Hermes would lose every
    HermesNag tool until the gateway restarted."""
    resp = client.call("tools/call", {"name": "list_tasks", "arguments": {}})
    result = resp["result"]
    assert result["isError"] is True
    assert "cannot reach task service" in result["content"][0]["text"]


def test_server_survives_a_failed_call(client):
    client.call("tools/call", {"name": "list_tasks", "arguments": {}})
    # Still responsive afterwards.
    assert "result" in client.call("tools/list")


def test_missing_required_argument_is_reported(client):
    resp = client.call("tools/call", {"name": "complete_task", "arguments": {}})
    assert resp["result"]["isError"] is True
    assert "task_id" in resp["result"]["content"][0]["text"]


def test_malformed_json_does_not_kill_the_server():
    c = MCPClient()
    try:
        c.proc.stdin.write("this is not json\n")
        c.proc.stdin.flush()
        assert "result" in c.call("tools/list")
    finally:
        c.close()


def test_stdout_carries_only_json(client):
    """Logging to stdout would corrupt the protocol — logs must go to stderr."""
    resp = client.call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}})
    assert resp["jsonrpc"] == "2.0"
