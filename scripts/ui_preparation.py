"""Seal a development bundle and AX driver for one UI suite."""

import argparse
import hashlib
import json
import logging
import os
import plistlib
import shutil
import subprocess
from pathlib import Path

log = logging.getLogger(__name__)
DOMAIN = "com.wiltodelta.rota.dev"


def tree_hash(path: Path) -> str:
    digest = hashlib.sha256()
    paths = [path, *sorted(path.rglob("*"))] if path.is_dir() else [path]
    for entry in paths:
        name = str(entry.relative_to(path)) if entry != path else "."
        if entry.is_symlink():
            value = b"link:" + str(entry.readlink()).encode()
        elif entry.is_file():
            value = b"file:" + hashlib.sha256(entry.read_bytes()).digest()
        elif entry.is_dir():
            value = b"directory"
        else:
            raise ValueError(f"Missing prepared input: {entry}")
        digest.update(name.encode() + b"\0" + value + b"\0")
    return digest.hexdigest()


def source_hash(repo: Path) -> str:
    paths = subprocess.check_output([
        "git", "-C", str(repo), "ls-files", "-co", "--exclude-standard", "-z", "--",
        "Sources", "scripts", "Package.swift", "Package.resolved", "create-app.sh",
        ":(glob)*.xcassets/**", ":(glob)*.icon/**",
    ]).decode().split("\0")
    digest = hashlib.sha256()
    for name in sorted(set(paths) - {""}):
        if "__pycache__" in Path(name).parts or Path(name).suffix in {".pyc", ".pyo"}:
            continue
        path = repo / name
        value = tree_hash(path) if path.exists() or path.is_symlink() else "missing"
        digest.update(name.encode() + b"\0" + value.encode() + b"\0")
    return digest.hexdigest()


def fingerprint(repo: Path, app: Path, driver: Path) -> dict[str, str]:
    return {"source": source_hash(repo), "app": tree_hash(app), "driver": tree_hash(driver)}


def validate(manifest_path: Path, repo: Path) -> tuple[Path, Path]:
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schema") != 1 or manifest.get("repo") != str(repo.resolve()):
        raise ValueError("Prepared UI inputs belong to another checkout or schema")
    app, driver = Path(manifest["app"]), Path(manifest["driver"])
    if not app.is_absolute() or not driver.is_absolute():
        raise ValueError("Prepared paths must be absolute")
    if any("\n" in str(path) for path in [app, driver]):
        raise ValueError("Prepared paths cannot contain newlines")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != DOMAIN:
        raise ValueError("UI checks require the isolated development bundle")
    actual = fingerprint(repo, app, driver)
    if actual != manifest["fingerprint"]:
        changed = [name for name in actual if actual[name] != manifest["fingerprint"].get(name)]
        raise ValueError("Prepared UI inputs changed: " + ", ".join(changed))
    return app, driver


def require_idle_development_app() -> None:
    result = subprocess.run(["pgrep", "-f", "/Contents/MacOS/Rota$"], capture_output=True, text=True)
    if result.returncode not in [0, 1]:
        raise RuntimeError("Could not check running Rota processes")
    for pid in result.stdout.split():
        command = subprocess.run(["ps", "-p", pid, "-o", "comm="], capture_output=True, text=True).stdout.strip()
        if not command:
            continue
        app = Path(command).parents[2]
        try:
            domain = plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")
        except (OSError, plistlib.InvalidFileException) as error:
            raise RuntimeError(f"Cannot identify running Rota process {pid}: {command}") from error
        if domain == DOMAIN:
            raise RuntimeError(f"A development Rota is already running: pid {pid}, {app}")


def prepare(repo: Path, work: Path, artifacts=None) -> Path:
    require_idle_development_app()
    before = source_hash(repo)
    if artifacts is not None:
        transferred = json.loads((artifacts / "prepared.json").read_text())
        original = artifacts / "Rota.app"
        if transferred.get("schema") != 1 or fingerprint(repo, original, artifacts / "driver") != transferred.get("fingerprint"):
            raise ValueError("Transferred UI inputs changed or use another schema")
    else:
        subprocess.run(["bash", "create-app.sh"], cwd=repo, env=os.environ | {"RELEASE": "0"}, check=True)
        original = repo / "Rota.app"
    app, driver = work / "Rota.app", work / "driver"
    shutil.copytree(original, app, symlinks=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    if artifacts is not None:
        shutil.copy2(artifacts / "driver", driver)
    else:
        subprocess.run(["swiftc", "-O", str(repo / "scripts/ui-driver.swift"), "-o", str(driver)], check=True)
    sealed = fingerprint(repo, app, driver)
    if sealed["source"] != before:
        raise ValueError("Sources changed while preparing the UI suite")
    manifest = work / "prepared.json"
    manifest.write_text(json.dumps({"schema": 1, "repo": str(repo.resolve()), "app": str(app),
                                    "driver": str(driver), "fingerprint": sealed}, indent=2) + "\n")
    validate(manifest, repo)
    log.info("Prepared and verified one bundle and driver: %s", manifest)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "idle"])
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        if args.command == "idle":
            require_idle_development_app()
        else:
            if args.manifest is None:
                parser.error("validate requires --manifest")
            app, driver = validate(args.manifest, Path(__file__).resolve().parents[1])
            # Machine output consumed as two complete lines, never evaluated as shell code.
            import sys
            sys.stdout.write(f"{app}\n{driver}\n")
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"UI preparation failed: {error}\n")


if __name__ == "__main__":
    main()
