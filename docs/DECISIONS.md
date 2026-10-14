# Implementation decisions

## Rust core and companion daemon

`narad-core` owns portable identity, protocol models, authorization, session
rules and recoverable file storage. `narad` owns mDNS, pinned TLS listeners,
command routing and the CLI. Flutter calls a token-authenticated loopback API.

This gives the initial desktop client a usable boundary without coupling UI
code to Rust memory layout. Mobile will need an embedded daemon/runtime bridge
and platform lifecycle integration before it is functional.

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
identity-derived key. Identity secrets currently use protected files, pending
OS keystore integration. An exclusive file lock prevents two daemons from
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

Clipboard sending and receiving are manual. File acceptance is per offer,
independent of global pairing. Audio capture begins only after receiver
approval and stops locally before waiting for remote teardown. No background
clipboard monitoring is enabled implicitly.

## Reproducible development

The dependency lockfile uses patched networking libraries and requires Rust
1.88 for the corrected time dependency. `rust-toolchain.toml` pins a project
toolchain without changing the global Rust default. Flutter
uses the tested 3.44.8 SDK. Planning documents and each milestone remain in Git;
`DEVELOPMENT.md` and implementation status describe validation without claiming
untested platforms or a completed production release.
