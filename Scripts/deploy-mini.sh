#!/bin/bash
# Build Release and push it to the Mac mini over SSH (Tailscale).
#
# rsync/scp don't set the quarantine attribute, so the Developer ID-signed
# build runs on the mini without notarization. The code signature is stable
# across versions, so TCC grants (Accessibility / Screen Recording) on the
# mini survive updates.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${1:-bobbys-mac-mini}"

xcodegen generate
xcodebuild -project DuoTranslator.xcodeproj \
  -scheme DuoTranslator \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build

APP="build/DerivedData/Build/Products/Release/DuoTranslator.app"

echo "==> Deploying to $HOST"
ssh "$HOST" 'pkill -x DuoTranslator || true'
rsync -az --delete "$APP" "$HOST:/Applications/"
ssh "$HOST" 'open /Applications/DuoTranslator.app'
echo "Done: DuoTranslator updated and relaunched on $HOST"
