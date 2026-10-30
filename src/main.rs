#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
fn main() {
    if let Err(error) = laqay::app::run() {
        use windows::{
            Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW},
            core::{PCWSTR, w},
        };
        let message: Vec<u16> = format!("Laqay could not start.\n\n{error}")
            .encode_utf16()
            .chain(Some(0))
            .collect();
        // SAFETY: A startup failure has already cleaned up application resources.
        // The error buffer lives through the synchronous message box.
        unsafe {
            MessageBoxW(
                None,
                PCWSTR(message.as_ptr()),
                w!("Laqay"),
                MB_OK | MB_ICONERROR,
            );
        }
        std::process::exit(1);
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Laqay requires Windows.");
    std::process::exit(1);
}
