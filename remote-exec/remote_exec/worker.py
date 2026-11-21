"""Remote-exec worker loop: claim an action, run ``holbuild exec-action`` on it, heartbeat, report the result.

Standard library only, so a worker needs just python3, curl, and what building holbuild and HOL takes:

    REMOTE_EXEC_WORKER_TOKEN=... HOLBUILD_CACHE=/var/cache/holbuild python3 -m remote_exec.worker \\
        --coordinator URL --remote-cache URL --cache-limit-gb N [--tier standard|high] [--max-heap MB] ...

Each action runs on the holbuild release that exported it, which the worker builds on first use.
"""

import argparse
import contextlib
import ctypes
import errno
import fcntl
import functools
import http.client
import itertools
import json
import math
import os
import random
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Iterator
from dataclasses import asdict, dataclass, field, replace
from typing import Any

from remote_exec.auth import cache_discovery_token
from remote_exec.cache import blob_key, cache_nodes, preferred_identities, ranked_nodes
from remote_exec.formats import SHA256, sanitize_detail
from remote_exec.membership import REFRESH_SECONDS, Membership, check_plain_http

DEFAULT_SOURCE_URL = "https://github.com/HOL-Theorem-Prover/holbuild/archive/refs/tags/v{version}.tar.gz"
RELEASE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
COMPLETE = ".complete"  # stamp file of a finished release build
MIN_SANDBOX_RELEASE = (0, 13, 58)
MIN_TOOLCHAIN_SANDBOX_RELEASE = (0, 14, 0)
MIN_AHEAD_RELEASE = (0, 14, 26)  # the first whose exec-action takes --ahead-parent
MIN_FREE_FLOOR_RELEASE = (0, 14, 57)  # the first whose exec-action takes --cache-min-free-gb
MIN_SWEEP_ONLY_RELEASE = (0, 14, 60)  # the first whose exec-action takes --sweep-only
MIN_PIPELINE_RELEASE = (0, 14, 75)  # the first whose exec-action takes --pipeline
CACHE_MIN_FREE_GB = 16  # the free space the cache cap keeps on the cache's disk for writers it doesn't count


@functools.cache
def check_sandbox(executable: str, version: str) -> None:
    """Fail closed before a release can execute submitted code. Runs with the environment its actions get, which
    release ``version`` validates."""
    subprocess.run(
        [executable, "sandbox-check"],
        check=True,
        stdin=subprocess.DEVNULL,
        timeout=30,
        env=exec_action_env(version=version),
    )


# How long each ECS scale-in protection call protects the task. ECS refuses renewals with DEPLOYMENT_BLOCKED once a
# service has more protected tasks than it wants (a scale-in or a rolling deployment), so the window set when the
# action was claimed must outlast the longest action. A dead worker still loses it: its container is the task's
# essential one, so the task stops with it, and the worker clears protection when an action ends or loses its lease.
PROTECTION_MINUTES = 180
CLAIM_RETRY_SECONDS = 5  # least time between two claims that found nothing
# Longest wait for a heartbeat or completion answer: above the coordinator's database pool timeout plus the work, so
# a request it accepted is answered rather than given up on and repeated.
REQUEST_TIMEOUT_S = 15.0
CHECKPOINT_PUBLISH_SECONDS = 15
# How often a running exec-action is checked for exit and for its result, and how often its HOL children are.
POLL_SECONDS = 0.1
HOL_SAMPLE_SECONDS = 1.0
# How long exec-action may go on publishing checkpoints for later actions after its result is reported. A large
# theory's publish takes up to ~30 s; past this a hung upload stops parking the worker.
POST_RESULT_SECONDS = 120.0
DRAIN_CHECKPOINT_PUBLISH_SECONDS = 8
# What exec-action runs with besides holbuild's own HOLBUILD_* settings: what curl, git and the locale read, and where
# HOL's libraries find external solvers (the action sandbox passes the same SOLVER_ENV on to HOL). The rest of the
# worker's environment, its coordinator token above all, stays out of the builds' environment.
SOLVER_ENV = (
    "HOL4_Z3_EXECUTABLE", "HOL4_CVC_EXECUTABLE", "HOL4_CSDP_EXECUTABLE", "HOL4_EPROVER_EXECUTABLE",
    "HOL4_VAMPIRE_EXECUTABLE", "HOL4_ZIPPERPOSITION_EXECUTABLE", "HOL4_JAVA_EXECUTABLE", "HOL4_KODKODI",
    "MINISAT_HOME",
)
EXEC_ACTION_ENV = (
    "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR", *SOLVER_ENV
)
PROXY_ENV = ("http_proxy", "https_proxy", "all_proxy", "no_proxy")  # in either case
# holbuild's --cooperate-dir admission, as in sml/machine_memory.sml: the --child-charge default caps a child's charge
# at this many MiB (default_charge_mb), and a lease this young still counts against MemAvailable (startup_seconds).
DEFAULT_CHARGE_MIB = 3072
STARTUP_SECONDS = 30
MEMORY_POLL_SECONDS = 2  # between two looks at the host's memory while waiting to claim
BOOT_ID = "/proc/sys/kernel/random/boot_id"  # one per host and boot, the same in every container on the host
MAX_HOST_RANK = 1000  # the coordinator's bound on a host's rank
PROC_STAT = "/proc/stat"
CPU_SAMPLE_SECONDS = 1.0  # least time a worker measures the host's idle CPU over
MIB = 2**20
GIB = 1024 * MIB
# Free space below which a worker doesn't claim, and puts an action that failed in it down to the full disk: room
# for one action's scratch, restored checkpoints and theory modules.
DISK_FLOOR = 4 * GIB
DISK_POLL_SECONDS = 10  # between two looks at the disk while waiting to claim


# What a request to the coordinator raises when it or the network fails; ValueError covers a reply that isn't JSON.
COORDINATOR_ERRORS = (OSError, RuntimeError, http.client.HTTPException, ValueError)
# Wait before retrying a heartbeat that failed, while the lease still holds; it doubles with each failure in a row, up
# to the heartbeat interval, and each wait is jittered, so a fleet facing an overloaded coordinator doesn't add to its
# load with retries in step.
HEARTBEAT_RETRY_SECONDS = 5.0
# Waits before each retry of a result report the coordinator couldn't take, as while it restarts; then 8 s apart.
COMPLETE_RETRY_DELAYS = (1.0, 2.0, 4.0, 8.0)


class DrainStopped(BaseException):
    """Stop an idle wait or preparation without treating shutdown as an action failure."""


class Drain:
    """One SIGTERM stops claims and gives the running action a fixed grace period."""

    def __init__(self, seconds: float = 20) -> None:
        self.seconds = seconds
        self.stop = threading.Event()
        self.wake = threading.Event()
        self.deadline: float | None = None
        self.interrupt = False
        self.publish_seconds = 0.0

    def request(self, *_: object) -> None:
        if self.deadline is not None:
            return
        self.deadline = time.monotonic() + self.seconds
        self.stop.set()
        self.wake.set()
        if self.interrupt:
            self.interrupt = False
            raise DrainStopped

    def remaining(self) -> float:
        return float("inf") if self.deadline is None else max(0.0, self.deadline - time.monotonic())

    @contextlib.contextmanager
    def interruptible(self) -> Iterator[None]:
        """Interrupt a blocking leaf call; cleanup outside this scope cannot be interrupted."""
        try:
            self.interrupt = True
            if self.stop.is_set():
                raise DrainStopped
            yield
        finally:
            self.interrupt = False

    @contextlib.contextmanager
    def installed(self) -> Iterator[None]:
        previous = signal.signal(signal.SIGTERM, self.request)
        try:
            yield
        finally:
            signal.signal(signal.SIGTERM, previous)


def stop_group(process: subprocess.Popen[Any]) -> None:
    """Terminate and reap our session, including descendants that outlive its leader."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
        time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)
    process.wait()


def kill_group(process: subprocess.Popen[Any]) -> None:
    """Kill our session at once, from another thread; the worker reaps it with ``stop_group``."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)


class ClaimRefused(RuntimeError):
    """The coordinator answered a claim with an error status."""


class Unreleased(Exception):
    """The action was exported by a holbuild version that has no release to build."""


class CacheUnavailable(RuntimeError):
    """The remote cache gave no answer, 429, 5xx or a transfer cut short, as while it restarts."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuses redirects, which would send the worker token to wherever they point."""

    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


