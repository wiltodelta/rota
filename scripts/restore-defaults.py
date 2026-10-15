"""Restore the exact preferences snapshot of a stopped development audit app."""

import argparse
import logging
import plistlib
import subprocess
from pathlib import Path

log = logging.getLogger(__name__)


def restore(domain: str, backup: Path) -> None:
    if not domain.endswith(".dev"):
        raise ValueError("Only a development defaults domain may be restored.")
    expected = plistlib.loads(backup.read_bytes())
    if not isinstance(expected, dict):
        raise ValueError("The defaults snapshot must be a dictionary.")
    # Import merges keys. Remove additions made by the audit before importing.
    subprocess.run(["defaults", "delete", domain], capture_output=True, check=False)
    subprocess.run(["defaults", "import", domain, str(backup)], capture_output=True, check=True)
    exported = subprocess.run(["defaults", "export", domain, "-"], capture_output=True, check=True)
    if plistlib.loads(exported.stdout) != expected:
        raise RuntimeError("The restored defaults differ from the snapshot.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("domain")
    parser.add_argument("backup", type=Path)
    args = parser.parse_args()
    try:
        restore(args.domain, args.backup)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        log.error("Defaults restoration failed; snapshot retained at %s", args.backup)
        return 1
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    raise SystemExit(main())
