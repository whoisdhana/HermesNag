"""Static bearer token.

Localhost binding is the real security boundary (the service never leaves
127.0.0.1). The token stops accidents — a stray curl, a misconfigured client —
not a determined attacker who already has a shell on the box.
"""

from __future__ import annotations

import hmac
import os

from fastapi import Header, HTTPException, status


def expected_token() -> str | None:
    token = os.getenv("HERMESNAG_TOKEN")
    return token or None


async def require_token(authorization: str | None = Header(default=None)) -> None:
    """Guard every route except /health."""
    expected = expected_token()

    if expected is None:
        # Fail closed. A missing token in production would otherwise silently
        # leave the API wide open to anything that reaches the port.
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"code": "server_misconfigured", "message": "HERMESNAG_TOKEN is not set"},
        )

    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "unauthorized", "message": "missing bearer token"},
            headers={"WWW-Authenticate": "Bearer"},
        )

    presented = authorization.split(" ", 1)[1].strip()
    # compare_digest: constant-time, avoids leaking the token via timing.
    if not hmac.compare_digest(presented, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "unauthorized", "message": "invalid bearer token"},
            headers={"WWW-Authenticate": "Bearer"},
        )
