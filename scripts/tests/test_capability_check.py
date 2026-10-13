"""Deterministic evidence checks; no agents, browser, desktop or network calls."""

import base64
import importlib.util
import json
import struct
import unittest
import zlib
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "capability_check", Path(__file__).parents[1] / "capability-check.py"
)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def event(turn, **patch):
    return {"turnID": turn, "payload": {"tool": patch}}


class CapabilityEvidenceTests(unittest.TestCase):
    def test_streamed_reports_are_reconstructed_without_duplicate_snapshots(self):
        events = [
            {"turnID": "one", "payload": {"delta": {"id": "reply", "text": "blo"}}},
            {"turnID": "one", "payload": {"delta": {"id": "reply", "text": "cked"}}},
            {
                "turnID": "one",
                "payload": {"assistant": {"id": "reply", "text": "blocked"}},
            },
        ]
        self.assertEqual(check.assistant_reports(events), ["blocked"])
        self.assertEqual(
            check.inspect(events, "nonce")["browser"]["status"], "unverified"
        )

    def test_browser_requires_real_tool_result_not_prompt_or_final_answer(self):
        token = "fresh-browser-value"
        events = [
            event(
                "one",
                id="browser",
                title="browser_evaluate",
                input=token,
                status="running",
            ),
            {"turnID": "one", "payload": {"assistant": {"text": token}}},
            event(
                "one",
                id="shell",
                title="exec_command",
                output=token,
                status="completed",
            ),
        ]
        self.assertEqual(
            check.inspect(events, token)["browser"]["status"], "unverified"
        )
        events.append(
            event("one", id="browser", title="", output=token, status="completed")
        )
        self.assertEqual(check.inspect(events, token)["browser"]["status"], "passed")

    def test_failure_and_reused_id_in_another_turn_cannot_borrow_browser_identity(self):
        events = [
            event(
                "one",
                id="same",
                title="browser_evaluate",
                output="nonce",
                status="failed",
            ),
            event(
                "two",
                id="same",
                title="exec_command",
                output="nonce",
                status="completed",
            ),
        ]
        self.assertEqual(
            check.inspect(events, "nonce")["browser"]["status"], "unverified"
        )
        self.assertEqual(len(check.tools_from_events(events)), 2)

    def test_computer_requires_native_image_not_path_text_or_browser_screenshot(self):
        def chunk(kind, value):
            return (
                struct.pack(">I", len(value))
                + kind
                + value
                + struct.pack(">I", zlib.crc32(kind + value))
            )

        raw = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\x00\xff\xff\xff"))
            + chunk(b"IEND", b"")
        )
        png = base64.b64encode(raw).decode()
        image = {"type": "image", "source": {"data": png}}
        output = json.dumps([image])
        events = [
            event(
                "one",
                id="browser",
                title="mcp__claude-in-chrome__computer",
                output=output,
                status="completed",
            ),
            event(
                "one",
                id="native",
                title="computer",
                output="screenshot.png",
                status="completed",
            ),
        ]
        self.assertEqual(
            check.inspect(events, "nonce")["computer"]["status"], "unverified"
        )
        events.append(
            event("one", id="native", title="", output=output, status="completed")
        )
        self.assertEqual(check.inspect(events, "nonce")["computer"]["status"], "passed")
        image["source"]["data"] = base64.b64encode(b"not an image").decode()
        events[-1]["payload"]["tool"]["output"] = json.dumps([image])
        self.assertEqual(
            check.inspect(events, "nonce")["computer"]["status"], "unverified"
        )

    def test_codex_native_surface_metadata_survives_short_tool_name(self):
        def chunk(kind, value):
            return (
                struct.pack(">I", len(value))
                + kind
                + value
                + struct.pack(">I", zlib.crc32(kind + value))
            )

        raw = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\x00\xff\xff\xff"))
            + chunk(b"IEND", b"")
        )
        output = {
            "_meta": {
                "codex/toolSurface": {
                    "kind": "computerUse",
                    "app": {"appId": "com.apple.calculator"},
                }
            },
            "content": [{"type": "image", "data": base64.b64encode(raw).decode()}],
        }
        events = [
            event(
                "one",
                id="native",
                title="js",
                input="await calculator.getScreenshot();",
                output=json.dumps(output),
                status="completed",
            )
        ]
        self.assertEqual(check.inspect(events, "nonce")["computer"]["status"], "passed")
        output["_meta"]["codex/toolSurface"] = {
            "kind": "computerUse",
            "browser": {"tabId": "x"},
        }
        events[0]["payload"]["tool"]["output"] = json.dumps(output)
        self.assertEqual(
            check.inspect(events, "nonce")["computer"]["status"], "unverified"
        )

    def test_cua_requires_native_app_scope(self):
        tools = [
            event(
                "one",
                id="cua",
                title="mcp__cua_repl__js",
                input="await cua.getTab('x')",
                output='[{"type":"image","data":"bad"}]',
                status="completed",
            )
        ]
        self.assertEqual(
            check.inspect(tools, "nonce")["computer"]["status"], "unverified"
        )


if __name__ == "__main__":
    unittest.main()
