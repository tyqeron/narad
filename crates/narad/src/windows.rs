//! Windows desktop controls and suspended-start command job containment.
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE},
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Thread32First, Thread32Next, TH32CS_SNAPTHREAD, THREADENTRY32,
        },
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        Shutdown::LockWorkStation,
        Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME},
    },
};

struct Handle(HANDLE);
// SAFETY: an owned Windows kernel handle may be closed on any thread. It is not shared.
unsafe impl Send for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

pub struct CommandJob(Handle);
impl CommandJob {
    /// The child is created suspended. Assign its process tree before allowing
    /// the first shell instruction to run, so revocation cannot leave children.
    pub fn attach(child: &tokio::process::Child) -> Result<Self> {
        let process = child.raw_handle().context("command process unavailable")?;
        let pid = child.id().context("command process exited before setup")?;
        // SAFETY: initialized job limits and valid live process handle; all owned
        // handles are closed on every failure path. Snapshot records have dwSize set.
        unsafe {
            let raw = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            ensure!(
                !raw.is_null(),
                "create command job: {}",
                std::io::Error::last_os_error()
            );
            let job = Handle(raw);
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            ensure!(
                SetInformationJobObject(
                    job.0,
                    JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    std::mem::size_of_val(&limits) as u32
                ) != 0,
                "configure command job: {}",
                std::io::Error::last_os_error()
            );
            ensure!(
                AssignProcessToJobObject(job.0, process) != 0,
                "assign command job: {}",
                std::io::Error::last_os_error()
            );
            let raw = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            ensure!(
                raw != INVALID_HANDLE_VALUE,
                "snapshot command thread: {}",
                std::io::Error::last_os_error()
            );
            let snapshot = Handle(raw);
            let mut entry: THREADENTRY32 = std::mem::zeroed();
            entry.dwSize = std::mem::size_of_val(&entry) as u32;
            let mut next = Thread32First(snapshot.0, &mut entry);
            while next != 0 {
                if entry.th32OwnerProcessID == pid {
                    let raw = OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID);
                    ensure!(
                        !raw.is_null(),
                        "open command thread: {}",
                        std::io::Error::last_os_error()
                    );
                    let thread = Handle(raw);
                    ensure!(
                        ResumeThread(thread.0) != u32::MAX,
                        "resume command: {}",
                        std::io::Error::last_os_error()
                    );
                    return Ok(Self(job));
                }
                next = Thread32Next(snapshot.0, &mut entry);
            }
        }
        anyhow::bail!("suspended command thread not found")
    }
}
impl Drop for CommandJob {
    fn drop(&mut self) {
        // The owned handle's Drop terminates all members, including descendants.
        let _ = &self.0;
    }
}

pub fn device_action(kind: &str) -> Result<Value> {
    ensure!(kind == "lock", "Unlock this PC locally using Windows Hello, PIN or password; Windows does not allow remote credential bypass");
    // SAFETY: no pointers; Windows applies the current interactive-session policy.
    ensure!(
        unsafe { LockWorkStation() } != 0,
        "Windows lock request failed: {}",
        std::io::Error::last_os_error()
    );
    Ok(json!({"ok":true,"exit_code":0,"stdout":"Lock requested","stderr":""}))
}
