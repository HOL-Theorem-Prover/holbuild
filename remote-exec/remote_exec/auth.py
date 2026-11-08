"""Credentials scoped to read-only cache discovery."""

import hmac


def cache_discovery_token(worker_token: str) -> str:
    """Derive a bearer accepted only by GET /v1/cache/members, without exposing its key."""
    return hmac.new(worker_token.encode(), b"holbuild-cache-members-v1", "sha256").hexdigest()
