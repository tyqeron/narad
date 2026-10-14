use crate::model::{Peer, Session, SessionState, TrustState};
use anyhow::{ensure, Result};

pub fn permission_key(peer: &str, capability: &str) -> String {
    format!("{peer}/{capability}")
}

impl TrustState {
    pub fn authenticate(&self, peer: &Peer) -> Result<()> {
        let record = self
            .peers
            .get(&peer.device_id)
            .ok_or_else(|| anyhow::anyhow!("device is not paired"))?;
        ensure!(
            record.peer.public_key == peer.public_key
                && record.peer.certificate_hash == peer.certificate_hash,
            "paired identity changed"
        );
        Ok(())
    }
    pub fn authorize(&self, peer: &Peer, capability: &str, os_allowed: bool) -> Result<()> {
        self.authenticate(peer)?;
        ensure!(os_allowed, "platform permission denied");
        ensure!(
            self.permissions
                .get(&permission_key(&peer.device_id, capability))
                == Some(&true),
            "capability permission denied"
        );
        Ok(())
    }
    pub fn authorize_session(
        &self,
        peer: &Peer,
        session: &Session,
        capability: &str,
    ) -> Result<()> {
        self.authorize(peer, capability, true)?;
        ensure!(
            session.peer_id == peer.device_id && session.capability == capability,
            "session ownership mismatch"
        );
        ensure!(
            matches!(
                session.state,
                SessionState::Authorized
                    | SessionState::Negotiating
                    | SessionState::Connected
                    | SessionState::Active
            ),
            "session is not authorized"
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        identity::Identity,
        model::{now, TrustRecord},
    };
    #[test]
    fn pairing_does_not_grant_capabilities() {
        let d = tempfile::tempdir().unwrap();
        let peer =
            Identity::load_or_create(d.path())
                .unwrap()
                .peer("A".into(), "127.0.0.1".into(), 45678);
        let mut state = TrustState::default();
        assert!(state.authorize(&peer, "file.transfer", true).is_err());
        state.peers.insert(
            peer.device_id.clone(),
            TrustRecord {
                peer: peer.clone(),
                paired_at: now(),
            },
        );
        assert!(state.authorize(&peer, "file.transfer", true).is_err());
        state
            .permissions
            .insert(permission_key(&peer.device_id, "file.transfer"), true);
        state.authorize(&peer, "file.transfer", true).unwrap();
        assert!(state.authorize(&peer, "clipboard.sync", true).is_err());
        assert!(state.authorize(&peer, "file.transfer", false).is_err());
    }
}
