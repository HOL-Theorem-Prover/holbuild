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


def preferred_identities(text: str | None) -> frozenset[str]:
    """Identities of the nodes in a HOLBUILD_REMOTE_CACHE_PREFERRED_URLS value; empty when it is unset or empty."""
    return frozenset(node_identity(url) for url in cache_nodes(text)) if text and text.strip() else frozenset()


def ranked_nodes(nodes: list[str], digest: str, preferred: frozenset[str] = frozenset()) -> list[str]:
    """Preferred nodes first, then the rest; each group by descending SHA256(identity + ':' + digest), then
    ascending identity, as in SML."""
    if len(nodes) == 1:
        return nodes
    scored = [(node_identity(url) not in preferred, -int(hashlib.sha256(f"{node_identity(url)}:{digest}".encode())
                                                             .hexdigest(), 16), node_identity(url), url)
              for url in nodes]
    return [url for *_, url in sorted(scored)]
