"""A UI suite must never reuse stale code or lose its visual matrix."""

import json
import os
import plistlib
import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.ui_preparation import DOMAIN, fingerprint, prepare, validate


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rota-ui-seal-test-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.repo = root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / "Sources").mkdir()
        self.source = self.repo / "Sources/View.swift"
        self.source.write_text("struct Fixture {}\n")
        self.app = root / "Rota.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": DOMAIN}))
        self.resource = self.app / "Contents/resource"
        self.resource.write_bytes(b"sealed resource")
        self.driver = root / "driver"
        self.driver.write_bytes(b"sealed driver")
        self.manifest = root / "prepared.json"
        self.manifest.write_text(json.dumps({"schema": 1, "repo": str(self.repo.resolve()),
            "app": str(self.app), "driver": str(self.driver),
            "fingerprint": fingerprint(self.repo, self.app, self.driver)}))

    def test_sealed_inputs_validate_but_each_changed_input_is_rejected(self):
        self.assertEqual(validate(self.manifest, self.repo), (self.app, self.driver))
        for path in [self.source, self.resource, self.driver]:
            with self.subTest(input=path.name):
                original = path.read_bytes()
                path.write_bytes(original + b" changed")
                with self.assertRaisesRegex(ValueError, "inputs changed"):
                    validate(self.manifest, self.repo)
                path.write_bytes(original)

    def test_new_source_and_missing_resource_are_rejected(self):
        added = self.repo / "Sources/New.swift"
        added.write_text("struct Added {}")
        with self.assertRaisesRegex(ValueError, "inputs changed"):
            validate(self.manifest, self.repo)
        added.unlink()
        self.resource.unlink()
        with self.assertRaisesRegex(ValueError, "inputs changed"):
            validate(self.manifest, self.repo)

    def test_other_checkout_and_release_identity_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "another checkout"):
            validate(self.manifest, self.repo.parent)
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.wiltodelta.rota"}))
        with self.assertRaisesRegex(ValueError, "development bundle"):
            validate(self.manifest, self.repo)

    def test_transferred_inputs_are_copied_and_resealed_but_corruption_is_rejected(self):
        work = Path(self.temporary.name) / "owned"
        work.mkdir()
        real_run = subprocess.run

        def run(command, **options):
            if command[0] == "codesign":
                return subprocess.CompletedProcess(command, 0)
            return real_run(command, **options)

        with patch("scripts.ui_preparation.require_idle_development_app"), \
                patch("scripts.ui_preparation.subprocess.run", side_effect=run):
            manifest = prepare(self.repo, work, self.manifest.parent)
            app, driver = validate(manifest, self.repo)
            self.assertEqual((app, driver), (work / "Rota.app", work / "driver"))
            self.resource.write_bytes(b"corrupted transfer")
            self.assertEqual(validate(manifest, self.repo), (app, driver))
            with self.assertRaisesRegex(ValueError, "Transferred UI inputs changed"):
                prepare(self.repo, work / "rejected", self.manifest.parent)

    def test_shell_rejects_stale_manifest_before_touching_preferences(self):
        root = Path(self.temporary.name)
        binary = root / "bin"
        binary.mkdir()
        marker = root / "preferences-touched"
        audit = root / "macaudit.py"
        audit.write_text("# The scope call is isolated by the uv fixture below.\n")
        commands = {"pgrep": "exit 1", "defaults": f": > {shlex.quote(str(marker))}\nexit 1",
                    "uv": 'test "$4" = scope'}
        for name, body in commands.items():
            script = binary / name
            script.write_text("#!/bin/sh\n" + body + "\n")
            script.chmod(0o755)
        project = Path(__file__).resolve().parents[2]
        for script, options in [("ui-check.sh", ["--filters-only"]), ("capture-screenshots.sh", [])]:
            with self.subTest(script=script):
                result = subprocess.run(["bash", str(project / "scripts" / script), *options,
                                         "--prepared", str(self.manifest)], capture_output=True, text=True,
                                        env=os.environ | {"PATH": str(binary) + os.pathsep + os.environ["PATH"],
                                                          "ROTA_MACAUDIT": str(audit)})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("another checkout", result.stderr)
                self.assertFalse(marker.exists(), "Rejected prepared inputs must not touch the user's defaults")

    def test_split_filters_keep_all_theme_scale_combinations_and_one_action_pass(self):
        phases = runpy.run_path(str(Path(__file__).resolve().parents[1] / "ui-suite.py"))["phases"]
        matrix = set()
        actions = 0
        for options in phases("filters"):
            values = dict(zip(options[::2], options[1::2]))
            actions += values["--phase"] == "actions"
            scales = ["normal", "zoom"] if values["--scale"] == "both" else [values["--scale"]]
            matrix.update((values["--appearance"], scale) for scale in scales)
        self.assertEqual(actions, 1)
        self.assertEqual(matrix, {(theme, scale) for theme in ["light", "dark"] for scale in ["normal", "zoom"]})
        question_phases = [dict(zip(options[::2], options[1::2])) for options in phases("questions")]
        self.assertEqual([item["--phase"] for item in question_phases], ["actions", "renders"])
        self.assertEqual({item["--appearance"] for item in question_phases}, {"light", "dark"})

    def test_toolbar_placement_uses_column_width_without_outline_inset(self):
        source = (Path(__file__).resolve().parents[1] / "ui-check.sh").read_text()
        body = source.split('if python3 - "$normal_bar"', 1)[1].split("<<'PYTHON'\n", 1)[1].split("\nPYTHON", 1)[0]
        rectangles = [
            [100, 100, 1000, 52], [388, 108, 36, 36], [1024, 108, 64, 36],
            [436, 117, 40, 18], [108, 152, 280, 500],
            [100, 100, 1000, 78], [392, 112, 54, 54], [986, 112, 96, 54],
            [464, 125.5, 60, 27], [108, 178, 280, 450],
        ]

        def verify():
            arguments = [" ".join(map(str, rect)) for rect in rectangles]
            return subprocess.run([sys.executable, "-c", body, *arguments], capture_output=True, text=True)

        self.assertEqual(verify().returncode, 0)
        rectangles[1][0] += 8
        self.assertNotEqual(verify().returncode, 0)

    def test_wait_value_retries_an_element_replaced_during_transition(self):
        root = Path(self.temporary.name)
        marker = root / "first-read"
        driver = root / "transient-driver"
        driver.write_text("#!/bin/bash\n"
                          f"if [[ ! -f {shlex.quote(str(marker))} ]]; then\n"
                          f"  touch {shlex.quote(str(marker))}\n  exit 1\nfi\necho Ready\n")
        driver.chmod(0o755)
        source = (Path(__file__).resolve().parents[1] / "ui-check.sh").read_text()
        function = "wait_value() {" + source.split("wait_value() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        script = root / "wait-check.sh"
        script.write_text(f"DRIVER={shlex.quote(str(driver))}\nsleep() {{ :; }}\n" + function
                          + "wait_value questionTitle Ready\n")
        result = subprocess.run(["bash", str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cleanup_stops_only_the_notice_it_started(self):
        stop = runpy.run_path(str(Path(__file__).resolve().parents[1] / "ui-suite.py"))["stop_notice"]
        with patch("subprocess.check_output", return_value=b'{"running":true,"pid":99}'), \
                patch("subprocess.run") as command:
            stop(Path("audit.py"), 42)
            command.assert_not_called()
        with patch("subprocess.check_output", return_value=b'{"running":true,"pid":42}'), \
                patch("subprocess.run") as command:
            stop(Path("audit.py"), 42)
            self.assertEqual(command.call_count, 1)

    def test_question_harnesses_share_the_job_matrix(self):
        jobs = runpy.run_path(str(Path(__file__).resolve().parents[1] / "ui-suite.py"))["jobs"]
        selected = list(jobs(["questions", "full"], ["codex", "antigravity"]))
        self.assertEqual({item[1] for item in selected if item[0] == "questions"}, {"codex", "antigravity"})
        self.assertEqual(len([item for item in selected if item[0] == "full"]), 1)


if __name__ == "__main__":
    unittest.main()
