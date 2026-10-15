# Implementation status

The original planning files are preserved unchanged as the requirements
baseline. This document describes the actual implementation.

| Area | Implemented | Remaining work |
| --- | --- | --- |
| Identity | Persistent Ed25519/TLS identity, private Unix state, Android Keystore wrapping | Desktop/iOS keychain integration; Windows ACL validation |
| Discovery | mDNS/DNS-SD, metadata validation, live capability advertising, manual fallback | Physical multi-network/platform matrix; IPv6 |
| Pairing | Direct nearby requests with receiver acceptance and automatic completion, invitation/QR fallback, verification codes | Standalone short-code pairing; security review |
| Trust | Encrypted local trust/permission records, pinned TLS, unpair/revocation | Key rotation/migration; independent security audit |
| Sessions | Guarded transitions, ownership checks, timeout/lease cleanup, stop | Full reconnect/re-negotiation policy and persisted diagnostics |
| Files | Persistent per-peer auto-grants or per-offer acceptance, scoped Shared-folder browsing, separate TLS plane, bounded checksummed chunks, resume/retry, cancellation, archive | Performance tuning, streaming transport optimization, disk quota management |
| Clipboard | Opt-in receive permission, manual sending, persistent automatic receive grants or one-off acceptance, native system clipboard write | Optional background monitoring with platform privacy policies |
| Audio | Flutter WebRTC microphone-to-speaker adapter, LAN host candidates, authorized signaling, stop/cleanup | Physical audio/latency tests, reconnection, output selection and diagnostics |
| Camera | Permissioned WebRTC camera viewing, foreground source, native permission gate and teardown | Physical capture/quality/device matrix |
| Controls | Locally configured command presets, bounded execution, Android force-lock and unlock-authentication notification, Linux loginctl | Physical lock/unlock matrix and desktop-session support |
| Flutter client | Nearby/online/offline dashboard, per-device settings, saved Device/Light/Dark themes, grouped activity, Media, Inbox and transfers | Platform packaging/installers, accessibility/device QA |
| Linux | Rust checks, Flutter tests, native debug build, real daemon integration | Packaged release and physical two-machine media QA |
| Windows | Supervised packaged daemon, DPAPI identity migration, private ACLs, Windows command Jobs, workstation lock, ZIP/installer/firewall helpers, CI job; cross-compiled backend | Windows-native CI run, full GUI build and physical Windows/Android/Linux media/firewall/locking QA |
| Android | Embedded Rust/JNI backend, connected-device service, multicast lock, permissions, Keystore identity, QR scan, file picker/export, universal APK | More physical devices/OS versions; camera, document export and microphone QA; battery policy matrix |
| iOS | Architecture boundary only | Runner, embedding, entitlements, lifecycle, keychain and device QA |
| Release | Lockfiles, development journal, CI configuration, setup/protocol docs | Release candidate criteria and security/compatibility review |

## Verified locally

- 21 Rust behavioral tests, formatting and strict Clippy.
- Thirteen two-daemon integration scenarios with multicast enabled: pairing and
  code mismatch, certificate pin mismatch, expired invitations, local API
  authentication, file acceptance/cancellation, interruption/resume, restart,
  persisted revocation, clipboard acceptance, media signaling gates, nearby acceptance/decline/cancellation, authenticated online/offline/reconnect,
  automatic grants, scoped browsing, and preset command execution/revocation.
- Twenty Flutter tests: device actions, clipboard acceptance, pairing confirmation,
  narrow-screen layout, no media capture before approval, Android readiness,
  shutdown waiting, identity-error propagation, nearby request/accept/cancel UI, themes, grouped activity and per-device grants.
- Flutter analysis and Linux native debug build.
- Desktop and narrow-screen previews rendered and inspected.
- Android 15/API 35 physical ARM64 tablet: two device integration tests verify
  Keystore identity persistence, no plaintext identity file, and native WebRTC
  data-channel delivery without microphone or camera capture.
- Eight Android/Linux nearby-mode checks passed on both an Android 15/API 35
  tablet and a Nothing A015 Android 16/API 36 phone: mutual LAN mDNS discovery,
  direct request/accept pairing without invitations, full Android process restart
  preserving identity/trust/file approval, byte-for-byte file transfer in both directions,
  clipboard permission/acceptance, revocation, and Android-initiated pairing
  completion while the app is backgrounded. Fixtures are generated.
- Twelve updated Android/Linux checks pass on the Android 15 tablet, adding
  authenticated online presence, persistent automatic file delivery, Shared-folder
  browsing and byte-for-byte download, and command presets executed on both
  Android and Linux. Cameras and actual device locking are excluded from automation.
- Universal release-mode APK built and installed on the tablet; the Devices
  dashboard and foreground service are verified. ARM64, ARMv7 and x86_64
  backends are packaged; signature and checksum verified. All 16 packaged 64-bit native libraries pass 16 KiB ELF
  alignment checks; APK zip alignment passes too. The physical tablet uses
  4 KiB pages; physical 16 KiB-page hardware and additional Android devices
  remain untested.
- Windows GNU backend and test executables cross-compile, with strict Windows-target
  Clippy. The native supervisor and Flutter method channel compile against official
  Windows engine headers. Full Windows GUI packaging and Windows-native integration
  are configured in CI but have not run here; isolated Wine initialization did not
  complete and is not counted as Windows runtime validation.
- Public OSV check: 171 locked Rust registry packages, no matched advisories.
  CI includes an Android APK artifact job; hosted CI has not been run here.

## Release boundaries

Linux identity material is stored in a permissions-protected local file. Windows
wraps identity with per-user DPAPI and protects state with owner/SYSTEM DACLs.
Android stores only AES-GCM-wrapped identity bytes using a non-exportable Android
Keystore key in no-backup app storage; unwrapped bytes remain in process memory.
Trust, permissions, transfer manifests and outgoing history are encrypted with
an identity-derived key. Protect state directories and never copy identities
between devices. Development APKs use the local debug signing key.

The control protocol is experimental. Replay IDs are retained in memory for
120 seconds and messages must be within 60 seconds of the receiver clock;
clock skew can prevent pairing or commands. The receiver always rechecks
permissions for file chunks, browsing, commands and media signals. Persistent
per-peer grants allow automatic delivery; legacy per-offer approvals do not
silently become persistent automatic grants.

Transfers use BLAKE3 rather than the illustrative SHA-256 field in the original
specification. A receiver must explicitly allow a revoked or stale file session
to resume. Received file contents are ordinary files in the private download
folder; manifest encryption does not encrypt the transferred file itself.

Audio/camera negotiation and lifecycle code compile, and its permission boundary is
tested. Actual audio/camera capture/playback across physical devices has not been
validated. The app closes disrupted streams and lets the user start again;
automatic media reconnection and audio-device selection are pending.

The complete cross-platform MVP and release criteria in the PRD are **not yet
fulfilled**. Follow the remaining platform and release work above before
claiming public-release readiness.
