#!/bin/bash
# End-to-end UI check of the built Rota.app through the Accessibility API
# (scripts/ui-driver.swift): create a routine in the New Routine sheet, run it,
# follow its session, and capture every main surface in both appearances at the
# 820 pt minimum width. It runs the development build (com.wiltodelta.rota.dev)
# on a fresh data folder and its own defaults, beside the installed Rota, which it
# never quits or reads. Needs Accessibility and Screen Recording for the terminal.
#   scripts/ui-check.sh           shell routine only, no agent quota spent
#   scripts/ui-check.sh --live    also message a running Codex session
#   ROTA_UI_TERMINAL=terminal scripts/ui-check.sh  use Terminal in both appearances
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
TERMINAL_MODE="${ROTA_UI_TERMINAL:-auto}"
CACHE="$HOME/Library/Caches/Rota/chat"

pass() { echo "ok    $1"; }
fail() {
    echo "FAIL  $1"
    if [[ -x "$DRIVER" ]]; then "$DRIVER" tree > "$OUT/failure-tree.txt" 2>&1 || true; fi
    exit 1
}
check() { if "$@" >/dev/null 2>&1; then pass "${*: -1}"; else fail "${*: -1}"; fi; }

wait_value() {
    local actual attempt
    for ((attempt = 0; attempt < 30; attempt++)); do
        actual="$("$DRIVER" value "$1")" || return 1
        [[ "$actual" == "$2" ]] && return 0
        sleep 0.2
    done
    return 1
}

wait_exists() {
    local attempt
    for ((attempt = 0; attempt < 150; attempt++)); do
        "$DRIVER" exists "$1" && return 0
        sleep 0.2
    done
    fail "element did not appear: $1"
}

wait_visible() {
    local attempt
    for ((attempt = 0; attempt < 30; attempt++)); do
        "$DRIVER" visible "$1" >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    return 1
}

# Only the build under test, by its full path: never the installed app.
quit_rota() {
    local app_pid child command
    # Settings inspections can still be running when a pane closes. Stop only
    # this build's read-only MCP children before their parent exits.
    for app_pid in $(pgrep -f "$APP/Contents/MacOS/Rota" || true); do
        for child in $(pgrep -P "$app_pid" || true); do
            command="$(ps -o args= -p "$child")" || continue
            case "$command" in
                *" mcp get rota"|*" mcp list --json"|*" mcp list") kill "$child" 2>/dev/null || true ;;
            esac
        done
    done
    pkill -f "$APP/Contents/MacOS/Rota" || true
    while pgrep -f "$APP/Contents/MacOS/Rota" >/dev/null; do sleep 0.5; done
}

cleanup() {
    quit_rota
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    if [[ "$HAD_DEFAULTS" == 1 ]]; then
        defaults import "$DOMAIN" "$WORK/defaults.plist"
        defaults export "$DOMAIN" "$WORK/restored.plist"
        python3 - "$WORK/defaults.plist" "$WORK/restored.plist" <<'PYTHON'
import plistlib
import sys
with open(sys.argv[1], "rb") as before, open(sys.argv[2], "rb") as after:
    assert plistlib.load(before) == plistlib.load(after), "Development defaults were not restored"
PYTHON
    fi
    for name in ui-shell-light ui-shell-dark ui-codex; do
        if [[ -f "$WORK/$name.command" ]]; then cp -p "$WORK/$name.command" "$CACHE/$name.command"
        else rm -f "$CACHE/$name.command"
        fi
    done
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

check_layout() {
    local violations
    violations="$("$DRIVER" gate)"
    if [[ "${violations##*$'\n'}" == "0 violations" ]]; then pass "layout $1"
    else printf '%s\n' "$violations"; fail "layout $1"
    fi
}

check_agents_scrolling() {
    local mode amount
    wait_exists agentAccess-antigravity
    # AXReveal and scrollbar values bypass the wheel delivery path that can be
    # swallowed by a natural-height Form nested inside another scroll view.
    for mode in pixel line; do
        if [[ "$mode" == pixel ]]; then amount=3000; else amount=200; fi
        "$DRIVER" scroll-wheel Agents "$amount" "$mode"
        check wait_visible agentCLIsHeading
        "$DRIVER" scroll-wheel Agents "-$amount" "$mode"
        check wait_visible agentAccess-antigravity
        check wait_visible agentAccessFooter
    done
}

capture() {
    local title="$1" name="$2" id actual_width
    "$DRIVER" window "$title" 820 600 || true
    sleep 1
    actual_width="$("$DRIVER" bounds "$title" | awk '{print $3}')"
    awk -v width="$actual_width" 'BEGIN { exit !(width >= 819.5 && width <= 820.5) }' \
        || fail "$name is not at minimum width: $actual_width"
    id="$("$DRIVER" wid "$title")"
    screencapture -x -o -l "$id" "$OUT/$name.png" && pass "captured $name"
    check_layout "$name"
}

session_value() {
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[0]; print(sys.argv[2] in json.dumps(r["outcome"]), r.get("sessionID") or "")' \
        "$SUPPORT/runs/$1.json" "$2"
}

for name in ui-shell-light ui-shell-dark ui-codex; do
    if [[ -f "$CACHE/$name.command" ]]; then cp -p "$CACHE/$name.command" "$WORK/$name.command"; fi
done
HAD_DEFAULTS=0
if defaults export "$DOMAIN" "$WORK/defaults.plist" 2>/dev/null; then HAD_DEFAULTS=1; fi
trap cleanup EXIT
trap 'fail "UI check command at line $LINENO"' ERR
case "$TERMINAL_MODE" in
    auto) ;;
    terminal) pass "terminal override: Terminal in both appearances" ;;
    *) fail "ROTA_UI_TERMINAL must be auto or terminal" ;;
