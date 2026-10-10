use std::io::{BufRead, BufReader};
use std::net::{SocketAddr, TcpStream};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::process::{Command as StdCommand, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tauri::menu::{MenuBuilder, MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder};
use tauri::{Manager, RunEvent};

#[cfg(windows)]
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;

// Shutdown: TERM the backend's group first so the BEAM halts through
// its normal shutdown (Sidecar.terminate stops the engine it spawned),
// and hard-kill only what survives the grace period. The engine is its
// own process group and may predate this run, so a sweep over the
// sidecar pidfile finishes the job however the backend died.
#[cfg(unix)]
fn kill_backend(pid: i32) {
    unsafe {
        libc::kill(-pid, libc::SIGTERM);
    }
    if !wait_group_gone(pid, 5_000) {
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
        }
    }
    sweep_sidecar_engine();
}

#[cfg(unix)]
fn wait_group_gone(pgid: i32, timeout_ms: u64) -> bool {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);

    loop {
        if unsafe { libc::kill(-pgid, 0) } != 0 {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[cfg(windows)]
fn kill_backend(pid: i32) {
    taskkill(&["/PID", &pid.to_string(), "/T", "/F"]);
    sweep_sidecar_engine();
}

#[cfg(windows)]
fn taskkill(args: &[&str]) {
    let _ = StdCommand::new("taskkill")
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

// <home>/sidecar.json — the sidecar's record of the engine it owns.
// HIGHWIRE_HOME mirrors config/runtime.exs; anything unreadable just
// skips the sweep.
fn sidecar_pidfile() -> Option<std::path::PathBuf> {
    let raw = std::env::var("HIGHWIRE_HOME").unwrap_or_else(|_| "~/.highwire".to_string());

    let home = match raw.strip_prefix("~/") {
        Some(rest) => std::path::PathBuf::from(std::env::var("HOME").ok()?).join(rest),
        None => std::path::PathBuf::from(raw),
    };

    Some(home.join("sidecar.json"))
}

fn sidecar_engine_pid(path: &std::path::Path) -> Option<i32> {
    let body = std::fs::read_to_string(path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&body).ok()?;
    json.get("os_pid")?.as_i64().map(|pid| pid as i32)
}

// The pidfile can outlive its engine (and pids get reused) — only a
// process that still looks like the Erlang VM gets a signal. Mirrors
// the sidecar's beam?/1 check.
#[cfg(unix)]
fn looks_like_engine(pid: i32) -> bool {
    match StdCommand::new("ps")
        .args(["-p", &pid.to_string(), "-o", "comm="])
        .output()
    {
        Ok(out) if out.status.success() => {
            let comm = String::from_utf8_lossy(&out.stdout);
            comm.contains("beam") || comm.contains("/erl")
        }
        _ => false,
    }
}

#[cfg(windows)]
fn looks_like_engine(pid: i32) -> bool {
    match StdCommand::new("tasklist")
        .args(["/FO", "CSV", "/NH", "/FI", &format!("PID eq {pid}")])
        .output()
    {
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout).to_lowercase();
            text.contains("beam") || text.contains("erl")
        }
        Err(_) => false,
    }
}

// A graceful backend shutdown removes the pidfile itself; what is left
// here is either a backend that died abruptly or an engine from an
// earlier run — TERM, give it the same grace, then KILL what is left.
#[cfg(unix)]
fn sweep_sidecar_engine() {
    let Some(path) = sidecar_pidfile() else {
        return;
    };
    let Some(pid) = sidecar_engine_pid(&path) else {
        return;
    };

    if !looks_like_engine(pid) {
        return;
    }

    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }

    let deadline = Instant::now() + Duration::from_millis(5_000);

    loop {
        if unsafe { libc::kill(pid, 0) } != 0 {
            break;
        }
        if Instant::now() >= deadline {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    let _ = std::fs::remove_file(&path);
}

#[cfg(windows)]
fn sweep_sidecar_engine() {
    let Some(path) = sidecar_pidfile() else {
        return;
    };
    let Some(pid) = sidecar_engine_pid(&path) else {
        return;
    };

    if looks_like_engine(pid) {
        taskkill(&["/PID", &pid.to_string(), "/T", "/F"]);
        let _ = std::fs::remove_file(&path);
    }
}

// The Elixir (Burrito) backend serves the LiveView on this port.
const BACKEND_URL: &str = "http://localhost:24042";
const BACKEND_ADDR: &str = "127.0.0.1:24042";

fn build_menu(app: &tauri::App) -> tauri::Result<()> {
    let handle = app.handle();

    let timeline = MenuItemBuilder::with_id("timeline", "Timeline")
        .accelerator("CmdOrCtrl+1")
        .build(handle)?;
    let network = MenuItemBuilder::with_id("network", "Network")
        .accelerator("CmdOrCtrl+2")
        .build(handle)?;
    let dashboard = MenuItemBuilder::with_id("dashboard", "Dashboard")
        .accelerator("CmdOrCtrl+D")
        .build(handle)?;
    let prefs = MenuItemBuilder::with_id("prefs", "Preferences")
        .accelerator("CmdOrCtrl+,")
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
        .item(&timeline)
        .item(&network)
        .separator()
        .item(&dashboard)
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
        .plugin(tauri_plugin_window_state::Builder::default().build())
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
        .on_menu_event(|app, event| {
            // Menu navigation drives the webview directly: the LiveView
            // only needs a URL, and a full navigation keeps history working
            // in both directions.
            let navigate = |path: &str| {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.eval(format!("window.location.href = \"{path}\""));
                }
            };
            match event.id().as_ref() {
                "timeline" => navigate("/"),
                "network" => navigate("/network"),
                "dashboard" => navigate("/dashboard"),
                "prefs" => navigate("/settings"),
                "profile" => navigate("/profile"),
                "reload" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.reload();
                    }
                }
                #[cfg(target_os = "macos")]
                "emoji" => show_character_palette(),
                _ => {}
            }
        })
        .on_window_event(|window, event| {
            // Closing the app window quits the app (and thus kills the
            // backend) even on macOS, where the default is to keep the
            // process alive without windows.
            if let tauri::WindowEvent::Destroyed = event {
                window.app_handle().exit(0);
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
