use crate::{
    state::{ClipboardOffer, Pairing, Signal, State},
    transport::remote_call,
};
use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use narad_core::{
    identity::{pairing_code, random_token},
    model::{now, Invitation, Peer, SessionState, TrustRecord},
    policy::permission_key,
    transfer::{hash_file, Transfer, MAX_FILE_SIZE},
    CHUNK_SIZE,
};
use serde_json::{json, Value};
use std::{
    io::{Read, Seek, SeekFrom},
    path::Path,
    sync::Arc,
};
use tokio::sync::Mutex;

pub fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().with_context(|| format!("missing {key}"))
}
pub(crate) fn number(v: &Value, key: &str) -> Result<u64> {
    v[key].as_u64().with_context(|| format!("missing {key}"))
}
fn media_capability(payload: &Value) -> Result<&'static str> {
    match payload["kind"].as_str() {
        Some("camera") => Ok("camera.stream"),
        Some("microphone") => Ok("audio.input"),
        Some("audio") => Ok("audio.output"),
        None if payload["kind"].is_null() => Ok("audio.output"),
        _ => anyhow::bail!("unsupported media kind"),
    }
}

fn capability(v: &Value) -> Result<&str> {
    let c = string(v, "capability")?;
    ensure!(
        [
            "file.transfer",
            "clipboard.sync",
            "audio.output",
            "audio.input",
            "camera.stream",
            "file.browse",
            "file.upload",
            "command.run",
            "device.find",
            "device.lock",
            "device.unlock"
        ]
        .contains(&c)
            || crate::phone::CAPABILITIES.contains(&c),
        "unsupported capability"
    );
    Ok(c)
}
fn ok() -> Value {
    json!({"ok":true})
}

