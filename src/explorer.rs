//! Read-only Shell diagnostics. These observations do not authorize input suppression.

use crate::context::{
    ContextEvidence, EmptyListEvidence, FocusNode, FocusRole, ValueAccess, ViewEvidence,
    native_empty_list, select_focused_view, static_text_in_folder_list,
};
use crate::file_writer::StagingLease;
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
                CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationValuePattern,
                TreeScope_Subtree, UIA_DataGridControlTypeId, UIA_DataItemControlTypeId,
                UIA_E_ELEMENTNOTAVAILABLE, UIA_GroupControlTypeId, UIA_HasKeyboardFocusPropertyId,
                UIA_IsValuePatternAvailablePropertyId, UIA_ListControlTypeId,
                UIA_ListItemControlTypeId, UIA_PaneControlTypeId, UIA_TextControlTypeId,
                UIA_ValuePatternId,
            },
            Shell::{
                IFolderView, IPersistFolder2, IShellBrowser, IShellFolder, IShellItem,
                IShellWindows, IWebBrowserApp, SHCreateItemFromIDList, SHCreateItemWithParent,
                SID_STopLevelBrowser, SIGDN_FILESYSPATH, SVGIO_ALLVIEW, ShellWindows,
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
    pub confirmed_empty: bool,
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
    pub empty_list_candidate: bool,
    pub unchanged: bool,
    pub identity_changed: bool,
    pub static_text_path: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub struct NativeControlObservation {
    pub window: usize,
    pub win32_class: String,
    pub control_type: i32,
    pub provider_window: usize,
    pub has_keyboard_focus: bool,
    pub focused_descendant_type: Option<i32>,
}

#[derive(Debug, PartialEq, Eq)]
struct EmptyListObservation {
    control: NativeControlObservation,
    provider_class: String,
    enabled: bool,
    value_access: ValueAccess,
    focused_count: i32,
}

fn inspect_empty_list(
    automation: &IUIAutomation,
    info: &GUITHREADINFO,
    diagnostics: bool,
) -> Result<Option<EmptyListObservation>> {
    if diagnostics {
        println!(
            "Empty list probe: native control, flags={}, menu={}, capture={}, move_size={}",
            info.flags.0,
            !info.hwndMenuOwner.is_invalid(),
            !info.hwndCapture.is_invalid(),
            !info.hwndMoveSize.is_invalid()
        );
    }
    let control = inspect_control(automation, info.hwndFocus)?;
    // SAFETY: The existing native focus control is queried on this MTA. No
    // accessible names, values, input, files or UI state are changed.
    let observation = unsafe {
        let element = automation.ElementFromHandle(info.hwndFocus)?;
        if diagnostics {
            println!("Empty list probe: value-pattern availability");
        }
        let value =
            element.GetCurrentPropertyValueEx(UIA_IsValuePatternAvailablePropertyId, true)?;
        let focused = automation
            .CreatePropertyCondition(UIA_HasKeyboardFocusPropertyId, &VARIANT::from(true))?;
        if diagnostics {
            println!("Empty list probe: focused subtree");
        }
        let focused_count = element.FindAll(TreeScope_Subtree, &focused)?.Length()?;
        EmptyListObservation {
            control,
            provider_class: element.CurrentClassName()?.to_string(),
            enabled: element.CurrentIsEnabled()?.as_bool(),
            value_access: if bool::try_from(&value)? {
                match element
                    .GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                    .and_then(|pattern| pattern.CurrentIsReadOnly())
                {
                    Ok(read_only) if read_only.as_bool() => ValueAccess::ReadOnly,
                    Ok(_) => ValueAccess::Writable,
                    Err(_) => ValueAccess::Unknown,
                }
            } else {
                ValueAccess::Absent
            },
            focused_count,
        }
    };
    if diagnostics {
        println!("Empty list provider: {observation:?}");
    }
    let eligible = native_empty_list(EmptyListEvidence {
        native_class: &observation.control.win32_class,
        provider_class: &observation.provider_class,
        provider_matches_focus: observation.control.window != 0
            && observation.control.provider_window == observation.control.window,
        role: if observation.control.control_type == UIA_ListControlTypeId.0 {
            FocusRole::List
        } else {
            FocusRole::Other
        },
        enabled: observation.enabled,
        value_access: observation.value_access,
        focused_descendant: observation.focused_count != 0
            || observation.control.focused_descendant_type.is_some(),
        menu_or_capture: info.flags.0 & 0x1e != 0
            || !info.hwndMenuOwner.is_invalid()
            || !info.hwndCapture.is_invalid()
            || !info.hwndMoveSize.is_invalid(),
    });
    Ok(eligible.then_some(observation))
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
    pub(crate) fn identity_refresh_directory(&self) -> Option<(&std::path::Path, usize)> {
        let semantic = self.semantic_focus.as_ref()?;
        let native = semantic.native_control.as_ref()?;
        if !semantic.identity_changed
            || semantic.unchanged
            || !semantic.static_text_path
            || semantic.control_type != UIA_TextControlTypeId.0
            || native.window != self.focus_window
            || native.provider_window != self.focus_window
            || native.win32_class != "DirectUIHWND"
            || native.control_type != UIA_ListControlTypeId.0
            || native.focused_descendant_type != Some(UIA_TextControlTypeId.0)
            || !self.foreground_unchanged
            || !self.native_focus_unchanged
            || self.unresolved_entries != 0
        {
            return None;
        }
        let mut views = self.observations.iter().filter(|view| view.contains_focus);
        let view = views.next()?;
        if views.next().is_some() || !view.visible {
            return None;
        }
        Some((view.directory.as_deref()?, view.view_window))
    }

    pub(crate) fn directory_view(&self, directory: &std::path::Path) -> Option<usize> {
        let mut views = self.observations.iter().filter(|view| view.contains_focus);
        let view = views.next()?;
        (views.next().is_none() && view.visible && view.directory.as_deref() == Some(directory))
            .then_some(view.view_window)
    }

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
                folder_items_focused: semantic.folder_items_focused
                    || (semantic.empty_list_candidate
                        && self.observations.iter().any(|view| {
                            view.visible && view.contains_focus && view.confirmed_empty
                        })),
                unresolved_entries: self.unresolved_entries,
            },
        )?;
        self.observations[index].directory.as_deref()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SemanticFocusCheck {
    ElementIdentity,
    ControlType,
    KeyboardFocus,
    Enabled,
    TextAncestry,
}

