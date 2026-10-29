#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args().nth(1).as_deref() == Some("--input-only") {
        let seconds = std::env::args()
            .nth(2)
            .unwrap_or_else(|| "30".into())
            .parse()?;
        laqay::paste_probe::run_input(seconds)?;
        return Ok(());
    }
    let seconds = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "30".into())
        .parse()?;
    let directory = std::env::args()
        .nth(2)
        .ok_or("Missing approved destination directory")?;
    let use_hook = match std::env::args().nth(3).as_deref().unwrap_or("raw") {
        "raw" => false,
        "hook" => true,
        _ => return Err("Input backend must be raw or hook".into()),
    };
    laqay::paste_probe::run(seconds, std::path::Path::new(&directory), use_hook)?;
    Ok(())
}

#[cfg(not(windows))]
fn main() {
    eprintln!("This experiment requires Windows.");
    std::process::exit(1);
}
