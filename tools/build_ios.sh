#!/usr/bin/env bash
# Builds the static core for iOS and packs it as an XCFramework. Run on a Mac with Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo build --release --lib --target aarch64-apple-ios
cargo build --release --lib --target aarch64-apple-ios-sim
cargo build --release --lib --target x86_64-apple-ios
mkdir -p target/ios-sim
lipo -create target/aarch64-apple-ios-sim/release/libcablesend.a \
             target/x86_64-apple-ios/release/libcablesend.a -output target/ios-sim/libcablesend.a
rm -rf app/ios/CableSendCore.xcframework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libcablesend.a \
  -library target/ios-sim/libcablesend.a \
  -output app/ios/CableSendCore.xcframework
echo "OK: app/ios/CableSendCore.xcframework (see NATIVE.md for the Xcode steps)"
