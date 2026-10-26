# User guide

[Back to Rota](../README.md).

## Features

- **One scheduler for every harness.** Pick Claude Code, Codex, Grok Build, Antigravity or
  Shell per routine and switch at any time, with the model and reasoning
  effort to run on: Rota lists the models each agent's CLI offers. Standard five-field cron
  schedules, with common ones a click away and the next three run times shown
  as you type.
- **Sessions are the main view.** The collapsible Routines section stays at the top of the sidebar
  and remembers whether you left it expanded. Below it, the Sessions section lists every routine's sessions,
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
  Select any part of a message by dragging across its paragraphs and lists;
  hover a message for a Copy button that copies the whole of it.
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
  - Antigravity runs through `agy` with stream-json. Messages wait for the
    current turn to finish; finished conversations continue by ID in Rota.
    Models are grouped by family, with a separate effort picker containing
    only the tiers its CLI reports for that model. Fixed-effort models disable
    the effort picker. Native question forms and
    synchronized terminal continuation are not available for Antigravity.
  - Shell commands run in a detached `screen` session; **Open in Terminal**
    attaches with `screen -r`, where you can type into the command or stop it.
  A continued session runs again and appends to the same chat. Finished Claude Code, Codex and Grok Build
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
  50 finished sessions of each routine are kept. Running sessions and unanswered questions are protected;
  skipped slots have a separate history limit and never displace sessions.
  Each routine's session list shows the last reply or command output beside
  its date, agent, duration and status. Pending questions take precedence over
  earlier replies, and failures show their recorded reason.
  Delete a finished session and its local logs with the trash button or
  **Delete Session…** in its context menu. Confirmation is required; the
  routine and the agent's own history stay unchanged.
- **Agents manage routines.** A Claude Code, Codex, Grok Build or Antigravity session can
  schedule a routine ("run this every weekday at 9"), change, run, pause or
  delete one, and read or message its sessions, through Rota's MCP server.
  Turn it on per agent in Settings > Routines from agents. A routine an agent
  adds runs on its schedule and Rota notifies you. The same works from a
  terminal with the `rota` command: `rota list`, `rota add`, `rota run`,
  `rota log`, `rota help`. Both interfaces also expose session state and pending
  questions, explicit answers, attention dismissal, read marks, finished-session
  deletion and file attachments. `rota tools` lists the commands and MCP schemas
  shipped with the installed app; the shared catalog and coverage tests keep
  the two interfaces aligned as the control API grows. MCP is optional when an
  agent can use the CLI.
- **Answer agents in Rota.** Native questions from Claude Code, Codex and
  Grok Build appear in the session with their options or input fields. The
  session stays marked as needing your reply until you send an answer or
  explicitly decline/cancel the request. Multiple selections, private input,
  plan approvals and standard MCP forms/URL requests use the same flow.
  Free-text answers use the session composer, labeled with the current question.
  Numbered options highlight your selection; Something else moves focus to the composer.
  Multiple questions appear one at a time, with Back/Next and preserved drafts.
  Ordinary message drafts and attachments are kept separately. Codex's asynchronous
  questions and Antigravity questionnaires remain available after the turn ends
  and after restarting Rota; answering continues the same session. Antigravity's
  headless CLI skips its native questionnaire, so Rota reads its structured
  call from the native archive and sends the explicit answer as a later user turn.
  Device verification and forms Rota cannot
  render explain how to continue in the provider's app and never offer a false approval.
  Supported request types and verification coverage: [agent questions](agent-questions.md).
- **Routines can notify you.** A routine (or its skill) runs
  `"$ROTA_CLI" notify "…"`, or an agent calls the `notify_user` tool, and Rota
  shows a Mac notification from that session. With `--needs-reply` the session
  is marked "Needs your reply" until you answer in its chat, from the notification's
  Reply field, or dismiss it. Shell sessions say "Needs your attention" and offer
  dismissal instead of Reply. Click
  the notification to open the session. This gives routines on every agent a
  Mac notification channel.
- **An inbox.** A session that finished since you last opened it is unread:
  bold in the list with a blue dot and counted in the menu bar panel. The Dock
  badge counts only sessions that need your reply or attention. It clears when
  you answer or dismiss the last request, even if unread sessions remain.
