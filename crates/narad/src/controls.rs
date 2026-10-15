//! Permissioned shared-folder, command and operating-system controls.
use crate::{
    handler,
    state::{PlatformAction, State},
};
use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use narad_core::model::{now, Peer};
use serde_json::{json, Value};
use std::{
    path::{Component, Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{io::AsyncReadExt, sync::Mutex};

pub fn shared_path(state: &State, relative: &str) -> Result<PathBuf> {
    ensure!(
        relative.len() <= 1024 && !relative.contains('\\'),
        "invalid shared path"
    );
    ensure!(
        Path::new(relative)
            .components()
            .all(|c| matches!(c, Component::Normal(_))),
        "path must stay in the shared folder"
    );
    #[cfg(windows)]
    for part in relative.split('/').filter(|p| !p.is_empty()) {
        narad_core::transfer::validate_windows_name(part)?;
    }
    let root = state.dir.join("shared");
    narad_core::storage::private_dir(&root)?;
    ensure!(
        !root.symlink_metadata()?.file_type().is_symlink(),
        "shared root cannot be a symbolic link"
    );
    let root = root.canonicalize()?;
    let path = root.join(relative).canonicalize()?;
    ensure!(path.starts_with(&root), "path escapes the shared folder");
    Ok(path)
}

pub async fn remote(
    shared: Arc<Mutex<State>>,
    peer: &Peer,
    payload: &Value,
    file_plane: bool,
) -> Result<Value> {
    let op = handler::string(payload, "op")?;
    if !matches!(
        op,
        "browse"
            | "shared_read"
            | "command_list"
            | "command"
            | "device_action"
            | "device_action_status"
    ) {
        return handler::remote(&mut *shared.lock().await, peer, payload, file_plane);
    }
    ensure!(!file_plane, "command sent on wrong transport plane");
    let kind = payload["kind"].as_str().unwrap_or("");
    let capability = match op {
        "browse" | "shared_read" => "file.browse",
        "command" | "command_list" => "command.run",
        "device_action" => match kind {
            "lock" => "device.lock",
            "unlock" => "device.unlock",
            _ => anyhow::bail!("unsupported device action"),
        },
        _ => "",
    };
    {
        let mut state = shared.lock().await;
        state.expire();
        state.trust.authenticate(peer)?;
        if !capability.is_empty() {
            state.trust.authorize(peer, capability, true)?;
        }
        state.note_presence(&peer.device_id, true);
        if op == "command_list" {
            return Ok(
                json!({"ok":true,"commands":state.commands.values().map(|c|json!({"id":c.id,"label":c.label})).collect::<Vec<_>>()}),
            );
        }
        if op == "browse" {
            let relative = payload["path"].as_str().unwrap_or("");
            let path = shared_path(&state, relative)?;
            ensure!(path.is_dir(), "not a directory");
            let mut entries = vec![];
            let mut encoded_size = 0usize;
            let mut truncated = false;
            for entry in std::fs::read_dir(&path)? {
                if entries.len() >= 256 {
                    truncated = true;
                    break;
                }
                let entry = entry?;
                let name = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| anyhow::anyhow!("file name is not UTF-8"))?;
                let metadata = entry.path().symlink_metadata()?;
                if metadata.file_type().is_symlink() {
                    continue;
                }
                let entry = json!({"name":name,"path":if relative.is_empty(){name.clone()} else {format!("{relative}/{name}")},"directory":metadata.is_dir(),"size":metadata.len()});
                encoded_size += serde_json::to_vec(&entry)?.len();
                if encoded_size > 60 * 1024 {
                    truncated = true;
                    break;
                }
                entries.push(entry);
            }
            entries.sort_by(|a, b| {
                b["directory"]
                    .as_bool()
                    .cmp(&a["directory"].as_bool())
                    .then_with(|| a["name"].as_str().cmp(&b["name"].as_str()))
            });
            state.event("browse.opened", json!({"peer_id":peer.device_id}));
            return Ok(json!({"ok":true,"path":relative,"entries":entries,"truncated":truncated}));
        }
        if op == "shared_read" {
            use std::io::{Read, Seek, SeekFrom};
            let path = shared_path(&state, handler::string(payload, "path")?)?;
            ensure!(path.is_file(), "not a file");
            let mut file = std::fs::File::open(path)?;
            let size = file.metadata()?.len();
            let offset = payload["offset"].as_u64().unwrap_or(0);
            ensure!(offset <= size, "invalid file offset");
            file.seek(SeekFrom::Start(offset))?;
            let mut chunk = vec![0; 48 * 1024];
            let n = file.read(&mut chunk)?;
            return Ok(
                json!({"ok":true,"data":STANDARD.encode(&chunk[..n]),"size":size,"offset":offset,"next":offset+n as u64}),
            );
        }
        if op == "device_action_status" {
            let action = state
                .platform_actions
                .get(handler::string(payload, "id")?)
                .context("action expired")?;
            ensure!(action.peer_id == peer.device_id, "action owner mismatch");
            return Ok(
                json!({"ok":true,"id":action.id,"status":action.status,"message":action.message}),
            );
        }
        #[cfg(windows)]
        if op == "device_action" {
            let result = crate::windows::device_action(kind)?;
            state.event(
                "device.completed",
                json!({"peer_id":peer.device_id,"kind":kind}),
            );
            return Ok(result);
        }
        if op == "device_action" && cfg!(target_os = "android") {
            ensure!(
                state.platform_actions.len() < 32,
                "too many pending device actions"
            );
            let id = uuid::Uuid::new_v4().to_string();
            state.platform_actions.insert(
                id.clone(),
                PlatformAction {
                    id: id.clone(),
                    peer_id: peer.device_id.clone(),
                    kind: kind.into(),
                    capability: capability.into(),
                    expires_at: now() + 60,
                    status: "pending".into(),
                    message: String::new(),
                },
            );
            state.event(
                "device.requested",
                json!({"peer_id":peer.device_id,"kind":kind}),
            );
            return Ok(json!({"ok":true,"id":id,"status":"pending"}));
        }
    }
    let command = if op == "command" {
        shared
            .lock()
            .await
            .commands
            .get(handler::string(payload, "id")?)
            .context("unknown command preset")?
            .script
            .clone()
    } else {
        ensure!(
            cfg!(target_os = "linux"),
            "device control is not supported on this platform"
        );
        format!("loginctl {kind}-session")
    };
    let result = execute(shared.clone(), peer, capability, &command).await?;
    shared.lock().await.event(
        if op == "command" {
            "command.completed"
        } else {
            "device.completed"
        },
        json!({"peer_id":peer.device_id,"exit_code":result["exit_code"],"kind":kind}),
    );
    Ok(result)
}

async fn read_bounded<R: tokio::io::AsyncRead + Unpin>(mut source: R) -> Result<(Vec<u8>, bool)> {
    let mut output = vec![];
    let mut truncated = false;
    let mut buffer = [0; 4096];
    loop {
        let n = source.read(&mut buffer).await?;
        if n == 0 {
            return Ok((output, truncated));
        }
        let remaining = (8 * 1024usize).saturating_sub(output.len());
        output.extend_from_slice(&buffer[..n.min(remaining)]);
        truncated |= n > remaining;
    }
}
#[cfg(unix)]
struct ProcessGroup(Option<u32>);
#[cfg(unix)]
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        #[cfg(any(target_os = "linux", target_os = "android"))]
        if let Some(pid) = self.0 {
            // SAFETY: the group was created for this command; no caller-supplied PID is accepted.
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
    }
}
async fn execute(
    shared: Arc<Mutex<State>>,
    peer: &Peer,
    capability: &str,
    command: &str,
) -> Result<Value> {
    let directory = {
        let state = shared.lock().await;
        shared_path(&state, "")?
    };
    #[cfg(windows)]
    let mut builder = {
        // Use the system shell, never a cmd.exe found in a writable cwd/PATH.
        let system =
            std::env::var_os("SystemRoot").context("Windows system directory unavailable")?;
        let mut command_builder =
            tokio::process::Command::new(PathBuf::from(system).join("System32/cmd.exe"));
        command_builder.args(["/D", "/S", "/C"]).arg(command);
        command_builder.creation_flags(0x08000000 | 0x00000004); // NO_WINDOW | SUSPENDED
        command_builder
    };
    #[cfg(not(windows))]
    let mut builder = {
        let mut command_builder = tokio::process::Command::new(if cfg!(target_os = "android") {
            "/system/bin/sh"
        } else {
            "/bin/sh"
        });
        command_builder.arg("-c").arg(command);
        command_builder
    };
    builder
        .current_dir(directory)
        .kill_on_drop(true)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        builder.as_std_mut().process_group(0);
    }
    let mut child = builder.spawn().context("could not start command")?;
    #[cfg(unix)]
    let group = ProcessGroup(child.id());
    #[cfg(windows)]
    let group = crate::windows::CommandJob::attach(&child)?;
    let stdout = tokio::spawn(read_bounded(child.stdout.take().unwrap()));
    let stderr = tokio::spawn(read_bounded(child.stderr.take().unwrap()));
    let deadline = tokio::time::sleep(Duration::from_secs(10));
    tokio::pin!(deadline);
    let outcome = loop {
        tokio::select! {
            result=child.wait()=>break result.map_err(anyhow::Error::from),
            _=&mut deadline=>break Err(anyhow::anyhow!("command timed out after 10 seconds")),
            _=tokio::time::sleep(Duration::from_millis(200))=> {
                if shared.lock().await.trust.authorize(peer,capability,true).is_err() {
                    break Err(anyhow::anyhow!("permission revoked during command"));
                }
            }
        }
    };
    // Also close output pipes inherited by background children.
    drop(group);
    if outcome.is_err() {
        let _ = child.kill().await;
    }
    let streams = tokio::time::timeout(Duration::from_secs(2), async {
        Ok::<_, anyhow::Error>((stdout.await??, stderr.await??))
    })
    .await;
    let exit = outcome?;
    let ((out, out_cut), (err, err_cut)) = streams.context("command output did not close")??;
    shared
        .lock()
        .await
        .trust
        .authorize(peer, capability, true)?;
    Ok(
        json!({"ok":true,"exit_code":exit.code(),"stdout":String::from_utf8_lossy(&out),"stderr":String::from_utf8_lossy(&err),"truncated":out_cut||err_cut}),
    )
}

