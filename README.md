# Narad

A local-first device collaboration platform. Rust owns identity, trust,
authorization, sessions and the network planes. Flutter provides the client UI
and platform media adapter. No accounts or cloud relay.

Implementation follows [the technical specification](TECHNICAL_IMPLEMENTATION_SPEC.md).
See [DEVELOPMENT.md](DEVELOPMENT.md) for milestones and validation evidence.

## Development

Prerequisites: Rust 1.83+, Flutter 3.44+, a LAN that permits multicast discovery.

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo run -p narad -- --help
```
