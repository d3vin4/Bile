#!/bin/bash
set -euo pipefail

CONFIG="${1:-Release}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Building Bile ($CONFIG)..."
rm -rf build/DerivedData build/Payload build/*.app build/*.ipa
mkdir -p build

xcodebuild -project Bile.xcodeproj \
    -scheme Bile \
    -configuration "$CONFIG" \
    -derivedDataPath build/DerivedData \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

APP_PATH="$(find build/DerivedData/Build/Products -name "Bile.app" -type d | head -n 1)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: Bile.app not found in DerivedData"
    exit 1
fi

echo "==> Packaging IPA..."
cp -R "$APP_PATH" build/Bile.app

rm -rf build/Bile.app/_CodeSignature
rm -rf build/Bile.app/embedded.mobileprovision

mkdir -p build/Payload
cp -R build/Bile.app build/Payload/Bile.app

cd build
zip -qr "Bile.ipa" Payload
rm -rf Payload Bile.app

echo "==> Done! IPA generated at: $ROOT/build/Bile.ipa"
ls -lh "$ROOT/build/Bile.ipa"
