"""Membership transitions preserve configured credentials and the permanent fallback."""


import http.client
from urllib.parse import urlsplit

import httpx
import pytest
import sqlalchemy as sa
from conftest import CLIENT_TOKEN, WORKER_TOKEN
from test_cache_pool import Provider

from remote_exec import membership as membership_module
from remote_exec.auth import cache_discovery_token
from remote_exec.cache_pool import CachePool, CacheSlot
from remote_exec.membership import Membership, check_plain_http, parse_members, resolves
from remote_exec.worker import Coordinator, refresh_cache_members

DEFAULTS = ['https://ci:password@cache-a.example', 'https://ci:password@cache-b.example']
ALLOWED = ['https://cache-a.example', 'https://cache-b.example', 'https://cache-c.example']
SNAPSHOT = 'holbuild-cache-members-v1\nhttps://cache-a.example\nhttps://cache-b.example\nhttps://cache-c.example\n'


def test_discovery_reuses_local_credentials_only_for_configured_endpoints() -> None:
    assert parse_members(SNAPSHOT, DEFAULTS, ALLOWED) == [*DEFAULTS, 'https://ci:password@cache-c.example']
    with pytest.raises(ValueError, match='unconfigured'):
        parse_members(SNAPSHOT.replace('cache-c.example', 'attacker.example'), DEFAULTS, ALLOWED)
    with pytest.raises(ValueError, match='credentials'):
        parse_members(SNAPSHOT.replace('https://cache-c', 'https://bad:secret@cache-c'), DEFAULTS, ALLOWED)
    with pytest.raises(ValueError, match='omitted'):
        parse_members(SNAPSHOT.replace('https://cache-a.example\n', ''), DEFAULTS, ALLOWED)


def test_credentials_reach_new_endpoints_only_over_https() -> None:
    plain = ['http://cache-a.example', 'http://cache-c.example']
    with pytest.raises(ValueError, match='plain-HTTP endpoint http://cache-c.example'):
        check_plain_http(DEFAULTS, [*ALLOWED, 'http://cache-c.example'], curl_config=False)
    with pytest.raises(ValueError, match='plain-HTTP'):
        check_plain_http(['http://cache-a.example'], plain, curl_config=True)
    check_plain_http(DEFAULTS, ALLOWED, curl_config=True)
    check_plain_http(['http://cache-a.example'], plain, curl_config=False)
    with pytest.raises(ValueError, match='plain-HTTP endpoint http://cache-a.example'):
        check_plain_http(['http://ci:password@cache-a.example'], ['http://cache-a.example'], curl_config=False)


def test_discovery_keeps_complete_snapshots_and_expires_to_permanent_nodes() -> None:
    membership = Membership(DEFAULTS, ALLOWED)
    assert membership.current(0) == DEFAULTS
    membership.update(SNAPSHOT, 10)
    assert len(membership.current(69)) == 3
    with pytest.raises(ValueError):
        membership.update('garbage', 50)
    assert len(membership.current(69)) == 3
    assert membership.current(70) == DEFAULTS
    membership.update(SNAPSHOT.replace('https://cache-c.example\n', ''), 80)
    assert membership.current(80) == DEFAULTS


def test_resolution_checks_the_name_and_accepts_ip_literals() -> None:
    assert resolves('https://ci:password@localhost:8443/cache')
    assert resolves('https://127.0.0.1:1')
    assert resolves('https://[::1]:1')
    assert not resolves('https://cache-c.invalid')


def test_unresolvable_members_wait_for_a_later_refresh_and_then_join(monkeypatch) -> None:
    unresolvable = {'cache-a.example', 'cache-c.example'}
    monkeypatch.setattr(membership_module, 'resolves', lambda url: urlsplit(url).hostname not in unresolvable)
    membership = Membership(DEFAULTS, ALLOWED)
    membership.update(SNAPSHOT, 0, resolve=True)
    assert membership.current(0) == DEFAULTS  # permanent nodes stay, resolvable or not
    assert not membership.joining(0)
    unresolvable.clear()
    membership.update(SNAPSHOT, 30, resolve=True)
    assert membership.current(30) == [*DEFAULTS, 'https://ci:password@cache-c.example']
    assert membership.joining(30)


