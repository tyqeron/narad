//! Opt-in clipboard publication: no durable text, no pending offers, no echo forwarding.
use crate::{handler::string, state::State, transport::remote_call};
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::sync::Mutex;

pub async fn publish(shared: Arc<Mutex<State>>, p: &Value) -> Result<Value> {
    let text = string(p, "text")?;
    ensure!(
        !text.is_empty() && text.len() <= 16384 && !text.contains('\0'),
        "invalid clipboard text"
    );
    let (identity, own, peers) = {
        let mut s = shared.lock().await;
        ensure!(
            s.preferences.clipboard_sync,
            "Automatic clipboard sync is off"
        );
        let digest = *blake3::hash(text.as_bytes()).as_bytes();
        if s.clipboard_digest == Some(digest) {
            return Ok(json!({"ok":true,"sent":0}));
        }
        s.clipboard_digest = Some(digest);
        let peers = s
            .trust
            .peers
            .values()
            .filter(|r| s.presence.get(&r.peer.device_id).is_some_and(|p| p.online))
            .map(|r| r.peer.clone())
            .take(32)
            .collect::<Vec<_>>();
        (s.identity.clone(), s.own.clone(), peers)
    };
    let mut sent = 0;
    for peer in peers {
        {
            let s = shared.lock().await;
            if !s.preferences.clipboard_sync || s.peer(&peer.device_id).is_err() {
                break;
            }
        }
        if remote_call(
            &identity,
            &own,
            &peer,
            false,
            json!({"op":"clipboard_push","text":text}),
        )
        .await
        .is_ok()
        {
            sent += 1;
        }
    }
    Ok(json!({"ok":true,"sent":sent}))
}
