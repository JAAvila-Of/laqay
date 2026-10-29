//! Read-only Shell diagnostics. These observations do not authorize input suppression.

use crate::context::{ContextEvidence, ViewEvidence, select_focused_view};
use std::path::PathBuf;
use std::sync::mpsc;
use windows::{
    Win32::{
        Foundation::HWND,
        System::{
            Com::{
                CLSCTX_ALL, COINIT, COINIT_APARTMENTTHREADED, COINIT_MULTITHREADED,
                CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, IServiceProvider,
            },
            Variant::VARIANT,
        },
        UI::{
            Accessibility::{
                CUIAutomation, IUIAutomation, UIA_DataGridControlTypeId, UIA_DataItemControlTypeId,
                UIA_ListControlTypeId, UIA_ListItemControlTypeId,
            },
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
    fn new(model: COINIT) -> Result<Self> {
        // SAFETY: This thread initializes COM once; the guard balances every success.
        unsafe { CoInitializeEx(None, model).ok()? };
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
    pub native_focus_unchanged: bool,
    pub semantic_focus: Option<FocusObservation>,
    pub observations: Vec<ShellObservation>,
    pub unresolved_entries: usize,
}

#[derive(Debug)]
pub struct FocusObservation {
    pub control_type: i32,
    pub folder_items_focused: bool,
    pub unchanged: bool,
}

impl ExplorerSnapshot {
    /// Return an observed directory only; this is not permission to swallow input.
    pub fn diagnostic_directory(&self) -> Option<&std::path::Path> {
        let semantic = self.semantic_focus.as_ref()?;
        let views: Vec<_> = self
            .observations
            .iter()
            .map(|view| ViewEvidence {
                contains_focus: view.contains_focus,
                filesystem: view.directory.is_some(),
            })
            .collect();
        let index = select_focused_view(
            &views,
            ContextEvidence {
                foreground_stable: self.foreground_unchanged,
                native_focus_stable: self.native_focus_unchanged,
                semantic_focus_stable: semantic.unchanged,
                folder_items_focused: semantic.folder_items_focused,
                unresolved_entries: self.unresolved_entries,
            },
        )?;
        self.observations[index].directory.as_deref()
    }
}

fn observe_semantic_focus(
    ready: mpsc::Sender<()>,
    finish: mpsc::Receiver<()>,
) -> Result<FocusObservation> {
    let _apartment = Apartment::new(COINIT_MULTITHREADED)?;
    // SAFETY: UI Automation objects are created, queried and released on this
    // windowless MTA worker. No COM interfaces cross thread or apartment boundaries.
    unsafe {
        let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_ALL)?;
        let focused = automation.GetFocusedElement()?;
        let kind = focused.CurrentControlType()?;
        let folder_items_focused = [
            UIA_ListControlTypeId,
            UIA_ListItemControlTypeId,
            UIA_DataGridControlTypeId,
            UIA_DataItemControlTypeId,
        ]
        .contains(&kind)
            && focused.CurrentHasKeyboardFocus()?.as_bool()
            && focused.CurrentIsEnabled()?.as_bool();
        // Closing either channel cancels the handshake without retaining a worker.
        if ready.send(()).is_err() || finish.recv().is_err() {
            return Err(windows::core::Error::from_hresult(
                windows::Win32::Foundation::E_ABORT,
            ));
        }
        let after = automation.GetFocusedElement()?;
        let unchanged = automation.CompareElements(&focused, &after)?.as_bool()
            && after.CurrentControlType()? == kind
            && after.CurrentHasKeyboardFocus()?.as_bool()
            && after.CurrentIsEnabled()?.as_bool();
        Ok(FocusObservation {
            control_type: kind.0,
            folder_items_focused,
            unchanged,
        })
    }
}

/// Enumerate Shell views associated with the foreground window.
/// A focused descendant can still be an editable control, including a rename box.
/// Callers must not interpret this diagnostic snapshot as a safe paste target.
pub fn observe_foreground() -> Result<ExplorerSnapshot> {
    std::thread::scope(|scope| {
        let (ready_tx, ready_rx) = mpsc::channel();
        let (finish_tx, finish_rx) = mpsc::channel();
        let worker = scope.spawn(move || observe_semantic_focus(ready_tx, finish_rx));
        let ready = ready_rx.recv().is_ok();
        let result = observe_shell();
        let _ = finish_tx.send(());
        let semantic = worker.join().ok().and_then(Result::ok);
        let mut snapshot = result?;
        if ready {
            snapshot.semantic_focus = semantic;
        }
        // SAFETY: These APIs only inspect existing windows; the out-parameter is
        // initialized local storage. Invalid or vanished windows reject stability.
        unsafe {
            let foreground = GetForegroundWindow();
            snapshot.foreground_unchanged &= foreground.0 as usize == snapshot.foreground_window;
            let mut info = GUITHREADINFO {
                cbSize: size_of::<GUITHREADINFO>() as u32,
                ..Default::default()
            };
            snapshot.native_focus_unchanged &=
                GetGUIThreadInfo(GetWindowThreadProcessId(foreground, None), &mut info).is_ok()
                    && info.hwndFocus.0 as usize == snapshot.focus_window;
        }
        Ok(snapshot)
    })
}

fn observe_shell() -> Result<ExplorerSnapshot> {
    let _apartment = Apartment::new(COINIT_APARTMENTTHREADED)?;
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
        let mut after = GUITHREADINFO {
            cbSize: size_of::<GUITHREADINFO>() as u32,
            ..Default::default()
        };
        let native_focus_unchanged =
            GetGUIThreadInfo(thread, &mut after).is_ok() && after.hwndFocus == info.hwndFocus;
        Ok(ExplorerSnapshot {
            foreground_window: foreground.0 as usize,
            focus_window: info.hwndFocus.0 as usize,
            foreground_unchanged: GetForegroundWindow() == foreground,
            native_focus_unchanged,
            semantic_focus: None,
            observations,
            unresolved_entries,
        })
    }
}