def test_worker_discovery_is_rate_limited_and_a_failure_does_not_disable_the_cache(monkeypatch) -> None:
    from unittest.mock import Mock

    monkeypatch.setattr(membership_module, 'resolves', lambda _url: True)
    coordinator = Coordinator('https://coordinator.example', 'worker-token')
    response = Mock()
    response.status = 200
    response.read.side_effect = lambda _: SNAPSHOT.encode()
    response.__enter__ = Mock(return_value=response)
    response.__exit__ = Mock(return_value=False)
    opener = Mock()
    opener.open.return_value = response
    monkeypatch.setattr(coordinator, 'opener', opener)
    membership = Membership(DEFAULTS, ALLOWED)
    url = coordinator.url + '/v1/cache/members'
    assert len(refresh_cache_members(coordinator, membership, url, 0)) == 3
    assert len(refresh_cache_members(coordinator, membership, url, 29)) == 3
    assert opener.open.call_count == 1
    request = opener.open.call_args.args[0]
    assert request.get_header('Authorization') == 'Bearer worker-token'
    opener.open.side_effect = OSError('coordinator down')
    assert len(refresh_cache_members(coordinator, membership, url, 30)) == 3
    assert refresh_cache_members(coordinator, membership, url, 60) == DEFAULTS


async def test_members_endpoint_auth_and_no_credentials_before_or_after_ready(http, coordinator) -> None:
    coordinator.settings.cache_url = ','.join(DEFAULTS)
    for token in [None, 'wrong', cache_discovery_token('wrong-worker'), cache_discovery_token(CLIENT_TOKEN)]:
        response = await http.get('/v1/cache/members', headers={'Authorization': f'Bearer {token}'})
        assert response.status_code == 401
    for token in [CLIENT_TOKEN, WORKER_TOKEN, cache_discovery_token(WORKER_TOKEN)]:
        response = await http.get('/v1/cache/members', headers={'Authorization': f'Bearer {token}'})
        assert response.status_code == 200
        assert 'ci:' not in response.text and 'password' not in response.text
        assert len(response.text.splitlines()) == 3
    p = Provider()
    pool = CachePool(coordinator.engine, [CacheSlot(name='c', url='https://cache-c.example')], p, drain_seconds=60)
    coordinator.cache_pool = pool
    async with coordinator.engine.begin() as conn:
        await conn.execute(sa.text('DELETE FROM cache_slots'))
        await conn.execute(sa.text("INSERT INTO cache_slots(slot,url,owner,phase) VALUES ('c',:url,'instance','ready')"),
                           {'url': 'https://cache-c.example'})
    response = await http.get('/v1/cache/members', headers={'Authorization': f'Bearer {CLIENT_TOKEN}'})
    assert len(response.text.splitlines()) == 3
    async with coordinator.engine.begin() as conn:
        await conn.execute(sa.text("UPDATE cache_slots SET phase='admit' WHERE slot='c'"))
    response = await http.get('/v1/cache/members', headers={'Authorization': f'Bearer {CLIENT_TOKEN}'})
    assert len(response.text.splitlines()) == 3
    async with coordinator.engine.begin() as conn:
        await conn.execute(sa.text("UPDATE cache_slots SET phase='serving' WHERE slot='c'"))
    response = await http.get('/v1/cache/members', headers={'Authorization': f'Bearer {WORKER_TOKEN}'})
    assert response.text == SNAPSHOT
    async with coordinator.engine.begin() as conn:
        await conn.execute(sa.text("UPDATE cache_slots SET phase='drain' WHERE slot='c'"))
    response = await http.get('/v1/cache/members', headers={'Authorization': f'Bearer {CLIENT_TOKEN}'})
    assert len(response.text.splitlines()) == 3
    slots = await http.get('/v1/cache/slots', headers={'Authorization': f'Bearer {CLIENT_TOKEN}'})
    assert slots.json() == [{'slot': 'c', 'url': 'https://cache-c.example', 'owner': 'instance', 'phase': 'drain', 'error': None}]


@pytest.mark.parametrize(("method", "path"), [
    ("GET", "/v1/cache/slots"),
    ("GET", "/v1/queue"),
    ("GET", "/v1/batches/00000000-0000-0000-0000-000000000000"),
    ("GET", "/v1/batches/00000000-0000-0000-0000-000000000000/events"),
    ("POST", "/v1/batches"),
    ("POST", "/v1/batches/00000000-0000-0000-0000-000000000000/cancel"),
    ("POST", "/v1/work/claim"),
    ("POST", "/v1/work/00000000-0000-0000-0000-000000000000/heartbeat"),
    ("POST", "/v1/work/00000000-0000-0000-0000-000000000000/complete"),
])
async def test_discovery_token_cannot_use_client_or_worker_routes(
    http: httpx.AsyncClient, method: str, path: str
) -> None:
    response = await http.request(method, path, headers={
        "Authorization": f"Bearer {cache_discovery_token(WORKER_TOKEN)}",
    }, json={"tier": "standard", "worker": "test"})
    assert response.status_code == 401


