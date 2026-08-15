"""SQLite engine in WAL mode.

WAL matters here because the SSE broadcaster and the scheduler read while the
API writes; the default rollback journal would serialize them behind a lock.
"""

from __future__ import annotations

import os
from collections.abc import Iterator

from sqlalchemy import event
from sqlalchemy.engine import Engine
from sqlmodel import Session, SQLModel, create_engine

DB_PATH = os.getenv("HERMESNAG_DB", "hermesnag.db")

_engine: Engine | None = None


def _configure_sqlite(dbapi_conn, _record) -> None:
    cur = dbapi_conn.cursor()
    cur.execute("PRAGMA journal_mode=WAL")
    cur.execute("PRAGMA foreign_keys=ON")
    cur.execute("PRAGMA synchronous=NORMAL")  # safe with WAL, much faster
    cur.execute("PRAGMA busy_timeout=5000")
    cur.close()


def get_engine() -> Engine:
    global _engine
    if _engine is None:
        url = DB_PATH if DB_PATH.startswith("sqlite") else f"sqlite:///{DB_PATH}"
        _engine = create_engine(
            url,
            echo=False,
            connect_args={"check_same_thread": False},
        )
        event.listen(_engine, "connect", _configure_sqlite)
    return _engine


def init_db() -> None:
    SQLModel.metadata.create_all(get_engine())


def get_session() -> Iterator[Session]:
    with Session(get_engine()) as session:
        yield session


def reset_engine() -> None:
    """Test helper: drop the cached engine so a new DB_PATH takes effect."""
    global _engine
    if _engine is not None:
        _engine.dispose()
    _engine = None