pub fn remote(s: &mut State, peer: &Peer, p: &Value, file_plane: bool) -> Result<Value> {
    s.expire();
    let op = string(p, "op")?;
    ensure!(
        file_plane == matches!(op, "file_chunk" | "file_finish"),
        "command sent on wrong transport plane"
    );
    if op == "pair_request" {
        ensure!(peer.device_id != s.own.device_id, "cannot pair with self");
        ensure!(
            !s.trust.peers.contains_key(&peer.device_id),
            "device already paired"
        );
        ensure!(s.pairings.len() < 32, "too many pairing requests");
        ensure!(
            !s.pairings
                .values()
                .any(|p| p.peer.device_id == peer.device_id && p.status == "pending"),
            "pairing request already pending"
        );
        let id = uuid::Uuid::new_v4().to_string();
        let nonce = random_token();
        let code = pairing_code(&s.own, peer, &nonce);
        let expires_at = now() + 300;
        s.pairings.insert(
            id.clone(),
            Pairing {
                id: id.clone(),
                peer: peer.clone(),
                nonce: nonce.clone(),
                code: code.clone(),
                expires_at,
                status: "pending".into(),
                outgoing: false,
                nearby: true,
            },
        );
        s.event(
            "pairing.requested",
            json!({"id":id,"peer_id":peer.device_id,"nearby":true}),
        );
        return Ok(json!({"ok":true,"id":id,"nonce":nonce,"code":code,"expires_at":expires_at}));
    }
    if op == "pair_begin" {
        let nonce = string(p, "nonce")?;
        let invitation = s
            .invitations
            .get(nonce)
            .context("pairing invitation expired or used")?
            .clone();
        invitation.validate()?;
        ensure!(peer.device_id != s.own.device_id, "cannot pair with self");
        ensure!(s.pairings.len() < 32, "too many pairing requests");
        s.invitations.remove(nonce);
        let id = uuid::Uuid::new_v4().to_string();
        let code = pairing_code(&s.own, peer, nonce);
        s.pairings.insert(
            id.clone(),
            Pairing {
                id: id.clone(),
                peer: peer.clone(),
                nonce: nonce.into(),
                code: code.clone(),
                expires_at: invitation.expires_at,
                status: "pending".into(),
                outgoing: false,
                nearby: false,
            },
        );
        s.event(
            "pairing.requested",
            json!({"id":id,"peer_id":peer.device_id}),
        );
        return Ok(json!({"ok":true,"id":id,"code":code}));
    }
    if op == "pair_cancel" {
        let pair = s
            .pairings
            .get_mut(string(p, "id")?)
            .context("pairing expired")?;
        ensure!(
            pair.nearby && !pair.outgoing && pair.status == "pending",
            "pairing is not pending"
        );
        ensure!(
            pair.peer.public_key == peer.public_key
                && pair.peer.certificate_hash == peer.certificate_hash,
            "pairing owner mismatch"
        );
        pair.status = "denied".into();
        return Ok(ok());
    }
    if op == "pair_status" {
        let pair = s
            .pairings
            .get(string(p, "id")?)
            .context("pairing expired")?;
        ensure!(
            pair.peer.public_key == peer.public_key
                && pair.peer.certificate_hash == peer.certificate_hash,
            "pairing owner mismatch"
        );
        let status = if pair.status == "approved" && !s.trust.peers.contains_key(&peer.device_id) {
            "denied"
        } else {
            &pair.status
        };
        return Ok(json!({"ok":true,"status":status}));
    }
    s.trust.authenticate(peer)?;
    // Authenticated metadata can refresh the address after a network change.
    if let Some(record) = s.trust.peers.get_mut(&peer.device_id) {
        record.peer.address = peer.address.clone();
        record.peer.port = peer.port;
    }
    s.note_presence(&peer.device_id, true);
    match op {
        "ping" => Ok(json!({"ok":true,"device":s.own})),
        "file_offer" => {
            let id = string(p, "id")?;
            ensure!(uuid::Uuid::parse_str(id).is_ok(), "invalid transfer ID");
            if let Some(t) = s.transfers.get(id) {
                ensure!(
                    t.peer_id == peer.device_id
                        && t.checksum == string(p, "checksum")?
                        && t.file_size == number(p, "file_size")?
                        && t.file_name == string(p, "file_name")?,
                    "transfer metadata or ownership changed"
                );
                return Ok(json!({"ok":true,"transfer":t}));
            }
            ensure!(
                s.transfers.len() < 256,
                "transfer history full; archive completed transfers before receiving more"
            );
            ensure!(
                s.trust
                    .permissions
                    .get(&permission_key(&peer.device_id, "file.transfer"))
                    != Some(&false),
                "file transfer permission denied"
            );
            let t = Transfer {
                id: id.into(),
                peer_id: peer.device_id.clone(),
                file_name: string(p, "file_name")?.into(),
                file_size: number(p, "file_size")?,
                checksum: string(p, "checksum")?.into(),
                received: 0,
                status: "pending".into(),
                updated_at: now(),
            };
            t.validate()?;
            t.persist(&s.dir.join("transfers"), &s.identity.storage_key())?;
            s.transfers.insert(id.into(), t);
            s.event("file.offered", json!({"id":id,"peer_id":peer.device_id}));
            if s.automatic(&peer.device_id, "file.transfer") {
                s.approve_file(id)?;
            }
            Ok(json!({"ok":true,"transfer":s.transfers[id]}))
        }
        "file_chunk" | "file_finish" => {
            let id = string(p, "id")?;
            s.session(id, peer, "file.transfer")?;
            let t = s.transfers.get_mut(id).context("unknown transfer")?;
            ensure!(t.peer_id == peer.device_id, "transfer ownership mismatch");
            let dir = s.dir.join("transfers");
            let key = s.identity.storage_key();
            if op == "file_chunk" {
                t.append(
                    &dir,
                    &key,
                    number(p, "offset")?,
                    &STANDARD.decode(string(p, "data")?)?,
                    string(p, "checksum")?,
                )?;
                s.sessions.get_mut(id).unwrap().updated_at = now();
                Ok(json!({"ok":true,"received":t.received}))
            } else {
                let path = t.finish(&dir, &key, &s.dir.join("downloads"))?;
                s.sessions.get_mut(id).unwrap().close();
                s.event("file.completed", json!({"id":id}));
                Ok(json!({"ok":true,"path":path}))
            }
        }
        "clipboard_offer" | "clipboard_push" => {
            if op == "clipboard_push" {
                ensure!(
                    s.preferences.clipboard_sync,
                    "Automatic clipboard sync is off"
                );
                ensure!(
                    s.automatic(&peer.device_id, "clipboard.sync"),
                    "Automatic clipboard permission denied"
                );
            }
            s.trust.authorize(peer, "clipboard.sync", true)?;
            let text = string(p, "text")?;
            ensure!(
                !text.is_empty() && text.len() <= 16384 && !text.contains('\0'),
                "invalid clipboard text"
            );
            ensure!(s.clipboard.len() < 32, "clipboard inbox full");
            let id = uuid::Uuid::new_v4().to_string();
            s.new_session(&id, &peer.device_id, "clipboard.sync", true)?;
            s.clipboard.insert(
                id.clone(),
                ClipboardOffer {
                    id: id.clone(),
                    peer_id: peer.device_id.clone(),
                    text: text.into(),
                    status: if s.automatic(&peer.device_id, "clipboard.sync") {
                        "automatic"
                    } else {
                        "pending"
                    }
                    .into(),
                    expires_at: now() + 120,
                },
            );
            s.event("clipboard.offered", json!({"id":id}));
            Ok(json!({"ok":true,"id":id}))
        }
        "media_offer" => {
            let cap = media_capability(p)?;
            ensure!(
                match cap {
                    "camera.stream" => s.camera_ready,
                    "audio.input" => s.microphone_ready,
                    _ => s.media_ready,
                },
                "media must be enabled on the receiving device"
            );
            ensure!(
                s.trust
                    .permissions
                    .get(&permission_key(&peer.device_id, cap))
                    != Some(&false),
                "media permission denied"
            );
            let id = string(p, "id")?;
            ensure!(uuid::Uuid::parse_str(id).is_ok(), "invalid session ID");
            s.new_session(id, &peer.device_id, cap, s.automatic(&peer.device_id, cap))?;
            s.event("media.requested", json!({"id":id,"peer_id":peer.device_id}));
            Ok(ok())
        }
        "media_status" => {
            let session = s
                .sessions
                .get(string(p, "id")?)
                .context("unknown session")?;
            ensure!(
                session.peer_id == peer.device_id,
                "session ownership mismatch"
            );
            Ok(json!({"ok":true,"session":session}))
        }
        "media_signal" => {
            let id = string(p, "id")?;
            let cap = s
                .sessions
                .get(id)
                .context("unknown session")?
                .capability
                .clone();
            ensure!(
                match cap.as_str() {
                    "camera.stream" => s.camera_ready,
                    "audio.input" if !s.outgoing_media.contains(id) => s.microphone_ready,
                    _ => s.media_ready,
                },
                "media client disconnected"
            );
            s.session(id, peer, &cap)?;
            ensure!(
                serde_json::to_vec(&p["data"])?.len() <= 65536 && p["data"].is_object(),
                "invalid media signal"
            );
            ensure!(s.signals.len() < 256, "media signal queue full");
            s.signals.push(Signal {
                session_id: id.into(),
                peer_id: peer.device_id.clone(),
                data: p["data"].clone(),
            });
            s.sessions.get_mut(id).unwrap().updated_at = now();
            Ok(ok())
        }
        "session_close" => {
            let id = string(p, "id")?;
            let session = s.sessions.get_mut(id).context("unknown session")?;
            ensure!(
                session.peer_id == peer.device_id,
                "session ownership mismatch"
            );
            session.close();
            s.signals.retain(|signal| signal.session_id != id);
            Ok(ok())
        }
        _ => anyhow::bail!("unsupported remote command"),
    }
}

