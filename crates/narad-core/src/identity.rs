use crate::{
    model::{now, Peer},
    storage::private_dir,
};
use anyhow::{ensure, Result};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::Path};

pub fn hex(data: &[u8]) -> String {
    use std::fmt::Write;
    data.iter()
        .fold(String::with_capacity(data.len() * 2), |mut s, b| {
            write!(&mut s, "{b:02x}").unwrap();
            s
        })
}
pub fn unhex(s: &str) -> Result<Vec<u8>> {
    ensure!(s.len() % 2 == 0 && s.is_ascii(), "invalid hex");
    Ok((0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16))
        .collect::<Result<Vec<_>, _>>()?)
}
pub fn random_token() -> String {
    let mut b = [0; 32];
    OsRng.fill_bytes(&mut b);
    hex(&b)
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Identity {
    secret: [u8; 32],
    pub certificate: Vec<u8>,
    pub tls_key: Vec<u8>,
}
impl Identity {
    pub fn load_or_create(dir: &Path) -> Result<Self> {
        private_dir(dir)?;
        #[cfg(windows)]
        return crate::windows::load_identity(dir);
        #[cfg(not(windows))]
        {
            let path = dir.join("identity.json");
            if path.exists() {
                return Ok(serde_json::from_slice(&std::fs::read(path)?)?);
            }
            let identity = Self::generate()?;
            crate::storage::atomic_write(&path, &serde_json::to_vec(&identity)?)?;
            Ok(identity)
        }
    }
    /// Generate in memory so platform keystores can persist wrapped identity bytes.
    pub fn generate() -> Result<Self> {
        let key = SigningKey::generate(&mut OsRng);
        let cert = rcgen::generate_simple_self_signed(vec!["narad.local".into()])?;
        Ok(Self {
            secret: key.to_bytes(),
            certificate: cert.cert.der().to_vec(),
            tls_key: cert.key_pair.serialize_der(),
        })
    }
    pub fn public_key(&self) -> String {
        hex(SigningKey::from_bytes(&self.secret)
            .verifying_key()
            .as_bytes())
    }
    pub fn storage_key(&self) -> [u8; 32] {
        blake3::derive_key("Narad v1 encrypted trust storage", &self.secret)
    }
    pub fn peer(&self, name: String, address: String, port: u16) -> Peer {
        let public_key = self.public_key();
        Peer {
            device_id: blake3::hash(public_key.as_bytes()).to_hex().to_string(),
            device_name: name,
            platform: std::env::consts::OS.into(),
            protocol_version: crate::PROTOCOL_VERSION,
            public_key,
            certificate_hash: blake3::hash(&self.certificate).to_hex().to_string(),
            address,
            port,
            capabilities: {
                let mut capabilities: Vec<String> = vec![
                    "file.transfer".into(),
                    "clipboard.sync".into(),
                    "file.browse".into(),
                    "file.upload".into(),
                    "command.run".into(),
                    "device.lock".into(),
                    "device.find".into(),
                ];
                if cfg!(target_os = "ios") {
                    capabilities.retain(|c| !["command.run", "device.lock"].contains(&c.as_str()));
                }
                if !cfg!(windows) && !cfg!(target_os = "ios") {
                    capabilities.push("device.unlock".into());
                }
                capabilities
            },
        }
    }
    pub fn sign(&self, peer: &Peer, payload: serde_json::Value) -> Result<SignedFrame> {
        let mut f = SignedFrame {
            version: crate::PROTOCOL_VERSION,
            sender: peer.clone(),
            request_id: random_token(),
            timestamp: now(),
            payload,
            signature: String::new(),
        };
        f.signature = hex(&SigningKey::from_bytes(&self.secret)
            .sign(&f.signing_bytes()?)
            .to_bytes());
        Ok(f)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SignedFrame {
    pub version: u16,
    pub sender: Peer,
    pub request_id: String,
    pub timestamp: u64,
    pub payload: serde_json::Value,
    pub signature: String,
}
impl SignedFrame {
    fn signing_bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(&(
            self.version,
            &self.sender,
            &self.request_id,
            self.timestamp,
            &self.payload,
        ))?)
    }
    pub fn verify(&self, replay: &mut HashMap<String, u64>) -> Result<()> {
        self.sender.validate()?;
        ensure!(
            self.version == crate::PROTOCOL_VERSION && self.timestamp.abs_diff(now()) <= 60,
            "invalid protocol version or stale message"
        );
        ensure!(self.request_id.len() == 64, "invalid request ID");
        let key = VerifyingKey::from_bytes(
            &unhex(&self.sender.public_key)?
                .try_into()
                .map_err(|_| anyhow::anyhow!("bad public key"))?,
        )?;
        let signature = Signature::from_slice(&unhex(&self.signature)?)?;
        key.verify_strict(&self.signing_bytes()?, &signature)?;
        replay.retain(|_, t| now().saturating_sub(*t) <= 120);
        let token = format!("{}:{}", self.sender.device_id, self.request_id);
        ensure!(!replay.contains_key(&token), "replayed message");
        ensure!(replay.len() < 10000, "too many messages; retry later");
        replay.insert(token, now());
        Ok(())
    }
}

/// Both devices compare this transcript-bound code after an out-of-band invitation.
pub fn pairing_code(a: &Peer, b: &Peer, nonce: &str) -> String {
    let mut keys = [
        format!("{}:{}", a.public_key, a.certificate_hash),
        format!("{}:{}", b.public_key, b.certificate_hash),
    ];
    keys.sort();
    let hash = blake3::hash(format!("Narad pairing v1|{}|{}|{nonce}", keys[0], keys[1]).as_bytes());
    format!(
        "{:06}",
        u32::from_le_bytes(hash.as_bytes()[..4].try_into().unwrap()) % 1_000_000
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stable_identity_and_authenticated_frames() {
        let d = tempfile::tempdir().unwrap();
        let i = Identity::load_or_create(d.path()).unwrap();
        assert_eq!(
            i.public_key(),
            Identity::load_or_create(d.path()).unwrap().public_key()
        );
        let p = i.peer("Laptop".into(), "127.0.0.1".into(), 45678);
        let f = i.sign(&p, serde_json::json!({"op":"ping"})).unwrap();
        let mut replay = HashMap::new();
        f.verify(&mut replay).unwrap();
        assert!(f.verify(&mut replay).is_err());
        let mut tampered = f.clone();
        tampered.payload = serde_json::json!({"op":"file.delete"});
        assert!(tampered.verify(&mut HashMap::new()).is_err());
        let mut stale = f;
        stale.timestamp = 0;
        assert!(stale.verify(&mut HashMap::new()).is_err());
    }
}
