"""Write synthetic, disabled routines for the README capture script."""

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import uuid


def write_fixtures(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / "runs").mkdir(exist_ok=True)
    now = datetime.now(timezone.utc).replace(microsecond=0)

    def stamp(value: datetime) -> str:
        return value.isoformat().replace("+00:00", "Z")

    examples = [
        ("daily-review", "Daily code review", "claude", "0 9 * * 1-5",
         "Review recent changes. Summarize findings and suggest the next step.",
         "claude-sonnet-4-6", "high",
         "## Morning review\nReviewed the latest changes in the sample project.\n\n"
         "- **Tests:** all checks passed.\n- **Dependencies:** no updates needed.\n"
         "- **Next step:** review the new export flow before merging.\n\n"
         "The full review is saved in `docs/review.md`."),
        ("weekly-report", "Weekly project report", "codex", "0 16 * * 5",
         "Read the project notes and prepare a short weekly report.",
         "gpt-6-sol", "high",
         "## This week\nThe export flow is ready for review. Documentation and tests are up to date.\n\n"
         "Which format should the report use?"),
        ("docs-check", "Documentation check", "grok", "30 10 * * 1-5",
         "Check the documentation against the current code and report stale references.",
         None, None, "Documentation matches the current code. No stale references found."),
        ("release-notes", "Draft release notes", "antigravity", "0 14 * * 5",
         "Summarize the changes since the last release for users.",
         None, None, "Release notes are ready in `docs/release-notes.md`."),
        ("local-backup", "Local backup", "shell", "0 18 * * *",
         "./scripts/backup.sh", None, None, "Backup complete. Archive verified."),
    ]
    routines = []
    for index, (key, name, harness, schedule, prompt, model, effort, reply) in enumerate(examples):
        routine = dict(id=key, name=name, workingDirectory="/tmp/rota-demo-project",
                       schedule=schedule, harness=harness, enabled=False, prompt=prompt)
        if model:
            routine["model"] = model
        if effort:
            routine["effort"] = effort
        routines.append(routine)
        log = root / "Logs" / key / "example.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(f"[you] {prompt}\n{reply}\n", encoding="utf-8")
        ended = now - timedelta(minutes=5 + index * 25)
        record = dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL, "rota-demo/" + key)).upper(),
                      routineID=key, trigger="scheduled", harness=harness,
                      startedAt=stamp(ended - timedelta(seconds=83 + index * 12)),
                      endedAt=stamp(ended), outcome={"succeeded": {}}, logPath=str(log))
        if harness != "shell":
            # Synthetic IDs only enable the normal composer; the capture never sends.
            record["sessionID"] = "rota-demo-" + key
        if model:
            record["reportedModel"] = model
        if effort:
            record["reportedEffort"] = effort
        if key == "weekly-report":
            record["attention"] = "Choose a format for the weekly report."
            record["questions"] = [dict(
                id="report-format", title="Choose the report format", detail="",
                replyViaMessage=True, allowsDecline=False,
                actions=[dict(id="accept", label="Send Answer", detail="")],
                fields=[dict(id="format", title="How should the weekly report be prepared?",
                             detail="", kind="choice", required=True, allowsOther=True,
                             options=[dict(id=value, label=label, detail="") for value, label in
                                      [("short", "Short summary (Recommended)"),
                                       ("detailed", "Detailed report with links")]])])]
        (root / "runs" / f"{key}.json").write_text(json.dumps([record]))
    (root / "routines.json").write_text(json.dumps(routines))


if __name__ == "__main__":
    write_fixtures(Path(sys.argv[1]))
