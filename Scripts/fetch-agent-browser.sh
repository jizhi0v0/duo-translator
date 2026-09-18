#!/bin/bash
# Fetch the agent-browser CLI (Apache-2.0) and lipo the two macOS arch binaries
# into a single universal2 executable under Vendor/, for bundling into the app.
#
# Idempotent: skips the download when the universal binary for the pinned
# version already exists. Bump AB_VERSION to update; delete Vendor/agent-browser
# to force a re-fetch.
set -euo pipefail
cd "$(dirname "$0")/.."

AB_VERSION="v0.32.4"
REPO="vercel-labs/agent-browser"
OUT_DIR="Vendor/agent-browser"
BIN="$OUT_DIR/agent-browser"
STAMP="$OUT_DIR/.version"

# Expected sizes (bytes) from the v0.32.4 release, as a light integrity check.
ARM64_SIZE=11437856
X64_SIZE=12517808

if [[ -f "$BIN" && -f "$STAMP" && "$(cat "$STAMP")" == "$AB_VERSION" ]]; then
  echo "agent-browser $AB_VERSION already vendored → $BIN"
  exit 0
fi

mkdir -p "$OUT_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

base="https://github.com/$REPO/releases/download/$AB_VERSION"
echo "==> Downloading agent-browser $AB_VERSION (arm64 + x64)"
curl -fL --retry 3 -o "$tmp/arm64" "$base/agent-browser-darwin-arm64"
curl -fL --retry 3 -o "$tmp/x64"   "$base/agent-browser-darwin-x64"

check_size() { # file expected
  local actual; actual="$(stat -f%z "$1")"
  if [[ "$actual" != "$2" ]]; then
    echo "!! size mismatch for $1: got $actual, expected $2" >&2; exit 1
  fi
}
check_size "$tmp/arm64" "$ARM64_SIZE"
check_size "$tmp/x64"   "$X64_SIZE"

echo "==> lipo → universal2"
lipo -create "$tmp/arm64" "$tmp/x64" -output "$BIN"
chmod +x "$BIN"

echo "==> Fetching LICENSE"
curl -fL --retry 3 -o "$OUT_DIR/LICENSE" \
  "https://raw.githubusercontent.com/$REPO/$AB_VERSION/LICENSE" || \
  echo "(LICENSE fetch failed — add manually before release)"

echo "$AB_VERSION" > "$STAMP"
echo "Done: $BIN"
lipo -info "$BIN"
