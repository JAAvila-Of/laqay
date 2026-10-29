#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::{self, Write};

    let argument = std::env::args().nth(1).unwrap_or_else(|| "3".into());
    if argument == "--wait" {
        println!("Ready. Send a line on stdin to take one snapshot; EOF cancels.");
        io::stdout().flush()?;
        if io::stdin().read_line(&mut String::new())? == 0 {
            return Ok(());
        }
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

#[cfg(not(windows))]
fn main() {
    eprintln!("This diagnostic requires Windows.");
    std::process::exit(1);
}
