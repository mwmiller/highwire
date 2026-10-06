use std::io::{BufRead, BufReader};
use std::net::{SocketAddr, TcpStream};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::process::{Command as StdCommand, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::json;
use tauri::menu::{MenuBuilder, MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder};
use tauri::{Emitter, Manager, RunEvent, Window};

#[cfg(windows)]
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;

#[cfg(unix)]
fn kill_backend(pid: i32) {
    unsafe {
        libc::kill(-pid, libc::SIGKILL);
    }
}

#[cfg(windows)]
fn kill_backend(pid: i32) {
    let _ = StdCommand::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

// The Elixir (Burrito) backend serves the LiveView on this port.
const BACKEND_URL: &str = "http://localhost:24042";
const BACKEND_ADDR: &str = "127.0.0.1:24042";

#[tauri::command]
fn set_window_size(window: Window, width: f64, height: f64) {
    let _ = window.set_size(tauri::LogicalSize::new(width, height));
}

#[tauri::command]
fn write_file(path: String, content: String) -> Result<(), String> {
    std::fs::write(&path, content).map_err(|e| e.to_string())
}

fn build_menu(app: &tauri::App) -> tauri::Result<()> {
    let handle = app.handle();

    let dashboard = MenuItemBuilder::with_id("dashboard", "Dashboard")
        .accelerator("CmdOrCtrl+D")
        .build(handle)?;
    let prefs = MenuItemBuilder::with_id("prefs", "Preferences")
        .accelerator("CmdOrCtrl+,")
        .build(handle)?;
    let oases = MenuItemBuilder::with_id("oases", "Oases")
        .accelerator("CmdOrCtrl+O")
        .build(handle)?;
    let unshown = MenuItemBuilder::with_id("unshown", "Unshown")
        .accelerator("CmdOrCtrl+U")
        .build(handle)?;
    // The playground is where a new app starts, so it takes the shortcut a
    // "New" item would otherwise hold.
    let playground = MenuItemBuilder::with_id("playground", "Playground")
        .accelerator("CmdOrCtrl+N")
        .build(handle)?;
    let profile = MenuItemBuilder::with_id("profile", "My Profile")
        .accelerator("CmdOrCtrl+Shift+P")
        .build(handle)?;
    let reload = MenuItemBuilder::with_id("reload", "Reload")
        .accelerator("CmdOrCtrl+R")
        .build(handle)?;
    let close_window = PredefinedMenuItem::close_window(handle, None)?;
    let about = PredefinedMenuItem::about(
        handle,
        Some("About HighWire"),
        Some(tauri::menu::AboutMetadata {
            license: Some("MIT".into()),
            ..Default::default()
        }),
    )?;
    let quit = PredefinedMenuItem::quit(handle, Some("Quit HighWire"))?;

    let undo = PredefinedMenuItem::undo(handle, None)?;
    let redo = PredefinedMenuItem::redo(handle, None)?;
    let cut = PredefinedMenuItem::cut(handle, None)?;
    let copy = PredefinedMenuItem::copy(handle, None)?;
    let paste = PredefinedMenuItem::paste(handle, None)?;
    let select_all = PredefinedMenuItem::select_all(handle, None)?;
    // macOS opens the Character Viewer from a menu item holding this key
    // equivalent, so the shortcut only works while an item claims it.
    #[cfg(target_os = "macos")]
    let emoji = MenuItemBuilder::with_id("emoji", "Emoji & Symbols")
        .accelerator("Ctrl+Cmd+Space")
        .build(handle)?;

    let mut edit = SubmenuBuilder::new(handle, "Edit")
        .item(&undo)
        .item(&redo)
        .separator()
        .item(&cut)
        .item(&copy)
        .item(&paste)
        .separator()
        .item(&select_all);
    #[cfg(target_os = "macos")]
    {
        edit = edit.separator().item(&emoji);
    }
    let edit = edit.build()?;

    let highwire = SubmenuBuilder::new(handle, "HighWire")
        .item(&about)
        .separator()
        .item(&prefs)
        .separator()
        .item(&quit)
        .build()?;
    let go = SubmenuBuilder::new(handle, "Go")
        .item(&dashboard)
        .separator()
        .item(&oases)
        .item(&unshown)
        .item(&playground)
        .separator()
        .item(&profile)
        .build()?;
    let view = SubmenuBuilder::new(handle, "View").item(&reload).build()?;
    let window = SubmenuBuilder::new(handle, "Window")
        .item(&close_window)
        .build()?;

    let menu = MenuBuilder::new(handle)
        .item(&highwire)
        .item(&go)
        .item(&edit)
        .item(&view)
        .item(&window)
        .build()?;

    app.set_menu(menu)?;
    Ok(())
}

// Opens the macOS Character Viewer at the current insertion point. The
// responder chain ends at NSApplication, which is what the standard Edit >
// Emoji & Symbols item invokes, so calling it directly is equivalent to the
// menu action firing.
#[cfg(target_os = "macos")]
fn show_character_palette() {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSApplication;

    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    NSApplication::sharedApplication(mtm).orderFrontCharacterPalette(None);
}

// Spawns the backend synchronously and returns its PID once recorded, so
// there is never a window where a quit would miss the PID and orphan the
// backend. Output pumping and reaping continue on background threads.
fn start_backend() -> Option<i32> {
    let mut exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(err) => {
            eprintln!("[highwire] unable to resolve the app executable: {err}");
            return None;
        }
    };
    exe.set_file_name("highwire-backend");

    let mut command = StdCommand::new(exe);
    #[cfg(unix)]
    command
        .arg("--no-halt")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    #[cfg(windows)]
    command
        .arg("--no-halt")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NEW_PROCESS_GROUP);

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(err) => {
            eprintln!("[highwire] failed to spawn the backend: {err}");
            return None;
        }
    };

    let stdout = child.stdout.take().map(BufReader::new);
    let stderr = child.stderr.take().map(BufReader::new);
    let pid = child.id() as i32;

    if let Some(stdout) = stdout {
        std::thread::spawn(move || {
            for line in stdout.lines().map_while(Result::ok) {
                println!("[highwire] {}", line.trim_end());
            }
        });
    }
    if let Some(stderr) = stderr {
        std::thread::spawn(move || {
            for line in stderr.lines().map_while(Result::ok) {
                eprintln!("[highwire] {}", line.trim_end());
            }
        });
    }

    // Reap the child so it doesn't linger as a zombie after it exits.
    std::thread::spawn(move || {
        let _ = child.wait();
    });

    println!("[highwire] backend started");
    Some(pid)
}

