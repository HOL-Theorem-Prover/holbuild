"""Remote-exec worker loop: claim an action, run ``holbuild exec-action`` on it, heartbeat, report the result.

Standard library only, so a worker needs just python3, curl, and what building holbuild and HOL takes:

    REMOTE_EXEC_WORKER_TOKEN=... HOLBUILD_CACHE=/var/cache/holbuild python3 -m remote_exec.worker \\
        --coordinator URL --remote-cache URL --cache-limit-gb N [--tier standard|high] [--max-heap MB] ...

Each action runs on the holbuild release that exported it, which the worker builds on first use.
"""

import argparse
import contextlib
import fcntl
import http.client
import json
import os
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
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any

DEFAULT_SOURCE_URL = "https://github.com/HOL-Theorem-Prover/holbuild/archive/refs/tags/v{version}.tar.gz"
RELEASE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
COMPLETE = ".complete"  # stamp file of a finished release build
# ECS task scale-in protection lasts this long unless a heartbeat renews it, so a dead worker loses it.
PROTECTION_MINUTES = 10
CLAIM_RETRY_SECONDS = 5  # least time between two claims that found nothing
# What exec-action runs with besides holbuild's own HOLBUILD_* settings: what curl, git and the locale read. The rest
# of the worker's environment, its coordinator token above all, stays out of the builds' environment.
EXEC_ACTION_ENV = ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR")
PROXY_ENV = ("http_proxy", "https_proxy", "all_proxy", "no_proxy")  # in either case


# What a request to the coordinator raises when it or the network fails; ValueError covers a reply that isn't JSON.
COORDINATOR_ERRORS = (OSError, RuntimeError, http.client.HTTPException, ValueError)


class Unreleased(Exception):
    """The action was exported by a holbuild version that has no release to build."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuses redirects, which would send the worker token to wherever they point."""

    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


class Coordinator:
    """The worker endpoints of the coordinator."""

    opener = urllib.request.build_opener(NoRedirect)

    def __init__(self, url: str, token: str) -> None:
        self.url = url.rstrip("/")
        self.token = token

    def post(self, path: str, body: bytes, content_type: str, timeout: float = 30) -> tuple[int, Any]:
        request = urllib.request.Request(
            self.url + path,
            data=body,
            method="POST",
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": content_type},
        )
        try:
            with self.opener.open(request, timeout=timeout) as response:
                payload = response.read()
                return response.status, json.loads(payload) if payload else None
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode(errors="replace")

    def claim(self, tiers: list[str], worker: str, wait_s: float) -> dict[str, Any] | None:
        """An action, waiting up to ``wait_s`` seconds for one, or None."""
        body = {"tier": tiers[0], "also_claim": tiers[1:], "worker": worker, "wait_s": wait_s}
        status, response = self.post("/v1/work/claim", json.dumps(body).encode(), "application/json", 30 + wait_s)
        if status == 204:
            return None
        if status != 200:
            raise RuntimeError(f"claim answered {status}: {response}")
        return response

    def heartbeat(self, token: str) -> bool:
        status, body = self.post(f"/v1/work/{token}/heartbeat", b"", "application/json")
        if status not in (200, 409):
            raise RuntimeError(f"heartbeat answered {status}: {body}")
        return status == 200

    def complete(self, token: str, record: str) -> None:
        status, body = self.post(f"/v1/work/{token}/complete", record.encode(), "text/plain")
        if status == 409:
            print(f"result dropped as stale: {body}", file=sys.stderr)
        elif status != 200:
            raise RuntimeError(f"complete answered {status}: {body}")


class Protection:
    """Scale-in protection while the worker holds an action: ``--protection-cmd on|off``, or the ECS agent's
    task-protection endpoint when ``ECS_AGENT_URI`` is set, or nothing. Failures are logged, never raised."""

    def __init__(self, command: str | None, ecs_agent_uri: str | None) -> None:
        self.command = command
        self.ecs_agent_uri = ecs_agent_uri

    def set(self, *, enabled: bool) -> None:
        try:
            if self.command is not None:
                subprocess.run([*shlex.split(self.command), "on" if enabled else "off"], check=True, timeout=60)
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
                with urllib.request.urlopen(request, timeout=30):
                    pass
        except Exception as error:  # noqa: BLE001  # protection is best effort and must never stop an action
            print(f"setting scale-in protection to {enabled} failed: {error}", file=sys.stderr)


