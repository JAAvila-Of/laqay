//! Native tray application. Calling run starts live clipboard handling.

use crate::{
    activity::Activity,
    runtime::{self, Observer},
    settings,
    tray::{self, Tray},
};
use std::{
    cell::{Cell, RefCell},
    ffi::OsString,
    path::PathBuf,
    sync::Arc,
};
use windows::{
    Win32::{
        Foundation::{E_INVALIDARG, E_UNEXPECTED, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM},
        System::LibraryLoader::GetModuleHandleW,
        UI::{
            Shell::{NIN_SELECT, NINF_KEY},
            WindowsAndMessaging::*,
        },
    },
    core::{Error, PCWSTR, Result, w},
};

#[derive(Debug)]
struct Trial {
    seconds: u32,
    directory: PathBuf,
}

fn parse_trial(arguments: &[OsString]) -> Result<Option<Trial>> {
    if arguments.is_empty() {
        return Ok(None);
    }
    if arguments.len() != 3 || arguments[0] != "--trial" {
        return Err(Error::new(
            E_INVALIDARG,
            "Usage: laqay --trial <1-30 seconds> <existing absolute folder>",
        ));
    }
    let seconds = arguments[1]
        .to_str()
        .and_then(|text| text.parse::<u32>().ok())
        .filter(|seconds| (1..=30).contains(seconds))
        .ok_or_else(|| Error::from_hresult(E_INVALIDARG))?;
    let directory = PathBuf::from(&arguments[2]);
    if !directory.is_absolute() {
        return Err(Error::from_hresult(E_INVALIDARG));
    }
    Ok(Some(Trial { seconds, directory }))
}

struct State {
    activity: Arc<Activity>,
    observer: RefCell<Option<Observer>>,
    tray: RefCell<Option<Tray>>,
    startup: Cell<bool>,
    trial: bool,
    taskbar_created: u32,
}

fn message(window: HWND, text: &str, flags: MESSAGEBOX_STYLE) {
    let text: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    // SAFETY: The UTF-16 buffer lives through the modal, user-dismissable call.
    // This is used only for real launch/settings failures, not paste declines.
    unsafe {
        MessageBoxW(
            Some(window),
            PCWSTR(text.as_ptr()),
            w!("Laqay"),
            MB_OK | flags,
        );
    }
}

impl State {
    fn update_icon(&self) -> Result<()> {
        if let Some(tray) = self
            .tray
            .try_borrow_mut()
            .map_err(|_| Error::from_hresult(E_UNEXPECTED))?
            .as_mut()
        {
            tray.set_enabled(self.activity.ticket().is_some())?;
        }
        Ok(())
    }
    fn command(&self, window: HWND, command: u32) -> Result<()> {
        if self.activity.is_stopped() {
            return Ok(());
        }
        if command == tray::ENABLED {
            let enabled = self.activity.ticket().is_none();
            self.activity.set_enabled(enabled);
            let result = self
                .observer
                .try_borrow()
                .map_err(|_| Error::from_hresult(E_UNEXPECTED))?
                .as_ref()
                .ok_or_else(|| Error::from_hresult(E_UNEXPECTED))?
                .refresh();
            if let Err(error) = result {
                self.activity.set_enabled(false);
                let _ = self.update_icon();
                return Err(error);
            }
            self.update_icon()?;
            if !self.trial && settings::save_enabled(enabled).is_err() {
                message(
                    window,
                    "The change applies to this session, but Windows could not save the preference.",
                    MB_ICONWARNING,
                );
            }
        } else if command == tray::STARTUP && !self.trial {
            let desired = !self.startup.get();
            let executable = std::env::current_exe()
                .map_err(|error| Error::new(E_INVALIDARG, error.to_string()))?;
            match settings::set_startup(desired, &executable) {
                Ok(()) => self.startup.set(desired),
                Err(_) => message(
                    window,
                    "Windows could not change automatic startup. The previous setting is unchanged.",
                    MB_ICONWARNING,
                ),
            }
        } else if command == tray::EXIT {
            self.activity.stop();
            // SAFETY: Exit ends only this application's UI message loop.
            unsafe { PostQuitMessage(0) };
        }
        Ok(())
    }

