#!/usr/bin/env python3
"""Collect bounded, local performance evidence from an already running Rota."""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import platform
import plistlib
import signal
import subprocess
import time
from datetime import datetime
from pathlib import Path

log = logging.getLogger(__name__)
DEFAULT_ROOT = Path.home() / "Library/Logs/Rota/Performance"


def timestamp():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def cpu_seconds(value):
    """Decode ps cumulative CPU time, including hours and days."""
    days, separator, clock = value.rpartition("-")
    parts = (clock if separator else value).split(":")
    total = 0.0
    for part in parts:
        total = total * 60 + float(part)
    return total + (int(days) * 86400 if separator else 0)


def process_rows(output, executable):
    rows = []
    for line in output.splitlines():
        fields = line.split(None, 8)
        if len(fields) != 9 or fields[8] != str(executable):
            continue
        rows.append(
            {
                "pid": int(fields[0]),
                "cpu_seconds": cpu_seconds(fields[1]),
                "rss_bytes": int(fields[2]) * 1024,
                "started": " ".join(fields[3:8]),
            }
        )
    return rows


def processes(app):
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,time=,rss=,lstart=,comm="],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
        env={**os.environ, "LC_ALL": "C"},
    )
    return process_rows(result.stdout, app / "Contents/MacOS/Rota")


def interval_cpu(previous, current, elapsed):
    if previous is None or elapsed <= 0:
        return None
    if (previous["pid"], previous["started"]) != (current["pid"], current["started"]):
        return None
    difference = current["cpu_seconds"] - previous["cpu_seconds"]
    return max(0.0, difference / elapsed * 100)


def observe(app, folder):
    try:
        return processes(app)
    except (OSError, subprocess.SubprocessError) as error:
        log.warning("Process observation failed: %s", type(error).__name__)
        append_event(
            folder, {"event": "observation_failed", "error": type(error).__name__}
        )
        return []


def append_event(folder, event):
    with (folder / "metrics.jsonl").open("a", encoding="utf-8") as file:
        file.write(json.dumps({"time": timestamp(), **event}, allow_nan=False) + "\n")


