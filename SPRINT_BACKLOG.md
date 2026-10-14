# Narad Sprint Backlog

## 1. Sprint planning principles

This backlog is structured around the MVP value chain and the underlying trust model. The team should not begin with broad media features before the local trust and pairing model is production-worthy.

Priorities are ordered as:

1. trust and identity
2. control plane and session model
3. file and clipboard workflows
4. media and stream reliability
5. scalability and ecosystem compatibility

---

## 2. Sprint 1: Local discovery foundation

### Goal
Create the discovery layer for nearby devices on the LAN.

### Stories
- As a user, I can see nearby devices in a list
- As a user, I can see peer metadata and platform information
- As the system, I can advertise device identity over the LAN
- As the system, I can handle peer metadata updates and disappearances

### Deliverables
- discovery service
- peer registry
- device metadata schema
- basic discovery UI

### Acceptance criteria
- peer list refreshes reliably on network changes
- unknown or unpaired peers are visible but not trusted
- discovery is local-only and does not require cloud access

---

## 3. Sprint 2: Pairing and trust establishment

### Goal
Add secure, user-visible pairing between trusted devices.

### Stories
- As a user, I can pair a device using QR code
- As a user, I can pair a device using a numeric verification code
- As the system, I can generate and validate keypairs safely
- As the system, I can persist trust records locally

### Deliverables
- pair request + verify workflow
- key generation and secure storage
- local trust state
- pairing UI and failure states

### Acceptance criteria
- pairing succeeds only after verification
- paired devices store trusted keys locally
- invalid or mismatched pair attempts fail cleanly

---

## 4. Sprint 3: Session model and control plane

### Goal
Define how capabilities are requested, authorized, and managed during runtime.

### Stories
- As a user, I can request a device capability
- As the system, I can enforce authorization before capability activation
- As the system, I can maintain session state through lifecycle transitions
- As a user, I can see the active status of a session

### Deliverables
- capability registry
- session state machine
- command channel framework
- authorization engine

### Acceptance criteria
- a capability request enters a deterministic lifecycle
- unauthorized actions are rejected before session creation
- session termination is handled cleanly

---

## 5. Sprint 4: Permission model and policy enforcement

### Goal
Turn the capability registry into an enforceable user approval system.

### Stories
- As a user, I can grant or deny device capabilities
- As the system, I can store explicit permissions
- As a user, I can revoke or update permission later
- As the system, I can prevent access when the OS denies a request

### Deliverables
- permission policy schema
- grant/deny UX
- revocation flows
- policy enforcement hooks

### Acceptance criteria
- permission checks are specific to capability, not global device access
- permission changes propagate to new sessions
- a denied request surfaces a clear error and no session is created

---

## 6. Sprint 5: File transfer MVP

### Goal
Deliver a basic, reliable file-transfer workflow.

### Stories
- As a user, I can send a file to a paired device
- As a user, I can receive a file from a paired device
- As the system, I can show transfer progress and status
- As the system, I can retry or resume when interrupted

### Deliverables
- file transfer channel
- chunking and resume strategy
- progress events
- transfer UI and error handling

### Acceptance criteria
- files transfer successfully over the LAN
- interrupted transfers can be resumed or restarted
- transfer requires explicit user intent and authorization

---

## 7. Sprint 6: Clipboard and productivity sync

### Goal
Ship the first non-file productivity feature in a controlled, privacy-safe way.

### Stories
- As a user, I can approve clipboard sync between paired devices
- As the system, I can transmit clipboard payloads only within an active session
- As a user, I can reject or ignore sync data
- As the system, I can prevent unsafe clipboard propagation

### Deliverables
- clipboard sync service
- sync policy enforcement
- approval UX
- clipboard event logging

### Acceptance criteria
- clipboard sync occurs only with explicit approval
- sync flow fails gracefully when permissions are absent
- invalid payloads are rejected safely

---

## 8. Sprint 7: Media negotiation foundation

### Goal
Build a real-time media connection framework for audio or screen-based use cases.

### Stories
- As a system, I can establish a WebRTC media session
- As a user, I can request a media session for a capability
- As the system, I can manage candidates and connection state
- As the system, I can reject media requests without leaving stale sessions

### Deliverables
- WebRTC negotiation layer
- media session state model
- capability-specific stream handlers
- negotiation error handling

### Acceptance criteria
- a media session can be established and torn down cleanly
- negotiation failures are surfaced without crashing the app
- media session lifecycle integrates with the authorization flow

---

## 9. Sprint 8: Audio output and media reliability

### Goal
Make the first real media capability usable on supported devices.

### Stories
- As a user, I can request audio output from a paired device
- As the system, I can authorize and start the stream
- As a user, I can stop the stream at any time
- As the system, I can recover or clean up from a disrupted stream

### Deliverables
- audio output capability implementation
- stream lifecycle controls
- media health checks
- restart and cleanup logic

### Acceptance criteria
- audio stream starts only after approval
- stream can be stopped without leaving active state behind
- transient failures are handled gracefully

---

## 10. Sprint 9: Observability, reliability, and QA

### Goal
Harden the system before public readiness.

### Stories
- As a developer, I can inspect device and session health
- As the system, I can log permission, connection, and transfer failures
- As the team, I can validate behavior under interrupted network conditions
- As the product, I can deliver clear user-facing failure states

### Deliverables
- telemetry and diagnostics
- load and failure testing
- UX error states
- stability fixes

### Acceptance criteria
- the system handles temporary network loss without silent failure
- diagnostics support debugging of trust and session problems
- user-visible errors are actionable and understandable

---

## 11. Sprint 10: Release candidate

### Goal
Prepare a production-quality release candidate version.

### Stories
- As a release manager, I can validate the product against exit criteria
- As the product team, I can verify security and trust assumptions
- As a user, I can complete the full local pairing and capability workflow reliably

### Deliverables
- release candidate build
- QA checklist
- docs and known limitations
- release notes and support readiness

### Acceptance criteria
- core user journeys pass end-to-end
- no critical trust bypass conditions remain
- release notes accurately describe scope and limitations

---

## 12. Backlog health rules

- No sprint should begin without a secure trust pathway
- No media feature should be planned without authorization and session support
- No transfer or stream feature should skip failure handling
- The team should keep the protocol versioned and backward-aware

---

## 13. Definition of done

A backlog item is done when:

- the work is implemented and reviewed
- tests cover the main happy path and a failure path
- UI or CLI behavior matches the requirement
- permission and security checks are enforced
- the feature is observable through logs or status states

---

## 14. Priority ranking

1. device discovery and peer trust
2. pairing and key management
3. capability registry and permissions
4. session lifecycle model
5. file transfer
6. clipboard sync
7. media stream support
8. release hardening
9. ecosystem compatibility
