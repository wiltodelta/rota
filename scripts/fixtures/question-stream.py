#!/usr/bin/env python3
"""Synthetic Claude stream for isolated question/composer UI checks. No model calls."""

import json
import sys
import uuid


def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


if "--version" in sys.argv:
    sys.stdout.write("Synthetic question stream 1\n")
    sys.exit(0)
if "--help" in sys.argv:
    sys.exit(0)

emit({"type": "system", "subtype": "init", "session_id": "synthetic-question-session", "model": "synthetic-model"})
for line in sys.stdin:
    event = json.loads(line)
    if event.get("type") == "control_request":
        emit({"type": "control_response", "response": {
            "subtype": "success", "request_id": event["request_id"],
            "response": {"applied": {"model": "synthetic-model", "effort": "low"}},
        }})
    elif event.get("type") == "user":
        text = "\n".join(block.get("text", "") for block in event["message"]["content"])
        emit({"type": "assistant", "message": {"id": str(uuid.uuid4()), "role": "assistant",
              "content": [{"type": "text", "text": "Received: " + text}]}})