impl SemanticFocusCheck {
    const ORDER: [Self; 5] = [
        Self::ElementIdentity,
        Self::ControlType,
        Self::KeyboardFocus,
        Self::Enabled,
        Self::TextAncestry,
    ];
}

fn semantic_focus_change(
    diagnostics: bool,
    mut check: impl FnMut(SemanticFocusCheck) -> Result<bool>,
) -> Result<Option<SemanticFocusCheck>> {
    // Preserve short-circuit order: a rejected or unavailable element must not
    // receive later property queries just to produce a more detailed log.
    for step in SemanticFocusCheck::ORDER {
        let result = check(step);
        if diagnostics {
            match &result {
                Ok(false) => println!("Semantic focus changed: check={step:?}"),
                Err(error) => eprintln!(
                    "Semantic focus check failed: check={step:?}, hresult={:#010x}",
                    error.code().0 as u32
                ),
                Ok(true) => {}
            }
        }
        if !result? {
            return Ok(Some(step));
        }
    }
    Ok(None)
}

fn observe_semantic_focus(
    ready: mpsc::Sender<bool>,
    finish: mpsc::Receiver<()>,
    diagnostics: bool,
) -> Result<FocusObservation> {
    let _apartment = Apartment::new(COINIT_MULTITHREADED)?;
    // SAFETY: UI Automation objects are created, queried and released on this
    // windowless MTA worker. No COM interfaces cross thread or apartment boundaries.
    unsafe {
        let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_ALL)?;
        let focused = match automation.GetFocusedElement() {
            Ok(focused) => focused,
            Err(error) if error.code().0 as u32 == UIA_E_ELEMENTNOTAVAILABLE => {
                return observe_unavailable_empty_focus(&automation, ready, finish, diagnostics);
            }
            Err(error) => return Err(error),
        };
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
        let static_text_path = kind == UIA_TextControlTypeId
            && folder_text_path(&automation, &focused, info.hwndFocus, diagnostics)?;
        let folder_items_focused = ([
            UIA_ListControlTypeId,
            UIA_ListItemControlTypeId,
            UIA_DataGridControlTypeId,
            UIA_DataItemControlTypeId,
        ]
        .contains(&kind)
            || static_text_path)
            && focused.CurrentHasKeyboardFocus()?.as_bool()
            && focused.CurrentIsEnabled()?.as_bool();
        // Closing either channel cancels the handshake without retaining a worker.
        if ready.send(false).is_err() || finish.recv().is_err() {
            return Err(windows::core::Error::from_hresult(
                windows::Win32::Foundation::E_ABORT,
            ));
        }
        let after = automation.GetFocusedElement().inspect_err(|error| {
            if diagnostics {
                eprintln!(
                    "Semantic focus check failed: check=FocusedElement, hresult={:#010x}",
                    error.code().0 as u32
                );
            }
        })?;
        let change = semantic_focus_change(diagnostics, |step| match step {
            SemanticFocusCheck::ElementIdentity => {
                Ok(automation.CompareElements(&focused, &after)?.as_bool())
            }
            SemanticFocusCheck::ControlType => Ok(after.CurrentControlType()? == kind),
            SemanticFocusCheck::KeyboardFocus => Ok(after.CurrentHasKeyboardFocus()?.as_bool()),
            SemanticFocusCheck::Enabled => Ok(after.CurrentIsEnabled()?.as_bool()),
            SemanticFocusCheck::TextAncestry => Ok(kind != UIA_TextControlTypeId
                || folder_text_path(&automation, &after, info.hwndFocus, diagnostics)?),
        })?;
        Ok(FocusObservation {
            control_type: kind.0,
            global_control_window,
            native_control,
            folder_items_focused,
            empty_list_candidate: false,
            unchanged: change.is_none(),
            identity_changed: change == Some(SemanticFocusCheck::ElementIdentity),
            static_text_path,
        })
    }
}

