"""Portable cache-ring identity, shared by the coordinator and worker bootstrap."""

import hashlib
import re


def node_identity(url: str) -> str:
    """Remove authority userinfo without reserializing the host or path."""
    return re.sub(r"^(.*?://)[^/?#]*@", r"\1", url, count=1)


def cache_nodes(text: str) -> list[str]:
    """Normalize a comma/whitespace-separated ring, preserving the first occurrence of each URL."""
    by_identity: dict[str, str] = {}
    for url in re.split(r"[,\s]+", text.strip()):
        if url:
            url = url.rstrip("/")
            by_identity.setdefault(node_identity(url), url)
    nodes = list(by_identity.values())
    if not nodes or "" in nodes:
        raise ValueError("remote cache URL must not be empty")
    return nodes


def ranked_nodes(nodes: list[str], digest: str) -> list[str]:
    """Descending SHA256(identity + ':' + digest), then ascending identity, as in SML."""
    if len(nodes) == 1:
        return nodes
    scored = [(hashlib.sha256(f"{node_identity(url)}:{digest}".encode()).hexdigest(), node_identity(url), url)
              for url in nodes]
    return [url for _, _, url in sorted(scored, key=lambda item: (-int(item[0], 16), item[1]))]
