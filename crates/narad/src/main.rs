mod discovery;
mod handler;
mod state;
mod transport;

use anyhow::{ensure, Context, Result};
use clap::{Parser, Subcommand};
use narad_core::{identity::SignedFrame, model::now};
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

#[derive(Parser)]
#[command(version, about = "Narad: secure local-first device collaboration")]
struct Args {
    #[arg(long, default_value = ".narad", global = true)]
    state: PathBuf,
    #[arg(long, default_value_t = 45700, global = true)]
    api_port: u16,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Run a device daemon. The next port is reserved for the file plane.
    Serve {
        #[arg(long, default_value = "Narad device")]
        name: String,
        #[arg(long, default_value_t = 45678)]
        port: u16,
        #[arg(long)]
        address: Option<String>,
        #[arg(long)]
        no_discovery: bool,
    },
    /// Send a local API command as JSON. See docs/PROTOCOL.md.
    Call {
        json: String,
    },
    Status,
    Invite,
    Pair {
        invitation: PathBuf,
    },
    ApprovePair {
        id: String,
        code: String,
    },
    ConfirmPair {
        id: String,
        code: String,
    },
    Permission {
        peer_id: String,
        capability: String,
        #[arg(long)]
        allow: bool,
    },
    Unpair {
        peer_id: String,
    },
    Send {
        peer_id: String,
        path: PathBuf,
        #[arg(long)]
        id: Option<String>,
    },
    AcceptFile {
        id: String,
    },
    ResumeFile {
        id: String,
    },
    CancelFile {
        id: String,
    },
    Clipboard {
        peer_id: String,
        text: String,
    },
    AcceptClipboard {
        id: String,
    },
}
#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}
async fn run() -> Result<()> {
    let args = Args::parse();
    let value = match args.command {
        Command::Serve {
            name,
            port,
            address,
            no_discovery,
        } => return serve(args.state, args.api_port, name, port, address, no_discovery).await,
        Command::Call { json } => serde_json::from_str(&json)?,
        Command::Status => json!({"op":"status"}),
        Command::Invite => json!({"op":"invite"}),
        Command::Pair { invitation } => {
            let v: Value = serde_json::from_slice(&std::fs::read(invitation)?)?;
            json!({"op":"pair","invitation":v.get("invitation").unwrap_or(&v)})
        }
        Command::ApprovePair { id, code } => json!({"op":"pair_approve","id":id,"code":code}),
        Command::ConfirmPair { id, code } => json!({"op":"pair_confirm","id":id,"code":code}),
        Command::Permission {
            peer_id,
            capability,
            allow,
        } => json!({"op":"permission","peer_id":peer_id,"capability":capability,"allow":allow}),
        Command::Unpair { peer_id } => json!({"op":"unpair","peer_id":peer_id}),
        Command::Send { peer_id, path, id } => {
            json!({"op":"send_file","peer_id":peer_id,"path":path,"id":id})
        }
        Command::AcceptFile { id } => json!({"op":"file_accept","id":id}),
        Command::ResumeFile { id } => json!({"op":"file_resume","id":id}),
        Command::CancelFile { id } => json!({"op":"file_cancel","id":id}),
        Command::Clipboard { peer_id, text } => {
            json!({"op":"send_clipboard","peer_id":peer_id,"text":text})
        }
        Command::AcceptClipboard { id } => json!({"op":"clipboard_accept","id":id}),
    };
    let token = std::fs::read_to_string(args.state.join("api-token"))
        .context("start the daemon first, using the same --state directory")?;
    let result = tokio::time::timeout(Duration::from_secs(600), async {
        let mut stream = TcpStream::connect(("127.0.0.1", args.api_port))
            .await
            .context("local daemon unavailable")?;
        write_frame(&mut stream, &json!({"token":token,"command":value})).await?;
        read_frame::<_, Value>(&mut stream).await
    })
    .await
    .context("local command timed out")??;
    ensure!(
        result["ok"] != false,
        "{}",
        result["error"].as_str().unwrap_or("command failed")
    );
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}
fn local_address() -> String {
    let address = (|| -> Result<String> {
        let socket = std::net::UdpSocket::bind("0.0.0.0:0")?;
        socket.connect("192.0.2.1:9")?;
        Ok(socket.local_addr()?.ip().to_string())
    })();
    address.unwrap_or_else(|_| "127.0.0.1".into())
}
async fn serve(
    dir: PathBuf,
    api_port: u16,
    name: String,
    port: u16,
    address: Option<String>,
    no_discovery: bool,
) -> Result<()> {
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
    let state = State::load(dir, name, address.unwrap_or_else(local_address), port)?;
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
    let permits = Arc::new(Semaphore::new(32));
    let local_permits = Arc::new(Semaphore::new(8));
    let mut workers = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            _=tokio::signal::ctrl_c()=>break,
            Some(result)=workers.join_next(),if !workers.is_empty()=>{if let Err(e)=result {eprintln!("connection task failed: {e}");}},
            accepted=control.accept()=>{let (socket,_)=accepted?;spawn_remote(&mut workers,socket,tls.clone(),shared.clone(),permits.clone(),false);},
            accepted=file.accept()=>{let (socket,_)=accepted?;spawn_remote(&mut workers,socket,tls.clone(),shared.clone(),permits.clone(),true);},
            accepted=local.accept()=>{
                let (mut socket,_)=accepted?;let Ok(permit)=local_permits.clone().try_acquire_owned() else {continue;};let shared=shared.clone();let discovered=discovered.clone();
                workers.spawn(async move {let _permit=permit;
                    let result=tokio::time::timeout(Duration::from_secs(600),async {
                        let request:Value=tokio::time::timeout(Duration::from_secs(10),read_frame(&mut socket)).await??;
                        {let s=shared.lock().await;let token=request["token"].as_str().unwrap_or("");ensure!(token.len()==s.token.len() && token.bytes().zip(s.token.bytes()).fold(0u8,|a,(b,c)|a|(b^c))==0,"local API authentication failed");}
                        let mut result=handler::local(shared.clone(),request["command"].clone()).await?;
                        if request["command"]["op"]=="status" {let map=discovered.lock().unwrap();let peers=map.values().filter(|(_,seen)|seen.elapsed()<Duration::from_secs(120)).map(|(p,_)|p).take(32).collect::<Vec<_>>();result["discovered"]=json!(peers);}
                        Ok::<_,anyhow::Error>(result)
                    }).await;
                    let result=match result {Ok(Ok(v))=>v,Ok(Err(e))=>json!({"ok":false,"error":e.to_string()}),Err(_)=>json!({"ok":false,"error":"command timed out"})};let _=write_frame(&mut socket,&result).await;
                });
            }
        }
    }
    if let Some(d) = discovery {
        let _ = d.shutdown();
    }
    workers.abort_all();
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
    workers.spawn(async move {
        let _permit = permit;
        let result = tokio::time::timeout(Duration::from_secs(20), async {
            let mut stream = tls.accept(socket).await?;
            let frame: SignedFrame = read_frame(&mut stream).await?;
            let response = {
                let mut s = shared.lock().await;
                let result = (|| {
                    frame.verify(&mut s.replay)?;
                    handler::remote(&mut s, &frame.sender, &frame.payload, file_plane)
                })();
                let value = match result {
                    Ok(v) => v,
                    Err(e) => {
                        s.event("request.rejected", json!({"error":e.to_string()}));
                        json!({"ok":false,"error":e.to_string()})
                    }
                };
                s.identity
                    .sign(&s.own, json!({"reply_to":frame.request_id,"result":value}))?
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
