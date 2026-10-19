//! Open a validated web URL using the receiver's default browser.
use anyhow::{ensure, Result};
use serde_json::{json, Value};

pub fn validate(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty() && value.len() <= 2048,
        "URL must be 1–2048 bytes"
    );
    ensure!(
        !value.chars().any(|c| c.is_control() || c.is_whitespace()),
        "URL cannot contain spaces or control characters"
    );
    let lower = value.to_ascii_lowercase();
    ensure!(
        lower.starts_with("https://") || lower.starts_with("http://"),
        "Only http:// and https:// links can be shared"
    );
    let authority = value
        .split_once("://")
        .map(|(_, rest)| rest.split(['/', '?', '#']).next().unwrap_or(""))
        .unwrap_or("");
    let host = authority.rsplit('@').next().unwrap_or("");
    let host = if host.starts_with('[') {
        host.split(']').next().unwrap_or("").trim_start_matches('[')
    } else {
        host.split(':').next().unwrap_or("")
    };
    ensure!(!host.is_empty(), "URL must include a host name");
    Ok(())
}

pub fn open(value: &str) -> Result<Value> {
    validate(value)?;
    #[cfg(target_os = "linux")]
    {
        use std::process::Command;
        let child = Command::new("xdg-open").arg(value).spawn()?;
        drop(child);
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::Shell::ShellExecuteW;
        let verb = "open\0".encode_utf16().collect::<Vec<_>>();
        let target = value.encode_utf16().chain([0]).collect::<Vec<_>>();
        let result = unsafe {
            ShellExecuteW(
                std::ptr::null_mut(),
                verb.as_ptr(),
                target.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                1,
            )
        };
        ensure!((result as isize) > 32, "Windows could not open the URL");
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    anyhow::bail!("Opening a URL is not supported directly on this platform");
    Ok(json!({"ok":true,"message":"Opened with the default browser"}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_valid_web_urls_are_accepted() {
        for url in ["https://example.com/page", "http://192.168.1.2:8080/"] {
            validate(url).unwrap();
        }
        for url in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "https://",
            "https://example.com/a b",
            "https://example.com\n",
        ] {
            assert!(validate(url).is_err(), "{url:?}");
        }
    }
}