class Coordinator:
    """The worker endpoints of the coordinator. Claims and heartbeats carry ``host``'s report, when given; with
    ``load_ahead``, claims also take actions whose parents still build (exec-action --ahead-parent)."""

    opener = urllib.request.build_opener(NoRedirect)

    def __init__(
        self, url: str, token: str, host: "HostTelemetry | None" = None, drain: Drain | None = None,
        *, load_ahead: bool = False,
    ) -> None:
        self.url = url.rstrip("/")
        self.token = token
        self.host = host
        self.drain = drain or Drain()
        self.load_ahead = load_ahead

    def post(self, path: str, body: bytes, content_type: str, timeout: float = 30) -> tuple[int, Any]:
        request = urllib.request.Request(
            self.url + path,
            data=body,
            method="POST",
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": content_type},
        )
        try:
            if path == "/v1/work/claim":
                with self.drain.interruptible():
                    response = self.opener.open(request, timeout=timeout)
            else:
                response = self.opener.open(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            # Long-poll timeout applies to headers only; a partially sent claim must not strand shutdown.
            http_response = response.fp if isinstance(response, urllib.error.HTTPError) else response
            http_response.fp.raw._sock.settimeout(min(timeout, 5))
            payload = response.read()
            if isinstance(response, urllib.error.HTTPError):
                return response.code, payload.decode(errors="replace")
            return response.status, json.loads(payload) if payload else None

    def post_reporting(self, path: str, body: dict[str, Any], timeout: float = 30) -> tuple[int, Any]:
        """``post`` a JSON body with the host's report in it, or only the host's id and rank when it can't be read
        now, since the coordinator quarantines and packs by them; or no host when the worker reports none."""
        host = None
        if self.host is not None:
            report = self.host.report()
            host = {"id": self.host.id, "rank": self.host.rank} if report is None else asdict(report)
        return self.post(path, json.dumps({**body, "host": host}).encode(), "application/json", timeout)

    def claim(self, tiers: list[str], worker: str, wait_s: float, phases: dict[str, float]) -> dict[str, Any] | None:
        """An action, waiting up to ``wait_s`` seconds for one, or None. ``phases`` reports where the worker's time
        went since its last claim."""
        body = {
            "tier": tiers[0], "also_claim": tiers[1:], "worker": worker, "wait_s": wait_s, "phases": phases,
        } | ({"ahead": True} if self.load_ahead else {})
        status, response = self.post_reporting("/v1/work/claim", body, 30 + wait_s)
        if status == 204:
            return None
        if status != 200:
            raise ClaimRefused(f"claim answered {status}: {response}")
        return response

    def report(self, tiers: list[str], worker: str) -> None:
        """Report the host while the worker isn't claiming, so the coordinator keeps knowing it and its workers. A
        coordinator without the endpoint (404) is no error."""
        body = {"tier": tiers[0], "also_claim": tiers[1:], "worker": worker}
        status, response = self.post_reporting("/v1/work/report", body, timeout=REQUEST_TIMEOUT_S)
        if status not in (204, 404):
            raise RuntimeError(f"host report answered {status}: {response}")

    def heartbeat(self, token: str) -> bool:
        status, body = self.post_reporting(f"/v1/work/{token}/heartbeat", {}, timeout=REQUEST_TIMEOUT_S)
        if status not in (200, 409):
            raise RuntimeError(f"heartbeat answered {status}: {body}")
        return status == 200

    def outlined(self, token: str) -> None:
        """Tell the coordinator the action published its outline, so that its children may be claimed ahead. A
        coordinator without the endpoint (404) is no error, nor one that can't be reached: the outline is only a
        head start."""
        try:
            status, body = self.post_reporting(f"/v1/work/{token}/outlined", {}, timeout=REQUEST_TIMEOUT_S)
        except COORDINATOR_ERRORS as error:
            print(f"could not report the outline: {error}", file=sys.stderr)
            return
        if status not in (204, 404):
            print(f"outline report answered {status}: {body}", file=sys.stderr)

    def complete(self, token: str, record: str, retry_s: float) -> None:
        """Report an action's result. A coordinator that can't be reached or answers 5xx, as while it restarts, is
        asked again for up to ``retry_s`` seconds, so the result isn't lost while the action's lease still holds."""
        deadline = time.monotonic() + retry_s
        delays = itertools.chain(COMPLETE_RETRY_DELAYS, itertools.repeat(COMPLETE_RETRY_DELAYS[-1]))
        while True:
            effective = deadline if self.drain.deadline is None else min(
                deadline, self.drain.deadline + self.drain.publish_seconds + 7
            )
            try:
                status, body = self.post(
                    f"/v1/work/{token}/complete", record.encode(), "text/plain",
                    min(REQUEST_TIMEOUT_S, max(0.1, effective - time.monotonic())),
                )
            except COORDINATOR_ERRORS as error:
                status, body = None, error
            if status == 200:
                return
            if status == 409:
                print(f"result dropped as stale: {body}", file=sys.stderr)
                return
            failure = f"complete failed: {body}" if status is None else f"complete answered {status}: {body}"
            delay = next(delays)
            effective = deadline if self.drain.deadline is None else min(
                deadline, self.drain.deadline + self.drain.publish_seconds + 7
            )
            if (status is not None and status < 500) or time.monotonic() + delay > effective:
                raise RuntimeError(failure)
            print(f"{failure}; retrying in {delay:g} s", file=sys.stderr)
            if self.drain.stop.is_set():
                time.sleep(delay)
            else:
                self.drain.stop.wait(delay)


class Protection:
    """Scale-in protection while the worker holds an action: ``--protection-cmd on|off``, or the ECS agent's
    task-protection endpoint when ``ECS_AGENT_URI`` is set, or nothing. Failures, such as ECS refusing protection
    with DEPLOYMENT_BLOCKED in a scale-in or a rolling deployment, are logged, never raised."""

    def __init__(self, command: str | None, ecs_agent_uri: str | None) -> None:
        self.command = command
        self.ecs_agent_uri = ecs_agent_uri

    def set(self, *, enabled: bool, timeout: float = 30) -> None:
        try:
            if self.command is not None:
                subprocess.run([*shlex.split(self.command), "on" if enabled else "off"], check=True, timeout=timeout)
            elif self.ecs_agent_uri is not None:
                body: dict[str, Any] = {"ProtectionEnabled": enabled}
                if enabled:
                    body["ExpiresInMinutes"] = PROTECTION_MINUTES
                request = urllib.request.Request(
                    self.ecs_agent_uri + "/task-protection/v1/state",
                    data=json.dumps(body).encode(),
                    method="PUT",
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    payload = json.load(response)
                if failure := payload.get("failure") or payload.get("error"):
                    raise RuntimeError(str(failure))
        except Exception as error:  # noqa: BLE001  # protection is best effort and must never stop an action
            print(f"setting scale-in protection to {enabled} failed: {error}", file=sys.stderr)


@dataclass(frozen=True)
class SpecHead:
    """What the worker reads of an action spec: the holbuild release that runs it, and its dependency context's key,
    which the worker reports with the result for the coordinator's placement (Coordinator._learn_locality)."""

    version: str
    deps_key: str | None


@dataclass(frozen=True)
class Releases:
    """Preinstalled releases from ``baked_root``, falling back to builds in ``<root>/v<version>`` from
    ``source_url`` with ``{version}`` filled in. Workers sharing ``root`` wait for one build per release."""

    root: str
    source_url: str
    remote_cache: str
    curl_config: str | None
    baked_root: str = field(default="/opt/holbuild-baked", kw_only=True)
    discovery_config: str | None = field(default=None, kw_only=True)
    drain: Drain = field(default_factory=Drain, kw_only=True, compare=False)

    def read_spec(self, spec_sha256: str) -> SpecHead:
        """The ``holbuild-version`` and ``deps-key`` of the action spec stored in the remote cache: under ``/cas/``,
        or as releases from 0.15.0 write it, zstd-compressed under ``/ac/``."""
        # Until clients move to 0.15.0, nearly every spec is under /cas/: asking /ac/ first would cost a miss on
        # every node.
        spec = self._fetch_spec(spec_sha256, f"cas/{spec_sha256}", spec_sha256)
        if spec is None:
            compressed = self._fetch_spec(spec_sha256, f"ac/{blob_key(spec_sha256)}", blob_key(spec_sha256))
            if compressed is None:
                raise RuntimeError(f"spec {spec_sha256} is missing from the remote cache: HTTP 404")
            # zstd checks the frame's checksum; exec-action checks the spec's digest when it fetches it.
            decoded = subprocess.run(["zstd", "-dcq"], input=compressed, check=False, capture_output=True)
            if decoded.returncode != 0:
                raise RuntimeError(f"spec {spec_sha256} in the remote cache is corrupt: {decoded.stderr.decode().strip()}")
            spec = decoded.stdout
        lines = spec.decode(errors="replace").splitlines()
        versions = [line.removeprefix("holbuild-version=") for line in lines if line.startswith("holbuild-version=")]
        if len(versions) != 1:
            raise RuntimeError(f"spec {spec_sha256} has {len(versions)} holbuild-version lines, expected 1")
        # exec-action checks the spec itself; a deps-key that isn't one line of a SHA-256 is only left unreported.
        deps_keys = [line.removeprefix("deps-key=") for line in lines if line.startswith("deps-key=")]
        deps_key = deps_keys[0] if len(deps_keys) == 1 and SHA256.fullmatch(deps_keys[0]) else None
        return SpecHead(versions[0], deps_key)

    def _fetch_spec(self, spec_sha256: str, path: str, digest: str) -> bytes | None:
        """The body at ``path`` on the first node ranked by ``digest`` that has it; None when every node answers
        404."""
        # -g: no URL globbing, whose errors print the URL with any credentials in it.
        # The status follows the body on its own line: 000 when there was no answer.
        nodes = cache_nodes(self.remote_cache)
        command = ["curl", "-fsSLg", "-w", "\n%{http_code}"]
        if len(nodes) == 1:
            command += ["--retry", "3"]
        else:
            command += ["--connect-timeout", "5", "--speed-limit", "1", "--speed-time", "30"]
        if self.curl_config is not None:
            command += ["-K", self.curl_config]
        unavailable: str | None = None
        preferred = preferred_identities(os.environ.get("HOLBUILD_REMOTE_CACHE_PREFERRED_URLS"))
        # Every node is asked before a miss: until a node has written a new spec through to the shared store, only
        # that node holds it.  A spec the client sent must be there, so a node that failed leaves it unavailable even
        # when another answered 404.
        for node in ranked_nodes(nodes, digest, preferred):
            # Not check=True: its error would print credentials in the command line.
            try:
                with self.drain.interruptible():
                    fetched = subprocess.run(
                        [*command, f"{node}/{path}"], check=False, capture_output=True, timeout=120
                    )
            except subprocess.TimeoutExpired:
                unavailable = f"fetching spec {spec_sha256} from the remote cache timed out"
                continue
            body, _, status = fetched.stdout.rpartition(b"\n")
            if fetched.returncode == 0:
                return body
            failure = f"fetching spec {spec_sha256} from the remote cache failed: {fetched.stderr.decode(errors='replace').strip()}"
            if fetched.returncode == 22 and status.startswith(b"4") and status != b"429":
                if status == b"404":
                    continue
                raise RuntimeError(failure)
            unavailable = failure
        if unavailable is not None:
            raise CacheUnavailable(unavailable)
        return None

    def holbuild(self, version: str) -> str:
        """The holbuild executable of release ``version``, built first if this host doesn't have it yet.

        Raises Unreleased when the version isn't a release or its source can't be found.
        """
        if not RELEASE.fullmatch(version):
            raise Unreleased(f"holbuild {version!r} is not a release version")
        if tuple(map(int, version.split("."))) < MIN_SANDBOX_RELEASE:
            raise Unreleased(f"holbuild {version} predates mandatory action isolation")
        baked = os.path.join(self.baked_root, f"v{version}", "bin", "holbuild")
        if os.path.isfile(baked) and os.access(baked, os.X_OK):
            check_sandbox(baked, version)
            return baked
        directory = os.path.join(self.root, f"v{version}")
        executable = os.path.join(directory, "bin", "holbuild")
        if os.path.exists(os.path.join(directory, COMPLETE)):
            check_sandbox(executable, version)
            return executable
        os.makedirs(self.root, exist_ok=True)
        with open(os.path.join(self.root, f"v{version}.lock"), "a") as lock:
            with self.drain.interruptible():
                fcntl.flock(lock, fcntl.LOCK_EX)
            if not os.path.exists(os.path.join(directory, COMPLETE)):
                self._build(version, directory)
        check_sandbox(executable, version)
        return executable

    def newest(self, minimum: tuple[int, int, int]) -> tuple[str, str] | None:
        """The version and executable of the newest release at or above ``minimum`` this host has, preinstalled or
        built, without building one; None if it has none."""
        found: dict[tuple[int, ...], tuple[str, str]] = {}
        for root, done in ((self.baked_root, os.path.join("bin", "holbuild")), (self.root, COMPLETE)):
            try:
                names = os.listdir(root)
            except OSError:
                continue
            for name in names:
                version = name.removeprefix("v")
                executable = os.path.join(root, name, "bin", "holbuild")
                if (
                    name.startswith("v") and RELEASE.fullmatch(version)
                    and tuple(map(int, version.split("."))) >= minimum
                    and os.path.exists(os.path.join(root, name, done)) and os.access(executable, os.X_OK)
                ):
                    found.setdefault(tuple(map(int, version.split("."))), (version, executable))
        return found[max(found)] if found else None

    def _build(self, version: str, directory: str) -> None:
        # holbuild finds its runtime sources where it was compiled, so it's built in the directory it runs from.
        shutil.rmtree(directory, ignore_errors=True)
        url = self.source_url.format(version=version)
        print(f"building holbuild {version} from {url}", file=sys.stderr, flush=True)
        with tempfile.TemporaryDirectory(dir=self.root) as scratch:
            archive = os.path.join(scratch, "source.tar.gz")
            try:
                with (
                    self.drain.interruptible(),
                    urllib.request.urlopen(url, timeout=300) as response,
                    open(archive, "wb") as file,
                ):
                    shutil.copyfileobj(response, file)
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    raise Unreleased(f"holbuild {version} has no release at {url}") from error
                raise
            except urllib.error.URLError as error:
                if isinstance(error.reason, FileNotFoundError):
                    raise Unreleased(f"holbuild {version} has no release at {url}") from error
                raise
            with self.drain.interruptible(), tarfile.open(archive) as tar:
                tar.extractall(scratch, filter="data")
            (top,) = [entry for entry in os.listdir(scratch) if entry != "source.tar.gz"]
            os.rename(os.path.join(scratch, top), directory)
        if self.drain.stop.is_set():
            raise DrainStopped
        process = subprocess.Popen(["make", "bin/holbuild"], cwd=directory, stdout=2, start_new_session=True)
        try:
            with self.drain.interruptible():
                if process.wait() != 0:
                    raise subprocess.CalledProcessError(process.returncode, process.args)
        finally:
            stop_group(process)
        with open(os.path.join(directory, COMPLETE), "w"):
            pass


def reserve(total: int) -> int:
    """What holbuild's default budget leaves out of MemTotal (``reserve`` in sml/machine_memory.sml)."""
    return max(GIB, min(total // 4, 30 * GIB))


@dataclass(frozen=True)
class HostMemory:
    """What holbuild's ``--cooperate-dir`` admission reads, in bytes: ``/proc/meminfo``, the dir's budget, and the
    charges of the leases held in it, all and those whose child is still starting, and how many leases are held.
    With no dir, only ``/proc/meminfo``."""

    total: int | None
    available: int | None
    budget: int | None
    reserved: int
    starting: int
    leases: int

    @classmethod
    def read(cls, directory: str | None, *, wait: bool = True) -> "HostMemory":
        """Read it now. Without ``wait``, raises BlockingIOError if a holbuild admission holds the dir's lock."""
        meminfo: dict[str, int] = {}
        with open(os.environ.get("HOLBUILD_TEST_MEMINFO", "/proc/meminfo")) as file:
            for line in file:
                match = re.fullmatch(r"(\w+):\s+(\d+) kB", line.strip())
                if match:
                    meminfo[match[1]] = int(match[2]) * 1024
        total = meminfo.get("MemTotal")
        budget = None if total is None else total - reserve(total)
        reserved = starting = leases = 0
        if directory is None:
            return cls(total, meminfo.get("MemAvailable"), budget, reserved, starting, leases)
        # Lease files are probed under DIR/lock, as holbuild scans them: a probe's flock on a lease another
        # process has just created, before it locks it, would make that process's admission fail.
        with contextlib.suppress(FileNotFoundError), open(os.path.join(directory, "lock")) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB)
            with contextlib.suppress(FileNotFoundError), open(os.path.join(directory, "budget")) as file:
                budget = int(file.read())
            for name in os.listdir(directory):
                if not name.startswith("lease-"):
                    continue
                with contextlib.suppress(FileNotFoundError), open(os.path.join(directory, name)) as lease:
                    try:
                        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        continue  # nobody holds it: its child is gone
                    except BlockingIOError:
                        pass
                    charge = int(lease.read())
                    reserved += charge
                    leases += 1
                    if time.time() - os.fstat(lease.fileno()).st_mtime < STARTUP_SECONDS:
                        starting += charge
        return cls(total, meminfo.get("MemAvailable"), budget, reserved, starting, leases)

    def shortfall(self, charge: int) -> str | None:
        """Why holbuild's admission (``acquire`` and ``live_shortfall`` in sml/machine_memory.sml) would hold back a
        child charged ``charge`` bytes now, or None if it would start it."""
        # With no lease held, holbuild starts a child that fits the budget whatever MemAvailable says, and fails one
        # that doesn't; with no budget, it fails too. Neither is worth waiting for.
        if self.reserved == 0 or self.budget is None:
            return None
        if self.reserved + charge > self.budget:
            return f"{self.reserved // MIB} of {self.budget // MIB} MiB reserved"
        if self.total is None or self.available is None:
            return None
        margin = min(reserve(self.total), max(GIB, self.total - self.budget))
        if self.available - self.starting < charge + margin:
            return (
                f"MemAvailable {self.available // MIB} MiB, less {self.starting // MIB} MiB for children "
                f"starting, is below {charge // MIB} MiB plus {margin // MIB} MiB kept free"
            )
        return None


def child_charge(max_heap: int | None) -> int:
    """The bytes holbuild charges a child by default: ``--max-heap``, at most DEFAULT_CHARGE_MIB."""
    return min(max_heap or DEFAULT_CHARGE_MIB, DEFAULT_CHARGE_MIB) * MIB


def wait_for_memory(directory: str, charge: int, drain: Drain | None = None) -> bool:
    """Return once holbuild's admission in ``directory`` would start a child charged ``charge`` bytes, so that a
    worker on a host whose memory is taken doesn't claim an action only to wait on it while other hosts could run it.
    A check, not a reservation: workers racing past it still wait in exec-action's own admission.

    Returns whether it waited."""
    logged = False
    if drain is not None and drain.stop.is_set():
        return False
    while (why := HostMemory.read(directory).shortfall(charge)) is not None:
        if not logged:
            print(f"waiting for memory before claiming: {why}", file=sys.stderr, flush=True)
            logged = True
        if drain is None:
            time.sleep(MEMORY_POLL_SECONDS)
        elif drain.stop.wait(MEMORY_POLL_SECONDS):
            break
    return logged


def file_system(path: str) -> os.statvfs_result:
    """The file system ``path`` is on, or would be created on."""
    path = os.path.abspath(path)
    while not os.path.exists(path):
        path = os.path.dirname(path)
    return os.statvfs(path)


def free_bytes(path: str) -> int:
    """Bytes an unprivileged writer has free on the file system ``path`` is on, or would be created on."""
    stat = file_system(path)
    return stat.f_bavail * stat.f_frsize


def disk_paths() -> list[str]:
    """Where an action needs disk: the temp dir, where the worker keeps its scratch, ``TMPDIR`` (else /tmp), where
    exec-action keeps its own (``tempfile`` falls back from an unwritable one), and the ``HOLBUILD_CACHE`` root, where
    exec-action's sandboxes and stores are."""
    paths = (tempfile.gettempdir(), os.environ.get("TMPDIR", "/tmp"), os.environ.get("HOLBUILD_CACHE"))
    return list(dict.fromkeys(path for path in paths if path))


def disk_shortfall() -> str | None:
    """Why the host's disk has no room for an action now, or None if it has: one of ``disk_paths`` has less than
    DISK_FLOOR free."""
    for path in disk_paths():
        if (free := free_bytes(path)) < DISK_FLOOR:
            return f"{path} has {free // MIB} MiB free, below {DISK_FLOOR // MIB} MiB"
    return None


def least_free_bytes() -> int:
    """Free bytes on the file system of ``disk_paths`` with the least free, the one ``disk_shortfall`` goes by."""
    return min(map(free_bytes, disk_paths()))


def remove_children(directory: str) -> None:
    """Delete everything in ``directory``, keeping it; a missing one has nothing to delete. HOL leaves read-only
    directories behind, which are made writable first."""
    def writable(function: Callable[..., Any], path: str, _: BaseException) -> None:
        os.chmod(os.path.dirname(path), 0o700)
        if function in (os.open, os.scandir):
            # A directory rmtree couldn't read (mode 000 or 300): it skipped it, so this removes it.
            os.chmod(path, 0o700)
            shutil.rmtree(path, onexc=writable)
        else:
            function(path)

    try:
        entries = list(os.scandir(directory))
    except FileNotFoundError:
        return
    for entry in entries:
        try:
            if entry.is_dir(follow_symlinks=False):
                shutil.rmtree(entry.path, onexc=writable)
            else:
                os.unlink(entry.path)
        except OSError as error:
            print(f"cleaning {entry.path} failed: {error}", file=sys.stderr)


def sweep_cache(releases: Releases, cache_limit_gb: int) -> None:
    """Evict from the cache root as exec-action does before an action, down to its cap and the free-space floor,
    with the newest release this host has that can do it without an action; none, and nothing is evicted."""
    if (release := releases.newest(MIN_SWEEP_ONLY_RELEASE)) is None:
        return
    version, holbuild = release
    command = [holbuild, "exec-action", "--sweep-only", "--cache-limit-gb", str(cache_limit_gb),
               "--cache-min-free-gb", str(CACHE_MIN_FREE_GB)]
    process = subprocess.Popen(command, env=exec_action_env(version=version), stdout=2, start_new_session=True)
    try:
        # A drain stops the sweep: the worker is idle, so it stops at once.
        with releases.drain.interruptible():
            returncode = process.wait(timeout=900)
    except subprocess.TimeoutExpired:
        print("sweeping the cache for disk space timed out", file=sys.stderr)
        return
    except DrainStopped:
        return
    finally:
        stop_group(process)
    if returncode != 0:
        print(f"sweeping the cache for disk space failed: exit {returncode}", file=sys.stderr)


def wait_for_disk(
    drain: Drain, coordinator: Coordinator, tiers: list[str], worker: str, sweep: Callable[[], None]
) -> None:
    """Return once the host's disk has room for an action (``disk_shortfall``), or the worker drains, so that a
    worker on a full disk doesn't claim action after action only to fail each at once while other hosts could run
    them. First the worker deletes what its own actions left in its cache root: the action sandboxes, temp files
    and the parked theories releases 0.14.79-0.14.83 left, which no other worker shares and no action of its own
    uses between claims, and the record of what its action root holds, which would no longer be true. Each poll it
    still waits it runs ``sweep``, the cache's own eviction of checkpoints and shared entries, and reports the host,
    so the coordinator keeps the host, its disk and its workers in view."""
    if disk_shortfall() is None:
        return
    cache = os.environ.get("HOLBUILD_CACHE")
    if cache:
        for records in ("action-resident", "parked-records", "parked-stats"):
            with contextlib.suppress(FileNotFoundError):
                os.unlink(os.path.join(cache, records))
        for directory in ("action", "parked", "action-parked", "tmp"):
            remove_children(os.path.join(cache, directory))
    logged = False
    while disk_shortfall() is not None:
        sweep()
        if drain.stop.is_set() or (why := disk_shortfall()) is None:
            return
        if not logged:
            print(f"waiting for disk space before claiming: {why}", file=sys.stderr, flush=True)
        try:
            coordinator.report(tiers, worker)
        except COORDINATOR_ERRORS as error:
            if not logged:
                print(f"reporting the host failed: {error}", file=sys.stderr)
        logged = True
        if drain.stop.wait(DISK_POLL_SECONDS):
            return


def full_disk(error: Exception) -> str | None:
    """Why an action that failed in the worker with ``error`` failed for want of disk, or None if it didn't: the
    error is ENOSPC, or the disk is short now (as when exec-action couldn't write its result record)."""
    why = disk_shortfall()
    if why is None and not (isinstance(error, OSError) and error.errno == errno.ENOSPC):
        return None
    return f"the worker's disk is full: {error}" + ("" if why is None else f"; {why}")


def cpu_times(stat_line: str) -> tuple[int, int]:
    """Idle and total time of all CPUs from the first line of /proc/stat. iowait isn't idle: a host whose cores
    wait on its disks has no room for more workers. guest and guest_nice are already counted in user and nice."""
    name, *fields = stat_line.split()
    if name != "cpu" or len(fields) < 8:
        raise ValueError(f"expected the cpu line of /proc/stat, got {stat_line!r}")
    times = [int(f) for f in fields[:8]]
    return times[3], sum(times)


@dataclass(frozen=True)
class HostReport:
    """A worker's report of its host to the coordinator; memory in bytes as in HostMemory, ``memory_short`` when
    admission would hold a child back now or held this worker back since its last report, and the host's ``rank``
    (``--host-rank``)."""

    id: str
    cpu_idle_pct: float | None  # since the CPU sample it was last measured from, None under CPU_SAMPLE_SECONDS ago
    mem_total: int | None
    mem_available: int | None
    budget: int | None
    reserved: int
    leases: int
    memory_short: bool
    rank: int
    disk_free: int  # bytes free on the disk ``disk_shortfall`` goes by


class HostTelemetry:
    """What a worker reports of its host with each claim and heartbeat, which come from two threads."""

    def __init__(self, cooperate_dir: str | None, charge: int, rank: int = 0) -> None:
        with open(BOOT_ID) as file:
            self.id = file.read().strip()
        self.rank = rank
        self.cooperate_dir = cooperate_dir
        self.charge = charge
        self.lock = threading.Lock()
        self.cpu: tuple[float, int, int] | None = None  # when, idle and total of the CPU sample measured from
        self.waited = False  # whether wait_for_memory held the worker back since the last report

    def report(self) -> HostReport | None:
        """The host now, or None when it can't be read now. It doesn't wait for the cooperate dir's lock, which
        would hold up the heartbeat that renews a running action's lease: while an admission holds it, there is no
        reading."""
        try:
            memory = HostMemory.read(self.cooperate_dir, wait=False)
            with open(PROC_STAT) as file:
                idle, total = cpu_times(file.readline())
            disk_free = least_free_bytes()
        except (OSError, ValueError) as error:
            if not isinstance(error, BlockingIOError):
                print(f"reading the host for the coordinator failed: {error}", file=sys.stderr)
            return None
        now = time.monotonic()
        with self.lock:
            waited, self.waited = self.waited, False
            idle_pct = None
            if self.cpu is None or now - self.cpu[0] >= CPU_SAMPLE_SECONDS:
                # The kernel's iowait count can go backwards (Documentation/filesystems/proc.rst), so a share
                # outside 0-100 is no measurement.
                if self.cpu is not None and total > self.cpu[2] and 0 <= idle - self.cpu[1] <= total - self.cpu[2]:
                    idle_pct = round(100 * (idle - self.cpu[1]) / (total - self.cpu[2]), 1)
                self.cpu = (now, idle, total)
        return HostReport(
            self.id,
            idle_pct,
            memory.total,
            memory.available,
            memory.budget,
            memory.reserved,
            memory.leases,
            memory.shortfall(self.charge) is not None or waited,
            self.rank,
            disk_free,
        )


class Phases:
    """The seconds this worker spent in each phase since it last reported them (``PhaseReport`` in the
    coordinator). Between them they cover its time: waiting for memory, claiming, sleeping after a claim got
    nothing or an action failed in the worker, finding the action's release, running exec-action (before, while
    and after it has HOL children, or all of it as ``exec`` when they can't be seen) and reporting the result."""

    NAMES = ("memory_wait", "claim", "idle", "lease", "release", "before_hol", "hol", "after_hol", "exec", "complete", "after_result")

    def __init__(self) -> None:
        self.seconds = dict.fromkeys(self.NAMES, 0.0)

    def add(self, name: str, seconds: float) -> None:
        self.seconds[name] += seconds

    @contextlib.contextmanager
    def timed(self, name: str) -> Iterator[None]:
        started = time.monotonic()
        try:
            yield
        finally:
            self.add(name, time.monotonic() - started)

    def take(self) -> dict[str, float]:
        """The seconds so far, rounded, starting again from none."""
        taken = {name: round(seconds, 3) for name, seconds in self.seconds.items()}
        self.seconds = dict.fromkeys(self.NAMES, 0.0)
        return taken

    def put_back(self, taken: dict[str, float]) -> None:
        """Add what ``take`` returned back in, when it couldn't be reported."""
        for name, seconds in taken.items():
            self.add(name, seconds)


class ExecSpans:
    """Splits exec-action's time, given in steps of the 1 s poll, into before its first HOL child, from then to
    the end of its last one, and after. A gap between two HOL children counts as HOL, a child seen only once gets
    its poll step."""

    def __init__(self) -> None:
        self.before_hol = self.hol = self.after_hol = 0.0

    def step(self, seconds: float, *, hol: bool) -> None:
        if hol:
            self.hol += self.after_hol + seconds
            self.after_hol = 0.0
        elif self.hol:
            self.after_hol += seconds
        else:
            self.before_hol += seconds


def child_pids(pid: int) -> list[int]:
    """The children of process ``pid``, none once it's gone."""
    children: list[int] = []
    with contextlib.suppress(OSError):
        for task in os.listdir(f"/proc/{pid}/task"):
            with contextlib.suppress(OSError), open(f"/proc/{pid}/task/{task}/children") as file:
                children += [int(child) for child in file.read().split()]
    return children


def runs_hol(pid: int, cooperate_dir: str) -> bool:
    """Whether a descendant of process ``pid`` holds a lease of ``cooperate_dir`` (canonical) open: a HOL child,
    which inherits the lease holbuild's admission took for it. Process ``pid`` itself also opens other workers'
    leases while it reads them, so it isn't looked at."""
    prefix = os.path.join(cooperate_dir, "lease-")
    pending = child_pids(pid)
    while pending:
        descendant = pending.pop()
        with contextlib.suppress(OSError):
            fds = f"/proc/{descendant}/fd"
            for fd in os.listdir(fds):
                with contextlib.suppress(OSError):
                    if os.readlink(os.path.join(fds, fd)).startswith(prefix):
                        return True
        pending += child_pids(descendant)
    return False


# The detail of an action the worker gives back unstarted because it is draining.
DRAINING = "the worker is draining"


def with_deps_key(record: str, deps_key: str | None) -> str:
    """``record`` with the spec's ``deps-key`` added, when the worker read one."""
    if deps_key is None:
        return record
    separator = "" if record.endswith("\n") else "\n"
    return f"{record}{separator}deps-key={deps_key}\n"


def failed_record(spec_sha256: str, failure: str, detail: str | None = None) -> str:
    """A result record the worker writes itself: ``spec-rejected`` for an action it won't run, which fails it
    finally like exec-action's own; ``unavailable`` for one whose spec the cache couldn't give (no answer, 429 or
    5xx, or a transfer cut short), that was interrupted (``recordless_failure``) or that the host's disk had no room
    for (``full_disk``), which is retried without counting the attempt; ``memory`` for one whose exec-action was
    SIGKILLed; or ``internal`` for any other error in the worker, such as exec-action failing without a record,
    which is retried. ``detail`` says why, for the client:
    the record has no log."""
    record = f"holbuild-action-result-v1\nspec={spec_sha256}\ninput-key=\nstatus=failed\nfailure={failure}\n"
    return record if detail is None else f"{record}detail={sanitize_detail(detail)}\n"


def recordless_failure(returncode: int, draining: bool) -> tuple[str, str] | None:
    """The failure, and its detail, to report for an exec-action that exited ``returncode`` without writing its
    result record, or None for an error in the worker (``internal``). One stopped while the worker drains, or by
    SIGTERM or SIGINT (a host shutting down, as on a Spot reclaim), was interrupted: ``unavailable`` refunds the
    attempt. One killed by SIGKILL otherwise is what the kernel's OOM killer does: ``memory``."""
    def by(*signals: int) -> bool:
        return any(returncode in (-s, 128 + s) for s in signals)

    if draining:
        return "unavailable", f"the worker drained; exec-action exited {returncode} without a result"
    for stop in (signal.SIGTERM, signal.SIGINT):
        if by(stop):
            return "unavailable", f"exec-action was stopped by {stop.name} without a result"
    if by(signal.SIGKILL):
        return "memory", "exec-action was killed by SIGKILL without a result, as by the kernel's OOM killer"
    return None


def exec_action_env(*, version: str, discovery_config: str | None = None) -> dict[str, str]:
    env = {
        name: value
        for name, value in os.environ.items()
        if (name in EXEC_ACTION_ENV or name.lower() in PROXY_ENV or name.startswith("HOLBUILD_"))
        and name not in ("HOLBUILD_REMOTE_CACHE_DISCOVERY_TOKEN", "HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG")
        and not name.startswith("HOLBUILD_REMOTE_EXEC_")
    }
    if discovery_config is not None:
        env["HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG"] = discovery_config
    if tuple(map(int, version.split("."))) < MIN_TOOLCHAIN_SANDBOX_RELEASE:
        name = "HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES"
        entries = env.get(name, "").split()
        if "*" in entries:
            remaining = [entry for entry in entries if entry != "*"]
            if remaining:
                env[name] = " ".join(remaining)
            else:
                # Older clients lack toolchain confinement; retain their canonical HOL default.
                del env[name]
    return env


def exec_action_command(
    args: argparse.Namespace, holbuild: str, version: str, spec: str, result: str, max_heap_mb: int | None,
    ahead_parents: list[dict[str, str]], *, pipeline: bool = False,
) -> list[str]:
    command = [holbuild, "--remote-cache", args.remote_cache]
    command += ["--max-heap", str(args.max_heap if max_heap_mb is None else max_heap_mb)]
    if args.cooperate_dir is not None:
        command += ["--cooperate-dir", args.cooperate_dir]
    command += ["exec-action", spec, "--cache-limit-gb", str(args.cache_limit_gb)]
    if tuple(map(int, version.split("."))) >= MIN_FREE_FLOOR_RELEASE:
        command += ["--cache-min-free-gb", str(CACHE_MIN_FREE_GB)]
    command += ["--result", result]
    if args.share_heaps:
        command.append("--share-heaps")
    if pipeline and tuple(map(int, version.split("."))) >= MIN_PIPELINE_RELEASE:
        command.append("--pipeline")
    for parent in ahead_parents:
        command += ["--ahead-parent", f"{parent['input_key']}:{parent['spec_sha256']}"]
    return command


class Lease:
    """Heartbeats an action's lease from a thread while the action runs and its result is posted, and holds scale-in
    protection. A lease the coordinator can't renew is lost once it may have expired there."""

    def __init__(
        self, coordinator: Coordinator, token: str, lease_s: float, protection: Protection,
        *, claimed: float | None = None,
    ) -> None:
        self.coordinator = coordinator
        self.token = token
        self.lease_s = lease_s
        self.interval = max(1.0, lease_s / 3)
        # The coordinator expires the lease lease_s after it took the claim or after the last heartbeat that renewed
        # it, each after its request was sent: ``claimed``, by default now, is when the claim's was.
        self.expires = (time.monotonic() if claimed is None else claimed) + lease_s
        self.protection = protection
        self.lost = threading.Event()
        self.completing = threading.Event()  # the result is being posted: a stale lease no longer stops anything
        self.checking = threading.Lock()
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._beat, daemon=True)

    @contextlib.contextmanager
    def held(self, phases: Phases) -> Iterator["Lease"]:
        """Holds the lease, adding the time taking and giving it up blocks for to ``phases``' ``lease``."""
        with phases.timed("lease"):
            if not self.coordinator.drain.stop.is_set():
                self.protection.set(enabled=True, timeout=5)
            self.thread.start()
        try:
            yield self
        finally:
            self.done.set()
            with phases.timed("lease"):
                deadline = self.coordinator.drain.deadline
                self.thread.join(timeout=None if deadline is None else max(
                    0.0, deadline + self.coordinator.drain.publish_seconds + 7 - time.monotonic()
                ))
                self.protection.set(enabled=False, timeout=30 if deadline is None else 2)

    def check(self) -> bool:
        """Whether the lease is lost, marking it lost once it may have expired at the coordinator before the result
        is posted. The action's poll calls this too, so a heartbeat blocked on an unresponsive coordinator doesn't
        hold the action past the deadline."""
        with self.checking:
            if not self.lost.is_set() and not self.completing.is_set() and time.monotonic() >= self.expires:
                print("lease ran out without a renewal; stopping the action", file=sys.stderr)
                self._lose()
        return self.lost.is_set()

    def _beat(self) -> None:
        wait = self.interval
        retry = HEARTBEAT_RETRY_SECONDS
        while not self.check():
            left = self.expires - time.monotonic()
            if self.done.wait(wait if left <= 0 or self.completing.is_set() else min(wait, left)):
                return
            if self.check():
                return
            sent = time.monotonic()
            try:
                alive = self.coordinator.heartbeat(self.token)
            except COORDINATOR_ERRORS as error:
                wait = min(retry, self.interval) * random.uniform(0.5, 1.0)
                retry *= 2
                print(f"heartbeat failed, retrying in {wait:.1f} s: {error}", file=sys.stderr)
                continue
            if not alive:
                # A heartbeat that crossed the posted result finds its token spent: the lease ended as it should.
                if not self.completing.is_set():
                    print("lease lost; stopping the action", file=sys.stderr)
                    self._lose()
                return
            with self.checking:
                if self.lost.is_set():
                    return
                self.expires = sent + self.lease_s
            wait = self.interval
            retry = HEARTBEAT_RETRY_SECONDS
            if not self.done.is_set() and not self.coordinator.drain.stop.is_set():
                self.protection.set(enabled=True, timeout=5)

    def _lose(self) -> None:
        self.lost.set()
        self.coordinator.drain.wake.set()


def claim_reporting(
    coordinator: Coordinator, tiers: list[str], worker: str, wait_s: float, phases: Phases
) -> dict[str, Any] | None:
    """``Coordinator.claim``, reporting ``phases`` with it, or None when the claim failed. The phases reported
    start again once the coordinator answered, even with an error, since it has them then."""
    report = phases.take()
    try:
        with phases.timed("claim"):
            return coordinator.claim(tiers, worker, wait_s, report)
    except COORDINATOR_ERRORS as error:
        print(f"claim failed: {error}", file=sys.stderr)
        if not isinstance(error, ClaimRefused):
            phases.put_back(report)
        return None
    except DrainStopped:
        return None


def run_one(
    coordinator: Coordinator,
    args: argparse.Namespace,
    releases: Releases,
    protection: Protection,
    claim: dict[str, Any],
    phases: Phases,
    *,
    claimed: float | None = None,
) -> bool:
    """Run one claimed action to its end, or until its lease is lost, and report it, adding its phases' time to
    ``phases``. An error in the worker is reported for a retry and then raised, so that ``main`` waits before it
    claims again. True when exec-action reported the remote cache ``unavailable``, after which ``main`` waits too.
    ``claimed`` is when the claim's request was sent (``time.monotonic()``), by default now."""
    token = claim["attempt_token"]
    spec = claim["spec_sha256"]
    drain = coordinator.drain
    releases = replace(releases, drain=drain)
    # Coordinators before 0.14.80 don't name the batch.
    batch = f" in batch {claim['batch_id']}" if "batch_id" in claim else ""
    print(f"running {claim['theory']} ({claim['input_key']}){batch}", file=sys.stderr, flush=True)
    with Lease(coordinator, token, claim["lease_s"], protection, claimed=claimed).held(phases) as lease:
        completed = False

        def report(record: str) -> None:
            """Completes the action once, even if posting it fails: the coordinator then retries it when the
            worker claims again or the lease expires. The heartbeat goes on while the result is posted, so the lease
            doesn't lapse while the coordinator restarts, and stops once it is: the token is spent then. Scale-in
            protection stays on until exec-action exits."""
            nonlocal completed
            completed = True
            lease.completing.set()
            try:
                with phases.timed("complete"):
                    coordinator.complete(token, with_deps_key(record, claim.get("deps_key")), claim["lease_s"])
            finally:
                lease.done.set()

        try:
            record = execute(args, releases, lease, claim, phases, report)
        except CacheUnavailable as error:
            # The cache couldn't give the spec, as while it restarts: the action is retried without counting it.
            if not completed:
                report(failed_record(spec, "unavailable", str(error)))
            raise
        except Exception as error:
            # The coordinator retries the action now rather than when the lease expires. One the disk had no room
            # for doesn't count as an attempt: the worker waits for space before it claims again, so it goes to
            # another host.
            if not completed:
                full = full_disk(error)
                report(failed_record(spec, "internal") if full is None else failed_record(spec, "unavailable", full))
            raise
        if record is None:
            return False
        if not completed:
            report(record)
        return "failure=unavailable" in record.splitlines()


def read_result(path: str) -> str | None:
    """exec-action's result record, once it has written one; it renames it into place whole."""
    try:
        with open(path) as file:
            return file.read() or None
    except FileNotFoundError:
        return None


def execute(
    args: argparse.Namespace,
    releases: Releases,
    lease: Lease,
    claim: dict[str, Any],
    phases: Phases,
    report: Callable[[str], None],
) -> str | None:
    """The result record of the claimed action, or None once its lease is lost. A record exec-action writes
    while it runs is passed to ``report`` at once; the record returned is then that one. One it writes as it
    stops for a lost lease is reported too, for the log of the action it stopped."""
    spec = claim["spec_sha256"]
    drain = releases.drain
    drain.publish_seconds = 0.0
    if drain.stop.is_set():
        return failed_record(spec, "unavailable", DRAINING)
    ahead_parents = claim.get("ahead_parents", [])
    try:
        with phases.timed("release"):
            head = releases.read_spec(spec)
            version = head.version
            claim["deps_key"] = head.deps_key
            if drain.stop.is_set():
                return failed_record(spec, "unavailable", DRAINING)
            if ahead_parents and RELEASE.fullmatch(version) and tuple(map(int, version.split("."))) < MIN_AHEAD_RELEASE:
                return failed_record(spec, "ahead-abandoned", f"holbuild {version} predates loading ahead")
            holbuild = releases.holbuild(version)
    except DrainStopped:
        return failed_record(spec, "unavailable", DRAINING)
    except Unreleased as error:
        print(f"refusing {spec}: {error}", file=sys.stderr)
        return failed_record(spec, "spec-rejected", f"the worker refuses the action: {error}")
    if lease.check():
        return None
    if drain.stop.is_set():
        return failed_record(spec, "unavailable", DRAINING)
    with tempfile.TemporaryDirectory() as scratch:
        result = os.path.join(scratch, "result")
        # Its own session, so a lost lease stops holbuild's HOL children with it.
        cooperate_dir = None if args.cooperate_dir is None else os.path.realpath(args.cooperate_dir)
        spans = ExecSpans()
        stepped = time.monotonic()
        process = subprocess.Popen(
            exec_action_command(
                args, holbuild, version, spec, result, claim.get("max_heap_mb"), ahead_parents,
                pipeline=claim.get("pipeline", False),
            ),
            env=exec_action_env(version=version, discovery_config=releases.discovery_config),
            start_new_session=True
        )
        drained_out = lost = False
        # exec-action writes its result (atomically) before publishing for later actions; it is reported then,
        # and the worker waits for the rest without the lease, at most POST_RESULT_SECONDS.
        reported: str | None = None
        seen = after_result = 0.0
        # The bound holds while the result is being posted too, which retries for as long as the lease.
        hard_stop: threading.Timer | None = None
        sampled = stepped
        # exec-action --pipeline creates it once it published the action's outline.
        outline = result + ".outline"
        told_outline = False
        try:
            while process.poll() is None:
                if reported is None:
                    if lease.check():
                        lost = True
                        break
                    if not told_outline and os.path.exists(outline):
                        told_outline = True
                        threading.Thread(target=lease.coordinator.outlined, args=(lease.token,), daemon=True).start()
                    if (record := read_result(result)) is not None:
                        now = time.monotonic()
                        if cooperate_dir is None:
                            phases.add("exec", now - stepped)
                        else:
                            spans.step(now - stepped, hol=False)
                        stepped = seen = now
                        hard_stop = threading.Timer(POST_RESULT_SECONDS, kill_group, (process,))
                        hard_stop.daemon = True
                        hard_stop.start()
                        report(record)
                        reported = record
                        stepped = after_result = time.monotonic()
                        continue
                elif time.monotonic() - seen >= POST_RESULT_SECONDS:
                    print(f"{claim['theory']}: exec-action still running {POST_RESULT_SECONDS:.0f} s after its result; "
                          "stopping it", file=sys.stderr, flush=True)
                    break
                if drain.remaining() == 0:
                    drained_out = reported is None and process.poll() is None
                    break
                drain.wake.clear()
                drain.wake.wait(min(POLL_SECONDS, drain.remaining()))
                # HOL is sampled once a second, as walking /proc each poll would cost more than it tells.
                now = time.monotonic()
                if reported is None and cooperate_dir is not None and now - sampled >= HOL_SAMPLE_SECONDS:
                    spans.step(now - stepped, hol=runs_hol(process.pid, cooperate_dir))
                    stepped = sampled = now
        finally:
            if hard_stop is not None:
                hard_stop.cancel()
            timed_out = seen > 0 and time.monotonic() - seen >= POST_RESULT_SECONDS
            if process.poll() is None and not timed_out:
                drain.publish_seconds = DRAIN_CHECKPOINT_PUBLISH_SECONDS
                # Signal only the driver: it stops HOL, uploads the log, writes its record and then publishes
                # the sandbox-validated saves. Killing its group here loses them.
                with contextlib.suppress(ProcessLookupError):
                    process.send_signal(signal.SIGTERM)
                deadline = time.monotonic() + CHECKPOINT_PUBLISH_SECONDS
                while process.poll() is None:
                    effective = deadline if drain.deadline is None else min(
                        deadline, drain.deadline + drain.publish_seconds
                    )
                    remaining = effective - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        process.wait(timeout=min(0.1, remaining))
                    except subprocess.TimeoutExpired:
                        pass
            stop_group(process)
            if reported is not None:
                phases.add("after_result", time.monotonic() - after_result)
            elif cooperate_dir is None:
                phases.add("exec", time.monotonic() - stepped)
            if cooperate_dir is not None:
                if reported is None:
                    spans.step(time.monotonic() - stepped, hol=False)
                phases.add("before_hol", spans.before_hol)
                phases.add("hol", spans.hol)
                phases.add("after_hol", spans.after_hol)
        if reported is not None:
            # Reported already: whatever the driver did after its result changes nothing for the client.
            print(f"{claim['theory']}: exit {process.returncode} after the result", file=sys.stderr, flush=True)
            return reported
        if lost:
            if (record := read_result(result)) is not None:
                report(record)
            return None
        if drained_out:
            record = failed_record(spec, "unavailable", "the worker's drain deadline passed before exec-action finished")
            # The log exec-action uploaded as it stopped shows how far the action got.
            log = next((line for line in (read_result(result) or "").splitlines() if line.startswith("log=")), None)
            return record if log is None else f"{record}{log}\n"
        if (record := read_result(result)) is None:
            if recordless := recordless_failure(process.returncode, drain.stop.is_set()):
                failure, detail = recordless
                print(f"{claim['theory']}: exec-action exited {process.returncode} without a result record, "
                      f"reporting {failure}", file=sys.stderr, flush=True)
                return failed_record(spec, failure, detail)
            raise RuntimeError(f"exec-action exited {process.returncode} without a result record")
    print(f"{claim['theory']}: exit {process.returncode}", file=sys.stderr, flush=True)
    return record


def tier_list(text: str) -> list[str]:
    tiers = [t for t in text.split(",") if t]
    for tier in tiers:
        if tier not in ("standard", "high"):
            raise argparse.ArgumentTypeError(f"unknown tier {tier!r}, expected standard or high")
    return tiers


def claim_wait_seconds(text: str) -> float:
    seconds = float(text)
    if not 0 <= seconds <= 50:
        raise argparse.ArgumentTypeError(f"{text} is not between 0 and 50")
    return seconds


def host_rank(text: str) -> int:
    rank = int(text)
    if not 0 <= rank <= MAX_HOST_RANK:
        raise argparse.ArgumentTypeError(f"{text} must be between 0 and {MAX_HOST_RANK}")
    return rank


def drain_seconds(text: str) -> float:
    seconds = float(text)
    if not math.isfinite(seconds) or seconds < 0:
        raise argparse.ArgumentTypeError(f"{text} must be finite and nonnegative")
    return seconds


def worker_name(image: str | None) -> str:
    """The default worker name: ``host:pid``, then ``@`` and the first 12 hex digits of the digest when ``image``
    (``REMOTE_EXEC_IMAGE``) names one as ``<repository>@sha256:<digest>``, so a lease says which image ran an action."""
    name = f"{socket.gethostname()}:{os.getpid()}"
    _, found, digest = (image or "").partition("@sha256:")
    return f"{name}@{digest[:12]}" if found and digest else name


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--coordinator", required=True, help="coordinator base URL")
    parser.add_argument(
        "--remote-cache", default=os.environ.get("HOLBUILD_REMOTE_CACHE_URL"),
        help="comma-separated remote cache URLs passed to holbuild (or HOLBUILD_REMOTE_CACHE_URL)",
    )
    parser.add_argument("--cache-limit-gb", required=True, type=int, help="holbuild exec-action --cache-limit-gb")
    parser.add_argument("--tier", choices=("standard", "high"), default="standard")
    parser.add_argument(
        "--also-claim",
        type=tier_list,
        action="extend",
        default=[],
        help="tiers to claim from when --tier has nothing ready, in order (repeatable or comma-separated)",
    )
    parser.add_argument(
        "--host-rank", type=host_rank, default=0,
        help="claims pack onto hosts of lower rank first, so hosts of higher rank empty first and scale in "
        "(default: %(default)s)",
    )
    parser.add_argument("--max-heap", type=int, default=12000, help="default holbuild --max-heap MB (default: %(default)s)")
    parser.add_argument("--cooperate-dir", help="holbuild --cooperate-dir, shared by a host's workers")
    parser.add_argument("--share-heaps", action="store_true", help="holbuild exec-action --share-heaps")
    parser.add_argument(
        "--load-ahead",
        action="store_true",
        help="also claim theories of batches that load ahead while their parents still build, and wait for them; "
        "for burst workers, so the warm pool stays free for ready work",
    )
    parser.add_argument(
        "--holbuild-releases-dir",
        default=os.environ.get("REMOTE_EXEC_HOLBUILD_RELEASES", "/opt/holbuild-releases"),
        help="where holbuild releases are built, one directory per version; a host's workers can share it "
        "(default: %(default)s)",
    )
    parser.add_argument(
        "--baked-releases",
        default=os.environ.get("REMOTE_EXEC_BAKED_RELEASES", "/opt/holbuild-baked"),
        help="preinstalled releases root, checked before downloading (default: %(default)s)",
    )
    parser.add_argument(
        "--holbuild-source-url",
        default=DEFAULT_SOURCE_URL,
        help="URL of a release's source tarball, with {version} for the version (default: %(default)s)",
    )
    parser.add_argument(
        "--protection-cmd",
        help="command run with 'on' when the worker takes an action and on each heartbeat, and 'off' when it "
        "finishes, to keep a scaler from stopping a busy worker",
    )
    parser.add_argument(
        "--name", default=worker_name(os.environ.get("REMOTE_EXEC_IMAGE")),
        help="worker name in leases (default: host:pid, then @ and the image digest's first 12 hex digits when "
        "REMOTE_EXEC_IMAGE names the image as <repository>@sha256:<digest>)",
    )
    parser.add_argument(
        "--drain-seconds", type=drain_seconds, default=20.0,
        help="time for a running action to finish after SIGTERM (default: %(default)s); leave at least 10s "
        "before the container stop timeout for cleanup and reporting",
    )
    parser.add_argument(
        "--claim-wait-seconds",
        type=claim_wait_seconds,
        default=20.0,
        help="how long a claim waits at the coordinator for an action to become ready (at most 50)",
    )
    args = parser.parse_args(argv)
    if not args.remote_cache:
        parser.error("--remote-cache or HOLBUILD_REMOTE_CACHE_URL is required")
    try:
        args.remote_cache = ",".join(cache_nodes(args.remote_cache))
    except ValueError as error:
        parser.error(str(error))
    return args


def refresh_cache_members(coordinator: Coordinator, membership: Membership, url: str, now: float) -> list[str]:
    """Fetch one bounded, nonredirecting snapshot, retaining static cache access when discovery fails."""
    if now - membership.attempted >= REFRESH_SECONDS:
        membership.attempted = now
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {coordinator.token}"})
        try:
            with coordinator.opener.open(request, timeout=5) as response:
                data = response.read(16385)
                if response.status != 200 or len(data) > 16384:
                    raise ValueError("invalid cache membership response")
                membership.update(data.decode(), now, resolve=True)
        except (OSError, ValueError, http.client.HTTPException):
            pass
    return membership.current(now)


def main() -> None:
    if ctypes.CDLL(None, use_errno=True).prctl(4, 0, 0, 0, 0) != 0:
        sys.exit("cannot protect worker process")
    args = parse_args()
    token = os.environ.get("REMOTE_EXEC_WORKER_TOKEN")
    if not token:
        sys.exit("REMOTE_EXEC_WORKER_TOKEN is not set")
    if "\r" in token or "\n" in token:
        sys.exit("worker token must not contain a newline")
    # exec-action's --cache-limit-gb sweeps the whole cache root, so it must be the worker's own.
    if not os.environ.get("HOLBUILD_CACHE"):
        sys.exit("HOLBUILD_CACHE is not set; give the worker its own cache root")
    charge = child_charge(args.max_heap)
    try:
        host: HostTelemetry | None = HostTelemetry(args.cooperate_dir, charge, args.host_rank)
    except OSError as error:
        print(f"not reporting the host to the coordinator: {error}", file=sys.stderr)
        host = None
    drain = Drain(args.drain_seconds)
    coordinator = Coordinator(args.coordinator, token, host, drain, load_ahead=args.load_ahead)
    releases = Releases(
        args.holbuild_releases_dir,
        args.holbuild_source_url,
        args.remote_cache,
        os.environ.get("HOLBUILD_REMOTE_CACHE_CURL_CONFIG"),
        baked_root=args.baked_releases,
        drain=drain,
    )
    protection = Protection(args.protection_cmd, os.environ.get("ECS_AGENT_URI"))
    tiers = list(dict.fromkeys([args.tier, *args.also_claim]))
    phases = Phases()
    discovery_url = os.environ.get("HOLBUILD_REMOTE_CACHE_DISCOVERY_URL")
    membership = None
    with contextlib.ExitStack() as resources:
        resources.enter_context(drain.installed())
        if discovery_url:
            if discovery_url != coordinator.url + "/v1/cache/members":
                sys.exit("cache discovery must use this worker's coordinator /v1/cache/members endpoint")
            defaults = cache_nodes(args.remote_cache)
            allowed = cache_nodes(os.environ.get("HOLBUILD_REMOTE_CACHE_ALLOWED_URLS", args.remote_cache))
            try:
                check_plain_http(defaults, allowed, bool(os.environ.get("HOLBUILD_REMOTE_CACHE_CURL_CONFIG")))
            except ValueError as error:
                sys.exit(str(error))
            membership = Membership(defaults, allowed)
            directory = resources.enter_context(tempfile.TemporaryDirectory(prefix="holbuild-cache-discovery-"))
            config = os.path.join(directory, "auth.curl")
            # Builds share our uid, so file permissions cannot protect the worker bearer from them.
            header = "Authorization: Bearer " + cache_discovery_token(token)
            with open(config, "x", opener=lambda path, flags: os.open(path, flags, 0o600)) as out:
                out.write('header = "' + header + '"\n')
            releases = replace(releases, discovery_config=config)
        sweep = functools.partial(sweep_cache, releases, args.cache_limit_gb)
        while not drain.stop.is_set():
            with phases.timed("idle"):
                wait_for_disk(drain, coordinator, tiers, args.name, sweep)
            if args.cooperate_dir is not None:
                try:
                    with phases.timed("memory_wait"), drain.interruptible():
                        waited = wait_for_memory(args.cooperate_dir, charge, drain)
                except DrainStopped:
                    break
                if waited and host is not None:
                    host.waited = True
            if drain.stop.is_set():
                break
            started = time.monotonic()
            claim = claim_reporting(coordinator, tiers, args.name, args.claim_wait_seconds, phases)
            if claim is None:
                # A claim that failed at once, or a coordinator that doesn't wait, isn't retried in a tight loop.
                with phases.timed("idle"):
                    drain.stop.wait(max(0.0, CLAIM_RETRY_SECONDS - (time.monotonic() - started)))
                continue
            if not drain.stop.is_set() and membership is not None and discovery_url is not None:
                now = time.monotonic()
                nodes = refresh_cache_members(coordinator, membership, discovery_url, now)
                releases = replace(releases, remote_cache=",".join(nodes))
            try:
                unavailable = run_one(coordinator, args, releases, protection, claim, phases, claimed=started)
            except Exception as error:  # noqa: BLE001  # run_one reported it where it could; the worker goes on
                # Else the next claim ends the lease and the coordinator retries; a rerun finds a published result
                # cached. Waiting keeps a worker from failing ready action after ready action while the cache or the
                # coordinator is down.
                print(f"action failed in the worker: {error}", file=sys.stderr)
                with phases.timed("idle"):
                    drain.stop.wait(CLAIM_RETRY_SECONDS)
                continue
            if unavailable:
                # The coordinator readies the action again at once, so without the wait the worker would claim it
                # straight back while the cache is still down.
                with phases.timed("idle"):
                    drain.stop.wait(CLAIM_RETRY_SECONDS)


if __name__ == "__main__":
    main()
