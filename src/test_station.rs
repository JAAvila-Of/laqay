//! A new, nonvisible window station for a dedicated child test process.

use std::time::{SystemTime, UNIX_EPOCH};
use windows::{
    Win32::{
        Foundation::{E_UNEXPECTED, GENERIC_ALL, HANDLE},
        System::{StationsAndDesktops::*, Threading::GetCurrentThreadId},
    },
    core::{Error, PCWSTR, Result, w},
};

pub(crate) struct Station {
    previous_station: HWINSTA,
    previous_desktop: HDESK,
    station: HWINSTA,
    desktop: Option<HDESK>,
}

impl Station {
    pub(crate) fn new() -> Result<Self> {
        // SAFETY: This runs only in the dedicated child test. CWF_CREATE_ONLY
        // refuses any existing station, including the interactive one. A unique
        // name prevents accidentally opening a station shared by another process.
        unsafe {
            let previous_station = GetProcessWindowStation()?;
            let previous_desktop = GetThreadDesktop(GetCurrentThreadId())?;
            const CWF_CREATE_ONLY: u32 = 1;
            let name = format!(
                "Laqay.Test.{}.{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            );
            let name: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
            let station =
                CreateWindowStationW(PCWSTR(name.as_ptr()), CWF_CREATE_ONLY, GENERIC_ALL.0, None)?;
            let mut owned = Self {
                previous_station,
                previous_desktop,
                station,
                desktop: None,
            };
            let mut flags = USEROBJECTFLAGS::default();
            GetUserObjectInformationW(
                HANDLE(station.0),
                UOI_FLAGS,
                Some((&mut flags as *mut USEROBJECTFLAGS).cast()),
                size_of::<USEROBJECTFLAGS>() as u32,
                None,
            )?;
            const WSF_VISIBLE: u32 = 1;
            if station == previous_station || flags.dwFlags & WSF_VISIBLE != 0 {
                return Err(Error::new(
                    E_UNEXPECTED,
                    "Clipboard isolation was not established",
                ));
            }
            SetProcessWindowStation(station)?;
            let desktop = CreateDesktopW(
                w!("Default"),
                PCWSTR::null(),
                None,
                DESKTOP_CONTROL_FLAGS::default(),
                GENERIC_ALL.0,
                None,
            )?;
            owned.desktop = Some(desktop);
            SetThreadDesktop(desktop)?;
            if GetProcessWindowStation()? != station
                || GetThreadDesktop(GetCurrentThreadId())? != desktop
            {
                return Err(Error::from_hresult(E_UNEXPECTED));
            }
            Ok(owned)
        }
    }

    #[cfg(feature = "isolated-clipboard-tests")]
    pub(crate) fn desktop(&self) -> HDESK {
        self.desktop.unwrap()
    }

    pub(crate) fn finish(mut self) {
        // SAFETY: All test windows, clipboard locks, and worker threads have
        // ended. Only this child's station/thread association is restored.
        unsafe {
            SetProcessWindowStation(self.previous_station).unwrap();
            SetThreadDesktop(self.previous_desktop).unwrap();
            CloseDesktop(self.desktop.take().unwrap()).unwrap();
            CloseWindowStation(self.station).unwrap();
            self.station = HWINSTA::default();
        }
    }
}

impl Drop for Station {
    fn drop(&mut self) {
        // SAFETY: Unwind cleanup is confined to this child and its owned handles.
        unsafe {
            let _ = SetProcessWindowStation(self.previous_station);
            let _ = SetThreadDesktop(self.previous_desktop);
            if let Some(desktop) = self.desktop.take() {
                let _ = CloseDesktop(desktop);
            }
            if !self.station.is_invalid() {
                let _ = CloseWindowStation(self.station);
            }
        }
    }
}
