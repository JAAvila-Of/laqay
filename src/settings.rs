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

// The root is borrowed. Production always uses predefined HKCU; test owners
// keep their isolated key alive for the entire Store call.
struct Store {
    root: HKEY,
}

pub(crate) fn load() -> Result<Preferences> {
    Store {
        root: HKEY_CURRENT_USER,
    }
    .load()
}

pub(crate) fn save_enabled(enabled: bool) -> Result<()> {
    Store {
        root: HKEY_CURRENT_USER,
    }
    .save_enabled(enabled)
}

pub(crate) fn set_startup(enabled: bool, executable: &Path) -> Result<()> {
    Store {
        root: HKEY_CURRENT_USER,
    }
    .set_startup(enabled, executable)
}

impl Store {
    fn load(&self) -> Result<Preferences> {
        let mut value = 0u32;
        let mut bytes = size_of::<u32>() as u32;
        // SAFETY: Only this application's values in HKCU are queried. Buffers have
        // the requested DWORD size; no registry key is created by a read.
        let status = unsafe {
            RegGetValueW(
                self.root,
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
        let mut command = [0u16; 261];
        let mut startup_bytes = size_of_val(&command) as u32;
        // SAFETY: Read only our own bounded Run value. The command is never
        // executed or logged. Size-only queries can include an extra terminator,
        // so inspect the first UTF-16 unit instead of inferring a nonempty string.
        let status = unsafe {
            RegGetValueW(
                self.root,
                RUN,
                w!("Laqay"),
                RRF_RT_REG_SZ,
                None,
                Some(command.as_mut_ptr().cast()),
                Some(&mut startup_bytes),
            )
        };
        let startup = if missing(status) {
            false
        } else {
            status.ok()?;
            startup_bytes >= 2 && command[0] != 0
        };
        Ok(Preferences { enabled, startup })
    }
}

struct Key(HKEY);
impl Drop for Key {
    fn drop(&mut self) {
        // SAFETY: Each Key owns one handle returned by Create/OpenKey.
        let _ = unsafe { RegCloseKey(self.0) };
    }
}

impl Store {
    fn create(&self, path: PCWSTR) -> Result<Key> {
        let mut key = HKEY::default();
        // SAFETY: HKCU only, minimum write permission, owned out-handle. This
        // production call follows a tray action; tests use a separate owned root.
        unsafe {
            RegCreateKeyExW(
                self.root,
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

    fn save_enabled(&self, enabled: bool) -> Result<()> {
        let key = self.create(PREFERENCES)?;
        let bytes = u32::from(enabled).to_le_bytes();
        // SAFETY: REG_DWORD receives exactly four live bytes in our own key.
        unsafe { RegSetValueExW(key.0, w!("Enabled"), None, REG_DWORD, Some(&bytes)).ok() }
    }
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

impl Store {
    fn set_startup(&self, enabled: bool, executable: &Path) -> Result<()> {
        if enabled {
            let command = startup_command(executable)?;
            let key = self.create(RUN)?;
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
            let status = unsafe { RegOpenKeyExW(self.root, RUN, None, KEY_SET_VALUE, &mut handle) };
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
}

#[cfg(test)]
mod tests {
    use super::*;
    // Codec tests are pure. Registry tests below use an isolated, owned root.
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

#[cfg(test)]
mod registry_tests {
    use super::*;
    use std::{
        sync::atomic::{AtomicU64, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };
    use windows::Win32::Foundation::E_UNEXPECTED;

    static NEXT_HIVE: AtomicU64 = AtomicU64::new(0);
    const CHILD_TEST: &str = "settings::registry_tests::child_reads_persisted_preferences";
    const TEST_ROOT: &str = "Software\\LaqayTest.";

    struct TestHive {
        path: Vec<u16>,
        name: String,
        key: Option<Key>,
    }

    impl TestHive {
        fn new() -> Self {
            let name = format!(
                "{TEST_ROOT}{}.{}.{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
                NEXT_HIVE.fetch_add(1, Ordering::Relaxed)
            );
            let path: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
            let mut handle = HKEY::default();
            let mut disposition = REG_CREATE_KEY_DISPOSITION::default();
            // SAFETY: Create a unique test-only key, never Software\Laqay or
            // the user's real Run key. The owned path remains live throughout.
            unsafe {
                RegCreateKeyExW(
                    HKEY_CURRENT_USER,
                    PCWSTR(path.as_ptr()),
                    None,
                    None,
                    REG_OPTION_NON_VOLATILE,
                    KEY_ALL_ACCESS,
                    None,
                    &mut handle,
                    Some(&mut disposition),
                )
                .ok()
                .unwrap();
            }
            let key = Key(handle);
            // An existing key must never become owned by this cleanup guard.
            assert_eq!(disposition, REG_CREATED_NEW_KEY);
            Self {
                path,
                name,
                key: Some(key),
            }
        }

        fn store(&self) -> Store {
            Store {
                root: self.key.as_ref().unwrap().0,
            }
        }

        fn reopen(&self) -> Key {
            open_test_root(&self.name).unwrap()
        }

        fn children(&self) -> u32 {
            let mut count = 0;
            // SAFETY: Query only the test-owned root; all unused outputs are null.
            unsafe {
                RegQueryInfoKeyW(
                    self.key.as_ref().unwrap().0,
                    None,
                    None,
                    None,
                    Some(&mut count),
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                )
                .ok()
                .unwrap();
            }
            count
        }

        fn clean(&mut self) -> Result<()> {
            drop(self.key.take());
            // SAFETY: This exact unique path was created with NEW_KEY above.
            // Never delete a parent or a path supplied by another process.
            let status = unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, PCWSTR(self.path.as_ptr())) };
            if missing(status) { Ok(()) } else { status.ok() }
        }

        fn finish(mut self) {
            self.clean().unwrap();
            let mut handle = HKEY::default();
            // SAFETY: Verify deletion of the exact previously owned test path.
            let status = unsafe {
                RegOpenKeyExW(
                    HKEY_CURRENT_USER,
                    PCWSTR(self.path.as_ptr()),
                    None,
                    KEY_READ,
                    &mut handle,
                )
            };
            if status.is_ok() {
                drop(Key(handle));
            }
            assert!(missing(status), "Test key was not removed: {status:?}");
        }
    }

    impl Drop for TestHive {
        fn drop(&mut self) {
            // Best-effort unwind cleanup; successful tests verify it in finish.
            let _ = self.clean();
        }
    }

    fn open_test_root(name: &str) -> Result<Key> {
        if !name.strip_prefix(TEST_ROOT).is_some_and(|suffix| {
            !suffix.is_empty() && suffix.chars().all(|c| c.is_ascii_digit() || c == '.')
        }) {
            return Err(Error::from_hresult(E_UNEXPECTED));
        }
        let path: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        let mut handle = HKEY::default();
        // SAFETY: The child may open only an existing isolated test path, read-only.
        unsafe {
            RegOpenKeyExW(
                HKEY_CURRENT_USER,
                PCWSTR(path.as_ptr()),
                None,
                KEY_READ,
                &mut handle,
            )
            .ok()?;
        }
        Ok(Key(handle))
    }

    fn put(key: &Key, name: PCWSTR, kind: REG_VALUE_TYPE, bytes: &[u8]) {
        // SAFETY: Test-owned key and live bytes are used only synchronously.
        unsafe {
            RegSetValueExW(key.0, name, None, kind, Some(bytes))
                .ok()
                .unwrap()
        };
    }

    fn raw(store: &Store, path: PCWSTR, name: PCWSTR) -> (REG_VALUE_TYPE, Vec<u8>) {
        let mut kind = REG_VALUE_TYPE::default();
        let mut size = 0;
        // SAFETY: Query size/type first, then read exactly that size from our
        // isolated key. The result is owned and does not retain a registry pointer.
        unsafe {
            RegGetValueW(
                store.root,
                path,
                name,
                RRF_RT_ANY,
                Some(&mut kind),
                None,
                Some(&mut size),
            )
            .ok()
            .unwrap();
            let mut bytes = vec![0u8; size as usize];
            RegGetValueW(
                store.root,
                path,
                name,
                RRF_RT_ANY,
                Some(&mut kind),
                Some(bytes.as_mut_ptr().cast()),
                Some(&mut size),
            )
            .ok()
            .unwrap();
            bytes.truncate(size as usize);
            (kind, bytes)
        }
    }

    #[test]
    fn reading_defaults_does_not_create_preference_or_run_keys() {
        let hive = TestHive::new();
        let preferences = hive.store().load().unwrap();
        assert!(preferences.enabled);
        assert!(!preferences.startup);
        assert_eq!(hive.children(), 0);
        hive.finish();
    }

    #[test]
    fn enabled_persists_for_an_independent_reader_process() {
        let hive = TestHive::new();
        hive.store()
            .set_startup(true, Path::new("C:\\Laqay\\laqay.exe"))
            .unwrap();
        for enabled in [false, true] {
            hive.store().save_enabled(enabled).unwrap();
            assert_eq!(
                raw(&hive.store(), PREFERENCES, w!("Enabled")),
                (REG_DWORD, u32::from(enabled).to_le_bytes().to_vec())
            );
            crate::test_support::child_test(
                CHILD_TEST,
                &[
                    ("LAQAY_TEST_REGISTRY_ROOT", &hive.name),
                    (
                        "LAQAY_TEST_EXPECTED_ENABLED",
                        if enabled { "1" } else { "0" },
                    ),
                ],
            );
        }
        hive.finish();
    }

    #[test]
    #[ignore = "Executed in a child process by enabled_persists_for_an_independent_reader_process"]
    fn child_reads_persisted_preferences() {
        let name = std::env::var("LAQAY_TEST_REGISTRY_ROOT").unwrap();
        let expected = match std::env::var("LAQAY_TEST_EXPECTED_ENABLED")
            .unwrap()
            .as_str()
        {
            "0" => false,
            "1" => true,
            _ => panic!("Invalid child expectation"),
        };
        let key = open_test_root(&name).unwrap();
        let preferences = Store { root: key.0 }.load().unwrap();
        assert_eq!(preferences.enabled, expected);
        assert!(preferences.startup);
    }

    #[test]
    fn startup_round_trip_quotes_unicode_and_preserves_other_run_values() {
        let hive = TestHive::new();
        let executable = Path::new("C:\\Program Files\\Laqay ñ\\laqay.exe");
        hive.store().set_startup(true, executable).unwrap();
        let run = hive.store().create(RUN).unwrap();
        put(&run, w!("OtherApplication"), REG_SZ, &[b'x', 0, 0, 0]);
        let reopened = hive.reopen();
        let store = Store { root: reopened.0 };
        let (kind, bytes) = raw(&store, RUN, w!("Laqay"));
        assert_eq!(kind, REG_SZ);
        let actual: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        assert_eq!(actual, startup_command(executable).unwrap());
        assert!(store.load().unwrap().startup);
        store.set_startup(false, executable).unwrap();
        assert!(!store.load().unwrap().startup);
        assert_eq!(
            raw(&store, RUN, w!("OtherApplication")),
            (REG_SZ, vec![b'x', 0, 0, 0])
        );
        drop(run);
        drop(reopened);
        hive.finish();
    }

    #[test]
    fn removing_absent_startup_does_not_create_a_run_key() {
        let hive = TestHive::new();
        hive.store()
            .set_startup(false, Path::new("C:\\Laqay\\laqay.exe"))
            .unwrap();
        assert_eq!(hive.children(), 0);
        hive.finish();
    }

    #[test]
    fn malformed_enabled_values_never_enable_handling() {
        let hive = TestHive::new();
        let key = hive.store().create(PREFERENCES).unwrap();
        for bytes in [&2u32.to_le_bytes()[..], &[1, 0][..]] {
            put(&key, w!("Enabled"), REG_DWORD, bytes);
            assert!(!matches!(
                hive.store().load(),
                Ok(Preferences { enabled: true, .. })
            ));
        }
        drop(key);
        hive.finish();
    }

    #[test]
    fn incorrect_registry_types_are_reported_as_errors() {
        let hive = TestHive::new();
        let key = hive.store().create(PREFERENCES).unwrap();
        put(&key, w!("Enabled"), REG_SZ, &[b'1', 0, 0, 0]);
        assert!(hive.store().load().is_err());
        hive.store().save_enabled(false).unwrap();
        let run = hive.store().create(RUN).unwrap();
        put(&run, w!("Laqay"), REG_DWORD, &1u32.to_le_bytes());
        assert!(hive.store().load().is_err());
        drop(run);
        drop(key);
        hive.finish();
    }

    #[test]
    fn empty_startup_value_is_disabled() {
        let hive = TestHive::new();
        let run = hive.store().create(RUN).unwrap();
        for bytes in [&[0, 0][..], &[0, 0, 0, 0][..]] {
            put(&run, w!("Laqay"), REG_SZ, bytes);
            assert!(!hive.store().load().unwrap().startup);
        }
        drop(run);
        hive.finish();
    }

    #[test]
    fn oversized_startup_value_is_rejected_with_a_bounded_read() {
        let hive = TestHive::new();
        let run = hive.store().create(RUN).unwrap();
        let mut bytes = [b'x', 0].repeat(300);
        bytes.extend([0, 0]);
        put(&run, w!("Laqay"), REG_SZ, &bytes);
        assert!(hive.store().load().is_err());
        drop(run);
        hive.finish();
    }

    #[test]
    fn invalid_startup_path_is_rejected_before_creating_keys() {
        let hive = TestHive::new();
        assert!(
            hive.store()
                .set_startup(true, Path::new("relative.exe"))
                .is_err()
        );
        assert_eq!(hive.children(), 0);
        hive.finish();
    }

    #[test]
    fn registry_failures_propagate_instead_of_reporting_success() {
        let store = Store {
            root: HKEY::default(),
        };
        assert!(store.load().is_err());
        assert!(store.save_enabled(true).is_err());
        assert!(
            store
                .set_startup(true, Path::new("C:\\Laqay\\laqay.exe"))
                .is_err()
        );
        assert!(
            store
                .set_startup(false, Path::new("C:\\Laqay\\laqay.exe"))
                .is_err()
        );
    }
}
