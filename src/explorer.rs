//! Read-only Shell diagnostics. These observations do not authorize input suppression.

use crate::context::{
    ContextEvidence, FocusNode, FocusRole, ViewEvidence, select_focused_view,
    static_text_in_folder_list,
};
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
                CUIAutomation, IUIAutomation, IUIAutomationElement, TreeScope_Subtree,
                UIA_DataGridControlTypeId, UIA_DataItemControlTypeId, UIA_GroupControlTypeId,
                UIA_HasKeyboardFocusPropertyId, UIA_IsValuePatternAvailablePropertyId,
                UIA_ListControlTypeId, UIA_ListItemControlTypeId, UIA_PaneControlTypeId,
                UIA_TextControlTypeId,
            },
            Shell::{
                IFolderView, IPersistFolder2, IShellBrowser, IShellItem, IShellWindows,
                IWebBrowserApp, SHCreateItemFromIDList, SID_STopLevelBrowser, SIGDN_FILESYSPATH,
                ShellWindows,
            },
            WindowsAndMessaging::{
                GUITHREADINFO, GetClassNameW, GetForegroundWindow, GetGUIThreadInfo,
                GetWindowThreadProcessId, IsChild, IsWindowVisible,
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
    pub global_control_window: usize,
    pub native_control: Option<NativeControlObservation>,
    pub folder_items_focused: bool,
    pub unchanged: bool,
}

#[derive(Debug)]
pub struct NativeControlObservation {
    pub window: usize,
    pub win32_class: String,
    pub control_type: i32,
    pub provider_window: usize,
    pub has_keyboard_focus: bool,
    pub focused_descendant_type: Option<i32>,
}

fn inspect_control(automation: &IUIAutomation, window: HWND) -> Result<NativeControlObservation> {
    // SAFETY: The HWND is queried without changing state. UIA objects remain in
    // the caller's MTA. The class-name buffer is writable local storage; no text
    // contents, accessible names, values or clipboard data are requested.
    unsafe {
        let mut class = [0u16; 256];
        let length = GetClassNameW(window, &mut class);
        if length == 0 {
            return Err(windows::core::Error::from_thread());
        }
        let element = automation.ElementFromHandle(window)?;
        let condition = automation
            .CreatePropertyCondition(UIA_HasKeyboardFocusPropertyId, &VARIANT::from(true))?;
        let focused_descendant_type = element
            .FindFirst(TreeScope_Subtree, &condition)
            .and_then(|focused| focused.CurrentControlType())
            .ok()
            .map(|kind| kind.0);
        Ok(NativeControlObservation {
            window: window.0 as usize,
            win32_class: String::from_utf16_lossy(&class[..length as usize]),
            control_type: element.CurrentControlType()?.0,
            provider_window: element.CurrentNativeWindowHandle()?.0 as usize,
            has_keyboard_focus: element.CurrentHasKeyboardFocus()?.as_bool(),
            focused_descendant_type,
        })
    }
}

/// Inspect an explicitly supplied native control without activating its window.
/// This exposes structural metadata only and never authorizes a paste target.
pub fn inspect_native_control(window: usize) -> Result<NativeControlObservation> {
    std::thread::spawn(move || {
        let _apartment = Apartment::new(COINIT_MULTITHREADED)?;
        // SAFETY: The automation client is created and released on this MTA
        // worker. Only owned scalar/string observations return to the caller.
        let automation: IUIAutomation =
            unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_ALL)? };
        inspect_control(&automation, HWND(window as *mut _))
    })
    .join()
    .unwrap_or_else(|_| {
        Err(windows::core::Error::from_hresult(
            windows::Win32::Foundation::E_FAIL,
        ))
    })
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
        let global_control_window = focused.CurrentNativeWindowHandle()?.0 as usize;
        let mut info = GUITHREADINFO {
            cbSize: size_of::<GUITHREADINFO>() as u32,
            ..Default::default()
        };
        let native_control = GetGUIThreadInfo(
            GetWindowThreadProcessId(GetForegroundWindow(), None),
            &mut info,
        )
        .ok()
        .and_then(|_| inspect_control(&automation, info.hwndFocus).ok());
        let folder_items_focused = ([
            UIA_ListControlTypeId,
            UIA_ListItemControlTypeId,
            UIA_DataGridControlTypeId,
            UIA_DataItemControlTypeId,
        ]
        .contains(&kind)
            || (kind == UIA_TextControlTypeId
                && folder_text_path(&automation, &focused, info.hwndFocus)?))
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
            && after.CurrentIsEnabled()?.as_bool()
            && (kind != UIA_TextControlTypeId
                || folder_text_path(&automation, &after, info.hwndFocus)?);
        Ok(FocusObservation {
            control_type: kind.0,
            global_control_window,
            native_control,
            folder_items_focused,
            unchanged,
        })
    }
}

fn folder_text_path(
    automation: &IUIAutomation,
    focused: &IUIAutomationElement,
    native: HWND,
) -> Result<bool> {
    if native.is_invalid() {
        return Ok(false);
    }
    // SAFETY: All UIA elements and the tree walker remain on this MTA thread.
    // Only types, pattern availability and element identity are requested; no
    // names or values are read. Failure or a path longer than 32 nodes declines.
    unsafe {
        let root = automation.ElementFromHandle(native)?;
        let walker = automation.RawViewWalker()?;
        let mut current = focused.clone();
        let mut path = Vec::new();
        for _ in 0..32 {
            let kind = current.CurrentControlType()?;
            let role = [
                (UIA_TextControlTypeId, FocusRole::Text),
                (UIA_ListControlTypeId, FocusRole::List),
                (UIA_ListItemControlTypeId, FocusRole::ListItem),
                (UIA_DataGridControlTypeId, FocusRole::DataGrid),
                (UIA_DataItemControlTypeId, FocusRole::DataItem),
                (UIA_PaneControlTypeId, FocusRole::Pane),
                (UIA_GroupControlTypeId, FocusRole::Group),
            ]
            .into_iter()
            .find_map(|(control, role)| (control == kind).then_some(role))
            .unwrap_or(FocusRole::Other);
            let value =
                current.GetCurrentPropertyValueEx(UIA_IsValuePatternAvailablePropertyId, true)?;
            let value_pattern = bool::try_from(&value)?;
            path.push(FocusNode {
                role,
                value_pattern,
            });
            if role == FocusRole::Other || value_pattern || !current.CurrentIsEnabled()?.as_bool() {
                println!(
                    "Static text focus declined: ancestor_type={}, value_pattern={value_pattern}",
                    kind.0
                );
                return Ok(false);
            }
            if automation.CompareElements(&current, &root)?.as_bool() {
                return Ok(static_text_in_folder_list(&path, true));
            }
            current = walker.GetParentElement(&current)?;
        }
        println!("Static text focus declined: native list was not reached within 32 nodes");
        Ok(false)
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
        let semantic = match worker.join() {
            Ok(Ok(observation)) => Some(observation),
            Ok(Err(error)) => {
                eprintln!("Semantic focus declined: {error}");
                None
            }
            Err(_) => {
                eprintln!("Semantic focus declined: observation worker failed");
                None
            }
        };
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
