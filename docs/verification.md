# Verification

## Running and capture hooks

- `./create-app.sh` builds and signs `Rota.app` with the team's Developer ID (ad hoc without it). The app icon (`App Icon.icon`) and the menu bar template images (`MenuIcons.xcassets`) are drawn by `scripts/draw-icon.py`, `icon.json` included; edit the script and rerun it, never its output. To look at the built icon, render `NSWorkspace.shared.icon(forFile: "Rota.app")` to a PNG; `qlmanage -t Rota.app` hung for ten minutes here. Quit a running copy first: the app quits on launch if another instance with its bundle id runs.
- The status item often sits in a menu bar manager's hidden section on this Mac, so a scripted click does not open the panel. Development hooks: `open --env ROTA_OPEN_PANEL=1 Rota.app` shows the panel at the top of the main screen and logs its window number (`category == "app"`) for `screencapture -l`; `--env ROTA_APPEARANCE=dark|light` renders one appearance without touching the system setting; `--env ROTA_OPEN_EDIT=1` opens the edit sheet of the routine shown; `--env ROTA_OPEN_SETTINGS=1` opens Settings. System Events clicks and keystrokes did not reach the window here; drive it with `scripts/ui-driver.swift` (AX actions, and `key`, which posts a key event to Rota's pid and does reach it) and use these hooks to capture. Opening the app a second time shows the main window.
- The app logs at `.info` under `com.wiltodelta.rota`; watch live with `/usr/bin/log stream --info --predicate 'subsystem == "com.wiltodelta.rota"'`.

## Tests and live checks

