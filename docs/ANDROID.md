# Android testing

Narad runs its Rust backend inside the Android app. Install the APK on each
Android device; no Termux, Rust installation, server or account is needed there.
Android 8.0 (API 26) or newer is required. The universal APK includes arm64-v8a,
armeabi-v7a and x86_64. Each installation creates its own Keystore-wrapped identity.

## Install and pair multiple devices

1. Copy `dist/narad-android-release.apk` to each phone/tablet and open it.
   Allow installation from the app you use to open the APK if Android asks.
   These development builds use the local Android debug signing key.
2. Connect devices to the same Wi-Fi network or hotspot. Open Narad on each.
   Allow notifications so its connection service is visible. Give each device
   a recognizable name using **Rename device**.
3. Find device B under **Nearby devices** on A and select **Send pairing request**.
   A shows the pending request and verification code; it can cancel the request.
4. On B, open **Inbox** (or **Review request** from its incoming notice). Recognize
   the requesting device, compare the displayed verification code, and select
   **Accept request**. Both devices connect automatically; no invitation, code
   entry or camera is required. **Decline** leaves them unpaired. Requests expire
   in five minutes. Update Narad on both devices to use nearby requests.
5. Devices lists **Nearby**, then paired **Online** and **Offline** groups. Open
   **Device settings** on A's entry for B to allow what B may do on A. Permissions
   persist across restarts. Enable **File transfer**, then send a small file from B:
   it transfers without another acceptance prompt. Without that grant, accept in
   A's Inbox and retry **Send / resume** on B. Use **Save to device** to export it.
6. Enable **Clipboard** for automatic delivery of manually sent text. Enable
   **Audio** and/or **Camera** grants and the relevant adapter in **Media**; allow
   the Android microphone/camera prompt and keep the apps foregrounded. **View
   camera** requests the other device's camera without capturing your own microphone.
7. In Settings, add files to **Shared folder** for permitted peers to browse and
   download. Browsing is restricted to this app-managed folder. Configure command
   presets on the target; permitted peers can run only those presets, within the
   app's Android sandbox, with a ten-second deadline and bounded output.
8. Granting **Lock device** offers Android's device-admin activation screen (only
   force-lock is requested). **Request unlock** posts a notification on the target;
   tap it and authenticate with Android. Notifications must be allowed. Secure
   credentials are never bypassed. Revoke the grant to block subsequent requests.
9. Settings offers **Device / Light / Dark** appearance; Device is the default.
   Activity groups events by day and type. The launcher uses the in-app hub icon.

Repeat these steps for each device pair: A–B and A–C do not automatically pair
B–C. If multicast discovery is blocked, use **Create invitation** on one device
and **Scan invitation** or **Enter invitation** on the other; compare the code
and approve on both screens for that fallback flow.