esac
./create-app.sh >/dev/null
swiftc -O scripts/ui-driver.swift -o "$DRIVER"
mkdir -p "$OUT" "$WORK/project"
quit_rota
defaults delete "$DOMAIN" >/dev/null 2>&1 || true

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

# Light must pass completely before dark is exercised. Any failed check stops the run.
for appearance in light dark; do
    # Each pass starts from no routines, so the window opens by itself as on a first launch.
    rm -rf "$SUPPORT" "$LOGS"
    # The light pass opens sessions in Terminal, the dark one in iTerm2 when it is
    # installed; LiveHarnessTests covers the default, which follows macOS.
    if [[ "$appearance" == dark && "$TERMINAL_MODE" == auto && -n "$ITERM" ]]; then
        defaults write "$DOMAIN" terminalApp "$ITERM"; expected=iTerm
    else
        defaults write "$DOMAIN" terminalApp /System/Applications/Utilities/Terminal.app; expected=Terminal
    fi
    cp scripts/fixtures/antigravity-catalog.sh "$WORK/agy"
    chmod 700 "$WORK/agy"
    defaults write "$DOMAIN" executables -dict antigravity "$WORK/agy"
    launch "$appearance"
    check "$DRIVER" exists newRoutine
    check "$DRIVER" in-toolbar toggleSidebar
    check "$DRIVER" in-toolbar newRoutine
    # Zoom the existing window and measure the complete title-bar composition.
    "$DRIVER" key command-zero
    sleep 0.5
    normal_bar="$("$DRIVER" bounds mainToolbar)"
    normal_circle="$("$DRIVER" bounds toggleSidebar)"
    normal_actions="$("$DRIVER" bounds toolbarActions)"
    normal_title="$("$DRIVER" bounds mainWindowTitle)"
    normal_sidebar="$("$DRIVER" bounds routineSidebar)"
    for _ in 1 2 3; do "$DRIVER" key command-plus; sleep 0.2; done
    sleep 0.5
    large_bar="$("$DRIVER" bounds mainToolbar)"
    large_circle="$("$DRIVER" bounds toggleSidebar)"
    large_actions="$("$DRIVER" bounds toolbarActions)"
    large_title="$("$DRIVER" bounds mainWindowTitle)"
    large_sidebar="$("$DRIVER" bounds routineSidebar)"
    if python3 - "$normal_bar" "$normal_circle" "$normal_actions" "$normal_title" "$normal_sidebar" \
        "$large_bar" "$large_circle" "$large_actions" "$large_title" "$large_sidebar" <<'PYTHON'
