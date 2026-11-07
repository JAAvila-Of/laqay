//! Real Shell enumeration on a private, noninteractive child desktop.

use super::*;
use crate::file_writer::{ScreenshotTime, create_screenshot_with_staging_checked};
use std::{
    fs,
    io::{self, Write},
    path::Path,
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::RECT,
        UI::{
            Shell::{
                EBO_NOPERSISTVIEWSTATE, EBO_NOTRAVELLOG, ExplorerBrowser, IExplorerBrowser,
                IShellView, SHCreateItemFromParsingName,
            },
            WindowsAndMessaging::*,
        },
    },
    core::{PCWSTR, w},
};

const CHILD: &str = "explorer::shell_view_tests::child_checks_real_shell_staging";

#[test]
fn real_shell_staging_is_checked_on_a_private_desktop() {
    let output = crate::test_support::child_test(CHILD, &[]);
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("Empty Shell view: verified owned staging entry excluded"));
    assert!(
        stdout.contains(
            "Real Shell: owned singleton accepted; unpinned and copied singleton declined"
        )
    );
    assert!(
        stdout.contains("Real Shell: mixed view declined; writer removed only its staging file")
    );
    print!("{stdout}");
}

struct Folder(PathBuf);
impl Folder {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("laqay-shell-staging-{}", std::process::id()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Folder {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

struct Parent(HWND);
impl Parent {
    fn new() -> Self {
        // SAFETY: The caller has established a private nonvisible station. This
        // built-in parent is never shown, activated, or used for input.
        Self(unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("STATIC"),
                w!("Laqay Shell test"),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                640,
                480,
                None,
                None,
                None,
                None,
            )
            .unwrap()
        })
    }
}
impl Drop for Parent {
    fn drop(&mut self) {
        // SAFETY: This thread owns this hidden parent and destroys it after its browser.
        unsafe {
            DestroyWindow(self.0).unwrap();
        }
    }
}

struct Browser(IExplorerBrowser);
impl Browser {
    fn new(parent: HWND, path: &Path) -> Self {
        // SAFETY: All COM objects stay on this private-desktop STA. The browser
        // is embedded only in our hidden parent and does not persist view state.
        unsafe {
            let browser: IExplorerBrowser =
                CoCreateInstance(&ExplorerBrowser, None, CLSCTX_ALL).unwrap();
            browser
                .SetOptions(EBO_NOPERSISTVIEWSTATE | EBO_NOTRAVELLOG)
                .unwrap();
            browser
                .Initialize(
                    parent,
                    &RECT {
                        left: 0,
                        top: 0,
                        right: 640,
                        bottom: 480,
                    },
                    None,
                )
                .unwrap();
            let owned = Self(browser);
            let wide: Vec<u16> = path
                .as_os_str()
                .to_string_lossy()
                .encode_utf16()
                .chain(Some(0))
                .collect();
            let item: IShellItem =
                SHCreateItemFromParsingName(PCWSTR(wide.as_ptr()), None).unwrap();
            owned.0.BrowseToObject(&item, 0).unwrap();
            owned
        }
    }

