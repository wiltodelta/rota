#!/usr/bin/python3
"""Synthetic MCP identity server. It never contacts a service or changes an agent configuration."""

import json
import os
import sys


def respond(request):
    """Use the same line framing as the real Rota MCP server."""
    method = request.get("method")
    if method == "initialize":
        return {
            "protocolVersion": request.get("params", {}).get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "synthetic-rota-identity", "version": "1"},
        }
    if method == "tools/list":
        return {"tools": [{"name": "identity", "description": "Return this synthetic session's identity token.",
                           "inputSchema": {"type": "object", "properties": {}}}]}
    if method == "tools/call":
        token = os.environ.get("ROTA_SESSION", "missing-session")
        audit = os.environ.get("ROTA_BRIDGE_AUDIT")
        if audit:
            with open(audit, "a", encoding="utf-8") as output:
                output.write(json.dumps({"request": request, "session": token}) + "\n")
        return {"content": [{"type": "text", "text": token}]}
    return {}


for incoming in sys.stdin:
    payload = json.loads(incoming)
    if "id" in payload:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": payload["id"], "result": respond(payload)}) + "\n")
        sys.stdout.flush()
