# iOS source preview

This runner has not been built/signed or tested on Apple hardware in this Linux
workspace. A macOS simulator build job is configured in CI but has not run here.
Do not treat the source preview as a verified iPhone release.

On a Mac with Xcode, Flutter and Rust installed:

```sh
./scripts/build-ios.sh --simulator
```

For a signed device build, configure your development team in
`clients/flutter/ios/Runner.xcworkspace`, then run `./scripts/build-ios.sh`.
The script builds Rust device and simulator static libraries, wraps them into
`Runner/NaradMobile.xcframework`, and builds Flutter. The generated framework and
signing credentials are not committed. Rust targets are arm64 devices, arm64
simulator and x86_64 simulator; deployment target is iOS 15+.

The Swift host uses a small owned-string C ABI to start/stop the same authenticated
backend, access its private local bridge, and obtain a stable device identity.
Identity lives in device-only, when-unlocked Keychain storage. Backend state lives
under protected Application Support excluded from backups. Camera/microphone and
local-network usage descriptions are included. File export uses Apple's document
picker and the app icon reuses Narad branding.

Keep Narad foregrounded. It stops the backend on backgrounding and restarts on
resume; it does not claim a permanent iOS background service. Use same-LAN
invitation/QR pairing: raw multicast discovery is disabled to avoid requiring an
unimplemented iOS multicast entitlement/native Bonjour adapter.

The shared Phone companion screen can view an Android phone's granted data. An
optional iPhone-source handoff can open an SMS composer or call confirmation while
the app is visible. It cannot read iPhone SMS/call history or mirror general iOS
notifications. Full bidirectional phone-data parity is not implemented and cannot
be promised using the public APIs currently integrated. See
[the phone integration matrix](PHONE_INTEGRATION.md) for the exact boundaries.

Before device delivery, verify Xcode linking/Swift compilation, Keychain restart
and reinstall behavior, local-network denial/recovery, invitation and QR pairing,
foreground lifecycle/capture cleanup, file export, and cancellation/delivery
semantics of phone-side composer/call handoff. No signing or Apple eligibility
settings have been changed automatically.


## Shared folders

Media → Share a directory opens the system folder picker. Narad stores the selected
folder's minimal security-scoped bookmark inside its encrypted preferences.
While the foreground runtime is active, a dedicated storage queue coordinates
listing, chunked reads and verified uploads with the file provider. Stopping a
share or revoking peer permissions invalidates pending jobs. Uploads need both
`file.upload` and the folder's upload switch, and existing destinations fail.
Folder access is released after each operation; a stale bookmark requires choosing
the folder again. Background suspension can interrupt requests.

This bridge follows Apple's [directory access guidance](https://developer.apple.com/documentation/uikit/providing-access-to-directories).
The implementation has been reviewed on Linux; compiling and exercising iCloud,
local folders and third-party providers still requires macOS/Xcode and an iOS
or iPadOS device. Those native checks have not run here.


### Choose shared directories per device (build 15)

Open Devices, select a paired device, then use its top-right settings button.
Under **Directories shared with this device**, select existing folders or choose
**Share a directory with this device**. You can also use **Media → Shared folders
→ Choose devices** on each folder. Selections persist for offline devices.
The device still needs browse permission and, for writes, upload permission plus
the folder upload switch. Existing folders, including the app Shared folder,
require explicit device selection after upgrading; their files are preserved.