pub async fn local(shared: Arc<Mutex<State>>, p: Value) -> Result<Value> {
    let op = string(&p, "op")?.to_string();
    if matches!(
        op.as_str(),
        "share_add"
            | "share_remove"
            | "share_uploads"
            | "upload_shared"
            | "storage_jobs"
            | "storage_validate"
            | "storage_result"
    ) {
        return crate::sharing::local(shared, &p).await;
    }
    if op == "clipboard_publish" {
        return crate::clipboard::publish(shared, &p).await;
    }
    if matches!(
        op.as_str(),
        "phone_request" | "phone_bridge_ready" | "phone_jobs" | "phone_validate" | "phone_result"
    ) {
        return crate::phone::local(shared, &p).await;
    }
    if matches!(
        op.as_str(),
        "pair"
            | "pair_nearby"
            | "pair_confirm"
            | "send_file"
            | "send_clipboard"
            | "media_start"
            | "media_poll"
            | "media_send"
            | "session_stop"
            | "ping_peer"
            | "browse_peer"
            | "read_shared"
            | "download_shared"
            | "run_command"
            | "list_commands"
            | "device_action"
            | "device_action_status"
    ) {
        return outgoing(shared, &op, &p).await;
    }
    let mut s = shared.lock().await;
    s.expire();
    match op.as_str() {
        "clipboard_sync" => {
            s.preferences.clipboard_sync =
                p["enabled"].as_bool().context("Expected enabled boolean")?;
            s.save_preferences()?;
            s.clipboard_digest = None;
            Ok(ok())
        }
        "status" => {
            let offset = p["offset"].as_u64().unwrap_or(0) as usize;
            let clipboard=s.clipboard.values().skip(offset).take(32).map(|c|json!({"id":c.id,"peer_id":c.peer_id,"status":c.status,"preview":c.text.chars().take(160).collect::<String>(),"expires_at":c.expires_at})).collect::<Vec<_>>();
            Ok(
                json!({"ok":true,"device":s.own,"paired":s.trust.peers.iter().skip(offset).take(32).collect::<std::collections::BTreeMap<_,_>>(),"automatic_permissions":s.trust.automatic.iter().skip(offset).take(256).collect::<std::collections::BTreeMap<_,_>>(),"presence":s.presence,"shared_directory":s.dir.join("shared"),"clipboard_sync":s.preferences.clipboard_sync,"shared_folders":s.preferences.shares,"commands":s.commands.values().collect::<Vec<_>>(),"permissions":s.trust.permissions.iter().skip(offset).take(96).collect::<std::collections::BTreeMap<_,_>>(),"pairings":s.pairings.values().skip(offset).take(32).collect::<Vec<_>>(),"transfers":s.transfers.values().skip(offset).take(32).collect::<Vec<_>>(),"sessions":s.sessions.values().skip(offset).take(32).collect::<Vec<_>>(),"clipboard":clipboard,"events":s.events.iter().rev().take(100).collect::<Vec<_>>(),"outbound":s.outbound.values().skip(offset).take(32).collect::<Vec<_>>(),"media_ready":s.media_ready,"camera_ready":s.camera_ready,"microphone_ready":s.microphone_ready,"offset":offset,"has_more":([s.trust.peers.len(),s.pairings.len(),s.transfers.len(),s.sessions.len(),s.clipboard.len(),s.outbound.len()].into_iter().max().unwrap_or(0)>offset+32)}),
            )
        }
        "command_set" => {
            ensure!(
                s.commands.len() < 32
                    || p["id"]
                        .as_str()
                        .is_some_and(|id| s.commands.contains_key(id)),
                "maximum 32 command presets"
            );
            let id = p["id"]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
            ensure!(uuid::Uuid::parse_str(&id).is_ok(), "invalid command ID");
            let label = string(&p, "label")?.trim();
            let script = string(&p, "script")?;
            ensure!(
                !label.is_empty()
                    && label.len() <= 80
                    && !script.trim().is_empty()
                    && script.len() <= 4096
                    && !script.contains('\0'),
                "invalid command preset"
            );
            let mut commands = s.commands.clone();
            commands.insert(
                id.clone(),
                crate::state::SavedCommand {
                    id: id.clone(),
                    label: label.into(),
                    script: script.into(),
                },
            );
            narad_core::storage::save_encrypted(
                &s.dir.join("commands.json.enc"),
                &s.identity.storage_key(),
                &commands,
            )?;
            s.commands = commands;
            Ok(json!({"ok":true,"id":id}))
        }
        "command_remove" => {
            let mut commands = s.commands.clone();
            commands
                .remove(string(&p, "id")?)
                .context("unknown command")?;
            narad_core::storage::save_encrypted(
                &s.dir.join("commands.json.enc"),
                &s.identity.storage_key(),
                &commands,
            )?;
            s.commands = commands;
            Ok(ok())
        }
        "platform_events" => crate::controls::platform_events(&mut s),
        "platform_error" => {
            ensure!(p["kind"] == "clipboard.failed", "unknown platform error");
            s.event("clipboard.failed", json!({}));
            Ok(ok())
        }
        "platform_validate" => {
            let action = s
                .platform_actions
                .get(string(&p, "id")?)
                .context("action expired")?;
            ensure!(
                action.status == "dispatched"
                    || (action.kind == "find"
                        && action.status == "completed"
                        && action.expires_at > narad_core::model::now()),
                "action no longer pending"
            );
            s.trust
                .authorize(&s.peer(&action.peer_id)?, &action.capability, true)?;
            Ok(ok())
        }
        "platform_result" => {
            let id = string(&p, "id")?;
            let action = s.platform_actions.get_mut(id).context("action expired")?;
            ensure!(action.status == "dispatched", "action not dispatched");
            action.status = if p["success"] == true {
                "completed"
            } else {
                "failed"
            }
            .into();
            action.message = p["message"]
                .as_str()
                .unwrap_or("")
                .chars()
                .take(256)
                .collect();
            Ok(ok())
        }
        "network_address" => {
            let mut peer = s.own.clone();
            peer.address = string(&p, "address")?.into();
            peer.validate()?;
            s.own = peer;
            Ok(ok())
        }
        "device_name" => {
            let mut peer = s.own.clone();
            peer.device_name = string(&p, "name")?.trim().into();
            peer.validate()?;
            s.own = peer;
            Ok(ok())
        }
        "invite" => {
            ensure!(s.invitations.len() < 16, "too many open invitations");
            let invitation = Invitation {
                peer: s.own.clone(),
                nonce: random_token(),
                expires_at: now() + 300,
            };
            s.invitations
                .insert(invitation.nonce.clone(), invitation.clone());
            Ok(json!({"ok":true,"invitation":invitation}))
        }
        "pair_approve" => {
            let id = string(&p, "id")?;
            let pair = s.pairings.get(id).context("pairing expired")?.clone();
            ensure!(
                !pair.outgoing && pair.status == "pending",
                "pairing is not awaiting approval"
            );
            ensure!(
                pair.code == string(&p, "code")?,
                "pairing verification code mismatch"
            );
            s.trust.peers.insert(
                pair.peer.device_id.clone(),
                TrustRecord {
                    peer: pair.peer.clone(),
                    paired_at: now(),
                },
            );
            s.save_trust()?;
            s.pairings.get_mut(id).unwrap().status = "approved".into();
            s.event("pairing.approved", json!({"peer_id":pair.peer.device_id}));
            Ok(ok())
        }
        "pair_deny" => {
            let id = string(&p, "id")?;
            let pair = s.pairings.get(id).context("unknown pairing")?.clone();
            ensure!(pair.status == "pending", "pairing is not pending");
            s.pairings.get_mut(id).unwrap().status = if pair.nearby && pair.outgoing {
                "cancelled"
            } else {
                "denied"
            }
            .into();
            if pair.nearby && pair.outgoing {
                let identity = s.identity.clone();
                let own = s.own.clone();
                drop(s);
                // Local withdrawal is final even if the other device went offline.
                let _ = remote_call(
                    &identity,
                    &own,
                    &pair.peer,
                    false,
                    json!({"op":"pair_cancel","id":id}),
                )
                .await;
            }
            Ok(ok())
        }
        "permission" => {
            let id = string(&p, "peer_id")?;
            s.peer(id)?;
            let cap = capability(&p)?;
            let allow = p["allow"]
                .as_bool()
                .context("missing permission decision")?;
            s.trust.permissions.insert(permission_key(id, cap), allow);
            let automatic = allow && p["automatic"].as_bool().unwrap_or(true);
            s.trust.automatic.insert(permission_key(id, cap), automatic);
            s.save_trust()?;
            if automatic && cap == "file.transfer" {
                let pending = s
                    .transfers
                    .values()
                    .filter(|t| t.peer_id == id && t.status == "pending")
                    .map(|t| t.id.clone())
                    .collect::<Vec<_>>();
                for transfer in pending {
                    s.approve_file(&transfer)?;
                }
            }
            if automatic && ["audio.output", "audio.input", "camera.stream"].contains(&cap) {
                for session in s.sessions.values_mut().filter(|t| {
                    t.peer_id == id && t.capability == cap && t.state == SessionState::Requested
                }) {
                    session.transition(SessionState::Authorized)?;
                }
            }
            if automatic && cap == "clipboard.sync" {
                for offer in s.clipboard.values_mut().filter(|c| c.peer_id == id) {
                    offer.status = "automatic".into();
                }
            }
            if !allow {
                for action in s.platform_actions.values_mut().filter(|a| {
                    a.peer_id == id
                        && a.capability == cap
                        && ["pending", "dispatched"].contains(&a.status.as_str())
                }) {
                    action.status = "failed".into();
                    action.message = "Permission revoked".into();
                }
                for session in s.sessions.values_mut() {
                    if session.peer_id == id && session.capability == cap {
                        session.close();
                    }
                }
                s.signals.retain(|signal| signal.peer_id != id);
                if cap == "clipboard.sync" {
                    s.clipboard.retain(|_, c| c.peer_id != id);
                }
            }
            s.event(
                "permission.changed",
                json!({"peer_id":id,"capability":cap,"allow":allow}),
            );
            Ok(ok())
        }
        "unpair" => {
            let id = string(&p, "peer_id")?;
            s.trust.peers.remove(id).context("device not paired")?;
            s.trust
                .permissions
                .retain(|k, _| !k.starts_with(&format!("{id}/")));
            s.trust
                .automatic
                .retain(|k, _| !k.starts_with(&format!("{id}/")));
            s.presence.remove(id);
            s.save_trust()?;
            for session in s.sessions.values_mut() {
                if session.peer_id == id {
                    session.close();
                }
            }
            s.clipboard.retain(|_, c| c.peer_id != id);
            s.signals.retain(|signal| signal.peer_id != id);
            s.event("device.unpaired", json!({"peer_id":id}));
            Ok(ok())
        }
        "file_accept" => {
            let id = string(&p, "id")?;
            let t = s.transfers.get(id).context("unknown transfer")?.clone();
            let peer = s.peer(&t.peer_id)?;
            s.trust
                .permissions
                .insert(permission_key(&peer.device_id, "file.transfer"), true);
            s.save_trust()?;
            s.approve_file(id)?;
            Ok(ok())
        }
        "archive_transfer" => {
            let id = string(&p, "id")?;
            if p["outgoing"] == true {
                let t = s.outbound.get(id).context("unknown outgoing transfer")?;
                ensure!(
                    ["completed", "cancelled"].contains(&t.status.as_str()),
                    "transfer is still active"
                );
                s.outbound.remove(id);
                s.save_outbound()?;
            } else {
                let t = s.transfers.get(id).context("unknown transfer")?;
                ensure!(
                    ["completed", "cancelled"].contains(&t.status.as_str()),
                    "transfer is still active"
                );
                std::fs::remove_file(s.dir.join("transfers").join(format!("{id}.json.enc")))?;
                s.transfers.remove(id);
                s.sessions.remove(id);
            }
            Ok(ok())
        }
        "file_cancel" => {
            let id = string(&p, "id")?;
            let dir = s.dir.join("transfers");
            let key = s.identity.storage_key();
            s.transfers
                .get_mut(id)
                .context("unknown transfer")?
                .cancel(&dir, &key)?;
            if let Some(session) = s.sessions.get_mut(id) {
                session.close();
            }
            Ok(ok())
        }
        "file_resume" => {
            let id = string(&p, "id")?;
            let t = s.transfers.get(id).context("unknown transfer")?.clone();
            ensure!(t.status == "receiving", "transfer is not recoverable");
            let peer = s.peer(&t.peer_id)?;
            s.trust.authorize(&peer, "file.transfer", true)?;
            s.sessions.insert(
                id.into(),
                narad_core::model::Session {
                    id: id.into(),
                    peer_id: peer.device_id,
                    capability: "file.transfer".into(),
                    state: SessionState::Active,
                    updated_at: now(),
                },
            );
            Ok(ok())
        }
        "clipboard_accept" => {
            let id = string(&p, "id")?;
            let offer = s
                .clipboard
                .get(id)
                .context("clipboard offer expired")?
                .clone();
            let peer = s.peer(&offer.peer_id)?;
            s.session(id, &peer, "clipboard.sync")?;
            ensure!(
                ["pending", "automatic"].contains(&offer.status.as_str()),
                "clipboard already handled"
            );
            s.clipboard_digest = Some(*blake3::hash(offer.text.as_bytes()).as_bytes());
            s.clipboard.remove(id);
            s.sessions.get_mut(id).unwrap().close();
            s.event("clipboard.accepted", json!({"id":id}));
            Ok(json!({"ok":true,"text":offer.text}))
        }
        "clipboard_deny" => {
            let id = string(&p, "id")?;
            s.clipboard.remove(id).context("unknown clipboard offer")?;
            if let Some(session) = s.sessions.get_mut(id) {
                session.close();
            }
            Ok(ok())
        }
        "media_ready" => {
            s.media_ready = p["audio_ready"]
                .as_bool()
                .unwrap_or(p["ready"].as_bool().unwrap_or(false));
            s.camera_ready = p["camera_ready"].as_bool().unwrap_or(false);
            s.microphone_ready = p["microphone_ready"].as_bool().unwrap_or(false);
            s.media_seen = now();
            let outgoing = s.outgoing_media.clone();
            let playback_ready = s.media_ready;
            for (cap, ready) in [
                ("audio.output", s.media_ready),
                ("audio.input", s.microphone_ready),
                ("camera.stream", s.camera_ready),
            ] {
                if ready && !s.own.capabilities.iter().any(|c| c == cap) {
                    s.own.capabilities.push(cap.into());
                }
                if !ready {
                    s.own.capabilities.retain(|c| c != cap);
                    for session in s.sessions.values_mut().filter(|s| {
                        s.capability == cap
                            && !(cap == "audio.input" && outgoing.contains(&s.id) && playback_ready)
                    }) {
                        session.close();
                    }
                }
            }
            let active = s
                .sessions
                .iter()
                .filter(|(_, s)| s.state != SessionState::Closed)
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            s.signals
                .retain(|signal| active.contains(&signal.session_id));
            Ok(ok())
        }
        "media_accept" => {
            let id = string(&p, "id")?;
            let session = s.sessions.get(id).context("unknown session")?.clone();
            let peer = s.peer(&session.peer_id)?;
            ensure!(
                ["audio.output", "audio.input", "camera.stream"]
                    .contains(&session.capability.as_str())
                    && session.state == SessionState::Requested,
                "media is not awaiting approval"
            );
            s.trust
                .permissions
                .insert(permission_key(&peer.device_id, &session.capability), true);
            s.save_trust()?;
            s.sessions
                .get_mut(id)
                .unwrap()
                .transition(SessionState::Authorized)?;
            Ok(ok())
        }
        "media_deny" => {
            s.sessions
                .get_mut(string(&p, "id")?)
                .context("unknown session")?
                .transition(SessionState::Denied)?;
            Ok(ok())
        }
        "media_events" => {
            let signals = std::mem::take(&mut s.signals);
            Ok(json!({"ok":true,"signals":signals}))
        }
        "media_state" => {
            let id = string(&p, "id")?;
            let next: SessionState = serde_json::from_value(p["state"].clone())?;
            let session = s.sessions.get(id).context("unknown session")?.clone();
            let peer = s.peer(&session.peer_id)?;
            s.session(id, &peer, &session.capability)?;
            s.sessions.get_mut(id).unwrap().transition(next)?;
            Ok(ok())
        }
        "session_touch" => {
            let session = s
                .sessions
                .get_mut(string(&p, "id")?)
                .context("unknown session")?;
            ensure!(
                !matches!(
                    session.state,
                    SessionState::Closed | SessionState::Denied | SessionState::Failed
                ),
                "session has ended"
            );
            session.updated_at = now();
            Ok(ok())
        }
        _ => anyhow::bail!("unsupported local command"),
    }
}

