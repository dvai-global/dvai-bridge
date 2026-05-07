// Hide the console window on Windows release builds. The CLI/dev path keeps it.
#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

fn main() {
    dvai_hub_lib::run();
}