fn observe_unavailable_empty_focus(
    automation: &IUIAutomation,
    ready: mpsc::Sender<bool>,
    finish: mpsc::Receiver<()>,
    diagnostics: bool,
) -> Result<FocusObservation> {
    // SAFETY: Both native snapshots and UIA observations are read on this MTA.
    // The Shell thread must independently confirm the single focused view is
    // a physical folder with zero items during this handshake.
    unsafe {
        let declined = || windows::core::Error::from_hresult(windows::Win32::Foundation::E_ABORT);
        let foreground = GetForegroundWindow();
        let thread = GetWindowThreadProcessId(foreground, None);
        let mut before = GUITHREADINFO {
            cbSize: size_of::<GUITHREADINFO>() as u32,
            ..Default::default()
        };
        GetGUIThreadInfo(thread, &mut before)?;
        let initial = inspect_empty_list(automation, &before, diagnostics)?.ok_or_else(declined)?;
        if ready.send(true).is_err() || finish.recv().is_err() {
            return Err(declined());
        }
        let mut after = GUITHREADINFO {
            cbSize: size_of::<GUITHREADINFO>() as u32,
            ..Default::default()
        };
        GetGUIThreadInfo(thread, &mut after)?;
        let unavailable = matches!(automation.GetFocusedElement(), Err(error) if error.code().0 as u32 == UIA_E_ELEMENTNOTAVAILABLE);
        let unchanged = unavailable
            && GetForegroundWindow() == foreground
            && before.hwndFocus == after.hwndFocus
            && inspect_empty_list(automation, &after, diagnostics)?.as_ref() == Some(&initial);
        Ok(FocusObservation {
            control_type: initial.control.control_type,
            global_control_window: 0,
            native_control: Some(initial.control),
            folder_items_focused: false,
            empty_list_candidate: true,
            unchanged,
            identity_changed: false,
            static_text_path: false,
        })
    }
}

