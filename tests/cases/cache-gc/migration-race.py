import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def check_migration(binary: str, cache: Path) -> None:
    lock = cache / "locks/gc.lock"
    lock.mkdir(parents=True)
    read_fd, write_fd = os.pipe()
    os.set_blocking(write_fd, False)
    try:
        while True:
            os.write(write_fd, b"x" * 4096)
    except BlockingIOError:
        pass
    os.set_blocking(write_fd, True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("HOLBUILD_REMOTE_")}
    env["HOLBUILD_CACHE"] = str(cache)
    child = subprocess.Popen(
        [binary, "gc", "--cache-only"], env=env,
        stdout=subprocess.DEVNULL, stderr=write_fd,
    )
    os.close(write_fd)
    try:
        # The full stderr pipe blocks the warning after the directory check,
        # without a test hook in the lock implementation.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            tasks = Path(f"/proc/{child.pid}/task")
            if any("pipe_write" in p.read_text() for p in tasks.glob("*/wchan")):
                break
            if child.poll() is not None:
                raise AssertionError("migrator exited before its warning")
            time.sleep(0.01)
        else:
            raise AssertionError("migration warning did not block")
        lock.rmdir()
        lock.write_text("held-by-sibling")
        with lock.open("r+") as held:
            fcntl.lockf(held, fcntl.LOCK_EX)
            original_inode = os.fstat(held.fileno()).st_ino
            os.read(read_fd, 65536)
            status = child.wait(timeout=10)
            assert lock.stat().st_ino == original_inode, "migration replaced a held lock"
            assert status != 0, "GC acquired a sibling's held lock"
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        os.close(read_fd)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="holbuild-lock-migration-") as tmp:
        check_migration(sys.argv[1], Path(tmp))
