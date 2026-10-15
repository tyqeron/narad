#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter_bin="${FLUTTER_BIN:-flutter}"
mode="${1:-release}"
if [[ "$mode" != release && "$mode" != debug ]]; then
  echo "Usage: $0 [release|debug]" >&2
  exit 2
fi
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cd clients/flutter
"$flutter_bin" pub get
"$flutter_bin" build apk "--$mode"
cd ../..
python3 scripts/verify-android-apk.py "clients/flutter/build/app/outputs/flutter-apk/app-$mode.apk"
mkdir -p dist
cp "clients/flutter/build/app/outputs/flutter-apk/app-$mode.apk" "dist/narad-android-$mode.apk"
(cd dist && sha256sum "narad-android-$mode.apk" > "narad-android-$mode.apk.sha256")
printf 'APK: %s/dist/narad-android-%s.apk\n' "$PWD" "$mode"
