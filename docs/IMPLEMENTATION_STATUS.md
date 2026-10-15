# Implementation status

The original planning files are preserved unchanged as the requirements
baseline. This document describes the actual implementation.

| Area | Implemented | Remaining work |
| --- | --- | --- |
| Identity | Persistent Ed25519/TLS identity, private Unix state, Android Keystore wrapping | Desktop/iOS keychain integration; Windows ACL validation |
| Discovery | mDNS/DNS-SD, metadata validation, live capability advertising, manual fallback | Physical multi-network/platform matrix; IPv6 |
| Pairing | Expiring one-time invitations, QR display and Android camera scanning, transcript code comparison, approval on both devices | Standalone short-code pairing; security review |
| Trust | Encrypted local trust/permission records, pinned TLS, unpair/revocation | Key rotation/migration; independent security audit |
| Sessions | Guarded transitions, ownership checks, timeout/lease cleanup, stop | Full reconnect/re-negotiation policy and persisted diagnostics |
| Files | Per-offer acceptance, separate TLS plane, bounded checksummed chunks, resume/retry, cancellation, archive | Performance tuning, streaming transport optimization, disk quota management |
| Clipboard | Opt-in receive permission, manual sending, payload preview and acceptance, system clipboard write | Optional background monitoring with platform privacy policies |
| Audio | Flutter WebRTC microphone-to-speaker adapter, LAN host candidates, authorized signaling, stop/cleanup | Physical audio/latency tests, reconnection, output selection and diagnostics |
| Flutter client | Device dashboard, Inbox, transfers, audio, activity, responsive layout | Platform packaging/installers, accessibility/device QA |
| Linux | Rust checks, Flutter tests, native debug build, real daemon integration | Packaged release and physical two-machine media QA |
| Windows | Generated runner and portable Rust/network code | Native build, storage/clipboard/audio/firewall QA |
| Android | Embedded Rust/JNI backend, connected-device service, multicast lock, permissions, Keystore identity, QR scan, file picker/export, universal APK | More physical devices/OS versions; camera, document export and microphone QA; battery policy matrix |
| iOS | Architecture boundary only | Runner, embedding, entitlements, lifecycle, keychain and device QA |
| Release | Lockfiles, development journal, CI configuration, setup/protocol docs | Release candidate criteria and security/compatibility review |

## Verified locally

- 14 Rust behavioral tests, formatting and strict Clippy.
- Seven two-daemon integration scenarios with multicast enabled: pairing and
  code mismatch, certificate pin mismatch, expired invitations, local API
  authentication, file acceptance/cancellation, interruption/resume, restart,
  persisted revocation, clipboard acceptance, and media signaling gates.
- Eight Flutter tests: device actions, clipboard acceptance, pairing confirmation,
  narrow-screen layout, no media capture before approval, Android readiness,
  shutdown waiting and identity-error propagation.
- Flutter analysis and Linux native debug build.
- Desktop and narrow-screen previews rendered and inspected.
- Android 15/API 35 physical ARM64 tablet: two device integration tests verify
  Keystore identity persistence, no plaintext identity file, and native WebRTC
  data-channel delivery without microphone or camera capture.
- Six Android/Linux checks: TLS pairing, full Android process restart preserving
  identity/trust/file approval, byte-for-byte file transfer in both directions,
  clipboard permission/acceptance, and revocation. Fixtures are generated.
- Universal release-mode APK built and installed on the tablet; the Devices
  dashboard and foreground service are verified. ARM64, ARMv7 and x86_64
  backends are packaged; signature and
  checksum verified. All 16 packaged 64-bit native libraries pass 16 KiB ELF
  alignment checks; APK zip alignment passes too. The physical tablet uses
  4 KiB pages; physical 16 KiB-page hardware and additional Android devices
  remain untested.
- Public OSV check: 171 locked Rust registry packages, no matched advisories.
  CI includes an Android APK artifact job; hosted CI has not been run here.

## Release boundaries

Desktop identity material is stored in a permissions-protected local file.
Android stores only AES-GCM-wrapped identity bytes using a non-exportable Android
Keystore key in no-backup app storage; unwrapped bytes remain in process memory.
Trust, permissions, transfer manifests and outgoing history are encrypted with
an identity-derived key. Protect state directories and never copy identities
between devices. Development APKs use the local debug signing key.

The control protocol is experimental. Replay IDs are retained in memory for
120 seconds and messages must be within 60 seconds of the receiver clock;
clock skew can prevent pairing or commands. The receiver always rechecks
permissions for file chunks and media signals. Clipboard offers need fresh
user acceptance.

Transfers use BLAKE3 rather than the illustrative SHA-256 field in the original
specification. A receiver must explicitly allow a revoked or stale file session
to resume. Received file contents are ordinary files in the private download
folder; manifest encryption does not encrypt the transferred file itself.

Audio negotiation and lifecycle code compile, and its permission boundary is
tested. Actual audio capture/playback across physical devices has not been
validated. The app closes disrupted streams and lets the user start again;
automatic media reconnection and audio-device selection are pending.

The complete cross-platform MVP and release criteria in the PRD are **not yet
fulfilled**. Follow the remaining platform and release work above before
claiming public-release readiness.
