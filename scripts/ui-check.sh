#!/bin/bash
# End-to-end UI check of the built Rota.app through the Accessibility API
# (scripts/ui-driver.swift): create a routine in the New Routine sheet, run it,
# follow its session, and capture every main surface in both appearances at the
# 820 pt minimum width. It runs the development build (com.wiltodelta.rota.dev)
# on a fresh data folder and its own defaults, beside the installed Rota, which it
# never quits or reads. Needs Accessibility and Screen Recording for the terminal.
#   scripts/ui-check.sh           shell routine only, no agent quota spent
#   scripts/ui-check.sh --live    also message a running Codex session
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${ROTA_UI_OUT:-/tmp/rota-ui-check}"
WORK="$(mktemp -d /tmp/rota-ui-work.XXXXXX)"
# The build under test keeps everything here; the command inside it follows ROTA_DATA_DIR too.
export ROTA_DATA_DIR="$WORK/data"
SUPPORT="$ROTA_DATA_DIR"
LOGS="$ROTA_DATA_DIR/Logs"
DOMAIN="com.wiltodelta.rota.dev"
APP="$PWD/Rota.app"
DRIVER="$WORK/driver"
LIVE="${1:-}"
FAILURES=0

pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; FAILURES=$((FAILURES + 1)); }
check() { if "$@" >/dev/null 2>&1; then pass "${*: -1}"; else fail "${*: -1}"; fi; }

# Only the build under test, by its full path: never the installed app.
quit_rota() {
    pkill -f "$APP/Contents/MacOS/Rota" || true
    while pgrep -f "$APP/Contents/MacOS/Rota" >/dev/null; do sleep 0.5; done
}

cleanup() {
    quit_rota
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}

# LaunchServices can refuse to open an app that has just quit (error -600), so try again.
# The data folder goes along, since an app opened by LaunchServices does not inherit the shell's environment.
open_rota() {
    for _ in 1 2 3; do open --env "ROTA_DATA_DIR=$ROTA_DATA_DIR" "$@" "$APP" && return 0; sleep 2; done
    return 1
}

launch() {
    open_rota --env "ROTA_APPEARANCE=$1"
    sleep 4
    open_rota
    sleep 2
}

capture() {
    local title="$1" name="$2" id violations
    "$DRIVER" window "$title" 820 600 || true
    sleep 1
    id="$("$DRIVER" wid "$title")"
    screencapture -x -o -l "$id" "$OUT/$name.png" && pass "captured $name"
    # Frames that leave their window or parent: clipped or overflowing controls.
    violations="$("$DRIVER" gate | tail -1)"
    [[ "$violations" == "0 violations" ]] && pass "layout $name" || { fail "layout $name: $violations"; "$DRIVER" gate | sed 's/^/      /'; }
}

session_value() {
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[0]; print(sys.argv[2] in json.dumps(r["outcome"]), r.get("sessionID") or "")' \
        "$SUPPORT/runs/$1.json" "$2"
}

./create-app.sh >/dev/null
swiftc -O scripts/ui-driver.swift -o "$DRIVER"
mkdir -p "$OUT" "$WORK/project"
quit_rota
defaults delete "$DOMAIN" >/dev/null 2>&1 || true
trap cleanup EXIT

# The terminal a process runs in: the app among its ancestors.
terminal_of() {
    local pid="$1" name
    while [[ -n "$pid" && "$pid" -gt 1 ]]; do
        name="$(ps -o comm= -p "$pid")"
        case "$name" in *iTerm*) echo iTerm; return ;; *Terminal.app*|*/Terminal) echo Terminal; return ;; esac
        pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
    done
}

ITERM="$(mdfind "kMDItemCFBundleIdentifier == 'com.googlecode.iterm2'" | head -1)"

