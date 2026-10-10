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
  Shell per routine and switch at any time. Standard five-field cron
  schedules, with the next three run times shown as you type.
- **Sessions are the main view.** The sidebar lists every routine's sessions,
  newest first, by day. A session reads as a chat: the routine's prompt, what
  the agent said, the tools it called, your messages.
- **Keep talking to a session, on every agent, while it works or after.** The
  field under the chat sends your message:
  - Claude Code runs as Claude Desktop runs it, `claude -p` with stream-json
    in and out: a message joins the current turn. Afterwards the session
    continues with `--resume`.
  - Codex runs on its local app-server daemon: a message joins the current
    turn (`turn/steer`). Afterwards the thread continues (`thread/resume`).
  - Grok Build runs through its shared leader: a message is answered right
    after the current turn. Afterwards the session is loaded and continued.
  - Shell commands run in a detached `screen` session; **Open in Terminal**
    attaches with `screen -r`, where you can type into the command or stop it.
  A continued session runs again and appends to the same chat. Finished agent
  sessions also open in their own CLI with **Continue in Terminal**. The last
  50 sessions of each routine are kept.
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
- **Harness warnings.** Rota reads the routine's project skill and warns when
  it uses a tool the chosen harness lacks: Claude in Chrome on Grok, for
  example, or phone push anywhere but Claude Code.
- **Import from Claude Desktop.** Reads the routines Claude Desktop schedules
  (read-only) and copies the ones you pick, turned off, so nothing runs twice.
- **Safe defaults, as in Claude Desktop.** Slots missed while the Mac slept or
  Rota was closed run once, late, marked as a catch-up, if the last one is
  under seven days old; older ones are recorded as skipped. A slot that arrives
  while the previous run is still going is skipped quietly. Skips stay in the
  routine's history, out of the sessions list. Every run has a time limit.

## Requirements

- macOS 15 (Sequoia) or later, on Apple silicon. On macOS 26 (Tahoe) the menu
  bar panel uses Liquid Glass.
- The CLIs you want to use, installed and signed in: `claude`, `codex`,
  `grok`. Their paths are set in Settings.
- For building from source: Xcode 26 or later.

## Install

### From a release

1. Download the latest `Rota-vX.Y.Z-macOS.zip` from the
   [Releases](https://github.com/wiltodelta/rota/releases) page.
2. Unzip it and move **Rota.app** to `/Applications`.
3. Launch it. A loop-and-play icon appears in the menu bar (filled while a
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
  the harness and a time limit. A Shell routine takes a command instead of a
  prompt and runs it with `zsh -c` in the project folder.
- **Import** with the download button: pick routines from Claude Desktop. Turn
  each one off in Claude Desktop before turning it on in Rota.
- Select a session to read it and write to it. Under **Routines**, a routine
  shows its next run, the switch that pauses it, **Run Now** and its
  sessions; **Edit…** opens its settings, Delete included. A new routine runs
  on its schedule from the start.
- Menus: File > New Routine… (Command-N) and Import from Claude Desktop…;
  Routine > Run Now (Command-R), Stop (Command-.) and Edit Routine…
  (Command-E), acting on the selected routine or the selected session's.
- The menu bar panel lists every routine with its next run; hover a row to run
  or stop it, click it to open its latest session. Right-click the icon for Settings,
  updates and Quit.
- If the icon is hidden (behind the notch, or by a menu bar manager), open
  Rota again from Finder or Spotlight to get its window.

Agents run unattended with approvals bypassed (`bypassPermissions` for
Claude, `--dangerously-bypass-approvals-and-sandbox` for Codex,
`--always-approve` for Grok), the same mode Claude Desktop routines use: nobody
is there to answer a prompt. Point a routine only at a project whose skill you
trust.

Rota runs routines only while it is open; turn on **Open at login** in
Settings. Quitting while routines run asks first and stops them; their
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
- `bash maintain.sh` runs SwiftLint, the tests and a release build.
- `scripts/ui-check.sh` drives the built app through the Accessibility API
  (`scripts/ui-driver.swift`): it makes and runs a routine in both appearances
  at the minimum window size, checks each step and saves screenshots; `--live`
  also messages a running Codex session. It backs up and restores Rota's data.

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
