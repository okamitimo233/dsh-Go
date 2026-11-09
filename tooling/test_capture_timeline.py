"""Tests for the pure helpers in tooling/capture-timeline.py."""

import importlib.util
import pathlib
import unittest

MODULE = pathlib.Path(__file__).resolve().parent / "capture-timeline.py"
SPEC = importlib.util.spec_from_file_location("capture_timeline", MODULE)
capture_timeline = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(capture_timeline)


class FindVmUrlTest(unittest.TestCase):
    def test_finds_the_tokenised_http_url_through_log_prefixes(self):
        text = (
            "Building...\n"
            "[IMPORTANT:flutter] Using the Impeller rendering backend\n"
            "The Dart VM service is listening on http://127.0.0.1:44639/qmZkL_0MBhM=/\n"
        )
        self.assertEqual(capture_timeline.find_vm_url(text), "http://127.0.0.1:44639/qmZkL_0MBhM=/")

    def test_ignores_a_bare_or_unrelated_url(self):
        self.assertIsNone(capture_timeline.find_vm_url("http://127.0.0.1:44639/"))
        self.assertIsNone(capture_timeline.find_vm_url("https://example.test/"))


if __name__ == "__main__":
    unittest.main()
