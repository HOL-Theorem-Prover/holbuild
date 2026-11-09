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
import select
import socket
import signal
import stat
import sys
import tempfile
import time
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


class SyscallData(ctypes.Structure):
    _fields_ = [("number", ctypes.c_int), ("arch", ctypes.c_uint32),
                ("ip", ctypes.c_uint64), ("args", ctypes.c_uint64 * 6)]


class Notification(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint64), ("pid", ctypes.c_uint32),
                ("flags", ctypes.c_uint32), ("data", SyscallData)]


class Response(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint64), ("value", ctypes.c_int64),
                ("error", ctypes.c_int32), ("flags", ctypes.c_uint32)]


class NotificationSizes(ctypes.Structure):
    _fields_ = [("request", ctypes.c_uint16), ("response", ctypes.c_uint16),
                ("data", ctypes.c_uint16)]


class FilterProgram(ctypes.Structure):
    _fields_ = [("length", ctypes.c_ushort), ("instructions", ctypes.c_void_p)]


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
        self.seccomp.seccomp_export_bpf.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.seccomp.seccomp_notify_alloc.argtypes = [
            ctypes.POINTER(ctypes.POINTER(Notification)), ctypes.POINTER(ctypes.POINTER(Response))
        ]
        self.seccomp.seccomp_notify_free.argtypes = [ctypes.POINTER(Notification), ctypes.POINTER(Response)]
        self.seccomp.seccomp_notify_receive.argtypes = [ctypes.c_int, ctypes.POINTER(Notification)]
        self.seccomp.seccomp_notify_respond.argtypes = [ctypes.c_int, ctypes.POINTER(Response)]
        self.seccomp.seccomp_notify_id_valid.argtypes = [ctypes.c_int, ctypes.c_uint64]
        self.seccomp_number = self.seccomp.seccomp_syscall_resolve_name(b"seccomp")
        self.sizes = NotificationSizes()
        checked(self.libc.syscall(self.seccomp_number, 3, 0, ctypes.byref(self.sizes)), "notification sizes")
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

    def confine_syscalls(self) -> int:
        lib = self.seccomp
        ctx = lib.seccomp_init(0x7FFF0000)  # SCMP_ACT_ALLOW
        if not ctx:
            raise SandboxError("seccomp_init failed")

        def deny(name: str, comparisons: list[Comparison] | None = None, *, error: int = errno.EPERM,
                 action: int | None = None) -> None:
            number = lib.seccomp_syscall_resolve_name(name.encode())
            # These Linux APIs are newer than some supported libseccomp tables.
            number = {"fchmodat2": 452, "setxattrat": 463, "removexattrat": 466,
                      "file_setattr": 469}.get(name, number)
            if number < 0:
                return  # syscall does not exist on the native architecture
            values = comparisons or []
            array = (Comparison * len(values))(*values)
            result = lib.seccomp_rule_add_array(ctx, action if action is not None else 0x50000 | error,
                                                number, len(values), array)
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
                tkill rt_sigqueueinfo rt_tgsigqueueinfo seccomp
                link linkat symlink symlinkat mknod mknodat
                unshare setns chroot pivot_root mount umount2
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
            deny("kill", action=0x7FC00000)  # SCMP_ACT_NOTIFY
            deny("tgkill", action=0x7FC00000)
            # prctl takes a 32-bit option, even on a 64-bit syscall ABI.
            deny("prctl", [Comparison(0, 7, 0xFFFFFFFF, 22)])  # PR_SET_SECCOMP
            for name in ("prlimit64", "sched_setaffinity", "sched_setattr", "sched_setscheduler", "sched_setparam"):
                deny(name, [Comparison(0, 1, 0, 0)])
            for cmd in (5, 6, 7, 8, 9, 10, 15, 36, 37, 38):
                deny("fcntl", [Comparison(1, 7, 0xFFFFFFFF, cmd)])  # 32-bit command: locks and signal ownership
            deny("ioctl", error=errno.ENOTTY)
            for name, argument in (("open", 1), ("openat", 2)):
                for access in (0, 3):
                    deny(name, [Comparison(argument, 7, os.O_ACCMODE | os.O_TRUNC, os.O_TRUNC | access)])
            # Export libseccomp's native-architecture BPF and load it directly:
            # libseccomp 2.5 has no WAIT_KILLABLE_RECV filter attribute. This
            # flag prevents caught signals interrupting a mediated kill.
            fd = os.memfd_create("holbuild-policy", os.MFD_CLOEXEC)
            try:
                result = lib.seccomp_export_bpf(ctx, fd)
                if result != 0:
                    raise SandboxError(f"seccomp_export_bpf: {os.strerror(-result)}")
                os.lseek(fd, 0, os.SEEK_SET)
                data = os.read(fd, os.fstat(fd).st_size)
            finally:
                os.close(fd)
            instructions = ctypes.create_string_buffer(data)
            program = FilterProgram(len(data) // 8, ctypes.cast(instructions, ctypes.c_void_p))
            listener = self.libc.syscall(self.seccomp_number, 1, 8 | 32, ctypes.byref(program))
            if listener < 0 and ctypes.get_errno() == errno.EINVAL:
                listener = self.libc.syscall(self.seccomp_number, 1, 8, ctypes.byref(program))
            return checked(listener, "load notifying seccomp policy")
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
            if any(path == grant or grant in path.parents or path in grant.parents for path in self.forbidden):
                raise SandboxError(f"sandbox grant contains protected worker state: {grant}")

    def validate_outputs(self) -> None:
        # With all descendants reaped, one no-follow walk validates every file
        # the trusted caller can harvest without a check/read race.
        for root in self.writable:
            if not root.is_dir():
                continue
            # A directory the walk cannot list hides what is inside it.
            for directory, dirs, files in os.walk(root, onerror=raise_error, followlinks=False):
                for name in dirs + files:
                    path = Path(directory) / name
                    info = path.lstat()
                    if stat.S_ISDIR(info.st_mode):
                        continue
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                        raise SandboxError(f"action produced a linked or special file: {path}")


def raise_error(error: OSError) -> None:
    raise SandboxError(f"cannot validate action output: {error}")


def process_info(pid: int) -> tuple[int, int]:
    fields = Path(f"/proc/{pid}/stat").read_bytes().rsplit(b")", 1)[1].split()
    return int(fields[1]), int(fields[2])  # parent PID, process group


def thread_group(tid: int) -> int:
    # comm may contain carriage returns, so only kernel LF boundaries count.
    for line in Path(f"/proc/{tid}/status").read_bytes().split(b"\n"):
        if line.startswith(b"Tgid:\t"):
            return int(line.split()[1])
    raise SandboxError("missing process thread group")


@dataclass
class Process:
    pid: int
    fd: int
    group: int

    def alive(self) -> bool:
        return not select.select([self.fd], [], [], 0)[0]

    def exists(self) -> bool:
        try:
            self.send(0)  # Includes unreaped zombies, whose PID is still reserved.
            return True
        except ProcessLookupError:
            return False

    def send(self, sig: int) -> None:
        signal.pidfd_send_signal(self.fd, sig)


def descendants() -> dict[int, Process]:
    """Discover only verified edges below this dedicated, live subreaper.

    A numeric upward PPID walk can follow a dead outsider's recycled parent
    PID into this tree. Pin each downward edge and check both endpoints after
    reading it; a dead parent's stale children list cannot authorize an edge.
    """
    found: dict[int, Process] = {}
    try:
        for _ in range(4):
            added = False
            pending = [os.getpid()]
            visited: set[int] = set()
            while pending:
                parent = pending.pop()
                if parent in visited:
                    continue
                visited.add(parent)
                pinned_parent = found.get(parent)
                if pinned_parent is not None and not pinned_parent.alive():
                    continue
                try:
                    tasks = list(Path(f"/proc/{parent}/task").iterdir())
                except (FileNotFoundError, ProcessLookupError):
                    continue
                children: set[int] = set()
                for task in tasks:
                    try:
                        children.update(map(int, (task / "children").read_text().split()))
                    except (FileNotFoundError, ProcessLookupError):
                        continue  # thread exited during the scan
                for pid in children:
                    candidate = None
                    try:
                        candidate = Process(pid, os.pidfd_open(pid), 0)
                        ppid, candidate.group = process_info(pid)
                        if ppid != parent or not candidate.exists() or (
                            pinned_parent is not None and not pinned_parent.alive()
                        ):
                            continue
                        previous = found.get(pid)
                        if previous is not None:
                            os.close(previous.fd)
                        else:
                            added = True
                        found[pid] = candidate
                        candidate = None
                        pending.append(pid)
                    except ProcessLookupError:
                        pass
                    except FileNotFoundError:
                        pass
                    finally:
                        if candidate is not None:
                            os.close(candidate.fd)
            if not added:
                break
        return found
    except BaseException:
        close_processes(found)
        raise


def close_processes(processes: dict[int, Process]) -> None:
    for process in processes.values():
        os.close(process.fd)


def finish_children(leader: int) -> int:
    # Stop to a fixed point before killing: detached children may fork while
    # /proc is being scanned. A fixed sweep bound treats an overwhelming fork
    # storm as failure, never as a successful action with validated outputs.
    settled = False
    previous: set[int] = set()
    for _ in range(64):
        processes = descendants()
        try:
            current = {pid for pid, process in processes.items() if process.alive()}
            for process in processes.values():
                try:
                    process.send(signal.SIGSTOP)
                except ProcessLookupError:
                    pass
            if current <= previous:
                settled = True
                break
            previous = current
        finally:
            close_processes(processes)
    # There can be adopted zombies as well as the held leader. Kill all pinned
    # descendants, then reap direct children without waiting on a live subgroup.
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        processes = descendants()
        try:
            for process in processes.values():
                try:
                    process.send(signal.SIGKILL)
                except ProcessLookupError:
                    pass
            # Check exits before reading this subreaper's children: a dying
            # process's orphans are adopted before its pidfd reports the exit,
            # so a child forked after the scan above shows up here.
            exited = all(not process.alive() for process in processes.values())
            children = set(map(int, Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()))
            for pid in children - {leader}:
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
            if exited and children <= {leader}:
                _, status = os.waitpid(leader, 0)
                if not settled:
                    raise SandboxError("action exceeded process cleanup sweep limit")
                return status
        finally:
            close_processes(processes)
        time.sleep(0.005)
    raise SandboxError("action descendants did not exit during cleanup")


class SignalBroker:
    def __init__(self, linux: Linux, fd: int) -> None:
        self.linux = linux
        self.fd = fd
        self.request = ctypes.POINTER(Notification)()
        self.response = ctypes.POINTER(Response)()
        result = linux.seccomp.seccomp_notify_alloc(ctypes.byref(self.request), ctypes.byref(self.response))
        if result != 0:
            raise SandboxError(f"allocate notifications: {os.strerror(-result)}")
        self.tgkill = linux.seccomp.seccomp_syscall_resolve_name(b"tgkill")

    def close(self) -> None:
        self.linux.seccomp.seccomp_notify_free(self.request, self.response)
        os.close(self.fd)

    def valid(self, identity: int) -> bool:
        result = self.linux.seccomp.seccomp_notify_id_valid(self.fd, identity)
        if result in (-errno.ENOENT, -errno.ECANCELED, -errno.EINTR):
            return False
        if result != 0:
            raise SandboxError(f"validate notification: {os.strerror(-result)}")
        return True

    def handle(self) -> None:
        lib = self.linux.seccomp
        ctypes.memset(self.request, 0, self.linux.sizes.request)
        result = lib.seccomp_notify_receive(self.fd, self.request)
        if result in (-errno.ENOENT, -errno.ECANCELED, -errno.EINTR):
            return
        if result != 0:
            raise SandboxError(f"receive notification: {os.strerror(-result)}")
        request = self.request.contents
        ctypes.memset(self.response, 0, self.linux.sizes.response)
        response = self.response.contents
        response.id = request.id
        try:
            target = ctypes.c_int32(request.data.args[0]).value
            caller = thread_group(request.pid)
            if not self.valid(request.id):
                return
            if request.data.number == self.tgkill:
                if target != caller:
                    raise PermissionError(errno.EPERM, "thread signal outside caller")
                # Scalar arguments belong to the blocked caller; the kernel
                # still verifies that the target TID belongs to its own TGID.
                response.flags = 1  # SECCOMP_USER_NOTIF_FLAG_CONTINUE
            elif target == caller:
                response.flags = 1  # native self-signal avoids caught-signal EINTR
            else:
                self.send(request, target, caller)
        except OSError as error:
            response.error = -(errno.ESRCH if error.errno == errno.ENOENT else error.errno or errno.EPERM)
        result = lib.seccomp_notify_respond(self.fd, self.response)
        if result not in (0, -errno.ENOENT, -errno.ECANCELED, -errno.EINTR):
            raise SandboxError(f"respond to notification: {os.strerror(-result)}")

    def send(self, request: Notification, target: int, caller: int) -> None:
        sig = ctypes.c_int32(request.data.args[1]).value
        if sig < 0 or sig >= signal.NSIG:
            raise OSError(errno.EINVAL, "invalid signal")
        if target == -1:
            raise PermissionError(errno.EPERM, "broadcast signal")
        processes = descendants()
        try:
            if target > 0:
                # kill accepts a nonleader TID too, delivering to its process.
                tgid = thread_group(target)
                selected = [processes[tgid]] if tgid in processes else []
                if not selected:
                    raise PermissionError(errno.EPERM, "signal outside action")
            else:
                group = process_info(request.pid)[1] if target == 0 else -target
                selected = []
                for process in processes.values():
                    try:
                        _, process.group = process_info(process.pid)
                        if process.exists() and process.group == group:
                            selected.append(process)
                    except (FileNotFoundError, ProcessLookupError):
                        pass
                if not selected:
                    # Probe with signal zero only; never send a real group
                    # signal from this privileged side of the boundary.
                    os.kill(-group, 0)
                    raise PermissionError(errno.EPERM, "group outside action")
            if not self.valid(request.id):
                return
            # A fatal self/group signal can cancel its own notification. Deliver
            # to the requesting process last so all other members are signaled.
            selected.sort(key=lambda process: process.pid == caller)
            delivered = False
            for process in selected:
                try:
                    process.send(sig)
                    delivered = True
                except ProcessLookupError:
                    pass
            if not delivered:
                raise ProcessLookupError(errno.ESRCH, "signal target exited")
        finally:
            close_processes(processes)


def run(linux: Linux, policy: Policy, argv: list[str], *, parent: int | None = None) -> int:
    policy.validate()
    policy.validate_outputs()
    # CONFIG_PROC_CHILDREN is required by the verified descendant walk.
    Path(f"/proc/self/task/{os.getpid()}/children").read_text()
    home = policy.writable[0] / ".holbuild/sandbox-home"
    (home / "tmp").mkdir(parents=True, exist_ok=True)
    env = sanitized_environment(home)
    if argv and argv[0] == "env":
        argv = argv[1:]
        while argv and "=" in argv[0]:
            key, value = argv.pop(0).split("=", 1)
            if not key.startswith("HOLBUILD_RUN_"):
                raise SandboxError(f"unexpected action environment assignment: {key}")
            env[key] = value
    if not argv:
        raise SandboxError("missing action command")
    expected_parent = os.getppid() if parent is None else parent
    if os.getppid() != expected_parent:
        raise SandboxError("sandbox launcher exited before startup")
    parent_fd = os.pidfd_open(expected_parent)
    if os.getppid() != expected_parent or select.select([parent_fd], [], [], 0)[0]:
        os.close(parent_fd)
        raise SandboxError("sandbox launcher exited before startup")
    # The outer shell's watcher escalates to group SIGKILL after 200 ms.
    # Keep this trusted reaper outside that group and watch its parent by
    # pidfd, so cancellation still permits the bounded descendant cleanup.
    if os.getpgrp() != os.getpid():
        os.setpgid(0, 0)
    linux.prctl(36, 1)  # PR_SET_CHILD_SUBREAPER
    signals = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    wake_read, wake_write = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
    previous_wakeup = signal.set_wakeup_fd(wake_write)
    previous_handlers = {sig: signal.signal(sig, lambda *_: None) for sig in signals}
    parent_socket, child_socket = socket.socketpair()
    parent = os.getpid()
    child = os.fork()
    if child == 0:
        try:
            os.setsid()
            signal.set_wakeup_fd(-1)
            linux.prctl(1, signal.SIGKILL)  # PR_SET_PDEATHSIG
            if os.getppid() != parent:
                os._exit(125)
            for sig in signals:
                signal.signal(sig, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            null = os.open("/dev/null", os.O_RDONLY)
            os.dup2(null, 0)
            for fd in os.listdir("/proc/self/fd"):
                if int(fd) >= 3 and int(fd) != child_socket.fileno():
                    try:
                        os.close(int(fd))
                    except OSError as error:
                        if error.errno != errno.EBADF:
                            raise
            linux.drop_privileges()
            linux.confine_paths(policy.readable + [Path(f"/proc/{os.getpid()}")], policy.writable + [Path("/dev/null")])
            listener = linux.confine_syscalls()
            socket.send_fds(child_socket, [b"N"], [listener])
            os.close(listener)
            child_socket.close()
            os.execvpe(argv[0], argv, env)
        except Exception as error:
            print(f"holbuild sandbox: {error}", file=sys.stderr, flush=True)
            os._exit(125)
    child_socket.close()
    leader_fd = os.pidfd_open(child)
    broker = None
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    try:
        poller = select.poll()
        poller.register(wake_read, select.POLLIN)
        poller.register(leader_fd, select.POLLIN)
        poller.register(parent_fd, select.POLLIN)
        poller.register(parent_socket, select.POLLIN)
        done = False
        while not done:
            # A short-lived child can finish before we are scheduled. Consume
            # its setup handoff before acting on simultaneous leader exit.
            for fd, _ in sorted(poller.poll(), key=lambda event: event[0] != parent_socket.fileno()):
                if fd in (wake_read, leader_fd, parent_fd):
                    done = True
                    break
                if fd == parent_socket.fileno():
                    data, descriptors, _, _ = socket.recv_fds(parent_socket, 1, 1)
                    if data != b"N" or len(descriptors) != 1:
                        for descriptor in descriptors:
                            os.close(descriptor)
                        raise SandboxError("missing seccomp listener handshake")
                    broker = SignalBroker(linux, descriptors[0])
                    poller.unregister(parent_socket)
                    parent_socket.close()
                    poller.register(broker.fd, select.POLLIN)
                elif broker is not None and fd == broker.fd:
                    broker.handle()
        # Wait without reaping: keep the initial leader's PID reserved until
        # cleanup has stopped all descendants and completed its final sweep.
    finally:
        try:
            status = finish_children(child)
        finally:
            if broker is not None:
                broker.close()
            parent_socket.close()
            os.close(leader_fd)
            os.close(parent_fd)
            signal.pthread_sigmask(signal.SIG_BLOCK, signals)
            signal.set_wakeup_fd(previous_wakeup)
            for sig, handler in previous_handlers.items():
                signal.signal(sig, handler)
            os.close(wake_read)
            os.close(wake_write)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    code = os.waitstatus_to_exitcode(status)
    if broker is None or code == 125:
        raise SandboxError("HOL child setup or execution failed before confirmed completion")
    policy.validate_outputs()
    return code if code >= 0 else 128 - code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--write", action="append", default=[])
    parser.add_argument("--read", action="append", default=[])
    parser.add_argument("--forbid", action="append", default=[])
    parser.add_argument("--completed", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        linux = Linux()
        if args.check:
            # Exercise the same FD handoff, notification and cleanup path as
            # an action, including CONFIG_PROC_CHILDREN and pidfd support.
            with tempfile.TemporaryDirectory(prefix="holbuild-sandbox-") as directory:
                root = Path(directory)
                readable = [Path(path).resolve() for path in
                            ("/usr", "/bin", "/lib", "/lib64", "/etc/ld.so.cache", sys.prefix, sys.base_prefix)
                            if Path(path).exists()]
                return run(linux, Policy([root], readable, []),
                           [sys.executable, "-I", "-c", "import os; os.kill(os.getpid(), 0)"])
        policy = Policy(
            [Path(path).resolve(strict=True) for path in args.write],
            [Path(path).resolve(strict=True) for path in args.read],
            [Path(path).resolve() for path in args.forbid] +
            ([args.completed.resolve()] if args.completed is not None else []),
        )
        if not policy.writable:
            raise SandboxError("missing private action directory")
        parent = os.environ.get("HOLBUILD_SANDBOX_PARENT")
        if args.completed is not None and (parent is None or not parent.isascii() or
                                           not parent.isdecimal() or int(parent) <= 0):
            raise SandboxError("missing trusted sandbox launcher identity")
        argv = args.command[1:] if args.command[:1] == ["--"] else args.command
        status = run(linux, policy, argv, parent=int(parent) if parent is not None else None)
        if args.completed is not None:
            args.completed.write_text("validated\n")
        return status
    except Exception as error:
        print(f"holbuild sandbox: {error}", file=sys.stderr)
        if args.completed is not None:
            try:
                args.completed.write_text("failed\n")
            except OSError:
                pass  # Missing confirmation still fails closed in the parent.
        return 125


if __name__ == "__main__":
    sys.exit(main())
