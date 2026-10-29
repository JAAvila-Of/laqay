#[cfg(windows)]
fn main() -> windows::core::Result<()> {
    let delay = std::env::args()
        .nth(1)
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(3)
        .min(60);
    println!("Select an Explorer window. Taking one snapshot in {delay} seconds.");
    std::thread::sleep(std::time::Duration::from_secs(delay));
    println!("{:#?}", laqay::explorer::observe_foreground()?);
    Ok(())
}

#[cfg(not(windows))]
fn main() {
    eprintln!("This diagnostic requires Windows.");
    std::process::exit(1);
}
