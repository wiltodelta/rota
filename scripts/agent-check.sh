#!/bin/bash
# End-to-end check of the `rota` command and `rota mcp` against the development build
# (com.wiltodelta.rota.dev) on a fresh data folder, beside the installed Rota, which it
# never quits or reads. It asks Claude
# Code, Codex and Grok Build to create a routine through MCP (a little quota each)
# without touching their own MCP settings, and leaves one session in each to delete
# (see CLAUDE.md). Run ./create-app.sh first.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROTA_AGENT_APP:-$REPO/Rota.app}"; R="$APP/Contents/Helpers/rota"
DOMAIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$DOMAIN" == *.dev ]] || { echo "error: agent checks require a development build" >&2; exit 1; }
export ROTA_BUNDLE_ID="$DOMAIN" ROTA_TEST_DISABLE_NOTIFICATIONS=1
OUT="${ROTA_AGENT_OUT:-/tmp/rota-agent-check}"
W=$(mktemp -d /tmp/rota-e2e-work.XXXX)
# Grok keys session folders by the physical cwd, including /private/tmp on macOS.
W="$(cd "$W" && pwd -P)"
DRIVER="$W/driver"
swiftc -O "$REPO/scripts/ui-driver.swift" -o "$DRIVER" || exit 1
[[ "$("$DRIVER" processes)" == '[]' ]] ||
    { echo "error: this development bundle id is already running; use an isolated audit bundle" >&2; rm -rf "$W"; exit 1; }
defaults export "$DOMAIN" "$W/defaults.plist" >/dev/null || exit 1
# The build under test and every command here use this data folder.
export ROTA_DATA_DIR="$W/data"; S="$ROTA_DATA_DIR"
FAIL=0; ok() { echo "ok    $1"; }; bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
# Only the build under test, by its full path: never the installed app.
quit_rota() { "$DRIVER" quit "$APP"; }
cleanup() {
    quit_rota || return 1
    python3 "$REPO/scripts/restore-defaults.py" "$DOMAIN" "$W/defaults.plist" || return 1
    mkdir -p "$OUT"
    for output in claude.out codex.out grok.out sessions.jsonl; do
        [[ ! -f "$W/$output" ]] || cp "$W/$output" "$OUT/"
    done
    [[ ! -f "$S/routines.json" ]] || cp "$S/routines.json" "$OUT/routines.json"
    rm -rf "$W"
}
trap 'check_exit=$?; cleanup || check_exit=1; exit "$check_exit"' EXIT
trap "exit 130" INT TERM
mkdir -p "$W/project"

