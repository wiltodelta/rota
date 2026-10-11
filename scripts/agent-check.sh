#!/bin/bash
# End-to-end check of the `rota` command and `rota mcp` against the built Rota.app, on
# clean data: Rota's data is moved aside and put back at the end. It asks Claude
# Code, Codex and Grok Build to create a routine through MCP (a little quota each)
# without touching their own MCP settings, and leaves one session in each to delete
# (see CLAUDE.md). Run ./create-app.sh first.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"; APP="$REPO/Rota.app"; R="$APP/Contents/Helpers/rota"
S="$HOME/Library/Application Support/Rota"; L="$HOME/Library/Logs/Rota"
B=$(mktemp -d /tmp/rota-e2e-backup.XXXX); W=$(mktemp -d /tmp/rota-e2e-work.XXXX)
FAIL=0; ok() { echo "ok    $1"; }; bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
quit_rota() { pkill -f "Rota.app/Contents/MacOS/Rota"; while pgrep -f "Rota.app/Contents/MacOS/Rota" >/dev/null; do sleep 0.5; done; }
restore() { quit_rota; rm -rf "$S" "$L"; [[ -d "$B/support" ]] && mv "$B/support" "$S"; [[ -d "$B/logs" ]] && mv "$B/logs" "$L"; rm -rf "$B" "$W"; }
quit_rota
[[ -d "$S" ]] && mv "$S" "$B/support"; [[ -d "$L" ]] && mv "$L" "$B/logs"
trap restore EXIT
trap "exit 130" INT TERM
mkdir -p "$W/project"

# 1. The command starts Rota when it is closed.
out=$("$R" list 2>&1); [[ "$out" == "No routines." ]] && ok "list starts Rota: $out" || bad "list starts Rota: $out"
pgrep -f "$APP/Contents/MacOS/Rota" >/dev/null && ok "Rota running" || bad "Rota running"
# 2. Manage a shell routine.
out=$("$R" add cli-shell --folder "$W/project" --schedule "0 9 * * 1-5" --harness shell --prompt 'echo from cli' 2>&1); [[ "$out" == *"cli-shell  on  shell  Weekdays"* ]] && ok "add: $out" || bad "add: $out"
out=$("$R" add cli-shell --folder "$W/project" --schedule "0 9 * * 1-5" --prompt x 2>&1); [[ "$out" == *exists* ]] && ok "duplicate refused" || bad "duplicate: $out"
out=$("$R" add bad --folder /nonexistent --schedule "0 9 * * *" --prompt x 2>&1); [[ "$out" == *"does not exist"* ]] && ok "missing folder refused" || bad "missing folder: $out"
"$R" run cli-shell >/dev/null 2>&1 && ok "run" || bad "run"
sleep 4
out=$("$R" log cli-shell 2>&1); [[ "$out" == *"from cli"* ]] && ok "log shows output" || bad "log: $out"
out=$("$R" sessions cli-shell 2>&1); [[ "$out" == *Succeeded* ]] && ok "sessions: $out" || bad "sessions: $out"
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
"$R" add asks --folder "$W/project" --schedule "0 9 * * 1" --harness shell --prompt '"$ROTA_CLI" notify --needs-reply "Approve the invoice?"' >/dev/null 2>&1
"$R" run asks >/dev/null 2>&1; sleep 4
out=$("$R" sessions asks --json 2>&1); [[ "$out" == *'"needsReply" : "Approve the invoice?"'* ]] && ok "a run asks for a reply" || bad "needs reply: $out"
/usr/bin/log show --last 1m --predicate 'process == "usernoted"' 2>/dev/null | grep -q "Presenting.*wiltodelta" && ok "the notification is shown" || bad "no banner logged"
"$R" remove asks >/dev/null 2>&1
"$R" remove cli-shell >/dev/null 2>&1; "$R" show cli-shell 2>&1 | grep -q "No routine" && ok "remove" || bad "remove"
# 4. Real agents create a routine through MCP.
# macOS has no timeout(1): kill the command after $1 seconds.
limited() { local secs=$1; shift; "$@" </dev/null & local pid=$!; ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local guard=$!; wait "$pid"; local status=$?; kill "$guard" 2>/dev/null; return $status; }
ask() { echo "Use the rota MCP tool create_routine to add a routine with id $1, workingDirectory $W/project, schedule \"0 9 * * 1\", harness shell, prompt \"echo $1\". Then reply with exactly: done"; }
echo "{\"mcpServers\":{\"rota\":{\"command\":\"$R\",\"args\":[\"mcp\"]}}}" > "$W/mcp.json"
(cd "$W/project" && limited 240 claude -p "$(ask by-claude)" --mcp-config "$W/mcp.json" --strict-mcp-config --allowedTools "mcp__rota__create_routine" --model haiku >"$W/claude.out" 2>&1)
"$R" show by-claude >/dev/null 2>&1 && ok "Claude Code created by-claude" || bad "Claude Code: $(tail -3 "$W/claude.out")"
(cd "$W/project" && limited 240 codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -c "mcp_servers.rota.command=\"$R\"" -c 'mcp_servers.rota.args=["mcp"]' "$(ask by-codex)" >"$W/codex.out" 2>&1)
"$R" show by-codex >/dev/null 2>&1 && ok "Codex created by-codex" || bad "Codex: $(tail -3 "$W/codex.out")"
(cd "$W/project" && grok mcp add -s project rota "$R" -- mcp >/dev/null 2>&1 && limited 240 grok -p "$(ask by-grok)" --always-approve >"$W/grok.out" 2>&1)
"$R" show by-grok >/dev/null 2>&1 && ok "Grok Build created by-grok" || bad "Grok: $(tail -3 "$W/grok.out")"
"$R" list
echo "$FAIL failures"
exit $FAIL
