"""Regression tests for review baselines and local collection artifacts."""

import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.harness_review import (
    accept,
    atomic_json,
    collect,
    comparison,
    load_state,
    normalize,
)


class ReviewTests(unittest.TestCase):
    def test_independent_sources_overlap_and_keep_manifest_order(self):
        barrier = threading.Barrier(2, timeout=3)

        def response(request, timeout):
            barrier.wait()
            body = io.BytesIO(
                ("document " + request.full_url + " details" * 30).encode()
            )
            body.status = 200
            return body

        with tempfile.TemporaryDirectory(prefix="rota-review-test-") as folder:
            root = Path(folder)
            sources = [
                {
                    "id": key,
                    "url": "https://example.invalid/" + key,
                    "marker": "document",
                }
                for key in ["first", "second"]
            ]
            (root / "sources.json").write_text(json.dumps(sources))
            with (
                patch("scripts.harness_review.SKILL", root),
                patch("scripts.harness_review.urlopen", response),
            ):
                result = collect(
                    {"version": 1, "sources": {}, "runs": []}, root / "evidence"
                )
            self.assertEqual(list(result["sources"])[:2], ["first", "second"])
            self.assertTrue(
                all(
                    result["sources"][key]["comparison"] == "baseline"
                    for key in ["first", "second"]
                )
            )

    def test_markdown_fingerprints_preserve_code_indentation(self):
        inside = "```python\nif ready:\n    send()\n```"
        outside = "```python\nif ready:\nsend()\n```"
        self.assertNotEqual(normalize(inside), normalize(outside))

    def setUp(self):
        self.old = "a" * 64
        self.new = "b" * 64
        self.state = {
            "version": 1,
            "sources": {"docs": {"sha256": self.old}},
            "runs": [],
        }
        self.collection = {
            "version": 1,
            "checked_at": "2026-10-30T12:00:00+00:00",
            "sources": {},
        }

    def test_unavailable_source_keeps_baseline_and_counts_consecutive_failures(self):
        self.collection["sources"]["docs"] = {"error": "TimeoutError"}
        first = accept(self.state, self.collection, set())
        second = accept(first, self.collection, set())
        self.assertEqual(second["sources"]["docs"]["sha256"], self.old)
        self.assertEqual(second["sources"]["docs"]["failures"], 2)
        self.assertEqual(
            comparison(self.state["sources"]["docs"], {"error": "TimeoutError"}),
            "unavailable",
        )

    def test_new_content_requires_review_before_baseline_can_advance(self):
        self.collection["sources"]["docs"] = {"sha256": self.new}
        deferred = accept(self.state, self.collection, set())
        self.assertEqual(deferred["sources"]["docs"]["sha256"], self.old)
        self.assertEqual(deferred["sources"]["docs"]["status"], "unreviewed")
        reviewed = accept(deferred, self.collection, {"docs"})
        self.assertEqual(reviewed["sources"]["docs"]["sha256"], self.new)
        self.assertEqual(
            comparison(reviewed["sources"]["docs"], {"sha256": self.new}), "unchanged"
        )

    def test_release_hash_ignores_download_counters_but_tracks_release_text(self):
        release = {
            "tag_name": "v1",
            "html_url": "https://example.com/v1",
            "published_at": "2026-10-30",
            "body": "Changed output",
            "download_count": 1,
        }
        first = normalize(json.dumps(release), "release")
        release["download_count"] = 2
        self.assertEqual(first, normalize(json.dumps(release), "release"))
        release["body"] = "Changed approvals"
        self.assertNotEqual(first, normalize(json.dumps(release), "release"))

    def test_damaged_state_is_not_reset_and_dry_run_does_not_write(self):
        with tempfile.TemporaryDirectory(prefix="rota-review-test-") as folder:
            path = Path(folder) / "state.json"
            path.write_text("{")
            with self.assertRaises(ValueError):
                load_state(path)
            atomic_json(path, self.state)
            before = path.read_bytes()
            self.collection["sources"]["docs"] = {"sha256": self.new}
            collected = Path(folder) / "collection.json"
            atomic_json(collected, self.collection)
            script = Path(__file__).resolve().parents[1] / "harness_review.py"
            subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--state",
                    str(path),
                    "accept",
                    "--collection",
                    str(collected),
                    "--reviewed",
                    "docs",
                    "--dry-run",
                ],
                check=True,
                capture_output=True,
            )
            self.assertEqual(before, path.read_bytes())

    def test_history_is_bounded_by_timestamp_and_state_write_is_atomic(self):
        state = {
            "version": 1,
            "sources": {},
            "runs": [
                {"checked_at": f"2026-10-{day:02}T12:00:00+00:00"}
                for day in range(1, 25)
            ],
        }
        updated = accept(state, self.collection, set())
        self.assertEqual(len(updated["runs"]), 16)
        self.assertEqual(
            updated["runs"][0]["checked_at"], self.collection["checked_at"]
        )
        with tempfile.TemporaryDirectory(prefix="rota-review-test-") as folder:
            path = Path(folder) / "state.json"
            atomic_json(path, updated)
            self.assertEqual(load_state(path), updated)
            self.assertEqual(list(Path(folder).iterdir()), [path])


if __name__ == "__main__":
    unittest.main()
