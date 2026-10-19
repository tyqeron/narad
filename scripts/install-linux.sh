#!/usr/bin/env bash
# Included in the bundle and called by the self-extracting installer.
set -euo pipefail
[[ "$EUID" -ne 0 ]] || { echo 'Run this per-user installer as your desktop user, without sudo.' >&2; exit 1; }
prefix="${HOME:?HOME is required}/.local/opt/narad"
archive=""
usage() { echo 'Usage: install-linux.sh [--prefix /absolute/path] [bundle.tar.gz]'; }
while (($#)); do
  case "$1" in
    --prefix) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; prefix="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [[ -z "$archive" ]] || { usage >&2; exit 2; }; archive="$1"; shift ;;
  esac
done
# Desktop Exec escaping below supports spaces/quotes/backslashes. Reject control
# characters so an installation path cannot inject additional desktop entries.
[[ "$prefix" == /* && "$prefix" != / && "$prefix" != *[[:cntrl:]]* ]] || {
  echo 'Choose an absolute installation directory without control characters.' >&2; exit 2;
}
[[ ! -L "$prefix" ]] || { echo 'Installation destination must not be a symbolic link.' >&2; exit 1; }
prefix="$(realpath -m -- "$prefix")"
[[ "$prefix" != / ]] || { echo 'Cannot install into the filesystem root.' >&2; exit 1; }
parent="$(dirname -- "$prefix")"
mkdir -p -- "$parent"
parent="$(cd -- "$parent" && pwd)"
prefix="$parent/$(basename -- "$prefix")"
[[ ! -L "$prefix" ]] || { echo 'Installation destination must not be a symbolic link.' >&2; exit 1; }
if [[ -e "$prefix" && ! -f "$prefix/.narad-install" ]]; then
  echo "Refusing to replace an unrecognized directory: $prefix" >&2; exit 1
fi
work="$(mktemp -d)"
stage="$(mktemp -d "$parent/.narad-stage.XXXXXX")"
backup=""
cleanup() {
  rm -rf -- "$work" "$stage"
  if [[ -n "$backup" && -d "$backup" && ! -e "$prefix" ]]; then mv -- "$backup" "$prefix"; fi
}
trap cleanup EXIT
if [[ -n "$archive" ]]; then
  # Validate all entries before extraction; archives must contain one plain bundle.
  python3 - "$archive" "$work" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    members = archive.getmembers()
    roots = set()
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not path.parts:
            raise SystemExit('Unsafe archive path')
        roots.add(path.parts[0])
        if member.issym():
            if member.linkname != 'narad-linux' or path.name != 'run.sh':
                raise SystemExit('Unexpected archive symlink')
        elif not (member.isdir() or member.isfile()):
            raise SystemExit('Unsupported archive entry')
    if len(roots) != 1:
        raise SystemExit('Expected one bundle directory')
    archive.extractall(sys.argv[2], members=members)
PY
  shopt -s nullglob
  roots=("$work"/*)
  source_dir="${roots[0]}"
else
  source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
for required in narad narad-linux app/narad_client app/data/narad.png; do
  [[ -f "$source_dir/$required" ]] || { echo "Incomplete bundle: $required missing" >&2; exit 1; }
done
cp -a -- "$source_dir/." "$stage/"
printf '%s\n' 'Narad managed installation v1' > "$stage/.narad-install"
# Prepare shortcuts before swapping an existing installation.
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p -- "$data_home/applications"
# Desktop-entry strings have a second escaping layer in Exec. %% is a literal %.
python3 - "$stage/narad.desktop" "$prefix" <<'PY'
import sys
from pathlib import Path
prefix = sys.argv[2]
def string(value):
    return value.replace('\\', '\\\\')
def argument(value):
    value = value.replace('%', '%%')
    for char in ['\\', '"', '`', '$']:
        value = value.replace(char, '\\' + char)
    return string('"' + value + '"')
Path(sys.argv[1]).write_text('[Desktop Entry]\nType=Application\nName=Narad\n'
    'Comment=Connect your trusted nearby devices\n'
    f'Exec={argument(prefix + "/narad-linux")} --share %F\n'
    f'Icon={string(prefix + "/app/data/narad.png")}\n'
    'Terminal=false\nCategories=Network;Utility;\nStartupNotify=true\n'
    'MimeType=text/uri-list;text/plain;application/octet-stream;application/pdf;application/zip;application/x-7z-compressed;application/x-tar;application/msword;application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/vnd.ms-excel;application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;application/vnd.ms-powerpoint;application/vnd.openxmlformats-officedocument.presentationml.presentation;image/*;video/*;audio/*;x-scheme-handler/http;x-scheme-handler/https;\n')
PY
if [[ -e "$prefix" ]]; then
  backup="$(mktemp -d "$parent/.narad-old.XXXXXX")"
  rmdir -- "$backup"
  mv -- "$prefix" "$backup"
fi
mv -- "$stage" "$prefix"
install -m 644 "$prefix/narad.desktop" "$data_home/applications/dev.narad.narad_client.desktop"
# File managers have separate Send To registries; installing an application
# desktop entry alone does not populate these menus.
python3 - "$prefix/narad.desktop" "$data_home" <<'PY_SENDTO'
import sys
from pathlib import Path
entry = Path(sys.argv[1]).read_text()
data = Path(sys.argv[2])
for relative in ['Thunar/sendto/narad.desktop', 'caja/sendto/narad.desktop']:
    target = data / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(entry)
target = data / 'kio/servicemenus/narad.desktop'
target.parent.mkdir(parents=True, exist_ok=True)
execute = next(line for line in entry.splitlines() if line.startswith('Exec='))
icon = next(line for line in entry.splitlines() if line.startswith('Icon='))
target.write_text('[Desktop Entry]\nType=Service\nMimeType=all/allfiles;\n'
                  'X-KDE-ServiceTypes=KonqPopupMenu/Plugin\nActions=narad;\n'
                  '\n[Desktop Action narad]\nName=Share with Narad\n'
                  + icon + '\n' + execute + '\n')
target.chmod(0o755)
PY_SENDTO
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
mkdir -p -- "$config_home/autostart"
if [[ ! -e "$config_home/narad/autostart-disabled" ]]; then
  python3 - "$prefix/narad.desktop" "$config_home/autostart/dev.narad.narad_client.desktop" <<'PY_STARTUP'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
lines = [line + ' --background' if line.startswith('Exec=') else line for line in lines]
Path(sys.argv[2]).write_text('\n'.join(lines) + '\nX-GNOME-Autostart-enabled=true\n')
PY_STARTUP
else
  rm -f -- "$config_home/autostart/dev.narad.narad_client.desktop"
fi
if [[ -n "$backup" ]]; then rm -rf -- "$backup"; backup=""; fi
if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$data_home/applications" >/dev/null 2>&1 || true
fi
printf 'Installed Narad: %s\nOpen Narad from your application menu, or run:\n  %q\n' "$prefix" "$prefix/narad-linux"
printf 'Identity and pairings stay in ${XDG_DATA_HOME:-$HOME/.local/share}/narad. Received files go to Downloads/Narad.\n'
