#!/usr/bin/env python3
"""Capture a Flutter VM timeline from a running profile app.

Example:
    app/build/linux/x64/profile/bundle/dsh_app > /tmp/dsh-profile.log 2>&1 &
    python3 tooling/capture-timeline.py --log /tmp/dsh-profile.log \
        --output /tmp/dsh-timeline.json --seconds 8
    python3 tooling/timeline_stage_check.py /tmp/dsh-timeline.json

Interact with the app while the capture is running. The script enables the
same build/layout/paint timeline switches used by DevTools, clears the ring
buffer, waits, and saves the getVMTimeline response. The app keeps running.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.parse import urlencode
from urllib.request import urlopen

VM_URL = re.compile(r"http://127\.0\.0\.1:\d+/[^\s]+?=/")


def find_vm_url(text: str) -> str | None:
    match = VM_URL.search(text)
    return match.group(0) if match else None


def _rpc(base: str, method: str, params: dict[str, str] | None = None) -> Any:
    url = base + method
    if params:
        url += "?" + urlencode(params)
    with urlopen(url, timeout=30) as response:
        document = json.loads(response.read().decode("utf-8"))
    if "error" in document:
        raise RuntimeError(f"{method}: {document['error']}")
    return document


def _wait_for_url(log: Path, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            match = find_vm_url(log.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            match = None
        if match:
            return match
        time.sleep(0.25)
    raise TimeoutError(f"no VM service URL in {log} after {timeout:.0f}s")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--log", type=Path, help="profile app log containing the VM service URL")
    source.add_argument("--vm-url", help="VM service URL, if already known")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=8.0)
    parser.add_argument("--wait-timeout", type=float, default=30.0)
    args = parser.parse_args(argv)
    if args.seconds <= 0:
        parser.error("--seconds must be positive")

    try:
        base = args.vm_url or _wait_for_url(args.log, args.wait_timeout)
        vm = _rpc(base, "getVM")["result"]
        isolate = vm["isolates"][0]["id"]
        for extension in (
            "ext.flutter.profileWidgetBuilds",
            "ext.flutter.profileRenderObjectLayouts",
            "ext.flutter.profileRenderObjectPaints",
        ):
            _rpc(base, extension, {"isolateId": isolate, "enabled": "true"})
        _rpc(base, "clearVMTimeline")
        print(f"capturing {args.seconds:g}s from {base}", file=sys.stderr)
        time.sleep(args.seconds)
        timeline = _rpc(base, "getVMTimeline")
    except (OSError, URLError, TimeoutError, RuntimeError, KeyError, IndexError) as error:
        print(f"capture-timeline: {error}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(timeline, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    events = timeline.get("result", {}).get("traceEvents", [])
    print(f"saved {len(events)} events to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
