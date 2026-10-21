#!/bin/bash
# Regenerate README images from synthetic data. Never runs a routine or an agent.
# Requires Accessibility and Screen Recording for the invoking terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/Rota.app"
DOMAIN="com.wiltodelta.rota.dev"
OUT="${ROTA_SCREENSHOT_OUT:-$ROOT/docs/screenshots}"
AUDIT="${ROTA_MACAUDIT:-$HOME/Documents/GitHub/claude-config/skills/ui-audit-macos/scripts/macaudit.py}"
[[ -f "$AUDIT" ]] || { echo "Set ROTA_MACAUDIT to the shared macaudit.py helper." >&2; exit 1; }
if pgrep -f "$APP/Contents/MacOS/Rota" >/dev/null; then
    echo "Close the repository's development build before capturing." >&2
    exit 1
fi
uv run "$AUDIT" preflight --require-unlocked
uv run "$AUDIT" notice start --app Rota --purpose "Preparing README screenshots" \
    --text "Capturing Rota. Please don't click or type."
WORK="$(mktemp -d /tmp/rota-screenshots.XXXXXX)"
HAD_DEFAULTS=0
if defaults export "$DOMAIN" "$WORK/defaults.plist" 2>/dev/null; then HAD_DEFAULTS=1; fi
PID=""
quit_dev() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        for _ in {1..40}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$PID" 2>/dev/null; then echo "Development build did not exit." >&2; return 1; fi
    fi
    PID=""
}
cleanup() {
    quit_dev
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    if [[ "$HAD_DEFAULTS" == 1 ]]; then
        defaults import "$DOMAIN" "$WORK/defaults.plist"
        defaults export "$DOMAIN" "$WORK/restored.plist"
        python3 - "$WORK/defaults.plist" "$WORK/restored.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as before, open(sys.argv[2], "rb") as after:
    assert plistlib.load(before) == plistlib.load(after), "Development defaults were not restored"
PY
    fi
    uv run "$AUDIT" notice stop
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'echo "Capture failed at line $LINENO" >&2' ERR
./create-app.sh
swiftc -O scripts/ui-driver.swift -o "$WORK/driver"
swiftc -O scripts/capture-window.swift -o "$WORK/capture"
mkdir -p "$OUT"
drive() {
    uv run "$AUDIT" preflight --require-unlocked >/dev/null
    uv run "$AUDIT" notice run -- "$WORK/driver" "$@"
}
capture() {
    local name="$1" title="$2" width="${3:-1000}"
    drive window "$title" "$width" 680
    drive focus routineSidebar
    sleep 1
    local bounds verdict
    bounds="$("$WORK/driver" bounds "$title")"
    awk -v expected="$width" 'NF == 4 {exit !($3 == expected && $4 == 680)}' <<< "$bounds"
    verdict="$("$WORK/driver" gate)"
    [[ "${verdict##*$'\n'}" == "0 violations" ]] || { echo "$verdict" >&2; return 1; }
    uv run "$AUDIT" notice run -- "$WORK/capture" "$("$WORK/driver" wid "$title")" \
        "$appearance" "$OUT/$name-$appearance.png"
    echo "Captured $name-$appearance ($bounds; 0 layout violations)"
}
for appearance in light dark; do
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    # Do not let launch-time model discovery initialize the real agent backends.
    defaults write "$DOMAIN" executables -dict claude "$WORK/no-agent" codex "$WORK/no-agent" \
        grok "$WORK/no-agent" antigravity "$WORK/no-agent"
    python3 scripts/screenshot-fixtures.py "$WORK/data"
    uv run "$AUDIT" preflight --require-unlocked >/dev/null
    uv run "$AUDIT" notice run -- open --env "ROTA_DATA_DIR=$WORK/data" \
        --env "ROTA_APPEARANCE=$appearance" "$APP"
    sleep 3
    PID="$(pgrep -f "$APP/Contents/MacOS/Rota")"
    [[ -n "$PID" && "$PID" != *$'\n'* ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" == "$DOMAIN" ]]
    uv run "$AUDIT" notice run -- open "$APP"
    sleep 2
    drive exists showSessionRoutine
    capture sessions 'Daily code review'
    capture sessions-minimum 'Daily code review' 820
    drive select 'Weekly project report' 2
    sleep 1
    drive exists questionCard
    drive press questionOption-format-short
    capture questions 'Weekly project report' 820
    drive press showSessionRoutine
    sleep 1
    capture schedule 'Weekly project report' 820
    quit_dev
done
