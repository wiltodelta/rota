#!/usr/bin/env python3
"""Opt-in, serial browser and desktop probes through the signed development app."""

import argparse
import base64
import json
import logging
import os
import plistlib
import secrets
import signal
import struct
import subprocess
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

log = logging.getLogger(__name__)
HARNESSES = ("claude", "codex", "grok")


def tools_from_events(events):
    """Join patches by turn and tool id, never by text or tool title alone."""
    tools = {}
    for event in events:
        patch = event.get("payload", {}).get("tool")
        if patch:
            key = (event["turnID"], patch["id"])
            merged = tools.setdefault(key, {})
            merged.update({k: v for k, v in patch.items() if v is not None and v != ""})
    return list(tools.values())


def assistant_reports(events):
    messages = {}
    for event in events:
        payload = event.get("payload", {})
        value = payload.get("assistant", payload.get("delta"))
        if value:
            key = (event["turnID"], value["id"])
            if "assistant" in payload:
                messages[key] = value["text"]
            else:
                messages[key] = messages.get(key, "") + value["text"]
    return list(messages.values())


def valid_png(raw):
    if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return False
    offset, pixels, dimensions = 8, bytearray(), None
    try:
        while offset < len(raw):
            size = int.from_bytes(raw[offset : offset + 4], "big")
            kind = raw[offset + 4 : offset + 8]
            chunk = raw[offset + 8 : offset + 8 + size]
            crc = raw[offset + 8 + size : offset + 12 + size]
            if (
                len(chunk) != size
                or len(crc) != 4
                or zlib.crc32(kind + chunk) != int.from_bytes(crc, "big")
            ):
                return False
            if kind == b"IHDR":
                width, height, depth, color, compression, filtering, interlace = (
                    struct.unpack(">IIBBBBB", chunk)
                )
                channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color)
                if (
                    not channels
                    or not width
                    or not height
                    or compression
                    or filtering
                    or interlace
                ):
                    return False
                dimensions = (height, (width * channels * depth + 7) // 8)
            if kind == b"IDAT":
                pixels.extend(chunk)
            offset += size + 12
            if kind == b"IEND" and dimensions and offset == len(raw):
                height, row = dimensions
                decoded = zlib.decompress(pixels)
                return len(decoded) == height * (row + 1) and all(
                    decoded[index] <= 4 for index in range(0, len(decoded), row + 1)
                )
    except (ValueError, struct.error, zlib.error):
        return False
    return False


def jpeg_dimensions(raw):
    if not raw.startswith(b"\xff\xd8") or not raw.endswith(b"\xff\xd9"):
        return False
    offset = 2
    while offset + 4 <= len(raw):
        if raw[offset] != 255:
            return False
        marker = raw[offset + 1]
        size = int.from_bytes(raw[offset + 2 : offset + 4], "big")
        if size < 2 or offset + 2 + size > len(raw):
            return False
        if marker in (0xC0, 0xC1, 0xC2):
            return (
                size >= 8
                and int.from_bytes(raw[offset + 5 : offset + 7], "big") > 0
                and int.from_bytes(raw[offset + 7 : offset + 9], "big") > 0
            )
        offset += size + 2
    return False


def image_in(value):
    """Require decoded image bytes, not a claimed screenshot or a file path."""
    if isinstance(value, dict):
        if value.get("type") == "image":
            source = value.get("source", value)
            encoded = source.get("data", "")
            try:
                raw = base64.b64decode(encoded, validate=True)
            except (ValueError, TypeError):
                raw = b""
            if valid_png(raw) or jpeg_dimensions(raw):
                return True
        return any(image_in(v) for v in value.values())
    if isinstance(value, list):
        return any(image_in(v) for v in value)
    if isinstance(value, str):
        try:
            return image_in(json.loads(value))
        except (ValueError, RecursionError):
            return False
    return False


def inspect(events, challenge):
    results = {
        "browser": {"status": "unverified"},
        "computer": {"status": "unverified"},
    }
    for tool in tools_from_events(events):
        title = tool.get("title", "").lower()
        source = (title + " " + tool.get("input", "")).lower()
        output = tool.get("output", "")
        if not output or tool.get("status", "").lower() in (
            "running",
            "failed",
            "error",
        ):
            continue
        # Shell, fetch and the agent's final text cannot prove browser access.
        browser = any(
            name in title for name in ("browser", "playwright", "chrome", "cua")
        ) or (title == "js" and "document.queryselector" in source)
        if browser and challenge in output:
            results["browser"] = {
                "status": "passed",
                "tool": tool["id"],
                "title": tool["title"],
            }
        # A browser screenshot does not establish native desktop access.
        desktop = ("computer" in title and "chrome" not in title) or (
            "cua" in title
            and any(name in source for name in ("getapp(", "getstate(", "desktop"))
        )
        try:
            payload = json.loads(output)
            surface = (
                payload.get("_meta", {}).get("codex/toolSurface", {})
                if isinstance(payload, dict)
                else {}
            )
            desktop = desktop or (
                surface.get("kind") == "computerUse" and bool(surface.get("app"))
            )
        except ValueError:
            pass
        if desktop and image_in(output):
            results["computer"] = {
                "status": "passed",
                "tool": tool["id"],
                "title": tool["title"],
            }
    return results


def command(cli, env, *args):
    completed = subprocess.run(
        [str(cli), *args, "--json"],
        env=env,
        text=True,
        capture_output=True,
        timeout=35,
        check=True,
    )
    return json.loads(completed.stdout)


def app_pids(executable):
    rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    return [
        int(row.split(None, 1)[0])
        for row in rows.splitlines()
        if len(row.split(None, 1)) == 2 and row.split(None, 1)[1] == str(executable)
    ]


def prompt(url):
    return f"""Run two independent, read-only capability probes with your existing tools and settings.
Do not run any routine, skill, project task or production workflow. Do not change files, config,
permissions, accounts or macOS grants. Do not install tools. Do not use shell, curl, HTTP clients,
WebFetch or file reads as a substitute for either probe. Do not send messages or notifications.
1. Browser: open {url} in your available browser integration, in a NEW owned tab. Execute browser
JavaScript to return document.querySelector('#challenge').textContent after the script has run.
Use a real browser tool result, not an inferred answer. Close only the tab you created.
2. Computer use: independently use an available NATIVE desktop/computer tool to capture one
screenshot of a neutral application window, preferably Calculator. A browser screenshot does not
satisfy this probe. Do not click or type into user applications. Return the image in the tool result;
do not save it to disk or expose other windows. If this needs a permission grant, stop this probe.
For each probe report passed, unavailable, blocked or failed, with the exact tool/error and scope.
A missing tool is unavailable, a denied permission is blocked, a transport error is failed.
Do not claim success from your own text. If one probe fails, still attempt the other independently.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--live",
        action="store_true",
        help="spends agent quota and may capture a window",
    )
    parser.add_argument(
        "--app", type=Path, default=Path(__file__).resolve().parents[1] / "Rota.app"
    )
    parser.add_argument(
        "--folder", type=Path, default=Path.cwd(), help="already trusted project folder"
    )
    parser.add_argument("--harness", choices=HARNESSES, action="append")
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    if not args.live:
        parser.error("explicit --live required; ordinary tests never launch an agent")
    if args.timeout < 60 or not args.folder.is_dir():
        parser.error("timeout must be at least 60 seconds and folder must exist")
    app = args.app.resolve()
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info["CFBundleIdentifier"] != "com.wiltodelta.rota.dev":
        parser.error("use the development bundle, never the installed production app")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    executable = app / "Contents/MacOS/Rota"
    if app_pids(executable):
        parser.error(
            "development Rota is already running; this check will not quit someone else's app"
        )
    os.umask(0o077)
    work = Path(tempfile.mkdtemp(prefix="rota-capability-"))
    env = dict(os.environ, ROTA_DATA_DIR=str(work / "data"))
    cli = app / "Contents/Helpers/rota"
    challenges = {}

    class Page(BaseHTTPRequestHandler):
        def do_GET(self):
            token = challenges.get(self.path)
            if not token:
                self.send_error(404)
                return
            # Value is not present as readable page text until JavaScript executes.
            codes = ",".join(str(ord(char)) for char in token)
            body = (
                "<!doctype html><title>Rota browser probe</title><p id='challenge'>Loading</p>"
                "<script>document.querySelector('#challenge').textContent="
                f"String.fromCharCode({codes});</script>"
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    owned = []
    report = {
        "app": str(app),
        "bundle": info["CFBundleIdentifier"],
        "results": {},
        "artifacts": str(work),
        "sessionsRetained": True,
    }
    active = None
    try:
        for harness in args.harness or HARNESSES:
            path = "/" + secrets.token_hex(16)
            challenge = f"Rota browser probe: {secrets.randbelow(10**9)}, {secrets.randbelow(10**9)}."
            challenges[path] = challenge
            url = f"http://127.0.0.1:{server.server_port}{path}"
            routine = "capability-" + harness
            command(
                cli,
                env,
                "add",
                routine,
                "--folder",
                str(args.folder.resolve()),
                "--schedule",
                "0 0 1 1 *",
                "--harness",
                harness,
                "--off",
                "--time-limit",
                str((args.timeout + 59) // 60),
                "--prompt",
                prompt(url),
            )
            owned = app_pids(executable)
            if len(owned) != 1:
                raise RuntimeError("cannot identify the app started by this check")
            active = routine
            command(cli, env, "run", routine)
            deadline = time.monotonic() + args.timeout
            while True:
                session = command(cli, env, "sessions", routine)[0]
                if not session["running"]:
                    break
                if time.monotonic() >= deadline:
                    command(cli, env, "stop", routine)
                    stop_deadline = time.monotonic() + 30
                    while time.monotonic() < stop_deadline:
                        session = command(cli, env, "sessions", routine)[0]
                        if not session["running"]:
                            break
                        time.sleep(0.25)
                    if session["running"]:
                        raise RuntimeError(
                            "provider did not stop; keep artifacts for diagnosis"
                        )
                    break
                time.sleep(1)
            # Read the app's persisted journal, not a claim in the exported readable log.
            records = json.loads((work / "data/runs" / (routine + ".json")).read_text())
            record = records[0]
            journal = Path(record["logPath"] + ".events.jsonl")
            events = [json.loads(line) for line in journal.read_text().splitlines()]
            result = inspect(events, challenge)
            result.update(
                outcome=session["outcome"],
                providerSession=record.get("sessionID"),
                journal=str(journal),
                expectedBrowserValue=challenge,
            )
            # Keep self-reported blockers distinct from verified evidence.
            result["agentReport"] = assistant_reports(events)
            report["results"][harness] = result
            active = None
            log.info(
                "%s: browser=%s computer=%s",
                harness,
                result["browser"]["status"],
                result["computer"]["status"],
            )
    finally:
        try:
            if active:
                command(cli, env, "stop", active)
            for pid in owned:
                if pid in app_pids(executable):
                    os.kill(pid, signal.SIGTERM)
                    deadline = time.monotonic() + 5
                    while pid in app_pids(executable) and time.monotonic() < deadline:
                        time.sleep(0.25)
                    if pid in app_pids(executable):
                        os.kill(pid, signal.SIGKILL)
        except (OSError, subprocess.SubprocessError) as error:
            report["cleanupError"] = str(error)
            log.error("Cleanup could not finish: %s", error)
        server.shutdown()
        server.server_close()
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        log.info(
            "Private report and provider session IDs retained at %s",
            work / "report.json",
        )
    return (
        0
        if all(
            result[key]["status"] == "passed"
            for result in report["results"].values()
            for key in ("browser", "computer")
        )
        else 1
    )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    raise SystemExit(main())
