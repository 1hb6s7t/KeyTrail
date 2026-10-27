#![cfg_attr(windows, windows_subsystem = "windows")]
#[cfg(windows)]
mod native;
fn main() {
    #[cfg(windows)]
    {
        if let Err(e) = native::run() {
            native::show_error(&e)
        }
    }
    #[cfg(not(windows))]
    {
        eprintln!("KeyTrail Windows collector requires Windows 10/11. Platform-independent normalization tests can run here.");
    }
}
