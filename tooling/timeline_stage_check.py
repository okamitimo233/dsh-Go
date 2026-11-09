#!/usr/bin/env python3
"""Summarize Flutter frame stages from a VM timeline capture.

Capture a timeline while a profile build is running (for example from DevTools,
or through the VM service), save the `getVMTimeline` JSON, then inspect the
frame-phase roots:

    python3 tooling/timeline_stage_check.py build/frame-timeline.json \
        --max-p95 "LAYOUT (root)=2" --max-p95 "PAINT (root)=4"

Build/layout/paint/compositing timings are only present after enabling the
profileRenderObjectLayouts / profileRenderObjectPaints service extensions (the
same switches DevTools uses). This checker does not start or drive the app.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

STAGES = ("BUILD", "LAYOUT (root)", "PAINT (root)", "COMPOSITING", "SEMANTICS", "Frame")


def _events(document: Any) -> list[dict[str, Any]]:
    if isinstance(document, dict) and "traceEvents" in document:
        events = document["traceEvents"]
    elif isinstance(document, dict) and isinstance(document.get("result"), dict):
        events = document["result"].get("traceEvents", [])
    else:
        events = []
    return [event for event in events if isinstance(event, dict)] if isinstance(events, list) else []


def stage_durations(events: Iterable[dict[str, Any]]) -> dict[str, list[float]]:
    """Pair synchronous B/E and async b/e events and return durations in ms."""
    stacks: dict[tuple[Any, ...], list[float]] = defaultdict(list)
    durations: dict[str, list[float]] = {stage: [] for stage in STAGES}
    wanted = set(STAGES)
    for event in events:
        name = event.get("name")
        phase = event.get("ph")
        timestamp = event.get("ts")
        if name not in wanted or not isinstance(timestamp, (int, float)):
            continue
        if phase == "B":
            key = (event.get("pid"), event.get("tid"), name, "sync")
            stacks[key].append(float(timestamp))
        elif phase == "E":
            key = (event.get("pid"), event.get("tid"), name, "sync")
            if stacks[key]:
                durations[name].append((float(timestamp) - stacks[key].pop()) / 1000)
        elif phase in ("b", "e"):
            key = (event.get("pid"), event.get("tid"), name, "async", event.get("id"))
            if phase == "b":
                stacks[key].append(float(timestamp))
            elif stacks[key]:
                durations[name].append((float(timestamp) - stacks[key].pop()) / 1000)
        elif phase == "X" and isinstance(event.get("dur"), (int, float)):
            durations[name].append(float(event["dur"]) / 1000)
    for values in durations.values():
        values[:] = [value for value in values if value >= 0]
    return {stage: values for stage, values in durations.items() if values}


def _percentile(sorted_values: list[float], percent: float) -> float:
    if not sorted_values:
        return 0.0
    index = math.ceil(percent / 100 * (len(sorted_values) - 1))
    return sorted_values[min(index, len(sorted_values) - 1)]


def summarize(durations: dict[str, list[float]]) -> dict[str, dict[str, float]]:
    result: dict[str, dict[str, float]] = {}
    for stage, values in durations.items():
        ordered = sorted(values)
        result[stage] = {
            "count": len(ordered),
            "p50Ms": _percentile(ordered, 50),
            "p95Ms": _percentile(ordered, 95),
            "p99Ms": _percentile(ordered, 99),
            "maxMs": ordered[-1],
            "totalMs": sum(ordered),
        }
    return result


def _parse_limit(text: str) -> tuple[str, float]:
    name, separator, value = text.rpartition("=")
    if not separator or not name:
        raise argparse.ArgumentTypeError("expected STAGE=MILLISECONDS")
    try:
        return name, float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("threshold must be a number") from error


def check_limits(summary: dict[str, dict[str, float]], limits: list[tuple[str, float]]) -> list[str]:
    errors = []
    for stage, limit_ms in limits:
        stage_summary = summary.get(stage)
        if stage_summary is None:
            errors.append(f"missing stage: {stage}")
        elif stage_summary["p95Ms"] > limit_ms:
            errors.append(f"{stage} p95 {stage_summary['p95Ms']:.3f}ms > {limit_ms:.3f}ms")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("timeline", type=Path, help="JSON returned by getVMTimeline")
    parser.add_argument(
        "--max-p95",
        action="append",
        default=[],
        type=_parse_limit,
        metavar="STAGE=MS",
        help="fail when a stage's p95 exceeds this; repeatable, e.g. 'LAYOUT (root)=2'",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        document = json.loads(args.timeline.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"timeline_stage_check: {error}", file=sys.stderr)
        return 1

    durations = stage_durations(_events(document))
    summary = summarize(durations)
    errors = [] if summary else ["no recognized frame stage events"]
    errors.extend(check_limits(summary, args.max_p95))

    if args.json:
        print(json.dumps({"stages": summary, "errors": errors}, ensure_ascii=False, indent=2))
    else:
        for stage, stats in summary.items():
            print(
                f"{stage}: {int(stats['count'])} frames, "
                f"p50={stats['p50Ms']:.3f}ms p95={stats['p95Ms']:.3f}ms "
                f"p99={stats['p99Ms']:.3f}ms max={stats['maxMs']:.3f}ms"
            )
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        if not errors:
            print("PASS")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