# 1. The command starts Rota when it is closed.
out=$("$R" list 2>&1); [[ "$out" == "No routines." ]] && ok "list starts Rota: $out" || bad "list starts Rota: $out"
[[ "$("$DRIVER" processes)" != '[]' ]] && ok "Rota running" || bad "Rota running"
# 2. Manage a shell routine.
out=$("$R" add cli-shell --folder "$W/project" --schedule "0 9 * * 1-5" --harness shell --off --prompt 'echo from cli' 2>&1); [[ "$out" == *"cli-shell  off  shell  Weekdays"* ]] && ok "add: $out" || bad "add: $out"
out=$("$R" add cli-shell --folder "$W/project" --schedule "0 9 * * 1-5" --prompt x 2>&1); [[ "$out" == *exists* ]] && ok "duplicate refused" || bad "duplicate: $out"
out=$("$R" add bad --folder /nonexistent --schedule "0 9 * * *" --prompt x 2>&1); [[ "$out" == *"does not exist"* ]] && ok "missing folder refused" || bad "missing folder: $out"
out=$("$R" help 2>&1) && [[ "$out" == Usage:* ]] && ok "help prints the usage" || bad "help: $out"
out=$("$R" run cli-shell 2>&1); [[ "$out" == "cli-shell  Running  "*"session "* ]] && ok "run: $out" || bad "run: $out"
sleep 4
out=$("$R" log cli-shell 2>&1); [[ "$out" == *"from cli"* ]] && ok "log shows output" || bad "log: $out"
out=$("$R" sessions cli-shell 2>&1); [[ "$out" == *Succeeded* && "$out" != *Z* ]] && ok "sessions in local time: $out" || bad "sessions: $out"
out=$("$R" update cli-shell --schedule "30 7 * * *" 2>&1); [[ "$out" == *"Every day"* ]] && ok "update: $out" || bad "update: $out"
out=$("$R" off cli-shell 2>&1); [[ "$out" == *"cli-shell  off"* ]] && ok "off: $out" || bad "off: $out"
out=$("$R" send cli-shell hello 2>&1); [[ "$out" == *"shell session takes no messages"* ]] && ok "shell refuses messages" || bad "send: $out"
grep -q '"cli-shell"' "$S/routines.json" && ok "saved by the app" || bad "saved by the app"
# 3. MCP over stdio.
mcp=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_routine","arguments":{"id":"cli-shell"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_routine","arguments":{"id":"nope"}}}' | "$R" mcp)
[[ $(echo "$mcp" | wc -l) -eq 4 ]] && ok "mcp answers each request, not the notification" || bad "mcp lines: $mcp"
echo "$mcp" | sed -n 2p | grep -q '"create_routine"' && ok "mcp lists tools" || bad "tools/list"
echo "$mcp" | sed -n 3p | grep -q 'cli-shell' && ok "mcp tool call" || bad "tools/call: $(echo "$mcp" | sed -n 3p)"
echo "$mcp" | sed -n 4p | grep -q '"isError":true' && ok "mcp tool error" || bad "tool error: $(echo "$mcp" | sed -n 4p)"
# A routine asks for a reply from inside its run, through the command Rota hands it.
"$R" add asks --folder "$W/project" --schedule "0 9 * * 1" --harness shell --off --prompt '"$ROTA_CLI" notify --needs-reply "Approve the invoice?"' >/dev/null 2>&1
"$R" run asks >/dev/null 2>&1; sleep 4
out=$("$R" sessions asks --json 2>&1); [[ "$out" == *'"needsReply" : "Approve the invoice?"'* ]] && ok "a run asks for a reply" || bad "needs reply: $out"
# Notification state is checked above. Test runs suppress real banners and permission requests.
"$R" remove asks >/dev/null 2>&1
"$R" remove cli-shell >/dev/null 2>&1; "$R" show cli-shell 2>&1 | grep -q "No routine" && ok "remove" || bad "remove"
# 4. Real agents create a routine through MCP.
[[ "${1:-}" != --cli-only ]] || { echo "$FAIL failures"; exit "$FAIL"; }
# macOS has no timeout(1): kill the command after $1 seconds.
limited() {
    local secs=$1 input=$2; shift 2
    env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /bin/zsh -lc 'exec "$0" "$@"' "$@" < "$input" & local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) & local guard=$!
    wait "$pid"; local status=$?; kill "$guard" 2>/dev/null; return "$status"
}
ask() { echo "Use the rota MCP tool create_routine to add a routine with id $1, workingDirectory $W/project, schedule \"0 9 * * 1\", harness shell, enabled false, prompt \"echo $1\". Then reply with exactly: done. Do not change configuration, trust, permissions or any other files. If the tool is unavailable, report that and stop."; }
# Each agent's server gets the data folder explicitly: an agent may not pass its own environment on.
echo "{\"mcpServers\":{\"rota\":{\"command\":\"$R\",\"args\":[\"mcp\"],\"env\":{\"ROTA_DATA_DIR\":\"$ROTA_DATA_DIR\"}}}}" > "$W/mcp.json"
ask by-claude > "$W/claude-prompt.txt"
ask by-codex > "$W/codex-prompt.txt"
ask by-grok > "$W/grok-prompt.txt"
CLAUDE_SESSION="$(uuidgen | tr '[:upper:]' '[:lower:]')"
GROK_SESSION="$(uuidgen | tr '[:upper:]' '[:lower:]')"
CLAUDE_PROGRAM="$(command -v claude)"
CODEX_PROGRAM="$(command -v codex)"
GROK_PROGRAM="$(command -v grok)"
python3 - "$W" "$R" <<'PY'
import json, sys
from pathlib import Path
folder = Path(sys.argv[1])
servers = [{"rota": {"command": sys.argv[2], "args": ["mcp"],
                    "env": {"ROTA_DATA_DIR": str(folder / "data"), "ROTA_TEST_DISABLE_NOTIFICATIONS": "1"}}}]
