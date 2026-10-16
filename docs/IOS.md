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
