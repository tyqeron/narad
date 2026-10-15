#!/usr/bin/env bash
# Build a self-extracting, per-user Linux installer. No AppImage/FUSE tooling needed.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mode=release
skip_build=false
for arg in "$@"; do
  case "$arg" in
    release|debug) mode="$arg" ;;
    --skip-build) skip_build=true ;;
    -h|--help)
      echo "Usage: $0 [release|debug] [--skip-build]"
      echo 'Output: dist/narad-linux-<x64|arm64>-<mode>.run and SHA-256 checksum'
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo 'Supported build hosts: Linux x64 and arm64.' >&2; exit 1 ;;
esac
if [[ "$skip_build" != true ]]; then "$repo_root/scripts/build-linux.sh" "$mode"; fi
name="narad-linux-$arch-$mode"
archive="$repo_root/dist/$name.tar.gz"
[[ -f "$archive" ]] || { echo "Bundle missing: $archive" >&2; exit 1; }
# Older development bundles did not include the installer.
tar -tzf "$archive" | awk -v required="$name/install.sh" '$0 == required {found=1} END {exit !found}' || {
  echo 'Rebuild the Linux bundle; install.sh is missing.' >&2; exit 1;
}
checksum="$(sha256sum "$archive" | cut -d ' ' -f 1)"
output="$repo_root/dist/$name.run"
stage="$(mktemp "$repo_root/dist/.linux-installer.XXXXXX")"
trap 'rm -f -- "$stage"' EXIT
cat > "$stage" <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo 'Narad Linux installer'
  echo 'Usage: bash narad-linux-<arch>-<mode>.run [--prefix /absolute/path]'
  echo 'Default: ~/.local/opt/narad, with an application-menu shortcut.'
  echo 'Requires Linux, Bash, Python 3, tar, sha256sum and desktop runtime libraries.'
  exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
payload_line="$(awk '/^__NARAD_PAYLOAD_BELOW__$/ {print NR+1; exit}' "${BASH_SOURCE[0]}")"
[[ -n "$payload_line" ]] || { echo 'Installer payload is missing.' >&2; exit 1; }
tail -n +"$payload_line" "${BASH_SOURCE[0]}" > "$work/bundle.tar.gz"
expected_sha256='@PAYLOAD_SHA256@'
actual_sha256="$(sha256sum "$work/bundle.tar.gz" | cut -d ' ' -f 1)"
[[ "$actual_sha256" == "$expected_sha256" ]] || { echo 'Installer checksum mismatch; download/build it again.' >&2; exit 1; }
# Extract only our embedded installer first; it validates the full archive before installation.
installer_path="$(tar -tzf "$work/bundle.tar.gz" | awk '/^[^/]+\/install\.sh$/ && !found {print; found=1}')"
[[ -n "$installer_path" ]] || { echo 'Installer helper is missing.' >&2; exit 1; }
tar -xOzf "$work/bundle.tar.gz" -- "$installer_path" > "$work/install.sh"
bash "$work/install.sh" "$@" "$work/bundle.tar.gz"
exit 0
__NARAD_PAYLOAD_BELOW__
HEADER
sed -i "s/@PAYLOAD_SHA256@/$checksum/" "$stage"
cat "$archive" >> "$stage"
chmod 755 "$stage"
mv -f -- "$stage" "$output"
(cd "$repo_root/dist" && sha256sum "$name.run" > "$name.run.sha256")
printf 'Linux installer: %s\n' "$output"
printf 'Install with: bash %q\n' "$output"
