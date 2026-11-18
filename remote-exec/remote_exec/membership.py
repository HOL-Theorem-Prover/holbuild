"""Validated discovery snapshots: endpoints come from configuration, never from API-supplied credentials."""

import re
import socket
from dataclasses import dataclass, field
from urllib.parse import urlsplit

from remote_exec.cache import cache_nodes, node_identity

REFRESH_SECONDS = 30
STALE_SECONDS = 60


def credentialed_nodes(defaults: list[str], allowed: list[str]) -> dict[str, str]:
    """Preserve configured credentials; the deployment allowlist bounds who may receive them."""
    auth = re.match(r'^(.*?://)([^/?#]*@)', defaults[0])
    by_identity = {node_identity(url): url for url in defaults}
    for url in allowed:
        identity = node_identity(url)
        full = re.sub(r'^(.*?://)', lambda m: m[1] + auth[2], url, count=1) if auth and identity == url else url
        by_identity.setdefault(identity, full)
    return by_identity


def check_plain_http(defaults: list[str], allowed: list[str], curl_config: bool) -> None:
    """With credentials, inline or from a curl config, every endpoint discovery may select must be HTTPS."""
    if not curl_config and not any(urlsplit(url).username or urlsplit(url).password for url in defaults):
        return
    for url in [*defaults, *allowed]:
        if urlsplit(url).scheme != 'https':
            raise ValueError(f'cache credentials must not reach plain-HTTP endpoint {node_identity(url)}')


def parse_members(text: str, defaults: list[str], allowed: list[str]) -> list[str]:
    """Accept only configured identities, retaining every permanent node and local authentication."""
    lines = text.splitlines()
    if not lines or lines[0] != 'holbuild-cache-members-v1':
        raise ValueError('bad cache membership header')
    configured = credentialed_nodes(defaults, allowed)
    identities = lines[1:]
    if any(url != node_identity(url) or url not in configured for url in identities):
        raise ValueError('cache membership contained an unconfigured endpoint or credentials')
    if not {node_identity(url) for url in defaults}.issubset(identities):
        raise ValueError('cache membership omitted a permanent endpoint')
    return cache_nodes(','.join(configured[url] for url in identities))


def resolves(url: str) -> bool:
    """Whether this host can look up the endpoint's name now; IP literals always can."""
    try:
        socket.getaddrinfo(urlsplit(url).hostname, None)
    except (OSError, UnicodeError):
        return False
    return True


@dataclass
class Membership:
    """The last complete membership snapshot; a stale API falls back to the permanent configuration."""

    defaults: list[str]
    allowed: list[str]
    attempted: float = float('-inf')
    succeeded: float = float('-inf')
    members: list[str] = field(default_factory=list)

    def update(self, text: str, now: float, resolve: bool = False) -> None:
        """With resolve, leave out a member this host can't resolve yet (its resolver may cache the empty
        slot's NXDOMAIN for minutes after the member is published); a later refresh adds it."""
        members = parse_members(text, self.defaults, self.allowed)
        if resolve:
            permanent = {node_identity(url) for url in self.defaults}
            members = [url for url in members if node_identity(url) in permanent or resolves(url)]
        self.members = members
        self.succeeded = now

    def current(self, now: float) -> list[str]:
        return self.members if self.members and now - self.succeeded < STALE_SECONDS else self.defaults
