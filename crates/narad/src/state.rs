use anyhow::{ensure, Context, Result};
use narad_core::{
    identity::Identity,
    model::{now, Invitation, Peer, Session, SessionState, TrustState},
    storage::{load_encrypted, save_encrypted},
    transfer::{load_transfers, Transfer},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::PathBuf,
};

#[derive(Clone, Serialize, Deserialize)]
pub struct Pairing {
    pub id: String,
    pub peer: Peer,
    pub nonce: String,
    pub code: String,
    pub expires_at: u64,
    pub status: String,
    pub outgoing: bool,
    #[serde(default)]
    pub nearby: bool,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct ClipboardOffer {
    pub id: String,
    pub peer_id: String,
    pub text: String,
    pub status: String,
    pub expires_at: u64,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Signal {
    pub session_id: String,
    pub peer_id: String,
    pub data: Value,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Outbound {
    pub id: String,
    pub peer_id: String,
    pub path: String,
    pub status: String,
    pub sent: u64,
    pub total: u64,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct SavedCommand {
    pub id: String,
    pub label: String,
    pub script: String,
}
#[derive(Clone, Default, Serialize)]
pub struct Presence {
    pub online: bool,
    pub last_seen: Option<u64>,
    pub checked_at: u64,
}
#[derive(Clone, Serialize)]
pub struct PlatformAction {
    pub id: String,
    pub peer_id: String,
    pub kind: String,
    pub capability: String,
    pub expires_at: u64,
    pub status: String,
    pub message: String,
    #[serde(default)]
    pub data: serde_json::Value,
}
pub struct State {
    pub preferences: crate::preferences::Preferences,
    pub clipboard_digest: Option<[u8; 32]>,
    pub shared_transfer_activity: BTreeMap<String, Value>,
    pub share_uploads: BTreeMap<String, crate::sharing::Upload>,
    pub storage_jobs: BTreeMap<String, crate::sharing::Job>,
    pub storage_notify: std::sync::Arc<tokio::sync::Notify>,
    pub dir: PathBuf,
    pub identity: Identity,
    pub own: Peer,
    pub token: String,
    pub trust: TrustState,
    pub replay: HashMap<String, u64>,
    pub invitations: BTreeMap<String, Invitation>,
    pub pairings: BTreeMap<String, Pairing>,
    pub sessions: BTreeMap<String, Session>,
    pub transfers: BTreeMap<String, Transfer>,
    pub clipboard: BTreeMap<String, ClipboardOffer>,
    pub outbound: BTreeMap<String, Outbound>,
    pub phone_jobs: BTreeMap<String, crate::phone::PhoneJob>,
    pub phone_support: Value,
    pub phone_seen: u64,
    pub media_ready: bool,
    pub camera_ready: bool,
    pub microphone_ready: bool,
    pub outgoing_media: HashSet<String>,
    pub presence: BTreeMap<String, Presence>,
    pub platform_actions: BTreeMap<String, PlatformAction>,
    pub commands: BTreeMap<String, SavedCommand>,
    pub media_seen: u64,
    pub signals: Vec<Signal>,
    pub events: Vec<Value>,
}
impl State {
    /// Mobile files are published through the platform's scoped-storage API.
    pub fn downloads_directory(dir: &std::path::Path) -> PathBuf {
        if cfg!(test) || cfg!(any(target_os = "android", target_os = "ios")) {
            return dir.join("downloads");
        }
        #[cfg(target_os = "linux")]
        if let Ok(output) = std::process::Command::new("xdg-user-dir")
            .arg("DOWNLOAD")
            .output()
        {
            let value = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            if output.status.success() && std::path::Path::new(&value).is_absolute() {
                return PathBuf::from(value).join("Narad");
            }
        }
        #[cfg(windows)]
        unsafe {
            use windows_sys::Win32::{
                System::Com::CoTaskMemFree,
                UI::Shell::{FOLDERID_Downloads, SHGetKnownFolderPath},
            };
            let mut path = std::ptr::null_mut();
            if SHGetKnownFolderPath(&FOLDERID_Downloads, 0, std::ptr::null_mut(), &mut path) == 0
                && !path.is_null()
            {
                let mut len = 0;
                while *path.add(len) != 0 {
                    len += 1;
                }
                let value = String::from_utf16_lossy(std::slice::from_raw_parts(path, len));
                CoTaskMemFree(path.cast());
                return PathBuf::from(value).join("Narad");
            }
        }
        let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" });
        home.map(PathBuf::from)
            .map(|home| home.join("Downloads").join("Narad"))
            .unwrap_or_else(|| dir.join("downloads"))
    }

    #[cfg(test)]
    pub fn load(dir: PathBuf, name: String, address: String, port: u16) -> Result<Self> {
        Self::load_with_identity(dir, name, address, port, None)
    }
    pub fn load_with_identity(
        dir: PathBuf,
        name: String,
        address: String,
        port: u16,
        identity: Option<Identity>,
    ) -> Result<Self> {
        let identity = match identity {
            Some(identity) => identity,
            None => Identity::load_or_create(&dir)?,
        };
        let own = identity.peer(name, address, port);
        own.validate()?;
        let path = dir.join("trust.enc");
        let trust: TrustState = if path.exists() {
            load_encrypted(&path, &identity.storage_key())?
        } else {
            TrustState::default()
        };
        let token = narad_core::identity::random_token();
        narad_core::storage::atomic_write(&dir.join("api-token"), token.as_bytes())?;
        let transfers = load_transfers(
            &dir.join("transfers"),
            &identity.storage_key(),
            &Self::downloads_directory(&dir),
        )?
        .into_iter()
        .map(|t| (t.id.clone(), t))
        .collect::<BTreeMap<_, _>>();
        let outbound_path = dir.join("outbound.enc");
        let outbound = if outbound_path.exists() {
            load_encrypted(&outbound_path, &identity.storage_key())?
        } else {
            BTreeMap::new()
        };
        let commands = if dir.join("commands.json.enc").exists() {
            load_encrypted(&dir.join("commands.json.enc"), &identity.storage_key())?
        } else {
            BTreeMap::new()
        };
        let preferences = if dir.join("preferences.enc").exists() {
            load_encrypted(&dir.join("preferences.enc"), &identity.storage_key())?
        } else {
            crate::preferences::Preferences::default()
        };
        let mut state = Self {
            preferences,
            clipboard_digest: None,
            shared_transfer_activity: BTreeMap::new(),
            share_uploads: BTreeMap::new(),
            storage_jobs: BTreeMap::new(),
            storage_notify: std::sync::Arc::new(tokio::sync::Notify::new()),
            dir,
            identity,
            own,
            token,
            trust,
            replay: HashMap::new(),
            invitations: BTreeMap::new(),
            pairings: BTreeMap::new(),
            sessions: BTreeMap::new(),
            transfers,
            clipboard: BTreeMap::new(),
            outbound,
            phone_jobs: BTreeMap::new(),
            phone_support: serde_json::json!({}),
            phone_seen: 0,
            media_ready: false,
            camera_ready: false,
            microphone_ready: false,
            outgoing_media: HashSet::new(),
            presence: BTreeMap::new(),
            platform_actions: BTreeMap::new(),
            commands,
            media_seen: 0,
            signals: vec![],
            events: vec![],
        };
        for t in state.transfers.values() {
            if t.status == "receiving"
                && state.trust.peers.get(&t.peer_id).is_some_and(|r| {
                    state
                        .trust
                        .authorize(&r.peer, "file.transfer", true)
                        .is_ok()
                })
            {
                state.sessions.insert(
                    t.id.clone(),
                    Session {
                        id: t.id.clone(),
                        peer_id: t.peer_id.clone(),
                        capability: "file.transfer".into(),
                        with_audio: false,
                        state: SessionState::Active,
                        updated_at: now(),
                    },
                );
            }
        }
        state.event("daemon.started", json!({"protocol_version":1}));
        Ok(state)
    }
    pub fn automatic(&self, peer: &str, capability: &str) -> bool {
        let key = narad_core::policy::permission_key(peer, capability);
        self.trust.permissions.get(&key) == Some(&true)
            && self.trust.automatic.get(&key) == Some(&true)
    }
    pub fn note_presence(&mut self, id: &str, online: bool) {
        let previous = self.presence.get(id).cloned().unwrap_or_default();
        self.presence.insert(
            id.into(),
            Presence {
                online,
                last_seen: if online {
                    Some(now())
                } else {
                    previous.last_seen
                },
                checked_at: now(),
            },
        );
        if previous.online != online {
            self.event(
                if online {
                    "device.online"
                } else {
                    "device.offline"
                },
                json!({"peer_id":id}),
            );
        }
    }
    pub fn approve_file(&mut self, id: &str) -> Result<()> {
        let peer = self
            .transfers
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("unknown transfer"))?
            .peer_id
            .clone();
        let dir = self.dir.join("transfers");
        let key = self.identity.storage_key();
        self.transfers.get_mut(id).unwrap().approve(&dir, &key)?;
        self.new_session(id, &peer, "file.transfer", true)?;
        for next in [
            SessionState::Negotiating,
            SessionState::Connected,
            SessionState::Active,
        ] {
            self.sessions.get_mut(id).unwrap().transition(next)?;
        }
        self.event(
            "file.accepted",
            json!({"id":id,"peer_id":peer,"automatic":self.automatic(&peer,"file.transfer")}),
        );
        Ok(())
    }
    pub fn save_trust(&mut self) -> Result<()> {
        let path = self.dir.join("trust.enc");
        if let Err(e) = save_encrypted(&path, &self.identity.storage_key(), &self.trust) {
            self.trust = load_encrypted(&path, &self.identity.storage_key()).unwrap_or_default();
            for s in self.sessions.values_mut() {
                s.close();
            }
            self.signals.clear();
            self.clipboard.clear();
            return Err(e);
        }
        Ok(())
    }
    pub fn save_preferences(&mut self) -> Result<()> {
        let path = self.dir.join("preferences.enc");
        if let Err(e) = save_encrypted(&path, &self.identity.storage_key(), &self.preferences) {
            self.preferences =
                load_encrypted(&path, &self.identity.storage_key()).unwrap_or_default();
            return Err(e);
        }
        Ok(())
    }
    pub fn save_outbound(&self) -> Result<()> {
        save_encrypted(
            &self.dir.join("outbound.enc"),
            &self.identity.storage_key(),
            &self.outbound,
        )
    }
    pub fn event(&mut self, kind: &str, detail: Value) {
        self.events
            .push(json!({"timestamp":now(),"type":kind,"detail":detail}));
        if self.events.len() > 100 {
            self.events.remove(0);
        }
    }
    pub fn peer(&self, id: &str) -> Result<Peer> {
        Ok(self
            .trust
            .peers
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("device is not paired"))?
            .peer
            .clone())
    }
    pub fn session(&self, id: &str, peer: &Peer, capability: &str) -> Result<()> {
        let session = self.sessions.get(id).context("unknown session")?;
        if session.with_audio && !self.outgoing_media.contains(id) {
            ensure!(self.microphone_ready, "Microphone sharing is disabled");
            self.trust.authorize(peer, "audio.input", true)?;
        }
        self.trust.authorize_session(
            peer,
            self.sessions
                .get(id)
                .ok_or_else(|| anyhow::anyhow!("unknown session"))?,
            capability,
        )
    }
    pub fn new_session(
        &mut self,
        id: &str,
        peer: &str,
        capability: &str,
        approved: bool,
    ) -> Result<()> {
        ensure!(!self.sessions.contains_key(id), "session already exists");
        if self.sessions.len() >= 512 {
            self.sessions.retain(|_, s| {
                !matches!(
                    s.state,
                    SessionState::Closed | SessionState::Failed | SessionState::Denied
                )
            });
        }
        ensure!(self.sessions.len() < 512, "too many sessions");
        self.sessions.insert(
            id.into(),
            Session {
                id: id.into(),
                peer_id: peer.into(),
                capability: capability.into(),
                with_audio: false,
                state: if approved {
                    SessionState::Authorized
                } else {
                    SessionState::Requested
                },
                updated_at: now(),
            },
        );
        Ok(())
    }
    pub fn expire(&mut self) {
        let t = now();
        if (self.media_ready || self.camera_ready || self.microphone_ready)
            && t.saturating_sub(self.media_seen) > 15
        {
            self.media_ready = false;
            self.camera_ready = false;
            self.microphone_ready = false;
            self.own.capabilities.retain(|c| {
                !["audio.output", "audio.input", "camera.stream"].contains(&c.as_str())
            });
            for s in self.sessions.values_mut() {
                if ["audio.output", "audio.input", "camera.stream"].contains(&s.capability.as_str())
                {
                    s.close();
                }
            }
            self.signals.clear();
        }
        self.outgoing_media.retain(|id| {
            self.sessions
                .get(id)
                .is_some_and(|s| s.state != SessionState::Closed)
        });
        self.storage_jobs.retain(|_, j| j.expires > t);
        let expired = self
            .share_uploads
            .iter()
            .filter(|(_, u)| t.saturating_sub(u.transfer.updated_at) > 120)
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        for id in expired {
            if let Some(mut u) = self.share_uploads.remove(&id) {
                let _ = u.transfer.cancel(
                    &self.dir.join("share-transfers"),
                    &self.identity.storage_key(),
                );
            }
        }
        self.platform_actions.retain(|_, a| a.expires_at > t);
        self.invitations.retain(|_, i| i.expires_at > t);
        self.pairings.retain(|_, p| p.expires_at > t);
        self.clipboard.retain(|_, c| c.expires_at > t);
        for s in self.sessions.values_mut() {
            if t.saturating_sub(s.updated_at) > 120 {
                s.close();
            }
        }
    }
}