import sys
rects = [list(map(float, value.split())) for value in sys.argv[1:]]
for factor, (bar, circle, actions, title, sidebar) in zip((1, 1.5), (rects[:5], rects[5:]), strict=True):
    assert abs(bar[3] - 52 * factor) <= 0.5, ("bar height", bar)
    assert abs(circle[2] - 36 * factor) <= 0.5, ("circle width", circle)
    assert abs(circle[3] - circle[2]) <= 0.5, ("circle aspect", circle)
    assert abs(actions[2] - 64 * factor) <= 0.5, ("capsule width", actions)
    assert abs(actions[3] - 36 * factor) <= 0.5, ("capsule height", actions)
    for item in (circle, actions, title):
        assert abs(item[1] + item[3] / 2 - bar[1] - bar[3] / 2) <= 0.75, ("vertical center", item)
    assert abs(circle[0] - sidebar[0] - sidebar[2] - 8 * factor) <= 0.5, ("sidebar placement", circle, sidebar)
    assert abs(bar[0] + bar[2] - actions[0] - actions[2] - 12 * factor) <= 0.5, ("trailing margin", actions)
assert abs(rects[8][3] - rects[3][3] * 1.5) <= 1.5, "title height follows zoom"
assert abs(rects[5][1] - rects[0][1]) <= 0.5, "bar stays at the window top"
PYTHON
    then pass "toolbar proportions, alignment and original placement follow zoom"
    else fail "toolbar zoom geometry"
    fi
    [[ "$("$DRIVER" text-count Rota)" == 1 ]] && pass "one visible toolbar title" || fail "duplicate toolbar title"
    capture "Rota" "$appearance-toolbar-zoom"
    "$DRIVER" key command-zero
    sleep 0.5
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
    "$DRIVER" choose routineHarness Antigravity
    check wait_value routineModel 'Default (Model A)'
    "$DRIVER" choose routineModel 'Model A'
    "$DRIVER" choose routineEffort High
    [[ "$("$DRIVER" enabled routineEffort)" == true ]] || fail "adjustable effort is disabled"
    capture "Rota" "$appearance-new-antigravity"
    "$DRIVER" choose routineModel Fixed
    check wait_value routineEffort 'Not supported'
    [[ "$("$DRIVER" enabled routineEffort)" == false ]] || fail "fixed effort is enabled"
    capture "Rota" "$appearance-antigravity-fixed"
    "$DRIVER" choose routineModel 'Model A'
    "$DRIVER" choose routineEffort Low
    "$DRIVER" choose routineHarness Shell
    "$DRIVER" choose routineHarness Antigravity
    check wait_value routineModel 'Default (Model A)'
    "$DRIVER" reveal routineTimeLimit
    [[ "$("$DRIVER" value routineTimeLimit)" == 0 ]] || fail "new routine starts without a time limit"
    "$DRIVER" press routineTimeLimit
    wait_value routineTimeLimit 1 && pass "time limit switch enables" || fail "time limit switch enables"
    check "$DRIVER" exists routineTimeLimitValue
    "$DRIVER" reveal routineTimeLimitValue
    check "$DRIVER" aligned "Stop a run after" routineTimeLimitValue
    "$DRIVER" press routineTimeLimit
    wait_value routineTimeLimit 0 && pass "time limit switch disables" || fail "time limit switch disables"
    "$DRIVER" reveal routineHarness
    "$DRIVER" choose routineHarness Shell
    check "$DRIVER" choose routineHarness Shell
    "$DRIVER" exists sheetProblem && fail "a complete routine can be added" || pass "a complete routine can be added"
    "$DRIVER" press addRoutine; sleep 1
    grep -q '"harness" : "shell"' "$SUPPORT/routines.json" && pass "saved as a shell routine" || fail "saved as a shell routine"
    check "$DRIVER" exists runNow

    "$DRIVER" press runNow; sleep 3
    check "$DRIVER" exists stopSession
    check "$DRIVER" exists openTerminal
    session="$(session_value "ui-shell-$appearance" running | cut -d' ' -f2)"
    [[ "$session" == rota-* ]] || fail "running shell session was not recorded"
    "$DRIVER" press openTerminal
    attach=""
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        "$DRIVER" confirm-iterm "ui-shell-$appearance" >/dev/null || true
        attach="$(pgrep -f "screen -r $session" | tail -1 || true)"; [[ -n "$attach" ]] && break
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

    # Open the owning routine page and return to its session.
    check "$DRIVER" exists showSessionRoutine
    check "$DRIVER" press showSessionRoutine
    check "$DRIVER" exists editRoutine
    check "$DRIVER" select "UI check $appearance" 2
    check "$DRIVER" exists showSessionRoutine
    check "$DRIVER" exists deleteSession

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
    "$DRIVER" select "UI check $appearance" 1; sleep 1
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
    # A long title must truncate at minimum width instead of expanding the window.
    "$DRIVER" key command-zero
    for _ in 1 2 3; do "$DRIVER" key command-plus; sleep 0.2; done
    "$DRIVER" window "UI check $appearance" 820 600
    long_title="Example project: Scheduled report with a longer title"
    "$DRIVER" press editRoutine; sleep 0.5
    "$DRIVER" set routineName "$long_title"
    "$DRIVER" press saveRoutine; sleep 0.75
    wait_value mainWindowTitle "$long_title" || fail "renamed title reaches toolbar"
    actual_width="$("$DRIVER" bounds mainToolbar | awk '{print $3}')"
    awk -v width="$actual_width" 'BEGIN { exit !(width >= 819.5 && width <= 820.5) }' \
        && pass "long title keeps the 820 pt window" || fail "long title expanded window to $actual_width"
    check "$DRIVER" visible newRoutine
    capture "$long_title" "$appearance-long-toolbar-title"
    "$DRIVER" press editRoutine; sleep 0.5
    "$DRIVER" set routineName "UI check $appearance"
    "$DRIVER" press saveRoutine; sleep 0.5
    "$DRIVER" key command-zero
    quit_rota

    # The menu bar panel: each routine is a button that opens its latest session.
    open_rota --env "ROTA_APPEARANCE=$appearance" --env ROTA_OPEN_PANEL=1
    sleep 4
    panel_id="$("$DRIVER" wid "")"
    [[ -n "$panel_id" ]] && screencapture -x -o -l "$panel_id" "$OUT/$appearance-panel.png" \
        && pass "captured $appearance-panel" || fail "captured $appearance-panel"
    "$DRIVER" tree > "$OUT/$appearance-panel-tree.txt"
    grep -q "AXButton  UI check $appearance | Shell" "$OUT/$appearance-panel-tree.txt" \
        && pass "panel row is a button" || fail "panel row is a button"
    "$DRIVER" press "UI check $appearance"
    wait_value mainWindowTitle "UI check $appearance" || fail "panel session title appears"
    "$DRIVER" tree > "$OUT/$appearance-panel-session-tree.txt"
    grep -q "AXWindow  UI check $appearance" "$OUT/$appearance-panel-session-tree.txt" \
        && pass "panel row opens its session" || fail "panel row opens its session"
    quit_rota

    # Render a synthetic legacy agent response without launching an agent.
    python3 - "$SUPPORT" "ui-shell-$appearance" <<'PYTHON'
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import uuid
root, routine = Path(sys.argv[1]), sys.argv[2]
log = root / "Logs" / routine / "table-fixture.log"
log.write_text("""Таблица с разным количеством текста.

| # | Пункт | Результат |
| ---: | :--- | :--- |
| 1 | Настройки | **Готово** |
| 2 | Проверка длинного описания и переноса текста внутри колонки | Проверены основные поля, дополнительные параметры и расположение элементов. Правая колонка содержит больше текста и получает больше места, сохраняя читаемые строки и форматирование `field_name`. |
| 3 | Статус | Проверено |

Текст после таблицы.
""", encoding="utf-8")
now = datetime.now(timezone.utc)
stamp = lambda value: value.isoformat(timespec="seconds").replace("+00:00", "Z")
history = root / "runs" / f"{routine}.json"
records = json.loads(history.read_text())
records.insert(0, {"id": str(uuid.uuid4()).upper(), "routineID": routine, "trigger": "manual",
                   "harness": "claude", "startedAt": stamp(now - timedelta(seconds=2)), "endedAt": stamp(now),
                   "outcome": {"succeeded": {}}, "logPath": str(log)})
