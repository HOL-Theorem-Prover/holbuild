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


def check_many_grants(helper: str, root: Path) -> None:
    """A launch with a deep theory's module grants: 7,000 files in one store
    reached through a link, and the worker's protected paths."""
    store = root / "theory-modules" / ("0" * 40)
    store.mkdir(parents=True)
    (root / "cache").symlink_to(root / "theory-modules")
    action = root / "action"
    action.mkdir()
    scratch = root / "scratch"
    scratch.mkdir()
    options = [option for directory in ("/usr", "/bin", "/lib", "/lib64") if os.path.exists(directory)
               for option in ("--read", directory)]
    for i in range(7000):
        module = store / f"0A1B2C3D4E5F6071-someTheoryName{i}-{i:040x}.pmo"
        module.touch()
        options += ["--read", str(root / "cache" / store.name / module.name)]
    for i in range(30):
        options += ["--forbid", str(root / "protected" / f"state{i}")]
    options += ["--keep-read-only", str(root / "theory-modules"), "--write", str(action), "--scratch", str(scratch)]
    file = root / "grants.options"
    file.write_bytes(b"".join(os.fsencode(option) + b"\0" for option in options))
    started = time.monotonic()
    subprocess.run([sys.executable, "-I", helper, "--options", str(file), "--", "/bin/true"], check=True)
    took = time.monotonic() - started
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
    check_many_grants(helper, scratch / "many")
    print("sandbox path checks match Path's and scale to 7,000 read grants")


if __name__ == "__main__":
    main()
