use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    time::{SystemTime, UNIX_EPOCH},
};

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Peer {
    pub device_id: String,
    pub device_name: String,
    pub platform: String,
    pub protocol_version: u16,
    pub public_key: String,
    pub certificate_hash: String,
    pub address: String,
    pub port: u16,
    pub capabilities: Vec<String>,
}
impl Peer {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.protocol_version == crate::PROTOCOL_VERSION,
            "unsupported protocol version"
        );
        ensure!(
            !self.device_name.is_empty() && self.device_name.len() <= 128,
            "invalid device name"
        );
        ensure!(self.port > 0 && self.port < 65535, "invalid control port");
        let address: std::net::Ipv4Addr = self.address.parse()?;
        ensure!(
            address.is_private() || address.is_loopback() || address.is_link_local(),
            "endpoint must be on a private IPv4 network"
        );
        ensure!(
            !self.platform.is_empty() && self.platform.len() <= 32 && self.platform.is_ascii(),
            "invalid platform"
        );
        ensure!(
            self.capabilities.len() <= 32
                && self.capabilities.iter().all(|c| !c.is_empty()
                    && c.len() <= 64
                    && c.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_')),
            "invalid advertised capabilities"
        );
        ensure!(
            self.public_key.len() == 64 && self.certificate_hash.len() == 64,
            "invalid identity"
        );
        ensure!(
            self.device_id == blake3::hash(self.public_key.as_bytes()).to_hex().as_str(),
            "device ID/key mismatch"
        );
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Invitation {
    pub peer: Peer,
    pub nonce: String,
    pub expires_at: u64,
}
impl Invitation {
    pub fn validate(&self) -> Result<()> {
        self.peer.validate()?;
        ensure!(
            self.expires_at > now() && self.expires_at <= now() + 360,
            "pairing invitation expired or invalid"
        );
        ensure!(self.nonce.len() == 64, "invalid pairing nonce");
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Requested,
    Authorized,
    Negotiating,
    Connected,
    Active,
    Releasing,
    Closed,
    Denied,
    Failed,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub peer_id: String,
    pub capability: String,
    #[serde(default)]
    pub with_audio: bool,
    pub state: SessionState,
    pub updated_at: u64,
}
impl Session {
    pub fn transition(&mut self, next: SessionState) -> Result<()> {
        use SessionState::*;
        let valid = matches!(
            (&self.state, &next),
            (Requested, Authorized | Denied)
                | (Authorized, Negotiating)
                | (Negotiating, Connected)
                | (Connected, Active)
                | (Active, Releasing)
                | (Authorized | Negotiating | Connected | Requested, Releasing)
                | (Releasing, Closed)
        );
        ensure!(
            valid || (next == Failed && !matches!(self.state, Closed | Denied | Failed)),
            "invalid session transition"
        );
        self.state = next;
        self.updated_at = now();
        Ok(())
    }
    pub fn close(&mut self) {
        if !matches!(
            self.state,
            SessionState::Closed | SessionState::Denied | SessionState::Failed
        ) {
            if self.state != SessionState::Releasing {
                self.transition(SessionState::Releasing)
                    .expect("nonterminal session can release");
            }
            self.transition(SessionState::Closed)
                .expect("releasing session can close");
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TrustRecord {
    pub peer: Peer,
    pub paired_at: u64,
}

#[derive(Default, Clone, Serialize, Deserialize)]
pub struct TrustState {
    pub peers: BTreeMap<String, TrustRecord>,
    pub permissions: BTreeMap<String, bool>,
    #[serde(default)]
    pub automatic: BTreeMap<String, bool>,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fresh_invitations_tolerate_the_signed_frame_clock_skew() {
        let peer = crate::identity::Identity::generate().unwrap().peer(
            "Clock fixture".into(),
            "127.0.0.1".into(),
            46000,
        );
        let mut invitation = Invitation {
            peer,
            nonce: "a".repeat(64),
            expires_at: now() + 330,
        };
        assert!(invitation.validate().is_ok());
        invitation.expires_at = now() + 400;
        assert!(invitation.validate().is_err());
        invitation.expires_at = now() - 1;
        assert!(invitation.validate().is_err());
    }
    #[test]
    fn cannot_skip_authorization_or_reactivate_closed_session() {
        let mut s = Session {
            id: "s".into(),
            peer_id: "p".into(),
            capability: "file.transfer".into(),
            with_audio: false,
            state: SessionState::Requested,
            updated_at: now(),
        };
        assert!(s.transition(SessionState::Active).is_err());
        for state in [
            SessionState::Authorized,
            SessionState::Negotiating,
            SessionState::Connected,
            SessionState::Active,
            SessionState::Releasing,
            SessionState::Closed,
        ] {
            s.transition(state).unwrap();
        }
        assert!(s.transition(SessionState::Active).is_err());
    }
}