history.write_text(json.dumps(records))
PYTHON
    launch "$appearance"
    check "$DRIVER" exists markdownTable
    capture "UI check $appearance" "$appearance-table"
    for _ in 1 2 3; do "$DRIVER" key command-plus; sleep 0.2; done
    "$DRIVER" window "UI check $appearance" 820 600
    sleep 0.5
    "$DRIVER" reveal markdownTable
    "$DRIVER" scroll-horizontal markdownTable
    sleep 0.5
    table_rect="$("$DRIVER" bounds markdownTable)"
    result_rect="$("$DRIVER" bounds Результат)"
    python3 - "$table_rect" "$result_rect" <<'PYTHON'
import sys
table, result = (list(map(float, value.split())) for value in sys.argv[1:])
assert result[0] >= table[0] - 0.5 and result[0] + result[2] <= table[0] + table[2] + 0.5
PYTHON
    capture "UI check $appearance" "$appearance-table-zoom"
    "$DRIVER" key command-zero
    quit_rota

    # Settings, with each agent's installed copies and versions; the light pass
    # shows the terminal picker on its default, which names the macOS default terminal.
    [[ "$appearance" == light ]] && { defaults delete "$DOMAIN" terminalApp >/dev/null 2>&1 || true; }
    defaults write "$DOMAIN" settingsTab -int 0
    open_rota --env "ROTA_APPEARANCE=$appearance" --env ROTA_OPEN_SETTINGS=1
    sleep 8
    # Preserve the original native Settings toolbar tabs.
    for tab in General Chat Agents; do
        [[ "$tab" == General ]] || { "$DRIVER" press "$tab"; sleep 2; }
        if [[ "$tab" == Chat ]]; then
            check "$DRIVER" aligned Size chatTextSize
            check "$DRIVER" aligned Size chatTextSizeValue
        fi
        if [[ "$tab" == General ]]; then
            "$DRIVER" scroll-wheel General -3000 pixel
            check wait_visible 'Check for Updates…'
        fi
        if [[ "$tab" == Agents ]]; then
            check_agents_scrolling
        fi
        settings_id="$("$DRIVER" wid "$tab")" \
            && screencapture -x -o -l "$settings_id" "$OUT/$appearance-settings-$(echo "$tab" | tr A-Z a-z).png" \
            && pass "captured $appearance-settings-$tab" || fail "captured $appearance-settings-$tab"
        check_layout "settings $tab"
    done
    normal_tab="$("$DRIVER" bounds settingsTab-General)"
    for _ in 1 2 3; do "$DRIVER" key command-plus; sleep 0.2; done
    sleep 1
    large_tab="$("$DRIVER" bounds settingsTab-General)"
    python3 - "$normal_tab" "$large_tab" <<'PYTHON'