def test_join_grace_expires_without_steady_state_miss_amplification() -> None:
    defaults = ALLOWED[:2]
    all_nodes = [*defaults, *[f'https://cache-{n}.example' for n in range(3, 7)]]
    membership = Membership(defaults, all_nodes)
    membership.update('holbuild-cache-members-v1\n' + '\n'.join(all_nodes), 0)
    assert membership.joining(59)
    # A successful unchanged refresh keeps the ring but does not extend the join grace.
    membership.update('holbuild-cache-members-v1\n' + '\n'.join(all_nodes), 30)
    assert not membership.joining(60)


async def test_coordinator_reads_a_former_owner_below_rank_two_only_during_join_grace(coordinator, monkeypatch) -> None:
    import asyncio
    from unittest.mock import AsyncMock, Mock

    import httpx

    from remote_exec.cache import node_identity, ranked_nodes

    nodes = [f'https://cache-{n}.example' for n in range(1, 7)]
    coordinator.cache_nodes = nodes[:2]
    coordinator.membership = Membership(nodes[:2], nodes)
    coordinator.cache_pool = Mock(ready_urls=AsyncMock(return_value=nodes[2:]))
    key = 'new-entry'
    ranked = ranked_nodes(nodes, key)
    former = ranked[-1]
    asked = []
    other_status = [404]

    def handle(request: httpx.Request) -> httpx.Response:
        url = node_identity(str(request.url).removesuffix('/ac/' + key))
        asked.append(url)
        status = 404 if other_status[0] == 503 and url == ranked[2] else other_status[0]
        return httpx.Response(200 if url == former else status)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as cache:
        monkeypatch.setattr(coordinator, 'cache', cache)
        assert await coordinator._check_cache(key, asyncio.Semaphore(1)) is True
        assert len(asked) == 6
        coordinator.membership.joined -= 61
        asked.clear()
        assert await coordinator._check_cache(key, asyncio.Semaphore(1)) is False
        assert len(asked) == 2
        coordinator.cache_pool.ready_urls.assert_awaited_once()
        other_status[0] = 503
        asked.clear()
        assert await coordinator._check_cache(key, asyncio.Semaphore(1)) is True
        assert len(asked) == 6


def test_worker_spec_reads_all_members_in_join_grace_and_two_otherwise(monkeypatch) -> None:
    import subprocess
    from dataclasses import replace

    from remote_exec.cache import ranked_nodes
    from remote_exec.worker import Releases

    nodes = [f'https://cache-{n}.example' for n in range(1, 7)]
    key = 'new-spec'
    ranked = ranked_nodes(nodes, key)
    former = ranked[-1]
    asked = []
    other_status = [404]

    def curl(command: list[str], **_kwargs) -> subprocess.CompletedProcess:
        url = command[-1].removesuffix('/cas/' + key)
        asked.append(url)
        status = 404 if other_status[0] == 503 and url == ranked[2] else other_status[0]
        return subprocess.CompletedProcess(command, 0 if url == former else 22,
                                           stdout='holbuild-version=1.2.3\n200' if url == former else f'\n{status}', stderr='')

    monkeypatch.setattr(subprocess, 'run', curl)
    releases = Releases('unused', 'unused', ','.join(nodes), None, joining=True)
    assert releases.spec_version(key) == '1.2.3'
    assert len(asked) == 6
    asked.clear()
    with pytest.raises(RuntimeError):
        replace(releases, joining=False).spec_version(key)
    assert len(asked) == 2
    other_status[0] = 503
    asked.clear()
    assert replace(releases, joining=False).spec_version(key) == '1.2.3'
    assert len(asked) == 6


@pytest.mark.parametrize("error", [http.client.BadStatusLine("broken"), http.client.IncompleteRead(b"partial")])
def test_worker_protocol_failure_retains_then_expires_membership(monkeypatch, error) -> None:
    from unittest.mock import Mock

    coordinator = Coordinator("https://coordinator.example", "worker-token")
    monkeypatch.setattr(coordinator, "opener", Mock(open=Mock(side_effect=error)))
    membership = Membership(DEFAULTS, ALLOWED)
    membership.update(SNAPSHOT, 0)
    url = coordinator.url + "/v1/cache/members"
    assert len(refresh_cache_members(coordinator, membership, url, 30)) == 3
    assert refresh_cache_members(coordinator, membership, url, 60) == DEFAULTS


def test_recovered_discovery_restarts_join_grace_after_permanent_fallback() -> None:
    membership = Membership(DEFAULTS, ALLOWED)
    membership.update(SNAPSHOT, 0)
    assert membership.current(61) == DEFAULTS
    assert not membership.joining(61)
    membership.update(SNAPSHOT, 62)
    assert len(membership.current(62)) == 3
    assert membership.joining(62)
    membership.update(SNAPSHOT, 92)
    assert not membership.joining(122)
