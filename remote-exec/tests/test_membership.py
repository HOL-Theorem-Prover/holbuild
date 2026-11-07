"""Membership transitions preserve configured credentials and the permanent fallback."""


import pytest
import sqlalchemy as sa
from conftest import CLIENT_TOKEN, WORKER_TOKEN
from test_cache_pool import Provider

from remote_exec.cache_pool import CachePool, CacheSlot
from remote_exec.membership import Membership, parse_members
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


def test_worker_discovery_is_rate_limited_and_a_failure_does_not_disable_the_cache(monkeypatch) -> None:
    from unittest.mock import Mock

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
    for token in [None, 'wrong']:
        response = await http.get('/v1/cache/members', headers={'Authorization': f'Bearer {token}'})
        assert response.status_code == 401
    for token in [CLIENT_TOKEN, WORKER_TOKEN]:
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
    former = ranked_nodes(nodes, key)[-1]
    asked = []
    other_status = [404]

    def handle(request: httpx.Request) -> httpx.Response:
        url = node_identity(str(request.url).removesuffix('/ac/' + key))
        asked.append(url)
        return httpx.Response(200 if url == former else other_status[0])

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
    former = ranked_nodes(nodes, key)[-1]
    asked = []
    other_status = [404]

    def curl(command: list[str], **_kwargs) -> subprocess.CompletedProcess:
        url = command[-1].removesuffix('/cas/' + key)
        asked.append(url)
        return subprocess.CompletedProcess(command, 0 if url == former else 22,
                                           stdout='holbuild-version=1.2.3\n200' if url == former else f'\n{other_status[0]}', stderr='')

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