for appearance in light dark; do
    # Each pass starts from no routines, so the window opens by itself as on a first launch.
    rm -rf "$SUPPORT" "$LOGS"
    # The light pass opens sessions in Terminal, the dark one in iTerm2 when it is
    # installed; LiveHarnessTests covers the default, which follows macOS.
    if [[ "$appearance" == dark && -n "$ITERM" ]]; then
        defaults write "$DOMAIN" terminalApp "$ITERM"; expected=iTerm
    else
        defaults write "$DOMAIN" terminalApp /System/Applications/Utilities/Terminal.app; expected=Terminal
    fi
    launch "$appearance"
    check "$DRIVER" exists newRoutine
    capture "Rota" "$appearance-empty"

    # The import sheet reads Claude Desktop and Codex as they are on this Mac; Cancel leaves both untouched.
    "$DRIVER" press import; sleep 4
    check "$DRIVER" exists Cancel
    capture "Rota" "$appearance-import"
    "$DRIVER" press Cancel; sleep 1

    # A routine made the way a person makes one: the New Routine sheet.
    "$DRIVER" press newRoutine; sleep 1.5
    # Add stays off with the reason beside it, by the rule the rota command and MCP refuse with.
    [[ "$("$DRIVER" value sheetProblem)" == "Give the routine an id"* ]] && pass "new sheet says what is missing" \
        || fail "new sheet says what is missing: $("$DRIVER" value sheetProblem)"
    "$DRIVER" set routineSkill "Bad Id"; sleep 0.5
    [[ "$("$DRIVER" value sheetProblem)" == *lowercase* ]] && pass "new sheet refuses a bad id" \
        || fail "new sheet refuses a bad id: $("$DRIVER" value sheetProblem)"
    "$DRIVER" set routineSkill "ui-shell-$appearance"
    "$DRIVER" set routineName "UI check $appearance"
    "$DRIVER" set routineFolder "$WORK/project"
    "$DRIVER" set routineSchedule "0 9 * * 1"
    "$DRIVER" set routinePrompt 'echo hello from rota; sleep 15; echo done'
    # An agent shows the model and effort its CLI lists; the list loads in the background.
    "$DRIVER" choose routineHarness Codex; sleep 4
    check "$DRIVER" exists routineModel
    check "$DRIVER" exists routineEffort
    capture "Rota" "$appearance-new"
    "$DRIVER" choose routineHarness Shell
    check "$DRIVER" choose routineHarness Shell
    "$DRIVER" exists sheetProblem && fail "a complete routine can be added" || pass "a complete routine can be added"
    "$DRIVER" press addRoutine; sleep 1
    grep -q '"harness" : "shell"' "$SUPPORT/routines.json" && pass "saved as a shell routine" || fail "saved as a shell routine"
    check "$DRIVER" exists runNow

    "$DRIVER" press runNow; sleep 3
    check "$DRIVER" exists stopSession
    check "$DRIVER" exists openTerminal
    "$DRIVER" press openTerminal
    attach=""
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        "$DRIVER" confirm-iterm "ui-shell-$appearance" >/dev/null || true
        attach="$(pgrep -f "screen -r rota-" | tail -1 || true)"; [[ -n "$attach" ]] && break
    done
    [[ -n "$attach" && "$(terminal_of "$attach")" == "$expected" ]] && pass "opens in $expected" \
        || fail "opens in $expected: [$(terminal_of "${attach:-0}")]"
    capture "UI check $appearance" "$appearance-running"
    for _ in $(seq 1 20); do
        sleep 1
        read -r succeeded session <<<"$(session_value "ui-shell-$appearance" succeeded)"
        [[ "$succeeded" == True ]] && break
    done
    [[ "$succeeded" == True ]] && pass "shell run succeeded" || fail "shell run succeeded"
    [[ "$session" == rota-* ]] && pass "screen session recorded" || fail "screen session recorded"
    grep -q "hello from rota" "$LOGS/ui-shell-$appearance/"*.log && pass "output in log" || fail "output in log"
    capture "UI check $appearance" "$appearance-finished"

    # A session that asks for a reply shows it until it is answered or dismissed.
    Rota.app/Contents/Helpers/rota notify --session "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["id"])' "$SUPPORT/runs/ui-shell-$appearance.json")" \
        --needs-reply "Approve the weekly report?" >/dev/null && pass "notify needs reply" || fail "notify needs reply"
    sleep 1.5
    # A command takes no reply, so the banner asks for a look and a Done.
    [[ "$("$DRIVER" value attentionBanner)" == "Needs your attention" ]] && pass "shell banner asks for attention" \
        || fail "shell banner asks for attention: $("$DRIVER" value attentionBanner)"
    capture "UI check $appearance" "$appearance-needs-reply"
    "$DRIVER" press dismissAttention; sleep 1
    "$DRIVER" exists attentionBanner && fail "dismiss clears the mark" || pass "dismiss clears the mark"

    # The sidebar folds away and comes back, and the choice is kept.
    check "$DRIVER" exists toggleSidebar
    "$DRIVER" press toggleSidebar; sleep 1
    "$DRIVER" exists Routines && fail "sidebar hides" || pass "sidebar hides"
    [[ "$(defaults read "$DOMAIN" sidebarVisible 2>/dev/null)" == 0 ]] && pass "hidden sidebar is kept" \
        || fail "hidden sidebar is kept"
    capture "UI check $appearance" "$appearance-sidebar-hidden"
    "$DRIVER" press toggleSidebar; sleep 1
    check "$DRIVER" exists Routines

    # The routine view and its settings sheet.
    "$DRIVER" select "UI check $appearance" 2; sleep 1
    check "$DRIVER" exists editRoutine
    capture "UI check $appearance" "$appearance-routine"
    "$DRIVER" press editRoutine; sleep 1
    check "$DRIVER" exists saveRoutine
    capture "UI check $appearance" "$appearance-edit"
    # No time limit by default; turning it on shows its length.
    [[ "$("$DRIVER" value routineTimeLimit)" == 0 ]] && pass "no time limit by default" || fail "no time limit by default"
    "$DRIVER" press routineTimeLimit; sleep 1
    [[ "$("$DRIVER" value routineTimeLimit)" == 1 ]] && pass "time limit turns on" || fail "time limit turns on"
    capture "UI check $appearance" "$appearance-edit-limit"
    "$DRIVER" press Cancel; sleep 0.5
    quit_rota

    # The menu bar panel: each routine is a button that opens its latest session.
    open_rota --env "ROTA_APPEARANCE=$appearance" --env ROTA_OPEN_PANEL=1
    sleep 4
    panel_id="$(/usr/bin/log show --last 10s --info --predicate 'subsystem == "com.wiltodelta.rota" && category == "app"' \
        | grep -io 'window [0-9]*' | tail -1 | awk '{print $2}')"
    [[ -n "$panel_id" ]] && screencapture -x -o -l "$panel_id" "$OUT/$appearance-panel.png" \
        && pass "captured $appearance-panel" || fail "captured $appearance-panel"
    "$DRIVER" tree | grep -q "AXButton  UI check $appearance | Shell" && pass "panel row is a button" \
        || fail "panel row is a button"
    "$DRIVER" press "UI check $appearance"; sleep 2
    "$DRIVER" tree | grep -q "AXWindow  UI check $appearance" && pass "panel row opens its session" \
        || fail "panel row opens its session"
    quit_rota

    # Settings, with each agent's installed copies and versions; the light pass
    # shows the terminal picker on its default, which names the macOS default terminal.
    [[ "$appearance" == light ]] && { defaults delete "$DOMAIN" terminalApp >/dev/null 2>&1 || true; }
    defaults write "$DOMAIN" settingsTab -int 0
    open_rota --env "ROTA_APPEARANCE=$appearance" --env ROTA_OPEN_SETTINGS=1
    sleep 8
    # Settings are toolbar tabs; the window takes each tab's title and height.
    for tab in General Chat Agents Integrations Browsers; do
        [[ "$tab" == General ]] || { "$DRIVER" press "$tab"; sleep 2; }
        settings_id="$("$DRIVER" wid "$tab")" \
            && screencapture -x -o -l "$settings_id" "$OUT/$appearance-settings-$(echo "$tab" | tr A-Z a-z).png" \
            && pass "captured $appearance-settings-$tab" || fail "captured $appearance-settings-$tab"
        violations="$("$DRIVER" gate | tail -1)"
        [[ "$violations" == "0 violations" ]] && pass "layout settings $tab" || fail "layout settings $tab: $violations"
    done
    quit_rota
