mod clipboard;
mod controls;
mod discovery;
mod handler;
mod input;
mod phone;
mod preferences;
mod sharing;
mod state;
mod telemetry;
pub mod transport;

use anyhow::{ensure, Context, Result};
use narad_core::{
    identity::{Identity, SignedFrame},
    model::now,
};
use serde::Deserialize;
use serde_json::{json, Value};
use state::State;
use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::{Arc, Mutex as StdMutex},
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{Mutex, Semaphore},
};
use transport::{read_frame, write_frame};

#[derive(Deserialize)]
pub struct DaemonOptions {
    pub state_dir: PathBuf,
    pub api_port: u16,
    pub name: String,
    pub port: u16,
    pub address: Option<String>,
    #[serde(default)]
    pub no_discovery: bool,
    pub identity: Option<Identity>,
}

fn local_address() -> String {
    let address = (|| -> Result<String> {
        let socket = std::net::UdpSocket::bind("0.0.0.0:0")?;
        socket.connect("192.0.2.1:9")?;
        Ok(socket.local_addr()?.ip().to_string())
    })();
    address.unwrap_or_else(|_| "127.0.0.1".into())
}
/// Run the same authenticated backend in a CLI or an embedded mobile runtime.
pub async fn serve(
    options: DaemonOptions,
    shutdown: impl std::future::Future<Output = ()>,
    ready: Option<std::sync::mpsc::Sender<std::result::Result<(), String>>>,
) -> Result<()> {
    let DaemonOptions {
        state_dir: dir,
        api_port,
        name,
        port,
        address,
        no_discovery,
        identity,
    } = options;
    ensure!(
        port > 0 && port < 65535 && api_port != port && api_port != port + 1 && api_port > 0,
        "ports must be distinct and nonzero"
    );
    let dir = if dir.is_absolute() {
        dir
    } else {
        std::env::current_dir()?.join(dir)
    };
    narad_core::storage::private_dir(&dir)?;
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let _lock = options.open(dir.join("daemon.lock"))?;
    fs2::FileExt::try_lock_exclusive(&_lock)
        .context("another daemon already owns this state directory")?;
    let state = State::load_with_identity(
        dir,
        name,
        address.unwrap_or_else(local_address),
        port,
        identity,
    )?;
    let tls = transport::acceptor(&state.identity)?;
    let control = TcpListener::bind(("0.0.0.0", port)).await?;
    let file = TcpListener::bind(("0.0.0.0", port + 1)).await?;
    let local = TcpListener::bind(("127.0.0.1", api_port)).await?;
    let discovered: discovery::Discovered = Arc::new(StdMutex::new(BTreeMap::new()));
    let discovery = if no_discovery {
        None
    } else {
        match discovery::start(&state.own, discovered.clone()) {
            Ok(d) => Some(d),
            Err(e) => {
                eprintln!("Discovery unavailable: {e}. Use an invitation for manual pairing.");
                None
            }
        }
    };
    println!(
        "Narad {} | control TLS :{port} | files TLS :{} | local API 127.0.0.1:{api_port}",
        state.own.device_name,
        port + 1
    );
    println!(
        "Device: {}\nState: {}",
        state.own.device_id,
        state.dir.display()
    );
    let shared = Arc::new(Mutex::new(state));
    let control_permits = Arc::new(Semaphore::new(16));
    let file_permits = Arc::new(Semaphore::new(16));
    let local_permits = Arc::new(Semaphore::new(8));
    let mut workers = tokio::task::JoinSet::new();
    let pairing_state = shared.clone();
    workers.spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(2)).await;
            handler::refresh_nearby_pairings(pairing_state.clone()).await;
        }
    });
    let presence_state = shared.clone();
    let presence_discovery = discovered.clone();
    workers.spawn(async move {
        loop {
            let candidates = presence_discovery
                .lock()
                .unwrap()
                .values()
                .map(|(p, _)| p.clone())
                .collect::<Vec<_>>();
            let (identity, own, peers) = {
                let mut state = presence_state.lock().await;
                for candidate in candidates {
                    if let Some(record) = state.trust.peers.get_mut(&candidate.device_id) {
                        if record.peer.public_key == candidate.public_key
                            && record.peer.certificate_hash == candidate.certificate_hash
                        {
                            record.peer.address = candidate.address;
                            record.peer.port = candidate.port;
                        }
                    }
                }
                (
                    state.identity.clone(),
                    state.own.clone(),
                    state
                        .trust
                        .peers
                        .values()
                        .map(|r| r.peer.clone())
                        .collect::<Vec<_>>(),
                )
            };
            let mut checks = tokio::task::JoinSet::new();
            for peer in peers {
                let state = presence_state.clone();
                let identity = identity.clone();
                let own = own.clone();
                checks.spawn(async move {
                    let online = matches!(
                        tokio::time::timeout(
                            Duration::from_secs(3),
                            transport::remote_call(
                                &identity,
                                &own,
                                &peer,
                                false,
                                json!({"op":"ping"})
                            )
                        )
                        .await,
                        Ok(Ok(_))
                    );
                    let mut state = state.lock().await;
                    if state.trust.peers.get(&peer.device_id).is_some_and(|r| {
                        r.peer.public_key == peer.public_key
                            && r.peer.certificate_hash == peer.certificate_hash
                    }) {
                        state.note_presence(&peer.device_id, online);
                    }
                });
            }
            while checks.join_next().await.is_some() {}
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    });
    if let Some(ready) = ready {
        let _ = ready.send(Ok(()));
    }
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            _=&mut shutdown=>break,
            Some(result)=workers.join_next(),if !workers.is_empty()=>{if let Err(e)=result {eprintln!("connection task failed: {e}");}},
            accepted=control.accept()=>{let (socket,_)=accepted?;spawn_remote(&mut workers,socket,tls.clone(),shared.clone(),control_permits.clone(),false);},
            accepted=file.accept()=>{let (socket,_)=accepted?;spawn_remote(&mut workers,socket,tls.clone(),shared.clone(),file_permits.clone(),true);},
            accepted=local.accept()=>{
                let (mut socket,_)=accepted?;let Ok(permit)=local_permits.clone().try_acquire_owned() else {continue;};let shared=shared.clone();let discovered=discovered.clone();let discovery=discovery.clone();
                workers.spawn(async move {let _permit=permit;
                    let result=tokio::time::timeout(Duration::from_secs(600),async {
                        let request:Value=tokio::time::timeout(Duration::from_secs(10),transport::read_frame_limit(&mut socket,transport::LOCAL_MAX_FRAME)).await??;
                        {let s=shared.lock().await;let token=request["token"].as_str().unwrap_or("");ensure!(token.len()==s.token.len() && token.bytes().zip(s.token.bytes()).fold(0u8,|a,(b,c)|a|(b^c))==0,"local API authentication failed");}
                        let candidates=discovered.lock().unwrap().values().map(|(p,_)|p.clone()).collect::<Vec<_>>();
                        {let mut s=shared.lock().await;for candidate in candidates {if let Some(record)=s.trust.peers.get_mut(&candidate.device_id){if record.peer.public_key==candidate.public_key && record.peer.certificate_hash==candidate.certificate_hash {record.peer.address=candidate.address;record.peer.port=candidate.port;}}}}
                        let before=shared.lock().await.own.clone();
                        let mut result=handler::local(shared.clone(),request["command"].clone()).await?;
                        let own=shared.lock().await.own.clone();
                        if before!=own {if let Some(d)=&discovery {let _=discovery::advertise(d,&own);}}
                        if request["command"]["op"]=="status" {let map=discovered.lock().unwrap();let peers=map.values().map(|(p,_)|p).take(32).collect::<Vec<_>>();result["discovered"]=json!(peers);}
                        Ok::<_,anyhow::Error>(result)
                    }).await;
                    let result=match result {Ok(Ok(v))=>v,Ok(Err(e))=>json!({"ok":false,"error":e.to_string()}),Err(_)=>json!({"ok":false,"error":"command timed out"})};let _=transport::write_frame_limit(&mut socket,&result,transport::LOCAL_MAX_FRAME).await;
                });
            }
        }
    }
    if let Some(d) = discovery {
        let own = shared.lock().await.own.clone();
        let _ = d.unregister(&format!("{}.{}", &own.device_id[..16], discovery::SERVICE));
        let _ = d.shutdown();
    }
    workers.abort_all();
    while workers.join_next().await.is_some() {}
    let mut s = shared.lock().await;
    for session in s.sessions.values_mut() {
        session.close();
    }
    s.event("daemon.stopped", json!({"timestamp":now()}));
    Ok(())
}
fn spawn_remote(
    workers: &mut tokio::task::JoinSet<()>,
    socket: TcpStream,
    tls: tokio_rustls::TlsAcceptor,
    shared: Arc<Mutex<State>>,
    permits: Arc<Semaphore>,
    file_plane: bool,
) {
    let Ok(permit) = permits.try_acquire_owned() else {
        return;
    };
    let observed_ip = socket.peer_addr().map(|a| a.ip().to_string());
    workers.spawn(async move {
        let _permit = permit;
        let result = tokio::time::timeout(Duration::from_secs(20), async {
            let mut stream = tls.accept(socket).await?;
            let frame: SignedFrame = read_frame(&mut stream).await?;
            let mut sender = frame.sender.clone();
            let verification = { frame.verify(&mut shared.lock().await.replay) };
            if let Ok(ip) = &observed_ip {
                sender.address = ip.clone();
            }
            let result = match verification {
                Ok(()) => {
                    controls::remote(shared.clone(), &sender, &frame.payload, file_plane).await
                }
                Err(error) => Err(error),
            };
            let response = {
                let mut state = shared.lock().await;
                let value = match result {
                    Ok(value) => value,
                    Err(error) => {
                        state.event("request.rejected", json!({"error":error.to_string()}));
                        json!({"ok":false,"error":error.to_string()})
                    }
                };
                state.identity.sign(
                    &state.own,
                    json!({"reply_to":frame.request_id,"result":value}),
                )?
            };
            write_frame(&mut stream, &response).await?;
            Ok::<_, anyhow::Error>(())
        })
        .await;
        if let Ok(Err(e)) = result {
            eprintln!("connection rejected: {e}");
        }
    });
}

#[cfg(windows)]
mod windows;
