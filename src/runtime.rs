//! Shared passive input observer and paste worker for the app and bounded probes.

use crate::{
    activity::Activity,
    clipboard, explorer,
    file_writer::{self, ScreenshotTime},
    image,
    keys::PasteKeys,
};
use std::{
    cell::{Cell, RefCell},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
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
    ticket: u64,
}

struct State {
    keys: RefCell<PasteKeys>,
    hook_keys: RefCell<PasteKeys>,
    use_hook: bool,
    counts: Counts,
    sender: Option<SyncSender<Request>>,
    activity: Arc<Activity>,
    hook: RefCell<Option<Hook>>,
    diagnostics: bool,
    notify_window: usize,
}

#[derive(Default, Debug)]
struct Counts {
    raw_messages: Cell<u64>,
    raw_keyboard: Cell<u64>,
    raw_errors: Cell<u64>,
    raw_chords: Cell<u64>,
    hook_events: Cell<u64>,
    hook_injected: Cell<u64>,
    hook_chords: Cell<u64>,
    snapshot_failures: Cell<u64>,
    queued: Cell<u64>,
    queue_rejections: Cell<u64>,
}

fn increment(counter: &Cell<u64>) {
    counter.set(counter.get().saturating_add(1));
}

impl State {
    fn enqueue(&self) {
        // Input-only mode has no sender or worker. Return before reading even
        // clipboard sequence or foreground context, regardless of the chord.
        let Some(sender) = &self.sender else { return };
        let Some(ticket) = self.activity.ticket() else {
            return;
        };
        if let Some(mut request) = current_request() {
            request.ticket = ticket;
            if sender.try_send(request).is_ok() {
                increment(&self.counts.queued);
            } else {
                increment(&self.counts.queue_rejections);
            }
        } else {
            increment(&self.counts.snapshot_failures);
        }
    }

    fn reconfigure(&self) -> Result<()> {
        let mut slot = self
            .hook
            .try_borrow_mut()
            .map_err(|_| Error::from_hresult(windows::Win32::Foundation::E_UNEXPECTED))?;
        if self.use_hook && self.activity.ticket().is_some() {
            if slot.is_none() {
                // Resolve the module before exposing State to the callback.
                // SAFETY: Query the current executable's module handle.
                let instance = unsafe { HINSTANCE(GetModuleHandleW(None)?.0) };
                let keys = seeded_keys();
                *self.hook_keys.borrow_mut() = keys;
                HOOK_STATE.with(|pointer| pointer.set(self));
                // SAFETY: The callback runs on this dedicated message-pump
                // thread. The boxed State remains alive until hook removal.
                let result = unsafe {
                    SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), Some(instance), 0)
                };
                match result {
                    Ok(handle) => {
                        *slot = Some(Hook {
                            handle,
                            diagnostics: self.diagnostics,
                        })
                    }
                    Err(error) => {
                        HOOK_STATE.with(|pointer| pointer.set(std::ptr::null()));
                        return Err(error);
                    }
                }
            }
        } else if let Some(hook) = slot.as_mut() {
            hook.remove()?;
            slot.take();
        }
        Ok(())
    }
}

fn normalized_key(code: u16, scan: u16, extended: bool) -> u16 {
    match code {
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
            if scan == 0x36 {
                0xa1
            } else {
                0xa0
            }
        }
        other => other,
    }
}

thread_local! {
    static HOOK_STATE: Cell<*const State> = const { Cell::new(std::ptr::null()) };
}

// Count callback entry independently of thread-local state, so a missing State
// cannot be mistaken for complete absence of hook dispatch.
static HOOK_CALLBACKS: AtomicU64 = AtomicU64::new(0);

