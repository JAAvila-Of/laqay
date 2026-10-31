//! Native clipboard tests confined to a child process's private window station.

use super::*;
use std::{
    sync::mpsc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use windows::{
    Win32::{
        Foundation::{E_UNEXPECTED, GENERIC_ALL, HANDLE, HWND},
        System::{
            DataExchange::{EmptyClipboard, SetClipboardData},
            Memory::{GMEM_MOVEABLE, GlobalAlloc},
            StationsAndDesktops::*,
            Threading::GetCurrentThreadId,
        },
        UI::WindowsAndMessaging::*,
    },
    core::PCWSTR,
};

const CHILD: &str = "clipboard::tests::child_exercises_private_clipboard";

struct Station {
    previous_station: HWINSTA,
    previous_desktop: HDESK,
    station: HWINSTA,
    desktop: Option<HDESK>,
}

impl Station {
    fn new() -> Result<Self> {
        // SAFETY: This runs only in the dedicated child test. CWF_CREATE_ONLY
        // refuses any existing station, including the interactive one. A unique
        // name prevents accidentally opening a station shared by another process.
        unsafe {
            let previous_station = GetProcessWindowStation()?;
            let previous_desktop = GetThreadDesktop(GetCurrentThreadId())?;
            const CWF_CREATE_ONLY: u32 = 1;
            let name = format!(
                "Laqay.Test.{}.{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            );
            let name: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
            let station =
                CreateWindowStationW(PCWSTR(name.as_ptr()), CWF_CREATE_ONLY, GENERIC_ALL.0, None)?;
            let mut owned = Self {
                previous_station,
                previous_desktop,
                station,
                desktop: None,
            };
            let mut flags = USEROBJECTFLAGS::default();
            GetUserObjectInformationW(
                HANDLE(station.0),
                UOI_FLAGS,
                Some((&mut flags as *mut USEROBJECTFLAGS).cast()),
                size_of::<USEROBJECTFLAGS>() as u32,
                None,
            )?;
            const WSF_VISIBLE: u32 = 1;
            if station == previous_station || flags.dwFlags & WSF_VISIBLE != 0 {
                return Err(Error::new(
                    E_UNEXPECTED,
                    "Clipboard isolation was not established",
                ));
            }
            SetProcessWindowStation(station)?;
            let desktop = CreateDesktopW(
                w!("Default"),
                PCWSTR::null(),
                None,
                DESKTOP_CONTROL_FLAGS::default(),
                GENERIC_ALL.0,
                None,
            )?;
            owned.desktop = Some(desktop);
            SetThreadDesktop(desktop)?;
            if GetProcessWindowStation()? != station
                || GetThreadDesktop(GetCurrentThreadId())? != desktop
            {
                return Err(Error::from_hresult(E_UNEXPECTED));
            }
            Ok(owned)
        }
    }

    fn finish(mut self) {
        // SAFETY: All test windows, clipboard locks, and worker threads have
        // ended. Only this child's station/thread association is restored.
        unsafe {
            SetProcessWindowStation(self.previous_station).unwrap();
            SetThreadDesktop(self.previous_desktop).unwrap();
            CloseDesktop(self.desktop.take().unwrap()).unwrap();
            CloseWindowStation(self.station).unwrap();
            self.station = HWINSTA::default();
        }
    }
}

impl Drop for Station {
    fn drop(&mut self) {
        // SAFETY: Unwind cleanup is confined to this child and its owned handles.
        unsafe {
            let _ = SetProcessWindowStation(self.previous_station);
            let _ = SetThreadDesktop(self.previous_desktop);
            if let Some(desktop) = self.desktop.take() {
                let _ = CloseDesktop(desktop);
            }
            if !self.station.is_invalid() {
                let _ = CloseWindowStation(self.station);
            }
        }
    }
}

struct Window(HWND);
impl Window {
    fn new() -> Self {
        // SAFETY: Built-in static class, message-only window, private desktop.
        // No window is shown or activated, and no input observer is installed.
        Self(unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("STATIC"),
                w!("Laqay clipboard test"),
                WINDOW_STYLE::default(),
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                None,
                None,
            )
            .unwrap()
        })
    }

    fn replace(&self, formats: &[(u32, &[u8])]) -> u32 {
        self.replace_with_bitmap(formats, None)
    }

    fn replace_with_bitmap(
        &self,
        formats: &[(u32, &[u8])],
        bitmap: Option<crate::test_support::TestBitmap>,
    ) -> u32 {
        // SAFETY: Station::new has succeeded before this window exists. Only
        // this child's private clipboard receives these synthetic fixtures.
        unsafe {
            OpenClipboard(Some(self.0)).unwrap();
            let open = Open;
            EmptyClipboard().unwrap();
            for (format, bytes) in formats {
                struct Allocation(HGLOBAL);
                impl Drop for Allocation {
                    fn drop(&mut self) {
                        // SAFETY: Frees only a test allocation not yet transferred.
                        let _ = unsafe { windows::Win32::Foundation::GlobalFree(Some(self.0)) };
                    }
                }
                let allocation = Allocation(GlobalAlloc(GMEM_MOVEABLE, bytes.len()).unwrap());
                let data = GlobalLock(allocation.0);
                assert!(!data.is_null());
                let locked = Locked(allocation.0);
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), data.cast::<u8>(), bytes.len());
                drop(locked);
                SetClipboardData(*format, Some(HANDLE(allocation.0.0))).unwrap();
                std::mem::forget(allocation);
            }
            if let Some(bitmap) = bitmap {
                SetClipboardData(2, Some(HANDLE(bitmap.handle().0))).unwrap();
                // Ownership transfers only after the clipboard accepts it.
                let _ = bitmap.into_raw();
            }
            drop(open);
            let sequence = GetClipboardSequenceNumber();
            assert_ne!(sequence, 0);
            sequence
        }
    }
}
impl Drop for Window {
    fn drop(&mut self) {
        // SAFETY: The private window is destroyed on its creating thread.
        unsafe { DestroyWindow(self.0).unwrap() };
    }
}

