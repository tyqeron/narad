//! Selected-folder mounts and bounded, permissioned native document-provider jobs.
use crate::{
    handler::{number, string},
    preferences::SharedFolder,
    state::State,
    transport::remote_call,
};
use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use narad_core::{
    model::{now, Peer},
    transfer::{Transfer, MAX_FILE_SIZE},
    CHUNK_SIZE,
};
use serde_json::{json, Value};
use std::{
    io::{Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::sync::Mutex;

pub struct Upload {
    pub transfer: Transfer,
    pub folder: SharedFolder,
    pub relative: String,
}
pub struct Job {
    pub peer: String,
    pub folder: SharedFolder,
    pub capability: String,
    pub kind: String,
    pub args: Value,
    pub expires: u64,
    pub dispatched: bool,
    pub result: Option<Value>,
}
fn relative(path: &str) -> Result<()> {
    ensure!(
        path.len() <= 1024
            && !path.contains(['\\', '\0'])
            && Path::new(path)
                .components()
                .all(|c| matches!(c, Component::Normal(_))),
        "Path must stay in the shared folder"
    );
    #[cfg(windows)]
    for name in path.split('/').filter(|v| !v.is_empty()) {
        narad_core::transfer::validate_windows_name(name)?;
    }
    Ok(())
}
fn mount(s: &State, path: &str) -> Result<(SharedFolder, String)> {
    relative(path)?;
    let (first, rest) = path.split_once('/').unwrap_or((path, ""));
    if let Some(id) = first
        .strip_prefix('@')
        .filter(|id| uuid::Uuid::parse_str(id).is_ok())
    {
        let folder = s
            .preferences
            .shares
            .iter()
            .find(|f| f.id == id)
            .context("Shared folder removed")?
            .clone();
        return Ok((folder, rest.into()));
    }
    Ok((
        SharedFolder {
            id: "default".into(),
            label: "Shared folder".into(),
            path: s.dir.join("shared").to_string_lossy().into(),
            documents: false,
            upload: true,
            devices: s.preferences.default_share_devices.clone(),
        },
        path.into(),
    ))
}
fn allowed(s: &State, peer: &Peer, folder: &SharedFolder, cap: &str) -> Result<()> {
    s.trust.authorize(peer, cap, true)?;
    ensure!(
        if folder.id == "default" {
            s.preferences
                .default_share_devices
                .contains(&peer.device_id)
        } else {
            s.preferences
                .shares
                .iter()
                .any(|f| f.id == folder.id && f.devices.contains(&peer.device_id))
        },
        "This folder is not shared with this device"
    );
    if folder.id != "default" {
        ensure!(
            s.preferences.shares.iter().any(|f| f.id == folder.id
                && f.path == folder.path
                && f.documents == folder.documents
                && (cap != "file.upload" || f.upload)),
            "Shared folder removed or uploads disabled"
        );
    }
    ensure!(
        cap != "file.upload" || folder.upload,
        "Uploads are disabled for this folder"
    );
    Ok(())
}
fn path_for(s: &State, folder: &SharedFolder, path: &str) -> Result<PathBuf> {
    relative(path)?;
    ensure!(
        !folder.documents,
        "This folder needs the native document bridge"
    );
    let root = PathBuf::from(&folder.path);
    if folder.id == "default" {
        narad_core::storage::private_dir(&root)?;
    }
    ensure!(
        !root.symlink_metadata()?.file_type().is_symlink(),
        "Shared root changed to a symbolic link"
    );
    let root = root.canonicalize()?;
    let target = root.join(path).canonicalize()?;
    ensure!(target.starts_with(&root), "Path escapes the shared folder");
    if folder.id != "default" {
        ensure!(
            !target.starts_with(s.dir.canonicalize()?),
            "Narad private data cannot be shared"
        );
    }
    Ok(target)
}
pub fn filesystem_path(s: &State, path: &str) -> Result<PathBuf> {
    let (f, p) = mount(s, path)?;
    path_for(s, &f, &p)
}
fn entry_path(folder: &SharedFolder, relative: &str, name: &str) -> String {
    let child = if relative.is_empty() {
        name.into()
    } else {
        format!("{relative}/{name}")
    };
    if folder.id == "default" {
        child
    } else {
        format!("@{}/{child}", folder.id)
    }
}
async fn native(
    shared: Arc<Mutex<State>>,
    peer: &Peer,
    folder: &SharedFolder,
    cap: &str,
    kind: &str,
    args: Value,
) -> Result<Value> {
    let id = uuid::Uuid::new_v4().to_string();
    {
        let mut s = shared.lock().await;
        allowed(&s, peer, folder, cap)?;
        s.storage_jobs.retain(|_, j| j.expires > now());
        ensure!(
            s.storage_jobs.len() < 16
                && s.storage_jobs
                    .values()
                    .filter(|j| j.peer == peer.device_id)
                    .count()
                    < 4,
            "Shared folder queue busy"
        );
        s.storage_jobs.insert(
            id.clone(),
            Job {
                peer: peer.device_id.clone(),
                folder: folder.clone(),
                capability: cap.into(),
                kind: kind.into(),
                args,
                expires: now() + 25,
                dispatched: false,
                result: None,
            },
        );
        s.storage_notify.notify_one();
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(12);
    loop {
        tokio::time::sleep(Duration::from_millis(20)).await;
        let mut s = shared.lock().await;
        if let Err(e) = allowed(&s, peer, folder, cap) {
            s.storage_jobs.remove(&id);
            return Err(e);
        }
        let job = s
            .storage_jobs
            .get_mut(&id)
            .context("Shared folder request expired")?;
        if let Some(result) = job.result.take() {
            s.storage_jobs.remove(&id);
            ensure!(
                result["ok"] == true,
                "{}",
                result["error"]
                    .as_str()
                    .unwrap_or("Shared folder access failed")
            );
            return Ok(result);
        }
        if tokio::time::Instant::now() >= deadline {
            s.storage_jobs.remove(&id);
            anyhow::bail!("Shared folder request timed out. Reopen Narad on the source device.");
        }
    }
}
pub async fn browse(
    shared: Arc<Mutex<State>>,
    peer: &Peer,
    p: &Value,
    file: bool,
) -> Result<Value> {
    ensure!(!file, "Wrong shared-folder transport plane");
    let path = p["path"].as_str().unwrap_or("");
    let (folder, child) = {
        let s = shared.lock().await;
        s.trust.authenticate(peer)?;
        s.trust.authorize(peer, "file.browse", true)?;
        mount(&s, path)?
    };
    let mut entries = if path.is_empty() && !folder.devices.contains(&peer.device_id) {
        vec![]
    } else if folder.documents {
        let r = native(
            shared.clone(),
            peer,
            &folder,
            "file.browse",
            "list",
            json!({"path":child}),
        )
        .await?;
        r["entries"]
            .as_array()
            .context("Invalid directory response")?
            .clone()
    } else {
        let s = shared.lock().await;
        allowed(&s, peer, &folder, "file.browse")?;
        let root = path_for(&s, &folder, &child)?;
        ensure!(root.is_dir(), "Not a directory");
        let mut entries = vec![];
        for e in std::fs::read_dir(root)?.take(257) {
            let e = e?;
            let metadata = e.path().symlink_metadata()?;
            if metadata.file_type().is_symlink() || !(metadata.is_file() || metadata.is_dir()) {
                continue;
            }
            let name = e
                .file_name()
                .into_string()
                .map_err(|_| anyhow::anyhow!("File name is not UTF-8"))?;
            if relative(&name).is_err() {
                continue;
            }
            if folder.id != "default" && e.path().canonicalize()?.starts_with(s.dir.canonicalize()?)
            {
                continue;
            }
            entries.push(json!({"name":name,"directory":metadata.is_dir(),"size":metadata.len()}));
        }
        entries
    };
    let mut truncated = entries.len() > 256;
    entries.truncate(256);
    for entry in &mut entries {
        let name = string(entry, "name")?;
        relative(name)?;
        ensure!(!name.contains('/'), "Invalid directory entry");
        entry["path"] = json!(entry_path(&folder, &child, name));
    }
    if path.is_empty() {
        let s = shared.lock().await;
        for f in s
            .preferences
            .shares
            .iter()
            .filter(|f| f.devices.contains(&peer.device_id))
        {
            entries.push(json!({"name":f.label,"path":format!("@{}",f.id),"directory":true,"mount":true,"upload":f.upload,"size":0}));
        }
    }
    entries.sort_by(|a, b| {
        b["directory"]
            .as_bool()
            .cmp(&a["directory"].as_bool())
            .then_with(|| a["name"].as_str().cmp(&b["name"].as_str()))
    });
    while serde_json::to_vec(&entries)?.len() > 60000 {
        entries.pop();
        truncated = true;
    }
    let mut s = shared.lock().await;
    s.trust.authorize(peer, "file.browse", true)?;
    if path.is_empty() {
        entries.retain(|entry| {
            if entry["mount"] == true {
                s.preferences.shares.iter().any(|f| {
                    entry["path"] == format!("@{}", f.id) && f.devices.contains(&peer.device_id)
                })
            } else {
                s.preferences
                    .default_share_devices
                    .contains(&peer.device_id)
            }
        });
    }
    if !path.is_empty() {
        allowed(&s, peer, &folder, "file.browse")?;
    }
    s.note_presence(&peer.device_id, true);
    Ok(
        json!({"ok":true,"path":path,"entries":entries,"truncated":truncated,"upload":allowed(&s,peer,&folder,"file.upload").is_ok()}),
    )
}
pub async fn read(shared: Arc<Mutex<State>>, peer: &Peer, p: &Value, file: bool) -> Result<Value> {
    ensure!(!file, "Wrong shared-folder transport plane");
    let (folder, child) = {
        let s = shared.lock().await;
        s.trust.authenticate(peer)?;
        s.trust.authorize(peer, "file.browse", true)?;
        mount(&s, string(p, "path")?)?
    };
    let offset = p["offset"].as_u64().unwrap_or(0);
    if folder.documents {
        return native(
            shared,
            peer,
            &folder,
            "file.browse",
            "read",
            json!({"path":child,"offset":offset}),
        )
        .await;
    }
    let s = shared.lock().await;
    allowed(&s, peer, &folder, "file.browse")?;
    let path = path_for(&s, &folder, &child)?;
    ensure!(path.is_file(), "Not a file");
    let mut f = std::fs::File::open(path)?;
    let size = f.metadata()?.len();
    ensure!(offset <= size, "Invalid offset");
    f.seek(SeekFrom::Start(offset))?;
    let mut data = vec![0; 48 * 1024];
    let n = f.read(&mut data)?;
    Ok(
        json!({"ok":true,"data":STANDARD.encode(&data[..n]),"size":size,"offset":offset,"next":offset+n as u64}),
    )
}
pub async fn local(shared: Arc<Mutex<State>>, p: &Value) -> Result<Value> {
    let op = string(p, "op")?;
    if op == "storage_jobs" {
        let notify = shared.lock().await.storage_notify.clone();
        if shared
            .lock()
            .await
            .storage_jobs
            .values()
            .all(|j| j.dispatched)
        {
            let _ = tokio::time::timeout(Duration::from_secs(2), notify.notified()).await;
        }
        let mut s = shared.lock().await;
        let mut jobs = vec![];
        let ids = s.storage_jobs.keys().cloned().collect::<Vec<_>>();
        for id in ids {
            let j = &s.storage_jobs[&id];
            if j.dispatched || j.expires <= now() {
                continue;
            }
            if allowed(&s, &s.peer(&j.peer)?, &j.folder, &j.capability).is_err() {
                s.storage_jobs.remove(&id);
                continue;
            }
            let j = s.storage_jobs.get_mut(&id).unwrap();
            j.dispatched = true;
            jobs.push(json!({"id":id,"root":j.folder.path,"kind":j.kind,"args":j.args}));
        }
        return Ok(json!({"ok":true,"jobs":jobs}));
    }
    if op == "storage_validate" || op == "storage_result" {
        let mut s = shared.lock().await;
        let id = string(p, "id")?;
        let j = s
            .storage_jobs
            .get(id)
            .context("Shared folder request expired")?;
        ensure!(
            j.expires > now() && j.dispatched && j.result.is_none(),
            "Shared folder request completed or expired"
        );
        allowed(&s, &s.peer(&j.peer)?, &j.folder, &j.capability)?;
        if op == "storage_result" {
            ensure!(
                p["result"].is_object() && serde_json::to_vec(&p["result"])?.len() <= 72000,
                "Native storage result too large"
            );
            s.storage_jobs.get_mut(id).unwrap().result = Some(p["result"].clone());
        }
        return Ok(json!({"ok":true}));
    }
    if op == "upload_shared" {
        return send_upload(shared, p).await;
    }
    let mut s = shared.lock().await;
    match op {
        "share_add" => {
            let mut devices = std::collections::BTreeSet::new();
            if let Some(peer) = p["peer_id"].as_str() {
                s.peer(peer)?;
                devices.insert(peer.to_string());
            }
            let label = string(p, "label")?;
            ensure!(
                !label.trim().is_empty()
                    && label.len() <= 128
                    && !label.chars().any(char::is_control),
                "Invalid folder label"
            );
            let documents = p["documents"].as_bool().unwrap_or(false);
            let path = string(p, "path")?;
            let path = if documents {
                ensure!(
                    ["android", "ios"].contains(&s.own.platform.as_str())
                        && path.len() <= 16000
                        && (path.starts_with("content://") || path.starts_with("bookmark:")),
                    "Invalid document directory"
                );
                path.to_string()
            } else {
                let path = Path::new(path).canonicalize()?;
                ensure!(
                    path.is_dir() && !path.starts_with(s.dir.canonicalize()?),
                    "Select a folder outside Narad private storage"
                );
                path.to_string_lossy().into()
            };
            if let Some(existing) = s
                .preferences
                .shares
                .iter_mut()
                .find(|f| f.path == path && f.documents == documents)
            {
                ensure!(
                    !devices.is_empty(),
                    "Folder is already shared. Choose devices for it."
                );
                existing.devices.extend(devices);
                let id = existing.id.clone();
                s.save_preferences()?;
                return Ok(json!({"ok":true,"id":id}));
            }
            ensure!(
                s.preferences.shares.len() < 16,
                "At most 16 folders can be shared"
            );
            let folder = SharedFolder {
                id: uuid::Uuid::new_v4().to_string(),
                label: label.trim().into(),
                path,
                documents,
                upload: p["upload"].as_bool().unwrap_or(false),
                devices,
            };
            let id = folder.id.clone();
            s.preferences.shares.push(folder);
            s.save_preferences()?;
            Ok(json!({"ok":true,"id":id}))
        }
        "share_remove" => {
            let id = string(p, "id")?;
            s.preferences.shares.retain(|f| f.id != id);
            s.save_preferences()?;
            Ok(json!({"ok":true}))
        }
        "share_access" => {
            let id = string(p, "id")?;
            let peer = string(p, "peer_id")?;
            s.peer(peer)?;
            let allow = p["allow"]
                .as_bool()
                .context("Expected folder access decision")?;
            let devices = if id == "default" {
                &mut s.preferences.default_share_devices
            } else {
                &mut s
                    .preferences
                    .shares
                    .iter_mut()
                    .find(|f| f.id == id)
                    .context("Shared folder removed")?
                    .devices
            };
            if allow {
                devices.insert(peer.into());
            } else {
                devices.remove(peer);
            }
            s.save_preferences()?;
            Ok(json!({"ok":true}))
        }
        "share_uploads" => {
            let id = string(p, "id")?;
            s.preferences
                .shares
                .iter_mut()
                .find(|f| f.id == id)
                .context("Shared folder removed")?
                .upload = p["enabled"].as_bool().context("Expected enabled boolean")?;
            s.save_preferences()?;
            Ok(json!({"ok":true}))
        }
        _ => anyhow::bail!("Unknown shared-folder operation"),
    }
}
pub async fn upload(
    shared: Arc<Mutex<State>>,
    peer: &Peer,
    p: &Value,
    file: bool,
) -> Result<Value> {
    let op = string(p, "op")?;
    ensure!(
        file == (op == "shared_upload_chunk"),
        "Wrong upload transport plane"
    );
    let id = string(p, "id")?;
    ensure!(uuid::Uuid::parse_str(id).is_ok(), "Invalid upload ID");
    let mut s = shared.lock().await;
    s.trust.authenticate(peer)?;
    s.trust.authorize(peer, "file.upload", true)?;
    let stage = s.dir.join("share-transfers");
    let key = s.identity.storage_key();
    if op == "shared_upload_begin" {
        ensure!(s.share_uploads.len() < 8, "Upload queue full");
        let (folder, child) = mount(&s, string(p, "path")?)?;
        allowed(&s, peer, &folder, "file.upload")?;
        if !folder.documents {
            ensure!(
                path_for(&s, &folder, &child)?.is_dir(),
                "Upload target is not a directory"
            );
        }
        let mut t = Transfer {
            id: id.into(),
            peer_id: peer.device_id.clone(),
            file_name: string(p, "name")?.into(),
            file_size: number(p, "size")?,
            checksum: string(p, "checksum")?.into(),
            received: 0,
            status: "pending".into(),
            updated_at: now(),
        };
        t.validate()?;
        narad_core::transfer::validate_windows_name(&t.file_name)?;
        narad_core::storage::private_dir(&stage)?;
        t.approve(&stage, &key)?;
        s.share_uploads.insert(
            id.into(),
            Upload {
                transfer: t,
                folder,
                relative: child,
            },
        );
        return Ok(json!({"ok":true,"received":0}));
    }
    let u = s.share_uploads.get(id).context("Upload expired")?;
    ensure!(
        u.transfer.peer_id == peer.device_id,
        "Upload owner mismatch"
    );
    allowed(&s, peer, &u.folder, "file.upload")?;
    if op == "shared_upload_chunk" {
        let data = STANDARD.decode(string(p, "data")?)?;
        let t = &mut s.share_uploads.get_mut(id).unwrap().transfer;
        t.append(
            &stage,
            &key,
            number(p, "offset")?,
            &data,
            string(p, "checksum")?,
        )?;
        return Ok(json!({"ok":true,"received":t.received}));
    }
    ensure!(op == "shared_upload_finish", "Unknown upload operation");
    let folder = u.folder.clone();
    let relative = u.relative.clone();
    let name = u.transfer.file_name.clone();
    let done = s.dir.join("share-completed");
    let path = s
        .share_uploads
        .get_mut(id)
        .unwrap()
        .transfer
        .finish(&stage, &key, &done)?;
    drop(s);
    let result = async {
        if folder.documents {
            native(
                shared.clone(),
                peer,
                &folder,
                "file.upload",
                "publish",
                json!({"path":relative,"name":name,"source":path,"upload_id":id}),
            )
            .await?;
        } else {
            let parent = {
                let s = shared.lock().await;
                allowed(&s, peer, &folder, "file.upload")?;
                path_for(&s, &folder, &relative)?
            };
            ensure!(parent.is_dir(), "Not a directory");
            let temporary = parent.join(format!(".narad-upload-{id}.part"));
            let source = path.clone();
            let output = temporary.clone();
            let copied = tokio::task::spawn_blocking(move || -> Result<()> {
                let mut options = std::fs::OpenOptions::new();
                options.write(true).create_new(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    options.mode(0o600);
                }
                let mut out = options.open(output)?;
                std::io::copy(&mut std::fs::File::open(source)?, &mut out)?;
                out.flush()?;
                out.sync_all()?;
                Ok(())
            })
            .await?;
            let publication = (|| -> Result<()> {
                copied?;
                Ok(())
            })();
            if let Err(e) = publication {
                let _ = std::fs::remove_file(&temporary);
                return Err(e);
            }
            let s = shared.lock().await;
            let publication = (|| -> Result<()> {
                allowed(&s, peer, &folder, "file.upload")?;
                ensure!(
                    path_for(&s, &folder, &relative)? == parent,
                    "Shared folder moved during upload"
                );
                narad_core::transfer::publish_completed(&temporary, &parent.join(&name))?;
                Ok(())
            })();
            let _ = std::fs::remove_file(&temporary);
            publication?;
        }
        Ok(json!({"ok":true}))
    }
    .await;
    let mut s = shared.lock().await;
    s.share_uploads.remove(id);
    let _ = std::fs::remove_dir_all(done.join(id));
    let _ = std::fs::remove_file(stage.join(format!("{id}.json.enc")));
    if result.is_ok() {
        s.event(
            "browse.uploaded",
            json!({"peer_id":peer.device_id,"name":name}),
        );
    }
    result
}
async fn send_upload(shared: Arc<Mutex<State>>, p: &Value) -> Result<Value> {
    let peer_id = string(p, "peer_id")?;
    let path = PathBuf::from(string(p, "source")?);
    ensure!(path.is_file(), "Select a file to upload");
    let name = path
        .file_name()
        .and_then(|v| v.to_str())
        .context("Invalid file name")?;
    let size = path.metadata()?.len();
    ensure!(size <= MAX_FILE_SIZE, "File exceeds 1 GiB");
    let (identity, own, peer) = {
        let s = shared.lock().await;
        (s.identity.clone(), s.own.clone(), s.peer(peer_id)?)
    };
    let id = uuid::Uuid::new_v4().to_string();
    let checksum = narad_core::transfer::hash_file(&path)?;
    remote_call(&identity,&own,&peer,false,json!({"op":"shared_upload_begin","id":id,"path":p["path"],"name":name,"size":size,"checksum":checksum})).await?;
    let mut input = std::fs::File::open(&path)?;
    let mut data = vec![0; CHUNK_SIZE];
    let mut offset = 0u64;
    while offset < size {
        shared.lock().await.peer(peer_id)?;
        let n = input.read(&mut data)?;
        ensure!(n > 0, "Upload source changed");
        let r=remote_call(&identity,&own,&peer,true,json!({"op":"shared_upload_chunk","id":id,"offset":offset,"data":STANDARD.encode(&data[..n]),"checksum":blake3::hash(&data[..n]).to_hex().to_string()})).await?;
        offset += n as u64;
        ensure!(r["received"] == offset, "Invalid upload acknowledgement");
    }
    let r = remote_call(
        &identity,
        &own,
        &peer,
        false,
        json!({"op":"shared_upload_finish","id":id}),
    )
    .await?;
    shared
        .lock()
        .await
        .event("browse.uploaded", json!({"peer_id":peer_id,"name":name}));
    Ok(r)
}

#[cfg(test)]
mod tests {
    use super::*;
    use narad_core::{identity::Identity, model::TrustRecord};
    #[test]
    fn older_folder_preferences_require_explicit_device_selection() {
        let preferences:crate::preferences::Preferences=serde_json::from_value(json!({"shares":[{"id":"old","label":"Old folder","path":"/fixture","documents":false,"upload":true}]})).unwrap();
        assert!(preferences.shares[0].devices.is_empty());
        assert!(preferences.default_share_devices.is_empty());
    }
    fn setup() -> (tempfile::TempDir, Arc<Mutex<State>>, Peer, PathBuf) {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("selected");
        std::fs::create_dir(&folder).unwrap();
        let mut s = State::load(
            temp.path().join("state"),
            "Host".into(),
            "127.0.0.1".into(),
            46000,
        )
        .unwrap();
        let peer = Identity::generate()
            .unwrap()
            .peer("Peer".into(), "127.0.0.1".into(), 46002);
        s.trust.peers.insert(
            peer.device_id.clone(),
            TrustRecord {
                peer: peer.clone(),
                paired_at: now(),
            },
        );
        for cap in ["file.browse", "file.upload"] {
            s.trust.permissions.insert(
                narad_core::policy::permission_key(&peer.device_id, cap),
                true,
            );
        }
        (temp, Arc::new(Mutex::new(s)), peer, folder)
    }
    async fn share(s: Arc<Mutex<State>>, folder: &Path, upload: bool) -> String {
        let peer = s.lock().await.trust.peers.keys().next().unwrap().clone();
        local(
            s,
            &json!({"op":"share_add","path":folder,"label":"Selected","upload":upload,"peer_id":peer}),
        )
        .await
        .unwrap()["id"]
            .as_str()
            .unwrap()
            .into()
    }
    #[tokio::test]
    async fn folder_selection_is_device_scoped_and_revokes_direct_reads() {
        let (_temp, s, peer, folder) = setup();
        std::fs::write(folder.join("private.txt"), b"selected peer only").unwrap();
        let other = Identity::generate()
            .unwrap()
            .peer("Other".into(), "127.0.0.1".into(), 46004);
        {
            let mut state = s.lock().await;
            state.trust.peers.insert(
                other.device_id.clone(),
                TrustRecord {
                    peer: other.clone(),
                    paired_at: now(),
                },
            );
            for cap in ["file.browse", "file.upload"] {
                state.trust.permissions.insert(
                    narad_core::policy::permission_key(&other.device_id, cap),
                    true,
                );
            }
        }
        let id = share(s.clone(), &folder, true).await;
        // Select a deterministic peer rather than relying on map ordering in the helper.
        local(
            s.clone(),
            &json!({"op":"share_access","id":id,"peer_id":other.device_id,"allow":false}),
        )
        .await
        .unwrap();
        local(
            s.clone(),
            &json!({"op":"share_access","id":id,"peer_id":peer.device_id,"allow":true}),
        )
        .await
        .unwrap();
        let path = format!("@{id}/private.txt");
        assert!(read(s.clone(), &peer, &json!({"path":path}), false)
            .await
            .is_ok());
        assert!(read(s.clone(), &other, &json!({"path":path}), false)
            .await
            .is_err());
        assert!(browse(s.clone(), &other, &json!({"path":""}), false)
            .await
            .unwrap()["entries"]
            .as_array()
            .unwrap()
            .is_empty());
        assert!(upload(s.clone(),&other,&json!({"op":"shared_upload_begin","id":uuid::Uuid::new_v4(),"path":format!("@{id}"),"name":"test.txt","size":0,"checksum":blake3::hash(b"").to_hex().to_string()}),false).await.is_err());
        local(
            s.clone(),
            &json!({"op":"share_access","id":id,"peer_id":peer.device_id,"allow":false}),
        )
        .await
        .unwrap();
        assert!(read(s.clone(), &peer, &json!({"path":path}), false)
            .await
            .is_err());
        let state = s.lock().await;
        let saved: crate::preferences::Preferences = narad_core::storage::load_encrypted(
            &state.dir.join("preferences.enc"),
            &state.identity.storage_key(),
        )
        .unwrap();
        assert!(saved.shares[0].devices.is_empty());
    }
    #[tokio::test]
    async fn mounts_are_persistent_scoped_and_exclude_private_state() {
        let (_temp, s, peer, folder) = setup();
        std::fs::write(folder.join("fixture.txt"), b"fixture").unwrap();
        let id = share(s.clone(), &folder, false).await;
        let root = format!("@{id}");
        let listing = browse(s.clone(), &peer, &json!({"path":""}), false)
            .await
            .unwrap();
        assert!(listing["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["path"] == root));
        let data = read(
            s.clone(),
            &peer,
            &json!({"path":format!("{root}/fixture.txt")}),
            false,
        )
        .await
        .unwrap();
        assert_eq!(
            STANDARD.decode(data["data"].as_str().unwrap()).unwrap(),
            b"fixture"
        );
        assert!(read(
            s.clone(),
            &peer,
            &json!({"path":format!("{root}/../state/identity.enc")}),
            false
        )
        .await
        .is_err());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(s.lock().await.dir.clone(), folder.join("escape")).unwrap();
            assert!(read(
                s.clone(),
                &peer,
                &json!({"path":format!("{root}/escape/api-token")}),
                false
            )
            .await
            .is_err());
        }
        let state = s.lock().await;
        let preferences: crate::preferences::Preferences = narad_core::storage::load_encrypted(
            &state.dir.join("preferences.enc"),
            &state.identity.storage_key(),
        )
        .unwrap();
        assert_eq!(preferences.shares[0].id, id);
    }
    #[tokio::test]
    async fn uploads_require_separate_grant_and_folder_switch_and_never_replace() {
        let (_temp, s, peer, folder) = setup();
        let id = share(s.clone(), &folder, false).await;
        let root = format!("@{id}");
        let body = b"generated upload";
        let hash = blake3::hash(body).to_hex().to_string();
        let transfer = uuid::Uuid::new_v4().to_string();
        let begin = json!({"op":"shared_upload_begin","id":transfer,"path":root,"name":"fixture.txt","size":body.len(),"checksum":hash});
        assert!(upload(s.clone(), &peer, &begin, false).await.is_err());
        local(
            s.clone(),
            &json!({"op":"share_uploads","id":id,"enabled":true}),
        )
        .await
        .unwrap();
        s.lock().await.trust.permissions.insert(
            narad_core::policy::permission_key(&peer.device_id, "file.upload"),
            false,
        );
        assert!(upload(s.clone(), &peer, &begin, false).await.is_err());
        s.lock().await.trust.permissions.insert(
            narad_core::policy::permission_key(&peer.device_id, "file.upload"),
            true,
        );
        upload(s.clone(), &peer, &begin, false).await.unwrap();
        let chunk = json!({"op":"shared_upload_chunk","id":transfer,"offset":0,"data":STANDARD.encode(body),"checksum":hash});
        upload(s.clone(), &peer, &chunk, true).await.unwrap();
        upload(s.clone(), &peer, &chunk, true).await.unwrap();
        upload(
            s.clone(),
            &peer,
            &json!({"op":"shared_upload_finish","id":transfer}),
            false,
        )
        .await
        .unwrap();
        assert_eq!(std::fs::read(folder.join("fixture.txt")).unwrap(), body);
        let second = uuid::Uuid::new_v4().to_string();
        let mut request = begin.clone();
        request["id"] = json!(second);
        upload(s.clone(), &peer, &request, false).await.unwrap();
        let mut chunk = chunk;
        chunk["id"] = json!(second);
        upload(s.clone(), &peer, &chunk, true).await.unwrap();
        assert!(upload(
            s.clone(),
            &peer,
            &json!({"op":"shared_upload_finish","id":second}),
            false
        )
        .await
        .is_err());
        assert_eq!(std::fs::read(folder.join("fixture.txt")).unwrap(), body);
    }
    #[tokio::test]
    async fn native_document_jobs_recheck_folder_and_peer_permission() {
        let (_temp, s, peer, _folder) = setup();
        s.lock().await.own.platform = "android".into();
        let id=local(s.clone(),&json!({"op":"share_add","path":"content://fixture/tree/selected","label":"Documents","documents":true,"peer_id":peer.device_id})).await.unwrap()["id"].as_str().unwrap().to_string();
        let target = format!("@{id}");
        let cloned = s.clone();
        let p = peer.clone();
        let reader =
            tokio::spawn(async move { browse(cloned, &p, &json!({"path":target}), false).await });
        let jobs = local(s.clone(), &json!({"op":"storage_jobs"}))
            .await
            .unwrap();
        let job = &jobs["jobs"][0];
        assert_eq!(job["root"], "content://fixture/tree/selected");
        local(
            s.clone(),
            &json!({"op":"share_access","id":id,"peer_id":peer.device_id,"allow":false}),
        )
        .await
        .unwrap();
        assert!(local(
            s.clone(),
            &json!({"op":"storage_result","id":job["id"],"result":{"ok":true,"entries":[]}})
        )
        .await
        .is_err());
        assert!(reader.await.unwrap().is_err());
    }
}