pub fn platform_events(state: &mut State) -> Result<Value> {
    let ids = state
        .clipboard
        .values()
        .filter(|c| c.status == "automatic")
        .map(|c| c.id.clone())
        .collect::<Vec<_>>();
    let mut clipboard = vec![];
    for id in ids {
        let offer = state.clipboard[&id].clone();
        let peer = state.peer(&offer.peer_id)?;
        if state.session(&id, &peer, "clipboard.sync").is_ok() {
            clipboard.push(json!({"id":id,"text":offer.text}));
            state.clipboard.remove(&id);
            state.sessions.get_mut(&id).unwrap().close();
            state.event("clipboard.applied", json!({"peer_id":peer.device_id}));
        }
    }
    let actions = state
        .platform_actions
        .values()
        .filter(|a| a.status == "pending")
        .filter(|a| {
            state
                .trust
                .peers
                .get(&a.peer_id)
                .is_some_and(|r| state.trust.authorize(&r.peer, &a.capability, true).is_ok())
        })
        .cloned()
        .collect::<Vec<_>>();
    for action in &actions {
        state.platform_actions.get_mut(&action.id).unwrap().status = "dispatched".into();
    }
    Ok(json!({"ok":true,"clipboard":clipboard,"actions":actions}))
}

pub async fn download(shared: Arc<Mutex<State>>, payload: &Value) -> Result<Value> {
    use crate::transport::remote_call;
    use narad_core::transfer::{hash_file, Transfer, MAX_FILE_SIZE};
    use std::io::Write;
    let peer_id = handler::string(payload, "peer_id")?;
    let relative = handler::string(payload, "path")?;
    let name = Path::new(relative)
        .file_name()
        .and_then(|n| n.to_str())
        .context("invalid file name")?
        .to_string();
    let id = uuid::Uuid::new_v4().to_string();
    let (identity, own, peer, directory) = {
        let state = shared.lock().await;
        (
            state.identity.clone(),
            state.own.clone(),
            state.peer(peer_id)?,
            state.dir.join("downloads").join(&id),
        )
    };
    let mut transfer = Transfer {
        id: id.clone(),
        peer_id: peer_id.into(),
        file_name: name.clone(),
        file_size: 0,
        received: 0,
        status: "completed".into(),
        checksum: "0".repeat(64),
        updated_at: now(),
    };
    transfer.validate()?;
    narad_core::storage::private_dir(&directory)?;
    let path = directory.join(&name);
    let result = async {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut output = options.open(&path)?;
        let mut offset = 0u64;
        let mut expected = None;
        loop {
            shared.lock().await.peer(peer_id)?;
            let chunk = remote_call(
                &identity,
                &own,
                &peer,
                false,
                json!({"op":"shared_read","path":relative,"offset":offset}),
            )
            .await?;
            let size = chunk["size"].as_u64().context("invalid shared file size")?;
            ensure!(
                size <= MAX_FILE_SIZE && expected.is_none_or(|n| n == size),
                "shared file changed or exceeds 1 GiB"
            );
            expected = Some(size);
            let bytes = STANDARD.decode(handler::string(&chunk, "data")?)?;
            ensure!(
                bytes.len() <= 48 * 1024
                    && chunk["offset"] == offset
                    && offset + bytes.len() as u64 <= size,
                "invalid shared file chunk"
            );
            ensure!(
                !bytes.is_empty() || offset == size,
                "shared file ended early"
            );
            output.write_all(&bytes)?;
            offset += bytes.len() as u64;
            if offset == size {
                break;
            }
        }
        output.sync_all()?;
        transfer.file_size = offset;
        transfer.received = offset;
        transfer.checksum = hash_file(&path)?;
        let mut state = shared.lock().await;
        ensure!(state.transfers.len() < 256, "transfer history full");
        transfer.persist(&state.dir.join("transfers"), &state.identity.storage_key())?;
        state.transfers.insert(id.clone(), transfer);
        state.event(
            "browse.downloaded",
            json!({"peer_id":peer_id,"id":id,"name":name}),
        );
        Ok::<_, anyhow::Error>(json!({"ok":true,"id":id,"name":name,"path":path}))
    }
    .await;
    if result.is_err() {
        let _ = std::fs::remove_dir_all(directory);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use narad_core::{identity::Identity, model::TrustRecord, policy::permission_key};
    #[tokio::test]
    async fn native_actions_recheck_permissions_after_dispatch() {
        let directory = tempfile::tempdir().unwrap();
        let mut state = State::load(
            directory.path().join("state"),
            "Native test".into(),
            "127.0.0.1".into(),
            46000,
        )
        .unwrap();
        let peer = Identity::generate()
            .unwrap()
            .peer("Peer".into(), "127.0.0.1".into(), 46002);
        state.trust.peers.insert(
            peer.device_id.clone(),
            TrustRecord {
                peer: peer.clone(),
                paired_at: now(),
            },
        );
        state
            .trust
            .permissions
            .insert(permission_key(&peer.device_id, "device.lock"), true);
        let id = uuid::Uuid::new_v4().to_string();
        state.platform_actions.insert(
            id.clone(),
            PlatformAction {
                id: id.clone(),
                peer_id: peer.device_id.clone(),
                kind: "lock".into(),
                capability: "device.lock".into(),
                expires_at: now() + 60,
                status: "pending".into(),
                message: String::new(),
            },
        );
        let events = platform_events(&mut state).unwrap();
        assert_eq!(events["actions"].as_array().unwrap().len(), 1);
        let shared = Arc::new(Mutex::new(state));
        handler::local(shared.clone(), json!({"op":"platform_validate","id":id}))
            .await
            .unwrap();
        handler::local(shared.clone(),json!({"op":"permission","peer_id":peer.device_id,"capability":"device.lock","allow":false})).await.unwrap();
        assert!(
            handler::local(shared.clone(), json!({"op":"platform_validate","id":id}))
                .await
                .is_err()
        );
        assert_eq!(shared.lock().await.platform_actions[&id].status, "failed");
    }
    #[tokio::test]
    async fn command_output_is_bounded_while_the_pipe_is_drained() {
        use tokio::io::AsyncWriteExt;
        let (read, mut write) = tokio::io::duplex(1024);
        let writer = tokio::spawn(async move {
            write.write_all(&vec![b'x'; 100_000]).await.unwrap();
        });
        let (output, truncated) = read_bounded(read).await.unwrap();
        writer.await.unwrap();
        assert_eq!(output.len(), 8 * 1024);
        assert!(truncated);
    }
    #[test]
    fn old_encrypted_trust_does_not_silently_grant_automatic_access() {
        let directory = tempfile::tempdir().unwrap();
        let identity = Identity::generate().unwrap();
        let peer =
            Identity::generate()
                .unwrap()
                .peer("Existing peer".into(), "127.0.0.1".into(), 46002);
        let old = json!({"peers":{peer.device_id.clone():{"peer":peer,"paired_at":now()}},"permissions":{permission_key(&peer.device_id,"file.transfer"):true}});
        narad_core::storage::save_encrypted(
            &directory.path().join("trust.enc"),
            &identity.storage_key(),
            &old,
        )
        .unwrap();
        let state = State::load_with_identity(
            directory.path().to_path_buf(),
            "Test".into(),
            "127.0.0.1".into(),
            46000,
            Some(identity),
        )
        .unwrap();
        state.trust.authenticate(&peer).unwrap();
        assert!(!state.automatic(&peer.device_id, "file.transfer"));
    }
}
