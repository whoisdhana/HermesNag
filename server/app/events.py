"""SSE broadcaster.

Push is the primary path (spec: "Polling is the fallback, never the primary"),
so Hermes can create a task and have it appear on the Mac immediately.

Each subscriber gets its own bounded queue. Bounded matters: if a client stalls
(laptop asleep, tunnel wedged), an unbounded queue would grow until the box —
a 2-vCPU free-tier VM — felt it. On overflow we drop the oldest event; the
client resyncs via GET /tasks on reconnect.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

QUEUE_MAX = 100


class Broadcaster:
    def __init__(self) -> None:
        self._subscribers: set[asyncio.Queue] = set()
        self._lock = asyncio.Lock()
        # The server's main event loop, captured at startup. Sync endpoints
        # run in a threadpool where get_running_loop() raises — without this
        # handle, publish_soon() silently dropped every event. (Latent since
        # M1; unnoticed because nothing consumed the stream until the Mac
        # gained an SSE client.)
        self._loop: asyncio.AbstractEventLoop | None = None

    def attach(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop

    async def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=QUEUE_MAX)
        async with self._lock:
            self._subscribers.add(q)
        return q

    async def unsubscribe(self, q: asyncio.Queue) -> None:
        async with self._lock:
            self._subscribers.discard(q)

    async def publish(self, event: str, data: dict[str, Any]) -> None:
        payload = {"event": event, "data": data}
        async with self._lock:
            targets = list(self._subscribers)
        for q in targets:
            try:
                q.put_nowait(payload)
            except asyncio.QueueFull:
                # Drop oldest, keep newest: a live client cares about the
                # current state, not a backlog it slept through.
                try:
                    q.get_nowait()
                    q.put_nowait(payload)
                except (asyncio.QueueEmpty, asyncio.QueueFull):
                    pass

    def publish_soon(self, event: str, data: dict[str, Any]) -> None:
        """Fire-and-forget, safe from sync request handlers.

        Sync endpoints execute in a threadpool, so scheduling must hop to the
        main loop via call_soon_threadsafe. Falls back to get_running_loop for
        async callers; silently no-ops only when there's no loop at all
        (unit tests).
        """
        if self._loop is not None and not self._loop.is_closed():
            self._loop.call_soon_threadsafe(
                lambda: self._loop.create_task(self.publish(event, data))
            )
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return  # no loop (e.g. unit tests) — nothing to notify
        loop.create_task(self.publish(event, data))

    @property
    def subscriber_count(self) -> int:
        return len(self._subscribers)


broadcaster = Broadcaster()


def sse_format(event: str, data: dict[str, Any]) -> str:
    """Serialize one SSE frame."""
    return f"event: {event}\ndata: {json.dumps(data, default=str)}\n\n"
