//! Small owned-string C ABI for the iOS host. Keychain storage belongs to Swift.
use anyhow::{ensure, Result};
use narad_android::BackendHost;
use serde_json::{json, Value};
use std::{
    ffi::{c_char, CStr, CString},
    sync::{Mutex, OnceLock},
};
fn host() -> &'static Mutex<BackendHost> {
    static HOST: OnceLock<Mutex<BackendHost>> = OnceLock::new();
    HOST.get_or_init(|| Mutex::new(BackendHost::default()))
}
fn configuration() -> &'static Mutex<Option<(std::path::PathBuf, u16)>> {
    static CONFIG: OnceLock<Mutex<Option<(std::path::PathBuf, u16)>>> = OnceLock::new();
    CONFIG.get_or_init(|| Mutex::new(None))
}
fn bridge(command: &Value) -> Result<Value> {
    use std::io::{BufRead, Read, Write};
    ensure!(
        matches!(
            command["op"].as_str(),
            Some("phone_bridge_ready" | "phone_jobs" | "phone_validate" | "phone_result")
        ),
        "unsupported native bridge command"
    );
    let (dir, port) = configuration()
        .lock()
        .map_err(|_| anyhow::anyhow!("configuration unavailable"))?
        .clone()
        .ok_or_else(|| anyhow::anyhow!("backend stopped"))?;
    let token = std::fs::read_to_string(dir.join("api-token"))?;
    let mut socket = std::net::TcpStream::connect_timeout(
        &std::net::SocketAddr::from(([127, 0, 0, 1], port)),
        std::time::Duration::from_secs(1),
    )?;
    socket.set_read_timeout(Some(std::time::Duration::from_secs(3)))?;
    socket.set_write_timeout(Some(std::time::Duration::from_secs(3)))?;
    writeln!(socket, "{}", json!({"token":token,"command":command}))?;
    let mut line = String::new();
    std::io::BufReader::new(socket.take(524289)).read_line(&mut line)?;
    ensure!(line.len() <= 524288, "bridge response too large");
    let response: Value = serde_json::from_str(&line)?;
    ensure!(
        response["ok"] == true,
        "{}",
        response["error"]
            .as_str()
            .unwrap_or("Bridge request failed")
    );
    Ok(response)
}
fn action(value: Value) -> Result<Value> {
    match value["op"].as_str().unwrap_or("") {
        "identity" => Ok(json!({"ok":true,"identity":narad_core::identity::Identity::generate()?})),
        "start" => {
            let options: narad::DaemonOptions = serde_json::from_value(value["config"].clone())?;
            ensure!(
                options.identity.is_some(),
                "Mobile identity must come from protected platform storage"
            );
            let config = (options.state_dir.clone(), options.api_port);
            host()
                .lock()
                .map_err(|_| anyhow::anyhow!("backend unavailable"))?
                .start(options)?;
            *configuration()
                .lock()
                .map_err(|_| anyhow::anyhow!("configuration unavailable"))? = Some(config);
            Ok(json!({"ok":true}))
        }
        "bridge" => bridge(&value["command"]),
        "stop" => {
            *configuration()
                .lock()
                .map_err(|_| anyhow::anyhow!("configuration unavailable"))? = None;
            host()
                .lock()
                .map_err(|_| anyhow::anyhow!("backend unavailable"))?
                .stop()?;
            Ok(json!({"ok":true}))
        }
        "status" => {
            let host = host()
                .lock()
                .map_err(|_| anyhow::anyhow!("backend unavailable"))?;
            Ok(json!({"ok":true,"running":host.is_running(),"error":host.error()}))
        }
        _ => anyhow::bail!("unsupported mobile operation"),
    }
}
/// # Safety
/// `input` must be null or a readable NUL-terminated UTF-8 string for the call.
/// Free the returned pointer exactly once with `narad_mobile_free`.
#[no_mangle]
pub unsafe extern "C" fn narad_mobile_call(input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> Result<Value> {
        ensure!(!input.is_null(), "missing request");
        let text = unsafe { CStr::from_ptr(input) }.to_str()?;
        ensure!(text.len() <= 65536, "request too large");
        action(serde_json::from_str(text)?)
    });
    let value = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => json!({"ok":false,"error":error.to_string()}),
        Err(_) => json!({"ok":false,"error":"Native backend failed"}),
    };
    CString::new(value.to_string())
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}
/// # Safety
/// Pass only null or an unfreed pointer returned by `narad_mobile_call`.
#[no_mangle]
pub unsafe extern "C" fn narad_mobile_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(unsafe { CString::from_raw(pointer) });
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    unsafe fn invoke(value: Value) -> Value {
        let text = CString::new(value.to_string()).unwrap();
        let p = unsafe { narad_mobile_call(text.as_ptr()) };
        let reply = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
        unsafe { narad_mobile_free(p) };
        serde_json::from_str(&reply).unwrap()
    }
    #[test]
    fn c_abi_returns_owned_errors_and_requires_protected_identity() {
        unsafe {
            let p = narad_mobile_call(std::ptr::null());
            assert!(!p.is_null());
            let result: Value = serde_json::from_str(CStr::from_ptr(p).to_str().unwrap()).unwrap();
            assert_eq!(result["ok"], false);
            narad_mobile_free(p);
            narad_mobile_free(std::ptr::null_mut());
            assert_eq!(invoke(json!({"op":"unknown"}))["ok"], false);
            assert_eq!(
                invoke(json!({"op":"bridge","command":{"op":"sms_send"}}))["ok"],
                false
            );
            let identity = invoke(json!({"op":"identity"}));
            assert_eq!(identity["ok"], true);
            assert!(identity["identity"].is_object());
            let dir = tempfile::tempdir().unwrap();
            let result = invoke(
                json!({"op":"start","config":{"state_dir":dir.path(),"name":"iOS test","api_port":0,"port":0,"no_discovery":true}}),
            );
            assert_eq!(result["ok"], false);
            assert!(!dir.path().join("identity.json").exists());
            assert_eq!(invoke(json!({"op":"status"}))["running"], false);
            let control = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = control.local_addr().unwrap().port();
            let next = std::net::TcpListener::bind(("127.0.0.1", port + 1)).unwrap();
            let api = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let api_port = api.local_addr().unwrap().port();
            drop(control);
            drop(next);
            drop(api);
            let started = invoke(
                json!({"op":"start","config":{"state_dir":dir.path(),"name":"Mobile ABI fixture","api_port":api_port,"port":port,"no_discovery":true,"address":"127.0.0.1","identity":identity["identity"]}}),
            );
            assert_eq!(started["ok"], true, "{}", started["error"]);
            assert_eq!(
                invoke(
                    json!({"op":"bridge","command":{"op":"phone_bridge_ready","support":{"enabled":true,"platform":"ios"}}})
                )["ok"],
                true
            );
            assert_eq!(
                invoke(json!({"op":"bridge","command":{"op":"phone_jobs"}}))["jobs"],
                json!([])
            );
            assert_eq!(invoke(json!({"op":"stop"}))["ok"], true);
            assert_eq!(invoke(json!({"op":"status"}))["running"], false);
            assert!(!dir.path().join("identity.json").exists());
        }
    }
}
