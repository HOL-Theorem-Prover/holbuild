"""Exercise the encountered same-user credential/cache attacks with sentinel state."""

import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import platform
import resource
import runpy
import select
import shutil
import signal
import threading
import subprocess
import sys
import tempfile
import time


def attack(root: Path, worker: int, secret: Path, shared: Path) -> None:
    denied: list[str] = []

    def refuses(name: str, action: object) -> None:
        try:
            action()
        except OSError as error:
            assert error.errno in (errno.EACCES, errno.EPERM, errno.ENOTTY), (name, error)
            denied.append(name)
        else:
            raise AssertionError(f"sandbox permitted {name}")

    assert not any(name.startswith(("HOLBUILD_REMOTE_", "REMOTE_EXEC_")) for name in os.environ)
    refuses("worker environment", lambda: Path(f"/proc/{worker}/environ").read_bytes())
    refuses("cache credential", secret.read_bytes)
    refuses("output symlink", lambda: (root / "stolen").symlink_to(secret))
    refuses("output hardlink", lambda: os.link(secret, root / "stolen"))
    refuses("worker signals", lambda: os.kill(worker, 0))
    refuses("worker group signals", lambda: os.killpg(os.getpgid(worker), 0))
    (root / "future-ready").write_text("ready")
    deadline = time.monotonic() + 10
    while not (root / "future.pid").exists():
        assert time.monotonic() < deadline, "future sibling did not start"
        time.sleep(0.01)
    sibling = int((root / "future.pid").read_text())
    refuses("future sibling signals", lambda: os.kill(sibling, 0))
    libc = ctypes.CDLL(None, use_errno=True)
    assert libc.prctl(15, b"\xff-action", 0, 0, 0) == 0  # /proc task names are bytes, not UTF-8.
    for option in (22, (1 << 32) | 22):
        result = libc.prctl(ctypes.c_ulong(option), 2, 0, 0, 0)
        assert result == -1 and ctypes.get_errno() == errno.EPERM, "replacement filter accepted"
    refuses("join worker group", lambda: os.setpgid(0, os.getpgid(worker)))
    refuses("worker limits", lambda: resource.prlimit(worker, resource.RLIMIT_NOFILE))
    refuses("signal owner", lambda: fcntl.fcntl(1, fcntl.F_SETOWN, worker))
    number = 25 if platform.machine() == "aarch64" else 72
    read_fd, write_fd = os.pipe()
    def raw(number: int, *args: object) -> None:
        if libc.syscall(number, *args) < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
    try:
        for cmd, value in ((fcntl.F_SETOWN, worker), (10, signal.SIGKILL)):
            refuses(f"high-bit fcntl {cmd}",
                    lambda: raw(number, read_fd, ctypes.c_ulong((1 << 32) | cmd), value))
    finally:
        os.close(read_fd)
        os.close(write_fd)
    refuses("old-table fchmodat2", lambda: raw(452, -100, os.fsencode(shared / "actions/other"), 0, 0))
    for directory in ("actions", "blobs", "locks", "cooperate"):
        path = shared / directory / "other"
        refuses(f"{directory} write", lambda: path.write_text("tampered"))
        refuses(f"{directory} delete", path.unlink)
        refuses(f"{directory} chmod", lambda: path.chmod(0))
        refuses(f"{directory} utime", lambda: os.utime(path))
        refuses(f"{directory} truncate", lambda: os.truncate(path, 0))
        for mode in (os.O_RDONLY, 3):
            refuses(f"{directory} readonly truncate {mode}", lambda: os.close(os.open(path, os.O_TRUNC | mode)))
    descriptors = []
    for fd in Path("/proc/self/fd").iterdir():
        try:
            descriptors.append(os.readlink(fd))
        except FileNotFoundError:
            pass
    assert not any("lease" in target or "cache.curl" in target or "seccomp" in target
                   for target in descriptors), descriptors
    status = Path("/proc/self/status").read_bytes()
    assert b"CapEff:\t0000000000000000" in status
    (root / "ordinary-output").write_text("ok")
    subprocess.run(["/bin/sh", "-c", "echo child > descendant-output"], check=True, cwd=root)
    if prover := os.environ.get("HOLBUILD_RUN_PROVER"):
        problem = root / "problem.p"
        problem.write_text("fof(a,axiom,p).\nfof(c,conjecture,p).\n")
        result = subprocess.run([prover, "--auto", str(problem)], check=True, capture_output=True, text=True)
        assert "SZS status Theorem" in result.stdout, result.stdout
    started = time.monotonic()
    timeout = subprocess.run(["/usr/bin/timeout", "0.1", "/bin/sleep", "2"])
    elapsed = time.monotonic() - started
    assert timeout.returncode == 124 and elapsed < 1.5, (timeout.returncode, elapsed)
    (root / "timeout-seconds").write_text(str(elapsed))
    zombie = os.fork()
    if zombie == 0:
        os.setsid()
        os._exit(0)
    os.waitid(os.P_PID, zombie, os.WEXITED | os.WNOWAIT)
    os.kill(zombie, 0)
    os.killpg(zombie, 0)
    os.waitpid(zombie, 0)
    for session in (False, True):
        read_fd, write_fd = os.pipe()
        child = os.fork()
        if child == 0:
            os.close(read_fd)
            if session:
                os.setsid()
            else:
                os.setpgid(0, 0)
            # Forked multi-threaded children need their own TGID, rather than
            # the original HOL PID, to work with pthread_kill.
            ready = threading.Event()
            release = threading.Event()
            thread = threading.Thread(target=lambda: (ready.set(), release.wait()))
            thread.start()
            ready.wait()
            signal.pthread_kill(thread.ident, 0)
            release.set()
            thread.join()
            os.write(write_fd, b"R")
            os.close(write_fd)
            signal.pause()
            os._exit(1)
        os.close(write_fd)
        assert os.read(read_fd, 1) == b"R"
        os.close(read_fd)
        os.killpg(child, signal.SIGKILL)
        _, status = os.waitpid(child, 0)
        assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGKILL, status
    child = os.fork()
    if child == 0:
        os.setsid()
        if os.fork():
            os._exit(0)
        (root / "linger.pid").write_text(str(os.getpid()))
        time.sleep(1)
        (root / "survived").write_text("bad")
        os._exit(0)
    (root / "report.json").write_text(json.dumps(denied))