fn dib() -> Vec<u8> {
    let mut bytes = vec![0u8; 44];
    bytes[0..4].copy_from_slice(&40u32.to_le_bytes());
    bytes[4..8].copy_from_slice(&1i32.to_le_bytes());
    bytes[8..12].copy_from_slice(&(-1i32).to_le_bytes());
    bytes[12..14].copy_from_slice(&1u16.to_le_bytes());
    bytes[14..16].copy_from_slice(&24u16.to_le_bytes());
    bytes[40..44].copy_from_slice(&[21, 73, 181, 0]);
    bytes
}

#[test]
fn native_clipboard_matrix_runs_without_the_interactive_clipboard() {
    let png = crate::image::to_png(&dib(), false).unwrap();
    let hex: String = png.iter().map(|byte| format!("{byte:02x}")).collect();
    crate::test_support::child_test(CHILD, &[("LAQAY_TEST_PNG", &hex)]);
}

#[test]
#[ignore = "Executed in a private child by native_clipboard_matrix_runs_without_the_interactive_clipboard"]
fn child_exercises_private_clipboard() {
    let hex = std::env::var("LAQAY_TEST_PNG").unwrap();
    let png: Vec<u8> = hex
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
        .collect();
    let station = Station::new()
        .expect("A private noninteractive station is required; no fallback is permitted");
    let window = Window::new();
    let bitmap = dib();
    // SAFETY: All format registration and clipboard APIs below run only after
    // private-station validation, before restoring the previous association.
    unsafe {
        let png_format = RegisterClipboardFormatW(w!("PNG"));
        let virtual_format = RegisterClipboardFormatW(w!("FileGroupDescriptorW"));
        assert_ne!(png_format, 0);
        assert_ne!(virtual_format, 0);

        let sequence = window.replace(&[]);
        assert!(read_image(sequence).unwrap().is_none());
        let text = [b'x', 0, 0, 0];
        let sequence = window.replace(&[(13, &text)]);
        assert!(read_image(sequence).unwrap().is_none());

        let sequence = window.replace(&[(png_format, &png), (8, &bitmap)]);
        let image = read_image(sequence).unwrap().unwrap();
        assert!(image.is_png);
        assert_eq!(image.bytes, png);

        let sequence = window.replace(&[(8, &bitmap)]);
        let image = read_image(sequence).unwrap().unwrap();
        assert!(!image.is_png);
        // Windows can synthesize DIBV5 from DIB. Validate the resulting container
        // and the actual pixel instead of assuming which header it returns.
        let bmp = crate::image::dib_to_bmp(&image.bytes).unwrap();
        let offset = u32::from_le_bytes(bmp[10..14].try_into().unwrap()) as usize;
        assert_eq!(&bmp[offset..offset + 3], &[21, 73, 181]);

        let native = || crate::test_support::TestBitmap::new(-1, 32, &[21, 73, 181, 0]);
        let sequence = window.replace_with_bitmap(&[], Some(native()));
        // Windows can synthesize DIB formats. Exercise the real HBITMAP copy
        // directly as well as the public selection path, without a test override.
        OpenClipboard(Some(window.0)).unwrap();
        let open = Open;
        let original = GetClipboardData(2).unwrap();
        let snapshot = copy_open_image(&open, 2, false).unwrap();
        assert!(!snapshot.is_png);
        assert_eq!(&snapshot.bytes[40..44], &[21, 73, 181, 255]);
        assert_eq!(GetClipboardData(2).unwrap(), original);
        assert_eq!(
            copy_open_image(&open, 2, false).unwrap().bytes,
            snapshot.bytes
        );
        drop(open);
        let selected = read_image(sequence).unwrap().unwrap();
        assert!(!selected.is_png);
        let bmp = crate::image::dib_to_bmp(&selected.bytes).unwrap();
        let offset = u32::from_le_bytes(bmp[10..14].try_into().unwrap()) as usize;
        assert_eq!(&bmp[offset..offset + 3], &[21, 73, 181]);
        window.replace(&[]);
        assert!(crate::image::to_png(&snapshot.bytes, false).is_ok());

        let sequence = window.replace_with_bitmap(&[(png_format, &png)], Some(native()));
        let image = read_image(sequence).unwrap().unwrap();
        assert!(image.is_png);
        assert_eq!(image.bytes, png);

        let mut drop_files = vec![0u8; 20];
        drop_files[0..4].copy_from_slice(&20u32.to_le_bytes());
        drop_files[16..20].copy_from_slice(&1u32.to_le_bytes());
        for unit in "C:\\synthetic\\file.txt\0\0".encode_utf16() {
            drop_files.extend(unit.to_le_bytes());
        }
        let sequence = window.replace(&[(png_format, &png), (15, &drop_files)]);
        assert!(read_image(sequence).unwrap().is_none());
        let sequence = window.replace_with_bitmap(&[(15, &drop_files)], Some(native()));
        assert!(read_image(sequence).unwrap().is_none());
        let sequence = window.replace(&[
            (png_format, &png),
            (virtual_format, b"synthetic descriptor"),
        ]);
        assert!(read_image(sequence).unwrap().is_none());

        let stale = window.replace(&[(png_format, &png)]);
        let current = window.replace(&[(13, &text)]);
        assert_ne!(stale, current);
        assert!(read_image(stale).unwrap().is_none());
        assert!(read_image(0).unwrap().is_none());

        let sequence = window.replace(&[(png_format, &png)]);
        let desktop = station.desktop.unwrap().0 as usize;
        std::thread::scope(|scope| {
            let (ready_tx, ready_rx) = mpsc::channel();
            let (release_tx, release_rx) = mpsc::channel();
            let owner = scope.spawn(move || {
                // This worker shares only the child's private desktop handle,
                // whose owner outlives the scoped thread.
                SetThreadDesktop(HDESK(desktop as *mut _)).unwrap();
                let other = Window::new();
                OpenClipboard(Some(other.0)).unwrap();
                let _open = Open;
                let _ = ready_tx.send(());
                let _ = release_rx.recv_timeout(Duration::from_secs(5));
            });
            ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            assert!(read_image(sequence).is_err());
            release_tx.send(()).unwrap();
            owner.join().unwrap();
        });
        assert_eq!(read_image(sequence).unwrap().unwrap().bytes, png);
        window.replace(&[]);
    }
    drop(window);
    station.finish();
}
