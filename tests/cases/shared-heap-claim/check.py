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
script = Path(__file__).with_name("publish.sml")


def action_key(key: str) -> str:
    return hashlib.sha256(f"holbuild-remote-ac-v1\n{key}\n".encode()).hexdigest()


def claim_path(heap_key: str) -> Path:
    claim = hashlib.sha256(f"holbuild-shared-heap-claim-v1\nheap={heap_key}\n".encode()).hexdigest()
    return remote / "ac" / action_key(claim)


def published_heap(heap_key: str) -> str | None:
    path = remote / "ac" / action_key(heap_key)
    if not path.exists():
        return None
    manifest = path.read_text().split("manifest-text-v1\n", 1)[1]
    return manifest.split("blob=", 1)[1].split()[0]


def heap_uploads() -> int:
    return sum(line.startswith("PUT /cas/") for line in requests.read_text().splitlines())


def action_writes() -> int:
    return sum(line.startswith("PUT /ac/") for line in requests.read_text().splitlines())


class Publisher:
    def __init__(self, name: str, heap_key: str) -> None:
        self.dir = directory / name
        self.dir.mkdir()
        self.log = self.dir / "poly.log"
        env = dict(os.environ, PUBLISH_DIR=str(self.dir), PUBLISHER=name, HEAP_KEY=heap_key)
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

    def heap(self) -> str:
        return (self.dir / "heap.sha").read_text()


def concurrent_publishers_upload_once() -> None:
    (control / "cas-put-enable").touch()
    first = Publisher("first", "one")
    uploads = control / "cas-put-count"
    first.wait_until(lambda: uploads.exists() and uploads.read_text() == "1")
    # The first publisher is mid-upload: the second skips its own copy.
    second = Publisher("second", "one")
    try:
        log = second.finish()
    finally:
        (control / "cas-put-release").touch()
    assert "another worker is publishing the shared deps-loaded heap" in log, log
    first.finish()
    assert uploads.read_text() == "1", "a second publisher uploaded the claimed heap"
    assert published_heap("one") == first.heap(), "the claimant's heap was not published"
    # Released, so a repair after the cache loses the blob needn't wait.
    assert claim_path("one").read_text().endswith("\ntime=0\n"), "the published heap kept its claim"
    for name in ("cas-put-enable", "cas-put-release", "cas-put-count"):
        (control / name).unlink()


def late_claim_write_also_uploads() -> None:
    """The cache has no conditional write: a claim written after the
    claimant's settle delay wins too, so its writer uploads as well."""
    late_write = f"action-put-{action_writes() + 1}-before"
    (control / f"{late_write}-enable").touch()
    late = Publisher("late", "three")
    late.wait_until(lambda: (control / f"{late_write}-event").exists())
    # The late publisher read no claim and its claim write is held back.
    (control / "cas-put-enable").touch()
    uploads = control / "cas-put-count"
    early = Publisher("early", "three")
    early.wait_until(lambda: uploads.exists() and uploads.read_text() == "1")
    (control / f"{late_write}-release").touch()
    late.wait_until(lambda: uploads.read_text() == "2")
    (control / "cas-put-release").touch()
    early.finish()
    late.finish()
    assert published_heap("three") in (early.heap(), late.heap())
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
    retry = Publisher("retry", "two")
    retry.finish()
    assert heap_uploads() == before + 1
    assert published_heap("two") == retry.heap(), "the released heap was not published at once"


if __name__ == "__main__":
    try:
        concurrent_publishers_upload_once()
        late_claim_write_also_uploads()
        failed_upload_releases_claim()
    except BaseException:
        for log in sorted(directory.glob("*/poly.log")):
            print(f"== {log.parent.name}\n{log.read_text()}")
        raise
    print("shared heap claim passed")