def linger(root: Path) -> None:
    child = os.fork()
    if child == 0:
        os.setsid()
        if os.fork():
            os._exit(0)
        (root / "detached.pid").write_text(str(os.getpid()))
        time.sleep(20)
        os._exit(0)
    os.waitpid(child, 0)
    while not (root / "detached.pid").exists():
        time.sleep(0.01)
    (root / "cancel-ready").write_text(str(os.getpid()))
    time.sleep(20)


def worker(helper: Path, root: Path) -> None:
    private = root / "action"
    checkpoints = root / "checkpoints"
    private.mkdir()
    checkpoints.mkdir()
    (private / "supervisor.pid").write_text(str(os.getpid()))
    shared = root / "shared"
    for directory in ("actions", "blobs", "locks", "cooperate"):
        path = shared / directory
        path.mkdir(parents=True)
        (path / "other").write_text("original")
    secret = Path(os.environ["HOLBUILD_REMOTE_CACHE_CURL_CONFIG"])
    secret.write_text("cache-write-sentinel")
    secret.chmod(0o600)
    # Copy this probe into the action, as source staging does.
    probe = private / "probe.py"
    probe.write_bytes(Path(__file__).read_bytes())
    module = runpy.run_path(str(helper), run_name="sandbox")
    if os.environ.get("HOLBUILD_RUN_SLOW_CLEANUP"):
        finish = module["finish_children"]
        def slow_cleanup(leader: int) -> int:
            time.sleep(0.5)
            return finish(leader)
        module["run"].__globals__["finish_children"] = slow_cleanup
    linux = module["Linux"]()
    linux.abi = min(linux.abi, 2)  # Exercise the deployed kernel's policy on newer test hosts too.
    # libseccomp 2.5.4 lacks this name even on kernels implementing the call.
    resolve = linux.seccomp.seccomp_syscall_resolve_name
    linux.seccomp.seccomp_syscall_resolve_name = lambda name: -1 if name == b"fchmodat2" else resolve(name)
    readable = [Path(path) for path in ("/usr", "/bin", "/lib", "/lib64", "/etc/ld.so.cache", "/dev/urandom") if Path(path).exists()]
    if prover := shutil.which("eprover"):
        os.environ["HOLBUILD_RUN_PROVER"] = prover
        readable.append(Path(prover).resolve())
    policy = module["Policy"](
        [private, checkpoints],
        readable,
        [secret, shared],
    )
    with (shared / "cooperate/lease-sentinel").open("w") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX)
        os.set_inheritable(lease.fileno(), True)
        command = [sys.executable, str(probe), "--attack", str(private), str(os.getpid()), str(secret), str(shared)]
        if os.environ.get("HOLBUILD_RUN_CANCEL"):
            command = [sys.executable, str(probe), "--linger", str(private)]
        status = module["run"](linux, policy, command)
    if os.environ.get("HOLBUILD_RUN_CANCEL"):
        assert status == 128 + signal.SIGKILL, status
        for file in ("cancel-ready", "detached.pid"):
            try:
                os.kill(int((private / file).read_text()), 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError("cancelled descendant survived")
        print("supervisor cancellation reaped detached descendants")
        (private / "cancel-confirmed").write_text("reaped")
        return
    assert status == 0, status
    assert (private / "ordinary-output").read_text() == "ok"
    assert (private / "descendant-output").read_text().strip() == "child"
    for directory in ("actions", "blobs", "locks", "cooperate"):
        assert (shared / directory / "other").read_text() == "original"
        assert (shared / directory / "other").stat().st_mode & 0o777 == 0o644
    time.sleep(1.1)
    assert not (private / "survived").exists()
    if (private / "linger.pid").exists():
        try:
            os.kill(int((private / "linger.pid").read_text()), 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("detached descendant survived cleanup")
    print(f"{len(json.loads((private / 'report.json').read_text()))} credential/cache/process attacks denied; "
          f"timeout={float((private / 'timeout-seconds').read_text()):.3f}s; "
          f"process groups, sessions, threads and cleanup passed; prover={'passed' if prover else 'unavailable'}")


def completion_probe(helper: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="holbuild-completion-probe-") as directory:
        root = Path(directory)
        private = root / "private"
        private.mkdir()
        completed = root / "completion"
        for child_status, cleanup_failure in ((0, False), (1, False), (0, True)):
            completed.write_text("pending\n")
            module = runpy.run_path(str(helper), run_name="sandbox")
            if cleanup_failure:
                original = module["finish_children"]
                def failed_cleanup(leader: int) -> int:
                    original(leader)
                    raise module["SandboxError"]("injected cleanup failure")
                module["run"].__globals__["finish_children"] = failed_cleanup
            code = (
                "from pathlib import Path\n"
                f"try: Path({str(completed)!r}).write_text('forged')\n"
                "except PermissionError: pass\n"
                "else: raise AssertionError('HOL could forge completion')\n"
                f"Path({str(private / 'checkpoint')!r}).write_text('checkpoint')\n"
                f"raise SystemExit({child_status})\n"
            )
            previous = sys.argv
            try:
                sys.argv = [str(helper), "--write", str(private), "--completed", str(completed)]
                for path in ("/usr", "/bin", "/lib", "/lib64"):
                    if Path(path).exists():
                        sys.argv += ["--read", path]
                sys.argv += ["--", sys.executable, "-I", "-c", code]
                status = module["main"]()
            finally:
                sys.argv = previous
            assert status == (125 if cleanup_failure else child_status), status
            assert completed.read_text() == ("failed\n" if cleanup_failure else "validated\n")
        print("completion protected from HOL; proof failure validated; cleanup failure withheld completion")


if __name__ == "__main__":
    if sys.argv[1] == "--attack":
        attack(Path(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4]), Path(sys.argv[5]))
    elif sys.argv[1] == "--linger":
        linger(Path(sys.argv[2]))
    elif sys.argv[1] == "--worker":
        worker(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        completion_probe(Path(sys.argv[1]))
        with tempfile.TemporaryDirectory(prefix="holbuild-sandbox-probe-") as directory:
            env = {**os.environ, "REMOTE_EXEC_WORKER_TOKEN": "worker-token-sentinel", "HOLBUILD_REMOTE_CACHE_CURL_CONFIG": f"{directory}/cache.curl"}
            process = subprocess.Popen([sys.executable, __file__, "--worker", sys.argv[1], directory], env=env)
            sibling = None
            try:
                deadline = time.monotonic() + 10
                while not (Path(directory) / "action/future-ready").exists():
                    assert process.poll() is None, process.returncode
                    assert time.monotonic() < deadline, "action did not start"
                    time.sleep(0.01)
                # This same-UID process is outside the dedicated subreaper,
                # and is born AFTER the sandbox's signal policy was installed.
                sibling = subprocess.Popen(["/bin/sleep", "20"])
                (Path(directory) / "action/future.pid").write_text(str(sibling.pid))
                assert process.wait(timeout=15) == 0, process.returncode
                assert sibling.poll() is None, "action killed its future sibling"
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                if sibling is not None:
                    sibling.terminate()
                    sibling.wait()

            cancel_root = Path(directory) / "cancel"
            cancel_root.mkdir()
            cancelled = subprocess.Popen(
                [sys.executable, __file__, "--worker", sys.argv[1], str(cancel_root)],
                env={**env, "HOLBUILD_RUN_CANCEL": "1"},
            )
            try:
                deadline = time.monotonic() + 10
                while not (cancel_root / "action/cancel-ready").exists():
                    assert cancelled.poll() is None, cancelled.returncode
                    assert time.monotonic() < deadline, "cancellation action did not start"
                    time.sleep(0.01)
                cancelled.terminate()
                assert cancelled.wait(timeout=5) == 0, cancelled.returncode
            finally:
                if cancelled.poll() is None:
                    cancelled.terminate()
                    cancelled.wait(timeout=5)

            outer_root = Path(directory) / "outer-cancel"
            outer_root.mkdir()
            with (outer_root / "log").open("w") as log:
                outer = subprocess.Popen(
                    ["/bin/sh", "-c", "trap ':' EXIT; \"$@\"", "outer", sys.executable,
                     __file__, "--worker", sys.argv[1], str(outer_root)],
                    env={**env, "HOLBUILD_RUN_CANCEL": "1", "HOLBUILD_RUN_SLOW_CLEANUP": "1"},
                    start_new_session=True, stdout=log, stderr=subprocess.STDOUT,
                )
                supervisor = None
                try:
                    deadline = time.monotonic() + 10
                    while not (outer_root / "action/cancel-ready").exists():
                        assert outer.poll() is None, outer.returncode
                        assert time.monotonic() < deadline, "outer cancellation action did not start"
                        time.sleep(0.01)
                    pid = int((outer_root / "action/supervisor.pid").read_text())
                    supervisor = os.pidfd_open(pid)
                    os.killpg(outer.pid, signal.SIGTERM)
                    time.sleep(0.2)
                    try:
                        os.killpg(outer.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    assert not select.select([supervisor], [], [], 0)[0], "outer escalation killed reaper"
                    assert select.select([supervisor], [], [], 5)[0], "reaper did not finish"
                    assert (outer_root / "action/cancel-confirmed").read_text() == "reaped"
                    try:
                        os.waitpid(pid, 0)  # completion_probe made this driver a subreaper.
                    except ChildProcessError:
                        pass
                finally:
                    if supervisor is not None:
                        try:
                            signal.pidfd_send_signal(supervisor, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        os.close(supervisor)
                    if outer.poll() is None:
                        outer.kill()
                    outer.wait()
            print("outer cancellation escalation preserved slow descendant cleanup")