import sys
normal, large = (list(map(float, value.split())) for value in sys.argv[1:])
# AX hit frames include fixed native insets and the system font uses optical sizing.
# Content fonts and geometry are checked directly by SettingsTabToolbarTests.
for dimension in (2, 3):
    assert 1.35 <= large[dimension] / normal[dimension] <= 1.65, ("Settings tab zoom", normal, large)
PYTHON
    pass "native Settings tabs grow with live zoom"
    [[ "$("$DRIVER" value settingsTab-Agents)" == Selected ]] || fail "Settings keeps the selected tab across zoom"
    for tab in General Chat Agents; do
        "$DRIVER" press "$tab"; sleep 1
        current_tab="$("$DRIVER" bounds settingsTab-General)"
        python3 - "$large_tab" "$current_tab" <<'PYTHON'
import sys
expected, actual = (list(map(float, value.split())) for value in sys.argv[1:])
assert all(abs(expected[index] - actual[index]) <= 1 for index in (2, 3)), (expected, actual)
PYTHON
        if [[ "$tab" == General ]]; then
            "$DRIVER" scroll-wheel General -3000 pixel
            check wait_visible 'Check for Updates…'
        fi
        if [[ "$tab" == Agents ]]; then
            check_agents_scrolling
        fi
        settings_id="$("$DRIVER" wid "$tab")"
        screencapture -x -o -l "$settings_id" "$OUT/$appearance-settings-$tab-zoom.png"
        check_layout "Settings $tab at 150%"
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
echo "all checks passed"
