#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let seconds = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "30".into())
        .parse()?;
    let directory = std::env::args()
        .nth(2)
        .ok_or("Missing approved destination directory")?;
    laqay::paste_probe::run(seconds, std::path::Path::new(&directory))?;
    Ok(())
}

#[cfg(not(windows))]
fn main() {
    eprintln!("This experiment requires Windows.");
    std::process::exit(1);
}
