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
3. On device A, select **Create invitation**. On B, select **Scan invitation**
   and allow camera access, or use **Enter invitation** to paste the JSON.
4. Compare the six-digit code on both devices and approve the pairing in
   **Inbox** on each. Repeat for every pair that needs to communicate: pairing
   A–B and A–C does not automatically pair B–C.
5. Send a small file from B. Accept it in A's Inbox, then choose **Send / resume**
   on B. In A's Transfers view, select **Save to device** and choose a destination.
   Repeat in the other direction, then try a larger file and a network interruption.
6. To test clipboard sharing, allow the peer's clipboard permission on the
   receiver. Each text offer still needs acceptance. Audio needs **Enable Audio**
   on both devices plus receiver approval; keep both apps in the foreground.

To test Android against Linux, start the desktop daemon and Flutter client using
[the root README](../README.md#run-on-linux), then follow the same pairing steps.
Only pair devices you control and compare codes before approval.

The foreground service keeps control and file listeners available while the UI
is backgrounded. It does not keep microphone capture running. **Stop Narad** in
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
python3 tests/android_e2e.py --serial DEVICE_SERIAL
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
pairing and fixtures. It never reads the system clipboard or personal files.
It requires the debug APK (`run-as`) and reachable IPv4 addresses on the LAN.

If discovery is empty, QR/pasted invitations still work. Guest Wi-Fi/client
isolation can block peer connections; use a network that allows devices to talk.
For a desktop firewall, allow TCP 45678/45679 and UDP 5353. Invitations expire
in five minutes; recreate one after switching Wi-Fi networks. VPN routing and
IPv6-only networks are outside the current tested scope.