- **Interface scale.** Settings > General scales app content from 80% to 150%.
  Rota uses bundled IBM Plex Sans for interface text.
  View > Zoom In, Zoom Out and Reset (Command-Plus, Command-Minus,
  Command-0) adjust it immediately. Toolbar height, buttons, backgrounds, text
  and Settings tabs grow together. Text and icons render at their new size.
- **Readable chat text.** Settings > Chat independently controls the chat's
  font, monospaced font for commands and output, and text scale (70% to 200%).
  View > Chat Zoom offers Zoom In, Zoom Out and Reset (Option-Command-Plus,
  Option-Command-Minus, Option-Command-0). Each step changes the chat scale by
  five percentage points; Reset returns it to 100% without changing interface zoom.
  Text scale multiplies the interface scale: 110% interface and 120% text make
  chat text 132% of its base size. Headings, code, line heights and paragraph
  spacing grow together. At 100% for both scales, body text is 14 pt with a
  22 pt line height; code blocks use 12.5 pt with a 20 pt line height.
  An existing text size is converted to a scale, preserving the body size.
  The defaults are IBM Plex Sans for messages and JetBrains Mono for code,
  bundled with Rota so no font installation is needed. Existing font choices,
  including System and System monospaced, are preserved.
- **Agent Markdown as it is meant to read:** headings, lists, code blocks and
  tables with wrapping, content-based column widths and horizontal scrolling.
  Local images appear as clickable previews; new sessions keep copies with their attachments.
- **Notifications** when a run fails, times out or cannot start, and when a
  missed slot is skipped; click one to open its session or routine. Completed runs notify too if you ask for it. A routine
  whose last five scheduled runs failed pauses itself and says so.
  In System Settings > Notifications > Rota, select the **Persistent** alert
  style so questions and problems stay visible until dismissed. macOS applies
  this setting to the whole app. Rota removes informational notifications
  (successes, routine additions and ordinary agent notices) after 8 seconds,
  including from Notification Center, while Rota is running. Notices requiring
  a reply, sessions with outstanding questions, failures and automatic pauses
  do not expire.
  Agents must use `--needs-reply` or `needsReply: true` for requests requiring
  action; Rota does not infer urgency from notification text.
- **Harness warnings.** Rota reads the routine's project skill and warns when
  it uses a tool the chosen harness lacks: Claude in Chrome on Grok Build, for
  example, or phone push anywhere but Claude Code.
- **Import from Claude Desktop and Codex.** Reads the routines Claude Desktop
  schedules and the automations of the Codex app (read-only), with their
  schedules in words, and copies the ones you pick, turned off, so nothing runs
  twice. Search by name, project folder, or source app; already imported routines
  stay hidden until you ask to see them. Selection survives filtering, and the
  footer shows how many routines will be imported. Automations with the same
  name remain separate; imported source IDs are remembered across renames.
  Codex automations keep their model and reasoning effort. Automations with
  several project folders are listed as unsupported; create a separate Rota
  routine for each folder. Grok Build
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
  readable log. Long chats initially load about 50 entries; tool calls and their
  output stay together even when the group is larger. Load Earlier Messages
  brings in previous entries without splitting those groups. See [Transcript format](transcript-format.md) for the
  storage and compatibility contract.
- The sidebar folds away with the button beside the title, View > Hide
  Sidebar or Control-Command-S. Its visibility and resized width are kept across
  launches, so the divider returns to where you left it.
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
daemon, `--always-approve` for Grok Build, and `--dangerously-skip-permissions`
for Antigravity). Rota does not grant or revoke Antigravity permissions;
permission requests surfaced from its archive offer only cancel/decline messages.
Native questions, explicit plan confirmations and MCP requests that reach Rota wait for your explicit answer,
in the app or through its CLI/MCP question tools.
Point a routine only at a project whose skill you trust.

Rota runs routines only while it is open; turn on **Launch at login** in
Settings, so runs cut off by a shutdown continue after the Mac starts.
Quitting Rota yourself while routines run asks first and stops them; their
sessions can be continued later.

If Rota restarts while an interactive Claude session is still alive, that routine
stays occupied until the session exits. Open in Terminal attaches to the existing
session. Another scheduled or manual run cannot start over it. Close that session
before deleting the routine.