/// Complete only explicitly sent nearby requests. A single daemon-owned worker
/// polls bounded requests concurrently; Activity/Flutter lifecycle is irrelevant.
pub async fn refresh_nearby_pairings(shared: Arc<Mutex<State>>) {
    let pending = {
        let mut s = shared.lock().await;
        s.expire();
        s.pairings
            .values()
            .filter(|p| p.nearby && p.outgoing && p.status == "pending")
            .cloned()
            .collect::<Vec<_>>()
    };
    let mut polls = tokio::task::JoinSet::new();
    for pair in pending {
        let shared = shared.clone();
        polls.spawn(async move {
            let (identity, own) = {
                let s = shared.lock().await;
                (s.identity.clone(), s.own.clone())
            };
            let Ok(response) = remote_call(
                &identity,
                &own,
                &pair.peer,
                false,
                json!({"op":"pair_status","id":pair.id}),
            )
            .await
            else {
                return;
            };
            if response["status"] == "approved" {
                // Rechecks expiry/cancellation after the network round trip.
                let _ = outgoing(
                    shared,
                    "pair_confirm",
                    &json!({"id":pair.id,"code":pair.code}),
                )
                .await;
            } else if response["status"] == "denied" {
                let mut s = shared.lock().await;
                if let Some(current) = s.pairings.get_mut(&pair.id) {
                    if current.status == "pending" {
                        current.status = "denied".into();
                    }
                }
            }
        });
    }
    while polls.join_next().await.is_some() {}
}

