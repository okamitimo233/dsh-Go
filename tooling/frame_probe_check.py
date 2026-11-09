#!/usr/bin/env python3
"""Validate DSH_FRAME_PROBE reports from a profile run.

The app's opt-in frame probe prints one JSON report as numbered
`DSH_FRAME_PROBE <seq> <part>/<parts> ...` lines every five seconds. This
checker joins those lines, reads the per-window FrameTiming summary, and fails
when a sustained benchmark window exceeds the supplied budget.

Example:
    python3 tooling/frame_probe_check.py build/frame-probe.log \
        --min-frames 240 --max-p95-ms 12 --max-p99-ms 20 \
        --max-jank-ratio 0.02 --min-fps 55 --require-active
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

PREFIX = re.compile(r"DSH_FRAME_PROBE\s+(\d+)\s+(\d+)/(\d+)\s+(.*)$")


def parse_reports(lines: Iterable[str]) -> list[dict[str, Any]]:
    """Join complete numbered probe reports found in log lines."""
    pending: dict[int, tuple[int, dict[int, str]]] = {}
    reports: list[dict[str, Any]] = []
    for raw in lines:
        match = PREFIX.search(raw.rstrip("\r\n"))
        if not match:
            continue
        seq = int(match.group(1))
        part = int(match.group(2))
        total = int(match.group(3))
        payload = match.group(4)
        if total <= 0 or part <= 0 or part > total:
            continue
        existing = pending.get(seq)
        if existing is None or existing[0] != total:
            existing = (total, {})
            pending[seq] = existing
        parts = existing[1]
        # A duplicate part means two runs reused the same sequence number;
        # keep the newest complete attempt rather than joining stale bytes.
        if part in parts:
            parts.clear()
        parts[part] = payload
        if len(parts) != total:
            continue
        joined = "".join(parts[i] for i in range(1, total + 1))
        del pending[seq]
        try:
            report = json.loads(joined)
        except json.JSONDecodeError:
            continue
        if isinstance(report, dict):
            reports.append(report)
    return reports


@dataclass(frozen=True)
class WindowResult:
    index: int
    frames: int
    fps: float
    build_p95_ms: float
    raster_p95_ms: float
    build_p99_ms: float
    raster_p99_ms: float
    jank_ratio: float
    errors: tuple[str, ...]


def check_report(
    index: int,
    report: dict[str, Any],
    *,
    min_frames: int,
    max_p95_ms: float,
    max_p99_ms: float,
    max_jank_ratio: float,
    min_fps: float,
) -> WindowResult:
    errors: list[str] = []
    frame_budget = report.get("frameBudget")
    window_ms = report.get("windowMs")
    if not isinstance(frame_budget, dict):
        return WindowResult(index, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, ("missing frameBudget",))
    if not isinstance(window_ms, (int, float)) or window_ms <= 0:
        errors.append(f"bad windowMs: {window_ms!r}")
        window_ms = 5000

    def number(value: Any, name: str) -> float:
        if not isinstance(value, (int, float)):
            errors.append(f"bad {name}: {value!r}")
            return 0.0
        return float(value)

    frames = int(number(frame_budget.get("count"), "frame count"))
    build = frame_budget.get("buildUs")
    raster = frame_budget.get("rasterUs")
    if not isinstance(build, dict) or not isinstance(raster, dict):
        errors.append("missing buildUs/rasterUs percentiles")
        build = build if isinstance(build, dict) else {}
        raster = raster if isinstance(raster, dict) else {}
    build_p95_us = number(build.get("p95"), "build p95")
    raster_p95_us = number(raster.get("p95"), "raster p95")
    build_p99_us = number(build.get("p99"), "build p99")
    raster_p99_us = number(raster.get("p99"), "raster p99")
    jank_ratio = number(frame_budget.get("jankRatio"), "jankRatio")
    fps = frames / (float(window_ms) / 1000)

    if frames < min_frames:
        errors.append(f"frames {frames} < {min_frames}")
    if build_p95_us > max_p95_ms * 1000:
        errors.append(f"build p95 {build_p95_us / 1000:.2f}ms > {max_p95_ms:.2f}ms")
    if raster_p95_us > max_p95_ms * 1000:
        errors.append(f"raster p95 {raster_p95_us / 1000:.2f}ms > {max_p95_ms:.2f}ms")
    if build_p99_us > max_p99_ms * 1000:
        errors.append(f"build p99 {build_p99_us / 1000:.2f}ms > {max_p99_ms:.2f}ms")
    if raster_p99_us > max_p99_ms * 1000:
        errors.append(f"raster p99 {raster_p99_us / 1000:.2f}ms > {max_p99_ms:.2f}ms")
    if jank_ratio > max_jank_ratio:
        errors.append(f"jank ratio {jank_ratio:.3f} > {max_jank_ratio:.3f}")
    if min_fps > 0 and fps < min_fps:
        errors.append(f"fps {fps:.1f} < {min_fps:.1f}")

    return WindowResult(
        index,
        frames,
        fps,
        build_p95_us / 1000,
        raster_p95_us / 1000,
        build_p99_us / 1000,
        raster_p99_us / 1000,
        jank_ratio,
        tuple(errors),
    )


def check_reports(
    reports: list[dict[str, Any]],
    *,
    min_frames: int = 60,
    max_p95_ms: float = 16.7,
    max_p99_ms: float = 33.3,
    max_jank_ratio: float = 0.05,
    min_fps: float = 0.0,
    require_active: bool = False,
    skip_windows: int = 0,
    max_windows: int = 0,
) -> tuple[list[WindowResult], list[str]]:
    results: list[WindowResult] = []
    active = 0
    examined = 0
    for index, report in enumerate(reports, 1):
        if index <= skip_windows:
            continue
        if max_windows > 0 and examined >= max_windows:
            break
        examined += 1
        frame_budget = report.get("frameBudget")
        count = frame_budget.get("count") if isinstance(frame_budget, dict) else None
        if count == 0:
            continue
        active += 1
        results.append(
            check_report(
                index,
                report,
                min_frames=min_frames,
                max_p95_ms=max_p95_ms,
                max_p99_ms=max_p99_ms,
                max_jank_ratio=max_jank_ratio,
                min_fps=min_fps,
            )
        )
    errors = []
    if not reports:
        errors.append("no complete DSH_FRAME_PROBE reports found")
    elif skip_windows >= len(reports):
        errors.append(f"all {len(reports)} reports skipped")
    elif require_active and active == 0:
        errors.append("no active frame windows found")
    errors.extend(f"window {result.index}: {error}" for result in results for error in result.errors)
    return results, errors


def _print_human(results: list[WindowResult]) -> None:
    if not results:
        print("no active frame windows (idle)")
        return
    for result in results:
        print(
            f"window {result.index}: {result.frames} frames "
            f"({result.fps:.1f} fps) "
            f"build p95={result.build_p95_ms:.2f}ms p99={result.build_p99_ms:.2f}ms "
            f"raster p95={result.raster_p95_ms:.2f}ms p99={result.raster_p99_ms:.2f}ms "
            f"jank={result.jank_ratio:.1%}"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="log file containing DSH_FRAME_PROBE lines, or - for stdin")
    parser.add_argument("--min-frames", type=int, default=60)
    parser.add_argument("--max-p95-ms", type=float, default=16.7)
    parser.add_argument("--max-p99-ms", type=float, default=33.3)
    parser.add_argument("--max-jank-ratio", type=float, default=0.05)
    parser.add_argument("--min-fps", type=float, default=0.0)
    parser.add_argument(
        "--skip-windows",
        type=int,
        default=0,
        help="drop this many leading reports (cold start / warm-up)",
    )
    parser.add_argument(
        "--max-windows",
        type=int,
        default=0,
        help="only examine this many reports after skipping (0 = all)",
    )
    parser.add_argument("--require-active", action="store_true")
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    args = parser.parse_args(argv)

    if str(args.log) == "-":
        lines = sys.stdin
    else:
        lines = args.log.read_text(encoding="utf-8").splitlines(keepends=True)
    reports = parse_reports(lines)
    results, errors = check_reports(
        reports,
        min_frames=args.min_frames,
        max_p95_ms=args.max_p95_ms,
        max_p99_ms=args.max_p99_ms,
        max_jank_ratio=args.max_jank_ratio,
        min_fps=args.min_fps,
        require_active=args.require_active,
        skip_windows=max(0, args.skip_windows),
        max_windows=max(0, args.max_windows),
    )
    if args.json:
        print(
            json.dumps(
                {
                    "reports": len(reports),
                    "windows": [result.__dict__ for result in results],
                    "errors": errors,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        _print_human(results)
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        if not errors:
            print("PASS")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
