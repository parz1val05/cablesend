#!/usr/bin/env bash
# Builds libcablesend.so for Android and drops it where Flutter/Gradle picks it up.
# Needs: rustup, Android NDK (ANDROID_NDK_HOME), `cargo install cargo-ndk`.
set -euo pipefail
cd "$(dirname "$0")/.."
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o app/android/app/src/main/jniLibs build --release --lib
echo "OK: app/android/app/src/main/jniLibs/*/libcablesend.so"
