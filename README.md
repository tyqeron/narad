# Narad

Local-first device discovery, pairing, file transfer, clipboard sharing and
permissioned audio/camera sharing and device controls. A portable Rust core owns trust and protocol decisions; a
Flutter client provides the interface and native WebRTC media adapter. No
account, cloud signaling, STUN or TURN service is required.

This is a development implementation of the [product plan](PRD.md). Linux and
Android builds are available. Windows runner, native backend support and packaging
are implemented; Windows-native builds and physical QA are pending. iOS still needs platform work.
See [implementation status](docs/IMPLEMENTATION_STATUS.md).

## Run on Android

Build an installable APK with `./scripts/build-android.sh`, then install
`dist/narad-android-release.apk` on each Android 8.0+ phone or tablet. The backend
starts inside the app. On the same Wi-Fi, select **Send pairing request** under
Nearby devices, then **Accept request** in the receiver’s Inbox.

See [Android setup and multi-device testing](docs/ANDROID.md) for build requirements,
installation, device checks, and troubleshooting.

## Run on Windows

On Windows 10/11 x64 with Rust, Flutter and Visual Studio C++ tools installed:

```powershell
.\scripts\build-windows.ps1
```

Extract `dist/narad-windows-x64-release.zip` and open `narad_client.exe`.
It starts the bundled backend automatically. The optional installer adds a Start
menu shortcut. See [Windows setup and testing](docs/WINDOWS.md).

## Run on Linux

Build a per-user Linux installer with `./scripts/build-linux-installer.sh`.
Run the resulting `dist/narad-linux-x64-release.run` (or `arm64`) to install
Narad and its application-menu shortcut. See [Linux installer details](docs/LINUX.md).


Prerequisites: Rust 1.88+, Flutter 3.44.8 (Dart 3.12.2), Python 3 for integration tests, and
Flutter's Linux native build dependencies (Clang, CMake, Ninja, pkg-config,
GTK 3 and PulseAudio development libraries). The WebRTC plugin downloads its
native library during the first build.

```sh
./scripts/dev-linux.sh "My laptop"
```

Or start the daemon from the repository root:

```sh
cargo run -p narad -- serve --name "My laptop"
```

In a second terminal:

```sh
cd clients/flutter
flutter pub get
flutter run -d linux
```

The client defaults to `../../.narad` when launched from its project directory.
For a packaged app, enter the absolute daemon state path on the connection
screen. `NARAD_STATE` can prefill that path.

Repeat on a second computer on the same private IPv4 LAN. Allow inbound TCP
45678 (control), TCP 45679 (files), and UDP 5353 (mDNS) as needed. The local API
on TCP 45700 binds only to loopback and requires a private token.

## Use the app

1. Under **Nearby devices**, select **Send pairing request**. On the receiver,
   open **Inbox**, recognize the device and compare the displayed code, then
   select **Accept request**. Both devices pair automatically. No code entry or
   QR scan is needed. Invitations and QR remain available as a fallback.
2. Paired devices are grouped into **Online** and **Offline** using authenticated
   connection checks. Open **Device settings** on a paired device to allow what
   that device may do on this one: files, clipboard, audio, camera, browsing,
   command presets, locking and unlocking. Grants persist across restarts;
   enabled capabilities do not ask for another app approval on each request.
3. Without a persistent file grant, accept a file in Inbox and retry **Send / resume**.
   With the grant, the first send transfers automatically. Completed files appear
   under `.narad/downloads/<transfer-id>/<file-name>`; Android has **Save to device**.
4. Use **Settings → Shared folder** to add files that permitted peers can browse
   and download. This folder is separate from private identity and settings data.
   Configure command presets in Settings on the target device; peers can execute
   those presets, with a ten-second limit, rather than submitting arbitrary commands.
5. Enable the required adapter in **Media** for audio or camera, grant the peer
   access, and keep both clients foregrounded. Stop or revoke to end a stream.
   Clipboard sending is manual; granted deliveries are applied automatically.
6. Android locking needs optional device-admin activation. Unlock requests open
   a notification leading to system authentication; a PIN/password is never bypassed.
   Linux session controls use `loginctl` and depend on the desktop session.
7. **Settings → Appearance** defaults to **Device**; choose **Light** or **Dark**
   for a saved override. **Activity** groups readable events by day and category.

Invitations expire after five minutes. Discovery is optional: invitation entry
works when multicast is blocked. Android supports camera QR scanning; desktop
supports pasted invitations.
Standalone short-code discovery is not yet implemented.

Desktop installations start quietly after login and stay connected when their
window closes. Reopen Narad from the menu/tray; use **Quit Narad** to exit.
**Settings → Start after login** controls startup. On Android, add **Narad Devices**
from your launcher's Widgets picker to access a paired device's actions from home.
The ongoing Android notification lists authenticated connected devices.

## CLI

```sh
cargo run -p narad -- --help
cargo run -p narad -- invite > /tmp/narad-invitation.json
cargo run -p narad -- pair /tmp/narad-invitation.json
cargo run -p narad -- approve-pair <pair-id> <code>   # receiver
cargo run -p narad -- confirm-pair <pair-id> <code>   # sender
cargo run -p narad -- status
cargo run -p narad -- send <peer-id> /path/to/file
cargo run -p narad -- accept-file <transfer-id>      # receiver
cargo run -p narad -- send <peer-id> /path/to/file --id <transfer-id>
cargo run -p narad -- permission <peer-id> clipboard.sync --allow
cargo run -p narad -- clipboard <peer-id> "Text to share"
cargo run -p narad -- accept-clipboard <clipboard-id>
cargo run -p narad -- unpair <peer-id>
```

Use `--state /absolute/path` and `--api-port <port>` for a non-default daemon.
For two daemons on one computer, give each a distinct state directory and
control/file/API port combination. Do not use the same identity directory on
multiple devices.

## Verify and trace development

```sh
cargo fmt --all --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build --workspace --locked
python3 tests/e2e.py
NARAD_TEST_MDNS=1 python3 tests/e2e.py  # optional multicast integration
python3 scripts/check-dependencies.py  # public OSV advisory check; needs network
cd clients/flutter
flutter analyze
flutter test
flutter build linux --debug
```

The integration suite launches two real daemon processes, tests TLS and
permissions, interrupts an 8 MiB transfer, restarts both peers, and verifies the
resumed file byte-for-byte. Multicast checks are opt-in for CI environments.
Physical audio quality and cross-device latency still require device testing.

Every implementation milestone is committed separately:

```sh
git log --reverse --oneline
git show <commit>
```

[DEVELOPMENT.md](DEVELOPMENT.md) records changes and validation.
[Protocol details](docs/PROTOCOL.md) describe the current experimental wire/API
contract. [Architecture decisions](docs/DECISIONS.md) record departures from the
planning examples and the remaining platform work.

Phone companion support and setup: [notifications, SMS and calls](docs/PHONE_INTEGRATION.md).
Android source controls require explicit grants and OS access; cellular call audio
is not bridged by Narad. The [iOS runner](docs/IOS.md) is an unverified source preview
with Android-phone viewing and confirmation-only iPhone handoff, not full iPhone
SMS/history/notification mirroring.

Camera switching, saving photos/video and OBS webcam setup: [Camera guide](docs/CAMERA.md). Contact access and copying: [Phone integration](docs/PHONE_INTEGRATION.md#contacts).

Ring an online paired phone, tablet or desktop: [Find device setup and platform limits](docs/FIND_DEVICE.md).

Publish Windows, Linux and Android packages automatically when pushing a version
tag: [GitHub release workflow and signing setup](docs/RELEASING.md).
