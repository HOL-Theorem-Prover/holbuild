"""Linux confinement for exec-action's untrusted HOL process.

The supervisor stays outside the policy so it can reap the whole action before
the trusted caller reads its outputs. No optional or unsandboxed execution path.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
from pathlib import Path
import platform
import signal
import stat
import sys
from dataclasses import dataclass


class SandboxError(Exception):
    pass


class Ruleset(ctypes.Structure):
    _fields_ = [("filesystem", ctypes.c_uint64), ("network", ctypes.c_uint64), ("scoped", ctypes.c_uint64)]


class PathRule(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("access", ctypes.c_uint64), ("parent", ctypes.c_int32)]


class Comparison(ctypes.Structure):
    _fields_ = [("arg", ctypes.c_uint), ("op", ctypes.c_uint), ("a", ctypes.c_uint64), ("b", ctypes.c_uint64)]


class CapHeader(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]


class CapData(ctypes.Structure):
    _fields_ = [("effective", ctypes.c_uint32), ("permitted", ctypes.c_uint32), ("inheritable", ctypes.c_uint32)]


def checked(result: int, operation: str) -> int:
    if result < 0:
        raise SandboxError(f"{operation}: {os.strerror(ctypes.get_errno())}")
    return result


class Linux:
    def __init__(self) -> None:
        if sys.platform != "linux" or platform.machine() not in ("aarch64", "x86_64"):
            raise SandboxError("exec-action needs Linux aarch64 or x86_64")
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.syscall.restype = ctypes.c_long
        self.seccomp = ctypes.CDLL("libseccomp.so.2", use_errno=True)
        self.seccomp.seccomp_init.argtypes = [ctypes.c_uint32]
        self.seccomp.seccomp_init.restype = ctypes.c_void_p
        self.seccomp.seccomp_release.argtypes = [ctypes.c_void_p]
        self.seccomp.seccomp_load.argtypes = [ctypes.c_void_p]
        self.seccomp.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
        self.seccomp.seccomp_rule_add_array.argtypes = [
            ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint, ctypes.POINTER(Comparison)
        ]
        self.abi = checked(self.libc.syscall(444, 0, 0, 1), "Landlock ABI probe")
        if self.abi < 1:
            raise SandboxError("exec-action needs Landlock ABI >= 1")

    def prctl(self, option: int, arg: int = 0, arg2: int = 0) -> None:
        checked(self.libc.prctl(option, arg, arg2, 0, 0), f"prctl({option})")

    def drop_privileges(self) -> None:
        if os.geteuid() == 0:
            # Lock out root's implicit capabilities, including after execve.
            self.prctl(28, 1 | 2)  # PR_SET_SECUREBITS, NOROOT | NOROOT_LOCKED
            for capability in range(64):
                result = self.libc.prctl(24, capability, 0, 0, 0)  # CAPBSET_DROP
                if result < 0 and ctypes.get_errno() != errno.EINVAL:
                    checked(result, "drop capability bounding set")
        self.prctl(47, 4)  # PR_CAP_AMBIENT_CLEAR_ALL
        header = CapHeader(0x20080522, 0)
        data = (CapData * 2)()
        checked(self.libc.capset(ctypes.byref(header), data), "clear capabilities")
        self.prctl(38, 1)  # PR_SET_NO_NEW_PRIVS
        self.prctl(4, 0)  # PR_SET_DUMPABLE

    def confine_paths(self, readable: list[Path], writable: list[Path]) -> None:
        # Handle every filesystem right supported by this kernel. In particular,
        # never grant link creation, special files, or cross-directory REFER.
        handled = (1 << 13) - 1
        if self.abi >= 2:
            handled |= 1 << 13
        if self.abi >= 3:
            handled |= 1 << 14
        if self.abi >= 5:
            handled |= 1 << 15
        attr = Ruleset(handled, 0, 3 if self.abi >= 6 else 0)
        ruleset_size = 24 if self.abi >= 6 else 8
        fd = checked(self.libc.syscall(444, ctypes.byref(attr), ruleset_size, 0), "create Landlock policy")
        read = 1 | 4 | 8  # execute, read file, read directory
        write = read | 2 | 16 | 32 | 128 | 256  # write, remove dir/file, make dir/regular
        if self.abi >= 3:
            write |= 1 << 14
        try:
            for paths, access in ((readable, read), (writable, write)):
                for path in paths:
                    parent = os.open(path, os.O_PATH | os.O_CLOEXEC)
                    try:
                        allowed = access if stat.S_ISDIR(os.fstat(parent).st_mode) else access & (1 | 2 | 4 | (1 << 14))
                        rule = PathRule(allowed, parent)
                        checked(self.libc.syscall(445, fd, 1, ctypes.byref(rule), 0), f"Landlock rule {path}")
                    finally:
                        os.close(parent)
            checked(self.libc.syscall(446, fd, 0), "enforce Landlock policy")
        finally:
            os.close(fd)

    def confine_syscalls(self) -> None:
        lib = self.seccomp
        ctx = lib.seccomp_init(0x7FFF0000)  # SCMP_ACT_ALLOW
        if not ctx:
            raise SandboxError("seccomp_init failed")

        def deny(name: str, comparisons: list[Comparison] | None = None, *, error: int = errno.EPERM) -> None:
            number = lib.seccomp_syscall_resolve_name(name.encode())
            # These Linux APIs are newer than some supported libseccomp tables.
            number = {"setxattrat": 463, "removexattrat": 466, "file_setattr": 469}.get(name, number)
            if number < 0:
                return  # syscall does not exist on the native architecture
            values = comparisons or []
            array = (Comparison * len(values))(*values)
            result = lib.seccomp_rule_add_array(ctx, 0x50000 | error, number, len(values), array)
            if result != 0:
                raise SandboxError(f"seccomp rule {name}: {os.strerror(-result)}")

        try:
            for name in """
                chmod fchmod fchmodat fchmodat2 chown fchown lchown fchownat
                utime utimes futimesat utimensat setxattr lsetxattr fsetxattr
                removexattr lremovexattr fremovexattr setxattrat removexattrat file_setattr
                truncate ftruncate flock io_uring_setup io_uring_enter io_uring_register
                ptrace process_vm_readv process_vm_writev process_madvise process_mrelease
                pidfd_open pidfd_getfd pidfd_send_signal kcmp perf_event_open bpf userfaultfd
                kill tkill rt_sigqueueinfo rt_tgsigqueueinfo
                link linkat symlink symlinkat mknod mknodat
                setsid setpgid unshare setns chroot pivot_root mount umount2
                move_mount open_tree fsopen fsconfig fsmount fspick mount_setattr
                open_by_handle_at name_to_handle_at openat2
                keyctl add_key request_key shmget shmat shmdt shmctl semget semop semtimedop semctl
                msgget msgsnd msgrcv msgctl mq_open mq_unlink mq_timedsend mq_timedreceive mq_notify mq_getsetattr
                migrate_pages move_pages setpriority ioprio_set
                setuid setgid setreuid setregid setresuid setresgid setfsuid setfsgid setgroups capset
                reboot kexec_load kexec_file_load init_module finit_module delete_module swapon swapoff
                acct quotactl settimeofday clock_settime adjtimex clock_adjtime sethostname setdomainname
            """.split():
                deny(name)
            deny("clone3", error=errno.ENOSYS)
            # A clone with a new namespace could evade process-group cleanup.
            for flag in (0x80, 0x20000, 0x2000000, 0x4000000, 0x8000000, 0x10000000, 0x20000000, 0x40000000):
                deny("clone", [Comparison(0, 7, flag, flag)])  # MASKED_EQ
            deny("tgkill", [Comparison(0, 1, os.getpid(), 0)])  # NE: Poly GC signals stay within HOL
            for name in ("prlimit64", "sched_setaffinity", "sched_setattr", "sched_setscheduler", "sched_setparam"):
                deny(name, [Comparison(0, 1, 0, 0)])
            for cmd in (5, 6, 7, 8, 9, 10, 15, 36, 37, 38):
                deny("fcntl", [Comparison(1, 4, cmd, 0)])  # EQ: locks and signal ownership
            deny("ioctl", error=errno.ENOTTY)
            for name, argument in (("open", 1), ("openat", 2)):
                for access in (0, 3):
                    deny(name, [Comparison(argument, 7, os.O_ACCMODE | os.O_TRUNC, os.O_TRUNC | access)])
            result = lib.seccomp_load(ctx)
            if result != 0:
                raise SandboxError(f"seccomp_load: {os.strerror(-result)}")
        finally:
            lib.seccomp_release(ctx)


def sanitized_environment(home: Path) -> dict[str, str]:
    env = {
        key: value for key, value in os.environ.items()
        if key in {"PATH", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "SSL_CERT_FILE", "SSL_CERT_DIR"}
        or key.startswith("HOLBUILD_RUN_")
    }
    env.update(HOME=str(home), TMPDIR=str(home / "tmp"))
    return env


@dataclass
class Policy:
    writable: list[Path]
    readable: list[Path]
    forbidden: list[Path]

    def validate(self) -> None:
        for grant in self.readable + self.writable:
            if not grant.exists():
                raise SandboxError(f"sandbox grant does not exist: {grant}")
            if any(path == grant or grant in path.parents for path in self.forbidden):
                raise SandboxError(f"sandbox grant contains protected worker state: {grant}")

    def validate_outputs(self) -> None:
        # With all descendants reaped, one no-follow walk validates every file
        # the trusted caller can harvest without a check/read race.
        for root in self.writable:
            if not root.is_dir():
                continue
            for directory, dirs, files in os.walk(root, followlinks=False):
                for name in dirs + files:
                    path = Path(directory) / name
                    info = path.lstat()
                    if stat.S_ISDIR(info.st_mode):
                        continue
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                        raise SandboxError(f"action produced a linked or special file: {path}")


def run(linux: Linux, policy: Policy, argv: list[str]) -> int:
    policy.validate()
    policy.validate_outputs()
    home = policy.writable[0] / ".holbuild/sandbox-home"
    (home / "tmp").mkdir(parents=True, exist_ok=True)
    env = sanitized_environment(home)
    # exec_run prefixes argv with env assignments. Apply only its declared
    # script context and exec HOL itself, keeping the PID used by the policy.
    if argv and argv[0] == "env":
        argv = argv[1:]
        while argv and "=" in argv[0]:
            key, value = argv.pop(0).split("=", 1)
            if not key.startswith("HOLBUILD_RUN_"):
                raise SandboxError(f"unexpected action environment assignment: {key}")
            env[key] = value
    if not argv:
        raise SandboxError("missing action command")
    linux.prctl(36, 1)  # PR_SET_CHILD_SUBREAPER
    signals = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    parent = os.getpid()
    child = os.fork()
    if child == 0:
        try:
            os.setpgid(0, 0)
            linux.prctl(1, signal.SIGKILL)  # PR_SET_PDEATHSIG
            if os.getppid() != parent:
                os._exit(125)
            for sig in signals:
                signal.signal(sig, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            null = os.open("/dev/null", os.O_RDONLY)
            os.dup2(null, 0)
            for fd in os.listdir("/proc/self/fd"):
                if int(fd) >= 3:
                    try:
                        os.close(int(fd))
                    except OSError as error:
                        if error.errno != errno.EBADF:
                            raise
            linux.drop_privileges()
            linux.confine_paths(policy.readable + [Path(f"/proc/{os.getpid()}")], policy.writable + [Path("/dev/null")])
            linux.confine_syscalls()
            os.execvpe(argv[0], argv, env)
        except Exception as error:
            print(f"holbuild sandbox: {error}", file=sys.stderr, flush=True)
            os._exit(125)

    def kill_group(_signum: int = 0, _frame: object = None) -> None:
        try:
            os.killpg(child, signal.SIGKILL)
        except ProcessLookupError:
            pass

    # Either side may establish the group first. Cancellation stays blocked
    # until the group exists and its handler is installed.
    try:
        os.setpgid(child, child)
    except PermissionError:
        pass  # child has already exec'd, after establishing its group
    previous_handlers = {sig: signal.signal(sig, kill_group) for sig in signals}
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    try:
        # WNOWAIT holds the leader's PID until after killpg (no PID reuse race).
        result = os.waitid(os.P_PID, child, os.WEXITED | os.WNOWAIT)
    finally:
        kill_group()
        while True:
            try:
                os.waitpid(-1, 0)
            except ChildProcessError:
                break
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
    policy.validate_outputs()
    return result.si_status if result.si_code == os.CLD_EXITED else 128 + result.si_status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--write", action="append", default=[])
    parser.add_argument("--read", action="append", default=[])
    parser.add_argument("--forbid", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        linux = Linux()
        if args.check:
            # Exercise stacking, not just the version syscall, in a child.
            child = os.fork()
            if child == 0:
                try:
                    linux.drop_privileges()
                    linux.confine_paths([], [])
                    linux.confine_syscalls()
                    os._exit(0)
                except Exception:
                    os._exit(125)
            return os.waitstatus_to_exitcode(os.waitpid(child, 0)[1])
        policy = Policy(
            [Path(path).resolve(strict=True) for path in args.write],
            [Path(path).resolve(strict=True) for path in args.read],
            [Path(path).resolve() for path in args.forbid],
        )
        if not policy.writable:
            raise SandboxError("missing private action directory")
        argv = args.command[1:] if args.command[:1] == ["--"] else args.command
        return run(linux, policy, argv)
    except (OSError, SandboxError) as error:
        print(f"holbuild sandbox: {error}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    sys.exit(main())
