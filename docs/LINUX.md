# Linux installer

Build a self-extracting installer on your Linux x64 or arm64 computer:

```sh
./scripts/build-linux-installer.sh
# If Flutter is not on PATH:
FLUTTER_BIN=/opt/flutter/bin/flutter ./scripts/build-linux-installer.sh
```

This builds the Rust backend and Flutter release application, stages their native
libraries/assets, and produces:

```text
dist/narad-linux-x64-release.run
dist/narad-linux-x64-release.run.sha256
```

ARM64 hosts produce `arm64` filenames. Builds target the host architecture; this
script does not cross-compile. A portable `.tar.gz` with its checksum is also
created. Use `debug` for a debug build, or `--skip-build` to wrap the last tarball
created by `scripts/build-linux.sh` without compiling again.

Build prerequisites: Rust 1.88, Flutter 3.44.8, Python 3, Bash, tar, coreutils,
Clang, CMake, Ninja, pkg-config, GTK 3, PulseAudio and ALSA development libraries.
Build on the oldest Linux distribution you intend to support: native glibc and
plugin dependencies are not made portable across older distributions by packaging.

Install on the same architecture, as your regular desktop user:

```sh
cd dist
sha256sum -c narad-linux-x64-release.run.sha256
bash narad-linux-x64-release.run
# Optional installation location:
bash narad-linux-x64-release.run --prefix "$HOME/Apps/Narad"
```

The installer checks its embedded payload before extracting, installs under
`~/.local/opt/narad` by default and adds **Narad** to your application menu.
It needs Bash, Python 3, tar, sha256sum and the app's GTK 3/PulseAudio/ALSA runtime
libraries. It uses no sudo, FUSE, AppImage runtime or package manager. No firewall
rules or background login services are installed.

You can also extract the `.tar.gz` and run its `install.sh`, or launch its
`narad-linux` without installing. The desktop shortcut always launches the
backend and GUI together. Closing the GUI stops the backend it started; an
already authenticated daemon is reused and left running.

State defaults to `${XDG_DATA_HOME:-$HOME/.local/share}/narad`, independently of
the installation folder. Set `NARAD_STATE` to reuse an existing development
identity (for example, the repository's `.narad` directory). Do not copy the same
identity onto another device. `NARAD_DEVICE_NAME`, `NARAD_API_PORT` and
`NARAD_CONTROL_PORT` can customize launch settings.

To update, close Narad and run a new installer with the same prefix. It replaces
only a recognized Narad installation, preserving state and downloads. To uninstall,
close the app, remove its installation directory and
`${XDG_DATA_HOME:-$HOME/.local/share}/applications/dev.narad.narad_client.desktop`.
Delete the separate state directory only if you intend to lose pairings/downloads.

Connect Windows, Linux and Android devices on the same private LAN. Pair using
Nearby devices and configure per-device permissions. Allow TCP 45678/45679 and
UDP 5353 in your firewall if needed; the token-authenticated API on 45700 remains
loopback-only. Actual microphone/camera permissions and desktop session locking
remain subject to your desktop environment.

Validate a built installer without installing into your account:

```sh
python3 tests/linux_packaging.py dist/narad-linux-x64-release.run
```

This uses temporary prefixes/generated data and checks installation, upgrade
preservation, desktop entries with spaces, invalid destinations, corrupted payloads,
and real backend ownership/reuse with a headless GUI fixture. CI repeats the
same checks against its debug bundle.
