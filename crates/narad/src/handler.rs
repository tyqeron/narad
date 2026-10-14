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
fn number(v: &Value, key: &str) -> Result<u64> {
    v[key].as_u64().with_context(|| format!("missing {key}"))
}
fn capability(v: &Value) -> Result<&str> {
    let c = string(v, "capability")?;
    ensure!(
        ["file.transfer", "clipboard.sync", "audio.output"].contains(&c),
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
            },
        );
        s.event(
            "pairing.requested",
            json!({"id":id,"peer_id":peer.device_id}),
        );
        return Ok(json!({"ok":true,"id":id,"code":code}));
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
        return Ok(json!({"ok":true,"status":pair.status}));
    }
    s.trust.authenticate(peer)?;
    // Authenticated metadata can refresh the address after a network change.
    if let Some(record) = s.trust.peers.get_mut(&peer.device_id) {
        record.peer.address = peer.address.clone();
        record.peer.port = peer.port;
    }
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
            s.transfers.insert(id.into(), t.clone());
            s.event("file.offered", json!({"id":id,"peer_id":peer.device_id}));
            Ok(json!({"ok":true,"transfer":t}))
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
        "clipboard_offer" => {
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
                    status: "pending".into(),
                    expires_at: now() + 120,
                },
            );
            s.event("clipboard.offered", json!({"id":id}));
            Ok(json!({"ok":true,"id":id}))
        }
        "media_offer" => {
            ensure!(s.media_ready, "audio client is not connected");
            let id = string(p, "id")?;
            ensure!(uuid::Uuid::parse_str(id).is_ok(), "invalid session ID");
            s.new_session(id, &peer.device_id, "audio.output", false)?;
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
            ensure!(s.media_ready, "audio client disconnected");
            let id = string(p, "id")?;
            s.session(id, peer, "audio.output")?;
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
        "pair"
            | "pair_confirm"
            | "send_file"
            | "send_clipboard"
            | "media_start"
            | "media_poll"
            | "media_send"
            | "session_stop"
            | "ping_peer"
    ) {
        return outgoing(shared, &op, &p).await;
    }
    let mut s = shared.lock().await;
    s.expire();
    match op.as_str() {
        "status" => {
            let offset = p["offset"].as_u64().unwrap_or(0) as usize;
            let clipboard=s.clipboard.values().skip(offset).take(32).map(|c|json!({"id":c.id,"peer_id":c.peer_id,"status":c.status,"preview":c.text.chars().take(160).collect::<String>(),"expires_at":c.expires_at})).collect::<Vec<_>>();
            Ok(
                json!({"ok":true,"device":s.own,"paired":s.trust.peers.iter().skip(offset).take(32).collect::<std::collections::BTreeMap<_,_>>(),"permissions":s.trust.permissions.iter().skip(offset).take(96).collect::<std::collections::BTreeMap<_,_>>(),"pairings":s.pairings.values().skip(offset).take(32).collect::<Vec<_>>(),"transfers":s.transfers.values().skip(offset).take(32).collect::<Vec<_>>(),"sessions":s.sessions.values().skip(offset).take(32).collect::<Vec<_>>(),"clipboard":clipboard,"events":s.events.iter().rev().take(20).collect::<Vec<_>>(),"outbound":s.outbound.values().skip(offset).take(32).collect::<Vec<_>>(),"media_ready":s.media_ready,"offset":offset,"has_more":([s.trust.peers.len(),s.pairings.len(),s.transfers.len(),s.sessions.len(),s.clipboard.len(),s.outbound.len()].into_iter().max().unwrap_or(0)>offset+32)}),
            )
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
            let pair = s
                .pairings
                .get_mut(string(&p, "id")?)
                .context("unknown pairing")?;
            pair.status = "denied".into();
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
            s.save_trust()?;
            if !allow {
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
            let dir = s.dir.join("transfers");
            let key = s.identity.storage_key();
            s.transfers.get_mut(id).unwrap().approve(&dir, &key)?;
            s.new_session(id, &peer.device_id, "file.transfer", true)?;
            let session = s.sessions.get_mut(id).unwrap();
            for state in [
                SessionState::Negotiating,
                SessionState::Connected,
                SessionState::Active,
            ] {
                session.transition(state)?;
            }
            s.event("file.accepted", json!({"id":id}));
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
            ensure!(offer.status == "pending", "clipboard already handled");
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
            s.media_ready = p["ready"].as_bool().context("missing ready flag")?;
            s.media_seen = now();
            if s.media_ready {
                if !s.own.capabilities.iter().any(|c| c == "audio.output") {
                    s.own.capabilities.push("audio.output".into());
                }
            } else {
                s.own.capabilities.retain(|c| c != "audio.output");
            }
            if !s.media_ready {
                for session in s.sessions.values_mut() {
                    if session.capability == "audio.output" {
                        session.close();
                    }
                }
                s.signals.clear();
            }
            Ok(ok())
        }
        "media_accept" => {
            ensure!(s.media_ready, "audio client is not connected");
            let id = string(&p, "id")?;
            let session = s.sessions.get(id).context("unknown session")?.clone();
            let peer = s.peer(&session.peer_id)?;
            ensure!(
                session.capability == "audio.output" && session.state == SessionState::Requested,
                "media is not awaiting approval"
            );
            s.trust
                .permissions
                .insert(permission_key(&peer.device_id, "audio.output"), true);
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
            s.session(id, &peer, "audio.output")?;
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

async fn outgoing(shared: Arc<Mutex<State>>, op: &str, p: &Value) -> Result<Value> {
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
        "media_start" => json!({"op":"media_offer","id":uuid::Uuid::new_v4().to_string()}),
        "media_poll" => json!({"op":"media_status","id":p["id"]}),
        "media_send" => json!({"op":"media_signal","id":p["id"],"data":p["data"]}),
        "session_stop" => json!({"op":"session_close","id":p["id"]}),
        _ => anyhow::bail!("unsupported outgoing command"),
    };
    if op == "media_send" {
        let s = shared.lock().await;
        s.session(string(p, "id")?, &peer, "audio.output")?;
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
        s.new_session(id, peer_id, "audio.output", false)?;
        return Ok(json!({"ok":true,"id":id}));
    }
    if op == "media_poll" {
        let id = string(p, "id")?;
        let state: SessionState = serde_json::from_value(result["session"]["state"].clone())?;
        if state == SessionState::Authorized {
            s.trust
                .permissions
                .insert(permission_key(peer_id, "audio.output"), true);
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
