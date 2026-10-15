# Narad experimental protocol v1

## Network planes and framing

- mDNS service: `_narad._tcp.local.`. TXT fields: `id`, `name`, `platform`,
  `version`, `key`, `pin`, `capabilities` (comma-separated).
- Control: pinned TLS over TCP, default 45678.
- Files: distinct pinned TLS listener at control port + 1.
- Media: Flutter WebRTC, host candidates only; signaling uses control.
- Local client API: TCP 127.0.0.1:45700 with a private bearer token.

One compact UTF-8 JSON object followed by LF per connection. A connection
carries one request and one response. Remote frames are at most 128 KiB;
local API frames are at most 512 KiB. Limits are checked before JSON parsing.
Peers must advertise a private, loopback or link-local IPv4 address. IPv6 is
not yet supported.

## Public peer card

Fields, in Rust serialization order:

```json
{
  "device_id": "64 lowercase hex characters",
  "device_name": "My laptop",
  "platform": "linux",
  "protocol_version": 1,
  "public_key": "32-byte Ed25519 public key as lowercase hex",
  "certificate_hash": "BLAKE3 of raw TLS certificate DER as lowercase hex",
  "address": "192.168.1.10",
  "port": 45678,
  "capabilities": ["file.transfer", "clipboard.sync"]
}
```

`device_id` is BLAKE3 of the UTF-8 **hex public-key string**. A name is at most
128 UTF-8 bytes; platform is at most 32 ASCII bytes. Capabilities contain at
most 16 nonempty ASCII identifiers, each at most 64 bytes using letters,
numbers, periods or underscores. Discovery never changes trust or permissions.
Audio is advertised only while its client adapter lease is active.

## Signed remote frame

```json
{
  "version": 1,
  "sender": {"...": "peer card"},
  "request_id": "random 32 bytes as 64 lowercase hex characters",
  "timestamp": 1792000000,
  "payload": {"op": "ping"},
  "signature": "64-byte Ed25519 signature as lowercase hex"
}
```

The signed bytes are the compact JSON encoding of
`[version, sender, request_id, timestamp, payload]`. Sender fields follow the
order above; object keys inside `payload` are recursively sorted as Rust's
`serde_json::Map` does. Use UTF-8 strings, standard JSON escapes, no whitespace,
and integral numbers for the initial commands. Remote implementations should
use the Rust models until canonical encoding is formalized for external SDKs.

Messages must be within 60 seconds of the receiver clock. Verified request IDs
are cached with the sender ID for 120 seconds (up to 10,000 entries); replay
state is in memory. A response is another signed frame with:

```json
{"reply_to":"original request_id","result":{"ok":true}}
```

The requester checks the TLS pin, response signature, expected peer key and
pin, timestamp, and request correlation. Errors use
`{"ok":false,"error":"actionable text"}` inside the signed result. TLS
certificate pinning replaces public-CA/name verification; TLS handshake
signatures are still verified. Incoming client identity is proven by the
application signature and checked against local trust records.

## Pairing

The local `invite` command returns:

```json
{"peer":{"...":"peer card"},"nonce":"random 32-byte hex","expires_at":1792000300}
```

Transfer this invitation out-of-band. The requester pins the recipient's
certificate and key, then sends `pair_begin` with the nonce. The nonce is
consumed once and expires after five minutes. Both devices show a code derived
from both public keys and certificate pins plus the invitation nonce:

1. Form `public_key:certificate_hash` for each peer and sort both strings.
2. Hash UTF-8 `Narad pairing v1|<first>|<second>|<nonce>` with BLAKE3.
3. Interpret the first four hash bytes as an unsigned little-endian integer,
   reduce modulo 1,000,000, and format as six digits.

For invitation pairing, the receiver approves after comparing codes. The
requester checks `pair_status` and explicitly confirms the same code before
storing trust.

Privileged requests remain gated by capability permissions after pairing.

