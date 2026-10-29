//! Read-only Shell diagnostics. These observations do not authorize input suppression.

use std::path::PathBuf;
use windows::{
    Win32::{
        Foundation::HWND,
        System::{
            Com::{
                CLSCTX_ALL, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx,
                CoTaskMemFree, CoUninitialize, IServiceProvider,
            },
            Variant::VARIANT,
        },
        UI::{
            Shell::{
                IFolderView, IPersistFolder2, IShellBrowser, IShellItem, IShellWindows,
                IWebBrowserApp, SHCreateItemFromIDList, SID_STopLevelBrowser, SIGDN_FILESYSPATH,
                ShellWindows,
            },
            WindowsAndMessaging::{
                GUITHREADINFO, GetForegroundWindow, GetGUIThreadInfo, GetWindowThreadProcessId,
                IsChild, IsWindowVisible,
            },
        },
    },
    core::{Interface, Result},
};

struct Apartment;

impl Apartment {
    fn new() -> Result<Self> {
        // SAFETY: This thread initializes COM once; the guard balances every success.
        unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok()? };
        Ok(Self)
    }
}

impl Drop for Apartment {
    fn drop(&mut self) {
        // SAFETY: The guard is thread-local and all COM interfaces have been dropped.
        unsafe { CoUninitialize() };
    }
}

#[derive(Debug)]
pub struct ShellObservation {
    pub browser_window: usize,
    pub view_window: usize,
    pub visible: bool,
    pub contains_focus: bool,
    pub directory: Option<PathBuf>,
}

#[derive(Debug)]
pub struct ExplorerSnapshot {
    pub foreground_window: usize,
    pub focus_window: usize,
    pub foreground_unchanged: bool,
    pub observations: Vec<ShellObservation>,
    pub unresolved_entries: usize,
}

/// Enumerate Shell views associated with the foreground window.
/// A focused descendant can still be an editable control, including a rename box.
/// Callers must not interpret this diagnostic snapshot as a safe paste target.
pub fn observe_foreground() -> Result<ExplorerSnapshot> {
    let _apartment = Apartment::new()?;
    // SAFETY: All out-parameters point to initialized local storage. COM interfaces
    // stay on this STA thread and are dropped before the apartment guard. Allocated
    // PIDLs and display-name buffers are freed with the documented COM allocator.
    unsafe {
        let foreground = GetForegroundWindow();
        let thread = GetWindowThreadProcessId(foreground, None);
        let mut info = GUITHREADINFO {
            cbSize: size_of::<GUITHREADINFO>() as u32,
            ..Default::default()
        };
        GetGUIThreadInfo(thread, &mut info)?;
        let shell: IShellWindows = CoCreateInstance(&ShellWindows, None, CLSCTX_ALL)?;
        let mut observations = Vec::new();
        let mut unresolved_entries = 0;
        for index in 0..shell.Count()? {
            let entry = (|| -> Result<Option<ShellObservation>> {
                let browser: IWebBrowserApp = shell.Item(&VARIANT::from(index))?.cast()?;
                let browser_window = HWND(browser.HWND()?.0 as *mut _);
                if browser_window != foreground {
                    return Ok(None);
                }
                let provider: IServiceProvider = browser.cast()?;
                let shell_browser: IShellBrowser = provider.QueryService(&SID_STopLevelBrowser)?;
                let view = shell_browser.QueryActiveShellView()?;
                let view_window = view.GetWindow()?;
                let folder_view: IFolderView = view.cast()?;
                let folder: IPersistFolder2 = folder_view.GetFolder()?;
                let pidl = folder.GetCurFolder()?;
                let item_result: Result<IShellItem> = SHCreateItemFromIDList(pidl);
                CoTaskMemFree(Some(pidl.cast()));
                let item = item_result?;
                let directory = match item.GetDisplayName(SIGDN_FILESYSPATH) {
                    Ok(name) => {
                        let path = name.to_string();
                        CoTaskMemFree(Some(name.0.cast()));
                        Some(PathBuf::from(path?))
                    }
                    Err(_) => None,
                };
                Ok(Some(ShellObservation {
                    browser_window: browser_window.0 as usize,
                    view_window: view_window.0 as usize,
                    visible: IsWindowVisible(view_window).as_bool(),
                    contains_focus: view_window == info.hwndFocus
                        || IsChild(view_window, info.hwndFocus).as_bool(),
                    directory,
                }))
            })();
            match entry {
                Ok(Some(observation)) => observations.push(observation),
                Ok(None) => {}
                Err(_) => unresolved_entries += 1,
            }
        }
        Ok(ExplorerSnapshot {
            foreground_window: foreground.0 as usize,
            focus_window: info.hwndFocus.0 as usize,
            foreground_unchanged: GetForegroundWindow() == foreground,
            observations,
            unresolved_entries,
        })
    }
}
