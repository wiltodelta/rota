#!/bin/bash
# Canonical quality gate for Rota (Rust engine + SwiftUI/AppKit UI):
# rustfmt, 500-line Rust cap, strict clippy, fatal osv-scanner, Rust tests,
# SwiftLint with fixes, Swift tests, Python script tests, and signed .app bundle.

set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

command -v cargo >/dev/null 2>&1 ||
    { echo "error: cargo is not installed (brew install rustup && rustup default stable)" >&2; exit 1; }
command -v osv-scanner >/dev/null 2>&1 ||
    { echo "error: osv-scanner is not installed (brew install osv-scanner)" >&2; exit 1; }
command -v swiftlint >/dev/null 2>&1 ||
    { echo "error: swiftlint is not installed (brew install swiftlint)" >&2; exit 1; }

cargo fmt --all
cargo fmt --all -- --check

OVER_LIMIT="$(find crates -name '*.rs' -print0 | xargs -0 wc -l | awk '$2 != "total" && $1 > 500 {print}')"
if [[ -n "$OVER_LIMIT" ]]; then
    echo "error: Rust source files exceed 500-line limit:" >&2
    echo "$OVER_LIMIT" >&2
    exit 1
fi

cargo clippy --workspace --all-targets -- -D warnings
osv-scanner --lockfile=Cargo.lock
cargo test --workspace

cargo build --release --target aarch64-apple-darwin -p rota-ffi
mkdir -p target/swift-ffi
cp target/aarch64-apple-darwin/release/librota_ffi.a target/swift-ffi/librota_ffi.a

swiftlint lint --fix
swiftlint lint --strict --quiet

swift test --disable-automatic-resolution
python3 -B -m unittest discover -s scripts/tests -v
./create-app.sh
