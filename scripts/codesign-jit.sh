#!/bin/bash
# Re-codesign the swift-js binary with the allow-jit entitlement so
# JavaScriptCore's high-tier JIT (FTL) can run. Without this, tight
# pure-JS loops are ~14× slower.
#
# Usage: scripts/codesign-jit.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HERE/.build/$CONFIG/swift-js"
ENT="$HERE/Sources/swift-js/Resources/swift-js.entitlements"

if [[ ! -x "$BIN" ]]; then
    echo "swift-js binary not found at $BIN — run \`swift build -c $CONFIG\` first." >&2
    exit 1
fi
if [[ ! -f "$ENT" ]]; then
    echo "Entitlements file missing: $ENT" >&2
    exit 1
fi

codesign --force --sign - --entitlements "$ENT" "$BIN"
echo "Re-signed $BIN with JIT entitlements."
codesign -d --entitlements - "$BIN" 2>&1 | grep -E "allow-jit|allow-unsigned" || true
