"""Run selected UI surfaces with one sealed development app and AX driver."""

import argparse
import json
import logging
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.ui_preparation import DOMAIN, prepare, require_idle_development_app, validate

log = logging.getLogger(__name__)
MODES = ["filters", "questions", "settings", "harnesses", "restart", "keyboard", "scroll",
         "parallel", "paint", "switch", "full", "live"]


def phases(mode: str) -> list[list[str]]:
    if mode == "filters":
        return [
            ["--phase", "actions", "--appearance", "light", "--scale", "normal"],
            ["--phase", "renders", "--appearance", "light", "--scale", "zoom"],
            ["--phase", "renders", "--appearance", "dark", "--scale", "both"],
        ]
    if mode == "questions":
        return [["--phase", "actions", "--appearance", "light"],
                ["--phase", "renders", "--appearance", "dark"]]
    return [[]]


def require_idle_notice(audit: Path) -> None:
    status = json.loads(subprocess.check_output(["uv", "run", "-q", str(audit), "notice", "status"]))
    if status.get("running"):
        raise RuntimeError("Another capture owns the shared UI notice; wait for it to finish")


def jobs(modes: list[str], harnesses: list[str]):
    for mode in modes:
        for harness in harnesses if mode == "questions" else [None]:
            for index, options in enumerate(phases(mode), 1):
                yield mode, harness, index, options


def stop_notice(audit: Path, owner_pid: int) -> None:
    status = json.loads(subprocess.check_output(["uv", "run", "-q", str(audit), "notice", "status"]))
    if status.get("pid") == owner_pid:
        subprocess.run(["uv", "run", "-q", str(audit), "notice", "stop"], check=True)
    elif status.get("running"):
        log.warning("UI notice ownership changed to pid %s; owned pid was %s", status.get("pid"), owner_pid)


def stop_prepared_app(app: Path) -> None:
    result = subprocess.run(["pgrep", "-f", f"^{re.escape(str(app))}/Contents/MacOS/Rota$"],
                            capture_output=True, text=True)
    for value in result.stdout.split():
        pid = int(value)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        for _ in range(50):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"Prepared Rota did not stop: pid {pid}")
    subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                    "-u", str(app)], capture_output=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", action="store_true", help="Only for explicitly agreed host diagnostics")
    parser.add_argument("--modes", nargs="+", choices=MODES, required=True)
    parser.add_argument("--out", type=Path, help="Capture and timing folder; defaults to a unique temporary folder")
    parser.add_argument("--artifacts", type=Path,
                        help="Transferred Rota.app, driver and prepared.json; verifies all hashes before reuse")
    parser.add_argument("--question-harnesses", nargs="+", choices=["codex", "antigravity"],
                        help="Question fixture matrix; defaults to ROTA_UI_QUESTION_HARNESS or codex")
    args = parser.parse_args()
    harnesses = args.question_harnesses or [os.environ.get("ROTA_UI_QUESTION_HARNESS", "codex")]
    if any(value not in ["codex", "antigravity"] for value in harnesses):
        parser.error("Question harness must be codex or antigravity")
    if args.question_harnesses and "questions" not in args.modes:
        parser.error("--question-harnesses requires questions in --modes")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    repo = Path(__file__).resolve().parents[1]
    audit = Path(os.environ.get("ROTA_MACAUDIT", str(Path.home()
        / "Documents/GitHub/claude-config/skills/ui-audit-macos/scripts/macaudit.py")))
    subprocess.run(["uv", "run", "-q", str(audit), "scope", *(["--allow-host"] if args.host else [])], check=True)
    out = (args.out or Path(tempfile.mkdtemp(prefix="rota-ui-results-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    timings = []
    notice_pid = None
    log.info("UI suite results: %s", out)
    require_idle_notice(audit)
    with tempfile.TemporaryDirectory(prefix="rota-ui-prepared-") as temporary:
        work = Path(temporary).resolve()
        try:
            started = time.monotonic()
            manifest = prepare(repo, work, args.artifacts)
            timings.append({"phase": "prepare", "seconds": round(time.monotonic() - started, 2), "exit": 0})
            (out / "timings.json").write_text(json.dumps(timings, indent=2) + "\n")
            require_idle_notice(audit)
            subprocess.run(["uv", "run", "-q", str(audit), "preflight", "--require-unlocked"], check=True)
            notice = json.loads(subprocess.check_output([
                "uv", "run", "-q", str(audit), "notice", "start", "--app", "Rota Dev",
                "--purpose", "Checking selected UI surfaces with one verified build"]))
            notice_pid = notice.get("pid")
            for mode, harness, index, options in jobs(args.modes, harnesses):
                name = f"{mode}{'-' + harness if harness else ''}-{index}"
                validate(manifest, repo)
                require_idle_development_app()
                flag = {"full": "--full", "live": "--live"}.get(mode, f"--{mode}-only")
                command = ["uv", "run", "-q", str(audit), "notice", "run", "--", "bash",
                           "scripts/ui-check.sh", *(["--host"] if args.host else []), flag, "--prepared", str(manifest), *options]
                env = os.environ | {"ROTA_UI_OUT": str(out / name), "ROTA_BUNDLE_ID": DOMAIN}
                if harness:
                    env["ROTA_UI_QUESTION_HARNESS"] = harness
                log.info("Starting %s: %s", name, " ".join(options) or "all existing checks")
                started = time.monotonic()
                with (out / f"{name}.log").open("w") as output:
                    result = subprocess.run(command, cwd=repo, env=env, stdout=output, stderr=subprocess.STDOUT)
                timings.append({"phase": name, "options": options,
                                "seconds": round(time.monotonic() - started, 2), "exit": result.returncode})
                (out / "timings.json").write_text(json.dumps(timings, indent=2) + "\n")
                if result.returncode:
                    raise RuntimeError(f"{name} failed; inspect {out / (name + '.log')} and its failure evidence")
                validate(manifest, repo)
                log.info("Passed %s", name)
        finally:
            try:
                if notice_pid is not None:
                    stop_notice(audit, notice_pid)
            finally:
                if (work / "Rota.app").exists():
                    stop_prepared_app(work / "Rota.app")
    log.info("UI suite passed; captures and timings: %s", out)


if __name__ == "__main__":
    main()
