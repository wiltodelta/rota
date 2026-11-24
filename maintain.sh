#!/bin/bash
# Canonical quality gate for Rota (Rust workspace): format, file-size check,
# strict clippy, fatal osv-scanner lockfile check, tests, and signed .app bundle.

set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

command -v cargo >/dev/null 2>&1 ||
    { echo "error: cargo is not installed (brew install rustup && rustup default stable)" >&2; exit 1; }
command -v osv-scanner >/dev/null 2>&1 ||
    { echo "error: osv-scanner is not installed (brew install osv-scanner)" >&2; exit 1; }

cargo fmt --all
cargo fmt --all -- --check

# Enforce modular file cap (<= 500 lines per Rust source file).
OVER_LIMIT="$(find crates -name '*.rs' -print0 | xargs -0 wc -l | awk '$2 != "total" && $1 > 500 {print}')"
if [[ -n "$OVER_LIMIT" ]]; then
    echo "error: Rust source files exceed 500-line limit:" >&2
    echo "$OVER_LIMIT" >&2
    exit 1
fi

cargo clippy --workspace --all-targets -- -D warnings
osv-scanner --lockfile=Cargo.lock
cargo test --workspace
./create-app.sh
