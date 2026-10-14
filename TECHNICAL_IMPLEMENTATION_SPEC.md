# Narad Technical Implementation Specification

## 1. Purpose

This document defines the technical implementation approach for the Narad project. It converts the product and architecture goals into a concrete engineering specification suitable for product implementation and team execution.

The focus is on a local-first cross-device communication platform with trust-aware capability execution.

---

## 2. Scope

### In scope for MVP
- local device discovery
- secure pairing
- trust and key management
- capability registry and permission checks
- session lifecycle management
- file transfer
- clipboard sync
- audio output capability

### Out of scope for MVP
- cloud relay service
- enterprise admin policy tooling
- broad device marketplace or plugin ecosystem
- all advanced media types beyond the initial streaming capability

---

## 3. System architecture

### 3.1 Layered architecture

```text
Presentation Layer
  Flutter UI

Application Layer
  Device orchestration
  User action handlers
  Permission UX

Domain Layer
  Identity
  Discovery
  Pairing
  Capability registry
  Session manager
  Authorization
  Protocol models
  Event bus

Infrastructure Layer
  mDNS / DNS-SD
  TLS sockets / WebSockets
  WebRTC
  File transfer
  OS-specific adapters
```

### 3.2 Component boundaries

- UI layer: all user interactions and rendering
- Core domain: protocol-agnostic logic and decision-making
- Native adapters: OS permissions, media capture, audio output, system clipboard access
- Network layer: discovery, transport, and stream management

---

## 4. Core technical decisions

### Decision 1: Core logic in Rust
The protocol and core logic should be implemented in Rust to maximize memory safety, separation from UI, and reusability across device targets.

### Decision 2: Flutter on the client side
Flutter is the recommended user experience layer for cross-platform interfaces.

### Decision 3: OS abstraction through native adapters
Every OS-specific capability should be implemented behind a stable capability interface so the domain layer remains portable.

### Decision 4: Separate transport planes
Control, media, and file transfer must not share a single overloaded channel.

---

## 5. Module design

### 5.1 Identity module

Responsibilities:
- device ID generation
- public/private key generation
- secure local trust storage
- peer identity verification

Key interfaces:
- DeviceIdentity
- KeyPair
- TrustRecord
- IdentityResolver

Required behavior:
- private keys never leave the device
- identity is validated before capability access
- trust relationships are revocable

### 5.2 Discovery module

Responsibilities:
- advertise device metadata on LAN
- scan for peers
- classify peer state as discovered, paired, or blocked

Key interfaces:
- DiscoveryService
- PeerAdvertiser
- PeerResolver
- PeerMetadata

Required behavior:
- detection uses local service discovery, not cloud APIs
- peer metadata contains platform, name, device ID, and capabilities
- discovery does not imply trust

### 5.3 Pairing module

Responsibilities:
- create pairing sessions
- verify peer identity through QR or code exchange
- store trusted device records

Key interfaces:
- PairingCoordinator
- PairingRequest
- PairingResponse
- PairingVerifier

Required behavior:
- user confirms the pairing request
- both sides validate the peer identity and exchanged public keys
- only paired devices can execute privileged capabilities

### 5.4 Capability registry

Responsibilities:
- define supported capabilities
- describe permissions and route targets
- expose runtime capability state

Example capability identifiers:
- audio.output
- audio.input
- clipboard.sync
- file.transfer
- camera.stream
- media.control

Key interfaces:
- CapabilityDescriptor
- CapabilityState
- CapabilityRegistry

Required behavior:
- capabilities are versioned and extensible
- a device advertises only supported capabilities
- the registry can report whether a capability is available, denied, or active

### 5.5 Session manager

Responsibilities:
- create and track active sessions
- manage session lifecycle transitions
- coordinate capability activation and teardown

Key interfaces:
- SessionManager
- Session
- SessionState
- CapabilitySession

Required behavior:
- enforce strict state transitions
- clean up stale sessions on timeout or disconnect
- allow session metadata to persist for diagnostics

### 5.6 Authorization engine

Responsibilities:
- verify request identity
- validate pair status
- check capability permission policy
- confirm OS-level permission

Key interfaces:
- AuthorizationPolicy
- AuthDecision
- CapabilityPermissionStore

Required behavior:
- all request paths must pass authorization before activation
- user consent is recorded as part of the decision
- activity is auditable and diagnosable

### 5.7 Transport layer

Responsibilities:
- manage control plane, media plane, and file plane communication
- maintain connection and renegotiation handling

Key interfaces:
- ControlChannel
- MediaChannel
- FileChannel
- TransportManager

Required behavior:
- control and media traffic remain distinct
- each plane has independent lifecycle rules
- file transfer can resume after interruption

---

## 6. Protocol and data contracts

### 6.1 Discovery payload

```json
{
  "device_id": "01abc...",
  "device_name": "My Phone",
  "platform": "android",
  "protocol_version": 1,
  "capabilities": [
    "audio.output",
    "clipboard.sync",
    "file.transfer"
  ],
  "port": 45678
}
```

### 6.2 Pairing request payload

```json
{
  "request_id": "uuid",
  "device_id": "01abc...",
  "nonce": "random-256-bit",
  "public_key": "base64-encoded-key",
  "timestamp": 1729000000
}
```

### 6.3 Capability request payload

```json
{
  "session_id": "uuid",
  "request_id": "uuid",
  "device_id": "peer-device-id",
  "capability": "audio.output",
  "action": "start",
  "params": {
    "output_device": "default"
  },
  "timestamp": 1729000000
}
```

