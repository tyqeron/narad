use anyhow::{ensure, Context, Result};
use clap::{Parser, Subcommand};
use narad::transport;
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio::net::TcpStream;

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
        } => {
            return narad::serve(
                narad::DaemonOptions {
                    state_dir: args.state,
                    api_port: args.api_port,
                    name,
                    port,
                    address,
                    no_discovery,
                    identity: None,
                },
                async {
                    let _ = tokio::signal::ctrl_c().await;
                },
                None,
            )
            .await
        }
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
        transport::write_frame_limit(
            &mut stream,
            &json!({"token":token,"command":value}),
            transport::LOCAL_MAX_FRAME,
        )
        .await?;
        transport::read_frame_limit::<_, Value>(&mut stream, transport::LOCAL_MAX_FRAME).await
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
