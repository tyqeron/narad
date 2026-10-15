//! Windows account-bound identity wrapping, protected DACLs and atomic replacement.
use crate::{identity::Identity, storage::atomic_write};
use anyhow::{ensure, Context, Result};
use std::{os::windows::ffi::OsStrExt, path::Path, ptr};
use windows_sys::Win32::{
    Foundation::LocalFree,
    Security::{
        Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW,
        Cryptography::{
            CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        },
        SetFileSecurityW, DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION,
    },
    Storage::FileSystem::{MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH},
};

pub fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

pub fn private_path(path: &Path) -> Result<()> {
    // Owner Rights + SYSTEM only, protected from parent ACL inheritance. Child
    // files/directories inherit this DACL. Administrators can still take ownership.
    let sddl: Vec<u16> = "D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;SY)\0"
        .encode_utf16()
        .collect();
    let mut descriptor = ptr::null_mut();
    // SAFETY: strings are terminated and descriptor is allocated by Windows.
    unsafe {
        ensure!(
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                1,
                &mut descriptor,
                ptr::null_mut()
            ) != 0,
            "create private Windows ACL: {}",
            std::io::Error::last_os_error()
        );
        let result = SetFileSecurityW(
            wide(path).as_ptr(),
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        );
        let error = std::io::Error::last_os_error();
        LocalFree(descriptor);
        ensure!(result != 0, "protect Windows state directory: {error}");
    }
    Ok(())
}

pub fn replace(source: &Path, destination: &Path) -> Result<()> {
    // SAFETY: buffers are valid terminated UTF-16 paths for the duration of the call.
    let ok = unsafe {
        MoveFileExW(
            wide(source).as_ptr(),
            wide(destination).as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    ensure!(
        ok != 0,
        "replace Windows state: {}",
        std::io::Error::last_os_error()
    );
    Ok(())
}

fn protect(bytes: &[u8], decrypt: bool) -> Result<Vec<u8>> {
    let input = CRYPT_INTEGER_BLOB {
        cbData: bytes.len().try_into()?,
        pbData: bytes.as_ptr().cast_mut(),
    };
    let mut output: CRYPT_INTEGER_BLOB = unsafe { std::mem::zeroed() };
    // SAFETY: DPAPI reads input during this call, allocates output, and never
    // displays UI. No machine-wide scope: ciphertext belongs to the current user.
    unsafe {
        let ok = if decrypt {
            CryptUnprotectData(
                &input,
                ptr::null_mut(),
                ptr::null(),
                ptr::null(),
                ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptProtectData(
                &input,
                ptr::null(),
                ptr::null(),
                ptr::null(),
                ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        ensure!(
            ok != 0,
            "Windows identity protection failed: {}",
            std::io::Error::last_os_error()
        );
        let result = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        if decrypt {
            std::ptr::write_bytes(output.pbData, 0, output.cbData as usize);
        }
        LocalFree(output.pbData.cast());
        Ok(result)
    }
}

pub fn load_identity(dir: &Path) -> Result<Identity> {
    let wrapped = dir.join("identity.dpapi");
    let legacy = dir.join("identity.json");
    if wrapped.exists() {
        let mut plain = protect(&std::fs::read(&wrapped)?, true).context(
            "use the Windows account that created this identity; do not delete it to recover",
        )?;
        let identity = serde_json::from_slice(&plain);
        plain.fill(0);
        let identity = identity?;
        // Finish a migration interrupted after publishing the wrapped identity.
        if legacy.exists() {
            std::fs::remove_file(&legacy)?;
        }
        return Ok(identity);
    }
    let identity = if legacy.exists() {
        serde_json::from_slice(&std::fs::read(&legacy)?)?
    } else {
        Identity::generate()?
    };
    let mut plain = serde_json::to_vec(&identity)?;
    let result = protect(&plain, false);
    plain.fill(0);
    atomic_write(&wrapped, &result?)?;
    if legacy.exists() {
        std::fs::remove_file(legacy)?;
    }
    Ok(identity)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_is_wrapped_migrated_and_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        crate::storage::private_dir(dir.path()).unwrap();
        let old = Identity::generate().unwrap();
        atomic_write(
            &dir.path().join("identity.json"),
            &serde_json::to_vec(&old).unwrap(),
        )
        .unwrap();
        let loaded = load_identity(dir.path()).unwrap();
        assert_eq!(old.public_key(), loaded.public_key());
        assert!(!dir.path().join("identity.json").exists());
        assert_eq!(
            load_identity(dir.path()).unwrap().public_key(),
            old.public_key()
        );
        std::fs::write(dir.path().join("identity.dpapi"), b"corrupt").unwrap();
        assert!(load_identity(dir.path()).is_err());
    }
}
