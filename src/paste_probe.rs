//! Opt-in, bounded experiment: observe Ctrl+V, preserve native input, and save PNG.
//! This module is not enabled by the application entry point.

use crate::{
    clipboard, explorer,
    file_writer::{self, ScreenshotTime},
    image,
    keys::PasteKeys,
};
use std::{
    cell::RefCell,
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
    },
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::{
            CloseHandle, E_INVALIDARG, ERROR_ALREADY_EXISTS, GetLastError, HANDLE, HINSTANCE, HWND,
            LPARAM, LRESULT, WPARAM,
        },
        System::{
            DataExchange::GetClipboardSequenceNumber,
            LibraryLoader::GetModuleHandleW,
            SystemInformation::{GetLocalTime, GetWindowsDirectoryW},
            Threading::{
                CreateMutexW, OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
                QueryFullProcessImageNameW,
            },
        },
        UI::{
            Input::{KeyboardAndMouse::GetAsyncKeyState, *},
            Shell::{SHCNE_CREATE, SHCNF_PATHW, SHChangeNotify},
            WindowsAndMessaging::*,
        },
    },
    core::{Error, PWSTR, Result, w},
};

#[derive(Clone, Copy)]
struct Request {
    window: usize,
    focus: usize,
    sequence: u32,
    received: Instant,
}

struct State {
    keys: RefCell<PasteKeys>,
    sender: SyncSender<Request>,
}

fn current_request() -> Option<Request> {
    // SAFETY: Only current window metadata and clipboard sequence are read;
    // out-parameters reference initialized local storage. No input is generated.
    unsafe {
        let window = GetForegroundWindow();
        if window.is_invalid() {
            return None;
        }
        let mut info = GUITHREADINFO {
            cbSize: size_of::<GUITHREADINFO>() as u32,
            ..Default::default()
        };
        GetGUIThreadInfo(GetWindowThreadProcessId(window, None), &mut info).ok()?;
        if info.hwndFocus.is_invalid() {
            return None;
        }
        Some(Request {
            window: window.0 as usize,
            focus: info.hwndFocus.0 as usize,
            sequence: GetClipboardSequenceNumber(),
            received: Instant::now(),
        })
    }
}

fn explorer_process(window: usize) -> Result<bool> {
    // SAFETY: The process is opened for limited read-only queries. Its owned
    // handle is closed on every path, and all path buffers remain alive.
    unsafe {
        let mut pid = 0;
        GetWindowThreadProcessId(HWND(window as *mut _), Some(&mut pid));
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)?;
        let mut path = vec![0u16; 32768];
        let mut length = path.len() as u32;
        let result = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(path.as_mut_ptr()),
            &mut length,
        );
        let _ = CloseHandle(process);
        result?;
        let actual = String::from_utf16_lossy(&path[..length as usize]);
        let mut system = vec![0u16; 32768];
        let count = GetWindowsDirectoryW(Some(&mut system)) as usize;
        if count == 0 || count >= system.len() {
            return Ok(false);
        }
        let expected =
            PathBuf::from(String::from_utf16_lossy(&system[..count])).join("explorer.exe");
        Ok(actual.eq_ignore_ascii_case(&expected.to_string_lossy()))
    }
}

fn target(request: Request) -> Result<Option<PathBuf>> {
    let current = current_request();
    if !matches!(current, Some(now) if now.window == request.window && now.focus == request.focus && now.sequence == request.sequence)
        || !explorer_process(request.window)?
    {
        return Ok(None);
    }
    let snapshot = explorer::observe_foreground()?;
    if snapshot.foreground_window != request.window || snapshot.focus_window != request.focus {
        return Ok(None);
    }
    Ok(snapshot
        .diagnostic_directory()
        .and_then(|path| path.canonicalize().ok()))
}

