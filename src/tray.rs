//! Native notification icon and its three-item menu.

use windows::{
    Win32::{
        Foundation::{E_FAIL, HINSTANCE, HWND, LPARAM, POINT, WPARAM},
        UI::{Shell::*, WindowsAndMessaging::*},
    },
    core::{Error, PCWSTR, Result, w},
};

pub(crate) const CALLBACK: u32 = WM_APP + 10;
pub(crate) const ENABLED: u32 = 1001;
pub(crate) const STARTUP: u32 = 1002;
pub(crate) const EXIT: u32 = 1003;

struct Icon(HICON);
impl Drop for Icon {
    fn drop(&mut self) {
        // SAFETY: LoadImageW below does not use LR_SHARED; this handle is owned.
        let _ = unsafe { DestroyIcon(self.0) };
    }
}

fn load_icon(instance: HINSTANCE, enabled: bool) -> Result<Icon> {
    let resource = if enabled { 1usize } else { 2 };
    // SAFETY: The integer pointer is a resource identifier, never dereferenced
    // by Rust. Both icon groups are embedded in the application executable.
    unsafe {
        let size = GetSystemMetrics(SM_CXSMICON).max(16);
        LoadImageW(
            Some(instance),
            PCWSTR(resource as *const u16),
            IMAGE_ICON,
            size,
            size,
            LR_DEFAULTCOLOR,
        )
        .map(|handle| Icon(HICON(handle.0)))
    }
}

fn tooltip(enabled: bool, trial: bool) -> [u16; 128] {
    let text = match (trial, enabled) {
        (false, true) => "Laqay (enabled)",
        (false, false) => "Laqay (disabled)",
        (true, true) => "Laqay (trial, enabled)",
        (true, false) => "Laqay (trial, disabled)",
    };
    let mut output = [0; 128];
    for (slot, unit) in output.iter_mut().zip(text.encode_utf16()) {
        *slot = unit;
    }
    output
}

pub(crate) struct Tray {
    window: HWND,
    instance: HINSTANCE,
    icon: Icon,
    enabled: bool,
    trial: bool,
}

impl Tray {
    pub fn new(window: HWND, instance: HINSTANCE, enabled: bool, trial: bool) -> Result<Self> {
        let tray = Self {
            window,
            instance,
            icon: load_icon(instance, enabled)?,
            enabled,
            trial,
        };
        tray.add()?;
        Ok(tray)
    }
    fn data(&self) -> NOTIFYICONDATAW {
        NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.window,
            uID: 1,
            uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP,
            uCallbackMessage: CALLBACK,
            hIcon: self.icon.0,
            szTip: tooltip(self.enabled, self.trial),
            ..Default::default()
        }
    }
    pub fn add(&self) -> Result<()> {
        let mut data = self.data();
        // SAFETY: Live owned icon/window and correctly sized synchronous data.
        // HWND+ID avoids tying a portable unsigned executable to a fixed path.
        unsafe {
            if !Shell_NotifyIconW(NIM_ADD, &data).as_bool() {
                return Err(Error::new(E_FAIL, "Could not add the notification icon"));
            }
            data.Anonymous.uVersion = NOTIFYICON_VERSION_4;
            if !Shell_NotifyIconW(NIM_SETVERSION, &data).as_bool() {
                let _ = Shell_NotifyIconW(NIM_DELETE, &data);
                return Err(Error::new(
                    E_FAIL,
                    "Could not initialize the notification icon",
                ));
            }
        }
        Ok(())
    }
    pub fn set_enabled(&mut self, enabled: bool) -> Result<()> {
        let icon = load_icon(self.instance, enabled)?;
        let mut data = self.data();
        data.hIcon = icon.0;
        data.szTip = tooltip(enabled, self.trial);
        // SAFETY: The new icon stays alive through modification and then
        // replaces the old owned icon only after successful publication.
        if !unsafe { Shell_NotifyIconW(NIM_MODIFY, &data) }.as_bool() {
            return Err(Error::new(E_FAIL, "Could not update the notification icon"));
        }
        self.icon = icon;
        self.enabled = enabled;
        Ok(())
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        // SAFETY: Removes only this application's icon before its window and
        // owned HICON are destroyed. It does not alter taskbar preferences.
        let _ = unsafe { Shell_NotifyIconW(NIM_DELETE, &self.data()) };
    }
}

struct Menu(HMENU);
impl Drop for Menu {
    fn drop(&mut self) {
        // SAFETY: Menu owns the temporary popup created for this invocation.
        let _ = unsafe { DestroyMenu(self.0) };
    }
}

pub(crate) fn show_menu(
    window: HWND,
    enabled: bool,
    startup: bool,
    trial: bool,
    coordinates: WPARAM,
) -> Result<u32> {
    // SAFETY: The menu and coordinates are local; only our hidden window is
    // made foreground in response to the user's tray activation. No key or
    // mouse event is synthesized. No State borrow spans the nested menu loop.
    unsafe {
        let menu = Menu(CreatePopupMenu()?);
        AppendMenuW(
            menu.0,
            MF_STRING | if enabled { MF_CHECKED } else { MF_UNCHECKED },
            ENABLED as usize,
            w!("Enabled"),
        )?;
        AppendMenuW(
            menu.0,
            MF_STRING
                | if startup { MF_CHECKED } else { MF_UNCHECKED }
                | if trial { MF_GRAYED } else { MF_ENABLED },
            STARTUP as usize,
            w!("Start with Windows"),
        )?;
        AppendMenuW(menu.0, MF_STRING, EXIT as usize, w!("Exit"))?;
        let mut point = POINT {
            x: (coordinates.0 as u16 as i16) as i32,
            y: ((coordinates.0 >> 16) as u16 as i16) as i32,
        };
        if point.x == -1 && point.y == -1 {
            let id = NOTIFYICONIDENTIFIER {
                cbSize: size_of::<NOTIFYICONIDENTIFIER>() as u32,
                hWnd: window,
                uID: 1,
                ..Default::default()
            };
            if let Ok(rect) = Shell_NotifyIconGetRect(&id) {
                point.x = rect.left;
                point.y = rect.bottom;
            } else {
                GetCursorPos(&mut point)?;
            }
        }
        let _ = SetForegroundWindow(window);
        let command = TrackPopupMenu(
            menu.0,
            TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
            point.x,
            point.y,
            None,
            window,
            None,
        )
        .0 as u32;
        let _ = PostMessageW(Some(window), WM_NULL, WPARAM(0), LPARAM(0));
        Ok(command)
    }
}
