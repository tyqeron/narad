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
libraries. It uses no sudo, FUSE, AppImage runtime or package manager. No firewall rules or system services are installed. A per-user desktop
autostart entry starts Narad quietly when you sign in after reboot.

You can also extract the `.tar.gz` and run its `install.sh`, or launch its
`narad-linux` without installing. The desktop shortcut always launches the
backend and GUI together. Closing the window hides it and keeps the app/backend connected. Open Narad
again from the application menu or tray to restore it. **Quit Narad** in Settings
or the tray stops the app and its owned backend; an externally owned daemon is
left running. Desktop shells without a legacy tray still support reopening from
the menu and quitting in Settings.

State defaults to `${XDG_DATA_HOME:-$HOME/.local/share}/narad`, independently of
the installation folder. Set `NARAD_STATE` to reuse an existing development
identity (for example, the repository's `.narad` directory). Do not copy the same
identity onto another device. `NARAD_DEVICE_NAME`, `NARAD_API_PORT` and
`NARAD_CONTROL_PORT` can customize launch settings.

To update, use **Quit Narad** and run a new installer with the same prefix. It replaces
only a recognized Narad installation, preserving state and downloads. To uninstall,
quit the app, remove its installation directory and
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

**Settings → Background operation → Start after login** enables/disables the
per-user autostart file under `${XDG_CONFIG_HOME:-$HOME/.config}/autostart`.
Its disabled preference survives upgrades. Remove the Narad autostart entry when
uninstalling. `--background` starts with the window hidden. This runs after user
login, not before authentication or as a root/system daemon. Clipboard delivery
and commands continue while the desktop app is hidden.

Native close/reopen regression checks can run without using your desktop:

```sh
xvfb-run -a dbus-run-session -- python3 tests/linux_background.py clients/flutter/build/linux/x64/release/bundle
```

This needs Xvfb, xdotool, D-Bus and a built debug backend at `target/debug/narad`.
It forces X11 within the isolated display and uses a temporary identity.

## Camera sharing

Update Narad on both devices and fully quit/reopen the desktop app after upgrading
so its background daemon also uses the fix. Camera signaling now uses the camera
permission; it does not require audio access. On the device providing video, allow
**Share this device’s camera** for the viewer and keep Narad open. On the viewer,
choose **View camera**; video appears in Media. A desktop source needs an accessible
webcam and operating-system camera permission. An empty camera stream now reports
an error instead of starting a session without video.

The opt-in physical Android-to-Linux camera check is:

```sh
FLUTTER_BIN=/path/to/flutter python3 tests/android_e2e.py --serial DEVICE_SERIAL --pairing nearby --desktop-camera
```

Install and open the normal debug APK first, with camera permission enabled on
Android. The test uses a temporary pairing and streams live video to a test window
(or Xvfb); it never records video or captures audio. Generated trust is removed.

Phone companion setup, platform support and cellular audio limitations: [Phone integration](PHONE_INTEGRATION.md).

## Find device

Enable **Ring this device (Find device)** for a paired requester in Device settings.
From an online device's actions choose **Find device** to ring for up to 30 seconds,
or **Stop ringing** to end it. Both endpoints need the updated app. Keep Narad's
background/tray service running. This uses the existing LAN connection; there is
no GPS tracking or offline wake-up. See [Find device](FIND_DEVICE.md) for platform
requirements, local Stop controls and volume/DND limitations.
Linux playback requires paplay, aplay or ffplay on PATH.

Phone speaker playback and meeting microphone/camera setup: [Meeting devices](MEETING.md).


### Choose shared directories per device (build 15)

Open Devices, select a paired device, then use its top-right settings button.
Under **Directories shared with this device**, select existing folders or choose
**Share a directory with this device**. You can also use **Media → Shared folders
→ Choose devices** on each folder. Selections persist for offline devices.
The device still needs browse permission and, for writes, upload permission plus
the folder upload switch. Existing folders, including the app Shared folder,
require explicit device selection after upgrading; their files are preserved.
