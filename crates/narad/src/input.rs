//! Minimal, consent-gated remote keyboard and pointer injection.
use anyhow::{ensure, Result};
use serde_json::{json, Value};
#[cfg(target_os = "linux")]
use std::process::Command;

pub fn inject(event: &Value) -> Result<Value> {
    let kind = event["type"].as_str().unwrap_or("");
    match kind {
        "text" => {
            let text = event["text"].as_str().unwrap_or("");
            ensure!(!text.is_empty() && text.len() <= 256, "invalid input text");
            #[cfg(target_os = "linux")]
            {
                ensure!(
                    std::env::var_os("WAYLAND_DISPLAY").is_none(),
                    "Remote input injection currently requires an X11 desktop session"
                );
                let status = Command::new("xdotool")
                    .args(["type", "--clearmodifiers", "--delay", "0", "--", text])
                    .status()?;
                ensure!(
                    status.success(),
                    "xdotool could not type into the active desktop"
                );
            }
            #[cfg(windows)]
            {
                use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
                    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP,
                    KEYEVENTF_UNICODE,
                };
                for unit in text.encode_utf16() {
                    let inputs = [
                        INPUT {
                            r#type: INPUT_KEYBOARD,
                            Anonymous: INPUT_0 {
                                ki: KEYBDINPUT {
                                    wVk: 0,
                                    wScan: unit,
                                    dwFlags: KEYEVENTF_UNICODE,
                                    time: 0,
                                    dwExtraInfo: 0,
                                },
                            },
                        },
                        INPUT {
                            r#type: INPUT_KEYBOARD,
                            Anonymous: INPUT_0 {
                                ki: KEYBDINPUT {
                                    wVk: 0,
                                    wScan: unit,
                                    dwFlags: KEYEVENTF_UNICODE | KEYEVENTF_KEYUP,
                                    time: 0,
                                    dwExtraInfo: 0,
                                },
                            },
                        },
                    ];
                    ensure!(
                        unsafe {
                            SendInput(2, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32)
                        } == 2,
                        "Windows rejected remote keyboard input"
                    );
                }
            }
            #[cfg(not(any(target_os = "linux", windows)))]
            anyhow::bail!("Remote input is not available on this platform");
        }
        "move" | "scroll" => {
            let x = event["x"].as_i64().unwrap_or(0).clamp(-2000, 2000) as i32;
            let y = event["y"].as_i64().unwrap_or(0).clamp(-2000, 2000) as i32;
            ensure!(x != 0 || y != 0, "empty pointer input");
            #[cfg(target_os = "linux")]
            {
                ensure!(
                    std::env::var_os("WAYLAND_DISPLAY").is_none(),
                    "Remote input injection currently requires an X11 desktop session"
                );
                let status = if kind == "move" {
                    Command::new("xdotool")
                        .args([
                            "mousemove",
                            "--sync",
                            "--relative",
                            &x.to_string(),
                            &y.to_string(),
                        ])
                        .status()?
                } else {
                    Command::new("xdotool")
                        .args([
                            "click",
                            "--repeat",
                            &y.unsigned_abs().to_string(),
                            if y < 0 { "4" } else { "5" },
                        ])
                        .status()?
                };
                ensure!(
                    status.success(),
                    "xdotool could not control the active desktop"
                );
            }
            #[cfg(windows)]
            {
                use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
                    SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_MOVE, MOUSEEVENTF_WHEEL,
                    MOUSEINPUT,
                };
                let mouse = MOUSEINPUT {
                    dx: x,
                    dy: y,
                    mouseData: if kind == "scroll" {
                        (y * 120) as u32
                    } else {
                        0
                    },
                    dwFlags: if kind == "scroll" {
                        MOUSEEVENTF_WHEEL
                    } else {
                        MOUSEEVENTF_MOVE
                    },
                    time: 0,
                    dwExtraInfo: 0,
                };
                let input = INPUT {
                    r#type: INPUT_MOUSE,
                    Anonymous: INPUT_0 { mi: mouse },
                };
                ensure!(
                    unsafe { SendInput(1, &input, std::mem::size_of::<INPUT>() as i32) } == 1,
                    "Windows rejected remote pointer input"
                );
            }
            #[cfg(not(any(target_os = "linux", windows)))]
            anyhow::bail!("Remote input is not available on this platform");
        }
        "click" => {
            let button = event["button"].as_str().unwrap_or("left");
            ensure!(
                ["left", "right"].contains(&button),
                "unsupported mouse button"
            );
            #[cfg(target_os = "linux")]
            {
                ensure!(
                    std::env::var_os("WAYLAND_DISPLAY").is_none(),
                    "Remote input injection currently requires an X11 desktop session"
                );
                let code = if button == "left" { "1" } else { "3" };
                let status = Command::new("xdotool").args(["click", code]).status()?;
                ensure!(
                    status.success(),
                    "xdotool could not click the active desktop"
                );
            }
            #[cfg(windows)]
            {
                use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
                    SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_LEFTDOWN,
                    MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEINPUT,
                };
                let (down, up) = if button == "left" {
                    (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP)
                } else {
                    (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP)
                };
                let inputs = [down, up].map(|flags| INPUT {
                    r#type: INPUT_MOUSE,
                    Anonymous: INPUT_0 {
                        mi: MOUSEINPUT {
                            dx: 0,
                            dy: 0,
                            mouseData: 0,
                            dwFlags: flags,
                            time: 0,
                            dwExtraInfo: 0,
                        },
                    },
                });
                ensure!(
                    unsafe { SendInput(2, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) }
                        == 2,
                    "Windows rejected remote click"
                );
            }
            #[cfg(not(any(target_os = "linux", windows)))]
            anyhow::bail!("Remote input is not available on this platform");
        }
        _ => anyhow::bail!("unsupported remote input event"),
    }
    Ok(json!({"ok":true}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_unrecognized_input_without_touching_the_desktop() {
        assert!(inject(&json!({"type":"execute","command":"rm -rf /"})).is_err());
        assert!(inject(&json!({"type":"text","text":""})).is_err());
        assert!(inject(&json!({"type":"click","button":"middle"})).is_err());
    }
}