    fn action_failed(&self, window: HWND) {
        self.activity.set_enabled(false);
        if let Ok(observer) = self.observer.try_borrow() {
            if let Some(observer) = observer.as_ref() {
                let _ = observer.refresh();
            }
        }
        let _ = self.update_icon();
        message(
            window,
            "Laqay could not complete this action. Clipboard handling has been disabled.",
            MB_ICONWARNING,
        );
    }
}

unsafe extern "system" fn window_proc(
    window: HWND,
    event: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    // SAFETY: Window user data points to the boxed State until after window
    // destruction. All UI callbacks run on its owner thread. Failures are
    // handled locally and no panic is allowed to cross the system callback.
    unsafe {
        if event == WM_NCCREATE {
            let create = &*(lparam.0 as *const CREATESTRUCTW);
            SetWindowLongPtrW(window, GWLP_USERDATA, create.lpCreateParams as isize);
        }
        let pointer = GetWindowLongPtrW(window, GWLP_USERDATA) as *const State;
        if let Some(state) = pointer.as_ref() {
            // Route standard menu commands through the same actions as the
            // notification menu. Control notifications and unknown IDs decline.
            if event == WM_COMMAND && lparam.0 == 0 && wparam.0 >> 16 == 0 {
                let command = wparam.0 as u32;
                if [tray::ENABLED, tray::STARTUP, tray::EXIT].contains(&command) {
                    if state.command(window, command).is_err() {
                        state.action_failed(window);
                    }
                    return LRESULT(0);
                }
            }
            if event == tray::CALLBACK {
                let activation = lparam.0 as u32 & 0xffff;
                if [WM_CONTEXTMENU, NIN_SELECT, NIN_SELECT | NINF_KEY].contains(&activation) {
                    let result = tray::show_menu(
                        window,
                        state.activity.ticket().is_some(),
                        state.startup.get(),
                        state.trial,
                        wparam,
                    )
                    .and_then(|command| state.command(window, command));
                    if result.is_err() {
                        state.action_failed(window);
                    }
                }
                return LRESULT(0);
            }
            if event == runtime::ENGINE_ERROR {
                let _ = state.update_icon();
                if state.activity.is_stopped() {
                    message(
                        window,
                        "The input observer stopped. Laqay will close.",
                        MB_ICONWARNING,
                    );
                } else if state.activity.ticket().is_none() {
                    message(
                        window,
                        "The input observer could not complete the change. Laqay is disabled; you can enable it again or exit.",
                        MB_ICONWARNING,
                    );
                }
                return LRESULT(0);
            }
            if event == runtime::ENGINE_STOPPED
                || event == WM_CLOSE
                || (event == WM_ENDSESSION && wparam.0 != 0)
            {
                state.activity.stop();
                PostQuitMessage(0);
                return LRESULT(0);
            }
            if event == WM_QUERYENDSESSION {
                return LRESULT(1);
            }
            if event == state.taskbar_created {
                let result = state
                    .tray
                    .try_borrow()
                    .map_err(|_| Error::from_hresult(E_UNEXPECTED))
                    .and_then(|tray| {
                        tray.as_ref()
                            .ok_or_else(|| Error::from_hresult(E_UNEXPECTED))?
                            .add()
                    });
                if result.is_err() {
                    state.activity.stop();
                    message(
                        window,
                        "Laqay could not restore its notification icon and will close.",
                        MB_ICONWARNING,
                    );
                    PostQuitMessage(0);
                }
                return LRESULT(0);
            }
            if event == WM_NCDESTROY {
                SetWindowLongPtrW(window, GWLP_USERDATA, 0);
            }
        }
        DefWindowProcW(window, event, wparam, lparam)
    }
}

struct Window {
    handle: HWND,
    instance: HINSTANCE,
}
impl Drop for Window {
    fn drop(&mut self) {
        // SAFETY: The observer and icon are already removed by Session below.
        unsafe {
            let _ = DestroyWindow(self.handle);
            let _ = UnregisterClassW(w!("LaqayTrayWindow"), Some(self.instance));
        }
    }
}
struct Session<'a>(&'a State);
impl Drop for Session<'_> {
    fn drop(&mut self) {
        self.0.activity.stop();
        self.0.tray.borrow_mut().take();
        self.0.observer.borrow_mut().take();
    }
}