async fn outgoing(shared: Arc<Mutex<State>>, op: &str, p: &Value) -> Result<Value> {
    if op == "pair_nearby" {
        let peer: Peer = serde_json::from_value(p["peer"].clone())?;
        peer.validate()?;
        let (identity, own) = {
            let mut s = shared.lock().await;
            s.expire();
            ensure!(s.own.device_id != peer.device_id, "cannot pair with self");
            ensure!(
                !s.trust.peers.contains_key(&peer.device_id),
                "device already paired"
            );
            ensure!(s.pairings.len() < 32, "too many pairing requests");
            ensure!(
                !s.pairings
                    .values()
                    .any(|p| p.peer.device_id == peer.device_id && p.status == "pending"),
                "pairing request already pending"
            );
            (s.identity.clone(), s.own.clone())
        };
        let response =
            remote_call(&identity, &own, &peer, false, json!({"op":"pair_request"})).await?;
        let id = string(&response, "id")?.to_string();
        ensure!(uuid::Uuid::parse_str(&id).is_ok(), "invalid pairing ID");
        let nonce = string(&response, "nonce")?.to_string();
        ensure!(nonce.len() == 64, "invalid pairing nonce");
        let code = pairing_code(&own, &peer, &nonce);
        ensure!(
            code == string(&response, "code")?,
            "pairing transcript mismatch"
        );
        let expires_at = number(&response, "expires_at")?;
        ensure!(
            expires_at > now() && expires_at <= now() + 360,
            "invalid pairing expiry"
        );
        let mut s = shared.lock().await;
        ensure!(s.pairings.len() < 32, "too many pairing requests");
        ensure!(
            !s.pairings
                .values()
                .any(|p| p.peer.device_id == peer.device_id && p.status == "pending"),
            "pairing request already pending"
        );
        s.pairings.insert(
            id.clone(),
            Pairing {
                id: id.clone(),
                peer,
                nonce,
                code: code.clone(),
                expires_at,
                status: "pending".into(),
                outgoing: true,
                nearby: true,
            },
        );
        s.event("pairing.sent", json!({"id":id,"nearby":true}));
        return Ok(json!({"ok":true,"id":id,"code":code}));
    }
    if op == "pair" {
        let invitation: Invitation = serde_json::from_value(p["invitation"].clone())?;
        invitation.validate()?;
        let (identity, own) = {
            let s = shared.lock().await;
            ensure!(s.pairings.len() < 32, "too many pairing requests");
            (s.identity.clone(), s.own.clone())
        };
        let r = remote_call(
            &identity,
            &own,
            &invitation.peer,
            false,
            json!({"op":"pair_begin","nonce":invitation.nonce}),
        )
        .await?;
        let id = string(&r, "id")?.to_string();
        let code = pairing_code(&own, &invitation.peer, &invitation.nonce);
        let mut s = shared.lock().await;
        ensure!(code == string(&r, "code")?, "pairing transcript mismatch");
        s.pairings.insert(
            id.clone(),
            Pairing {
                id: id.clone(),
                peer: invitation.peer,
                nonce: invitation.nonce,
                code: code.clone(),
                expires_at: invitation.expires_at,
                status: "pending".into(),
                outgoing: true,
                nearby: false,
            },
        );
        return Ok(json!({"ok":true,"id":id,"code":code}));
    }
    if op == "pair_confirm" {
        let mut s = shared.lock().await;
        s.expire();
        let id = string(p, "id")?;
        let pair = s.pairings.get(id).context("pairing expired")?.clone();
        ensure!(
            pair.outgoing && pair.status == "pending" && pair.code == string(p, "code")?,
            "pairing code mismatch or not pending"
        );
        let identity = s.identity.clone();
        let own = s.own.clone();
        drop(s);
        let r = remote_call(
            &identity,
            &own,
            &pair.peer,
            false,
            json!({"op":"pair_status","id":id}),
        )
        .await?;
        ensure!(
            r["status"] == "approved",
            "other device has not approved pairing"
        );
        let mut s = shared.lock().await;
        ensure!(
            s.pairings
                .get(id)
                .is_some_and(|p| p.status == "pending" && p.expires_at > now()),
            "pairing expired or withdrawn"
        );
        s.trust.peers.insert(
            pair.peer.device_id.clone(),
            TrustRecord {
                peer: pair.peer.clone(),
                paired_at: now(),
            },
        );
        s.save_trust()?;
        s.pairings.get_mut(id).unwrap().status = "approved".into();
        s.event("pairing.completed", json!({"peer_id":pair.peer.device_id}));
        return Ok(ok());
    }
    if op == "download_shared" {
        return crate::controls::download(shared, p).await;
    }
    if op == "send_file" {
        return send_file(shared, p).await;
    }
    let peer_id = string(p, "peer_id")?;
    // Network requests never hold the shared state lock: both peers may send concurrently.
    let (identity, own, peer) = {
        let s = shared.lock().await;
        let peer = s.peer(peer_id)?;
        (s.identity.clone(), s.own.clone(), peer)
    };

    let payload = match op {
        "send_clipboard" => json!({"op":"clipboard_offer","text":p["text"]}),
        "ping_peer" => json!({"op":"ping"}),
        "read_shared" => json!({"op":"shared_read","path":p["path"],"offset":p["offset"]}),
        "browse_peer" => json!({"op":"browse","path":p["path"]}),
        "list_commands" => json!({"op":"command_list"}),
        "run_command" => json!({"op":"command","id":p["id"]}),
        "device_action" => json!({"op":"device_action","kind":p["kind"]}),
        "device_action_status" => json!({"op":"device_action_status","id":p["id"]}),
        "media_start" => {
            media_capability(p)?;
            json!({"op":"media_offer","id":uuid::Uuid::new_v4().to_string(),"kind":p["kind"]})
        }
        "media_poll" => json!({"op":"media_status","id":p["id"]}),
        "media_send" => json!({"op":"media_signal","id":p["id"],"data":p["data"]}),
        "session_stop" => json!({"op":"session_close","id":p["id"]}),
        _ => anyhow::bail!("unsupported outgoing command"),
    };
    if op == "media_send" {
        let s = shared.lock().await;
        let id = string(p, "id")?;
        let capability = &s.sessions.get(id).context("unknown session")?.capability;
        ensure!(
            ["audio.output", "audio.input", "camera.stream"].contains(&capability.as_str()),
            "session is not a media session"
        );
        s.session(id, &peer, capability)?;
    }
    if op == "session_stop" {
        let mut s = shared.lock().await;
        let session = s
            .sessions
            .get_mut(string(p, "id")?)
            .context("unknown session")?;
        ensure!(session.peer_id == peer_id, "session ownership mismatch");
        session.close();
    }
    let result = remote_call(&identity, &own, &peer, false, payload.clone()).await?;
    let mut s = shared.lock().await;
    if op == "media_start" {
        let id = string(&payload, "id")?;
        let cap = media_capability(p)?;
        s.new_session(id, peer_id, cap, false)?;
        s.outgoing_media.insert(id.to_string());
        return Ok(json!({"ok":true,"id":id}));
    }
    if op == "media_poll" {
        let id = string(p, "id")?;
        let expected_cap = s
            .sessions
            .get(id)
            .context("unknown local session")?
            .capability
            .clone();
        ensure!(
            ["audio.output", "audio.input", "camera.stream"].contains(&expected_cap.as_str())
                && result["session"]["capability"] == expected_cap
                && result["session"]["id"] == id,
            "media response does not match local session"
        );
        let state: SessionState = serde_json::from_value(result["session"]["state"].clone())?;
        if state == SessionState::Authorized {
            s.trust
                .permissions
                .insert(permission_key(peer_id, &expected_cap), true);
            s.save_trust()?;
            if let Some(session) = s.sessions.get_mut(id) {
                if session.state == SessionState::Requested {
                    session.transition(SessionState::Authorized)?;
                }
            }
        }
        if matches!(
            state,
            SessionState::Closed | SessionState::Denied | SessionState::Failed
        ) {
            if let Some(session) = s.sessions.get_mut(id) {
                session.close();
            }
        }
    }
    if op == "session_stop" {
        if let Some(session) = s.sessions.get_mut(string(p, "id")?) {
            session.close();
        }
    }
    Ok(result)
}