To test Android against Linux, start the desktop daemon and Flutter client using
[the root README](../README.md#run-on-linux), then follow the same pairing steps.
Only pair devices you control and compare codes before approval.

The foreground service keeps control and file listeners available while the UI
is backgrounded. It does not keep microphone or camera capture running. **Stop Narad** in
its notification stops the service; reopen/retry in the app to start it again.
Android or manufacturer battery management can still terminate the process.
Accepted transfer checkpoints persist; reopen both apps and use **Send / resume**.
Clearing app data or uninstalling removes its identity and requires fresh pairing.

## Build from source

On the development computer install Rust 1.88, Python 3, Flutter 3.44.8, Java 17,
Android SDK platform 36 and NDK **28.2.13676358**. Accept Android SDK licenses.
Configure the SDK with `flutter config --android-sdk /path/to/Android/Sdk`.
Gradle uses the generated `clients/flutter/android/local.properties` SDK path.
The first build needs network access for Flutter, Cargo, Gradle and Maven caches.

```sh
./scripts/build-android.sh             # universal AOT APK for device testing
./scripts/build-android.sh debug       # debug APK, supports run-as test harness
# If flutter is not on PATH:
FLUTTER_BIN=/opt/flutter/bin/flutter ./scripts/build-android.sh
```

Gradle builds the Rust libraries automatically. The build script checks all three
embedded backend ABIs and 16 KiB alignment of the 64-bit native libraries. Do not copy identities or state
folders between devices. APKs and build outputs are ignored by Git. Release-mode
APKs currently use the development signing key; store publishing needs a dedicated
signing setup. Keep the same key for APK upgrades to preserve existing app data.

```sh
adb devices -l
adb -s DEVICE_SERIAL install -r dist/narad-android-release.apk
adb -s DEVICE_SERIAL shell am start -n dev.narad.narad_client/.MainActivity
```

On Xiaomi/HyperOS, Developer options may require **Install via USB** and an
on-device install confirmation even over wireless ADB. `INSTALL_FAILED_USER_RESTRICTED`
means installation was blocked on the device.

## Repeatable checks

```sh
cd clients/flutter
flutter analyze
flutter test
flutter test integration_test/android_smoke_test.dart -d DEVICE_SERIAL
cd ../..
cargo build --workspace --locked
# Launch the debug app, then run generated-fixture Android/Linux checks:
python3 tests/android_e2e.py --serial DEVICE_SERIAL --pairing nearby --controls
# Retain the invitation compatibility regression too:
python3 tests/android_e2e.py --serial DEVICE_SERIAL --pairing invitation
```

Use an expendable installation for `flutter test integration_test/...`: the
Flutter runner can uninstall the app after testing, removing its identity and
state. Reinstall a normal APK before manual testing or the host harness.

The device integration test checks Keystore-backed persistence across service
restart, absence of plaintext identity files, and a native WebRTC data-channel
exchange. It does not record audio or use the camera. The host harness pairs a
fresh temporary desktop identity, restarts the Android process to check identity,
trust and file approval persistence, sends generated files in both directions,
checks bytes and clipboard permission/acceptance, then removes its temporary
pairing and fixtures. In nearby mode it also verifies Android-initiated pairing while the app is
backgrounded. With `--controls`, it additionally checks authenticated presence,
automatic file delivery, Shared-folder browsing/downloads, and preset commands
on both Android and Linux. It never locks a device or captures media. It never reads the system clipboard or personal files.
It requires the debug APK (`run-as`) and reachable IPv4 addresses on the LAN.

If discovery is empty, QR/pasted invitations still work. Guest Wi-Fi/client
isolation can block peer connections; use a network that allows devices to talk.
For a desktop firewall, allow TCP 45678/45679 and UDP 5353. Invitations expire
in five minutes; recreate one after switching Wi-Fi networks. VPN routing and
IPv6-only networks are outside the current tested scope.

## Platform permission boundaries

Persistent Narad grants remove repeated app-level acceptance. Android still owns
camera/microphone permissions, foreground capture, notifications and device-admin
activation. OS restrictions may reject background clipboard updates; failures are
reported in Activity. Files added to Shared folder are copied into app storage;
remove that copy to stop exposing it, or revoke browsing. Linux presets run as the
current daemon user; Android presets run as the app UID. Configure only commands
you intend a granted peer to trigger.

See Android's [device locking API](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#lockNow())
and [keyguard dismissal API](https://developer.android.com/reference/android/app/KeyguardManager#requestDismissKeyguard(android.app.Activity,%20android.app.KeyguardManager.KeyguardDismissCallback))
for the system-enforced lock and authentication requirements.

## Home-screen device widget

Long-press an empty area of your home screen, choose **Widgets → Narad Devices**,
and place the widget. Select a paired device: its actions appear immediately as
a scrollable list with icons. No command preset is required to configure it.
Resize the widget to show more rows; the header shows the selected device and
its authenticated online/offline status. The gear changes devices and Refresh
checks connections.

The widget offers the same actions as the device menu: files, clipboard, audio,
camera, browsing, commands, locking, supported unlock requests, device settings
and unpairing. File pickers, clipboard input, command selection, media and
confirmation dialogs open in Narad for that selected device. Receiver-side
permissions still apply. Offline communication actions are disabled; settings
and unpair remain available. Windows does not offer remote unlock. Existing
command widgets migrate to the device-action layout using their selected peer.

The foreground-service notification remains ongoing while Narad runs. It shows
connected-device count and names, with the full list when expanded. Only paired
devices passing authenticated presence checks count as connected; nearby discovery
does not. No connected devices and temporary connection checks have explicit
messages. Names are hidden in the lock-screen public version. Allow Narad
notifications in Android Settings to see it. Android 14+ may let users dismiss
ongoing notifications; see [Android's notification behavior](https://developer.android.com/about/versions/14/behavior-changes-all#non-dismissable-notifications).

For generated-fixture physical tests, install the debug APK and use:

```sh
python3 tests/android_e2e.py --serial DEVICE_SERIAL --pairing nearby --controls --widget
```

The debug-only widget host tests real collection rows and action routing without
placing a widget on the user's launcher. It temporarily grants then revokes widget
binding for Narad, and deletes its own temporary widgets. The release APK contains
no debug preview activity.

## Camera sharing checks

Install the current APK on **both** the phone sharing its camera and the tablet
viewing it. Builds before 0.1.0+7 incorrectly checked camera signaling against the
audio capability and could show `Bad state: capability permission denied` even
when camera access was allowed.

On the phone, open the tablet's device settings and allow **Share this device’s
camera**, including Android's camera permission. Keep Narad open on the phone.
On the tablet, select **View camera** for that phone; video appears in Media.
Camera sharing stops when the source app is backgrounded.

To explicitly test native camera capture and rendering on one Android device:

```sh
cd clients/flutter
flutter test integration_test/android_camera_test.dart -d DEVICE_SERIAL --no-uninstall
```

This hardware test opens the camera, exchanges video between two local WebRTC
connections, checks a rendered frame and stops capture. It never records video
or sends it off the test device. It is separate from the default smoke tests.
Use a development test device; reinstall the normal release APK afterwards to
restore the app UI.