unsafe extern "system" fn keyboard_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    HOOK_CALLBACKS.fetch_add(1, Ordering::Relaxed);
    // SAFETY: Windows supplies a live KBDLLHOOKSTRUCT for actionable events.
    // The thread-local pointer exists only while the hook and State are alive.
    // The callback only updates aggregate counters and submits bounded work.
    unsafe {
        if code == HC_ACTION as i32 {
            let _ = HOOK_STATE.try_with(|slot| {
                let Some(state) = slot.get().as_ref() else {
                    return;
                };
                let key = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
                increment(&state.counts.hook_events);
                if key.flags.contains(LLKHF_INJECTED) {
                    increment(&state.counts.hook_injected);
                }
                let message = wparam.0 as u32;
                if !matches!(message, WM_KEYDOWN | WM_SYSKEYDOWN | WM_KEYUP | WM_SYSKEYUP) {
                    return;
                }
                let down = matches!(message, WM_KEYDOWN | WM_SYSKEYDOWN);
                let normalized = normalized_key(
                    key.vkCode as u16,
                    key.scanCode as u16,
                    key.flags.contains(LLKHF_EXTENDED),
                );
                if let Ok(mut keys) = state.hook_keys.try_borrow_mut() {
                    if keys.transition(normalized, down) && !key.flags.contains(LLKHF_ALTDOWN) {
                        increment(&state.counts.hook_chords);
                        if state.use_hook {
                            state.enqueue();
                        }
                    }
                }
            });
        }
        // This observer never suppresses an event or generates replacement input.
        CallNextHookEx(None, code, wparam, lparam)
    }
}

