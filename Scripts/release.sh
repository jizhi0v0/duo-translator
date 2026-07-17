#!/bin/bash
# Build, sign (Developer ID), notarize, staple, and package DuoTranslator.
#
# One-time setup:
#   xcrun notarytool store-credentials duo-notary \
#     --apple-id <apple-id-email> --team-id RS59HDH7Y3
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -project DuoTranslator.xcodeproj \
  -scheme DuoTranslator \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  clean build

APP="build/DerivedData/Build/Products/Release/DuoTranslator.app"

echo "==> Verifying code signature"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing"
ditto -c -k --keepParent "$APP" build/DuoTranslator.zip
xcrun notarytool submit build/DuoTranslator.zip --keychain-profile duo-notary --wait
xcrun stapler staple "$APP"

echo "==> Packaging DMG"
rm -f build/DuoTranslator.dmg
hdiutil create -volname DuoTranslator -srcfolder "$APP" -ov -format UDZO build/DuoTranslator.dmg

echo "==> Gatekeeper check"
spctl -a -vv "$APP"

echo "Done: build/DuoTranslator.dmg"
