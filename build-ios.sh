#!/bin/bash
# build-ios.sh
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

export PATH="$HOME/.cargo/bin:$PATH"

export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/build"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${HOME}=/build"
export TARGET_CFLAGS="${TARGET_CFLAGS:-} -ffile-prefix-map=${HOME}=/build"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/rust-core"

echo "==> Installing iOS targets (if needed)"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

echo "==> Building Rust static libs (release)"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

cd "$ROOT"
echo "==> Repackaging AirliftFFI.xcframework"
rm -rf "$ROOT/AirliftFFI.xcframework"
xcodebuild -create-xcframework \
  -library rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a \
  -headers rust-core/include \
  -library rust-core/target/aarch64-apple-ios-sim/release/libairlift_ffi.a \
  -headers rust-core/include \
  -output "$ROOT/AirliftFFI.xcframework"

echo "==> Done."
