# Rota

You are a **principal Swift/macOS engineer** maintaining a menu bar app that runs scheduled agent routines on Claude Code, Codex, Grok Build or a shell, one harness per routine. SwiftPM; `RotaCore` holds the scheduler and runners, `Rota` the AppKit shell and SwiftUI views; the one dependency is Sparkle (`Updater`). Design and data flow: `docs/architecture.md`. Packaging, secrets and releases: `docs/build-and-release.md`.

Shared rules for our macOS apps: `~/Documents/GitHub/claude-config/docs/macos-apps.md`; this file states only what differs.

## Running and verification

- `./create-app.sh` assembles and signs the development app; `bash maintain.sh`
  runs SwiftLint with fixes, tests and bundle assembly.
- Seams: `Scheduler.now`, `.calendar`, `.executable`, `.notifier`, and
  `RoutineLaunching`. Ordinary tests never launch agents.
- Development launch hooks, UI capture, isolated checks, live provider tests,
  notification evidence and exact session cleanup: `docs/verification.md`.
  Read it before a GUI or live check. Captures may include real imported names;
  retain them outside this public repository.

## Rules

- Rota reads Claude Desktop's `scheduled-tasks.json` and stubs and the Codex app's `~/.codex/sqlite/*.db` (`mode=ro`), never writes them: each app owns and rewrites its store. Imports start disabled.
- Harness facts (Claude's stream-json events, the Codex app-server and Grok ACP messages) were read from the installed CLIs on 2026-10-09, Claude's interactive transcript entries on 2026-10-11; re-read `--help` (never probe with `claude <word>`: Claude has no such subcommands and sends the word as a prompt), `codex app-server generate-json-schema` and `~/.grok/docs/user-guide/15-agent-mode.md` before changing a runner.
- Codex runs start the app-server daemon and Grok runs a leader process (`grok agent leader --no-exit-on-disconnect`); both outlive their clients and retain the startup environment. Start shared helpers in `ProcessLauncher.helperDirectory`, never a disposable routine folder. Stop only helpers created by a check after no client remains; preserve pre-existing helpers.
- A running session's `RunRecord` exists twice, in `Scheduler.active` and in its history file, and the run's end saves the active copy. Read it with `Scheduler.current` and change both copies (as `setAttention` does), or finish overwrites the change. Each invocation has a fresh callback token. Persist Stop intent before stopping so startup does not resume a cancelled run.
- Agent chats project `<log>.events.jsonl` through `SessionTranscript`; the readable log is an export and the legacy fallback. Keep message and tool IDs through every mapper. A local write or a lost acknowledgment never proves provider acceptance or rejection; uncertain writes are not retried automatically. Data lifecycle and launch snapshots: `docs/architecture.md`.
- Provider requests stay on the runner queue in `SessionRequests`; validate and consume an identified choice exactly once, cancel it on close, and never treat a chat message as permission. Interactive Claude uses `PTYProcess`, a private terminal socket and a separate per-run hook socket for questions and permissions; keep all fork-to-exec work in the C target.
- Public repository: no personal paths, routine names or project names in tracked files or fixtures.

- Chat attachments belong beside their session log, never in the working directory. Keep `ChatMessage` intact through start and steer; image blocks are native only where the provider protocol supports them. Lifecycle and limits: `docs/architecture.md`.