- `bash maintain.sh` is the gate. A JSON-RPC peer delivers replies on its run's queue (`callbackQueue`); a JSON value handed across queues goes in `UncheckedSendable`.
- `python3 -m unittest discover -s Tests/AuditPreferences -p '*Tests.py'` verifies audit preference cleanup through macOS's real `defaults` tool and the shell checks' actual EXIT handlers. Each test owns a unique development domain; CI runs this check too. The UI, CLI/MCP and capability checks use `scripts/restore-defaults.py` to clear audit additions, restore the exact snapshot and verify it. Cleanup failure makes the check fail and retains the backup. Never restore preferences while the audit app is still running.
- Settings > Browsers checks native connections on demand. `python3 scripts/capability-check.py --live` probes browser and desktop tools through the signed dev app; it spends quota and retains private diagnostics. Commands and evidence rules: `README.md`, "Browser and computer use checks".
- Seams: `Scheduler.now`, `.calendar`, `.executable`, `.notifier`, and the `RoutineLaunching` launcher (`FakeLauncher` in `SchedulerTests` drives `RunEvents` by hand). Ordinary tests never spawn an agent; the opt-in live suites do.
- `ROTA_LIVE=1 swift test --filter LiveHarnessTests` runs Claude Code, Codex, Grok Build and Shell for real, sends a message mid-run, continues finished sessions, stops each harness, runs each agent on a chosen model and prints each log. It spends quota and leaves provider sessions behind. Set `ROTA_HOOK_LIVE_MANIFEST` to record exact IDs and source folders; verify each against its provider registry before removing only that check's sessions. Delete Codex threads with `thread/delete` over app-server stdio, never by editing SQLite. A recently stopped thread may retain an active writer; retry after it closes. Run it after touching a runner, in the background with a log: one combined run hung past ten minutes once and did not again.
- `scripts/ui-check.sh` (add `--live` for a Codex session) is the end-to-end UI check: it drives the built app through the Accessibility API, checks each step, runs the layout gate on every capture, and saves both appearances at the minimum width to `/tmp/rota-ui-check` (empty, import, new routine with model pickers, running, finished, needs reply, routine, edit, menu bar panel, each settings tab; `--live` adds a running Codex session's composer). It runs the development build (`com.wiltodelta.rota.dev`, a non-`RELEASE` build) on a temporary `ROTA_DATA_DIR` and quits only that build by its path, so the installed Rota keeps running its routines; `scripts/ui-driver.swift` drives the dev bundle id unless `ROTA_BUNDLE_ID` names another. It reads this Mac's Claude Desktop and Codex for the import sheet, so its screenshots carry real routine names: keep them out of the repository. Look at the screenshots; a green run does not say the screen reads well. Never fire a real routine to test the scheduler.
- `scripts/agent-check.sh` (after `./create-app.sh`) checks the `rota` command and `rota mcp` end to end on clean data, and has Claude Code, Codex and Grok Build each create a routine over MCP without touching their own MCP settings (Claude `--mcp-config`, Codex `-c mcp_servers.rota...`, Grok a temporary agent definition with explicit MCP servers). Agent CLIs wait on stdin unless given `</dev/null`. It records provider IDs in its private output directory; verify and delete only those sessions as for live tests. Never test Settings' Add buttons against the real configs from a dev build: they would point the agents at the repository's Rota.app.
- To try an interactive Claude run by hand, start it from a clean environment (`env -i HOME=… PATH=/usr/bin:/bin …`): a `claude` started inside another Claude session inherits `CLAUDE_CODE_CHILD_SESSION`, turns transcript saving off and leaves Rota nothing to read. It needs a folder Claude Code trusts, so it leaves its transcript in that project's `~/.claude/projects` folder: delete it after. Interactive Rota runs now own a PTY; use the bundled `rota attach-terminal <socket>` to inspect it, Ctrl-] to detach.
- `TerminalLauncher` also uses `ProcessLauncher.baseEnvironment` when opening a terminal. Never launch one with the test process's inherited environment: a terminal started inside an agent session passes `CLAUDE_CODE_CHILD_SESSION` to future tabs and disables Claude transcript saving. This cannot repair an already running terminal's environment.
- To check the scheduler live, write Shell routines into `routines.json` with a past or next-minute `nextFire` (catch-up, skip, scheduled slot) and launch the app; back up and remove that data after.
- Notification Center records the path of the first build that posts a notification as the app's source (`apps[…].src` in `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist`) and draws the banner icon from there; a dev build in `~/Documents` (TCC-protected) or a deleted copy leaves every banner with the blank app icon. It is a system setting: report it, never edit it.
- Notification banners are not in the Accessibility tree, so they cannot be pressed from a script; read delivery from `/usr/bin/log show --predicate 'process == "usernoted"'` ("Presenting ... as banner").
- Render UI changes in both appearances and at the 820 pt minimum width; the layout rules that width taught are in `docs/architecture.md`.

## Isolated audit builds

The GUI and agent scripts accept a separately identified signed development
bundle. Use `ROTA_UI_APP`, `ROTA_UI_BUNDLE_ID` and `ROTA_UI_OUT` for UI checks;
`ROTA_AGENT_APP` and `ROTA_AGENT_OUT` for CLI/MCP checks; `--app` for the
capability probe. The bundle ID must end in `.dev`. Checks refuse a running
copy with the same identity, use temporary routine data, back up and restore
that identity's defaults, and quit only the exact app under test.
`ROTA_TEST_DISABLE_NOTIFICATIONS=1` suppresses notification permission requests
and delivery only in development builds. Do not use an installed app's identity
for an audit copy. The UI driver guards composer keystrokes by frontmost app
and focused control; an AX action's error alone is not a failed navigation,
so inspect the resulting state.

The agent check creates disabled routines and reads their saved state back.
Grok receives a temporary agent definition containing the Rota MCP server;
project-scope MCP files in an untrusted temporary folder are not loaded by Grok.
The check must not change the user's provider configuration or folder trust.
Resolve a recorded cwd before looking up Grok's URL-encoded session directory:
`/tmp` and `/private/tmp` can name the same folder while producing different
encoded keys. Verify the session ID and cwd inside its own summary before
removing it; a missing lookup under an unresolved alias is not proof of absence.

Set `ROTA_HOOK_LIVE_MANIFEST` when running live tests to retain exact provider
session IDs and their source folders for cleanup. Keep these manifests and all
raw captures outside the public repository. Delete only the recorded sessions;
never stop a pre-existing shared daemon or leader. A failed capability probe
means the required evidence was not observed, not that a permission or tool
is absent. Do not grant permissions or change provider configuration during a
read-only connection check.

The main window title follows the selected routine. Resolve captures against
its current Accessibility title, not a constant `Rota` title. `open --env`
sets hooks only on a new process; quit the owned audit copy before changing
appearance or startup hooks. Wait for the window and tab animation before
measuring; an empty window walk is not a successful layout check.

Keep `ROTA_DATA_DIR` short, such as a temporary folder under `/tmp`: macOS
limits the local socket pathname. Reject captures covered by a startup alert,
even when their geometry gate reports no violations.

At constrained chat heights, verify the last line's native text bounds after
scrolling to the end. The text view's frame and scrollbar value alone do not
prove that a line is visible; trailing layout space can fill the whole viewport.

For an isolated Sparkle installation check, both fixture bundles must carry
the test data and notification hooks in their own `LSEnvironment` dictionary
before signing. Sparkle relaunches through Launch Services without the initial
`open --env` values. Verify the restarted process's data directory before
continuing. Use a temporary signing seed and local feed, never the production
Sparkle key or the installed application's bundle identity.

The request form intentionally scrolls at constrained sizes. Verify that an
option and a free-text field below the initial viewport can be reached, not
just set through AXValue. `ui-driver.swift scroll <control-id> top|bottom` targets
the owned scroll area and refuses to change it unless Rota is frontmost.
`reveal <control-id>` uses its scroll bar and measured bounds to bring each
control fully into that viewport. AX scroll actions and scrollbar min/max
attributes are not implemented consistently by SwiftUI; verify the resulting
bar value and control frame instead of treating an AX return code as proof.
After a synthetic-provider check, verify the selected executable before a live
probe; a fixture left in the audit identity is not evidence about a real CLI.

Exercise attachment selection through the native file dialog, not only by
injecting draft state. Use synthetic image and text files, check multiple
selection, carousel scrolling, removal, navigation retention and oversized-file
rejection. Capture the populated composer and the complete error at minimum
window size in both appearances. Use chat text at 10, 14 and 28 pt; native controls must keep their size. The history's
scrollbar must keep a usable viewport while the composer shows attachments or
an error. A native CUA app target can drive the file dialog when the project
driver's guarded composer keystrokes cannot; selecting files does not authorize
sending them to a provider.

The toolbar press driver resolves elements that actually support `AXPress`.
A native toolbar item can expose a named wrapper group before its hosted
button, so matching the first label alone can select a non-actionable group.
Verify all five native Settings tabs in both appearances. Compare toolbar,
sidebar, composer controls and attachment frames before and after chat text
resizing; their geometry must stay fixed. Inspect the actual screenshots for
spacing and alignment as well as running the layout gate. The global zoom
experiment was rejected in user review despite passing several geometry checks;
those checks did not establish acceptable visual quality.
