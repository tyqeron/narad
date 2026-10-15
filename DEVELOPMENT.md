# Development journal

Each milestone is a separate Git commit. Planning documents are preserved in
the first commit. `git log --reverse --oneline` shows the development sequence.

## 1. Workspace foundation

- Rust workspace split into portable `narad-core` and the `narad` daemon/CLI.
- Protocol v1; control, file and media responsibilities remain separate.
- Flutter desktop client planned first; Android/iOS native daemon embedding and
  platform keystores require device work before those targets can ship.
- Private state and generated build output are excluded from Git.

## Validation policy

Run formatting, relevant behavioral tests, and lint checks at milestones.
Use two actual daemon instances for integration tests, including negative trust,
permission and recovery cases. Record unsupported or untested behavior honestly.

## 2. Identity, trust and authorization

- Stable Ed25519 identities and self-signed TLS certificates.
- Signed protocol envelopes bind the sender, payload, nonce and timestamp.
- Replay and stale-message rejection; encrypted ChaCha20-Poly1305 trust state.
- Capability permissions are independent of pairing; session transitions are guarded.
- Validation: four behavioral core tests passed; strict Clippy cleanup included in
  the transfer milestone.

## 3. Recoverable file storage

- Bounded chunks and BLAKE3 checksums for chunks and complete files.
- Encrypted progress manifests, atomic writes and durable checkpoints.
- Safe file names and per-transfer download directories prevent path traversal
  and accidental overwrite. Cancelled transfers reject further chunks.
- Validation: six core tests pass, including restart/resume, duplicate chunks,
  corrupt chunks, cancellation, encrypted-state tampering and authorization.

## 4. Network daemon and usable CLI

- mDNS/DNS-SD discovery and manual invitations; discovery is never a trust grant.
- Pinned TLS control and file listeners; signed, bounded protocol frames.
- One-time expiring pairing invitations and transcript verification codes with
  explicit approval on both devices.
- Token-authenticated loopback API, bounded concurrent connections and
  exclusive state-directory locking.
- File offer/accept/resume/cancel, encrypted outgoing history, clipboard
  permission plus per-payload acceptance, and approved WebRTC signaling.
- Revocation closes sessions; clipboard contents are excluded from activity logs.
- Validation: 12 Rust tests and strict Clippy pass; four real two-daemon TLS
  integration scenarios pass, including certificate mismatch and restart.

## 5. Flutter client and local audio adapter

- Device dashboard, QR invitation display/import, code comparison and pairing
  approval; capability permission management and unpair controls.
- File picker, durable outgoing history, transfer progress, resume and cancel.
- Clipboard preview/acceptance with actual platform clipboard writes.
- Separate WebRTC connections for microphone-to-speaker audio, host-only ICE,
  authenticated signaling, permission gates and explicit stop/cleanup.
- Media adapter lease prevents a disconnected UI from leaving its capability active.
- Responsive desktop/phone-sized layouts and activity diagnostics.
- Validation: five Flutter tests and static analysis pass; Linux debug build
  succeeds with native WebRTC plugin. Windows/mobile and physical-device audio
  are not yet validated.

## 6. Reliability and lifecycle fixes

- Actual multicast integration confirms discovery remains untrusted and audio
  availability follows the connected adapter.
- Refresh paired addresses only when discovery keys and TLS pins match; incoming
  metadata uses the observed network source address.
- Independent connection budgets for control, files and the local UI.
- Paginated history, bounded peer metadata, private IPv4 endpoints and archive
  actions that preserve completed downloads.
- Revoked file sessions stay closed through restart and need explicit resume.
- Keep one shutdown future across the accept loop and drain cancelled tasks;
  the expanded restart test exposed and resolved a missed-signal race.
- Audio cleanup stops local capture before network teardown; late microphone
  permission results are disposed when their session has already ended.
- Validation: 12 Rust tests, seven real daemon integration scenarios (including
  multicast and interrupted 8 MiB transfer), five Flutter tests, clean linting
  and rendered desktop/narrow layout previews.

## 7. Bounded buffered transport

- Read JSON frames through bounded buffered I/O instead of awaiting each byte.
- Keep the existing remote/local limits and reject missing frame terminators.
- Flush download directories before removing the partial-file link on Unix.
- Validation: Rust behavior tests and strict Clippy pass; real transfer/restart
  integration verifies the same framing and durability behavior.

## 8. Patched dependencies and project toolchain

- Checked registry dependencies against OSV and inspected the corresponding
  RustSec advisories. Updated Anyhow, Rand, Rustls/WebPKI, Tokio/Tokio-Rustls,
  Time, and the compatible Serde dependency chain.
- Rustls 0.23.46 includes the fixes listed in the
  [TLS handshake advisory](https://rustsec.org/advisories/RUSTSEC-2026-0285.html).
  Time 0.3.55 includes the
  [stack exhaustion fix](https://rustsec.org/advisories/RUSTSEC-2026-0009.html).
- `rust-toolchain.toml` pins Rust 1.88, required by patched Time. The global
  default toolchain remains unchanged.
- Added `scripts/check-dependencies.py` to repeat the public package-version
  advisory check; it sends no source code or private state.
- Validation on 2026-10-15: all 151 registry dependencies returned no matched
  OSV advisories; 12 Rust tests, strict Clippy and all seven daemon integration
  scenarios pass on the patched graph. This is not an independent security audit.

## 9. Run instructions, CI and implementation status

- Added the Linux development launcher, CLI/GUI setup instructions, experimental
  protocol reference, architecture decisions and explicit remaining-work status.
- Added Rust and Flutter CI jobs; CI configuration is committed, not yet run on
  a hosted repository. Linux native builds and equivalent local checks pass.
- Set client version 0.1.0 and included the workspace MIT license.
- Original PRD, architecture, roadmap, backlog and technical specification stay
  preserved as the planning baseline; cross-platform release criteria remain open.

## 10. Embeddable backend and Android JNI foundation

- Extracted the daemon into a reusable library with caller-owned shutdown and
  startup readiness signaling; the desktop CLI uses the same implementation.
- Added the Android JNI runtime host and in-memory identity generation so Android
  can wrap private identity bytes with Keystore without writing a plaintext key.
- Added NDK builds for arm64-v8a, armeabi-v7a and x86_64 with 16 KiB page alignment.
- Added local metadata operations for device naming and Wi-Fi address updates.
- Validation: 13 Rust tests and strict Clippy pass; ARM64 native library builds
  against installed NDK r27. Embedded start/stop/restart preserves identity and
  releases sockets without depending on process signals.
