//! Per-user preferences. Reads never create keys or enable automatic startup.

use std::{os::windows::ffi::OsStrExt, path::Path};
use windows::{
    Win32::{
        Foundation::{ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, WIN32_ERROR},
        System::Registry::*,
    },
    core::{Error, PCWSTR, Result, w},
};

const PREFERENCES: PCWSTR = w!("Software\\Laqay");
const RUN: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");

pub(crate) struct Preferences {
    pub enabled: bool,
    pub startup: bool,
}

fn missing(status: WIN32_ERROR) -> bool {
    status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND
}

fn enabled_value(value: Option<u32>) -> bool {
    // Missing is the first-run default; malformed values fail closed.
    matches!(value, None | Some(1))
}

pub(crate) fn load() -> Result<Preferences> {
    let mut value = 0u32;
    let mut bytes = size_of::<u32>() as u32;
    // SAFETY: Only this application's values in HKCU are queried. Buffers have
    // the requested DWORD size; no registry key is created by a read.
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            PREFERENCES,
            w!("Enabled"),
            RRF_RT_REG_DWORD,
            None,
            Some((&mut value as *mut u32).cast()),
            Some(&mut bytes),
        )
    };
    let enabled = if missing(status) {
        enabled_value(None)
    } else {
        status.ok()?;
        enabled_value(Some(if bytes == 4 { value } else { 0 }))
    };
    let mut startup_bytes = 0;
    // SAFETY: Query only type/size of our Run value, without loading or running
    // its command. An absent entry is disabled; nothing is written at startup.
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            RUN,
            w!("Laqay"),
            RRF_RT_REG_SZ,
            None,
            None,
            Some(&mut startup_bytes),
        )
    };
    let startup = if missing(status) {
        false
    } else {
        status.ok()?;
        startup_bytes > 2
    };
    Ok(Preferences { enabled, startup })
}

struct Key(HKEY);
impl Drop for Key {
    fn drop(&mut self) {
        // SAFETY: Each Key owns one handle returned by Create/OpenKey.
        let _ = unsafe { RegCloseKey(self.0) };
    }
}

fn create(path: PCWSTR) -> Result<Key> {
    let mut key = HKEY::default();
    // SAFETY: HKCU only, minimum write permission, owned out-handle. This
    // function is called exclusively after a settings action in the tray.
    unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            path,
            None,
            None,
            REG_OPTION_NON_VOLATILE,
            KEY_SET_VALUE,
            None,
            &mut key,
            None,
        )
        .ok()?;
    }
    Ok(Key(key))
}

pub(crate) fn save_enabled(enabled: bool) -> Result<()> {
    let key = create(PREFERENCES)?;
    let bytes = u32::from(enabled).to_le_bytes();
    // SAFETY: REG_DWORD receives exactly four live bytes in our own key.
    unsafe { RegSetValueExW(key.0, w!("Enabled"), None, REG_DWORD, Some(&bytes)).ok() }
}

fn startup_command(executable: &Path) -> Result<Vec<u16>> {
    let path: Vec<u16> = executable.as_os_str().encode_wide().collect();
    if !executable.is_absolute() || path.contains(&0) || path.contains(&(b'"' as u16)) {
        return Err(Error::new(
            windows::Win32::Foundation::E_INVALIDARG,
            "Invalid executable path",
        ));
    }
    let mut command = Vec::with_capacity(path.len() + 3);
    command.push(b'"' as u16);
    command.extend(path);
    command.push(b'"' as u16);
    // Run entries are documented as commands of no more than 260 characters.
    if command.len() >= 260 {
        return Err(Error::new(
            windows::Win32::Foundation::E_INVALIDARG,
            "Executable path is too long for automatic startup",
        ));
    }
    command.push(0);
    Ok(command)
}

pub(crate) fn set_startup(enabled: bool, executable: &Path) -> Result<()> {
    if enabled {
        let command = startup_command(executable)?;
        let key = create(RUN)?;
        // SAFETY: The live UTF-16 command includes its terminator and is exposed
        // as bytes for the synchronous API. Only our named Run value is changed.
        unsafe {
            let bytes =
                std::slice::from_raw_parts(command.as_ptr().cast::<u8>(), command.len() * 2);
            RegSetValueExW(key.0, w!("Laqay"), None, REG_SZ, Some(bytes)).ok()
        }
    } else {
        let mut handle = HKEY::default();
        // SAFETY: Open existing HKCU Run key with write-only value permission.
        // Deleting an absent entry succeeds without creating the key.
        let status =
            unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, RUN, None, KEY_SET_VALUE, &mut handle) };
        if missing(status) {
            return Ok(());
        }
        status.ok()?;
        let key = Key(handle);
        // SAFETY: Delete only the application's own value, never the Run key.
        let status = unsafe { RegDeleteValueW(key.0, w!("Laqay")) };
        if missing(status) { Ok(()) } else { status.ok() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // These tests are pure codecs. They never open or modify the real registry.
    #[test]
    fn defaults_and_corrupt_enabled_values_are_safe() {
        assert!(enabled_value(None));
        assert!(enabled_value(Some(1)));
        for value in [0, 2, u32::MAX] {
            assert!(!enabled_value(Some(value)));
        }
    }
    #[test]
    fn startup_is_one_quoted_executable_even_with_spaces_or_unicode() {
        let path = Path::new("C:\\Program Files\\Laqay ñ\\laqay.exe");
        let command = startup_command(path).unwrap();
        assert_eq!(
            String::from_utf16(&command[..command.len() - 1]).unwrap(),
            "\"C:\\Program Files\\Laqay ñ\\laqay.exe\""
        );
        assert_eq!(command.last(), Some(&0));
    }
    #[test]
    fn unsafe_or_oversized_startup_paths_are_rejected() {
        for path in [
            "laqay.exe".to_owned(),
            "C:\\bad\"name.exe".into(),
            "C:\\bad\0name.exe".into(),
            format!("C:\\{}\\laqay.exe", "x".repeat(260)),
        ] {
            assert!(startup_command(Path::new(&path)).is_err());
        }
    }

    #[test]
    fn startup_limit_includes_the_terminating_null() {
        let fits = format!("C:\\{}", "x".repeat(254));
        let too_long = format!("C:\\{}", "x".repeat(255));
        assert_eq!(startup_command(Path::new(&fits)).unwrap().len(), 260);
        assert!(startup_command(Path::new(&too_long)).is_err());
    }
}