### 6.4 File transfer payload

```json
{
  "transfer_id": "uuid",
  "file_name": "example.pdf",
  "file_size": 123456,
  "checksum": "sha256",
  "chunk_index": 4,
  "total_chunks": 12,
  "payload": "base64-encoded-data"
}
```

---

## 7. Security requirements

### 7.1 Trust model
- discovery does not imply authorization
- pairing creates an authenticated local trust relation
- device identity is validated before capability execution
- permissions are capability-specific and revocable

### 7.2 Local storage
- private keys remain on-device and never leave the device
- trust records are encrypted at rest
- permission state is local and user-scoped

### 7.3 Attack surface controls
- reject unpaired capability requests
- validate all device IDs and nonces
- enforce authorization before stream startup
- verify session ownership before actions

---

## 8. Control plane design

The control plane is the orchestration layer for trust, capability, and session creation.

### Responsibilities
- discovery metadata exchange
- pairing handshake
- session creation and teardown
- permission policy negotiation
- capability commands

### Transport
- encrypted local socket or WebSocket transport
- TLS or equivalent authenticated channel
- message-based request/response with versioning

---

## 9. Media plane design

The media plane is reserved for real-time streams with high-latency sensitivity.

### Media capabilities to support
- audio output
- microphone input
- camera stream
- display sharing

### Implementation choice
- WebRTC as the default media transport
- separate peer connection per media capability
- session metadata retained in the control plane

### Media lifecycle

```text
capability requested
  -> authorize
  -> create media session
  -> negotiate ICE / SDP
  -> start stream
  -> monitor health
  -> stop / release on teardown
```

---

## 10. File plane design

The file plane is optimized for immutable payload transfer and recovery.

### Functional requirements
- upload/download support
- resumable transfer using chunk index and checksum
- progress status reporting
- cancellation and retry support

### Data handling
- each chunk carries metadata and checksum
- chunk sequences are validated before commit
- incomplete transfers remain recoverable

---

## 11. State machine specification

The system should enforce a strict state model for all capabilities.

```text
DISCOVERED
  -> AVAILABLE
  -> REQUESTED
  -> AUTHORIZED
  -> NEGOTIATING
  -> CONNECTED
  -> ACTIVE
  -> RELEASING
  -> CLOSED
```

### State rules
- a capability cannot move to ACTIVE without authorization
- a disconnected or denied capability cannot remain in ACTIVE
- initialization and teardown must always be explicit

---

## 12. API surface

### 12.1 Core service interfaces

```rust
trait DiscoveryService {
    fn discover(&self) -> Vec<PeerMetadata>;
    fn advertise(&self, metadata: PeerMetadata);
}

trait PairingService {
    fn create_pairing_request(&self, peer: &PeerMetadata) -> PairingRequest;
    fn verify_pairing(&self, response: &PairingResponse) -> Result<TrustRecord, AuthError>;
}

trait CapabilityRegistry {
    fn list_capabilities(&self, device_id: &str) -> Vec<CapabilityDescriptor>;
    fn request_capability(&self, session: &CapabilitySession) -> AuthDecision;
}

trait SessionManager {
    fn create_session(&self, request: CapabilityRequest) -> Session;
    fn update_state(&self, session_id: &str, state: SessionState);
    fn close_session(&self, session_id: &str);
}
```

### 12.2 UI-facing interfaces
- show nearby devices
- show pair status
- request permission
- show transfer progress
- show streaming status

---

## 13. Platform-specific adapters

### Android
- access audio and system features through the Android runtime
- integrate with Android permission model
- handle audio routing and clipboard access according to OS rules

### iOS
- integrate with iOS system APIs for media and file operations
- align with privacy and permission constraints

### Windows
- handle discovery, audio output, clipboard, and file channel semantics using OS-native APIs

### Linux
- use desktop-level permission handling and audio stack integration appropriately

---

## 14. Testing strategy

### Unit tests
- capability authorization logic
- session state transitions
- pairing key verification
- file chunk validation and checksum processing

### Integration tests
- local discovery across peers on the same LAN
- pairing and trust validation
- file transfer under interruption
- media session negotiation and closure

### End-to-end UX tests
- pairing complete flow
- permission prompt flow
- file transfer success path
- audio output flow

### Acceptance tests
- no unpaired device can access protected capabilities
- a denied capability never moves to ACTIVE
- transfer and stream flows cleanly recover from interruption

---

## 15. Risks and mitigation

### Risk: trust bypass by local network assumptions
Mitigation: enforce cryptographic trust validation on every capability activation.

### Risk: media negotiation complexity
Mitigation: isolate WebRTC negotiation behind a stable media capability interface and state model.

### Risk: flaky discovery on some networks
Mitigation: add retry logic and network compatibility checks for LAN discovery.

### Risk: permission confusion in UX
Mitigation: keep prompts capability-scoped and explicit, with clear state reporting.

---

## 16. Definition of done for MVP

The MVP is complete when:
- devices can discover each other locally
- pairing between devices succeeds through a verified flow
- permissioned capability requests are enforced
- file transfer works across paired devices
- clipboard sync works according to explicit policy
- the first media capability works under a supported environment
- diagnostics and failure states are sufficiently clear for product use

---

## 17. Implementation priorities

1. discovery + identity
2. pairing + trust store
3. capability + permission model
4. session manager
5. file transfer
6. clipboard sync
7. media output
8. hardening and release quality

This sequence minimizes the biggest product risk early while enabling real user value quickly.
