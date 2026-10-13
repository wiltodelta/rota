# Rota

[![Build Rota App](https://github.com/wiltodelta/rota/actions/workflows/build.yml/badge.svg)](https://github.com/wiltodelta/rota/actions/workflows/build.yml)

A macOS menu bar app that runs your agent routines on a schedule, on the
harness you choose for each one: Claude Code, Codex, Grok Build, or a plain
shell command. A routine is a project folder, a cron schedule and a prompt,
usually "invoke this project skill and follow it". Each run is a session you
read as a chat and keep talking to, while it works or after, as in Claude
Desktop.

## Features

- **One scheduler for every harness.** Pick Claude Code, Codex, Grok Build or
  Shell per routine and switch at any time, with the model and reasoning
  effort to run on: Rota lists the models each agent's CLI offers. Standard five-field cron
  schedules, with common ones a click away and the next three run times shown
  as you type.
- **Sessions are the main view.** The sidebar lists every routine's sessions,
  newest first, by day. Messages use a plain layout with speaker labels and
  basic Markdown: paragraphs, lists, links and code. Select any number of lines,
  across paragraphs and messages, and copy with Command-C. Tool activity can
  be shown or hidden, and plans show each step's status as text. The rounded
  message field shows the model and run clock, with Send and Stop controls.
  The chat follows the session unless you scroll up or select text.
- **Attach files and images.** Use the paperclip or drop files onto the composer.
  Image previews and file names stay with the message; a message can contain only
  attachments. Up to 10 files, 20 MB each and 50 MB total. Rota copies attachments
  into the session's log storage. Claude print mode and Codex receive PNG, JPEG,
  GIF and WebP as image inputs. Grok receives native images on a new turn when
  its ACP capabilities allow them; live steering and interactive Claude receive
  local file references. Other files are passed as local references for the
  agent's tools to read, under its existing permissions.
- **Keep talking to a session, on every agent, while it works or after.** The
  field under the chat sends your message:
  - Claude Code runs interactively, as in a terminal, inside a detached
    PTY owned by Rota: it gets computer use where you turned it on, a message
    is typed in and joins the current turn, and **Open in Terminal** shows the
    live session. Afterwards the session continues with `--resume`. A folder
    Claude Code has not been trusted in, or Settings > Agents with the switch
    off, runs `claude -p` with stream-json instead. Computer use acts as Rota,
    so Settings asks macOS to allow Rota Accessibility and Screen Recording.
  - Codex runs on its local app-server daemon: a message joins the current
    turn (`turn/steer`). Afterwards the thread continues (`thread/resume`).
  - Grok Build runs through its shared leader: a text message can interject
    into the current turn. Afterwards the session is loaded and continued.
  - Shell commands run in a detached `screen` session; **Open in Terminal**
    attaches with `screen -r`, where you can type into the command or stop it.
  Messages show whether they are being sent, accepted, queued, rejected, or
  unconfirmed. A rejected message can be restored to the composer. Streamed
  responses and tool results appear as they arrive; each response keeps its
  reported model, and editing a routine preserves its existing sessions' launch
  settings.
  A continued session runs again and appends to the same chat. Finished agent
  sessions also open in their own CLI with **Continue in Terminal**. Sessions
  open in the terminal app picked in Settings (Terminal, iTerm2, Ghostty or
  any other), or in the macOS default terminal, the one that opens executables
  (iTerm2 after "Make iTerm2 Default Term"). iTerm2 asks "OK to run" before
  each script until you tick "Suppress this message permanently" once. The last
  50 sessions of each routine are kept.
- **Agents manage routines.** A Claude Code, Codex or Grok Build session can
  schedule a routine ("run this every weekday at 9"), change, run, pause or
  delete one, and read or message its sessions, through Rota's MCP server.
  Turn it on per agent in Settings > Integrations > Routines from agents. A routine an agent
  adds runs on its schedule and Rota notifies you. The same works from a
  terminal with the `rota` command: `rota list`, `rota add`, `rota run`,
  `rota log`, `rota help`.
- **Routines can ask you.** A routine (or its skill) runs
  `"$ROTA_CLI" notify "…"`, or an agent calls the `notify_user` tool, and Rota
  shows a Mac notification from that session. With `--needs-reply` the session
  is marked "Needs your reply" in the list, the menu bar and the Dock until you
  answer in its chat, from the notification's Reply field, or dismiss it. Click
  the notification to open the session. This replaces phone push for routines
  on every agent.
- **An inbox.** A session that finished since you last opened it is unread:
  bold in the list with a blue dot, counted on the Dock icon and in the menu
  bar panel.
- **Readable chat text.** Pick the chat's font, a monospaced font for commands
  and output, and the size in Settings; View > Bigger, Smaller and Actual Size
  (Command-Plus, Command-Minus, Command-0) change the size as you read.
- **Agent Markdown as it is meant to read:** headings, lists and code blocks.
- **Notifications** when a run fails, times out or cannot start, and when a
  missed slot is skipped; click one to open its session. Successes notify too if you ask for it. A routine
  whose last five scheduled runs failed pauses itself and says so.
- **Choose the agent.** Rota passes the routine to the selected harness. The
  agent resolves the skill's tool requirements during the run.
- **Import from Claude Desktop and Codex.** Reads the routines Claude Desktop
  schedules and the automations of the Codex app (read-only), with their
  schedules in words, and copies the ones you pick, turned off, so nothing runs
  twice. Codex automations keep their model and reasoning effort. Grok Build
  has no saved schedules to import: its `/loop` tasks live in one session.
- **Safe defaults, as in Claude Desktop.** Slots missed while the Mac slept or
  Rota was closed run once, late, marked as a catch-up, if the last one is
  under seven days old; older ones are recorded as skipped. A slot that arrives
  while the previous run is still going is skipped quietly. Skips stay in the
  routine's history, out of the sessions list. A run takes as long as it
  needs; a routine can set a time limit if it should not.
- **Sleep, shutdown and lost Wi-Fi do not lose work.** A due slot waits for
  the network rather than failing on a Mac that just woke. An agent run cut
  off by sleep or a network error, or still open when the Mac shut down,
  simply continues in the same session once its agent's service answers again
  (twice at most per run); one that failed on the network before it started
  working runs again. A shutdown quits Rota without
  asking. Shell commands are never run again on their own.

## Requirements

- macOS 15 (Sequoia) or later, on Apple silicon. On macOS 26 (Tahoe) the menu
  bar panel uses Liquid Glass.
- The CLIs you want to use, installed and signed in: `claude`, `codex`,
  `grok`. Rota finds them on your login shell's PATH and in the usual install
  folders; Settings lists every copy it found with its version, and Choose
  Other picks any file.
- For building from source: Xcode 26 or later.

## Install

### From a release

1. Download the latest `Rota-vX.Y.Z-macOS.zip` from the
   [Releases](https://github.com/wiltodelta/rota/releases) page.
2. Unzip it and move **Rota.app** to `/Applications`.
3. Launch it. A dial-and-play icon appears in the menu bar (a solid disc while a
   routine runs); the window opens on the first launch.

### From source

```bash
git clone https://github.com/wiltodelta/rota.git
cd rota
./create-app.sh
mv Rota.app /Applications/
```

## Usage

- **Add a routine** with **+**: the project folder, the skill it runs (the
  prompt defaults to "invoke the `<skill>` skill and follow it"), a schedule,
  the harness, and the model it runs on. A run takes as long as it needs
  unless you turn on a time limit. A Shell routine takes a command instead of a
  prompt and runs it with `zsh -c` in the project folder.
- **Import** with the download button: pick routines from Claude Desktop or
  Codex. Turn each one off in its app before turning it on in Rota.
- Select a session to read it and write to it. Under **Routines**, a routine
  shows its schedule and next run, the switch that pauses it, **Run Now** and its
  sessions; **Edit…** opens its settings, Delete included. A new routine runs
  on its schedule from the start.
- The sidebar folds away with the button beside the title, View > Hide
  Sidebar or Control-Command-S, and stays as you left it.
- Menus: File > New Routine… (Command-N) and Import Routines…;
  Routine > Run Now (Command-R), Stop (Command-.) and Edit Routine…
  (Command-E), acting on the selected routine or the selected session's.
- The menu bar panel lists every routine with its next run; hover a row to run
  or stop it (VoiceOver offers both as actions), click it to open its latest session. Right-click the icon for Settings,
  updates and Quit.
- If the icon is hidden (behind the notch, or by a menu bar manager), open
  Rota again from Finder or Spotlight to get its window.

Sessions use the selected harness's own configuration for permissions, sandbox,
MCP servers, plugins and skills. Rota does not enable bypass or auto-approval.
Default model and effort use the harness settings; an explicit choice in a
routine overrides those values. Configure the harness for the routine's needs.
Codex, Grok and both Claude modes show supported permission requests and
questions in the chat. Interactive Claude bridges `AskUserQuestion` and one-time
permissions through its own per-session hooks while keeping its PTY. Native
prompts outside those hooks remain available in Terminal.
Closing or stopping a run invalidates its pending requests; chat text never
approves a tool. Ctrl-] detaches from an interactive Claude terminal without
stopping its session.

Rota runs routines only while it is open; turn on **Launch at login** in
Settings, so runs cut off by a shutdown continue after the Mac starts.
Quitting Rota yourself while routines run asks first and stops them; their
sessions can be continued later.

## Updates

Rota uses [Sparkle](https://sparkle-project.org) (MIT licensed; its notice
ships in the app bundle) to check for a new release once a day. It does not
take focus while you work: a found update appears in the panel, and the update
window opens when you choose it or check from Settings.

## Building and releasing

- `./create-app.sh` builds and signs `Rota.app` (Developer ID when the
  maintainer's identity is in the keychain, ad hoc otherwise).
- `RELEASE=1 ./create-app.sh && ./notarize.sh` notarizes and zips a release.
- `bash maintain.sh` runs SwiftLint, the tests and `create-app.sh`.
- `scripts/ui-check.sh` drives the built app through the Accessibility API
  (`scripts/ui-driver.swift`): it makes and runs a routine in both appearances
  at the minimum window size, checks each step and saves screenshots; `--live`
  also messages a running Codex session. It runs the development build on its
  own data folder, beside an installed Rota it never touches.

Pushing an annotated `vX.Y.Z` tag builds, notarizes and publishes a release
with the Sparkle appcast. Details: [`docs/build-and-release.md`](docs/build-and-release.md).

### Browser and computer use checks

Settings > Browsers checks Chrome and native Browser Use separately for each
agent. Choose the project folder and click **Check Connection**. The check uses
the CLI selected in Agents and the harness's existing settings. It reads browser
inventories, with a two-minute limit, without changing permissions, accounts or
tabs. It uses a short agent session and may spend quota. Results show the last
check time for this app session; changing the folder or CLI invalidates them.
A successful native tool result confirms the connection. **Not confirmed** is
not proof that a tool is absent. **Open Check Log** provides the tool errors.
External and isolated Playwright results do not confirm a native connection.


After `./create-app.sh`, run `python3 scripts/capability-check.py --live` to probe
Claude Code, Codex and Grok Build serially through the signed development app.
It spends quota and requires the development app to be closed first. Use
`--harness codex` to select one provider, or `--folder /path/to/trusted/project`
to use that project's existing configuration. It preserves harness defaults and
never grants permissions or changes tool settings.

The browser probe reads a fresh DOM challenge on a loopback page. The computer
probe requires an image returned by a native desktop tool; a browser screenshot
does not count. A provider's success message or a successful process exit is
insufficient. Missing evidence remains `unverified`, with the provider's own
blocker reported separately. Exit 1 means at least one capability was not proven.
Private journals, a JSON report and provider session IDs are retained in the
reported temporary directory for diagnosis; screenshots can contain private
content. The check closes only its own app process and asks agents to close
only their own tabs. Shared provider daemons remain running.

Test the evidence checker without starting agents:
`python3 -m unittest discover -s scripts/tests -v`.

## Uninstall

Quit Rota from the panel, move **Rota.app** to the Trash, and remove its data:

```bash
defaults delete com.wiltodelta.rota
rm -rf ~/Library/Application\ Support/Rota ~/Library/Logs/Rota ~/Library/Caches/Rota
```

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
