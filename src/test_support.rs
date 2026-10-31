//! Bounded child test processes, without console windows or desktop input.

use std::{
    os::windows::process::CommandExt,
    process::{Command, Output, Stdio},
    time::{Duration, Instant},
};
use windows::Win32::System::Threading::CREATE_NO_WINDOW;

pub(crate) fn child_test(name: &str, environment: &[(&str, &str)]) -> Output {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .creation_flags(CREATE_NO_WINDOW.0)
        .args(["--ignored", "--exact", name, "--nocapture"])
        .envs(environment.iter().copied())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("Owned child test {name} exceeded its deadline");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "Child {name} failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("1 passed"));
    output
}