Nearby requests use the selected discovered peer's key and certificate pin.
Local `pair_nearby` sends a signed `pair_request`; the receiver generates a fresh
nonce, request ID, verification code and five-minute expiry. Discovery itself
still grants no trust. Sending the request is the initiator's explicit consent.
Receiver `pair_approve` is required; the daemon polls `pair_status` and completes
only its own pending outgoing nearby requests, independently of Flutter. No
invitation or sender-side code-entry/confirmation step is needed. Both screens
show the code for verification before acceptance. Pending requests are bounded
and duplicate pending requests for a peer are rejected. Declines and local
cancellation prevent automatic completion; `pair_cancel` withdraws a reachable
receiver's pending request. Pending requests expire and are not persisted across
process restart; completed trust is persisted. Older clients can keep using
invitation pairing.

## Remote commands

Every command uses a JSON payload containing `op` plus the fields below.

| Control command | Fields | Result and gate |
| --- | --- | --- |
| `pair_begin` | `nonce` | `{id,code}`; valid invitation and signed peer, pending approval |
| `pair_status` | `id` | `status`; pairing owner only; revoked approval reports denied |
| `pair_request` | — | `{id,nonce,code,expires_at}`; signed nearby request, no trust granted |
| `pair_cancel` | `id` | withdraw pending nearby request; signed request owner only |
| `ping` | — | local `device`; trusted peer only |
| `file_offer` | `id,file_name,file_size,checksum` | `transfer`; trusted peer, persistent auto-grant or per-offer acceptance |
| `clipboard_offer` | `text` | new `id`; receive permission, bounded text, automatic delivery if persistently granted |
| `media_offer` | `id`, optional `kind:"camera"` | audio.output or camera.stream session; trusted peer and live adapter, auto-authorized with persistent grant |
| `media_status` | `id` | `session`; owner only |
| `media_signal` | `id,data` | queue SDP/ICE; matching audio/camera permission and authorized owned session |
| `session_close` | `id` | owner-only teardown |
| `browse` | `path` | file.browse; Shared-folder entries, max 256 / 60 KiB |
| `shared_read` | `path,offset` | file.browse; max 48 KiB base64 chunk, size and offset |
| `command_list` | — | command.run; preset IDs and labels, no scripts |
| `command` | `id` | command.run; configured preset, 10s limit, stdout/stderr max 8 KiB each |
| `device_action` | `kind` | device.lock or device.unlock; native action or Linux loginctl |
| `device_action_status` | `id` | owner-only Android action status |

| File-plane command | Fields | Gate |
| --- | --- | --- |
| `file_chunk` | `id,offset,data,checksum` | active owned file session and current permission |
| `file_finish` | `id` | all bytes and whole-file checksum validated |

File IDs are UUIDs. Checksums are lowercase BLAKE3 hex. `data` is standard
base64. Chunks are at most 64 KiB, offsets are byte positions, and files are at
most 1 GiB. A duplicate chunk is accepted only when it exactly matches already
stored bytes. Each acknowledged offset is durably checkpointed. Changed
metadata or ownership cannot reuse a transfer ID.

Completed files publish without replacing an existing destination under
`downloads/<uuid>/<file_name>`. Safe names exclude separators, NUL, `.` and
`..`; at most 240 bytes. Cancellation removes partial bytes and blocks further
writes. Restart preserves approved transfers; revoked/stale sessions require
an explicit local resume. Archived history does not remove downloaded files.

Clipboard text is nonempty UTF-8, at most 16 KiB and contains no NUL. Offers
expire after two minutes. Logs contain IDs and decisions, not clipboard text.

Media `data` is an object of at most 64 KiB. Flutter uses `type: offer` or
`answer` with `sdp`, and `type: candidate` with `candidate`, `sdpMid`, and
`sdpMLineIndex`. The signaling queue is bounded to 256 messages. Audio/camera sessions
require approval or the matching persistent grant; the adapter lease is 15 seconds and renewed every
two seconds. Session inactivity closes after two minutes.

## Local API

Read the 64-character token from `<state-dir>/api-token`. Send:

