"""Exercise the encountered same-user credential/cache attacks with sentinel state."""

import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import resource
import runpy
import shutil
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
    refuses("worker limits", lambda: resource.prlimit(worker, resource.RLIMIT_NOFILE))
    refuses("signal owner", lambda: fcntl.fcntl(1, fcntl.F_SETOWN, worker))
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
    assert not any("lease" in target or "cache.curl" in target for target in descriptors), descriptors
    status = Path("/proc/self/status").read_text()
    assert "CapEff:\t0000000000000000" in status
    (root / "ordinary-output").write_text("ok")
    subprocess.run(["/bin/sh", "-c", "echo child > descendant-output"], check=True, cwd=root)
    if prover := os.environ.get("HOLBUILD_RUN_PROVER"):
        problem = root / "problem.p"
        problem.write_text("fof(a,axiom,p).\nfof(c,conjecture,p).\n")
        result = subprocess.run([prover, "--auto", str(problem)], check=True, capture_output=True, text=True)
        assert "SZS status Theorem" in result.stdout, result.stdout
    child = os.fork()
    if child == 0:
        time.sleep(1)
        (root / "survived").write_text("bad")
        os._exit(0)
    (root / "report.json").write_text(json.dumps(denied))


def worker(helper: Path, root: Path) -> None:
    private = root / "action"
    checkpoints = root / "checkpoints"
    private.mkdir()
    checkpoints.mkdir()
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
    linux = module["Linux"]()
    linux.abi = min(linux.abi, 2)  # Exercise the deployed kernel's policy on newer test hosts too.
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
        status = module["run"](linux, policy, [sys.executable, str(probe), "--attack", str(private), str(os.getpid()), str(secret), str(shared)])
    assert status == 0, status
    assert (private / "ordinary-output").read_text() == "ok"
    assert (private / "descendant-output").read_text().strip() == "child"
    for directory in ("actions", "blobs", "locks", "cooperate"):
        assert (shared / directory / "other").read_text() == "original"
        assert (shared / directory / "other").stat().st_mode & 0o777 == 0o644
    time.sleep(1.1)
    assert not (private / "survived").exists()
    print(f"{len(json.loads((private / 'report.json').read_text()))} credential/cache/process attacks denied; normal child and cleanup passed; prover={'passed' if prover else 'unavailable'}")


if __name__ == "__main__":
    if sys.argv[1] == "--attack":
        attack(Path(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4]), Path(sys.argv[5]))
    elif sys.argv[1] == "--worker":
        worker(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        with tempfile.TemporaryDirectory(prefix="holbuild-sandbox-probe-") as directory:
            env = {**os.environ, "REMOTE_EXEC_WORKER_TOKEN": "worker-token-sentinel", "HOLBUILD_REMOTE_CACHE_CURL_CONFIG": f"{directory}/cache.curl"}
            subprocess.run([sys.executable, __file__, "--worker", sys.argv[1], directory], env=env, check=True)