fn save(
    request: Request,
    stopping: &AtomicBool,
    deadline: Instant,
    approved_directory: &Path,
) -> std::result::Result<Option<PathBuf>, Box<dyn std::error::Error>> {
    if stopping.load(Ordering::Acquire) || Instant::now() >= deadline {
        return Ok(None);
    }
    let Some(directory) = target(request)? else {
        return Ok(None);
    };
    if directory != approved_directory {
        return Ok(None);
    }
    let Some(source) = clipboard::read_image(request.sequence)? else {
        return Ok(None);
    };
    let png = image::to_png(&source.bytes, source.is_png)?;
    // SAFETY: GetLocalTime writes no external state and returns an owned value.
    let clock = unsafe { GetLocalTime() };
    let time = ScreenshotTime::new(
        clock.wYear,
        clock.wMonth as u8,
        clock.wDay as u8,
        clock.wHour as u8,
        clock.wMinute as u8,
        clock.wSecond as u8,
    )?;
    let output = file_writer::create_screenshot_checked(
        &directory,
        time,
        |file| file.write_all(&png),
        || {
            if stopping.load(Ordering::Acquire) || Instant::now() >= deadline {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "Probe stopped"));
            }
            let again = target(request).map_err(|error| io::Error::other(error.to_string()))?;
            if again.as_deref() != Some(directory.as_path()) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Paste context changed",
                ));
            }
            Ok(())
        },
    )?;
    let mut name: Vec<u16> =
        std::os::windows::ffi::OsStrExt::encode_wide(output.as_os_str()).collect();
    name.push(0);
    // SAFETY: This targeted notification references a live NUL-terminated path.
    // No Explorer window is refreshed or activated by this call.
    unsafe { SHChangeNotify(SHCNE_CREATE, SHCNF_PATHW, Some(name.as_ptr().cast()), None) };
    Ok(Some(output))
}

unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    // SAFETY: Win32 owns the callback window and message parameters. User data
    // points at a stable State allocation until the window is destroyed. RAWINPUT
    // storage is aligned and initialized; only a validated keyboard union is read.
    unsafe {
        if message == WM_NCCREATE {
            let create = &*(lparam.0 as *const CREATESTRUCTW);
            SetWindowLongPtrW(window, GWLP_USERDATA, create.lpCreateParams as isize);
        } else if message == WM_INPUT {
            let state = GetWindowLongPtrW(window, GWLP_USERDATA) as *const State;
            if !state.is_null() {
                let state = &*state;
                let mut raw = RAWINPUT::default();
                let mut size = size_of::<RAWINPUT>() as u32;
                let read = GetRawInputData(
                    HRAWINPUT(lparam.0 as *mut _),
                    RID_INPUT,
                    Some((&mut raw as *mut RAWINPUT).cast()),
                    &mut size,
                    size_of::<RAWINPUTHEADER>() as u32,
                );
                if read != u32::MAX
                    && read as usize >= size_of::<RAWINPUTHEADER>() + size_of::<RAWKEYBOARD>()
                    && raw.header.dwType == RIM_TYPEKEYBOARD.0
                {
                    let key = raw.data.keyboard;
                    let extended = key.Flags & 2 != 0;
                    let code = match key.VKey {
                        0x11 => {
                            if extended {
                                0xa3
                            } else {
                                0xa2
                            }
                        }
                        0x12 => {
                            if extended {
                                0xa5
                            } else {
                                0xa4
                            }
                        }
                        0x10 => {
                            if key.MakeCode == 0x36 {
                                0xa1
                            } else {
                                0xa0
                            }
                        }
                        other => other,
                    };
                    if let Ok(mut keys) = state.keys.try_borrow_mut() {
                        if keys.transition(code, key.Flags & 1 == 0) {
                            if let Some(request) = current_request() {
                                let _ = state.sender.try_send(request);
                            }
                        }
                    }
                }
            }
        } else if message == WM_TIMER {
            PostQuitMessage(0);
        } else if message == WM_NCDESTROY {
            SetWindowLongPtrW(window, GWLP_USERDATA, 0);
        }
        // Always retain native processing. No hotkey is registered and NOLEGACY
        // is never requested; this observer cannot consume another app's Ctrl+V.
        DefWindowProcW(window, message, wparam, lparam)
    }
}

struct Window {
    handle: HWND,
    instance: HINSTANCE,
}
impl Drop for Window {
    fn drop(&mut self) {
        // SAFETY: This guard owns the hidden window, timer, and this process's
        // raw keyboard registration. Its State allocation still exists here.
        unsafe {
            let _ = RegisterRawInputDevices(
                &[RAWINPUTDEVICE {
                    usUsagePage: 1,
                    usUsage: 6,
                    dwFlags: RIDEV_REMOVE,
                    hwndTarget: HWND::default(),
                }],
                size_of::<RAWINPUTDEVICE>() as u32,
            );
            let _ = KillTimer(Some(self.handle), 1);
            let _ = DestroyWindow(self.handle);
            let _ = UnregisterClassW(w!("LaqayPasteProbe"), Some(self.instance));
        }
    }
}

