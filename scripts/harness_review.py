#!/usr/bin/env python3
"""Collect public compatibility evidence; accept only explicitly reviewed changes."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import logging
import os
import re
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from html.parser import HTMLParser
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parent.parent
SKILL = ROOT / ".claude/skills/harness-compatibility-weekly"


class PageText(HTMLParser):
    """Ignore executable/style payloads and whitespace changes in HTML sources."""

    def __init__(self):
        super().__init__()
        self.hidden = 0
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "noscript", "svg"}:
            self.hidden += 1

    def handle_endtag(self, tag):
        if tag in {"script", "style", "noscript", "svg"}:
            self.hidden = max(0, self.hidden - 1)

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def normalize(text, kind="text"):
    if kind == "release":
        release = json.loads(text)
        return json.dumps(
            {
                key: release[key]
                for key in ["tag_name", "html_url", "published_at", "body"]
            },
            sort_keys=True,
            ensure_ascii=False,
        )
    if re.search(r"<(?:!doctype|html)\b", text[:500], re.IGNORECASE):
        parser = PageText()
        parser.feed(text)
        text = "\n".join(parser.parts)
    return "\n".join(line.rstrip() for line in text.splitlines() if line.strip())


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    if len(data.encode()) > 240_000:
        raise ValueError("State exceeds its bounded file budget")
    name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, delete=False
        ) as file:
            name = file.name
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        if name and os.path.exists(name):
            os.unlink(name)


def load_state(path):
    state = json.loads(path.read_text())
    if (
        state.get("version") != 1
        or not isinstance(state.get("sources"), dict)
        or not isinstance(state.get("runs"), list)
    ):
        raise ValueError("Invalid review state; refusing to reset the baseline")
    for source in state["sources"].values():
        if not isinstance(source, dict) or (
            "sha256" in source and not re.fullmatch("[a-f0-9]{64}", source["sha256"])
        ):
            raise ValueError("Invalid source baseline")
    return state


def comparison(previous, current):
    if "error" in current:
        return "unavailable"
    if not previous.get("sha256"):
        return "baseline"
    return "unchanged" if previous["sha256"] == current["sha256"] else "changed"


def fetch_source(source, output):
    key, url = source["id"], source["url"]
    log.info("GET %s", url)
    try:
        with urlopen(
            Request(url, headers={"User-Agent": "Rota-compatibility-review"}),
            timeout=40,
        ) as response:
            body = response.read(4_000_001)
            log.info("GET %s status=%s bytes=%s", url, response.status, len(body))
        if len(body) > 4_000_000:
            raise ValueError("Source exceeds collection budget")
        raw = body.decode("utf-8")
        if source.get("format") == "release":
            log.info("API response GET %s: %s", url, raw)
        text = normalize(raw, source.get("format", "text"))
        if len(text) < 100 or source["marker"].lower() not in text.lower():
            raise ValueError("Expected documentation content was not found")
        result = {"url": url, "sha256": hashlib.sha256(text.encode()).hexdigest()}
        (output / (key + ".txt")).write_text(text)
    except (ValueError, OSError, KeyError) as error:
        if isinstance(error, HTTPError) and source.get("format") == "release":
            log.warning(
                "API failure GET %s status=%s response=%s",
                url,
                error.code,
                error.read().decode("utf-8", errors="replace"),
            )
        log.warning("Source %s unavailable: %s", url, error)
        result = {"url": url, "error": type(error).__name__}
    return key, result


def collect(state, output, catalog=None, contracts_ok=False):
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((SKILL / "sources.json").read_text())
    seen = set()
    for source in manifest:
        key, url = source["id"], source["url"]
        if (
            not re.fullmatch("[a-z0-9-]+", key)
            or key in seen
            or not url.startswith("https://")
        ):
            raise ValueError("Invalid source manifest")
        seen.add(key)
    results = {}
    with ThreadPoolExecutor(max_workers=4) as executor:
        for key, result in executor.map(partial(fetch_source, output=output), manifest):
            result["comparison"] = comparison(state["sources"].get(key, {}), result)
            results[key] = result
    catalogs = json.loads(catalog.read_text()) if catalog and contracts_ok else {}
    for harness in ["claude", "codex", "grok", "antigravity"]:
        key = "installed-" + harness
        value = catalogs.get(harness)
        if value and value.get("models") and isinstance(value.get("version"), str):
            text = json.dumps(value, sort_keys=True)
            version = re.search(r"\b\d+\.\d+\.\d+\b", value["version"])
            result = {
                "sha256": hashlib.sha256(text.encode()).hexdigest(),
                "version": version.group() if version else "unreported",
            }
            (output / (key + ".txt")).write_text(text)
        else:
            result = {"error": "InstalledContractsUnavailable"}
        result["comparison"] = comparison(state["sources"].get(key, {}), result)
        results[key] = result
    collection = {
        "version": 1,
        "checked_at": subprocess.check_output(
            ["date", "-u", "+%Y-%m-%dT%H:%MZ"], text=True
        ).strip(),
        "sources": results,
    }
    atomic_json(output / "collection.json", collection)
    return collection


def accept(state, collection, reviewed):
    if collection.get("version") != 1 or not isinstance(
        collection.get("sources"), dict
    ):
        raise ValueError("Invalid collection")
    updated = copy.deepcopy(state)
    for key, current in collection["sources"].items():
        previous = updated["sources"].get(key, {})
        entry = dict(previous)
        status = comparison(previous, current)
        entry["checked_at"] = collection["checked_at"]
        if status == "unavailable":
            entry.update(
                status=status,
                failures=previous.get("failures", 0) + 1,
                error=current["error"],
            )
        elif status == "unchanged" or key in reviewed:
            if not re.fullmatch("[a-f0-9]{64}", current.get("sha256", "")):
                raise ValueError("Invalid collected digest")
            entry.update(
                {
                    field: current[field]
                    for field in ["sha256", "url", "version"]
                    if field in current
                }
            )
            entry.update(
                status="reviewed", failures=0, reviewed_at=collection["checked_at"]
            )
            entry.pop("error", None)
        else:
            entry.update(status="unreviewed", failures=0)
        updated["sources"][key] = entry
    updated["runs"] = sorted(
        [
            *state["runs"],
            {"checked_at": collection["checked_at"], "reviewed": sorted(reviewed)},
        ],
        key=lambda run: run["checked_at"],
        reverse=True,
    )[:16]
    return updated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, default=SKILL / "state/progress.json")
    commands = parser.add_subparsers(dest="command", required=True)
    collector = commands.add_parser("collect")
    collector.add_argument("--output", type=Path, required=True)
    collector.add_argument("--catalog", type=Path)
    collector.add_argument("--contracts-ok", action="store_true")
    accepting = commands.add_parser("accept")
    accepting.add_argument("--collection", type=Path, required=True)
    accepting.add_argument("--reviewed", nargs="*", default=[])
    accepting.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    state = load_state(args.state)
    if args.command == "collect":
        collect(state, args.output, args.catalog, args.contracts_ok)
    else:
        updated = accept(
            state, json.loads(args.collection.read_text()), set(args.reviewed)
        )
        if args.dry_run:
            log.info("Dry run: %s", json.dumps(updated, sort_keys=True))
        else:
            atomic_json(args.state, updated)


if __name__ == "__main__":
    main()
