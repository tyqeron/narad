# Narad

Local-first device discovery, pairing, file transfer, clipboard sharing and
permissioned audio. A portable Rust core owns trust and protocol decisions; a
Flutter client provides the interface and native WebRTC audio adapter. No
account, cloud signaling, STUN or TURN service is required.

This is an initial desktop implementation of the [product plan](PRD.md), not a
production release. Linux builds and integration tests are validated. Windows
needs a platform test pass; Android/iOS daemon embedding and native key stores
remain on the roadmap. See [implementation status](docs/IMPLEMENTATION_STATUS.md).

## Run on Linux

Prerequisites: Rust 1.88+, Flutter 3.44.8 (Dart 3.12.2), Python 3 for integration tests, and
Flutter's Linux native build dependencies (Clang, CMake, Ninja, pkg-config,
GTK 3 and PulseAudio development libraries). The WebRTC plugin downloads its
native library during the first build.

```sh
./scripts/dev-linux.sh "My laptop"
```

Or start the daemon from the repository root:

```sh
cargo run -p narad -- serve --name "My laptop"
```

In a second terminal:

```sh
cd clients/flutter
flutter pub get
flutter run -d linux
```

The client defaults to `../../.narad` when launched from its project directory.
For a packaged app, enter the absolute daemon state path on the connection
screen. `NARAD_STATE` can prefill that path.

Repeat on a second computer on the same private IPv4 LAN. Allow inbound TCP
45678 (control), TCP 45679 (files), and UDP 5353 (mDNS) as needed. The local API
on TCP 45700 binds only to loopback and requires a private token.

## Use the app

1. Create an invitation on one device; paste it into Enter invitation on the
   other. Compare the verification code and approve in Inbox on **both** devices.
2. Send a file. The receiver accepts it; the sender selects **Send / resume**.
   Completed files appear under `.narad/downloads/<transfer-id>/<file-name>`.
3. Grant clipboard permission on the receiver, then review and send text from
   the sender. Each received payload still needs acceptance before the system
   clipboard changes.
4. Enable Audio on both clients, request audio from the sender, and approve it
   in the receiver's Inbox. Capture begins after approval. Stop or revoke access
   to end the stream.

Invitations expire after five minutes. Discovery is optional: invitation entry
works when multicast is blocked. QR display is available; camera QR scanning
and standalone short-code discovery are not yet implemented.

## CLI

```sh
cargo run -p narad -- --help
cargo run -p narad -- invite > /tmp/narad-invitation.json
cargo run -p narad -- pair /tmp/narad-invitation.json
cargo run -p narad -- approve-pair <pair-id> <code>   # receiver
cargo run -p narad -- confirm-pair <pair-id> <code>   # sender
cargo run -p narad -- status
cargo run -p narad -- send <peer-id> /path/to/file
cargo run -p narad -- accept-file <transfer-id>      # receiver
cargo run -p narad -- send <peer-id> /path/to/file --id <transfer-id>
cargo run -p narad -- permission <peer-id> clipboard.sync --allow
cargo run -p narad -- clipboard <peer-id> "Text to share"
cargo run -p narad -- accept-clipboard <clipboard-id>
cargo run -p narad -- unpair <peer-id>
```

Use `--state /absolute/path` and `--api-port <port>` for a non-default daemon.
For two daemons on one computer, give each a distinct state directory and
control/file/API port combination. Do not use the same identity directory on
multiple devices.

## Verify and trace development

```sh
cargo fmt --all --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build --workspace --locked
python3 tests/e2e.py
NARAD_TEST_MDNS=1 python3 tests/e2e.py  # optional multicast integration
python3 scripts/check-dependencies.py  # public OSV advisory check; needs network
cd clients/flutter
flutter analyze
flutter test
flutter build linux --debug
```

The integration suite launches two real daemon processes, tests TLS and
permissions, interrupts an 8 MiB transfer, restarts both peers, and verifies the
resumed file byte-for-byte. Multicast checks are opt-in for CI environments.
Physical audio quality and cross-device latency still require device testing.

Every implementation milestone is committed separately:

```sh
git log --reverse --oneline
git show <commit>
```

[DEVELOPMENT.md](DEVELOPMENT.md) records changes and validation.
[Protocol details](docs/PROTOCOL.md) describe the current experimental wire/API
contract. [Architecture decisions](docs/DECISIONS.md) record departures from the
planning examples and the remaining platform work.