@dataclass(frozen=True)
class Releases:
    """holbuild releases built on demand, each in ``<root>/v<version>`` from ``source_url`` with ``{version}``
    filled in. A host's workers can share ``root``; one of them builds a release while the others wait."""

    root: str
    source_url: str
    remote_cache: str
    curl_config: str | None

    def spec_version(self, spec_sha256: str) -> str:
        """The ``holbuild-version`` of the action spec stored in the remote cache's ``/cas/``."""
        # -g: no URL globbing, whose errors print the URL with any credentials in it.
        command = ["curl", "-fsSLg", "--retry", "3"]
        if self.curl_config is not None:
            command += ["-K", self.curl_config]
        command.append(f"{self.remote_cache.rstrip('/')}/cas/{spec_sha256}")
        # Not check=True: its error would print the command line, and the cache URL may carry credentials.
        try:
            fetched = subprocess.run(command, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"fetching spec {spec_sha256} from the remote cache timed out") from None
        if fetched.returncode != 0:
            raise RuntimeError(f"fetching spec {spec_sha256} from the remote cache failed: {fetched.stderr.strip()}")
        spec = fetched.stdout
        versions = [
            line.removeprefix("holbuild-version=") for line in spec.splitlines() if line.startswith("holbuild-version=")
        ]
        if len(versions) != 1:
            raise RuntimeError(f"spec {spec_sha256} has {len(versions)} holbuild-version lines, expected 1")
        return versions[0]

    def holbuild(self, version: str) -> str:
        """The holbuild executable of release ``version``, built first if this host doesn't have it yet.

        Raises Unreleased when the version isn't a release or its source can't be found.
        """
        if not RELEASE.fullmatch(version):
            raise Unreleased(f"holbuild {version!r} is not a release version")
        directory = os.path.join(self.root, f"v{version}")
        executable = os.path.join(directory, "bin", "holbuild")
        if os.path.exists(os.path.join(directory, COMPLETE)):
            return executable
        os.makedirs(self.root, exist_ok=True)
        with open(os.path.join(self.root, f"v{version}.lock"), "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if not os.path.exists(os.path.join(directory, COMPLETE)):
                self._build(version, directory)
        return executable

    def _build(self, version: str, directory: str) -> None:
        # holbuild finds its runtime sources where it was compiled, so it's built in the directory it runs from.
        shutil.rmtree(directory, ignore_errors=True)
        url = self.source_url.format(version=version)
        print(f"building holbuild {version} from {url}", file=sys.stderr, flush=True)
        with tempfile.TemporaryDirectory(dir=self.root) as scratch:
            archive = os.path.join(scratch, "source.tar.gz")
            try:
                with urllib.request.urlopen(url, timeout=300) as response, open(archive, "wb") as file:
                    shutil.copyfileobj(response, file)
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    raise Unreleased(f"holbuild {version} has no release at {url}") from error
                raise
            except urllib.error.URLError as error:
                if isinstance(error.reason, FileNotFoundError):
                    raise Unreleased(f"holbuild {version} has no release at {url}") from error
                raise
            with tarfile.open(archive) as tar:
                tar.extractall(scratch, filter="data")
            (top,) = [entry for entry in os.listdir(scratch) if entry != "source.tar.gz"]
            os.rename(os.path.join(scratch, top), directory)
        subprocess.run(["make", "bin/holbuild"], cwd=directory, check=True, stdout=2)
        with open(os.path.join(directory, COMPLETE), "w"):
            pass


def failed_record(spec_sha256: str, failure: str) -> str:
    """A result record the worker writes itself: ``spec-rejected`` for an action it won't run, which fails it
    finally like exec-action's own, or ``internal`` for one exec-action ended without a record, which is retried."""
    return f"holbuild-action-result-v1\nspec={spec_sha256}\ninput-key=\nstatus=failed\nfailure={failure}\n"


def exec_action_env() -> dict[str, str]:
    return {
        name: value
        for name, value in os.environ.items()
        if name in EXEC_ACTION_ENV or name.lower() in PROXY_ENV or name.startswith("HOLBUILD_")
    }


def exec_action_command(args: argparse.Namespace, holbuild: str, spec: str, result: str) -> list[str]:
    command = [holbuild, "--remote-cache", args.remote_cache]
    if args.max_heap is not None:
        command += ["--max-heap", str(args.max_heap)]
    if args.cooperate_dir is not None:
        command += ["--cooperate-dir", args.cooperate_dir]
    command += ["exec-action", spec, "--cache-limit-gb", str(args.cache_limit_gb), "--result", result]
    if args.share_heaps:
        command.append("--share-heaps")
    return command


class Lease:
    """Heartbeats an action's lease from a thread while the action runs, and holds scale-in protection."""

    def __init__(self, coordinator: Coordinator, token: str, lease_s: float, protection: Protection) -> None:
        self.coordinator = coordinator
        self.token = token
        self.interval = max(1.0, lease_s / 3)
        self.protection = protection
        self.lost = threading.Event()
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._beat, daemon=True)

    @contextlib.contextmanager
    def held(self) -> Iterator["Lease"]:
        self.protection.set(enabled=True)
        self.thread.start()
        try:
            yield self
        finally:
            self.done.set()
            self.thread.join()
            self.protection.set(enabled=False)

    def _beat(self) -> None:
        while not self.done.wait(self.interval):
            try:
                alive = self.coordinator.heartbeat(self.token)
            except COORDINATOR_ERRORS as error:
                print(f"heartbeat failed, carrying on: {error}", file=sys.stderr)
                continue
            if not alive:
                print("lease lost; stopping the action", file=sys.stderr)
                self.lost.set()
                return
            self.protection.set(enabled=True)


