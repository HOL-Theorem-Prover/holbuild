#!/usr/bin/env python3
"""List half-budget proof steps from execution logs, preserving missing coverage."""

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from collections.abc import Iterable


@dataclass(frozen=True)
class Step:
    theory: str
    theorem: str
    index: str
    kind: str
    status: str
    elapsed_ms: float
    limit_ms: float
    label: str


@dataclass
class Execution:
    name: str
    available: bool
    steps: list[Step]


def parse_log(name: str, lines: Iterable[str]) -> Execution:
    result = Execution(name, False, [])
    for line in lines:
        if line.startswith("holbuild slow-proof-steps v1 coverage=executed limit_ms="):
            result.available = True
        if line.startswith("holbuild slow-proof-step\t"):
            _, theorem, index, kind, status, elapsed, limit, label = line.rstrip("\n").split("\t", 7)
            result.steps.append(Step(name, theorem, index, kind, status,
                                     float(elapsed), float(limit), label))
    return result


def read_log(name: str, path: Path) -> Execution:
    with path.open(encoding="utf-8", errors="replace") as log:
        return parse_log(name, log)


def read_batches(paths: list[Path], cache_url: str, curl_config: Path | None) -> list[Execution]:
    # A later execution supersedes the same key's earlier log; a cache hit
    # without a log must not hide an original execution we were also given.
    logs: dict[tuple[str, str], str | None] = {}
    for path in paths:
        batch = json.loads(path.read_text())
        if batch["state"] not in ("done", "failed", "cancelled"):
            raise ValueError(f"{path}: batch has not finished ({batch['state']})")
        for action in batch["actions"]:
            key = (action["theory"], action["input_key"])
            sha = action.get("log_sha256")
            if sha is not None or key not in logs:
                logs[key] = sha
    results = []
    with tempfile.TemporaryDirectory(prefix="holbuild-step-logs-") as tmp:
        log_path = Path(tmp) / "build.log"
        for (name, key), sha in logs.items():
            if sha is None:
                results.append(Execution(f"{name}@{key}", False, []))
                continue
            if re.fullmatch(r"[0-9a-f]{64}", sha) is None:
                raise ValueError(f"{name}: invalid log_sha256")
            command = ["curl", "--fail", "--silent", "--show-error", "--max-time", "60"]
            if curl_config is not None:
                command += ["--config", str(curl_config)]
            command += ["--output", str(log_path), cache_url.rstrip("/") + "/cas/" + sha]
            subprocess.run(command, check=True)
            results.append(read_log(f"{name}@{key}", log_path))
    return results


def report(executions: list[Execution]) -> None:
    steps = sorted((step for execution in executions for step in execution.steps),
                   key=lambda step: step.elapsed_ms, reverse=True)
    print("theory\ttheorem\tstep\tkind\tstatus\telapsed_ms\tlimit_ms\tlabel")
    for step in steps:
        print(f"{step.theory}\t{step.theorem}\t{step.index}\t{step.kind}\t{step.status}"
              f"\t{step.elapsed_ms:.3f}\t{step.limit_ms:.3f}\t{step.label}")
    for execution in executions:
        if not execution.available:
            print(f"timings unavailable: {execution.name}", file=sys.stderr)
    covered = sum(execution.available for execution in executions)
    print(f"{len(steps)} recorded half-budget steps; {covered}/{len(executions)} logs instrumented; "
          "executed work only (checkpoint prefixes and pre-submission cache hits are not covered)",
          file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="*", help="explicit build.log files from an execution")
    parser.add_argument("--batch", type=Path, action="append", default=[], help="saved finished batch JSON (repeatable)")
    parser.add_argument("--cache-url", help="remote cache URL for batch log blobs")
    parser.add_argument("--curl-config", type=Path, help="curl config for the remote cache")
    args = parser.parse_args()
    if not args.logs and not args.batch:
        parser.error("provide build logs or --batch")
    if args.batch and not args.cache_url:
        parser.error("--batch requires --cache-url")
    try:
        executions = [read_log(str(path), path) for path in args.logs]
        if args.batch:
            executions += read_batches(args.batch, args.cache_url, args.curl_config)
        report(executions)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