done

if [[ "$LIVE" == --live ]]; then
    launch light
    "$DRIVER" press newRoutine; sleep 1.5
    "$DRIVER" set routineSkill ui-codex
    "$DRIVER" set routineName "UI check codex"
    "$DRIVER" set routineFolder "$WORK/project"
    "$DRIVER" set routinePrompt 'Run the shell command `sleep 15; echo first`. Then reply with exactly the phrase a later message gives you, or done if none.'
    "$DRIVER" choose routineHarness Codex
    "$DRIVER" press addRoutine; sleep 1
    "$DRIVER" press runNow; sleep 6
    # Option-Return starts a new line and sends nothing.
    "$DRIVER" set composer "first line"
    "$DRIVER" focus composer; sleep 0.5
    "$DRIVER" key option-return; sleep 1
    # The trailing dot keeps the newline that command substitution would strip.
    [[ "$("$DRIVER" value composer; printf .)" == $'first line\n\n.' ]] && pass "option-return adds a line" \
        || fail "option-return adds a line: [$("$DRIVER" value composer | od -c | head -1)]"
    grep -q "\[you\] first line" "$LOGS/ui-codex/"*.log && fail "option-return sent the message" || pass "option-return sends nothing"
    # Return sends: the field empties and the message reaches the session.
    "$DRIVER" set composer "Reply with exactly: purple otter"
    check "$DRIVER" exists composerStop
    capture "UI check codex" codex-running
    "$DRIVER" focus composer; sleep 0.5
    "$DRIVER" key return; sleep 2
    [[ -z "$("$DRIVER" value composer)" ]] && pass "return empties the field" || fail "return empties the field"
    grep -q "\[you\] Reply with exactly: purple otter" "$LOGS/ui-codex/"*.log && pass "return sends the message" \
        || fail "return sends the message"
    for _ in $(seq 1 30); do
        sleep 3
        read -r succeeded _ <<<"$(session_value ui-codex succeeded)"
        [[ "$succeeded" == True ]] && break
    done
    [[ "$succeeded" == True ]] && pass "codex run succeeded" || fail "codex run succeeded"
    grep -qi "purple otter" "$LOGS/ui-codex/"*.log && pass "codex took the message" || fail "codex took the message"
    capture "UI check codex" codex-finished
    session="$(session_value ui-codex succeeded | cut -d' ' -f2)"
    echo "note: delete Codex thread $session when done (thread/delete on the app-server)"
fi

echo "screenshots in $OUT"
if (( FAILURES > 0 )); then echo "$FAILURES checks failed"; exit 1; fi
echo "all checks passed"