async fn send_file(shared: Arc<Mutex<State>>, p: &Value) -> Result<Value> {
    let path = Path::new(string(p, "path")?);
    let size = std::fs::metadata(path)?.len();
    ensure!(size <= MAX_FILE_SIZE, "file too large (maximum 1 GiB)");
    let checksum = hash_file(path)?;
    let peer_id = string(p, "peer_id")?;
    let id = if let Some(id) = p["id"].as_str() {
        id.to_string()
    } else {
        uuid::Uuid::new_v4().to_string()
    };
    ensure!(uuid::Uuid::parse_str(&id).is_ok(), "invalid transfer ID");
    let file_name = path
        .file_name()
        .context("invalid file name")?
        .to_str()
        .context("file name must be UTF-8")?;
    let (identity, own, peer) = {
        let s = shared.lock().await;
        (s.identity.clone(), s.own.clone(), s.peer(peer_id)?)
    };
    let r=remote_call(&identity,&own,&peer,false,json!({"op":"file_offer","id":id,"file_name":file_name,"file_size":size,"checksum":checksum})).await?;
    {
        let mut s = shared.lock().await;
        ensure!(
            s.outbound.len() < 256 || s.outbound.contains_key(&id),
            "outgoing transfer history full"
        );
        s.outbound.insert(
            id.clone(),
            crate::state::Outbound {
                id: id.clone(),
                peer_id: peer_id.into(),
                path: path.to_string_lossy().into(),
                status: r["transfer"]["status"].as_str().unwrap_or("unknown").into(),
                sent: r["transfer"]["received"].as_u64().unwrap_or(0),
                total: size,
            },
        );
        s.save_outbound()?;
    }
    let status = r["transfer"]["status"]
        .as_str()
        .context("invalid transfer status")?;
    if status != "receiving" {
        return Ok(json!({"ok":true,"id":id,"status":status,"received":r["transfer"]["received"]}));
    }
    let mut offset = r["transfer"]["received"]
        .as_u64()
        .context("invalid resume offset")?;
    ensure!(offset <= size, "invalid resume offset");
    let mut file = std::fs::File::open(path)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut buf = vec![0; CHUNK_SIZE];
    while offset < size {
        let n = file.read(&mut buf)?;
        ensure!(n > 0, "source file changed during transfer");
        let r=remote_call(&identity,&own,&peer,true,json!({"op":"file_chunk","id":id,"offset":offset,"data":STANDARD.encode(&buf[..n]),"checksum":blake3::hash(&buf[..n]).to_hex().to_string()})).await?;
        ensure!(
            r["received"].as_u64() == Some(offset + n as u64),
            "invalid transfer acknowledgement"
        );
        offset += n as u64;
        {
            let mut s = shared.lock().await;
            let t = s
                .outbound
                .get_mut(&id)
                .context("outgoing transfer disappeared")?;
            t.sent = offset;
            t.status = "sending".into();
            s.save_outbound()?;
        }
        shared
            .lock()
            .await
            .event("file.progress", json!({"id":id,"sent":offset,"total":size}));
    }
    let r = remote_call(
        &identity,
        &own,
        &peer,
        true,
        json!({"op":"file_finish","id":id}),
    )
    .await?;
    {
        let mut s = shared.lock().await;
        if let Some(t) = s.outbound.get_mut(&id) {
            t.status = "completed".into();
            t.sent = size;
        }
        s.save_outbound()?;
    }
    Ok(json!({"ok":true,"id":id,"status":"completed","received":size,"path":r["path"]}))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn setup() -> (tempfile::TempDir, State, Peer) {
        let d = tempfile::tempdir().unwrap();
        let mut s = State::load(
            d.path().join("receiver"),
            "Receiver".into(),
            "127.0.0.1".into(),
            46000,
        )
        .unwrap();
        let identity =
            narad_core::identity::Identity::load_or_create(&d.path().join("sender")).unwrap();
        let peer = identity.peer("Sender".into(), "127.0.0.1".into(), 46100);
        s.trust.peers.insert(
            peer.device_id.clone(),
            TrustRecord {
                peer: peer.clone(),
                paired_at: now(),
            },
        );
        (d, s, peer)
    }
    #[test]
    fn denied_clipboard_and_unpaired_requests_leave_no_session() {
        let (_d, mut s, peer) = setup();
        let p = json!({"op":"clipboard_offer","text":"private"});
        assert!(remote(&mut s, &peer, &p, false).is_err());
        assert!(s.sessions.is_empty());
        s.trust.peers.clear();
        assert!(remote(&mut s, &peer, &json!({"op":"ping"}), false).is_err());
    }
    #[test]
    fn file_plane_and_ownership_are_enforced() {
        let (_d, mut s, peer) = setup();
        s.trust
            .permissions
            .insert(permission_key(&peer.device_id, "file.transfer"), true);
        let id = uuid::Uuid::new_v4().to_string();
        s.new_session(&id, "different-peer", "file.transfer", true)
            .unwrap();
        assert!(remote(&mut s, &peer, &json!({"op":"file_chunk","id":id}), true).is_err());
        assert!(remote(&mut s, &peer, &json!({"op":"ping"}), true).is_err());
    }
    #[tokio::test]
    async fn revocation_closes_active_sessions_and_discards_payloads() {
        let (_d, mut s, peer) = setup();
        s.trust
            .permissions
            .insert(permission_key(&peer.device_id, "clipboard.sync"), true);
        let r = remote(
            &mut s,
            &peer,
            &json!({"op":"clipboard_offer","text":"private"}),
            false,
        )
        .unwrap();
        let shared = Arc::new(Mutex::new(s));
        local(shared.clone(),json!({"op":"permission","peer_id":peer.device_id,"capability":"clipboard.sync","allow":false})).await.unwrap();
        assert!(shared.lock().await.clipboard.is_empty());
        assert_eq!(
            shared.lock().await.sessions[r["id"].as_str().unwrap()].state,
            SessionState::Closed
        );
        assert!(local(shared, json!({"op":"clipboard_accept","id":r["id"]}))
            .await
            .is_err());
    }
    #[tokio::test]
    async fn nearby_requests_need_explicit_acceptance_and_cannot_bypass_ownership() {
        let (_d, mut s, peer) = setup();
        s.trust.peers.clear();
        let request = remote(&mut s, &peer, &json!({"op":"pair_request"}), false).unwrap();
        assert!(s.trust.peers.is_empty());
        let id = request["id"].as_str().unwrap();
        assert!(s.pairings[id].nearby);
        assert_eq!(
            request["code"],
            pairing_code(&s.own, &peer, request["nonce"].as_str().unwrap())
        );
        assert!(remote(&mut s, &peer, &json!({"op":"pair_request"}), false).is_err());
        let stranger = narad_core::identity::Identity::generate().unwrap().peer(
            "Other".into(),
            "127.0.0.1".into(),
            46200,
        );
        assert!(remote(
            &mut s,
            &stranger,
            &json!({"op":"pair_status","id":id}),
            false
        )
        .is_err());
        assert!(remote(&mut s, &peer, &json!({"op":"ping"}), false).is_err());
        let shared = Arc::new(Mutex::new(s));
        assert!(local(
            shared.clone(),
            json!({"op":"pair_approve","id":id,"code":"wrong"})
        )
        .await
        .is_err());
        local(
            shared.clone(),
            json!({"op":"pair_approve","id":id,"code":request["code"]}),
        )
        .await
        .unwrap();
        assert!(shared
            .lock()
            .await
            .trust
            .peers
            .contains_key(&peer.device_id));
        assert!(shared.lock().await.trust.permissions.is_empty());
        assert!(local(shared.clone(), json!({"op":"pair_deny","id":id}))
            .await
            .is_err());
        local(
            shared.clone(),
            json!({"op":"unpair","peer_id":peer.device_id}),
        )
        .await
        .unwrap();
        let mut s = shared.lock().await;
        assert_eq!(
            remote(&mut s, &peer, &json!({"op":"pair_status","id":id}), false).unwrap()["status"],
            "denied"
        );
    }
    #[tokio::test]
    async fn nearby_decline_and_expiry_never_grant_trust() {
        let (_d, mut s, peer) = setup();
        s.trust.peers.clear();
        let request = remote(&mut s, &peer, &json!({"op":"pair_request"}), false).unwrap();
        let shared = Arc::new(Mutex::new(s));
        local(shared.clone(), json!({"op":"pair_deny","id":request["id"]}))
            .await
            .unwrap();
        assert!(local(
            shared.clone(),
            json!({"op":"pair_approve","id":request["id"],"code":request["code"]})
        )
        .await
        .is_err());
        assert!(shared.lock().await.trust.peers.is_empty());
        let request = remote(
            &mut *shared.lock().await,
            &peer,
            &json!({"op":"pair_request"}),
            false,
        )
        .unwrap();
        shared
            .lock()
            .await
            .pairings
            .get_mut(request["id"].as_str().unwrap())
            .unwrap()
            .expires_at = now() - 1;
        assert!(local(
            shared.clone(),
            json!({"op":"pair_approve","id":request["id"],"code":request["code"]})
        )
        .await
        .is_err());
        assert!(shared.lock().await.trust.peers.is_empty());
    }
    #[test]
    fn pairing_nonce_is_one_time_and_codes_are_required() {
        let (_d, mut s, peer) = setup();
        let nonce = random_token();
        s.invitations.insert(
            nonce.clone(),
            Invitation {
                peer: s.own.clone(),
                nonce: nonce.clone(),
                expires_at: now() + 300,
            },
        );
        let p = json!({"op":"pair_begin","nonce":nonce});
        remote(&mut s, &peer, &p, false).unwrap();
        assert!(remote(&mut s, &peer, &p, false).is_err());
    }
    #[tokio::test]
    async fn automatic_clipboard_requires_both_switch_and_grant_and_does_not_echo() {
        let (_d, mut s, peer) = setup();
        s.trust
            .permissions
            .insert(permission_key(&peer.device_id, "clipboard.sync"), true);
        s.trust
            .automatic
            .insert(permission_key(&peer.device_id, "clipboard.sync"), true);
        let push = json!({"op":"clipboard_push","text":"generated clipboard fixture"});
        assert!(remote(&mut s, &peer, &push, false).is_err());
        s.preferences.clipboard_sync = true;
        s.trust
            .automatic
            .insert(permission_key(&peer.device_id, "clipboard.sync"), false);
        assert!(remote(&mut s, &peer, &push, false).is_err());
        s.trust
            .automatic
            .insert(permission_key(&peer.device_id, "clipboard.sync"), true);
        remote(&mut s, &peer, &push, false).unwrap();
        let events = crate::controls::platform_events(&mut s).unwrap();
        assert_eq!(events["clipboard"][0]["text"], push["text"]);
        let shared = Arc::new(Mutex::new(s));
        assert_eq!(
            local(
                shared.clone(),
                json!({"op":"clipboard_publish","text":push["text"]})
            )
            .await
            .unwrap()["sent"],
            0
        );
        local(
            shared.clone(),
            json!({"op":"clipboard_sync","enabled":false}),
        )
        .await
        .unwrap();
        let state = shared.lock().await;
        let saved: crate::preferences::Preferences = narad_core::storage::load_encrypted(
            &state.dir.join("preferences.enc"),
            &state.identity.storage_key(),
        )
        .unwrap();
        assert!(!saved.clipboard_sync);
        assert!(state.clipboard.is_empty());
    }
    #[test]
    fn microphone_requires_separate_readiness_and_permission() {
        let (_d, mut s, peer) = setup();
        s.media_ready = true;
        s.media_seen = now();
        s.trust
            .permissions
            .insert(permission_key(&peer.device_id, "audio.output"), true);
        let id = uuid::Uuid::new_v4().to_string();
        let offer = json!({"op":"media_offer","id":id,"kind":"microphone"});
        assert!(remote(&mut s, &peer, &offer, false).is_err());
        assert!(s.sessions.is_empty());
        s.microphone_ready = true;
        remote(&mut s, &peer, &offer, false).unwrap();
        assert_eq!(s.sessions[&id].capability, "audio.input");
        assert_eq!(s.sessions[&id].state, SessionState::Requested);
        s.sessions.remove(&id);
        s.trust
            .permissions
            .insert(permission_key(&peer.device_id, "audio.input"), false);
        assert!(remote(&mut s, &peer, &offer, false).is_err());
        s.trust
            .permissions
            .insert(permission_key(&peer.device_id, "audio.input"), true);
        s.trust
            .automatic
            .insert(permission_key(&peer.device_id, "audio.input"), true);
        remote(&mut s, &peer, &offer, false).unwrap();
        assert_eq!(s.sessions[&id].state, SessionState::Authorized);
        assert!(media_capability(&json!({"kind":"unsupported"})).is_err());
    }
    #[tokio::test]
    async fn microphone_disabled_closes_capture_but_keeps_remote_listening() {
        let (_d, mut s, peer) = setup();
        let incoming = uuid::Uuid::new_v4().to_string();
        let outgoing = uuid::Uuid::new_v4().to_string();
        s.new_session(&incoming, &peer.device_id, "audio.input", true)
            .unwrap();
        s.new_session(&outgoing, &peer.device_id, "audio.input", true)
            .unwrap();
        s.outgoing_media.insert(outgoing.clone());
        let shared = Arc::new(Mutex::new(s));
        local(
            shared.clone(),
            json!({"op":"media_ready","audio_ready":true,"microphone_ready":false}),
        )
        .await
        .unwrap();
        assert_eq!(
            shared.lock().await.sessions[&incoming].state,
            SessionState::Closed
        );
        assert_ne!(
            shared.lock().await.sessions[&outgoing].state,
            SessionState::Closed
        );
        local(
            shared.clone(),
            json!({"op":"media_ready","audio_ready":false}),
        )
        .await
        .unwrap();
        assert_eq!(
            shared.lock().await.sessions[&outgoing].state,
            SessionState::Closed
        );
    }
    #[test]
    fn media_requires_live_adapter_and_explicit_approval() {
        let (_d, mut s, peer) = setup();
        let id = uuid::Uuid::new_v4().to_string();
        let offer = json!({"op":"media_offer","id":id});
        assert!(remote(&mut s, &peer, &offer, false).is_err());
        s.media_ready = true;
        s.media_seen = now();
        remote(&mut s, &peer, &offer, false).unwrap();
        assert!(remote(
            &mut s,
            &peer,
            &json!({"op":"media_signal","id":id,"data":{"type":"offer"}}),
            false
        )
        .is_err());
        s.media_seen = now() - 20;
        s.expire();
        assert!(!s.media_ready);
        assert_eq!(s.sessions[&id].state, SessionState::Closed);
    }
}
