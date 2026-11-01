#!/bin/bash
set -euo pipefail

CONFIG="${1:-Release}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Building Readipa ($CONFIG)..."
rm -rf build/DerivedData build/Payload build/*.app build/*.ipa
mkdir -p build

xcodebuild -project Readipa.xcodeproj \
    -scheme Readipa \
    -configuration "$CONFIG" \
    -derivedDataPath build/DerivedData \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

APP_PATH="$(find build/DerivedData/Build/Products -name "Readipa.app" -type d | head -n 1)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: Readipa.app not found in DerivedData"
    exit 1
fi

echo "==> Packaging IPA..."
cp -R "$APP_PATH" build/Readipa.app

rm -rf build/Readipa.app/_CodeSignature
rm -rf build/Readipa.app/embedded.mobileprovision

mkdir -p build/Payload
cp -R build/Readipa.app build/Payload/Readipa.app

cd build
zip -qr "Readipa.ipa" Payload
rm -rf Payload Readipa.app

echo "==> Done! IPA generated at: $ROOT/build/Readipa.ipa"
ls -lh "$ROOT/build/Readipa.ipa"
