#!/usr/bin/env bash
# Run on a Mac with Xcode, Flutter, Rust and an iOS signing team configured.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Build iOS on macOS with Xcode.' >&2; exit 1; }
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export IPHONEOS_DEPLOYMENT_TARGET=15.0
flutter_bin="${FLUTTER_BIN:-flutter}"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo build --release --locked -p narad-mobile --target aarch64-apple-ios
cargo build --release --locked -p narad-mobile --target aarch64-apple-ios-sim
cargo build --release --locked -p narad-mobile --target x86_64-apple-ios
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
lipo -create target/aarch64-apple-ios-sim/release/libnarad_mobile.a target/x86_64-apple-ios/release/libnarad_mobile.a -output "$stage/libnarad_mobile.a"
# Headers are part of the C ABI; no Swift calls into private iOS APIs.
mkdir "$stage/headers"
cp clients/flutter/ios/Runner/narad_mobile.h "$stage/headers/"
framework=clients/flutter/ios/Runner/NaradMobile.xcframework
rm -rf -- "$framework"
xcodebuild -create-xcframework -library target/aarch64-apple-ios/release/libnarad_mobile.a -headers "$stage/headers" -library "$stage/libnarad_mobile.a" -headers "$stage/headers" -output "$framework"
cd clients/flutter
"$flutter_bin" pub get
if [[ "${1:-}" == --simulator ]]; then
  "$flutter_bin" build ios --simulator
else
  "$flutter_bin" build ios --release
fi
