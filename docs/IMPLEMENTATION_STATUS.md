# Implementation status

The original planning files are preserved unchanged as the requirements
baseline. This document describes the actual implementation.

| Area | Implemented | Remaining work |
| --- | --- | --- |
| Identity | Persistent Ed25519/TLS identity, private Unix state, Android Keystore wrapping | Desktop keychain integration; Windows ACL validation |
| Discovery | mDNS/DNS-SD, metadata validation, live capability advertising, manual fallback | Physical multi-network/platform matrix; IPv6 |
| Pairing | Direct nearby requests with receiver acceptance and automatic completion, invitation/QR fallback, verification codes | Standalone short-code pairing; security review |
| Trust | Encrypted local trust/permission records, pinned TLS, unpair/revocation | Key rotation/migration; independent security audit |
| Sessions | Guarded transitions, ownership checks, timeout/lease cleanup, stop | Full reconnect/re-negotiation policy and persisted diagnostics |
| Files | Persistent per-peer auto-grants or per-offer acceptance, scoped Shared-folder browsing, separate TLS plane, bounded checksummed chunks, resume/retry, cancellation, archive | Performance tuning, streaming transport optimization, disk quota management |
| Clipboard | Opt-in receive permission, manual sending, persistent automatic receive grants or one-off acceptance, native system clipboard write | Optional background monitoring with platform privacy policies |
| Audio | Flutter WebRTC microphone-to-speaker adapter, LAN host candidates, authorized signaling, stop/cleanup | Physical audio/latency tests, reconnection, output selection and diagnostics |
| Camera | Permissioned WebRTC viewing, lens switching, source preview, PNG/MP4 saving and localhost OBS desktop feed | End-to-end OBS call-app selection, Windows/iOS runtime and physical quality matrix |
| Controls | Locally configured command presets, bounded execution, Android force-lock and unlock-authentication notification, Linux loginctl | Physical lock/unlock matrix and desktop-session support |
| Flutter client | Nearby/online/offline dashboard, per-device settings, saved Device/Light/Dark themes, grouped activity, Media, Inbox and transfers | Platform packaging/installers, accessibility/device QA |
| Linux | Native builds, installer, tray/close-to-background, opt-out-aware login startup, isolated GTK hide/reopen tests, real daemon integration | Packaged release and physical two-machine media QA |
| Windows | Supervised packaged daemon, DPAPI identity migration, private ACLs, Windows command Jobs, workstation lock, ZIP/installer/firewall helpers, tray and hidden login startup, CI job; cross-compiled backend/native runner | Windows-native CI run, full GUI build and physical Windows/Android/Linux media/firewall/locking QA |
| Android | Embedded Rust/JNI backend, connected-device service, multicast lock, permissions, Keystore identity, QR scan, file picker/export, device-action widgets, live connection notification, universal APK | More physical devices/OS versions; camera, document export and microphone QA; battery policy matrix |
| iOS | Source-preview runner, Rust C ABI, Keychain identity, foreground Android companion viewer and user-confirmed SMS/call handoff | macOS compilation/signing and iPhone validation; no general iPhone SMS inbox, call logs or system notification sync |
| Phone companion | Permissioned notification read/dismiss/reply, SMS read/send, call logs and call controls from Android; shared viewer and desktop banners | Physical sensitive-data tests; desktop cellular audio; Windows banner runtime QA; iOS source restrictions (see PHONE_INTEGRATION.md) |
| Release | Lockfiles, development journal, CI configuration, setup/protocol docs | Release candidate criteria and security/compatibility review |

## Verified locally

- 22 Rust behavioral tests, formatting and strict Clippy.
- Seventeen two-daemon integration scenarios (multicast is opt-in): pairing and
  code mismatch, certificate pin mismatch, expired invitations, local API
  authentication, file acceptance/cancellation, interruption/resume, restart,
  persisted revocation, clipboard acceptance, media signaling gates, nearby acceptance/decline/cancellation, authenticated online/offline/reconnect,
  automatic grants, scoped browsing, preset command execution/revocation, and
  camera-only signaling with audio denied and camera revocation, phone permission separation, ephemeral dispatch and revocation, and separate contacts access. The latest fix
  run passed 16 cases with the multicast case skipped; multicast passed previously.
- Thirty-five Flutter tests: device actions, clipboard acceptance, pairing confirmation,
  narrow-screen layout, no media capture before approval, Android readiness,
  shutdown waiting, identity-error propagation, nearby request/accept/cancel UI, themes, grouped activity, per-device grants, validated widget routing, explicit SMS confirmation, sensitive-content clearing and banner deduplication.
- Eight native Android unit tests cover device actions without presets, platform
  differences, offline gating, notification text, unknown actions and rejecting unsafe phone numbers.
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
- Linux native virtual-desktop checks pass for hidden login startup, close-to-
  background and same-process restore. Seven installer scenarios cover login
  entry generation and preserving explicit startup opt-outs across upgrades.
- Android 0.1.0+7 includes the camera signaling authorization fix; 0.1.0+6 added
  device-action widgets and an ongoing authenticated connection notification. Fifteen Android/Linux
  physical checks pass on the Android 15 tablet, including real RemoteViews
  collection rendering without command presets, routing a widget tap to the
  selected device's settings, and its name in the foreground notification.
  The debug host leaves the user's launcher unchanged; launcher-specific resize,
  additional OEMs and physical media controls remain manual QA. The release
  excludes the debug host and passes signature and 16 KiB alignment checks.
  Windows tray/login behavior is cross-compiled, with native runtime work pending.
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

Camera-only signaling and permission revocation pass real-daemon tests. An
explicit hardware test on the Android 15 tablet captures camera video without
audio, negotiates native WebRTC and verifies a rendered frame with nonzero
dimensions, then stops capture. A real Android 16 phone-to-Linux test also renders
video through the production controller, paired TLS signaling and WebRTC while
audio is denied. Phone-to-tablet
video, desktop webcam capture and Windows camera runtime remain unverified.
Audio capture/playback across devices has not been validated. The app closes
disrupted streams and lets the user start again;
automatic media reconnection and audio-device selection are pending.

The complete cross-platform MVP and release criteria in the PRD are **not yet
fulfilled**. Follow the remaining platform and release work above before
claiming public-release readiness.

Phone integration build 0.1.0+8 adds Android opt-in setup and the shared companion UI. Tests use generated fixtures; no real SMS, calls or private phone records were exercised. iOS is source-only and the new Windows notification code awaits native compilation/runtime validation. See [phone integration](PHONE_INTEGRATION.md) and [iOS preview](IOS.md).

Final build 8 is installed on the Android 16 Nothing A015 with existing data preserved. Native setup layout was physically inspected after a system-bar inset fix. The integration switch remains off; existing OS access/role selections were preserved. Linux release installer passes all seven disposable packaging tests. Windows native banners and the iOS runner still require their platform build/runtime checks.

Build 9 adds separately granted live contact access, explicit contact-editor/vCard
copying, camera lens switching, PNG images, video-only MP4 recording and a local
OBS Browser feed for desktop webcam use. Automatic address-book merging and a
mobile system-wide virtual camera are not implemented. See [camera setup](CAMERA.md).
The Android 15 tablet passes physical render, both lens switches, valid PNG and
native H.264 recording with host full decode. An isolated animated Xvfb display
passes repeated native desktop snapshots, localhost feed retrieval and MP4 decode.
Native contact-editor field automation and saved-contact verification remain manual;
no existing contacts were read/modified. iOS sources still require Apple validation.