fn folder_text_path(
    automation: &IUIAutomation,
    focused: &IUIAutomationElement,
    native: HWND,
    diagnostics: bool,
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
            let value_access = if value_pattern {
                match current
                    .GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                    .and_then(|pattern| pattern.CurrentIsReadOnly())
                {
                    Ok(read_only) if read_only.as_bool() => ValueAccess::ReadOnly,
                    Ok(_) => ValueAccess::Writable,
                    Err(error) => {
                        if diagnostics {
                            eprintln!("Static text focus: cannot determine value access: {error}");
                        }
                        ValueAccess::Unknown
                    }
                }
            } else {
                ValueAccess::Absent
            };
            if diagnostics {
                println!(
                    "Static text focus node: control_type={}, value_access={value_access:?}",
                    kind.0
                );
            }
            path.push(FocusNode { role, value_access });
            if role == FocusRole::Other
                || matches!(value_access, ValueAccess::Writable | ValueAccess::Unknown)
                || !current.CurrentIsEnabled()?.as_bool()
            {
                if diagnostics {
                    println!(
                        "Static text focus declined: ancestor_type={}, value_access={value_access:?}",
                        kind.0
                    );
                }
                return Ok(false);
            }
            if automation.CompareElements(&current, &root)?.as_bool() {
                return Ok(static_text_in_folder_list(&path, true));
            }
            current = walker.GetParentElement(&current)?;
        }
        if diagnostics {
            println!("Static text focus declined: native list was not reached within 32 nodes");
        }
        Ok(false)
    }
}

/// Enumerate Shell views associated with the foreground window.
/// A focused descendant can still be an editable control, including a rename box.
/// Callers must not interpret this diagnostic snapshot as a safe paste target.
pub fn observe_foreground() -> Result<ExplorerSnapshot> {
    observe_with_diagnostics(true)
}

pub(crate) fn observe_with_diagnostics(diagnostics: bool) -> Result<ExplorerSnapshot> {
    observe_for_publication(diagnostics, None)
}

