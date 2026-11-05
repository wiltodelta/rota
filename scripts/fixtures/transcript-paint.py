"""Disabled synthetic history for a first-paint check, without querying Accessibility."""

import json
import sys
import uuid
from datetime import datetime, timedelta
from pathlib import Path

root = Path(sys.argv[1])
project = Path(sys.argv[2])
(root / "runs").mkdir(parents=True, exist_ok=True)
(root / "Logs").mkdir(exist_ok=True)
routine = "transcript-paint"
log = root / "Logs/session.log"
log.write_text("Synthetic readable log.\n", encoding="utf-8")
size = log.stat().st_size
rows = [{"version": 1, "type": "header", "logSize": size}]
items = [
    (
        "user" if index % 5 == 0 else "agent",
        f"Message {index}. " + "Synthetic paragraph text. " * 65,
    )
    for index in range(620)
]
items += [
    ("error", "Paint check passed after a long conversation."),
    ("status", "Failed (exit 1) after 1s"),
]
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
now = datetime.now().astimezone().replace(microsecond=0)
stamp = lambda value: value.isoformat()
(root / "routines.json").write_text(
    json.dumps(
        [
            {
                "id": routine,
                "name": "Transcript paint check",
                "harness": "antigravity",
                "enabled": False,
                "schedule": "0 9 * * *",
                "workingDirectory": str(project),
                "prompt": "Read a synthetic report.",
            }
        ]
    ),
    encoding="utf-8",
)
(root / "runs" / (routine + ".json")).write_text(
    json.dumps(
        [
            {
                "id": str(uuid.uuid4()),
                "routineID": routine,
                "trigger": "manual",
                "harness": "antigravity",
                "startedAt": stamp(now - timedelta(minutes=1)),
                "endedAt": stamp(now),
                "outcome": {"failed": {"exitCode": 1}},
                "logPath": str(log),
                "sessionID": "synthetic-native-session",
            }
        ]
    ),
    encoding="utf-8",
)
