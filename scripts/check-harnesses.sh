#!/bin/bash
# Validate the installed adapters and protocol contracts without inference.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

case "${1:-}" in
    ""|--live) ;;
    *) echo "Usage: scripts/check-harnesses.sh [--live]" >&2; exit 2 ;;
esac

ROTA_PROTOCOL_CHECK=1 cargo test -p rota-core -p rota-cli
if [[ "${1:-}" == --live ]]; then
    ROTA_LIVE=1 cargo test -p rota-core -- --ignored
fi