fn wait_for_backend() {
    let addr: SocketAddr = BACKEND_ADDR.parse().expect("valid socket address");
    let mut attempts = 0;
    while attempts < 150 {
        if TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(200));
        attempts += 1;
    }
    eprintln!("[highwire] backend did not come up in time");
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let backend_pid: Arc<Mutex<Option<i32>>> = Arc::new(Mutex::new(None));
    let exit_pid = backend_pid.clone();
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![set_window_size, write_file])
        .setup(move |app| {
            build_menu(app)?;
            // Spawn synchronously so the PID is recorded before any event
            // (including a fast quit) can be processed.
            *backend_pid.lock().unwrap() = start_backend();

            let handle = app.handle().clone();
            std::thread::spawn(move || {
                wait_for_backend();
                if let Some(window) = handle.get_webview_window("main") {
                    let _ = window.navigate(BACKEND_URL.parse().expect("valid backend URL"));
                }
            });

            Ok(())
        })
        .on_menu_event(|app, event| match event.id().as_ref() {
            "dashboard" => {
                let _ = app.emit_to("main", "highwire-menu", json!({ "view": "dashboard" }));
            }
            "prefs" => {
                let _ = app.emit_to(
                    "main",
                    "highwire-menu",
                    json!({ "view": "prefs", "entry": "none" }),
                );
            }
            "oases" => {
                let _ = app.emit_to(
                    "main",
                    "highwire-menu",
                    json!({ "view": "oases", "entry": "none" }),
                );
            }
            "unshown" => {
                let _ = app.emit_to(
                    "main",
                    "highwire-menu",
                    json!({ "view": "unshown", "entry": "all" }),
                );
            }
            // A blank draft, the same destination as the listings header's
            // New app button, so it is a navigation with history behind it.
            "playground" => {
                let _ = app.emit_to(
                    "main",
                    "highwire-menu",
                    json!({ "view": "playground", "entry": "all" }),
                );
            }
            "profile" => {
                let _ = app.emit_to("main", "highwire-menu", json!({ "value": "origin" }));
            }
            "reload" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.reload();
                }
            }
            #[cfg(target_os = "macos")]
            "emoji" => show_character_palette(),
            _ => {}
        })
        .on_window_event(|window, event| {
            match event {
                tauri::WindowEvent::Resized(size) => {
                    let scale = window.scale_factor().unwrap_or(1.0);
                    let logical = size.to_logical::<f64>(scale);
                    let _ = window.emit(
                        "highwire-resize",
                        json!({
                            "width": logical.width.to_string(),
                            "height": logical.height.to_string()
                        }),
                    );
                }
                // Closing the app window quits the app (and thus kills the
                // backend) even on macOS, where the default is to keep the
                // process alive without windows.
                tauri::WindowEvent::Destroyed => {
                    window.app_handle().exit(0);
                }
                _ => {}
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(move |_app, event| {
            if let RunEvent::Exit = event {
                if let Some(pid) = exit_pid.lock().unwrap().take() {
                    kill_backend(pid);
                    println!("[highwire] backend killed");
                }
            }
        });
}
