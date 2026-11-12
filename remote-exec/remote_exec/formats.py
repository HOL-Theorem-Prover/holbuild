"""Parsers for the two holbuild texts the coordinator reads: the action batch and the result record."""

import graphlib
import re
from dataclasses import dataclass, field

SHA256 = re.compile(r"[0-9a-f]{64}")
THEORY = re.compile(r"[^\s:]+:\S+")
PHASE = re.compile(r"[a-z]+")
DETAIL_MAX = 500

FAILURES = frozenset(
    {
        "proof",
        "tactic-timeout",
        "memory",
        "input-missing",
        "publish",
        "toolchain",
        "disk",
        "spec-rejected",
        "internal",
        "script",
        "timeout",
        "unavailable",
        "ahead-abandoned",  # an action claimed ahead of its parents gave up; it is built once they are done
    }
)


class FormatError(ValueError):
    """A batch or result record that doesn't follow holbuild's format."""


@dataclass(frozen=True)
class BatchAction:
    input_key: str
    ac_key: str
    spec_sha256: str
    theory: str


@dataclass
class Batch:
    actions: list[BatchAction] = field(default_factory=list)
    edges: list[tuple[str, str]] = field(default_factory=list)  # (input_key, parent input_key)


@dataclass(frozen=True)
class Missing:
    kind: str  # "theory" or "blob"
    key: str


@dataclass(frozen=True)
class Result:
    spec_sha256: str
    input_key: str | None  # holbuild leaves it empty when the spec couldn't be read
    status: str  # built | cached | failed
    failure: str | None
    missing: Missing | None
    peak_rss_mb: int | None
    log_sha256: str | None
    # Durations in ms; started/finished and hol/publish/log start/end are Unix ms.
    # rebuilt is 1 for a source build, 0 for a cache hit or failure.
    timings: dict[str, int] | None = None
    detail: str | None = None  # why a failure with no log failed, as sanitize_detail leaves it


def sanitize_detail(text: str) -> str:
    """``text`` as a result record's ``detail``: one line of printable ASCII, every other character a space,
    cut to ``DETAIL_MAX`` characters, as ``holbuild exec-action`` writes it."""
    return "".join(c if " " <= c <= "~" else " " for c in text[:DETAIL_MAX])


def _expect(pattern: re.Pattern[str], value: str, what: str) -> str:
    if not pattern.fullmatch(value):
        raise FormatError(f"bad {what}: {value!r}")
    return value


def parse_batch(text: str) -> Batch:
    """Parse a ``holbuild-action-batch-v1`` text, checking that the edges join actions of the batch without a cycle."""
    lines = text.splitlines()
    if not lines or lines[0] != "holbuild-action-batch-v1":
        raise FormatError(f"expected header 'holbuild-action-batch-v1', got {lines[0] if lines else ''!r}")
    batch = Batch()
    keys: set[str] = set()
    for line in lines[1:]:
        if not line:
            continue
        match line.split(" "):
            case ["action", input_key, ac_key, spec, theory]:
                if input_key in keys:
                    raise FormatError(f"duplicate action {input_key}")
                keys.add(input_key)
                batch.actions.append(
                    BatchAction(
                        _expect(SHA256, input_key, "input key"),
                        _expect(SHA256, ac_key, "ac key"),
                        _expect(SHA256, spec, "spec sha256"),
                        _expect(THEORY, theory, "theory"),
                    )
                )
            case ["edge", input_key, parent]:
                batch.edges.append((input_key, parent))
            case _:
                raise FormatError(f"bad batch line: {line!r}")
    for input_key, parent in batch.edges:
        if input_key not in keys or parent not in keys or input_key == parent:
            raise FormatError(f"edge {input_key} {parent} does not join two actions of the batch")
    if len(set(batch.edges)) != len(batch.edges):
        raise FormatError("duplicate edge")
    graph: dict[str, set[str]] = {}
    for input_key, parent in batch.edges:
        graph.setdefault(input_key, set()).add(parent)
    try:
        graphlib.TopologicalSorter(graph).prepare()
    except graphlib.CycleError as cycle:
        raise FormatError(f"the edges form a cycle: {' -> '.join(cycle.args[1])}") from None
    return batch


def parse_result(text: str) -> Result:
    """Parse a ``holbuild-action-result-v1`` record, as ``holbuild exec-action --result`` writes it."""
    lines = text.splitlines()
    if not lines or lines[0] != "holbuild-action-result-v1":
        raise FormatError(f"expected header 'holbuild-action-result-v1', got {lines[0] if lines else ''!r}")
    fields: dict[str, str] = {}
    for line in lines[1:]:
        if not line:
            continue
        name, sep, value = line.partition("=")
        if not sep:
            raise FormatError(f"bad result line: {line!r}")
        fields[name] = value
    status = fields.get("status")
    if status not in ("built", "cached", "failed"):
        raise FormatError(f"bad status: {status!r}")
    failure = fields.get("failure")
    if (failure is None) != (status != "failed") or (failure is not None and failure not in FAILURES):
        raise FormatError(f"status {status} with failure {failure!r}")
    missing = None
    if "missing" in fields:
        match fields["missing"].split(" "):
            case ["theory", key]:
                missing = Missing("theory", _expect(SHA256, key, "missing theory"))
            case ["blob", key]:
                missing = Missing("blob", _expect(SHA256, key, "missing blob"))
            case _:
                raise FormatError(f"bad missing: {fields['missing']!r}")
    peak = fields.get("peak-rss-mb")
    if peak is not None and not peak.isdigit():
        raise FormatError(f"bad peak-rss-mb: {peak!r}")
    log = fields.get("log")
    timings: dict[str, int] = {}
    for item in fields["phase-ms"].split(",") if "phase-ms" in fields else []:
        name, sep, ms = item.partition(":")
        if not (sep and PHASE.fullmatch(name) and ms.isdigit()) or name in timings:
            raise FormatError(f"bad phase-ms: {fields['phase-ms']!r}")
        timings[name] = int(ms)
    wall = fields.get("wall-ms")
    if wall is not None:
        if not wall.isdigit() or "wall" in timings:
            raise FormatError(f"bad wall-ms: {wall!r}")
        timings["wall"] = int(wall)
    return Result(
        spec_sha256=_expect(SHA256, fields.get("spec", ""), "spec"),
        input_key=_expect(SHA256, fields["input-key"], "input-key") if fields.get("input-key") else None,
        status=status,
        failure=failure,
        missing=missing,
        peak_rss_mb=int(peak) if peak is not None else None,
        log_sha256=_expect(SHA256, log.split(" ")[0], "log") if log else None,
        timings=timings or None,
        detail=sanitize_detail(fields["detail"]) if fields.get("detail") else None,
    )
