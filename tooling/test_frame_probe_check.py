"""Tests for tooling/frame_probe_check.py.

    python3 -m unittest discover -s tooling -p 'test_*.py'
"""

import json
import unittest

from frame_probe_check import check_reports, parse_reports


def report(
    count=300,
    *,
    window_ms=5000,
    build_p95=10000,
    raster_p95=8000,
    build_p99=15000,
    raster_p99=12000,
    jank_ratio=0.01,
):
    return {
        "windowMs": window_ms,
        "frameBudget": {
            "count": count,
            "buildUs": {"p50": 5000, "p95": build_p95, "p99": build_p99, "max": 20000},
            "rasterUs": {"p50": 4000, "p95": raster_p95, "p99": raster_p99, "max": 18000},
            "jankRatio": jank_ratio,
        },
    }


class ParseReportsTest(unittest.TestCase):
    def test_joins_numbered_parts_through_flutter_log_prefixes(self):
        payload = json.dumps(report(), ensure_ascii=False)
        middle = len(payload) // 2
        lines = [
            "I/flutter ( 4242): DSH_FRAME_PROBE 7 1/2 " + payload[:middle] + "\n",
            "flutter: unrelated line\n",
            "flutter: DSH_FRAME_PROBE 7 2/2 " + payload[middle:] + "\n",
        ]
        self.assertEqual(parse_reports(lines), [report()])

    def test_ignores_incomplete_and_malformed_reports(self):
        lines = [
            "DSH_FRAME_PROBE 1 1/2 {\"frameBudget\":",
            "DSH_FRAME_PROBE 2 1/1 {not json}",
        ]
        self.assertEqual(parse_reports(lines), [])

    def test_a_duplicate_part_restarts_the_current_report(self):
        second = json.dumps(report(count=300))
        lines = [
            f"DSH_FRAME_PROBE 3 1/2 {second[:5]}",
            f"DSH_FRAME_PROBE 3 1/2 {second[:-1]}",
            f"DSH_FRAME_PROBE 3 2/2 {second[-1:]}",
        ]
        # The repeated first part cannot be joined with the stale prefix; the
        # latest complete attempt wins.
        self.assertEqual(parse_reports(lines), [report(count=300)])


class CheckReportsTest(unittest.TestCase):
    def check(self, reports, **kwargs):
        return check_reports(reports, **kwargs)

    def test_passes_a_smooth_60hz_window(self):
        results, errors = self.check(
            [report()],
            min_frames=240,
            max_p95_ms=12,
            max_p99_ms=20,
            max_jank_ratio=0.02,
            min_fps=55,
            require_active=True,
        )
        self.assertEqual(errors, [])
        self.assertEqual(results[0].frames, 300)
        self.assertEqual(results[0].fps, 60)
        self.assertEqual(results[0].build_p95_ms, 10)
        self.assertEqual(results[0].raster_p95_ms, 8)

    def test_reports_each_budget_violation(self):
        results, errors = self.check(
            [report(count=120, build_p95=20000, raster_p99=40000, jank_ratio=0.2)],
            min_frames=240,
            max_p95_ms=16.7,
            max_p99_ms=33.3,
            max_jank_ratio=0.05,
            min_fps=55,
            require_active=True,
        )
        text = "\n".join(errors)
        self.assertIn("frames 120 < 240", text)
        self.assertIn("build p95 20.00ms > 16.70ms", text)
        self.assertIn("raster p99 40.00ms > 33.30ms", text)
        self.assertIn("jank ratio 0.200 > 0.050", text)
        self.assertIn("fps 24.0 < 55.0", text)
        self.assertEqual(len(results), 1)

    def test_idle_windows_are_allowed_only_when_not_required(self):
        _, errors = self.check([report(count=0)], require_active=False)
        self.assertEqual(errors, [])
        _, errors = self.check([report(count=0)], require_active=True)
        self.assertEqual(errors, ["no active frame windows found"])

    def test_skip_windows_drops_cold_start(self):
        cold = report(count=20, build_p95=50000)
        warm = report(count=300)
        results, errors = self.check(
            [cold, warm],
            skip_windows=1,
            min_frames=240,
            max_p95_ms=12,
            require_active=True,
        )
        self.assertEqual(errors, [])
        self.assertEqual([result.index for result in results], [2])

    def test_max_windows_keeps_only_fully_active_windows(self):
        partial = report(count=60)
        results, errors = self.check(
            [report(), report(), partial],
            skip_windows=1,
            max_windows=1,
            min_frames=240,
            require_active=True,
        )
        self.assertEqual(errors, [])
        self.assertEqual([result.index for result in results], [2])

    def test_skipping_every_report_fails(self):
        _, errors = self.check([report()], skip_windows=1)
        self.assertEqual(errors, ["all 1 reports skipped"])

    def test_missing_reports_fail(self):
        _, errors = self.check([], require_active=False)
        self.assertEqual(errors, ["no complete DSH_FRAME_PROBE reports found"])


if __name__ == "__main__":
    unittest.main()
