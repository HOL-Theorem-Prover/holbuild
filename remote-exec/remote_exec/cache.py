"""Portable cache-ring identity, shared by the coordinator and worker bootstrap."""

import hashlib
import re


def cache_nodes(text: str) -> list[str]:
    """Normalize a comma/whitespace-separated ring, preserving the first occurrence of each URL."""
    nodes = list(dict.fromkeys(url.rstrip("/") for url in re.split(r"[,\s]+", text.strip()) if url))
    if not nodes or "" in nodes:
        raise ValueError("remote cache URL must not be empty")
    return nodes


def ranked_nodes(nodes: list[str], digest: str) -> list[str]:
    """Descending SHA256(URL + ':' + digest), with ascending URL as the tie-break, as in SML."""
    if len(nodes) == 1:
        return nodes
    return sorted(nodes, key=lambda url: (-int(hashlib.sha256(f"{url}:{digest}".encode()).hexdigest(), 16), url))
