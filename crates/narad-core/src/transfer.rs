use crate::{
    model::now,
    storage::{load_encrypted, save_encrypted},
    CHUNK_SIZE,
};
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

pub const MAX_FILE_SIZE: u64 = 1024 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Transfer {
    pub id: String,
    pub peer_id: String,
    pub file_name: String,
    pub file_size: u64,
    pub checksum: String,
    pub received: u64,
    pub status: String,
    pub updated_at: u64,
}
impl Transfer {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            uuid::Uuid::parse_str(&self.id).is_ok(),
            "invalid transfer ID"
        );
        ensure!(
            !self.file_name.is_empty()
                && self.file_name.len() <= 240
                && !self.file_name.contains(['/', '\\', '\0'])
                && self.file_name != "."
                && self.file_name != "..",
            "unsafe file name"
        );
        ensure!(
            self.file_size <= MAX_FILE_SIZE && self.received <= self.file_size,
            "file size exceeds limit"
        );
        ensure!(
            self.checksum.len() == 64 && self.checksum.bytes().all(|b| b.is_ascii_hexdigit()),
            "invalid BLAKE3 checksum"
        );
        Ok(())
    }
    fn path(&self, dir: &Path) -> PathBuf {
        dir.join(format!("{}.part", self.id))
    }
    fn manifest(&self, dir: &Path) -> PathBuf {
        dir.join(format!("{}.json.enc", self.id))
    }
    pub fn persist(&self, dir: &Path, key: &[u8; 32]) -> Result<()> {
        self.validate()?;
        save_encrypted(&self.manifest(dir), key, self)
    }
    pub fn approve(&mut self, dir: &Path, key: &[u8; 32]) -> Result<()> {
        ensure!(self.status == "pending", "transfer is not pending");
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(self.path(dir))?;
        file.sync_all()?;
        self.status = "receiving".into();
        self.updated_at = now();
        self.persist(dir, key)
    }
    pub fn append(
        &mut self,
        dir: &Path,
        key: &[u8; 32],
        offset: u64,
        data: &[u8],
        checksum: &str,
    ) -> Result<()> {
        ensure!(
            self.status == "receiving",
            "transfer is not approved or was cancelled"
        );
        ensure!(
            !data.is_empty() && data.len() <= CHUNK_SIZE,
            "invalid chunk size"
        );
        ensure!(
            blake3::hash(data).to_hex().as_str() == checksum,
            "chunk checksum mismatch"
        );
        ensure!(
            offset <= self.received && offset + data.len() as u64 <= self.file_size,
            "invalid chunk offset"
        );
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(self.path(dir))?;
        if offset < self.received {
            ensure!(
                offset + data.len() as u64 <= self.received,
                "overlapping retry chunk"
            );
            let mut previous = vec![0; data.len()];
            file.seek(SeekFrom::Start(offset))?;
            file.read_exact(&mut previous)?;
            ensure!(previous == data, "retry chunk differs");
            return Ok(());
        }
        file.set_len(self.received)?;
        file.seek(SeekFrom::Start(offset))?;
        file.write_all(data)?;
        file.sync_all()?;
        self.received += data.len() as u64;
        self.updated_at = now();
        self.persist(dir, key)
    }
    pub fn finish(&mut self, dir: &Path, key: &[u8; 32], downloads: &Path) -> Result<PathBuf> {
        ensure!(
            self.status == "receiving" && self.received == self.file_size,
            "incomplete or inactive transfer"
        );
        ensure!(
            hash_file(&self.path(dir))? == self.checksum,
            "file checksum mismatch"
        );
        crate::storage::private_dir(downloads)?;
        // An ID directory prevents overwriting a user's existing file, including on retry.
        let destination = downloads.join(&self.id);
        crate::storage::private_dir(&destination)?;
        let out = destination.join(&self.file_name);
        // Android app sandboxes reject hard links. Publish by atomic no-replace
        // rename on Linux/Android; keep the original path until publication succeeds.
        publish_completed(&self.path(dir), &out)?;
        #[cfg(unix)]
        {
            File::open(&destination)?.sync_all()?;
            File::open(downloads)?.sync_all()?;
        }
        if self.path(dir).exists() {
            fs::remove_file(self.path(dir))?;
        }
        self.status = "completed".into();
        self.updated_at = now();
        self.persist(dir, key)?;
        Ok(out)
    }
    pub fn cancel(&mut self, dir: &Path, key: &[u8; 32]) -> Result<()> {
        ensure!(
            self.status != "completed",
            "completed transfer cannot be cancelled"
        );
        self.status = "cancelled".into();
        self.updated_at = now();
        self.persist(dir, key)?;
        if self.path(dir).exists() {
            fs::remove_file(self.path(dir))?;
        }
        Ok(())
    }
}

