use anyhow::{ensure, Context, Result};
use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305, Nonce,
};
use rand::{rngs::OsRng, RngCore};
use serde::{de::DeserializeOwned, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
};

pub fn private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Write in the same directory and atomically replace, never follow a temp symlink.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().context("missing parent directory")?;
    private_dir(parent)?;
    let tmp = parent.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| {
        let mut file = options.open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, path)?;
        #[cfg(unix)]
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result
}

pub fn save_encrypted<T: Serialize>(path: &Path, key: &[u8; 32], value: &T) -> Result<()> {
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let cipher = ChaCha20Poly1305::new(key.into());
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            serde_json::to_vec(value)?.as_ref(),
        )
        .map_err(|_| anyhow::anyhow!("state encryption failed"))?;
    atomic_write(path, &[nonce.as_slice(), ciphertext.as_slice()].concat())
}

pub fn load_encrypted<T: DeserializeOwned>(path: &Path, key: &[u8; 32]) -> Result<T> {
    let data = fs::read(path)?;
    ensure!(data.len() >= 28, "truncated encrypted state");
    let plaintext = ChaCha20Poly1305::new(key.into())
        .decrypt(Nonce::from_slice(&data[..12]), &data[12..])
        .map_err(|_| anyhow::anyhow!("state authentication failed"))?;
    Ok(serde_json::from_slice(&plaintext)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encrypted_state_rejects_tampering_and_wrong_key() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("trust");
        save_encrypted(&p, &[1; 32], &vec!["peer"]).unwrap();
        assert_eq!(
            load_encrypted::<Vec<String>>(&p, &[1; 32]).unwrap(),
            ["peer"]
        );
        assert!(load_encrypted::<Vec<String>>(&p, &[2; 32]).is_err());
        let mut data = fs::read(&p).unwrap();
        data[15] ^= 1;
        fs::write(&p, data).unwrap();
        assert!(load_encrypted::<Vec<String>>(&p, &[1; 32]).is_err());
    }
}