/// Explicitly start a 1-30 second experiment. Calling this observes real keyboard
/// input and may create screenshots; a desktop test must be authorized first.
pub fn run(seconds: u32, approved_directory: &Path) -> Result<()> {
    if !approved_directory.is_absolute() {
        return Err(Error::from_hresult(E_INVALIDARG));
    }
    let approved_directory = approved_directory
        .canonicalize()
        .map_err(|error| Error::new(E_INVALIDARG, error.to_string()))?;
    if !approved_directory.is_dir() {
        return Err(Error::from_hresult(E_INVALIDARG));
    }
    struct Instance(HANDLE);
    impl Drop for Instance {
        fn drop(&mut self) {
            // SAFETY: This guard owns the mutex handle and closes it exactly once.
            let _ = unsafe { CloseHandle(self.0) };
        }
    }
    // SAFETY: The named object is session-local. The guard releases its handle
    // on every exit path, including a rejected second probe instance.
    let instance = Instance(unsafe { CreateMutexW(None, false, w!("Local\\LaqayPasteProbe"))? });
    // SAFETY: Read immediately after CreateMutexW on the same thread.
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        return Err(Error::new(
            E_INVALIDARG,
            "A paste probe is already running in this session",
        ));
    }
    let result = run_inner(seconds, approved_directory);
    drop(instance);
    result
}

fn run_inner(seconds: u32, approved_directory: PathBuf) -> Result<()> {
    if !(1..=30).contains(&seconds) {
        return Err(Error::from_hresult(E_INVALIDARG));
    }
    let deadline = Instant::now() + Duration::from_secs(seconds.into());
    let stopping = Arc::new(AtomicBool::new(false));
    let worker_stop = Arc::clone(&stopping);
    let (sender, receiver) = mpsc::sync_channel(1);
    let worker = std::thread::spawn(move || {
        while let Ok(request) = receiver.recv() {
            match save(request, &worker_stop, deadline, &approved_directory) {
                Ok(Some(path)) => println!(
                    "Saved: {} ({} ms after request receipt)",
                    path.display(),
                    request.received.elapsed().as_millis()
                ),
                Ok(None) => println!("Declined: no stable supported image-paste context"),
                Err(error) => eprintln!("Paste declined: {error}"),
            }
        }
    });
    let mut keys = PasteKeys::default();
    // SAFETY: These initial modifier snapshots read state only. No keys, mouse
    // events, clipboard contents or activation messages are injected.
    unsafe {
        for key in [0xa2, 0xa3, 0xa0, 0xa1, 0xa4, 0xa5, 0x5b, 0x5c, 0x56] {
            keys.transition(key, GetAsyncKeyState(key.into()) as u16 & 0x8000 != 0);
        }
    }
    let state = Box::new(State {
        keys: RefCell::new(keys),
        sender,
    });
    // SAFETY: The class callback and stable State allocation outlive the window.
    // The message-only window never takes foreground focus or displays a UI.
    let result = unsafe {
        (|| -> Result<()> {
            let instance = HINSTANCE(GetModuleHandleW(None)?.0);
            let class = WNDCLASSW {
                lpfnWndProc: Some(window_proc),
                hInstance: instance,
                lpszClassName: w!("LaqayPasteProbe"),
                ..Default::default()
            };
            if RegisterClassW(&class) == 0 {
                return Err(Error::from_thread());
            }
            let handle = match CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("LaqayPasteProbe"),
                w!("Laqay paste experiment"),
                WINDOW_STYLE::default(),
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                Some(instance),
                Some((&*state as *const State).cast()),
            ) {
                Ok(handle) => handle,
                Err(error) => {
                    let _ = UnregisterClassW(w!("LaqayPasteProbe"), Some(instance));
                    return Err(error);
                }
            };
            let _window = Window { handle, instance };
            RegisterRawInputDevices(
                &[RAWINPUTDEVICE {
                    usUsagePage: 1,
                    usUsage: 6,
                    dwFlags: RIDEV_INPUTSINK,
                    hwndTarget: handle,
                }],
                size_of::<RAWINPUTDEVICE>() as u32,
            )?;
            if SetTimer(Some(handle), 1, seconds * 1000, None) == 0 {
                return Err(Error::from_thread());
            }
            println!(
                "Ready. Observing native Ctrl+V for {seconds} seconds; native paste remains enabled."
            );
            let mut message = MSG::default();
            loop {
                match GetMessageW(&mut message, None, 0, 0).0 {
                    -1 => return Err(Error::from_thread()),
                    0 => break,
                    _ => {
                        DispatchMessageW(&message);
                    }
                }
            }
            Ok(())
        })()
    };
    stopping.store(true, Ordering::Release);
    drop(state);
    let _ = worker.join();
    result
}
