"""Test fixtures. Each test gets a fresh on-disk SQLite DB (WAL needs a file)."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# The timezone suites assert IST day-boundary behaviour specifically (that's
# the interesting case: IST != UTC by 5h30m). Pin it before app import —
# the deployment default is whatever HERMESNAG_DISPLAY_TZ says.
os.environ.setdefault("HERMESNAG_DISPLAY_TZ", "Asia/Kolkata")

TEST_TOKEN = "test-token-do-not-use-in-production"


@pytest.fixture(autouse=True)
def _fresh_db(monkeypatch):
    with tempfile.TemporaryDirectory() as tmp:
        db_path = os.path.join(tmp, "test.db")
        monkeypatch.setenv("HERMESNAG_DB", db_path)
        monkeypatch.setenv("HERMESNAG_TOKEN", TEST_TOKEN)

        from app import db as db_mod

        monkeypatch.setattr(db_mod, "DB_PATH", db_path)
        db_mod.reset_engine()
        db_mod.init_db()
        yield db_path
        db_mod.reset_engine()


@pytest.fixture
def session():
    from sqlmodel import Session

    from app.db import get_engine

    with Session(get_engine()) as s:
        yield s


@pytest.fixture
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    with TestClient(app) as c:
        c.headers.update({"Authorization": f"Bearer {TEST_TOKEN}"})
        yield c


@pytest.fixture
def anon_client():
    """No auth header — for testing the 401 path."""
    from fastapi.testclient import TestClient

    from app.main import app

    with TestClient(app) as c:
        yield c
