# Narad Roadmap

## 1. Product direction

The Narad roadmap is built around a phased delivery model to validate the core local-first experience before expanding to more advanced device capabilities.

The guiding strategy is:

1. Validate trust and pairing
2. Prove local capability-based sessions work reliably
3. Expand to file transfer and media features
4. Harden security and operational quality
5. Prepare for external client compatibility

---

## 2. Delivery strategy

The roadmap is organized into four major phases:

- Phase 1: Foundation and trust
- Phase 2: Inter-device capability workflows
- Phase 3: Media and file transfer
- Phase 4: Hardening and ecosystem expansion

Each phase maps to a milestone with concrete deliverables and exit criteria.

---

## 3. Milestone overview

| Milestone | Target period | Goal | Exit criteria |
| --- | --- | --- | --- |
| M1 - Core trust foundation | Sprint 1-2 | Local discovery + pairing + secure identity | Devices can discover each other and establish a trusted pair |
| M2 - Capability session layer | Sprint 3-4 | Control plane + permissioned sessions | Capability requests and session lifecycle are stable |
| M3 - File + productivity flows | Sprint 5-7 | Clipboard and file transfer | Transfer flows are functional and observable |
| M4 - Media and release readiness | Sprint 8-10 | Audio sharing + production hardening | Media sessions are reliable and ready for release |
| M5 - Ecosystem expansion | Sprint 11-12 | Versioned protocol + optimization | Additional clients and capability expansion supported |

---

## 4. Phase-by-phase roadmap

### Phase 1: Foundation and trust

#### Objective
Establish the local network trust model and create the minimum viable peer-to-peer communication layer.

#### Deliverables
- device discovery service
- peer identity model
- secure key generation and storage
- QR-based pairing flow
- trust store and pairing record management
- local control channel handshake

#### Key outputs
- A device can discover a nearby peer on the LAN
- A pair can be created securely using QR or numeric verification
- Session state can be created, attached to a trusted peer, and closed cleanly

#### Exit criteria
- Discovery identifies nearby peers with metadata
- Pairing completes successfully for at least two supported platforms
- Pairing records are stored locally and validated before each interaction
- Unpaired devices cannot access protected capabilities

---

### Phase 2: Capability session layer

#### Objective
Create a stable control plane and capability-based session model that governs authorization and runtime access.

#### Deliverables
- capability registry
- session lifecycle state machine
- permission request and approval UX
- authorization engine
- event bus and command routing
- capability-specific activity tracking

#### Key outputs
- Device capabilities are advertised and enumerated
- User approval gates session activation
- Capability lifecycle supports request, authorize, active, and teardown states

#### Exit criteria
- A capability can be requested and denied or granted consistently
- Session lifecycle transitions are deterministic and observable
- User-facing UI reflects current permission state accurately

---

### Phase 3: File and productivity flows

#### Objective
Ship the MVP productivity value set: clipboard and file transfer.

#### Deliverables
- file transfer service
- resumable transfer chunking
- transfer status and progress UX
- clipboard sync service
- permission-aware clipboard policy
- cancellation and retry logic

#### Key outputs
- Files can be transferred securely across paired devices
- Clipboard sync works only with explicit user approval
- Interrupted transfers recover gracefully

#### Exit criteria
- File transfer succeeds for multiple file sizes and interrupted states
- Clipboard sync is opt-in and well-scoped
- Users can view and understand permission outcomes clearly

---

### Phase 4: Media and production hardening

#### Objective
Introduce low-latency media sharing and prepare the system for a public-facing release.

#### Deliverables
- WebRTC media negotiation layer
- audio output capability
- camera or display stream capability
- media lifecycle monitoring
- health checks and telemetry
- release instrumentation and crash handling

#### Key outputs
- Streaming is stable on a LAN
- Media session lifecycle is monitored and recoverable
- Bugs or permission errors are surfaced clearly to users

#### Exit criteria
- Audio output capability works on supported platforms
- Media connections recover from transient issues
- Release candidate passes core reliability, security, and UX checks

---

### Phase 5: Ecosystem expansion

#### Objective
Make the core protocol reusable by other clients and support additional capabilities without redesign.

#### Deliverables
- versioned protocol docs
- capability schema versioning
- compatibility testing across clients
- plugin model or extension registry
- developer onboarding documentation

#### Key outputs
- external clients can build compatible implementations
- capability model remains extensible
- product has a clear path beyond the first deployment

#### Exit criteria
- A new capability can be added without breaking the base protocol
- Compatibility test suite validates protocol behavior
- Developer documentation is sufficient for partner integration

---

## 5. Suggested sprint breakdown

### Sprint 1: discovery and peer registry
- explore discovery mechanisms
- define peer metadata schema
- create local network advertisement layer
- build peer list UI

### Sprint 2: pairing and trust
- implement QR and numeric pairing
- generate and store keypairs
- add trust records and validation hooks
- test pairing failure and edge cases

### Sprint 3: control plane and session manager
- implement session states
- add command channel framework
- start authorization engine
- create permission prompts

### Sprint 4: capability registry and authorization
- finalize capability definitions
- complete policy checks
- add session state transitions
- validate device-to-device requests end-to-end

### Sprint 5: file transfer foundation
- define transfer protocol
- implement chunking and status model
- add upload/download flows
- test cancellation and retries

### Sprint 6: clipboard sync and validation
- implement clipboard sync service
- add approval and policy checks
- complete end-to-end validation
- polish transfer UX

### Sprint 7: WebRTC media foundation
- integrate WebRTC negotiation
- create media session model
- manage candidate exchange
- verify connectivity under LAN conditions

### Sprint 8: audio and stream lifecycle
- implement audio output capability
- add stream resume/reconnect logic
- validate user controls and stop flows

### Sprint 9: hardening and observability
- telemetry and diagnostics
- failure state messaging
- edge-case bug fixes
- UX cleanup and reliability improvements

### Sprint 10: release candidate
- complete QA passes
- finalize docs and trust workflows
- cut release candidate build
- verify product acceptance criteria

### Sprint 11: ecosystem compatibility
- protocol versioning and docs
- third-party compatibility checks
- support additional client types

### Sprint 12: roadmap optimization and next release planning
- collect system metrics
- identify next growth capabilities
- refine roadmap for next iteration

---

## 6. Milestone deliverables

### M1 deliverables
- working local peer discovery
- secure pairing mechanism
- trust relationship persistence
- minimal control channel

### M2 deliverables
- capability registry
- permission model
- session lifecycle state machine
- UI for capability requests and approvals

### M3 deliverables
- file transfer with status tracking
- clipboard sync with approval gates
- retry / cancellation semantics

### M4 deliverables
- real-time audio output capability
- WebRTC session handling
- production reliability and telemetry

### M5 deliverables
- versioned protocol documentation
- wider client compatibility pathway
- next-generation capability extension model

---

## 7. Success metrics at each milestone

- M1: pairing works between at least two supported devices
- M2: capability requests succeed correctly with authorization enforcement
- M3: file and clipboard flows are reliable under normal LAN conditions
- M4: media session remains stable and user-observable
- M5: protocol remains extensible and compatible across client implementations

---

## 8. Recommended release posture

The most realistic launch posture is:

- MVP: local discovery, pairing, file transfer, clipboard sync, and audio output
- Post-MVP: camera sharing, display sharing, richer device control, and additional capability expansion

This keeps product value high while reducing engineering risk early.
