"""Exercise audit preference restoration through macOS's real defaults tool."""

import importlib.util
import plistlib
import shlex
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

source = Path(__file__).resolve().parents[2] / "scripts/restore-defaults.py"
spec = importlib.util.spec_from_file_location("restore_defaults", source)
restoration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restoration)


class DefaultsRestorationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="rota-defaults-test-")
        self.backup = Path(self.folder.name) / "defaults.plist"
        self.domain = "com.wiltodelta.rota.test-" + uuid.uuid4().hex + ".dev"

    def tearDown(self):
        subprocess.run(["defaults", "delete", self.domain], capture_output=True, check=False)
        self.folder.cleanup()

    def current(self):
        return plistlib.loads(subprocess.check_output(["defaults", "export", self.domain, "-"]))

    def verify_snapshot(self, expected):
        self.backup.write_bytes(plistlib.dumps(expected))
        subprocess.run(["defaults", "import", self.domain, str(self.backup)], check=True)
        subprocess.run(["defaults", "write", self.domain, "added-by-audit", "-bool", "true"], check=True)
        self.assertTrue(self.current()["added-by-audit"])
        restoration.restore(self.domain, self.backup)
        self.assertEqual(self.current(), expected)

    def test_empty_snapshot_removes_keys_added_by_audit(self):
        self.verify_snapshot({})

    def test_existing_nested_values_are_restored_without_new_keys(self):
        self.verify_snapshot({"old": "retained", "nested": {"count": 3, "enabled": True}})

    def test_invalid_snapshot_does_not_change_preferences(self):
        subprocess.run(["defaults", "write", self.domain, "old", "-string", "retained"], check=True)
        before = self.current()
        self.backup.write_bytes(plistlib.dumps(["invalid"]))
        with self.assertRaises(ValueError):
            restoration.restore(self.domain, self.backup)
        self.assertEqual(self.current(), before)

    def test_production_domain_is_rejected_before_any_subprocess(self):
        self.backup.write_bytes(plistlib.dumps({}))
        with patch.object(restoration.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                restoration.restore("com.example.production", self.backup)
            run.assert_not_called()

    def test_shell_checks_report_cleanup_failure_and_retain_snapshot(self):
        root = source.parents[1]
        self.backup.write_bytes(plistlib.dumps(["invalid"]))
        callers = {}
        for path in (root / "scripts").glob("*.sh"):
            text = path.read_text()
            if source.name in text:
                callers[path] = text
        self.assertTrue(callers, "No shell check uses the defaults restoration helper.")
        for path, text in callers.items():
            with self.subTest(script=path.name):
                start = text.index("cleanup() {")
                cleanup = text[start:text.index("\n}", start) + 2]
                exit_trap = next(line for line in text.splitlines()
                                 if line.startswith("trap ") and line.endswith(" EXIT"))
                commands = "\n".join([
                    "quit_rota() { return 0; }",
                    "DOMAIN=" + shlex.quote(self.domain),
                    "WORK=" + shlex.quote(self.folder.name),
                    "W=" + shlex.quote(self.folder.name),
                    "REPO=" + shlex.quote(str(root)),
                    "DEFAULTS_BACKUP=" + shlex.quote(str(self.backup)),
                    cleanup, exit_trap, "exit 0",
                ])
                result = subprocess.run(["bash", "-c", commands], cwd=root, capture_output=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn(b"snapshot retained", result.stderr)
                self.assertTrue(self.backup.exists())


if __name__ == "__main__":
    unittest.main()