/// Run the tray application. No arguments selects normal per-user settings.
/// `--trial <seconds> <folder>` is bounded and never reads or writes preferences.
/// Starting either mode observes real keyboard input; desktop tests need consent.
pub fn run() -> Result<()> {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    let mut trial = parse_trial(&arguments)?;
    if let Some(trial) = &mut trial {
        trial.directory = runtime::approved_folder(&trial.directory)?;
    }
    let Some(_instance) = runtime::Instance::acquire()? else {
        return Ok(());
    };
    let preferences = if trial.is_some() {
        Ok(settings::Preferences {
            enabled: true,
            startup: false,
        })
    } else {
        settings::load()
    };
    let settings_failed = preferences.is_err();
    let preferences = preferences.unwrap_or(settings::Preferences {
        enabled: false,
        startup: false,
    });
    // SAFETY: Register an Explorer-restart notification without changing it.
    let taskbar_created = unsafe { RegisterWindowMessageW(w!("TaskbarCreated")) };
    if taskbar_created == 0 {
        return Err(Error::from_thread());
    }
    let state = Box::new(State {
        activity: Arc::new(Activity::new(preferences.enabled)),
        observer: RefCell::new(None),
        tray: RefCell::new(None),
        startup: Cell::new(preferences.startup),
        trial: trial.is_some(),
        taskbar_created,
    });
    // SAFETY: The hidden top-level window can receive TaskbarCreated broadcasts
    // but is never shown or activated at startup. State outlives all callbacks.
    unsafe {
        let instance = HINSTANCE(GetModuleHandleW(None)?.0);
        let class = WNDCLASSW {
            lpfnWndProc: Some(window_proc),
            hInstance: instance,
            lpszClassName: w!("LaqayTrayWindow"),
            ..Default::default()
        };
        if RegisterClassW(&class) == 0 {
            return Err(Error::from_thread());
        }
        let handle = match CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("LaqayTrayWindow"),
            w!("Laqay"),
            WINDOW_STYLE::default(),
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance),
            Some((&*state as *const State).cast()),
        ) {
            Ok(handle) => handle,
            Err(error) => {
                let _ = UnregisterClassW(w!("LaqayTrayWindow"), Some(instance));
                return Err(error);
            }
        };
        let _window = Window { handle, instance };
        let _session = Session(&state);
        *state.tray.borrow_mut() = Some(Tray::new(
            handle,
            instance,
            preferences.enabled,
            state.trial,
        )?);
        if settings_failed {
            message(
                handle,
                "Preferences could not be read. Laqay starts disabled for this session.",
                MB_ICONWARNING,
            );
        }
        *state.observer.borrow_mut() = Some(Observer::start(
            Arc::clone(&state.activity),
            handle,
            trial.map(|trial| (trial.seconds, trial.directory)),
        )?);
        let mut event = MSG::default();
        loop {
            match GetMessageW(&mut event, None, 0, 0).0 {
                -1 => return Err(Error::from_thread()),
                0 => break,
                _ => {
                    DispatchMessageW(&event);
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn no_arguments_select_normal_mode_without_running_it() {
        assert!(parse_trial(&[]).unwrap().is_none());
    }
    #[test]
    fn trial_requires_exact_arguments_and_bounded_duration() {
        for args in [
            vec!["--trial"],
            vec!["--trial", "0", "C:\\test"],
            vec!["--trial", "31", "C:\\test"],
            vec!["--trial", "30", "relative"],
            vec!["--unknown", "30", "C:\\test"],
            vec!["--trial", "30", "C:\\test", "extra"],
        ] {
            let arguments: Vec<_> = args.into_iter().map(OsString::from).collect();
            assert!(parse_trial(&arguments).is_err());
        }
        let args: Vec<_> = ["--trial", "30", "C:\\folder with spaces"]
            .into_iter()
            .map(OsString::from)
            .collect();
        let trial = parse_trial(&args).unwrap().unwrap();
        assert_eq!(trial.seconds, 30);
        assert_eq!(trial.directory, PathBuf::from("C:\\folder with spaces"));
    }
}
