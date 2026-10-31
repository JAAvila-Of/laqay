//! Bounded child test processes, without console windows or desktop input.

use std::{
    os::windows::process::CommandExt,
    process::{Command, Output, Stdio},
    time::{Duration, Instant},
};
use windows::Win32::System::Threading::CREATE_NO_WINDOW;

/// Owned synthetic pixels; no screen DC, window, or clipboard access.
pub(crate) struct TestBitmap {
    handle: Option<windows::Win32::Graphics::Gdi::HBITMAP>,
    bits: *mut u8,
    size: usize,
}

impl TestBitmap {
    pub(crate) fn new(height: i32, depth: u16, bytes: &[u8]) -> Self {
        use windows::Win32::Graphics::Gdi::*;
        assert!([16, 24, 32].contains(&depth));
        assert!(height != 0 && height.unsigned_abs() <= 16);
        let stride = (depth as usize).div_ceil(32) * 4;
        let size = stride * height.unsigned_abs() as usize;
        assert_eq!(bytes.len(), size);
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: 1,
                biHeight: height,
                biPlanes: 1,
                biBitCount: depth,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        // SAFETY: The small, checked fixture owns its DIB section and pixel
        // storage. It is never selected into a DC or shared with another thread.
        let handle =
            unsafe { CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0).unwrap() };
        assert!(!bits.is_null());
        // SAFETY: The successfully created section has exactly size writable bytes.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), bits.cast::<u8>(), size) };
        Self {
            handle: Some(handle),
            bits: bits.cast(),
            size,
        }
    }

    pub(crate) fn handle(&self) -> windows::Win32::Graphics::Gdi::HBITMAP {
        self.handle.unwrap()
    }

    pub(crate) fn bytes(&self) -> Vec<u8> {
        // SAFETY: The section is still owned by this fixture.
        unsafe { std::slice::from_raw_parts(self.bits, self.size).to_vec() }
    }

    #[cfg(feature = "isolated-clipboard-tests")]
    pub(crate) fn into_raw(mut self) -> windows::Win32::Graphics::Gdi::HBITMAP {
        self.handle.take().unwrap()
    }
}

impl Drop for TestBitmap {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            // SAFETY: Delete only the fixture's still-owned GDI object.
            assert!(
                unsafe {
                    windows::Win32::Graphics::Gdi::DeleteObject(
                        windows::Win32::Graphics::Gdi::HGDIOBJ(handle.0),
                    )
                }
                .as_bool()
            );
        }
    }
}

pub(crate) fn child_test(name: &str, environment: &[(&str, &str)]) -> Output {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .creation_flags(CREATE_NO_WINDOW.0)
        .args(["--ignored", "--exact", name, "--nocapture"])
        .envs(environment.iter().copied())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("Owned child test {name} exceeded its deadline");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "Child {name} failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("1 passed"));
    output
}