def capture_stack(folder, process):
    """sample may be denied by macOS; preserve that failure as evidence."""
    name = "stack-" + datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z") + ".txt"
    target = folder / name
    try:
        result = subprocess.run(
            [
                "/usr/bin/sample",
                str(process["pid"]),
                "3",
                "10",
                "-file",
                str(target),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=90,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        log.warning(
            "Stack capture failed for pid %s: %s", process["pid"], type(error).__name__
        )
        append_event(
            folder,
            {
                "event": "stack_failed",
                "pid": process["pid"],
                "error": type(error).__name__,
            },
        )
        return False
    if result.returncode != 0 or not target.exists():
        log.warning(
            "Stack capture failed for pid %s: %s", process["pid"], result.stderr.strip()
        )
        append_event(
            folder,
            {"event": "stack_failed", "pid": process["pid"], "code": result.returncode},
        )
        return False
    # No transcript is read. Native symbol reports can still contain local paths.
    text = target.read_text(errors="replace").replace(str(Path.home()), "~")
    target.write_text(text, encoding="utf-8")
    append_event(folder, {"event": "stack", "pid": process["pid"], "file": name})
    log.info("Stack saved: %s", target)
    return True


def make_folder(root, app):
    root.mkdir(parents=True, exist_ok=True)
    folder = root / (
        datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z") + "-" + str(os.getpid())
    )
    folder.mkdir(mode=0o700)
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    metadata = {
        "schema": 1,
        "started": timestamp(),
        "collector_pid": os.getpid(),
        "app_version": info.get("CFBundleShortVersionString"),
        "app_build": info.get("CFBundleVersion"),
        "bundle_id": info.get("CFBundleIdentifier"),
        "os": platform.mac_ver()[0],
        "architecture": platform.machine(),
        "cpu_count": os.cpu_count(),
        "cpu_convention": "100 percent = one CPU core",
    }
    (folder / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return folder


def collect(args):
    folder = make_folder(args.output, args.app)
    log.info("Collecting locally in %s for %s seconds", folder, args.duration)
    stopped = False

    def stop(_signum, _frame):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    previous = None
    previous_at = 0.0
    high = 0
    stacks = 0
    last_stack = -math.inf
    deadline = time.monotonic() + args.duration
    append_event(
        folder,
        {
            "event": "start",
            "interval_seconds": args.interval,
            "duration_seconds": args.duration,
            "stack_cpu_threshold": args.stack_cpu,
        },
    )
    try:
        while not stopped and time.monotonic() < deadline:
            tick = time.monotonic()
            rows = observe(args.app, folder)
            if len(rows) != 1:
                append_event(folder, {"event": "unavailable", "matches": len(rows)})
                previous = None
                high = 0
            else:
                current = rows[0]
                cpu = interval_cpu(previous, current, tick - previous_at)
                append_event(
                    folder,
                    {
                        "event": "sample",
                        **current,
                        "cpu_percent": cpu,
                        "interval_seconds": tick - previous_at if previous else None,
                        "load_1m": os.getloadavg()[0],
                    },
                )
                high = high + 1 if cpu is not None and cpu >= args.stack_cpu else 0
                previous, previous_at = current, tick
                if high >= 3 and tick - last_stack >= 600 and stacks < 12:
                    # Recheck identity immediately before sampling; do not target another app on relaunch.
                    latest = observe(args.app, folder)
                    if len(latest) == 1 and (
                        latest[0]["pid"],
                        latest[0]["started"],
                    ) == (current["pid"], current["started"]):
                        capture_stack(folder, current)
                    stacks += 1
                    last_stack = tick
            remaining = min(
                args.interval - (time.monotonic() - tick), deadline - time.monotonic()
            )
            if remaining > 0 and not stopped:
                time.sleep(remaining)
    finally:
        append_event(
            folder,
            {"event": "stop", "reason": "signal" if stopped else "duration_or_error"},
        )
    log.info("Collection finished: %s", folder)


def percentile(ordered, fraction):
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def report(folder):
    result = {
        "folder": str(folder),
        "complete": False,
        "samples": 0,
        "processes": 0,
        "unavailable_samples": 0,
        "stacks": 0,
        "stack_failures": 0,
    }
    counters = {
        "unavailable": "unavailable_samples",
        "stack": "stacks",
        "stack_failed": "stack_failures",
    }
    identities = set()
    cpu = []
    first = last = None
    max_rss = 0
    with (folder / "metrics.jsonl").open(encoding="utf-8") as file:
        for line in file:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                log.warning("Ignoring incomplete metrics line")
                continue
            kind = event["event"]
            result["complete"] = kind == "stop"
            if kind in counters:
                result[counters[kind]] += 1
            if kind != "sample":
                continue
            result["samples"] += 1
            identities.add((event["pid"], event["started"]))
            if event["cpu_percent"] is not None:
                cpu.append(event["cpu_percent"])
            first = first or event
            last = event
            max_rss = max(max_rss, event["rss_bytes"])
    result["processes"] = len(identities)
    metadata_file = folder / "metadata.json"
    if metadata_file.exists():
        metadata = json.loads(metadata_file.read_text())
        result.update(
            {key: metadata[key] for key in ("app_version", "app_build", "os")}
        )
    if first:
        result.update(
            {
                "first": first["time"],
                "last": last["time"],
                "rss_first_mib": round(first["rss_bytes"] / 1048576, 1),
                "rss_last_mib": round(last["rss_bytes"] / 1048576, 1),
                "rss_max_mib": round(max_rss / 1048576, 1),
            }
        )
    if cpu:
        cpu.sort()
        result.update(
            {
                "cpu_p50": round(percentile(cpu, 0.5), 1),
                "cpu_p95": round(percentile(cpu, 0.95), 1),
                "cpu_max": round(cpu[-1], 1),
            }
        )
    log.info("Performance report:\n%s", json.dumps(result, indent=2))
    return result


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    record = commands.add_parser(
        "collect", help="Record an existing app without restarting it"
    )
    record.add_argument("--app", type=Path, default=Path("/Applications/Rota.app"))
    record.add_argument("--output", type=Path, default=DEFAULT_ROOT)
    record.add_argument(
        "--duration", type=positive, default=86400, help="Seconds, at most seven days"
    )
    record.add_argument(
        "--interval", type=positive, default=5, help="Seconds, at least one"
    )
    record.add_argument(
        "--stack-cpu", type=positive, default=20, help="CPU threshold, 100 = one core"
    )
    summary = commands.add_parser(
        "report", help="Summarize one collection, including an ongoing one"
    )
    summary.add_argument("folder", type=Path)
    snapshot = commands.add_parser(
        "snapshot", help="Capture stacks now, including low-CPU hangs"
    )
    snapshot.add_argument("--app", type=Path, default=Path("/Applications/Rota.app"))
    snapshot.add_argument("--output", type=Path, default=DEFAULT_ROOT)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "collect":
        if args.interval < 1 or args.duration > 604800:
            parser.error(
                "interval must be at least one second and duration at most seven days"
            )
        args.app = args.app.expanduser().resolve()
        args.output = args.output.expanduser()
        collect(args)
    elif args.command == "snapshot":
        args.app = args.app.expanduser().resolve()
        rows = processes(args.app)
        if len(rows) != 1:
            parser.error("expected exactly one running Rota at --app")
        if not capture_stack(make_folder(args.output.expanduser(), args.app), rows[0]):
            raise SystemExit(1)
    else:
        report(args.folder.expanduser())


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    main()
