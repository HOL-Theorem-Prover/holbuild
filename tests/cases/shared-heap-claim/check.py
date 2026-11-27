"""Workers that built the same cold heap: only the claimant uploads it."""

import hashlib
import os
from pathlib import Path
import subprocess
import time
from collections.abc import Callable


directory = Path(os.environ["CLAIM_DIR"])
control = directory / "control"
remote = directory / "remote"
requests = directory / "server/requests.log"
publish_script = Path(__file__).with_name("publish.sml")
restore_script = Path(__file__).with_name("restore.sml")


def action_key(key: str) -> str:
    return hashlib.sha256(f"holbuild-remote-ac-v1\n{key}\n".encode()).hexdigest()


def heap_path(heap_key: str) -> Path:
    return remote / "ac" / action_key(heap_key)


def claim_path(heap_key: str) -> Path:
    claim = hashlib.sha256(f"holbuild-shared-heap-claim-v1\nheap={heap_key}\n".encode()).hexdigest()
    return remote / "ac" / action_key(claim)


def published_heap(heap_key: str) -> str | None:
    path = heap_path(heap_key)
    if not path.exists():
        return None
    manifest = path.read_text().split("manifest-text-v1\n", 1)[1]
    return manifest.split("blob=", 1)[1].split()[0]


def heap_uploads() -> int:
    return sum(line.startswith("PUT /cas/") for line in requests.read_text().splitlines())


def claim_gets(heap_key: str) -> int:
    get = f"GET /ac/{claim_path(heap_key).name}"
    return sum(line.startswith(get) for line in requests.read_text().splitlines())


def action_writes() -> int:
    return sum(line.startswith("PUT /ac/") for line in requests.read_text().splitlines())


def stale_copy(path: Path, data: str, *, next_copy: bool = False) -> None:
    prefix = "ac-stale-next-" if next_copy else "ac-stale-"
    (control / f"{prefix}{path.name}").write_text(data)


def claim_at(data: str, seconds: int) -> str:
    header, manifest = data.split("manifest-text-v1\n", 1)
    manifest = manifest.rsplit("time=", 1)[0] + f"time={seconds}\n"
    return (
        f"{header.splitlines()[0]}\n"
        f"manifest-sha256 {hashlib.sha256(manifest.encode()).hexdigest()}\n"
        f"manifest-size {len(manifest)}\n"
        f"manifest-text-v1\n{manifest}"
    )


class Publisher:
    def __init__(self, name: str, heap_key: str, script: Path = publish_script, **extra_env: str) -> None:
        self.dir = directory / name
        self.dir.mkdir()
        self.log = self.dir / "poly.log"
        env = dict(os.environ, PUBLISH_DIR=str(self.dir), PUBLISHER=name, HEAP_KEY=heap_key, **extra_env)
        with self.log.open("wb") as log:
            self.process = subprocess.Popen(
                ["poly", "--gcthreads=1", "--error-exit", "--script", str(script)],
                stdout=log, stderr=log, env=env,
            )

    def wait_until(self, predicate: Callable[[], bool]) -> None:
        deadline = time.monotonic() + 300
        while not predicate():
            if self.process.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError(f"{self.dir.name} exited or timed out:\n{self.log.read_text()}")
            time.sleep(0.01)

    def finish(self) -> str:
        if self.process.wait(timeout=300) != 0:
            raise AssertionError(f"{self.dir.name} failed:\n{self.log.read_text()}")
        return self.log.read_text()

    def go(self) -> None:
        """Start a GATED script's timed part once it has compiled."""
        self.wait_until(lambda: (self.dir / "ready").exists())
        (self.dir / "go").touch()

    def heap(self) -> str:
        return (self.dir / "heap.sha").read_text()

    def result(self) -> str:
        self.finish()
        return (self.dir / "result").read_text()


def concurrent_publishers_upload_once() -> None:
    (control / "cas-put-enable").touch()
    first = Publisher("first", "one")
    uploads = control / "cas-put-count"
    first.wait_until(lambda: uploads.exists() and uploads.read_text() == "1")
    # The old settle slept and read back the claim before starting the transfer.
    calls = requests.read_text().splitlines()
    claim = claim_path("one")
    put = calls.index(f"PUT /ac/{claim.name}")
    upload = calls.index(f"PUT /cas/{first.heap()}")
    assert put < upload and f"GET /ac/{claim.name}" not in calls[put:upload], calls
    # The first publisher is mid-upload: the second skips its own copy.
    stale_copy(claim, claim_at(claim.read_text(), 0))
    second = Publisher("second", "one")
    try:
        log = second.finish()
    finally:
        (control / "cas-put-release").touch()
    assert "result=skipped-claimed" in log, log
    first.finish()
    assert uploads.read_text() == "1", "a second publisher uploaded the claimed heap"
    assert published_heap("one") == first.heap(), "the claimant's heap was not published"
    # Released, so a repair after the cache loses the blob needn't wait.
    assert claim_path("one").read_text().endswith("\ntime=0\n"), "the published heap kept its claim"
    for name in ("cas-put-enable", "cas-put-release", "cas-put-count"):
        (control / name).unlink()