pub(crate) fn observe_for_publication(
    diagnostics: bool,
    staging: Option<&StagingLease>,
) -> Result<ExplorerSnapshot> {
    std::thread::scope(|scope| {
        let (ready_tx, ready_rx) = mpsc::channel();
        let (finish_tx, finish_rx) = mpsc::channel();
        let worker = scope.spawn(move || observe_semantic_focus(ready_tx, finish_rx, diagnostics));
        let readiness = ready_rx.recv();
        let ready = readiness.is_ok();
        let result = observe_shell(readiness.unwrap_or(false), diagnostics, staging);
        let _ = finish_tx.send(());
        let semantic = match worker.join() {
            Ok(Ok(observation)) => Some(observation),
            Ok(Err(error)) => {
                if diagnostics {
                    eprintln!("Semantic focus declined: {error}");
                }
                None
            }
            Err(_) => {
                if diagnostics {
                    eprintln!("Semantic focus declined: observation worker failed");
                }
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

pub(crate) fn view_is_logically_empty(
    count: i32,
    staging: Option<&StagingLease>,
    item_path: impl FnOnce() -> Result<PathBuf>,
) -> Result<bool> {
    match count {
        0 => Ok(true),
        1 => match staging {
            Some(lease) => Ok(lease.matches_view_item(&item_path()?)),
            None => Ok(false),
        },
        _ => Ok(false),
    }
}

fn view_has_no_foreign_items(
    view: &IFolderView,
    staging: Option<&StagingLease>,
    diagnostics: bool,
) -> Result<bool> {
    // SAFETY: These interfaces and PIDLs remain on the Shell STA. The relative
    // child PIDL is freed after creating an independently owned Shell item.
    unsafe {
        let count = view.ItemCount(SVGIO_ALLVIEW)?;
        let empty = view_is_logically_empty(count, staging, || {
            let child = view.Item(0)?;
            let item_result: Result<IShellItem> = view
                .GetFolder::<IShellFolder>()
                .and_then(|parent| SHCreateItemWithParent(None, &parent, child));
            CoTaskMemFree(Some(child.cast()));
            let name = item_result?.GetDisplayName(SIGDN_FILESYSPATH)?;
            let path = name.to_string();
            CoTaskMemFree(Some(name.0.cast()));
            let path = path?;
            Ok(PathBuf::from(path))
        })?;
        if diagnostics && count == 1 && empty {
            println!("Empty Shell view: verified owned staging entry excluded");
        }
        Ok(empty)
    }
}

fn observe_shell(
    check_empty: bool,
    diagnostics: bool,
    staging: Option<&StagingLease>,
) -> Result<ExplorerSnapshot> {
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
                let initially_empty =
                    check_empty && view_has_no_foreign_items(&folder_view, staging, diagnostics)?;
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
                let confirmed_empty = initially_empty
                    && view_has_no_foreign_items(&folder_view, staging, diagnostics)?;
                if diagnostics && check_empty {
                    println!(
                        "Empty Shell view: initially_empty={initially_empty}, confirmed_empty={confirmed_empty}, filesystem={}, contains_focus={}",
                        directory.is_some(),
                        view_window == info.hwndFocus
                            || IsChild(view_window, info.hwndFocus).as_bool()
                    );
                }
                Ok(Some(ShellObservation {
                    browser_window: browser_window.0 as usize,
                    view_window: view_window.0 as usize,
                    visible: IsWindowVisible(view_window).as_bool(),
                    contains_focus: view_window == info.hwndFocus
                        || IsChild(view_window, info.hwndFocus).as_bool(),
                    directory,
                    confirmed_empty,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semantic_checks_stop_at_each_changed_property() {
        for diagnostics in [false, true] {
            for (index, changed) in SemanticFocusCheck::ORDER.into_iter().enumerate() {
                let mut observed = Vec::new();
                let change = semantic_focus_change(diagnostics, |step| {
                    observed.push(step);
                    Ok(step != changed)
                })
                .unwrap();
                assert_eq!(change, Some(changed));
                assert_eq!(observed, SemanticFocusCheck::ORDER[..=index]);
            }
        }
    }

    #[test]
    fn semantic_checks_preserve_provider_errors_without_later_queries() {
        for diagnostics in [false, true] {
            for (index, unavailable) in SemanticFocusCheck::ORDER.into_iter().enumerate() {
                let mut observed = Vec::new();
                let result = semantic_focus_change(diagnostics, |step| {
                    observed.push(step);
                    if step == unavailable {
                        Err(windows::core::Error::from_hresult(windows::core::HRESULT(
                            UIA_E_ELEMENTNOTAVAILABLE as i32,
                        )))
                    } else {
                        Ok(true)
                    }
                });
                assert_eq!(
                    result.unwrap_err().code().0 as u32,
                    UIA_E_ELEMENTNOTAVAILABLE
                );
                assert_eq!(observed, SemanticFocusCheck::ORDER[..=index]);
            }
        }
    }

    #[test]
    fn semantic_checks_require_every_property_in_original_order() {
        for diagnostics in [false, true] {
            let mut observed = Vec::new();
            assert!(
                semantic_focus_change(diagnostics, |step| {
                    observed.push(step);
                    Ok(true)
                })
                .unwrap()
                .is_none()
            );
            assert_eq!(
                observed,
                [
                    SemanticFocusCheck::ElementIdentity,
                    SemanticFocusCheck::ControlType,
                    SemanticFocusCheck::KeyboardFocus,
                    SemanticFocusCheck::Enabled,
                    SemanticFocusCheck::TextAncestry,
                ]
            );
        }
    }

    fn empty_snapshot() -> ExplorerSnapshot {
        ExplorerSnapshot {
            foreground_window: 1,
            focus_window: 3,
            foreground_unchanged: true,
            native_focus_unchanged: true,
            semantic_focus: Some(FocusObservation {
                control_type: UIA_ListControlTypeId.0,
                global_control_window: 0,
                native_control: None,
                folder_items_focused: false,
                empty_list_candidate: true,
                unchanged: true,
                identity_changed: false,
                static_text_path: false,
            }),
            observations: vec![ShellObservation {
                browser_window: 1,
                view_window: 2,
                visible: true,
                contains_focus: true,
                directory: Some(PathBuf::from(r"C:\case")),
                confirmed_empty: true,
            }],
            unresolved_entries: 0,
        }
    }

    fn changing_text_snapshot() -> ExplorerSnapshot {
        let mut snapshot = empty_snapshot();
        let semantic = snapshot.semantic_focus.as_mut().unwrap();
        semantic.control_type = UIA_TextControlTypeId.0;
        semantic.unchanged = false;
        semantic.identity_changed = true;
        semantic.static_text_path = true;
        semantic.empty_list_candidate = false;
        semantic.native_control = Some(NativeControlObservation {
            window: 3,
            provider_window: 3,
            win32_class: "DirectUIHWND".into(),
            control_type: UIA_ListControlTypeId.0,
            has_keyboard_focus: false,
            focused_descendant_type: Some(UIA_TextControlTypeId.0),
        });
        snapshot
    }

    #[test]
    fn changing_read_only_text_needs_a_new_observation_not_permission_to_publish() {
        let snapshot = changing_text_snapshot();
        assert_eq!(snapshot.diagnostic_directory(), None);
        assert_eq!(
            snapshot.identity_refresh_directory(),
            Some((std::path::Path::new(r"C:\case"), 2))
        );
    }

    #[test]
    fn identity_refresh_rejects_missing_or_changed_native_and_semantic_evidence() {
        let changes: [fn(&mut ExplorerSnapshot); 15] = [
            |s| s.semantic_focus.as_mut().unwrap().identity_changed = false,
            |s| s.semantic_focus.as_mut().unwrap().static_text_path = false,
            |s| s.semantic_focus.as_mut().unwrap().unchanged = true,
            |s| s.semantic_focus.as_mut().unwrap().control_type = 50004,
            |s| s.semantic_focus.as_mut().unwrap().native_control = None,
            |s| {
                s.semantic_focus
                    .as_mut()
                    .unwrap()
                    .native_control
                    .as_mut()
                    .unwrap()
                    .window = 9
            },
            |s| {
                s.semantic_focus
                    .as_mut()
                    .unwrap()
                    .native_control
                    .as_mut()
                    .unwrap()
                    .provider_window = 9
            },
            |s| {
                s.semantic_focus
                    .as_mut()
                    .unwrap()
                    .native_control
                    .as_mut()
                    .unwrap()
                    .win32_class = "Edit".into()
            },
            |s| {
                s.semantic_focus
                    .as_mut()
                    .unwrap()
                    .native_control
                    .as_mut()
                    .unwrap()
                    .focused_descendant_type = Some(50004)
            },
            |s| s.foreground_unchanged = false,
            |s| s.native_focus_unchanged = false,
            |s| s.unresolved_entries = 1,
            |s| s.observations[0].visible = false,
            |s| s.observations[0].directory = None,
            |s| {
                s.observations
                    .push(empty_snapshot().observations.pop().unwrap())
            },
        ];
        for change in changes {
            let mut snapshot = changing_text_snapshot();
            change(&mut snapshot);
            assert!(snapshot.identity_refresh_directory().is_none());
        }
    }

    #[test]
    fn empty_list_still_requires_complete_view_and_focus_evidence() {
        assert_eq!(
            empty_snapshot().diagnostic_directory(),
            Some(std::path::Path::new(r"C:\case"))
        );
        let changes: [fn(&mut ExplorerSnapshot); 10] = [
            |s| s.observations[0].confirmed_empty = false,
            |s| s.observations[0].visible = false,
            |s| s.observations[0].contains_focus = false,
            |s| s.observations[0].directory = None,
            |s| s.semantic_focus.as_mut().unwrap().empty_list_candidate = false,
            |s| s.semantic_focus.as_mut().unwrap().unchanged = false,
            |s| s.foreground_unchanged = false,
            |s| s.native_focus_unchanged = false,
            |s| s.unresolved_entries = 1,
            |s| {
                s.observations
                    .push(empty_snapshot().observations.pop().unwrap())
            },
        ];
        for change in changes {
            let mut snapshot = empty_snapshot();
            change(&mut snapshot);
            assert_eq!(snapshot.diagnostic_directory(), None);
        }
    }

    #[test]
    fn existing_semantic_focus_does_not_require_an_empty_view() {
        let mut snapshot = empty_snapshot();
        snapshot.observations[0].confirmed_empty = false;
        let focus = snapshot.semantic_focus.as_mut().unwrap();
        focus.empty_list_candidate = false;
        focus.folder_items_focused = true;
        assert_eq!(
            snapshot.diagnostic_directory(),
            Some(std::path::Path::new(r"C:\case"))
        );
    }
}
