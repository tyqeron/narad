//! Process-owned backend host. Android owns encrypted identity storage and calls JNI.
use anyhow::{ensure, Context, Result};
use narad::DaemonOptions;
use std::{
    sync::{mpsc, Arc, Mutex},
    thread::JoinHandle,
    time::Duration,
};
use tokio::sync::oneshot;

#[cfg(target_os = "android")]
mod jni_bridge;

struct Running {
    shutdown: oneshot::Sender<()>,
    thread: JoinHandle<()>,
}
#[derive(Default)]
pub struct BackendHost {
    running: Option<Running>,
    error: Arc<Mutex<Option<String>>>,
}
impl BackendHost {
    pub fn is_running(&self) -> bool {
        self.running
            .as_ref()
            .is_some_and(|r| !r.thread.is_finished())
    }
    pub fn error(&self) -> Option<String> {
        self.error.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
    pub fn start(&mut self, options: DaemonOptions) -> Result<()> {
        ensure!(!self.is_running(), "backend already running");
        self.stop()?;
        *self.error.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let (shutdown, stop) = oneshot::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        let failure_tx = ready_tx.clone();
        let error = self.error.clone();
        let thread = std::thread::Builder::new()
            .name("narad-backend".into())
            .spawn(move || {
                let result = (|| -> Result<()> {
                    let runtime = tokio::runtime::Builder::new_multi_thread()
                        .worker_threads(2)
                        .enable_all()
                        .build()?;
                    runtime.block_on(narad::serve(
                        options,
                        async {
                            let _ = stop.await;
                        },
                        Some(ready_tx),
                    ))
                })();
                if let Err(e) = result {
                    let message = e.to_string();
                    *error.lock().unwrap_or_else(|e| e.into_inner()) = Some(message.clone());
                    let _ = failure_tx.send(Err(message));
                }
            })?;
        self.running = Some(Running { shutdown, thread });
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(())) => Ok(()),
            Ok(Err(error)) => {
                self.stop()?;
                anyhow::bail!("{error}")
            }
            Err(error) => {
                self.stop()?;
                Err(error).context("backend startup timed out")
            }
        }
    }
    pub fn stop(&mut self) -> Result<()> {
        if let Some(running) = self.running.take() {
            let _ = running.shutdown.send(());
            running
                .thread
                .join()
                .map_err(|_| anyhow::anyhow!("backend thread failed"))?;
        }
        Ok(())
    }
}
impl Drop for BackendHost {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use narad_core::identity::Identity;
    use serde_json::{json, Value};
    use std::{
        io::{BufRead, BufReader, Write},
        net::{TcpListener, TcpStream},
    };
    fn ports() -> (u16, u16) {
        loop {
            let first = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = first.local_addr().unwrap().port();
            if port == 65535 {
                continue;
            }
            if let Ok(_next) = TcpListener::bind(("127.0.0.1", port + 1)) {
                let api = TcpListener::bind("127.0.0.1:0")
                    .unwrap()
                    .local_addr()
                    .unwrap()
                    .port();
                if api != port && api != port + 1 {
                    return (port, api);
                }
            }
        }
    }
    fn status(dir: &std::path::Path, port: u16) -> Value {
        let mut socket = TcpStream::connect(("127.0.0.1", port)).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        writeln!(socket,"{}",json!({"token":std::fs::read_to_string(dir.join("api-token")).unwrap(),"command":{"op":"status"}})).unwrap();
        let mut response = String::new();
        BufReader::new(socket).read_line(&mut response).unwrap();
        serde_json::from_str(&response).unwrap()
    }
    #[test]
    fn embedded_runtime_restarts_with_memory_identity_and_releases_ports() {
        let dir = tempfile::tempdir().unwrap();
        let identity = Identity::generate().unwrap();
        let (port, api) = ports();
        let options = || DaemonOptions {
            state_dir: dir.path().to_path_buf(),
            api_port: api,
            name: "Android test".into(),
            port,
            address: Some("127.0.0.1".into()),
            no_discovery: true,
            identity: Some(identity.clone()),
        };
        let mut host = BackendHost::default();
        host.start(options()).unwrap();
        assert!(host.is_running());
        assert!(host.start(options()).is_err());
        let first = status(dir.path(), api);
        assert_eq!(first["ok"], true);
        assert!(!dir.path().join("identity.json").exists());
        host.stop().unwrap();
        assert!(!host.is_running());
        host.start(options()).unwrap();
        assert_eq!(
            first["device"]["device_id"],
            status(dir.path(), api)["device"]["device_id"]
        );
        host.stop().unwrap();
        TcpListener::bind(("127.0.0.1", port)).unwrap();
        TcpListener::bind(("127.0.0.1", api)).unwrap();
    }
}
