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
