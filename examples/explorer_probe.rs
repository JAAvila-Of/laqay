#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::{self, Write};

    let argument = std::env::args().nth(1).unwrap_or_else(|| "3".into());
    if argument == "--inspect" {
        let window = std::env::args()
            .nth(2)
            .ok_or("Missing native window handle")?
            .parse::<usize>()?;
        println!("{:#?}", laqay::explorer::inspect_native_control(window)?);
        return Ok(());
    } else if argument == "--wait" {
        println!("Ready. Send a line on stdin to take one snapshot; EOF cancels.");
        io::stdout().flush()?;
        if io::stdin().read_line(&mut String::new())? == 0 {
            return Ok(());
        }
    } else if argument == "--event" {
        let id = std::env::args().nth(2).ok_or("Missing event identifier")?;
        wait_for_event(&id)?;
    } else {
        let delay = argument.parse::<u64>()?.min(60);
        println!("Select an Explorer window. Taking one snapshot in {delay} seconds.");
        std::thread::sleep(std::time::Duration::from_secs(delay));
    }
    let snapshot = laqay::explorer::observe_foreground()?;
    println!("{snapshot:#?}");
    println!(
        "Diagnostic directory: {:?}",
        snapshot.diagnostic_directory()
    );
    Ok(())
}

#[cfg(windows)]
fn wait_for_event(id: &str) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Write;
    use windows::{
        Win32::{
            Foundation::{CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE, WAIT_OBJECT_0},
            System::Threading::{CreateEventW, WaitForSingleObject},
        },
        core::HSTRING,
    };

    if id.is_empty()
        || id.len() > 64
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err("Event identifiers must contain 1-64 ASCII letters, digits, or hyphens".into());
    }
    struct Event(HANDLE);
    impl Drop for Event {
        fn drop(&mut self) {
            // SAFETY: This guard owns a handle returned by CreateEventW and closes it once.
            let _ = unsafe { CloseHandle(self.0) };
        }
    }
    let name = HSTRING::from(format!("Local\\Laqay.ExplorerProbe.{id}"));
    // SAFETY: The name remains alive during the call. Default security attributes
    // are used; the returned handle is immediately owned by the guard.
    let event = Event(unsafe { CreateEventW(None, false, false, &name)? });
    // SAFETY: Read on the creating thread immediately after CreateEventW; no
    // intervening Win32 calls change the last-error value.
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        return Err("Event identifier already in use; choose a new identifier".into());
    }
    println!("Ready. Signal {name} within 180 seconds to take one snapshot.");
    std::io::stdout().flush()?;
    // SAFETY: The event handle remains owned throughout this bounded wait.
    if unsafe { WaitForSingleObject(event.0, 180_000) } != WAIT_OBJECT_0 {
        return Err("Snapshot cancelled: event was not signaled before the deadline".into());
    }
    Ok(())
}

#[cfg(not(windows))]
fn main() {
    eprintln!("This diagnostic requires Windows.");
    std::process::exit(1);
}
