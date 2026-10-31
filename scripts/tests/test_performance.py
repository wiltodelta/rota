"""Performance evidence must identify the right app and measure interval CPU."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.performance import (
    capture_stack,
    collect,
    cpu_seconds,
    interval_cpu,
    process_rows,
    report,
)


class PerformanceTests(unittest.TestCase):
    def test_sustained_cpu_captures_once_and_records_all_observations(self):
        clock = [0.0]

        def sleep(seconds):
            clock[0] += seconds

        def processes(_app):
            return [
                {
                    "pid": 42,
                    "started": "first",
                    "cpu_seconds": clock[0],
                    "rss_bytes": 1024,
                }
            ]

        with tempfile.TemporaryDirectory(prefix="rota-performance-test-") as directory:
            folder = Path(directory)
            args = SimpleNamespace(
                output=folder, app=folder, duration=40, interval=5, stack_cpu=20
            )
            with (
                patch("scripts.performance.make_folder", return_value=folder),
                patch("scripts.performance.signal.signal"),
                patch(
                    "scripts.performance.time.monotonic", side_effect=lambda: clock[0]
                ),
                patch("scripts.performance.time.sleep", side_effect=sleep),
                patch("scripts.performance.processes", side_effect=processes),
                patch(
                    "scripts.performance.capture_stack", return_value=True
                ) as capture,
            ):
                collect(args)
            capture.assert_called_once_with(
                folder,
                {"pid": 42, "started": "first", "cpu_seconds": 15.0, "rss_bytes": 1024},
            )
            events = [
                json.loads(line)
                for line in (folder / "metrics.jsonl").read_text().splitlines()
            ]
            self.assertEqual(sum(event["event"] == "sample" for event in events), 8)
            self.assertEqual(events[-1]["event"], "stop")

    def test_cpu_is_interval_usage_and_resets_on_relaunch_or_pid_reuse(self):
        previous = {"pid": 42, "started": "first", "cpu_seconds": 120}
        current = {**previous, "cpu_seconds": 123}
        self.assertEqual(interval_cpu(previous, current, 5), 60)
        self.assertIsNone(interval_cpu(None, current, 5))
        self.assertIsNone(interval_cpu(previous, {**current, "pid": 43}, 5))
        self.assertIsNone(interval_cpu(previous, {**current, "started": "second"}, 5))
        self.assertEqual(cpu_seconds("02:03.50"), 123.5)
        self.assertEqual(cpu_seconds("1-02:03:04.50"), 93784.5)

    def test_matches_exact_executable_and_excludes_dev_or_other_arguments(self):
        rows = process_rows(
            "42 02:03.50 2048 Fri Oct 30 19:46:24 2026 /Applications/Rota.app/Contents/MacOS/Rota\n"
            "43 00:00.10 4096 Fri Oct 30 19:46:24 2026 /tmp/Rota.app/Contents/MacOS/Rota\n"
            "44 00:00.10 4096 Fri Oct 30 19:46:24 2026 /usr/bin/python3\n",
            Path("/Applications/Rota.app/Contents/MacOS/Rota"),
        )
        self.assertEqual([row["pid"] for row in rows], [42])
        self.assertEqual(rows[0]["rss_bytes"], 2097152)

    def test_sampling_failure_is_recorded_without_aborting_collection(self):
        with tempfile.TemporaryDirectory(prefix="rota-performance-test-") as directory:
            folder = Path(directory)
            with patch(
                "scripts.performance.subprocess.run",
                side_effect=subprocess.TimeoutExpired("sample", 30),
            ):
                capture_stack(folder, {"pid": 42})
            event = json.loads((folder / "metrics.jsonl").read_text())
            self.assertEqual(event["event"], "stack_failed")

    def test_report_keeps_missing_periods_and_restarts_visible(self):
        with tempfile.TemporaryDirectory(prefix="rota-performance-test-") as directory:
            folder = Path(directory)
            events = [
                {
                    "event": "sample",
                    "pid": 42,
                    "started": "a",
                    "time": "first",
                    "cpu_percent": None,
                    "rss_bytes": 1048576,
                },
                {
                    "event": "sample",
                    "pid": 42,
                    "started": "a",
                    "time": "next",
                    "cpu_percent": 20,
                    "rss_bytes": 2097152,
                },
                {
                    "event": "sample",
                    "pid": 42,
                    "started": "a",
                    "time": "peak",
                    "cpu_percent": 60,
                    "rss_bytes": 2097152,
                },
                {
                    "event": "sample",
                    "pid": 42,
                    "started": "a",
                    "time": "lower",
                    "cpu_percent": 10,
                    "rss_bytes": 1048576,
                },
                {"event": "unavailable"},
                {
                    "event": "sample",
                    "pid": 42,
                    "started": "b",
                    "time": "last",
                    "cpu_percent": None,
                    "rss_bytes": 1048576,
                },
                {"event": "stack_failed"},
            ]
            (folder / "metrics.jsonl").write_text(
                "\n".join(json.dumps(event) for event in events) + '\n{"event":'
            )
            result = report(folder)
            self.assertEqual(result["processes"], 2)
            self.assertEqual(result["unavailable_samples"], 1)
            self.assertEqual(result["stack_failures"], 1)
            self.assertEqual(result["cpu_p95"], 60)
            self.assertEqual(result["cpu_p50"], 20)
            self.assertEqual(result["rss_max_mib"], 2)


if __name__ == "__main__":
    unittest.main()
