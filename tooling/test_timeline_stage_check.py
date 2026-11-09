"""Tests for tooling/timeline_stage_check.py.

    python3 -m unittest discover -s tooling -p 'test_*.py'
"""

import unittest

from timeline_stage_check import check_limits, stage_durations, summarize


def event(name, phase, ts, *, pid=1, tid=2, event_id=None):
    value = {"name": name, "ph": phase, "ts": ts, "pid": pid, "tid": tid}
    if event_id is not None:
        value["id"] = event_id
    return value


class StageDurationsTest(unittest.TestCase):
    def test_pairs_nested_sync_events_and_async_frame(self):
        rendered = stage_durations(
            [
                event("Frame", "b", 0, event_id="frame"),
                event("BUILD", "B", 1000),
                event("LAYOUT (root)", "B", 1100),
                event("LAYOUT (root)", "E", 1110),
                event("PAINT (root)", "B", 1120),
                event("PAINT (root)", "E", 1150),
                event("COMPOSITING", "B", 1160),
                event("COMPOSITING", "E", 1180),
                event("BUILD", "E", 1300),
                event("Frame", "e", 2000, event_id="frame"),
            ]
        )
        self.assertEqual(rendered["Frame"], [2.0])
        self.assertEqual(rendered["BUILD"], [0.3])
        self.assertEqual(rendered["LAYOUT (root)"], [0.01])
        self.assertEqual(rendered["PAINT (root)"], [0.03])
        self.assertEqual(rendered["COMPOSITING"], [0.02])

    def test_ignores_unmatched_or_negative_events(self):
        self.assertEqual(stage_durations([event("BUILD", "E", 12)]), {})
        self.assertEqual(stage_durations([event("BUILD", "B", 20), event("BUILD", "E", 10)]), {})

    def test_summary_percentiles(self):
        summary = summarize({"PAINT (root)": [1.0, 2.0, 3.0, 4.0, 10.0]})
        self.assertEqual(summary["PAINT (root)"]["count"], 5)
        self.assertEqual(summary["PAINT (root)"]["p50Ms"], 3.0)
        self.assertEqual(summary["PAINT (root)"]["p95Ms"], 10.0)
        self.assertEqual(summary["PAINT (root)"]["maxMs"], 10.0)
        self.assertEqual(summary["PAINT (root)"]["totalMs"], 20.0)


class LimitsTest(unittest.TestCase):
    def test_reports_a_missed_stage_and_p95_overage(self):
        summary = summarize({"PAINT (root)": [1.0, 9.0]})
        errors = check_limits(summary, [("PAINT (root)", 5.0), ("LAYOUT (root)", 10.0)])
        self.assertEqual(len(errors), 2)
        self.assertIn("PAINT (root) p95 9.000ms > 5.000ms", errors[0])
        self.assertIn("missing stage: LAYOUT (root)", errors[1])

    def test_passes_at_the_limit(self):
        summary = summarize({"LAYOUT (root)": [2.0, 4.0]})
        self.assertEqual(check_limits(summary, [("LAYOUT (root)", 4.0)]), [])


if __name__ == "__main__":
    unittest.main()
