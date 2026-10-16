//! Ephemeral, permissioned native phone RPC. Content never enters history/storage.
use crate::{handler::string, state::State, transport::remote_call};
use anyhow::{ensure, Context, Result};
use narad_core::model::{now, Peer};
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};
use tokio::sync::Mutex;
pub const CAPABILITIES: [&str; 8] = [
    "contacts.read",
    "notification.read",
    "notification.manage",
    "notification.reply",
    "sms.read",
    "sms.send",
    "calls.read",
    "calls.control",
];
pub struct PhoneJob {
    pub peer: String,
    pub capability: String,
    pub kind: String,
    pub args: Value,
    pub expires: u64,
    pub dispatched: bool,
    pub result: Option<Value>,
}
pub fn capability(kind: &str) -> Result<&'static str> {
    Ok(match kind {
        "contacts_list" => "contacts.read",
        "notifications" => "notification.read",
        "notification_dismiss" => "notification.manage",
        "notification_reply" => "notification.reply",
        "sms_list" => "sms.read",
        "sms_send" => "sms.send",
        "calls_list" | "call_state" => "calls.read",
        "dial" | "answer" | "reject" | "hangup" | "mute" | "dtmf" => "calls.control",
        _ => anyhow::bail!("unsupported phone action"),
    })
}
pub async fn remote(
    shared: Arc<Mutex<State>>,
    peer: &Peer,
    p: &Value,
    file: bool,
) -> Result<Value> {
    ensure!(!file, "phone command sent on wrong transport plane");
    let kind = string(p, "kind")?;
    let mut s = shared.lock().await;
    s.trust.authenticate(peer)?;
    s.note_presence(&peer.device_id, true);
    ensure!(
        now().saturating_sub(s.phone_seen) < 15 && s.phone_support["enabled"] == true,
        "Phone bridge unavailable. Enable Phone integration on the phone."
    );
    if kind == "support" {
        return Ok(json!({"ok":true,"support":s.phone_support}));
    }
    let cap = capability(kind)?;
    s.trust.authorize(peer, cap, true)?;
    ensure!(
        p["args"].is_object() && serde_json::to_vec(&p["args"])?.len() <= 12000,
        "invalid phone arguments"
    );
    s.phone_jobs.retain(|_, j| j.expires > now());
    ensure!(
        s.phone_jobs.len() < 16
            && s.phone_jobs
                .values()
                .filter(|j| j.peer == peer.device_id)
                .count()
                < 4,
        "phone queue busy"
    );
    let id = uuid::Uuid::new_v4().to_string();
    s.phone_jobs.insert(
        id.clone(),
        PhoneJob {
            peer: peer.device_id.clone(),
            capability: cap.into(),
            kind: kind.into(),
            args: p["args"].clone(),
            expires: now() + 20,
            dispatched: false,
            result: None,
        },
    );
    drop(s);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(12);
    loop {
        tokio::time::sleep(Duration::from_millis(80)).await;
        let mut s = shared.lock().await;
        if let Err(error) = s.trust.authorize(peer, cap, true) {
            s.phone_jobs.remove(&id);
            return Err(error);
        }
        if s.phone_support["enabled"] != true || now().saturating_sub(s.phone_seen) >= 15 {
            s.phone_jobs.remove(&id);
            anyhow::bail!("Phone integration disabled or disconnected");
        }
        let job = s.phone_jobs.get_mut(&id).context("phone request expired")?;
        if let Some(result) = job.result.take() {
            s.phone_jobs.remove(&id);
            return Ok(result);
        }
        if tokio::time::Instant::now() > deadline {
            s.phone_jobs.remove(&id);
            anyhow::bail!("Phone request timed out. An action may already have run; check the phone before retrying.");
        }
    }
}
pub async fn local(shared: Arc<Mutex<State>>, p: &Value) -> Result<Value> {
    let op = string(p, "op")?;
    if op == "phone_request" {
        let (identity, own, peer) = {
            let s = shared.lock().await;
            (
                s.identity.clone(),
                s.own.clone(),
                s.peer(string(p, "peer_id")?)?,
            )
        };
        let result=remote_call(&identity,&own,&peer,false,json!({"op":"phone_request","kind":p["kind"],"args":p.get("args").cloned().unwrap_or(json!({}))})).await?;
        shared.lock().await.trust.authenticate(&peer)?;
        return Ok(result);
    }
    let mut s = shared.lock().await;
    s.phone_jobs.retain(|_, j| j.expires > now());
    match op {
        "phone_bridge_ready" => {
            ensure!(
                p["support"].is_object() && serde_json::to_vec(&p["support"])?.len() < 4096,
                "invalid phone support"
            );
            s.phone_support = p["support"].clone();
            s.phone_seen = now();
            if p["support"]["enabled"] != true {
                s.phone_jobs.clear();
            }
            for (cap, key) in [
                ("contacts.read", "contacts"),
                ("notification.read", "notifications"),
                ("notification.manage", "notifications"),
                ("notification.reply", "notifications"),
                ("sms.read", "sms_read"),
                ("sms.send", "sms_send"),
                ("calls.read", "call_logs"),
                ("calls.control", "call_control"),
            ] {
                s.own.capabilities.retain(|c| c != cap);
                if p["support"]["enabled"] == true && p["support"][key] == true {
                    s.own.capabilities.push(cap.into());
                }
            }
            Ok(json!({"ok":true}))
        }
        "phone_jobs" => {
            let ids = s
                .phone_jobs
                .iter()
                .filter(|(_, j)| !j.dispatched)
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            let mut jobs = vec![];
            for id in ids {
                let j = &s.phone_jobs[&id];
                if s.peer(&j.peer)
                    .and_then(|peer| s.trust.authorize(&peer, &j.capability, true))
                    .is_err()
                {
                    s.phone_jobs.remove(&id);
                    continue;
                }
                let j = s.phone_jobs.get_mut(&id).unwrap();
                j.dispatched = true;
                jobs.push(json!({"id":id,"kind":j.kind,"args":j.args}));
            }
            Ok(json!({"ok":true,"jobs":jobs}))
        }
        "phone_validate" | "phone_result" => {
            let id = string(p, "id")?;
            let job = s.phone_jobs.get(id).context("phone request expired")?;
            ensure!(
                job.dispatched && job.result.is_none(),
                "phone request already completed"
            );
            s.trust
                .authorize(&s.peer(&job.peer)?, &job.capability, true)?;
            if op == "phone_result" {
                ensure!(
                    p["result"].is_object() && serde_json::to_vec(&p["result"])?.len() <= 48000,
                    "phone response too large"
                );
                let j = s.phone_jobs.get_mut(id).unwrap();
                j.result = Some(p["result"].clone());
                j.args = json!({});
            }
            Ok(json!({"ok":true}))
        }
        _ => anyhow::bail!("unsupported phone operation"),
    }
}
