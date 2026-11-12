"""Gate real publication requests to check concurrency and blob dependencies."""

import hashlib
import os
from pathlib import Path
import subprocess
import time
from collections.abc import Callable


def wait_for(process: subprocess.Popen[bytes], predicate: Callable[[], bool]) -> None:
    deadline = time.monotonic() + 300
    while not predicate():
        if process.poll() is not None or time.monotonic() >= deadline:
            raise AssertionError("publication exited or timed out before its fixture event")
        time.sleep(0.01)


def run() -> None:
    directory = Path(os.environ["PUBLISH_DIR"])
    control = directory / "control"
    failing = os.environ["PUBLISH_FAIL"] == "1"
    count = 24 if failing else 451
    requests = directory / "server/requests.log"
    script = Path(__file__).with_suffix(".sml")
    with (directory / "poly.log").open("wb") as log:
        process = subprocess.Popen(
            ["poly", "--gcthreads=1", "--error-exit", "--script", str(script)],
            stdout=log, stderr=log,
        )
        try:
            wait_for(process, lambda: (directory / "publish.ready").exists())
            (control / "action-get-enable").touch()
            (control / "cas-put-enable").touch()
            for sequence in range(2, count + 1):
                (control / f"action-put-{sequence}-before-enable").touch()
            if failing:
                (control / "cas-put-reject-text").write_text("test=checkpoint-12\n")
            (directory / "publish.release").touch()
            probe_count = control / "action-get-count"
            wait_for(process, lambda: probe_count.exists() and probe_count.read_text() == "16")
            (control / "action-get-release").touch()
            blob_count = control / "cas-put-count"
            wait_for(process, lambda: blob_count.exists() and blob_count.read_text() == "4")
            (control / "cas-put-release").touch()
            wait_for(process, lambda: len(list(control.glob("action-put-*-before-event"))) == 4)
            for sequence in range(2, count + 1):
                (control / f"action-put-{sequence}-before-release").touch()
            wait_for(process, lambda: (directory / "published.ready").exists())
            lines = requests.read_text().splitlines()
            puts = [line for line in lines if line.startswith("PUT /cas/")]
            assert len(puts) == len(set(puts)), "a spine blob was uploaded more than once"
            assert len(puts) == 1 + 2 * (count - 1), "CAS writes must equal the distinct heap/state/sidecar files"
            manifests = list((directory / "remote/ac").glob("*"))
            expected = 11 if failing else count - 1
            assert len(manifests) == expected + 1, "wrong number of candidate manifests"
            for manifest in manifests:
                text = manifest.read_text().split("manifest-text-v1\n", 1)[1]
                for line in text.splitlines():
                    if line.startswith("blob="):
                        sha = line.split()[0][5:]
                        assert (directory / "remote/cas" / sha).exists(), "manifest names a failed blob"
            partial = hashlib.sha256(b"partial-uncommitted-save").hexdigest()
            assert not (directory / "remote/cas" / partial).exists(), "uncommitted save uploaded"
            # Independently reconstruct the existing wire format and ordering.
            tree = directory / "checkpoints"
            def digest(path: Path) -> str:
                return hashlib.sha256(path.read_bytes()).hexdigest()

            for index in range(1, expected + 1):
                key = hashlib.sha256(
                    f"holbuild-shared-checkpoint-v1\nheap=heap\nkind=theorem_context\ncheckpoint-key={index}\n".encode()
                ).hexdigest()
                action = hashlib.sha256(f"holbuild-remote-ac-v1\n{key}\n".encode()).hexdigest()
                entries = [f"blob={digest(tree / 'deps.save')} heap\n"]
                entries += [f"blob={digest(tree / f'c{i}.save')} spine c{i}.save\n" for i in range(1, index)]
                entries += [f"blob={digest(tree / f'c{i}.save.ok')} spine-sidecar c{i}.save.ok\n" for i in range(1, index)]
                entries += [f"blob={digest(tree / f'c{index}.save')} leaf c{index}.save\n",
                            f"blob={digest(tree / f'c{index}.save.ok')} sidecar .ok\n"]
                expected_text = "holbuild-shared-checkpoint-v1\nkind=theorem_context\n" + "".join(entries)
                actual = (directory / "remote/ac" / action).read_text().split("manifest-text-v1\n", 1)[1]
                assert actual == expected_text, "checkpoint manifest bytes changed"
            (directory / "published.release").touch()
            wait_for(process, lambda: (directory / "repeated.ready").exists())
            assert requests.read_text().splitlines().count("PUT /cas/" + partial) == 0
            if not failing:
                assert len(requests.read_text().splitlines()) == len(lines) + count - 1, "present candidate did more than a probe"
            (directory / "repeated.release").touch()
            wait_for(process, lambda: (directory / "repaired.ready").exists())
            (directory / "repaired.release").touch()
            assert process.wait(timeout=120) == 0, "checkpoint restore failed"
        except BaseException:
            process.kill()
            process.wait()
            print((directory / "poly.log").read_text())
            raise
    print(f"shared checkpoint publication passed (failed blob={failing})")


if __name__ == "__main__":
    run()
