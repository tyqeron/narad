//! On-demand, best-effort device status. No history is retained.
use serde_json::{json, Value};

pub fn battery(phone: Option<&Value>) -> Value {
    if let Some(battery) = phone.and_then(|v| v.get("battery")) {
        return battery.clone();
    }
    #[cfg(target_os = "linux")]
    {
        if let Ok(entries) = std::fs::read_dir("/sys/class/power_supply") {
            for entry in entries.flatten() {
                let path = entry.path();
                let kind = std::fs::read_to_string(path.join("type")).unwrap_or_default();
                if kind.trim() == "Battery" {
                    let level = std::fs::read_to_string(path.join("capacity"))
                        .ok()
                        .and_then(|v| v.trim().parse::<u8>().ok());
                    let status = std::fs::read_to_string(path.join("status"))
                        .unwrap_or_default()
                        .trim()
                        .to_lowercase();
                    return json!({"available":level.is_some(),"percent":level,"charging":status=="charging","status":status});
                }
            }
        }
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
        unsafe {
            let mut status: SYSTEM_POWER_STATUS = std::mem::zeroed();
            if GetSystemPowerStatus(&mut status) != 0 && status.BatteryLifePercent != 255 {
                return json!({"available":true,"percent":status.BatteryLifePercent,"charging":status.ACLineStatus==1});
            }
        }
    }
    json!({"available":false})
}

pub fn network(address: &str, phone: Option<&Value>) -> Value {
    if let Some(network) = phone.and_then(|v| v.get("network")) {
        return network.clone();
    }
    #[cfg(target_os = "linux")]
    {
        let mut interfaces = Vec::new();
        if let Ok(entries) = std::fs::read_dir("/sys/class/net") {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name == "lo" {
                    continue;
                }
                let base = entry.path();
                let state = std::fs::read_to_string(base.join("operstate"))
                    .unwrap_or_default()
                    .trim()
                    .to_owned();
                let kind = if base.join("wireless").exists() {
                    "wifi"
                } else if name.starts_with("wwan") || name.starts_with("wwp") {
                    "cellular"
                } else {
                    "ethernet"
                };
                interfaces.push(json!({"name":name,"type":kind,"state":state}));
            }
        }
        let cellular = interfaces.iter().any(|item| item["type"] == "cellular");
        return json!({"address":address,"interfaces":interfaces,"cellular":{"available":cellular,"connected":interfaces.iter().any(|item| item["type"]=="cellular" && item["state"]=="up")}});
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = phone;
        json!({"address":address,"interfaces":[],"cellular":{"available":false,"connected":false}})
    }
}
