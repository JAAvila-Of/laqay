//! Native clipboard tests confined to a child process's private window station.

use super::*;
use crate::test_station::Station;
use std::{sync::mpsc, time::Duration};
use windows::Win32::{
    Foundation::{HANDLE, HWND},
    System::{
        DataExchange::{EmptyClipboard, SetClipboardData},
        Memory::{GMEM_MOVEABLE, GlobalAlloc},
        StationsAndDesktops::*,
    },
    UI::WindowsAndMessaging::*,
};

const CHILD: &str = "clipboard::tests::child_exercises_private_clipboard";

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
    let output = crate::test_support::child_test(CHILD, &[("LAQAY_TEST_PNG", &hex)]);
    let stdout = String::from_utf8(output.stdout).unwrap();
    for stage in ["control", "before-encode", "before-publish", "generation"] {
        assert!(stdout.contains(&format!("Native publication guard: {stage} checked")));
    }
    for stage in ["released", "cancelled", "replaced"] {
        assert!(stdout.contains(&format!("Native clipboard open retry: {stage} checked")));
    }
    print!("{stdout}");
}

fn publication_checks(window: &Window) {
    use crate::{
        activity::Activity,
        file_writer::{ScreenshotTime, create_screenshot_with_staging_checked},
    };
    use std::{
        fs,
        io::{self, Write},
        path::PathBuf,
    };
    struct Directory(PathBuf);
    impl Drop for Directory {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn sequence() -> u32 {
        // SAFETY: This helper is called only after the child has established
        // and verified its private, noninteractive window station.
        unsafe { GetClipboardSequenceNumber() }
    }
    let text: Vec<u8> = "replacement fixture\0"
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    for (case, stage) in ["control", "before-encode", "before-publish", "generation"]
        .into_iter()
        .enumerate()
    {
        let path = std::env::temp_dir().join(format!(
            "Laqay.ClipboardPublication.{}.{case}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        let directory = Directory(path);
        let time = ScreenshotTime::new(2026, 1, 2, 3, 4, 5).unwrap();
        let original = directory.0.join(time.filename(0));
        fs::write(&original, b"preserve original").unwrap();
        let captured = window.replace(&[(8, &dib())]);
        let source = read_image(captured).unwrap().unwrap();
        assert!(!source.is_png);
        let activity = Activity::new(true);
        let ticket = activity.ticket().unwrap();
        let mut encodes = 0;
        let mut validations = 0;
        let result = create_screenshot_with_staging_checked(
            &directory.0,
            time,
            |file| {
                encodes += 1;
                if stage == "before-encode" {
                    window.replace(&[(13, &text)]);
                }
                let png = crate::image::to_png(&source.bytes, source.is_png).unwrap();
                file.write_all(&png)?;
                if stage == "generation" {
                    activity.set_enabled(false);
                    activity.set_enabled(true);
                }
                Ok(())
            },
            |staging| {
                validations += 1;
                let lease = staging.pin()?;
                let staged = fs::read_dir(&directory.0)?
                    .map(|e| e.unwrap().path())
                    .find(|p| p.extension().is_some_and(|e| e == "tmp"))
                    .unwrap();
                assert!(lease.matches_view_item(&staged));
                if stage == "before-publish" {
                    window.replace(&[(13, &text)]);
                }
                if !activity.valid(ticket)
                    || !crate::runtime::clipboard_sequences_match_for_test(captured, sequence())
                {
                    return Err(io::Error::new(
                        io::ErrorKind::Interrupted,
                        "Paste snapshot revoked",
                    ));
                }
                Ok(())
            },
        );
        assert_eq!(encodes, 1);
        assert_eq!(fs::read(&original).unwrap(), b"preserve original");
        if stage == "control" {
            let output = result.unwrap();
            assert_eq!(validations, 2); // The occupied name forces a second guard.
            assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 2);
            let png = fs::read(output).unwrap();
            assert_eq!(crate::image::to_png(&png, true).unwrap(), png);
        } else {
            assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Interrupted);
            assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
            if stage != "generation" {
                assert_ne!(sequence(), captured);
            } else {
                assert!(!activity.valid(ticket));
            }
            let fresh_sequence = window.replace(&[(8, &dib())]);
            let fresh = read_image(fresh_sequence).unwrap().unwrap();
            let fresh_ticket = activity.ticket().unwrap();
            let recovered = create_screenshot_with_staging_checked(
                &directory.0,
                time,
                |file| file.write_all(&crate::image::to_png(&fresh.bytes, fresh.is_png).unwrap()),
                |_| {
                    assert!(activity.valid(fresh_ticket));
                    assert!(crate::runtime::clipboard_sequences_match_for_test(
                        fresh_sequence,
                        sequence()
                    ));
                    Ok(())
                },
            )
            .unwrap();
            assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 2);
            assert_eq!(fs::read(&original).unwrap(), b"preserve original");
            let png = fs::read(recovered).unwrap();
            assert_eq!(crate::image::to_png(&png, true).unwrap(), png);
        }
        println!("Native publication guard: {stage} checked");
    }
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
    let png_format = unsafe { RegisterClipboardFormatW(w!("PNG")) };
    assert_ne!(png_format, 0);
    // SAFETY: Clipboard operations remain confined to the private station.
    unsafe {
        let virtual_format = RegisterClipboardFormatW(w!("FileGroupDescriptorW"));
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
        assert_eq!(selected.bytes, snapshot.bytes);
        let bmp = crate::image::dib_to_bmp(&selected.bytes).unwrap();
        let offset = u32::from_le_bytes(bmp[10..14].try_into().unwrap()) as usize;
        assert_eq!(&bmp[offset..offset + 3], &[21, 73, 181]);
        window.replace(&[]);
        assert!(crate::image::to_png(&snapshot.bytes, false).is_ok());

        let sequence = window.replace_with_bitmap(&[(png_format, &png)], Some(native()));
        let image = read_image(sequence).unwrap().unwrap();
        assert!(image.is_png);
        assert_eq!(image.bytes, png);

        // An explicitly supplied DIB family still takes priority over a later
        // bitmap representation with different pixels.
        let different = crate::test_support::TestBitmap::new(-1, 32, &[255, 0, 0, 0]);
        let sequence = window.replace_with_bitmap(&[(8, &bitmap)], Some(different));
        let image = read_image(sequence).unwrap().unwrap();
        assert!(!image.is_png);
        let bmp = crate::image::dib_to_bmp(&image.bytes).unwrap();
        let offset = u32::from_le_bytes(bmp[10..14].try_into().unwrap()) as usize;
        assert_eq!(&bmp[offset..offset + 3], &[21, 73, 181]);

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
        let desktop = station.desktop().0 as usize;
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
    for scenario in 0..3 {
        let sequence = window.replace(&[(png_format, &png)]);
        let desktop = station.desktop().0 as usize;
        std::thread::scope(|scope| {
            let (ready_tx, ready_rx) = mpsc::channel();
            let (release_tx, release_rx) = mpsc::channel();
            let (changed_tx, changed_rx) = mpsc::channel();
            let owner = scope.spawn(move || {
                // SAFETY: Only the child's private desktop is shared; its owner
                // outlives this scoped worker. No interactive clipboard is used.
                unsafe {
                    SetThreadDesktop(HDESK(desktop as *mut _)).unwrap();
                    let other = Window::new();
                    OpenClipboard(Some(other.0)).unwrap();
                    let open = Open;
                    ready_tx.send(()).unwrap();
                    if release_rx.recv_timeout(Duration::from_secs(5)).unwrap() {
                        EmptyClipboard().unwrap();
                    }
                    drop(open);
                    let _ = changed_tx.send(());
                }
            });
            ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            let mut attempts = 0;
            let started = std::time::Instant::now();
            let opened = open_image_clipboard(sequence, || {
                attempts += 1;
                if attempts == 2 {
                    release_tx.send(scenario == 2).unwrap();
                    if scenario == 2 {
                        changed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                    }
                }
                scenario != 1 || attempts < 2
            })
            .unwrap();
            assert!(
                attempts >= 2,
                "The real clipboard lock must reject the first open"
            );
            assert!(started.elapsed() < Duration::from_secs(2));
            if scenario == 0 {
                let open = opened.expect("The original image must become readable after release");
                assert_eq!(copy_open_image(&open, png_format, true).unwrap().bytes, png);
                drop(open);
            } else {
                assert!(
                    opened.is_none(),
                    "Cancelled or replaced requests must not read an image"
                );
            }
            owner.join().unwrap();
        });
        println!(
            "Native clipboard open retry: {} checked",
            ["released", "cancelled", "replaced"][scenario]
        );
    }
    publication_checks(&window);
    window.replace(&[]);
    drop(window);
    station.finish();
}