    fn wait_view(&self, path: &Path, count: i32) -> IFolderView {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut refreshed = false;
        let mut last_count = None;
        println!(
            "Real Shell fixture: refreshing {} for count={count}",
            path.display()
        );
        loop {
            // SAFETY: Only this dedicated child's message queue is pumped. The
            // interfaces and allocated PIDL/name remain on the initializing STA.
            unsafe {
                let mut message = MSG::default();
                for _ in 0..256 {
                    if !PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
                        break;
                    }
                    let _ = TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
                if let Ok(view) = self.0.GetCurrentView::<IFolderView>() {
                    let folder: IPersistFolder2 = view.GetFolder().unwrap();
                    let pidl = folder.GetCurFolder().unwrap();
                    let item: Result<IShellItem> = SHCreateItemFromIDList(pidl);
                    CoTaskMemFree(Some(pidl.cast()));
                    let name = item.unwrap().GetDisplayName(SIGDN_FILESYSPATH).unwrap();
                    let current = name.to_string();
                    CoTaskMemFree(Some(name.0.cast()));
                    if PathBuf::from(current.unwrap()).canonicalize().unwrap()
                        == path.canonicalize().unwrap()
                    {
                        if !refreshed {
                            // Do not rely on interactive Shell notifications in this
                            // hidden fixture. Refresh its own view once per assertion;
                            // the production observer itself remains read-only.
                            view.cast::<IShellView>().unwrap().Refresh().unwrap();
                            refreshed = true;
                        }
                        last_count = Some(view.ItemCount(SVGIO_ALLVIEW).unwrap());
                        if last_count == Some(count) {
                            return view;
                        }
                    }
                }
            }
            assert!(
                Instant::now() < deadline,
                "The real Shell view never reached the expected directory/count={count}; last_count={last_count:?}, refreshed={refreshed}"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
impl Drop for Browser {
    fn drop(&mut self) {
        // SAFETY: Balance Initialize before the parent and COM apartment end.
        unsafe {
            self.0.Destroy().unwrap();
        }
    }
}

#[test]
#[ignore = "Run only by real_shell_staging_is_checked_on_a_private_desktop"]
fn child_checks_real_shell_staging() {
    let station = crate::test_station::Station::new()
        .expect("A private noninteractive station is required; no fallback is permitted");
    {
        let _apartment = Apartment::new(COINIT_APARTMENTTHREADED).unwrap();
        let folder = Folder::new();
        let sibling = folder.0.join("sibling");
        fs::create_dir(&sibling).unwrap();
        let destination = folder.0.join("destination");
        fs::create_dir(&destination).unwrap();
        let parent = Parent::new();
        let browser = Browser::new(parent.0, &destination);
        let other_parent = Parent::new();
        let other_browser = Browser::new(other_parent.0, &sibling);
        let empty = browser.wait_view(&destination, 0);
        assert!(view_has_no_foreign_items(&empty, None, true).unwrap());
        drop(empty);
        let time = ScreenshotTime::new(2026, 1, 2, 3, 4, 5).unwrap();
        let mut encodes = 0;
        let published = create_screenshot_with_staging_checked(
            &destination,
            time,
            |file| {
                encodes += 1;
                file.write_all(b"owned complete staging fixture")
            },
            |staging| {
                let lease = staging.pin()?;
                let view = browser.wait_view(&destination, 1);
                assert!(!view_has_no_foreign_items(&view, None, true).unwrap());
                assert!(view_has_no_foreign_items(&view, Some(&lease), true).unwrap());
                // Same bytes and leaf name in another real view are not proof of ownership.
                let staged = fs::read_dir(&destination)?.next().unwrap()?.path();
                fs::copy(&staged, sibling.join(staged.file_name().unwrap()))?;
                let foreign = other_browser.wait_view(&sibling, 1);
                assert!(!view_has_no_foreign_items(&foreign, Some(&lease), true).unwrap());
                println!(
                    "Real Shell: owned singleton accepted; unpinned and copied singleton declined"
                );
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(encodes, 1);
        assert_eq!(
            fs::read(&published).unwrap(),
            b"owned complete staging fixture"
        );
        let view = browser.wait_view(&destination, 1);
        assert!(!view_has_no_foreign_items(&view, None, true).unwrap());
        drop(view);
        fs::remove_file(published).unwrap();
        browser.wait_view(&destination, 0);
        let foreign_path = destination.join("foreign.txt");
        let declined = create_screenshot_with_staging_checked(
            &destination,
            time,
            |file| file.write_all(b"must not publish"),
            |staging| {
                let lease = staging.pin()?;
                fs::write(&foreign_path, b"preserve this foreign file")?;
                let view = browser.wait_view(&destination, 2);
                assert!(!view_has_no_foreign_items(&view, Some(&lease), true).unwrap());
                Err(io::Error::other(
                    "Foreign Shell item prevents empty-view fallback",
                ))
            },
        );
        assert!(declined.is_err());
        assert_eq!(fs::read_dir(&destination).unwrap().count(), 1);
        assert_eq!(
            fs::read(&foreign_path).unwrap(),
            b"preserve this foreign file"
        );
        println!("Real Shell: mixed view declined; writer removed only its staging file");
        // Explicitly release both views before folders, apartment and station.
        drop(other_browser);
        drop(other_parent);
        drop(browser);
        drop(parent);
    }
    station.finish();
}