```json
{"token":"local private token","command":{"op":"status"}}
```

Responses are unsigned `{ok:true,...}` or `{ok:false,error:...}` on loopback.
The token rotates on daemon start. Never expose this listener beyond loopback
or copy the token to peers.

| Operation | Required fields | Purpose |
| --- | --- | --- |
| `status` | optional `offset` | device, discovered/paired peers, permissions, automatic_permissions, presence, shared_directory, local commands, requests, transfers, sessions, clipboard previews, activity |
| `invite` | — | create out-of-band invitation |
| `pair` | `invitation` | initiate invitation pairing |
| `pair_nearby` | `peer` | explicitly request nearby pairing; auto-completes after receiver approval |
| `pair_approve`, `pair_confirm` | `id,code` | receiver approval / requester confirmation |
| `pair_deny` | `id` | reject pending pairing |
| `permission` | `peer_id,capability,allow`, optional `automatic` (default true) | grant/revoke capability; revocation closes matching sessions |
| `unpair` | `peer_id` | remove trust, permissions and active state |
| `send_file` | `peer_id,path`, optional `id` | offer or retry/resume an outgoing transfer |
| `file_accept`, `file_resume`, `file_cancel` | `id` | explicit receiver transfer decisions |
| `archive_transfer` | `id,outgoing` | archive completed/cancelled metadata, retain completed download |
| `send_clipboard` | `peer_id,text` | offer clipboard text |
| `clipboard_accept`, `clipboard_deny` | `id` | return accepted text once / discard it |
| `ping_peer` | `peer_id` | check a paired endpoint |
| `media_ready` | `ready` or `audio_ready,camera_ready` | renew/release separate native adapter leases |
| `media_start` | `peer_id`, optional `kind:"camera"` | request new audio/camera session |
| `media_accept`, `media_deny` | `id` | receiver media decision |
| `media_poll` | `peer_id,id` | read peer session decision |
| `media_send` | `peer_id,id,data` | send authorized signaling |
| `media_events` | — | consume local signaling queue |
| `media_state` | `id,state` | update guarded media lifecycle |
| `session_touch` | `id` | keep an existing nonterminal session live |
| `session_stop` | `peer_id,id` | close local session, request peer teardown |

Additional local operations: `browse_peer(peer_id,path)`,
`read_shared(peer_id,path,offset)`, `download_shared(peer_id,path)` (new private
UUID download, max 1 GiB), `command_set(label,script,id?)`, `command_remove(id)`,
`list_commands(peer_id)`, `run_command(peer_id,id)`,
`device_action(peer_id,kind)` and `device_action_status(peer_id,id)`.
The private native adapter uses `platform_events`, `platform_validate(id)` and
`platform_result(id,success,message)`; actions expire after 60 seconds and are
rechecked against current permissions before execution. Automatic clipboard
items are consumed by `platform_events` on Android and by the Flutter client on
desktop. No clipboard contents or preset scripts/output are activity-logged.

Presence is checked over authenticated TLS every five seconds with a three-second
network timeout. Status includes online, checked_at and optional last_seen for
each paired peer; mDNS alone never establishes online status. Automatic permissions
are keyed like permissions; old trust records default to an empty automatic map.

The CLI `call '<json>'` exposes all operations. Status history pages contain
at most 32 entries per collection. Increase `offset` by 32 while `has_more` is
true; the Flutter client merges pages. Permissions are keyed by
`<peer-id>/<capability>`. Control, file and local API connection budgets are
16, 16 and 8 respectively. Transfers retain at most 256 records per direction;
archive terminal entries to make room.

## Session lifecycle

`requested → authorized → negotiating → connected → active → releasing → closed`

Requested sessions may be denied. Nonterminal sessions may fail or release
when cancelled, revoked, disconnected or expired. An active session can never
be reached by skipping approval, and terminal sessions cannot reactivate.
File resume creates a fresh authorized in-memory lifecycle for the persisted
transfer ID after local approval. Ownership and current permissions are checked
again on every privileged data operation.
