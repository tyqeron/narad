#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-release}"
case "$mode" in
  release) cargo_args=(--release); profile=release ;;
  debug) cargo_args=(); profile=debug ;;
  *) echo "Usage: $0 [release|debug]" >&2; exit 2 ;;
esac
[[ "$(uname -s)" == Linux ]] || { echo 'Build this package on Linux.' >&2; exit 1; }
case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo 'Flutter Linux packaging supports x64 or arm64 hosts.' >&2; exit 1 ;;
esac
flutter_bin="${FLUTTER_BIN:-flutter}"
cargo_bin="${CARGO_BIN:-cargo}"
command -v "$flutter_bin" >/dev/null || { echo 'Set FLUTTER_BIN to your Flutter executable.' >&2; exit 1; }
cd -- "$repo_root"
# Use a known output path even when the invoking shell has CARGO_TARGET_DIR set.
CARGO_TARGET_DIR="$repo_root/target" "$cargo_bin" build --locked -p narad "${cargo_args[@]}"
(cd clients/flutter && "$flutter_bin" pub get && "$flutter_bin" build linux "--$mode")
bundle="$repo_root/clients/flutter/build/linux/$arch/$mode/bundle"
[[ -x "$bundle/narad_client" ]] || { echo "Flutter bundle missing: $bundle" >&2; exit 1; }
mkdir -p dist
stage="$(mktemp -d "$repo_root/dist/.linux-build.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
name="narad-linux-$arch-$mode"
package="$stage/$name"
mkdir -p "$package/app"
cp -a -- "$bundle/." "$package/app/"
install -m 755 "target/$profile/narad" "$package/narad"
install -m 755 scripts/linux-launcher.sh "$package/narad-linux"
ln -s narad-linux "$package/run.sh"
install -m 755 scripts/install-linux.sh "$package/install.sh"
install -m 644 docs/LINUX.md "$package/README.md"
install -m 644 clients/flutter/assets/branding/MaterialIcons_LICENSE.txt "$package/MaterialIcons_LICENSE.txt"
# Publish the archive only after staging is complete; existing state is never in a bundle.
tar -czf "$stage/$name.tar.gz" -C "$stage" "$name"
mv -f -- "$stage/$name.tar.gz" "dist/$name.tar.gz"
(cd dist && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
printf 'Linux bundle: %s/dist/%s.tar.gz\n' "$repo_root" "$name"
