"""The sandbox helper's path checks at the scale of a deep theory's grants.

Usage: action_sandbox_paths.py HELPER SCRATCH_DIR

within, exposure and existing must decide as the Path-based checks they
replaced, and a launch with thousands of module read grants must stay fast.
"""

from __future__ import annotations

import importlib.util
import itertools
import os
from pathlib import Path
import subprocess
import sys
import time


def load(helper: str):
    spec = importlib.util.spec_from_file_location("action_sandbox", helper)
    module = importlib.util.module_from_spec(spec)
    sys.modules["action_sandbox"] = module  # dataclasses look the module up
    spec.loader.exec_module(module)
    return module


def check_within(sandbox) -> None:
    names = ["/", "//", "/foo", "/foobar", "/foo/bar", "/foo/bar/baz", "/foo/barbaz", "//foo", "//foo/bar",
             "/fo", "/foo bar", "/tmp", "/tmp/MLTEMP1"]
    paths = [Path(name) for name in names]
    for path, root in itertools.product(paths, paths):
        expected = path == root or root in path.parents
        assert sandbox.within(path, root) == expected, (path, root, expected)


def check_exposure(sandbox) -> None:
    names = ["/", "//", "/foo", "/foobar", "/foo/bar", "/foo/bar/baz", "//foo", "/cache/blobs", "/cache/blobsx"]
    paths = [Path(name) for name in names]
    for size in range(3):
        for forbidden in itertools.combinations(paths, size):
            exposes = sandbox.exposure(list(forbidden))
            for grant in paths:
                expected = any(path == grant or grant in path.parents or path in grant.parents for path in forbidden)
                got = exposes(grant)
                # Path.parents keeps "//" apart from "/"; refusing it too is stricter.
                stricter = got and Path("/") in forbidden and str(grant).startswith("//")
                assert got == expected or stricter, (grant, forbidden, expected)


def check_existing(sandbox, root: Path) -> None:
    store = root / "store"
    (store / "sub").mkdir(parents=True)
    (store / "a.pmo").write_text("a")
    (store / "sub" / "b.pmo").write_text("b")
    (root / "linked").symlink_to(store)
    (store / "relative.pmo").symlink_to("sub/b.pmo")
    (store / "absolute.pmo").symlink_to(store / "a.pmo")
    (store / "dangling.pmo").symlink_to("missing.pmo")
    (store / "up").symlink_to("sub")
    paths = [str(path) for path in [
        store / "a.pmo", root / "linked" / "a.pmo", root / "linked" / "sub" / "b.pmo", store / "relative.pmo",
        root / "linked" / "absolute.pmo", store / "dangling.pmo", store / "gone.pmo", root / "gone" / "x.pmo",
        store / "up" / ".." / "a.pmo", store / "sub" / "..", store / "sub" / ".", store / "sub",
    ]] + [f"{store}/sub/", f"{root}//linked//a.pmo", "/"]
    expected = []
    for path in paths:
        try:
            expected.append(Path(path).resolve(strict=True))
        except FileNotFoundError:
            pass
    assert sandbox.existing(paths) == expected, (sandbox.existing(paths), expected)


def check_many_grants(sandbox, helper: str, root: Path) -> None:
    """A deep theory's module grants: 7,000 files in one store reached
    through a link, and the worker's protected paths.  The helper's path
    checks on them, and a whole launch whose child reads the last module."""
    store = root / "theory-modules" / ("0" * 40)
    store.mkdir(parents=True)
    (root / "cache").symlink_to(root / "theory-modules")
    action = root / "action"
    action.mkdir()
    scratch = root / "scratch"
    scratch.mkdir()
    system = [directory for directory in ("/usr", "/bin", "/lib", "/lib64") if os.path.exists(directory)]
    modules = []
    for i in range(7000):
        module = store / f"0A1B2C3D4E5F6071-someTheoryName{i}-{i:040x}.pmo"
        module.write_text(f"module {i}")
        modules.append(str(root / "cache" / store.name / module.name))
    forbid = [str(root / "protected" / f"state{i}") for i in range(30)]
    keep_read_only = str(root / "theory-modules")

    # What the launch spends on them: before, 2-5 s on a loaded box.
    started = time.monotonic()
    policy = sandbox.Policy([action.resolve()], sandbox.existing(system + modules),
                            [path for name in forbid for path in sandbox.spellings(name)[0]])
    policy.validate()
    passed = ({path for name in forbid for path in sandbox.spellings(name)[1]} |
              {path for paths in sandbox.spellings(keep_read_only) for path in paths})
    usable = policy.usable_scratch([scratch.resolve()], passed)
    took = time.monotonic() - started
    assert len(policy.readable) == len(system) + 7000 and usable == [scratch.resolve()], (len(policy.readable), usable)
    assert took < 1, f"the path checks on 7,000 read grants took {took:.2f} s"
    print(f"path checks on 7,000 read grants: {took:.2f} s")

    options = [option for directory in system for option in ("--read", directory)]
    options += [option for module in modules for option in ("--read", module)]
    options += [option for name in forbid for option in ("--forbid", name)]
    options += ["--keep-read-only", keep_read_only, "--write", str(action), "--scratch", str(scratch)]
    file = root / "grants.options"
    file.write_bytes(b"".join(os.fsencode(option) + b"\0" for option in options))
    started = time.monotonic()
    read = subprocess.run([sys.executable, "-I", helper, "--options", str(file), "--", "/bin/cat", modules[-1]],
                          check=True, capture_output=True, text=True).stdout
    took = time.monotonic() - started
    assert read == "module 6999", read
    # Before the checks scaled, this launch took 8 s on a loaded box.  Python
    # 3.12's argparse spends up to 1 s on these 14,000 arguments (3.13 made
    # it linear), hence the margin.
    assert took < 2.5, f"a launch with 7,000 read grants took {took:.2f} s"
    print(f"launch with 7,000 read grants: {took:.2f} s")


def main() -> None:
    helper, scratch = sys.argv[1], Path(sys.argv[2])
    sandbox = load(helper)
    check_within(sandbox)
    check_exposure(sandbox)
    check_existing(sandbox, scratch / "existing")
    check_many_grants(sandbox, helper, scratch / "many")
    print("sandbox path checks match Path's and scale to 7,000 read grants")


if __name__ == "__main__":
    main()
