#!/bin/bash
# End-to-end UI check of the built Rota.app through the Accessibility API
# (scripts/ui-driver.swift): create a routine in the New routine sheet, run it,
# follow its session, and capture every main surface in both appearances at the
# 820 pt minimum width. Rota's data and defaults are backed up first and put back
# at the end. Needs Accessibility and Screen Recording for the terminal.
#   scripts/ui-check.sh           shell routine only, no agent quota spent
#   scripts/ui-check.sh --live    also message a running Codex session
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${ROTA_UI_OUT:-/tmp/rota-ui-check}"
WORK="$(mktemp -d /tmp/rota-ui-work.XXXXXX)"
SUPPORT="$HOME/Library/Application Support/Rota"
LOGS="$HOME/Library/Logs/Rota"
BACKUP="$(mktemp -d /tmp/rota-ui-backup.XXXXXX)"
DRIVER="$WORK/driver"
LIVE="${1:-}"
FAILURES=0

pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; FAILURES=$((FAILURES + 1)); }
check() { if "$@" >/dev/null 2>&1; then pass "${*: -1}"; else fail "${*: -1}"; fi; }

quit_rota() {
    pkill -f "Rota.app/Contents/MacOS/Rota" || true
    while pgrep -f "Rota.app/Contents/MacOS/Rota" >/dev/null; do sleep 0.5; done
}

restore() {
    quit_rota
    rm -rf "$SUPPORT" "$LOGS"
    [[ -d "$BACKUP/support" ]] && mv "$BACKUP/support" "$SUPPORT"
    [[ -d "$BACKUP/logs" ]] && mv "$BACKUP/logs" "$LOGS"
    if [[ -f "$BACKUP/defaults.plist" ]]; then
        defaults import com.wiltodelta.rota "$BACKUP/defaults.plist"
    else
        defaults delete com.wiltodelta.rota >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK" "$BACKUP"
}

launch() {
    open --env "ROTA_APPEARANCE=$1" Rota.app
    sleep 4
    open Rota.app
    sleep 2
}

capture() {
    local title="$1" name="$2" id
    "$DRIVER" window "$title" 820 600 || true
    sleep 1
    id="$("$DRIVER" wid "$title")"
    screencapture -x -o -l "$id" "$OUT/$name.png" && pass "captured $name"
}

session_value() {
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[0]; print(sys.argv[2] in json.dumps(r["outcome"]), r.get("sessionID") or "")' \
        "$SUPPORT/runs/$1.json" "$2"
}

./create-app.sh >/dev/null
swiftc -O scripts/ui-driver.swift -o "$DRIVER"
mkdir -p "$OUT" "$WORK/project"
quit_rota
[[ -d "$SUPPORT" ]] && mv "$SUPPORT" "$BACKUP/support"
[[ -d "$LOGS" ]] && mv "$LOGS" "$BACKUP/logs"
defaults export com.wiltodelta.rota "$BACKUP/defaults.plist" 2>/dev/null || rm -f "$BACKUP/defaults.plist"
defaults delete com.wiltodelta.rota >/dev/null 2>&1 || true
trap restore EXIT

for appearance in light dark; do
    # Each pass starts from no routines, so the window opens by itself as on a first launch.
    rm -rf "$SUPPORT" "$LOGS"
    launch "$appearance"
    check "$DRIVER" exists newRoutine
    capture "Rota" "$appearance-empty"

    # A routine made the way a person makes one: the New routine sheet.
    "$DRIVER" press newRoutine; sleep 1.5
    "$DRIVER" set routineSkill "ui-shell-$appearance"
    "$DRIVER" set routineName "UI check $appearance"
    "$DRIVER" set routineFolder "$WORK/project"
    "$DRIVER" set routineSchedule "0 9 * * 1"
    "$DRIVER" set routinePrompt 'echo hello from rota; sleep 6; echo done'
    "$DRIVER" choose routineHarness Shell
    check "$DRIVER" choose routineHarness Shell
    "$DRIVER" press addRoutine; sleep 1
    grep -q '"harness" : "shell"' "$SUPPORT/routines.json" && pass "saved as a shell routine" || fail "saved as a shell routine"
    check "$DRIVER" exists runNow

    "$DRIVER" press runNow; sleep 3
    check "$DRIVER" exists stopSession
    check "$DRIVER" exists openTerminal
    capture "UI check $appearance" "$appearance-running"
    sleep 6
    read -r succeeded session <<<"$(session_value "ui-shell-$appearance" succeeded)"
    [[ "$succeeded" == True ]] && pass "shell run succeeded" || fail "shell run succeeded"
    [[ "$session" == rota-* ]] && pass "screen session recorded" || fail "screen session recorded"
    grep -q "hello from rota" "$LOGS/ui-shell-$appearance/"*.log && pass "output in log" || fail "output in log"
    capture "UI check $appearance" "$appearance-finished"

    # The routine view and its settings sheet.
    "$DRIVER" select "UI check $appearance" 2; sleep 1
    check "$DRIVER" exists editRoutine
    capture "UI check $appearance" "$appearance-routine"
    "$DRIVER" press editRoutine; sleep 1
    check "$DRIVER" exists saveRoutine
    capture "UI check $appearance" "$appearance-edit"
    "$DRIVER" press Cancel; sleep 0.5
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
    "$DRIVER" set composer "Reply with exactly: purple otter"
    "$DRIVER" press send
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