struct Hook {
    handle: HHOOK,
    diagnostics: bool,
}
impl Hook {
    fn remove(&mut self) -> Result<()> {
        if self.handle.0.is_null() {
            return Ok(());
        }
        // SAFETY: This hook belongs to the current observer thread. A hook
        // already removed by Windows has no callback left to unregister.
        if let Err(error) = unsafe { UnhookWindowsHookEx(self.handle) } {
            if error.code()
                != windows::core::HRESULT::from_win32(
                    windows::Win32::Foundation::ERROR_INVALID_HOOK_HANDLE.0,
                )
            {
                return Err(error);
            }
        }
        self.handle = HHOOK::default();
        HOOK_STATE.with(|slot| slot.set(std::ptr::null()));
        if self.diagnostics {
            println!("Keyboard hook removed.");
        }
        Ok(())
    }
}
impl Drop for Hook {
    fn drop(&mut self) {
        if let Err(error) = self.remove() {
            if self.diagnostics {
                eprintln!("Keyboard hook removal failed: {error}");
            }
        }
        // Even an unexpected unhook failure must not leave a State pointer
        // behind after this observer is destroyed. Process exit removes hooks.
        HOOK_STATE.with(|slot| slot.set(std::ptr::null()));
    }
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
            ticket: 0,
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

fn target(request: Request, diagnostics: bool) -> Result<Option<PathBuf>> {
    let current = current_request();
    if !matches!(current, Some(now) if now.window == request.window && now.focus == request.focus && now.sequence == request.sequence)
    {
        if diagnostics {
            println!("Context declined: window, focus, or clipboard sequence changed");
        }
        return Ok(None);
    }
    if !explorer_process(request.window)? {
        if diagnostics {
            println!("Context declined: foreground process is not Explorer");
        }
        return Ok(None);
    }
    let snapshot = explorer::observe_with_diagnostics(diagnostics)?;
    if snapshot.foreground_window != request.window || snapshot.focus_window != request.focus {
        if diagnostics {
            println!("Context declined: Explorer snapshot no longer matches request");
        }
        return Ok(None);
    }
    if diagnostics && snapshot.diagnostic_directory().is_none() {
        println!(
            "Context declined: foreground_stable={}, native_focus_stable={}, unresolved_views={}, focused_views={}, semantic_focus={:?}",
            snapshot.foreground_unchanged,
            snapshot.native_focus_unchanged,
            snapshot.unresolved_entries,
            snapshot
                .observations
                .iter()
                .filter(|view| view.contains_focus)
                .count(),
            snapshot.semantic_focus
        );
    }
    Ok(snapshot
        .diagnostic_directory()
        .and_then(|path| path.canonicalize().ok()))
}

fn save(
    request: Request,
    activity: &Activity,
    deadline: Option<Instant>,
    approved_directory: Option<&Path>,
    diagnostics: bool,
) -> std::result::Result<Option<PathBuf>, Box<dyn std::error::Error>> {
    let active =
        || activity.valid(request.ticket) && deadline.is_none_or(|limit| Instant::now() < limit);
    if !active() {
        if diagnostics {
            println!("Request declined: observer paused, stopped, or expired");
        }
        return Ok(None);
    }
    let Some(directory) = target(request, diagnostics)? else {
        return Ok(None);
    };
    if approved_directory.is_some_and(|approved| directory != approved) {
        if diagnostics {
            println!("Request declined: folder differs from approved destination");
        }
        return Ok(None);
    }
    if !active() {
        return Ok(None);
    }
    let Some(source) = clipboard::read_image(request.sequence)? else {
        if diagnostics {
            println!("Request declined: clipboard changed or has no eligible image format");
        }
        return Ok(None);
    };
    let png = image::to_png(&source.bytes, source.is_png)?;
    if !active() {
        return Ok(None);
    }
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
            if !active() {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Observer paused or stopped",
                ));
            }
            let again = target(request, diagnostics)
                .map_err(|error| io::Error::other(error.to_string()))?;
            if !active() || again.as_deref() != Some(directory.as_path()) {
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
                increment(&state.counts.raw_messages);
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
                    increment(&state.counts.raw_keyboard);
                    let key = raw.data.keyboard;
                    let code = normalized_key(key.VKey, key.MakeCode, key.Flags & 2 != 0);
                    if let Ok(mut keys) = state.keys.try_borrow_mut() {
                        if keys.transition(code, key.Flags & 1 == 0) {
                            increment(&state.counts.raw_chords);
                            if !state.use_hook {
                                state.enqueue();
                            }
                        }
                    }
                } else {
                    increment(&state.counts.raw_errors);
                }
            }
        } else if message == RECONFIGURE {
            let pointer = GetWindowLongPtrW(window, GWLP_USERDATA) as *const State;
            if let Some(state) = pointer.as_ref() {
                if state.activity.is_stopped() {
                    PostQuitMessage(0);
                } else {
                    let ticket = state.activity.ticket();
                    if let Err(error) = state.reconfigure() {
                        if let Some(ticket) = ticket {
                            state.activity.disable_if_current(ticket);
                        }
                        if state.diagnostics {
                            eprintln!("Observer configuration failed: {error}");
                        }
                        if state.notify_window != 0 {
                            let _ = PostMessageW(
                                Some(HWND(state.notify_window as *mut _)),
                                ENGINE_ERROR,
                                WPARAM(0),
                                LPARAM(0),
                            );
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
    raw_input: bool,
}
impl Drop for Window {
    fn drop(&mut self) {
        // SAFETY: This guard owns the hidden window, timer, and this process's
        // raw keyboard registration. Its State allocation still exists here.
        unsafe {
            if self.raw_input {
                let _ = RegisterRawInputDevices(
                    &[RAWINPUTDEVICE {
                        usUsagePage: 1,
                        usUsage: 6,
                        dwFlags: RIDEV_REMOVE,
                        hwndTarget: HWND::default(),
                    }],
                    size_of::<RAWINPUTDEVICE>() as u32,
                );
            }
            let _ = KillTimer(Some(self.handle), 1);
            let _ = DestroyWindow(self.handle);
            let _ = UnregisterClassW(w!("LaqayInputWindow"), Some(self.instance));
        }
    }
}

/// Explicitly start a bounded experiment with an approved filesystem directory.
pub(crate) fn run(seconds: u32, approved_directory: &Path, use_hook: bool) -> Result<()> {
    let directory = approved_folder(approved_directory)?;
    run_probe(Options {
        seconds: Some(seconds),
        approved: Some(directory),
        input_only: false,
        use_hook,
        diagnostics: true,
        raw_input: true,
    })
}

pub(crate) fn run_input(seconds: u32) -> Result<()> {
    run_probe(Options {
        seconds: Some(seconds),
        approved: None,
        input_only: true,
        use_hook: true,
        diagnostics: true,
        raw_input: true,
    })
}

pub(crate) fn approved_folder(directory: &Path) -> Result<PathBuf> {
    if !directory.is_absolute() {
        return Err(Error::from_hresult(E_INVALIDARG));
    }
    let directory = directory
        .canonicalize()
        .map_err(|error| Error::new(E_INVALIDARG, error.to_string()))?;
    if !directory.is_dir() {
        return Err(Error::from_hresult(E_INVALIDARG));
    }
    Ok(directory)
}

pub(crate) struct Instance(HANDLE);
impl Instance {
    pub fn acquire() -> Result<Option<Self>> {
        // SAFETY: Session-local object shared by the app and its probes. Read
        // last-error immediately and close the owned handle on every path.
        let handle = unsafe { CreateMutexW(None, false, w!("Local\\LaqayInstance"))? };
        // SAFETY: Same thread, immediately following CreateMutexW.
        if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
            // SAFETY: This call owns the newly returned duplicate handle.
            let _ = unsafe { CloseHandle(handle) };
            Ok(None)
        } else {
            Ok(Some(Self(handle)))
        }
    }
}
impl Drop for Instance {
    fn drop(&mut self) {
        // SAFETY: Owns this handle, not any other process's instance.
        let _ = unsafe { CloseHandle(self.0) };
    }
}

pub(crate) const ENGINE_ERROR: u32 = WM_APP + 21;
pub(crate) const ENGINE_STOPPED: u32 = WM_APP + 22;
const RECONFIGURE: u32 = WM_APP + 23;

struct Options {
    seconds: Option<u32>,
    approved: Option<PathBuf>,
    input_only: bool,
    use_hook: bool,
    diagnostics: bool,
    raw_input: bool,
}

fn run_probe(options: Options) -> Result<()> {
    let _instance = Instance::acquire()?
        .ok_or_else(|| Error::new(E_INVALIDARG, "Laqay is already running in this session"))?;
    run_inner(options, Arc::new(Activity::new(true)), 0, None)
}

/// Owns only this application's observer thread. UI and registry operations
/// never run on the hook thread; pausing removes its hook asynchronously.
pub(crate) struct Observer {
    window: HWND,
    activity: Arc<Activity>,
    done: mpsc::Receiver<()>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Observer {
    pub fn start(
        activity: Arc<Activity>,
        notify: HWND,
        trial: Option<(u32, PathBuf)>,
    ) -> Result<Self> {
        let diagnostics = trial.is_some();
        let (seconds, approved) = match trial {
            Some((seconds, path)) => (Some(seconds), Some(path)),
            None => (None, None),
        };
        let options = Options {
            seconds,
            approved,
            input_only: false,
            use_hook: true,
            diagnostics,
            raw_input: false,
        };
        let (ready_tx, ready_rx) = mpsc::channel();
        let failure_tx = ready_tx.clone();
        let (done_tx, done_rx) = mpsc::channel();
        let gate = Arc::clone(&activity);
        let notify = notify.0 as usize;
        let thread = std::thread::spawn(move || {
            let result = run_inner(options, gate, notify, Some(ready_tx));
            if let Err(error) = result {
                let _ = failure_tx.send(Err(error));
                // SAFETY: Post to our UI window without dereferencing UI state.
                let _ = unsafe {
                    PostMessageW(
                        Some(HWND(notify as *mut _)),
                        ENGINE_ERROR,
                        WPARAM(0),
                        LPARAM(0),
                    )
                };
            }
            // SAFETY: A stopped worker must close its own UI, not other apps.
            let _ = unsafe {
                PostMessageW(
                    Some(HWND(notify as *mut _)),
                    ENGINE_STOPPED,
                    WPARAM(0),
                    LPARAM(0),
                )
            };
            let _ = done_tx.send(());
        });
        match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(window)) => Ok(Self {
                window: HWND(window as *mut _),
                activity,
                done: done_rx,
                thread: Some(thread),
            }),
            Ok(Err(error)) => {
                activity.stop();
                Err(error)
            }
            Err(_) => {
                activity.stop();
                Err(Error::new(
                    E_INVALIDARG,
                    "The input observer did not become ready",
                ))
            }
        }
    }
    pub fn refresh(&self) -> Result<()> {
        // SAFETY: The message targets our dedicated observer window only.
        unsafe { PostMessageW(Some(self.window), RECONFIGURE, WPARAM(0), LPARAM(0)) }
    }
}
impl Drop for Observer {
    fn drop(&mut self) {
        self.activity.stop();
        let _ = self.refresh();
        // The observer removes input hooks before waiting briefly for its paste
        // worker. A blocked external provider must not strand the tray process.
        if self.done.recv_timeout(Duration::from_secs(3)).is_ok() {
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
        // If an external call is still blocked, returning from main terminates
        // the remaining thread in this process; no other process is touched.
    }
}

fn seeded_keys() -> PasteKeys {
    let mut keys = PasteKeys::default();
    // SAFETY: Initial state reads occur outside the low-level callback. No
    // events are generated and unrelated key state is not retained.
    unsafe {
        for key in [0xa2, 0xa3, 0xa0, 0xa1, 0xa4, 0xa5, 0x5b, 0x5c, 0x56] {
            keys.transition(key, GetAsyncKeyState(key.into()) as u16 & 0x8000 != 0);
        }
    }
    keys
}

struct InputGuard<'a>(&'a State);
impl Drop for InputGuard<'_> {
    fn drop(&mut self) {
        self.0.activity.stop();
        self.0.hook.borrow_mut().take();
    }
}

fn run_inner(
    options: Options,
    activity: Arc<Activity>,
    notify_window: usize,
    mut ready: Option<mpsc::Sender<Result<usize>>>,
) -> Result<()> {
    if options
        .seconds
        .is_some_and(|seconds| !(1..=30).contains(&seconds))
    {
        return Err(Error::from_hresult(E_INVALIDARG));
    }
    if options.diagnostics {
        crate::probe_environment::log_environment("starting");
    }
    if activity.is_stopped() {
        return Err(Error::from_hresult(E_INVALIDARG));
    }
    HOOK_CALLBACKS.store(0, Ordering::Relaxed);
    let deadline = options
        .seconds
        .map(|seconds| Instant::now() + Duration::from_secs(seconds.into()));
    let (worker_done_tx, worker_done_rx) = mpsc::channel();
    let (sender, worker) = if options.input_only {
        (None, None)
    } else {
        let (sender, receiver) = mpsc::sync_channel(1);
        let gate = Arc::clone(&activity);
        let approved = options.approved;
        let diagnostics = options.diagnostics;
        let worker = std::thread::spawn(move || {
            while let Ok(request) = receiver.recv() {
                let result = save(request, &gate, deadline, approved.as_deref(), diagnostics);
                if diagnostics {
                    match result {
                        Ok(Some(path)) => println!(
                            "Saved: {} ({} ms after request receipt)",
                            path.display(),
                            request.received.elapsed().as_millis()
                        ),
                        Ok(None) => println!("Declined: no stable supported image-paste context"),
                        Err(error) => eprintln!("Paste declined: {error}"),
                    }
                }
            }
            let _ = worker_done_tx.send(());
        });
        (Some(sender), Some(worker))
    };
    let keys = seeded_keys();
    let state = Box::new(State {
        keys: RefCell::new(keys.clone()),
        hook_keys: RefCell::new(keys),
        use_hook: options.use_hook,
        counts: Counts::default(),
        sender,
        activity: Arc::clone(&activity),
        hook: RefCell::new(None),
        diagnostics: options.diagnostics,
        notify_window,
    });
    // SAFETY: Window callbacks refer to a stable State on this thread. The
    // message-only window never displays UI or changes foreground activation.
    let result = unsafe {
        (|| -> Result<()> {
            let instance = HINSTANCE(GetModuleHandleW(None)?.0);
            let class = WNDCLASSW {
                lpfnWndProc: Some(window_proc),
                hInstance: instance,
                lpszClassName: w!("LaqayInputWindow"),
                ..Default::default()
            };
            if RegisterClassW(&class) == 0 {
                return Err(Error::from_thread());
            }
            let handle = match CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("LaqayInputWindow"),
                w!("Laqay input observer"),
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
                    let _ = UnregisterClassW(w!("LaqayInputWindow"), Some(instance));
                    return Err(error);
                }
            };
            let _window = Window {
                handle,
                instance,
                raw_input: options.raw_input,
            };
            let _input = InputGuard(&state);
            if options.raw_input {
                RegisterRawInputDevices(
                    &[RAWINPUTDEVICE {
                        usUsagePage: 1,
                        usUsage: 6,
                        dwFlags: RIDEV_INPUTSINK,
                        hwndTarget: handle,
                    }],
                    size_of::<RAWINPUTDEVICE>() as u32,
                )?;
            }
            state.reconfigure()?;
            const READY: u32 = WM_APP + 1;
            PostMessageW(Some(handle), READY, WPARAM(0), LPARAM(0))?;
            let mut message = MSG::default();
            loop {
                match GetMessageW(&mut message, None, 0, 0).0 {
                    -1 => return Err(Error::from_thread()),
                    0 => break,
                    _ => {
                        if message.hwnd == handle && message.message == READY {
                            if activity.is_stopped() {
                                break;
                            }
                            if let Some(seconds) = options.seconds {
                                if SetTimer(Some(handle), 1, seconds * 1000, None) == 0 {
                                    return Err(Error::from_thread());
                                }
                            }
                            if let Some(sender) = ready.take() {
                                sender
                                    .send(Ok(handle.0 as usize))
                                    .map_err(|_| Error::from_hresult(E_INVALIDARG))?;
                            }
                            if options.diagnostics {
                                println!(
                                    "Ready. Observing native Ctrl+V for {} seconds; native paste remains enabled. Backend: {}; input_only={}.",
                                    options.seconds.unwrap_or(0),
                                    if options.use_hook { "hook" } else { "raw" },
                                    options.input_only
                                );
                                io::stdout()
                                    .flush()
                                    .map_err(|error| Error::new(E_INVALIDARG, error.to_string()))?;
                            }
                        } else {
                            DispatchMessageW(&message);
                        }
                    }
                }
            }
            Ok(())
        })()
    };
    activity.stop();
    if options.diagnostics {
        println!("Input summary: {:?}", state.counts);
        println!(
            "Hook callback entries: {}",
            HOOK_CALLBACKS.load(Ordering::Relaxed)
        );
    }
    drop(state);
    if let Some(worker) = worker {
        if worker_done_rx.recv_timeout(Duration::from_secs(1)).is_ok() {
            let _ = worker.join();
        }
    }
    if options.diagnostics {
        crate::probe_environment::log_environment("stopped");
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generic_modifier_scancodes_preserve_chord_semantics() {
        for extended in [false, true] {
            let mut keys = PasteKeys::default();
            let control = normalized_key(0x11, 0x1d, extended);
            keys.transition(control, true);
            assert!(keys.transition(normalized_key(0x56, 0x2f, false), true));
            keys.transition(0x56, false);
            keys.transition(control, false);
            assert!(!keys.transition(0x56, true));
        }
        for (code, scan, extended) in [
            (0x10, 0x2a, false),
            (0x10, 0x36, false),
            (0x12, 0x38, false),
            (0x12, 0x38, true),
        ] {
            let mut keys = PasteKeys::default();
            keys.transition(normalized_key(0x11, 0x1d, false), true);
            keys.transition(normalized_key(code, scan, extended), true);
            assert!(!keys.transition(0x56, true));
        }
    }
}