def late_claim_write_supersedes_uploader() -> None:
    sequence = action_writes() + 1
    late_write = f"action-put-{sequence}-before"
    late_ack = f"action-put-{sequence}-after"
    (control / f"{late_write}-enable").touch()
    (control / f"{late_ack}-enable").touch()
    late = Publisher("late", "three")
    late.wait_until(lambda: (control / f"{late_write}-event").exists())
    # The late publisher read no claim and its claim write is held back.
    (control / "cas-put-enable").touch()
    uploads = control / "cas-put-count"
    early = Publisher("early", "three")
    early.wait_until(lambda: uploads.exists() and uploads.read_text() == "1")
    claim = claim_path("three")
    early_claim = claim.read_text()
    try:
        (control / f"{late_write}-release").touch()
        late.wait_until(lambda: (control / f"{late_ack}-event").exists())
        winning_claim = claim.read_text()
        assert winning_claim != early_claim
        # The first uploader's host still has its own claim cached.
        stale_copy(claim, early_claim)
        stale_copy(claim, early_claim, next_copy=True)
        (control / "cas-put-release").touch()
        log = early.finish()
        assert "result=claim-lost" in log, log
        assert claim.read_text() == winning_claim, "the loser released the winner's claim"
        assert not heap_path("three").exists(), "the loser wrote the shared heap entry"
        assert not (early.dir / "store" / early.heap() / early.heap()).exists(), "the loser retained its heap"
    finally:
        (control / "cas-put-release").touch()
        (control / f"{late_ack}-release").touch()
    late.finish()
    assert published_heap("three") == late.heap()
    for name in ("cas-put-enable", "cas-put-release", "cas-put-count"):
        (control / name).unlink()


def failed_upload_releases_claim() -> None:
    (control / "cas-put-status").write_text("500")
    failed = Publisher("failed", "two")
    failed.finish()
    assert published_heap("two") is None
    assert claim_path("two").read_text().endswith("\ntime=0\n"), "the failed upload kept its claim"
    (control / "cas-put-status").unlink()
    before = heap_uploads()
    # A host's stale entry must not stop the repair of a missing heap.
    path = heap_path("two")
    stale_heap = heap_path("one").read_text()
    stale_copy(path, stale_heap)
    stale_copy(path, stale_heap, next_copy=True)
    retry = Publisher("retry", "two")
    retry.finish()
    assert heap_uploads() == before + 1
    assert published_heap("two") == retry.heap(), "the released heap was not published at once"


def restore_waits_for_claimed_upload() -> None:
    """An action right after the one that built its heap waits for that
    heap's upload instead of loading every ancestor itself."""
    # Both restores compile before the upload starts: the held upload gives
    # up after curl's 30 s low-speed limit, which compiling twice can pass.
    bounded = Publisher("bounded", "four", restore_script, WAIT_SECONDS="1", GATED="1")
    waiting = Publisher("waiting", "four", restore_script,
                        BASE_STATE=str(directory / "uploader" / "base.save"), GATED="1")
    for restore in (bounded, waiting):
        restore.wait_until(lambda: (restore.dir / "ready").exists())
    (control / "cas-put-enable").touch()
    uploads = control / "cas-put-count"
    uploader = Publisher("uploader", "four")
    uploader.wait_until(lambda: uploads.exists() and uploads.read_text() == "1")
    # Claimed and mid-upload: a restore waits no longer than its deadline.
    started = time.monotonic()
    bounded.go()
    assert bounded.result() == "wait-timeout", "the wait outlived an upload that never ends"
    assert time.monotonic() - started < 30, "the wait ignored its deadline"
    claim_reads = claim_gets("four")
    # The restore sees the origin's initial miss and then waits for the new heap.
    path = heap_path("four")
    stale_heap = heap_path("one").read_text()
    stale_copy(path, stale_heap)
    stale_copy(path, stale_heap, next_copy=True)
    waiting.go()
    waiting.wait_until(lambda: claim_gets("four") >= claim_reads + 2)
    (control / "cas-put-release").touch()
    uploader.finish()
    assert waiting.result() == f"{uploader.heap()} waited", "the restore missed the uploaded heap"
    assert "result=wait-hit" in waiting.log.read_text()
    for name in ("cas-put-enable", "cas-put-release", "cas-put-count"):
        (control / name).unlink()


def restore_sees_foreign_release() -> None:
    path = claim_path("five")
    released = claim_path("four").read_text()
    waiting = Publisher("released", "five", restore_script, WAIT_SECONDS="10", GATED="1")
    waiting.wait_until(lambda: (waiting.dir / "ready").exists())
    active = claim_at(released, int(time.time()))
    path.write_text(active)
    waiting.go()
    waiting.wait_until(lambda: claim_gets("five") >= 2)
    stale_copy(path, active)
    replacement = directory / "released.claim"
    replacement.write_text(released)
    replacement.replace(path)
    assert waiting.result() == "wait-miss", "the restore waited on a released claim"


def claim_and_heap_reads_revalidate() -> None:
    calls = requests.read_text().splitlines()
    revalidated = (control / "no-cache-gets").read_text().splitlines()
    for heap_key in ("one", "two", "three", "four", "five"):
        for key in (heap_path(heap_key).name, claim_path(heap_key).name):
            assert calls.count(f"GET /ac/{key}") == revalidated.count(key), (
                f"{heap_key}: a heap or claim GET omitted Cache-Control: no-cache"
            )


if __name__ == "__main__":
    try:
        concurrent_publishers_upload_once()
        late_claim_write_supersedes_uploader()
        failed_upload_releases_claim()
        restore_waits_for_claimed_upload()
        restore_sees_foreign_release()
        claim_and_heap_reads_revalidate()
    except BaseException:
        for log in sorted(directory.glob("*/poly.log")):
            print(f"== {log.parent.name}\n{log.read_text()}")
        raise
    print("shared heap claim passed")
