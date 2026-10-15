# Implementation decisions

## Rust core and companion daemon

`narad-core` owns portable identity, protocol models, authorization, session
rules and recoverable file storage. `narad` owns mDNS, pinned TLS listeners,
command routing and the CLI. Flutter calls a token-authenticated loopback API.

This gives the initial desktop client a usable boundary without coupling UI
code to Rust memory layout. Android embeds the same daemon through a JNI lifecycle host. The native
foreground service owns its runtime; Flutter talks to the private localhost API.
iOS still needs its platform bridge.

## Trust before capabilities

Discovery metadata is an untrusted hint. An out-of-band invitation pins the
recipient's Ed25519 public key and TLS certificate fingerprint. Both devices
compare the transcript-bound six-digit code and explicitly confirm pairing.
Pairing alone grants no capability permission.

TLS protects confidentiality. Signed application frames prove the client
identity; the server does not use TLS client certificates. Every privileged
command checks the trusted key and certificate pin before authorization.

## Protected local state

Unix state directories use mode 0700 and atomic identity/token writes use 0600.
ChaCha20-Poly1305 encrypts trust and transfer metadata with a domain-separated,
identity-derived key. Desktop identity secrets use protected files. Android wraps its identity with
a non-exportable Android Keystore AES-GCM key and stores only ciphertext in
no-backup app storage; private material crosses JNI only in memory. An exclusive file lock prevents two daemons from
using one identity directory concurrently.

## Three transport responsibilities

Control and files use distinct TLS listeners, connection budgets and commands.
Flutter WebRTC carries audio over a separate peer connection. Signaling stays
on the authenticated control plane. ICE uses host candidates without cloud
services.

The file implementation opens a bounded request connection per chunk. This is
straightforward to recover and test; connection reuse and throughput tuning
are later work.

## BLAKE3 file checksums

The planning document's SHA-256 field is illustrative. This implementation
uses BLAKE3 consistently for file/chunk integrity, device IDs, certificate pins
and code derivation. The protocol documentation specifies the exact inputs;
these hashes do not substitute for signatures or TLS authentication.

## Explicit productivity actions

Pairing grants no capabilities. Each peer has explicit encrypted persistent
permissions for files, clipboard, audio, camera, scoped browsing, command presets,
lock and unlock. A separate automatic-grant map avoids migrating old per-offer
approvals into broad access. Newly enabled device settings remove repeated app
approval; revocation closes matching sessions and queued actions. Clipboard
sending remains manual; no background clipboard monitoring is enabled.

Presence comes from signed, pinned-TLS heartbeats, not mDNS announcements. Camera
and audio need foreground native adapters and OS permission. Browsing exposes
only the dedicated Shared folder, rejects traversal/symlinks and uses bounded
chunks. Commands select locally configured encrypted presets; remote payloads
cannot introduce arbitrary shell scripts. Execution bounds time/output and kills
its process group on timeout/revocation. Scripts and output are excluded from
activity logs.

Android lock uses optional force-lock device-admin activation. Unlock opens a
minimal notification-driven Activity for system authentication, keeping private
Flutter content off the lock screen. Linux uses session-specific `loginctl`
controls; desktop support determines behavior. Neither path bypasses credentials.
The existing Material hub mark is reused for launcher/notification/desktop icons;
its Apache license and reproducible generation script are included.

## Reproducible development

The dependency lockfile uses patched networking libraries and requires Rust
1.88 for the corrected time dependency. `rust-toolchain.toml` pins a project
toolchain without changing the global Rust default. Flutter
uses the tested 3.44.8 SDK. Planning documents and each milestone remain in Git;
`DEVELOPMENT.md` and implementation status describe validation without claiming
untested platforms or a completed production release.
