//! Opt-in, bounded experiments sharing the application's paste engine.
use std::path::Path;
use windows::core::Result;

/// Observe native input for 1-30 seconds, writing only to the approved folder.
/// This reads the real clipboard on a paste request; agree a desktop test first.
pub fn run(seconds: u32, approved_directory: &Path, use_hook: bool) -> Result<()> {
    crate::runtime::run(seconds, approved_directory, use_hook)
}

/// Count input without inspecting the clipboard or Explorer context.
/// This still observes live input and requires an agreed desktop test window.
pub fn run_input(seconds: u32) -> Result<()> {
    crate::runtime::run_input(seconds)
}
