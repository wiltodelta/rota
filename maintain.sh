#!/bin/bash
# The canonical gate: lint with fixes, tests, then a release build.
set -e
cd "$(dirname "$0")"

if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --fix
    # `--fix` prints only what it corrected; fail on what it could not fix.
    swiftlint lint --strict --quiet
else
    echo "swiftlint not installed, skipping lint (brew install swiftlint)"
fi

swift test
swift build -c release
