use anyhow::Result;
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use narad_core::model::Peer;
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::Instant,
};

pub const SERVICE: &str = "_narad._tcp.local.";
pub type Discovered = Arc<Mutex<BTreeMap<String, (Peer, Instant)>>>;
pub fn advertise(daemon: &ServiceDaemon, peer: &Peer) -> Result<()> {
    let capabilities = peer.capabilities.join(",");
    let properties = [
        ("id", peer.device_id.as_str()),
        ("name", peer.device_name.as_str()),
        ("platform", peer.platform.as_str()),
        ("version", "1"),
        ("key", peer.public_key.as_str()),
        ("pin", peer.certificate_hash.as_str()),
        ("capabilities", capabilities.as_str()),
    ];
    let info = ServiceInfo::new(
        SERVICE,
        &peer.device_id[..16],
        &format!("{}.local.", &peer.device_id[..16]),
        peer.address.as_str(),
        peer.port,
        &properties[..],
    )?
    .enable_addr_auto();
    daemon.register(info)?;
    Ok(())
}
pub fn start(peer: &Peer, peers: Discovered) -> Result<ServiceDaemon> {
    let daemon = ServiceDaemon::new()?;
    advertise(&daemon, peer)?;
    let events = daemon.browse(SERVICE)?;
    let own = peer.device_id.clone();
    std::thread::spawn(move || {
        while let Ok(event) = events.recv() {
            match event {
                ServiceEvent::ServiceResolved(info) => {
                    let get = |key| {
                        info.get_property_val_str(key)
                            .unwrap_or_default()
                            .to_string()
                    };
                    let id = get("id");
                    if id == own {
                        continue;
                    }
                    let Some(address) = info.get_addresses().iter().find(|a| a.is_ipv4()) else {
                        continue;
                    };
                    let peer = Peer {
                        device_id: id.clone(),
                        device_name: get("name"),
                        platform: get("platform"),
                        protocol_version: get("version").parse().unwrap_or(0),
                        public_key: get("key"),
                        certificate_hash: get("pin"),
                        address: address.to_string(),
                        port: info.get_port(),
                        capabilities: get("capabilities")
                            .split(',')
                            .filter(|c| {
                                [
                                    "file.transfer",
                                    "clipboard.sync",
                                    "audio.output",
                                    "audio.input",
                                    "camera.stream",
                                    "screen.view",
                                    "file.browse",
                                    "command.run",
                                    "device.find",
                                    "device.lock",
                                    "device.unlock",
                                ]
                                .contains(c)
                            })
                            .map(String::from)
                            .collect(),
                    };
                    if peer.validate().is_ok() {
                        let mut map = peers.lock().unwrap();
                        if map.len() < 256 || map.contains_key(&id) {
                            map.insert(id, (peer, Instant::now()));
                        }
                    }
                }
                ServiceEvent::ServiceRemoved(_, fullname) => {
                    peers
                        .lock()
                        .unwrap()
                        .retain(|_, (p, _)| !fullname.starts_with(&p.device_id[..16]));
                }
                _ => {}
            }
        }
    });
    Ok(daemon)
}
