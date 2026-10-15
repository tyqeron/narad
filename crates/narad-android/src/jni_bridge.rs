use super::BackendHost;
use anyhow::{ensure, Result};
use jni::{
    objects::{JClass, JString},
    sys::jstring,
    JNIEnv,
};
use narad_core::identity::Identity;
use serde_json::{json, Value};
use std::sync::{Mutex, OnceLock};

fn host() -> &'static Mutex<BackendHost> {
    static HOST: OnceLock<Mutex<BackendHost>> = OnceLock::new();
    HOST.get_or_init(|| Mutex::new(BackendHost::default()))
}
fn response(mut env: JNIEnv<'_>, action: impl FnOnce(&mut JNIEnv<'_>) -> Result<Value>) -> jstring {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| action(&mut env)));
    let value = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => json!({"ok":false,"error":error.to_string()}),
        Err(_) => json!({"ok":false,"error":"Native backend failed"}),
    };
    // Never log JNI arguments: startup contains unwrapped identity material.
    env.new_string(value.to_string())
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "system" fn Java_dev_narad_narad_1client_NativeBackend_generateIdentity(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jstring {
    response(env, |_| {
        Ok(json!({"ok":true,"identity":Identity::generate()?}))
    })
}
#[no_mangle]
pub extern "system" fn Java_dev_narad_narad_1client_NativeBackend_start(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    config: JString<'_>,
) -> jstring {
    response(env, |env| {
        let text: String = env.get_string(&config)?.into();
        let options: narad::DaemonOptions = serde_json::from_str(&text)?;
        ensure!(
            options.identity.is_some(),
            "Android requires a keystore-protected identity"
        );
        host()
            .lock()
            .map_err(|_| anyhow::anyhow!("backend unavailable"))?
            .start(options)?;
        Ok(json!({"ok":true}))
    })
}
#[no_mangle]
pub extern "system" fn Java_dev_narad_narad_1client_NativeBackend_stop(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jstring {
    response(env, |_| {
        host()
            .lock()
            .map_err(|_| anyhow::anyhow!("backend unavailable"))?
            .stop()?;
        Ok(json!({"ok":true}))
    })
}
#[no_mangle]
pub extern "system" fn Java_dev_narad_narad_1client_NativeBackend_status(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jstring {
    response(env, |_| {
        let host = host()
            .lock()
            .map_err(|_| anyhow::anyhow!("backend unavailable"))?;
        Ok(json!({"ok":true,"running":host.is_running(),"error":host.error()}))
    })
}
