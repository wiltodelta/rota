"""Synthetic routines, sessions and a skipped slot for the Schedule UI checks."""

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import uuid


def stamp(value: datetime) -> str:
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def main() -> None:
    root = Path(sys.argv[1])
    project = sys.argv[2]
    (root / "runs").mkdir(parents=True, exist_ok=True)
    (root / "Logs" / "calendar-digest").mkdir(parents=True, exist_ok=True)
    (root / "Logs" / "calendar-review").mkdir(parents=True, exist_ok=True)

    digest_log = root / "Logs" / "calendar-digest" / "digest.log"
    digest_log.write_text(
        "[you] Summarize overnight changes.\nAll checks green across three repositories.\n",
        encoding="utf-8",
    )
    review_log = root / "Logs" / "calendar-review" / "review.log"
    review_log.write_text(
        "[you] Review release notes.\nDrafted notes; waiting on approval.\n",
        encoding="utf-8",
    )

    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    future_floor = now + timedelta(minutes=25)
    once_fire = (now + timedelta(hours=3)).replace(minute=30)
    review_id = str(uuid.uuid4()).upper()
    digest_id = str(uuid.uuid4()).upper()
    skip_id = str(uuid.uuid4()).upper()

    (root / "routines.json").write_text(
        json.dumps([
            {
                "id": "calendar-digest",
                "name": "Morning digest",
                "harness": "codex",
                "enabled": True,
                "schedule": "0 9,16 * * *",
                "scheduledAt": stamp(future_floor),
                "nextFire": stamp(now + timedelta(hours=4)),
                "workingDirectory": project,
                "prompt": "Summarize overnight changes.",
            },
            {
                "id": "calendar-review",
                "name": "Code review",
                "harness": "claude",
                "enabled": True,
                "schedule": "30 11 * * 1-5",
                "scheduledAt": stamp(future_floor),
                "nextFire": stamp(now + timedelta(hours=5)),
                "workingDirectory": project,
                "prompt": "Review open pull requests.",
            },
            {
                "id": "calendar-pulse",
                "name": "Health pulse",
                "harness": "antigravity",
                "enabled": True,
                "schedule": "*/15 * * * *",
                "scheduledAt": stamp(future_floor),
                "nextFire": stamp(now + timedelta(minutes=30)),
                "workingDirectory": project,
                "prompt": "Check service health.",
            },
            {
                "id": "calendar-once",
                "name": "Release cut",
                "harness": "shell",
                "enabled": True,
                "schedule": "30 14 * * *",
                "repeats": False,
                "scheduledAt": stamp(once_fire),
                "nextFire": stamp(once_fire),
                "workingDirectory": project,
                "prompt": "echo release",
            },
            {
                "id": "calendar-paused",
                "name": "Paused audit",
                "harness": "grok",
                "enabled": False,
                "schedule": "0 14 * * *",
                "workingDirectory": project,
                "prompt": "Run weekly audit.",
            },
        ]),
        encoding="utf-8",
    )
    (root / "runs" / "calendar-digest.json").write_text(
        json.dumps([{
            "id": digest_id,
            "routineID": "calendar-digest",
            "trigger": "scheduled",
            "harness": "codex",
            "startedAt": stamp(now - timedelta(hours=2)),
            "endedAt": stamp(now - timedelta(hours=1, minutes=58)),
            "outcome": {"succeeded": {}},
            "logPath": str(digest_log),
            "sessionID": "synthetic-calendar-digest",
        }, {
            # Sessions hide skipped slots; the Schedule shows them.
            "id": skip_id,
            "routineID": "calendar-digest",
            "trigger": "scheduled",
            "harness": "codex",
            "startedAt": stamp(now - timedelta(minutes=30)),
            "endedAt": stamp(now - timedelta(minutes=30)),
            "outcome": {"skipped": {"_0": "Mac was asleep"}},
        }]),
        encoding="utf-8",
    )
    (root / "runs" / "calendar-review.json").write_text(
        json.dumps([{
            "id": review_id,
            "routineID": "calendar-review",
            "trigger": "scheduled",
            "harness": "claude",
            "startedAt": stamp(now - timedelta(minutes=45)),
            "endedAt": stamp(now - timedelta(minutes=43)),
            "outcome": {"succeeded": {}},
            "attention": "Approve release notes?",
            "logPath": str(review_log),
            "sessionID": "synthetic-calendar-review",
        }]),
        encoding="utf-8",
    )
    (root / "calendar-ids.txt").write_text(
        f"{review_id} {int(once_fire.timestamp())} {skip_id}\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