(folder / "grok-agent.md").write_text(
    "---\nname: rota-e2e\ndescription: Verify Rota MCP on disposable data.\n"
    "model: inherit\nprompt_mode: full\npermission_mode: default\nagents_md: false\n"
    "tools: [search_tool, use_tool]\nmcpServers: " + json.dumps(servers)
    + "\n---\nUse only the rota MCP server. Do not change configuration or folder trust.\n"
)
PY
printf '{"harness":"claude","session":"%s","cwd":"%s"}\n' "$CLAUDE_SESSION" "$W/project" >> "$W/sessions.jsonl"
printf '{"harness":"grok","session":"%s","cwd":"%s"}\n' "$GROK_SESSION" "$W/project" >> "$W/sessions.jsonl"
(cd "$W/project" && limited 240 "$W/claude-prompt.txt" "$CLAUDE_PROGRAM" -p --session-id "$CLAUDE_SESSION" --mcp-config "$W/mcp.json" --strict-mcp-config --allowedTools "mcp__rota__create_routine" --model haiku >"$W/claude.out" 2>&1)
"$R" show by-claude >/dev/null 2>&1 && ok "Claude Code created by-claude" || bad "Claude Code: $(tail -3 "$W/claude.out")"
(cd "$W/project" && limited 240 "$W/codex-prompt.txt" "$CODEX_PROGRAM" exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -c "mcp_servers.rota.command=\"$R\"" -c 'mcp_servers.rota.args=["mcp"]' -c "mcp_servers.rota.env.ROTA_DATA_DIR=\"$ROTA_DATA_DIR\"" - >"$W/codex.out" 2>&1)
python3 - "$W" <<'PY'
import json, sys
from pathlib import Path
folder = Path(sys.argv[1])
with (folder / 'sessions.jsonl').open('a') as manifest:
    for line in (folder / 'codex.out').read_text().splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get('type') == 'thread.started':
            manifest.write(json.dumps({'harness': 'codex', 'session': event['thread_id'],
                                       'cwd': str(folder / 'project')}) + '\n')
PY
"$R" show by-codex >/dev/null 2>&1 && ok "Codex created by-codex" || bad "Codex: $(tail -3 "$W/codex.out")"
# Explicit agent MCP servers do not need to trust the disposable project folder.
(cd "$W/project" && limited 240 /dev/null "$GROK_PROGRAM" --agent "$W/grok-agent.md" --no-subagents --max-turns 6 --prompt-file "$W/grok-prompt.txt" --session-id "$GROK_SESSION" --always-approve >"$W/grok.out" 2>&1)
"$R" show by-grok >/dev/null 2>&1 && ok "Grok Build created by-grok" || bad "Grok: $(tail -3 "$W/grok.out")"
python3 - "$S/routines.json" <<'PY'
import json, sys
rows = json.loads(open(sys.argv[1]).read())
assert {row["id"] for row in rows} == {"by-claude", "by-codex", "by-grok"}, rows
assert all(row["enabled"] is False for row in rows), rows
PY
[[ $? -eq 0 ]] && ok "agent-created routines stay disabled" || bad "agent-created routines must be disabled"
"$R" list
echo "$FAIL failures"
exit $FAIL