/// Atomically publish a verified file without replacing another transfer's data.
#[cfg(any(target_os = "android", target_os = "linux"))]
fn publish_completed(source: &Path, destination: &Path) -> Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let source = CString::new(source.as_os_str().as_bytes())?;
    let destination = CString::new(destination.as_os_str().as_bytes())?;
    // SAFETY: both C strings remain alive for the syscall. AT_FDCWD interprets
    // these paths normally and RENAME_NOREPLACE refuses an existing destination.
    // A direct syscall also supports Android before bionic exposed renameat2.
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            destination.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error()).context("publish completed transfer");
    }
    Ok(())
}
#[cfg(not(any(target_os = "android", target_os = "linux")))]
fn publish_completed(source: &Path, destination: &Path) -> Result<()> {
    fs::hard_link(source, destination).context("publish completed transfer")
}

pub fn hash_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hash = blake3::Hasher::new();
    let mut buf = [0; CHUNK_SIZE];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Ok(hash.finalize().to_hex().to_string())
}

pub fn load_transfers(dir: &Path, key: &[u8; 32], downloads: &Path) -> Result<Vec<Transfer>> {
    crate::storage::private_dir(dir)?;
    let mut transfers = vec![];
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if !path.to_string_lossy().ends_with(".json.enc") {
            continue;
        }
        let mut t: Transfer = load_encrypted(&path, key).context("invalid transfer manifest")?;
        t.validate()?;
        if t.status == "receiving" {
            let completed = downloads.join(&t.id).join(&t.file_name);
            if completed.exists()
                && t.received == t.file_size
                && hash_file(&completed)? == t.checksum
            {
                if t.path(dir).exists() {
                    fs::remove_file(t.path(dir))?;
                }
                t.status = "completed".into();
                t.persist(dir, key)?;
            } else {
                let file = OpenOptions::new().write(true).open(t.path(dir))?;
                ensure!(
                    file.metadata()?.len() >= t.received,
                    "transfer data truncated"
                );
                file.set_len(t.received)?;
            }
        }
        transfers.push(t);
    }
    Ok(transfers)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn transfer(bytes: &[u8]) -> Transfer {
        Transfer {
            id: uuid::Uuid::new_v4().to_string(),
            peer_id: "p".into(),
            file_name: "notes.txt".into(),
            file_size: bytes.len() as u64,
            checksum: blake3::hash(bytes).to_hex().to_string(),
            received: 0,
            status: "pending".into(),
            updated_at: now(),
        }
    }
    #[test]
    fn resume_checksums_retry_and_completion() {
        let d = tempfile::tempdir().unwrap();
        let downloads = d.path().join("downloads");
        let key = [1; 32];
        let data = b"hello world";
        let mut t = transfer(data);
        assert!(t.append(d.path(), &key, 0, b"hello", "wrong").is_err());
        t.approve(d.path(), &key).unwrap();
        let h = blake3::hash(b"hello").to_hex().to_string();
        t.append(d.path(), &key, 0, b"hello", &h).unwrap();
        t.append(d.path(), &key, 0, b"hello", &h).unwrap();
        let mut t = load_transfers(d.path(), &key, &downloads)
            .unwrap()
            .remove(0);
        assert_eq!(t.received, 5);
        assert!(t.finish(d.path(), &key, &downloads).is_err());
        t.append(
            d.path(),
            &key,
            5,
            b" world",
            blake3::hash(b" world").to_hex().as_str(),
        )
        .unwrap();
        let out = t.finish(d.path(), &key, &downloads).unwrap();
        assert_eq!(fs::read(out).unwrap(), data);
    }
    #[test]
    fn completion_never_overwrites_an_existing_destination() {
        let directory = tempfile::tempdir().unwrap();
        let downloads = directory.path().join("downloads");
        let key = [3; 32];
        let data = b"verified bytes";
        let mut transfer = transfer(data);
        transfer.approve(directory.path(), &key).unwrap();
        transfer
            .append(
                directory.path(),
                &key,
                0,
                data,
                blake3::hash(data).to_hex().as_str(),
            )
            .unwrap();
        let destination = downloads.join(&transfer.id);
        fs::create_dir_all(&destination).unwrap();
        let existing = destination.join(&transfer.file_name);
        fs::write(&existing, b"keep existing file").unwrap();
        assert!(transfer.finish(directory.path(), &key, &downloads).is_err());
        assert_eq!(fs::read(&existing).unwrap(), b"keep existing file");
        assert_eq!(fs::read(transfer.path(directory.path())).unwrap(), data);
        fs::remove_file(existing).unwrap();
        let completed = transfer.finish(directory.path(), &key, &downloads).unwrap();
        assert_eq!(fs::read(completed).unwrap(), data);
    }
    #[test]
    fn reject_traversal_corruption_and_cancelled_writes() {
        let d = tempfile::tempdir().unwrap();
        let mut t = transfer(b"hello");
        t.file_name = "../secret".into();
        assert!(t.validate().is_err());
        t.file_name = "good".into();
        t.approve(d.path(), &[0; 32]).unwrap();
        assert!(t.append(d.path(), &[0; 32], 0, b"hello", "0").is_err());
        t.cancel(d.path(), &[0; 32]).unwrap();
        assert!(t
            .append(
                d.path(),
                &[0; 32],
                0,
                b"hello",
                blake3::hash(b"hello").to_hex().as_str()
            )
            .is_err());
    }
}
