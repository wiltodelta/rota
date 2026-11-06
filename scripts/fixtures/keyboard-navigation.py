"""Disabled synthetic conversations and one manually run Shell keyboard probe."""

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
routine = "keyboard-conversations"
records = []
ids = {}
for index, name in enumerate(("alpha", "beta", "gamma", "delta", "epsilon")):
    started = now - timedelta(minutes=index + 2)
    if index >= 2:
        started -= timedelta(days=1)
    ended = started + timedelta(seconds=1)
    log = root / "Logs" / (name + ".log")
    log.write_text("Synthetic keyboard transcript.\n", encoding="utf-8")
    size = log.stat().st_size
    rows = [
        {"version": 1, "type": "header", "logSize": size},
        {
            "version": 1,
            "type": "item",
            "logSize": size,
            "id": 0,
            "kind": "agent",
            "text": "Keyboard sample " + name,
            "complete": True,
        },
    ]
    Path(str(log) + ".chat.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
    )
    ids[name] = str(uuid.uuid4()).upper()
    record = {
        "id": ids[name],
        "routineID": routine,
        "trigger": "manual",
        "harness": "antigravity",
        "startedAt": started.isoformat(),
        "endedAt": ended.isoformat(),
        "outcome": {"failed": {"exitCode": 1}}
        if name == "gamma"
        else {"succeeded": {}},
        "logPath": str(log),
        "sessionID": "synthetic-keyboard-" + name,
    }
    if name not in {"delta", "epsilon"}:
        record["readAt"] = ended.isoformat()
    if name == "beta":
        record["attention"] = "Synthetic reply requested."
    records.append(record)
(root / "runs" / (routine + ".json")).write_text(json.dumps(records), encoding="utf-8")
(root / "runs/keyboard-running.json").write_text("[]", encoding="utf-8")
(root / "keyboard-ids.json").write_text(json.dumps(ids), encoding="utf-8")
(root / "routines.json").write_text(
    json.dumps(
        [
            {
                "id": routine,
                "name": "Keyboard conversations",
                "harness": "antigravity",
                "enabled": False,
                "schedule": "0 9 * * *",
                "workingDirectory": str(project),
                "prompt": "Read the synthetic report.",
            },
            {
                "id": "keyboard-running",
                "name": "Keyboard running",
                "harness": "shell",
                "enabled": False,
                "schedule": "0 9 * * *",
                "workingDirectory": str(project),
                "prompt": "printf 'Keyboard running sample\\n'; sleep 240",
            },
        ]
    ),
    encoding="utf-8",
)
