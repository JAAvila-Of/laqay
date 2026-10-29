//! Read-only metadata from the observer's own process and desktop.

use windows::{
    Win32::{
        Foundation::{E_INVALIDARG, HANDLE},
        System::{
            RemoteDesktop::{
                ProcessIdToSessionId, WTSClientProtocolType, WTSFreeMemory,
                WTSQuerySessionInformationW,
            },
            StationsAndDesktops::{
                CloseDesktop, DESKTOP_CONTROL_FLAGS, DESKTOP_READOBJECTS, GetProcessWindowStation,
                GetThreadDesktop, GetUserObjectInformationW, HDESK, OpenInputDesktop, UOI_IO,
                UOI_NAME,
            },
            Threading::{GetCurrentProcessId, GetCurrentThreadId},
        },
    },
    core::{BOOL, Error, PWSTR, Result},
};

fn object_name(handle: HANDLE) -> Result<String> {
    let mut name = [0u16; 512];
    // SAFETY: Borrowed object handle, bounded writable UTF-16 storage. The
    // query neither changes the desktop nor requests window text or values.
    unsafe {
        GetUserObjectInformationW(
            handle,
            UOI_NAME,
            Some(name.as_mut_ptr().cast()),
            size_of_val(&name) as u32,
            None,
        )?;
    }
    let end = name
        .iter()
        .position(|unit| *unit == 0)
        .ok_or_else(|| Error::from_hresult(E_INVALIDARG))?;
    Ok(String::from_utf16_lossy(&name[..end]))
}

fn receives_input(desktop: HDESK) -> Result<bool> {
    let mut input = BOOL::default();
    // SAFETY: The borrowed desktop is queried into a correctly sized BOOL.
    unsafe {
        GetUserObjectInformationW(
            HANDLE(desktop.0),
            UOI_IO,
            Some((&mut input as *mut BOOL).cast()),
            size_of::<BOOL>() as u32,
            None,
        )?;
    }
    Ok(input.as_bool())
}

fn protocol(session: u32) -> Result<u16> {
    let mut buffer = PWSTR::null();
    let mut bytes = 0;
    // SAFETY: Query only our own local session. Windows owns the returned
    // allocation; it is validated before reading and released exactly once.
    unsafe {
        WTSQuerySessionInformationW(
            None,
            session,
            WTSClientProtocolType,
            &mut buffer,
            &mut bytes,
        )?;
        let result = if buffer.is_null() || bytes < size_of::<u16>() as u32 {
            Err(Error::from_hresult(E_INVALIDARG))
        } else {
            Ok(buffer.0.read_unaligned())
        };
        WTSFreeMemory(buffer.0.cast());
        result
    }
}

struct InputDesktop(HDESK);
impl Drop for InputDesktop {
    fn drop(&mut self) {
        // SAFETY: This is the owned OpenInputDesktop handle, not a borrowed
        // handle from GetThreadDesktop or GetProcessWindowStation.
        let _ = unsafe { CloseDesktop(self.0) };
    }
}

pub(super) fn log_environment(phase: &str) {
    // SAFETY: IDs and borrowed desktop/station handles refer to this thread.
    // OpenInputDesktop requests read-only access and is closed by its guard.
    unsafe {
        let pid = GetCurrentProcessId();
        let thread = GetCurrentThreadId();
        let mut session = 0;
        let session_result = ProcessIdToSessionId(pid, &mut session).map(|_| session);
        println!("Environment ({phase}): pid={pid}, thread={thread}, session={session_result:?}");
        println!(
            "Window station: {:?}",
            GetProcessWindowStation().and_then(|handle| object_name(HANDLE(handle.0)))
        );
        let desktop = GetThreadDesktop(thread);
        println!(
            "Thread desktop: {:?}",
            desktop
                .as_ref()
                .map_err(Clone::clone)
                .and_then(|handle| object_name(HANDLE(handle.0)))
        );
        println!(
            "Thread desktop receives input: {:?}",
            desktop.and_then(receives_input)
        );
        println!(
            "Client protocol (0=console, 2=RDP): {:?}",
            session_result.and_then(protocol)
        );
        let input = OpenInputDesktop(DESKTOP_CONTROL_FLAGS::default(), false, DESKTOP_READOBJECTS)
            .map(InputDesktop);
        println!(
            "Input desktop: {:?}",
            input.and_then(|guard| object_name(HANDLE(guard.0.0)))
        );
    }
}
