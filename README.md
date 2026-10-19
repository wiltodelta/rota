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
- **Sessions are the main view.** Routines stay at the top of the sidebar.
  Below them, the sidebar lists every routine's sessions,
  newest first, by day. A session reads as a chat laid out like
  super.engineering's: your prompt and messages in bubbles, agent messages
  under the agent's own logo and model, basic tool activity, optional plans,
  and one completion line with the time, result, and duration. New sessions keep messages and
  actions in their recorded order. Older sessions retain their folded
  "Worked for …" sections. While a session works, the field shows the clock
  and turns its button into Stop. Its footer shows the session model and reasoning
  effort as resolved by the CLI. Model choices include their versions, and
  unsupported or unavailable effort is labeled explicitly. Attach
  files with the paperclip or by dropping them into the composer. Rota keeps
  copies with the session and sends their local paths for the agent to read;
  originals stay untouched. The chat follows the session unless you
  scroll up. Adjacent tool calls stay collapsed behind a count; expand them
  to read the full commands. Code blocks name their language and copy in one click.
- **Keep talking to a session, on every agent, while it works or after.** The
  field under the chat sends your message:
  - Claude Code runs interactively, as in a terminal, inside a detached
    `screen` session: it gets computer use where you turned it on, a message
    is typed in and joins the current turn, and **Open in Terminal** shows the
    live session. Afterwards the session continues with `--resume`. A folder
    Claude Code has not been trusted in, or Settings > Agents with the switch
    off, runs `claude -p` with stream-json instead. Computer use acts as Rota,
    so Settings asks macOS to allow Rota Accessibility and Screen Recording.
  - Codex runs on its local app-server daemon: a message joins the current
    turn (`turn/steer`). Afterwards the thread continues (`thread/resume`).
  - Grok Build runs through its shared leader: a message is answered right
    after the current turn. Afterwards the session is loaded and continued.
  - Shell commands run in a detached `screen` session; **Open in Terminal**
    attaches with `screen -r`, where you can type into the command or stop it.
  A continued session runs again and appends to the same chat. Finished agent
  sessions also open in their own CLI with **Continue in Terminal**. Rota follows
  that continuation: new messages and tool calls appear in the same chat and
  session preview, with **Working in Terminal** or **Waiting in Terminal** as
  the turn progresses. Type replies and approve actions in Terminal; Rota's
  composer returns after the CLI exits. Closing the terminal window detaches;
  **Open in Terminal** reconnects, and **Stop** ends the owned session. Terminal
  continuations have no routine time limit and are not automatically resumed
  after an interruption. Rota must stay open for synchronization. Sessions
  open in the terminal app picked in Settings (Terminal, iTerm2, Ghostty or
  any other), or in the macOS default terminal, the one that opens executables
  (iTerm2 after "Make iTerm2 Default Term"). iTerm2 asks "OK to run" before
  each script until you tick "Suppress this message permanently" once. The last
  50 finished sessions of each routine are kept. Running sessions are protected;
  skipped slots have a separate history limit and never displace sessions.
  Each routine's session list shows the last reply or command output beside
  its date, agent, duration and status. Pending questions take precedence over
  earlier replies, and failures show their recorded reason.
  Delete a finished session and its local logs with the trash button or
  **Delete Session…** in its context menu. Confirmation is required; the
  routine and the agent's own history stay unchanged.
- **Agents manage routines.** A Claude Code, Codex or Grok Build session can
  schedule a routine ("run this every weekday at 9"), change, run, pause or
  delete one, and read or message its sessions, through Rota's MCP server.
  Turn it on per agent in Settings > Routines from agents. A routine an agent
  adds runs on its schedule and Rota notifies you. The same works from a
  terminal with the `rota` command: `rota list`, `rota add`, `rota run`,
  `rota log`, `rota help`.
- **Answer agents in Rota.** Native questions from Claude Code, Codex and
  Grok Build appear in the session with their options or input fields. The
  session stays marked as needing your reply until you send an answer or
  explicitly decline/cancel the request. Multiple selections, private input,
  plan approvals and standard MCP forms/URL requests use the same flow.
- **Routines can notify you.** A routine (or its skill) runs
  `"$ROTA_CLI" notify "…"`, or an agent calls the `notify_user` tool, and Rota
  shows a Mac notification from that session. With `--needs-reply` the session
  is marked "Needs your reply" until you answer in its chat, from the notification's
  Reply field, or dismiss it. Shell sessions say "Needs your attention" and offer
  dismissal instead of Reply. Click
  the notification to open the session. This replaces phone push for routines
  on every agent.
- **An inbox.** A session that finished since you last opened it is unread:
  bold in the list with a blue dot, counted on the Dock icon and in the menu
  bar panel.
- **Interface scale.** Settings > General scales app content from 80% to 150%.
  View > Zoom In, Zoom Out and Actual Size (Command-Plus, Command-Minus,
  Command-0) adjust it immediately. Toolbar height, buttons, backgrounds, text
  and Settings tabs grow together. Text and icons render at their new size.
- **Readable chat text.** Settings > Chat independently controls the chat's
  font, monospaced font for commands and output, and base text size.
- **Agent Markdown as it is meant to read:** headings, lists, code blocks and
  tables with wrapping, content-based column widths and horizontal scrolling.
- **Notifications** when a run fails, times out or cannot start, and when a
  missed slot is skipped; click one to open its session. Successes notify too if you ask for it. A routine
  whose last five scheduled runs failed pauses itself and says so.
- **Harness warnings.** Rota reads the routine's project skill and warns when
  it uses a tool the chosen harness lacks: Claude in Chrome on Grok Build, for
  example, or phone push anywhere but Claude Code.
- **Import from Claude Desktop and Codex.** Reads the routines Claude Desktop
  schedules and the automations of the Codex app (read-only), with their
  schedules in words, and copies the ones you pick, turned off, so nothing runs
  twice. Search by name, project folder, or source app; already imported routines
  stay hidden until you ask to see them. Selection survives filtering, and the
  footer shows how many routines will be imported. Codex automations keep their model and reasoning effort. Grok Build
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
- Select a session to read it and write to it. **Show Routine** in its header
  opens the routine's page with its schedule, settings, and sessions.
  Under **Routines**, a routine
  shows its schedule and next run, the switch that pauses it, **Run Now** and its
  sessions; **Edit…** opens its settings, Delete included. A new routine runs
  on its schedule from the start.
- Chat shows messages and basic tool activity. Unsupported optional output is
  omitted; if chat history cannot be read, Rota shows a warning and uses the
  readable log. Long chats open at the latest 50 entries; Load Earlier Messages
  brings in previous entries. See [Transcript format](docs/transcript-format.md) for the
  storage and compatibility contract.
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

Routine tools retain their unattended execution policy (`bypassPermissions`
for Claude Code, `approvalPolicy: never` with `danger-full-access` for the Codex
daemon, and `--always-approve` for Grok Build). Native questions, explicit plan
confirmations and MCP requests that reach Rota wait for your answer in the app.
Point a routine only at a project whose skill you trust.

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

## Uninstall

Quit Rota from the panel, move **Rota.app** to the Trash, and remove its data:

```bash
defaults delete com.wiltodelta.rota
rm -rf ~/Library/Application\ Support/Rota ~/Library/Logs/Rota ~/Library/Caches/Rota
```

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
