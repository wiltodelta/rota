"""Disabled sessions with different lazy estimates for repeated paint checks."""

import json
import sys
import uuid
from datetime import datetime, timedelta
from pathlib import Path

root = Path(sys.argv[1])
project = Path(sys.argv[2])
(root / "runs").mkdir(parents=True, exist_ok=True)
(root / "Logs").mkdir(exist_ok=True)
now = datetime.now().astimezone().replace(microsecond=0)
routines = []
for offset, (key, count, repeats) in enumerate(
    [("alpha", 620, 65), ("beta", 12, 8), ("gamma", 3, 1800)]
):
    routine = "paint-" + key
    log = root / "Logs" / (routine + ".log")
    log.write_text("Synthetic readable log.\n", encoding="utf-8")
    size = log.stat().st_size
    rows = [{"version": 1, "type": "header", "logSize": size}]
    items = [
        (
            "user" if index % 5 == 0 else "agent",
            f"Message {index}. " + "Synthetic paragraph text. " * repeats,
        )
        for index in range(count)
    ] + [("agent", "Paint marker " + key)]
    for index, (kind, text) in enumerate(items):
        rows.append(
            {
                "version": 1,
                "type": "item",
                "logSize": size,
                "id": index,
                "kind": kind,
                "text": text,
                "complete": True,
            }
        )
    Path(str(log) + ".chat.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
    )
    routines.append(
        {
            "id": routine,
            "name": "Paint " + key,
            "harness": "antigravity",
            "enabled": False,
            "schedule": "0 9 * * *",
            "workingDirectory": str(project),
            "prompt": "Read the synthetic report.",
        }
    )
    started = now - timedelta(minutes=offset + 1)
    (root / "runs" / (routine + ".json")).write_text(
        json.dumps(
            [
                {
                    "id": str(uuid.uuid4()),
                    "routineID": routine,
                    "trigger": "manual",
                    "harness": "antigravity",
                    "startedAt": started.isoformat(),
                    "endedAt": (started + timedelta(seconds=1)).isoformat(),
                    "outcome": {"succeeded": {}},
                    "logPath": str(log),
                    "sessionID": "synthetic-" + key,
                }
            ]
        ),
        encoding="utf-8",
    )
(root / "routines.json").write_text(json.dumps(routines), encoding="utf-8")