def run_one(
    coordinator: Coordinator,
    args: argparse.Namespace,
    releases: Releases,
    protection: Protection,
    claim: dict[str, Any],
) -> None:
    """Run one claimed action to its end, or until its lease is lost, and report it."""
    token = claim["attempt_token"]
    spec = claim["spec_sha256"]
    print(f"running {claim['theory']} ({claim['input_key']})", file=sys.stderr, flush=True)
    with Lease(coordinator, token, claim["lease_s"], protection).held() as lease:
        try:
            holbuild = releases.holbuild(releases.spec_version(spec))
        except Unreleased as error:
            print(f"refusing {spec}: {error}", file=sys.stderr)
            coordinator.complete(token, failed_record(spec, "spec-rejected"))
            return
        if lease.lost.is_set():
            return
        with tempfile.TemporaryDirectory() as scratch:
            result = os.path.join(scratch, "result")
            # Its own session, so a lost lease stops holbuild's HOL children with it.
            process = subprocess.Popen(
                exec_action_command(args, holbuild, spec, result), env=exec_action_env(), start_new_session=True
            )
            try:
                while process.poll() is None:
                    if lease.lost.wait(1):
                        return
            finally:
                # A lost lease, Ctrl-C or SIGTERM (see main) stops the action rather than leaving it running
                # unreported. The group outlives holbuild while a HOL child is still in it.
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                process.wait()
            if not os.path.exists(result) or os.path.getsize(result) == 0:
                # It crashed or was killed; the coordinator retries the action now rather than when the lease expires.
                print(f"exec-action exited {process.returncode} without a result record", file=sys.stderr)
                coordinator.complete(token, failed_record(spec, "internal"))
                return
            with open(result) as file:
                coordinator.complete(token, file.read())
            print(f"{claim['theory']}: exit {process.returncode}", file=sys.stderr, flush=True)


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


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--coordinator", required=True, help="coordinator base URL")
    parser.add_argument("--remote-cache", required=True, help="remote cache URL passed to holbuild")
    parser.add_argument("--cache-limit-gb", required=True, type=int, help="holbuild exec-action --cache-limit-gb")
    parser.add_argument("--tier", choices=("standard", "high"), default="standard")
    parser.add_argument(
        "--also-claim",
        type=tier_list,
        action="extend",
        default=[],
        help="tiers to claim from when --tier has nothing ready, in order (repeatable or comma-separated)",
    )
    parser.add_argument("--max-heap", type=int, help="holbuild --max-heap MB")
    parser.add_argument("--cooperate-dir", help="holbuild --cooperate-dir, shared by a host's workers")
    parser.add_argument("--share-heaps", action="store_true", help="holbuild exec-action --share-heaps")
    parser.add_argument(
        "--holbuild-releases-dir",
        default="/opt/holbuild-releases",
        help="where holbuild releases are built, one directory per version; a host's workers can share it",
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
    parser.add_argument("--name", default=f"{socket.gethostname()}:{os.getpid()}", help="worker name in leases")
    parser.add_argument(
        "--claim-wait-seconds",
        type=claim_wait_seconds,
        default=20.0,
        help="how long a claim waits at the coordinator for an action to become ready (at most 50)",
    )
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()
    token = os.environ.get("REMOTE_EXEC_WORKER_TOKEN")
    if not token:
        sys.exit("REMOTE_EXEC_WORKER_TOKEN is not set")
    # exec-action's --cache-limit-gb sweeps the whole cache root, so it must be the worker's own.
    if not os.environ.get("HOLBUILD_CACHE"):
        sys.exit("HOLBUILD_CACHE is not set; give the worker its own cache root")
    coordinator = Coordinator(args.coordinator, token)
    releases = Releases(
        args.holbuild_releases_dir,
        args.holbuild_source_url,
        args.remote_cache,
        os.environ.get("HOLBUILD_REMOTE_CACHE_CURL_CONFIG"),
    )
    protection = Protection(args.protection_cmd, os.environ.get("ECS_AGENT_URI"))
    tiers = list(dict.fromkeys([args.tier, *args.also_claim]))
    # Exit through Python on SIGTERM, so run_one's cleanup stops the running action.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(128 + signal.SIGTERM))
    while True:
        started = time.monotonic()
        try:
            claim = coordinator.claim(tiers, args.name, args.claim_wait_seconds)
        except COORDINATOR_ERRORS as error:
            print(f"claim failed: {error}", file=sys.stderr)
            claim = None
        if claim is None:
            # A claim that failed at once, or a coordinator that doesn't wait, isn't retried in a tight loop.
            time.sleep(max(0.0, CLAIM_RETRY_SECONDS - (time.monotonic() - started)))
            continue
        try:
            run_one(coordinator, args, releases, protection, claim)
        except (*COORDINATOR_ERRORS, subprocess.SubprocessError, tarfile.TarError) as error:
            # The lease expires and the coordinator retries; a rerun finds a published result cached.
            print(f"action failed in the worker: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
