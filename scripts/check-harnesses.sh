#!/bin/bash
# Validate the installed adapters without inference. --live also spends vendor quota.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    ""|--live) ;;
    *) echo "Usage: scripts/check-harnesses.sh [--live]" >&2; exit 2 ;;
esac

ROTA_PROTOCOL_CHECK=1 swift test --filter 'HarnessContractTests|HarnessLifecycleTests|InstalledHarnessContractTests'
if [[ "${1:-}" == --live ]]; then
    ROTA_LIVE=1 swift test --filter 'LiveHarnessTests|LiveBridgeTests|LiveRecoveryTests' --skip testEachInstalledTerminalRunsTheScript
    ROTA_LIVE_QUESTIONS=1 swift test --filter LiveQuestionTests
fi
