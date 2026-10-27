use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use keytrail_core::Engine;
use keytrail_windows::activity_flush::flush_activity;
use keytrail_windows::text_archive::{
    civil_hour_start, finish_login_change, parse_civil_minute, random_key, TextArchive,
};
use keytrail_windows::{endpoint, sample, InputState, RecoveryCutoff};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    ffi::c_void,
    fs,
    mem::{size_of, zeroed},
    net::TcpListener,
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::Gdi::*,
    Security::Cryptography::*,
    Storage::FileSystem::*,
    System::{
        DataExchange::*, LibraryLoader::*, Memory::*, Registry::*, RemoteDesktop::*,
        SystemInformation::*, Threading::*, Time::*,
    },
    UI::{
        Input::{KeyboardAndMouse::EnableWindow, *},
        Shell::*,
        WindowsAndMessaging::*,
    },
};
#[path = "win_sync.rs"]
mod sync;
#[path = "text_capture.rs"]
mod text_capture;
const CLASS: &str = "KeyTrailResident12";
const TRAY: u32 = WM_APP + 1;
const DEFERRED_QUIT: u32 = WM_APP + 2;
const START: usize = 101;
const DASH: usize = 102;
const FLOAT: usize = 103;
const LOGIN: usize = 104;
const SAVE: usize = 105;
const SYNC: usize = 106;
const QUIT: usize = 107;
const COPY: usize = 108;
const TEXTKEY: usize = 109;
const TEXTCLEAR: usize = 110;
const DATA_ID: usize = 2201;
const DATA_START: usize = 2202;
const DATA_END: usize = 2203;
const DATA_UTC: usize = 2204;
const DATA_ONE: usize = 2205;
const DATA_TEXT: usize = 2206;
const DATA_JOINT: usize = 2207;
const DATA_ALL: usize = 2208;
const DATA_STATUS: usize = 2209;
const TEXTEN: usize = 206;
const TEXTSYNC: usize = 207;
const ENDPOINT: usize = 201;
const TOKEN: usize = 202;
const CAP: usize = 203;
const SYNCEN: usize = 204;
const STATUS: usize = 205;
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}
fn time() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn random() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    let status = unsafe {
        BCryptGenRandom(
            null_mut(),
            bytes.as_mut_ptr(),
            32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if status != 0 {
        return Err("Secure random source unavailable".into());
    }
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Settings {
    device_id: String,
    endpoint: String,
    protected_token: Vec<u8>,
    sync_enabled: bool,
    cursor: u64,
    replica_id: String,
    cap_bytes: u64,
    floating: bool,
    launch_at_login: bool,
    text_enabled: bool,
    text_sync_enabled: bool,
    protected_text_key: Vec<u8>,
    text_cursor: u64,
    text_replica_id: String,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            device_id: String::new(),
            endpoint: String::new(),
            protected_token: Vec::new(),
            sync_enabled: false,
            cursor: 0,
            replica_id: String::new(),
            cap_bytes: 0,
            floating: false,
            launch_at_login: false,
            text_enabled: false,
            text_sync_enabled: false,
            protected_text_key: Vec::new(),
            text_cursor: 0,
            text_replica_id: String::new(),
        }
    }
}
fn protect(input: &[u8], decrypt: bool) -> Result<Vec<u8>, String> {
    unsafe {
        let source = CRYPT_INTEGER_BLOB {
            cbData: input.len() as u32,
            pbData: input.as_ptr() as *mut u8,
        };
        let mut out: CRYPT_INTEGER_BLOB = zeroed();
        let okay = if decrypt {
            CryptUnprotectData(
                &source,
                null_mut(),
                null(),
                null_mut(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out,
            )
        } else {
            CryptProtectData(
                &source,
                null(),
                null(),
                null_mut(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out,
            )
        };
        if okay == 0 {
            return Err("Windows per-user credential protection failed".into());
        }
        let bytes = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
        LocalFree(out.pbData as *mut c_void);
        Ok(bytes)
    }
}
fn save(path: &Path, cfg: &Settings) -> Result<(), String> {
    let temp = path.with_extension("new");
    fs::write(
        &temp,
        serde_json::to_vec_pretty(cfg).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    fs::rename(temp, path).map_err(|e| e.to_string())
}
fn request(engine: &Arc<Mutex<Engine>>, v: Value) -> Result<Value, String> {
    engine
        .lock()
        .map_err(|_| "Store unavailable".to_string())?
        .request(&v.to_string())
}
struct App {
    engine: Arc<Mutex<Engine>>,
    text_archive: Arc<Mutex<TextArchive>>,
    text_status: Arc<Mutex<String>>,
    capture_active: Arc<AtomicBool>,
    text_intent: Arc<AtomicU64>,
    text_reset: Arc<AtomicU64>,
    settings: Arc<Mutex<Settings>>,
    config_path: PathBuf,
    stats_path: PathBuf,
    input: InputState,
    pending: Vec<Value>,
    enabled: bool,
    recovery: RecoveryCutoff,
    capture_ready: bool,
    tray_available: bool,
    locked: bool,
    suspended: bool,
    demo: bool,
    viewer_token: String,
    url: String,
    float: HWND,
    manager: HWND,
    data_job: Option<DataJob>,
    data_status: String,
    displayed_status: String,
    status: Arc<Mutex<String>>,
    sync_status: Arc<Mutex<String>>,
    stop: Arc<AtomicBool>,
    sync_now: Arc<AtomicBool>,
    instance: HANDLE,
    ticks: u32,
}
impl App {
    fn running(&self) -> bool {
        self.session_allows_collection() && self.recovery.pending().is_none()
    }
    fn session_allows_collection(&self) -> bool {
        self.enabled && self.capture_ready && !self.locked && !self.suspended && !self.demo
    }
    fn flush(&mut self, end: bool) -> Result<(), String> {
        let now = time();
        if end {
            self.capture_active.store(false, Ordering::Relaxed);
            self.text_intent.store(0, Ordering::Relaxed);
            self.text_reset.fetch_add(1, Ordering::Relaxed);
        }
        let ending = end || self.recovery.pending().is_some();
        let advance_allowed = self.session_allows_collection();
        let result = flush_activity(
            &mut self.pending,
            &mut self.recovery,
            now,
            end,
            advance_allowed,
            |v| request(&self.engine, v),
        );
        if ending && self.recovery.pending().is_none() {
            self.input.reset();
        }
        result
    }
    fn record(&mut self, event: Value) {
        if !self.running() {
            return;
        }
        if self.pending.len() >= 4096 {
            self.enabled = false;
            self.input.reset();
            *self.status.lock().unwrap() =
                "Collection paused: pending input limit reached; inspect disk/store error.".into();
            return;
        }
        self.pending.push(event);
        if self.pending.len() >= 512 {
            if let Err(e) = self.flush(false) {
                self.enabled = false;
                *self.status.lock().unwrap() = format!("Collection paused: {e}")
            }
        }
    }
    fn pause(&mut self) {
        if let Err(e) = self.pause_checked() {
            *self.status.lock().unwrap() = e;
        }
    }
    fn pause_checked(&mut self) -> Result<(), String> {
        self.enabled = false;
        self.capture_active.store(false, Ordering::Relaxed);
        self.text_intent.store(0, Ordering::Relaxed);
        self.text_reset.fetch_add(1, Ordering::Relaxed);
        let result = self.flush(true);
        self.input.reset();
        result
    }
    fn persist(&self) {
        if let Ok(cfg) = self.settings.lock() {
            if let Err(e) = save(&self.config_path, &cfg) {
                *self.status.lock().unwrap() = e;
            }
        }
    }
    unsafe fn update(&mut self, hwnd: HWND) {
        self.poll_management();
        self.capture_active.store(self.running(), Ordering::Relaxed);
        if !self.running() {
            self.text_intent.store(0, Ordering::Relaxed);
            self.text_reset.fetch_add(1, Ordering::Relaxed);
        }
        let mode = if self.recovery.pending().is_some() {
            "Recovery paused: retrying original pause/lock boundary"
        } else if !self.capture_ready {
            "Capture unavailable: OS registration failed"
        } else if self.demo {
            "DEMO: synthetic database; capture disabled"
        } else if self.running() {
            "Collecting physical input"
        } else if self.locked || self.suspended {
            "Session inactive: no collection"
        } else {
            "Paused: click Start explicitly"
        };
        SetWindowTextW(
            GetDlgItem(hwnd, START as i32),
            wide(if self.running() {
                "Pause collection"
            } else {
                "Start collection"
            })
            .as_ptr(),
        );
        let cfg = self.settings.lock().unwrap().clone();
        let storage = if self.data_job.is_some() {
            Err("Data management operation in progress".to_string())
        } else {
            let _owner = self.engine.lock().unwrap();
            self.text_archive
                .lock()
                .unwrap()
                .storage_combined(&self.stats_path)
        };
        let storage_note = match storage {
            Ok(v) => format!(
                "Storage {} bytes (text {} bytes / {} records), cap {}",
                v["combinedBytes"],
                v["textBytes"],
                v["textRecordCount"],
                if cfg.cap_bytes == 0 {
                    "unlimited".into()
                } else {
                    cfg.cap_bytes.to_string()
                }
            ),
            Err(e) => format!("Storage information error: {e}"),
        };
        let message = format!(
            "{}\r\n{}\r\n{}\r\nText record {} / sync {}: {}\r\n{}\r\nDevice: {} | login startup: {}",
            mode,
            self.status.lock().unwrap(),
            self.sync_status.lock().unwrap(),
            if cfg.text_enabled { "on" } else { "off" },
            if cfg.text_sync_enabled { "on" } else { "off" },
            self.text_status.lock().unwrap(),
            storage_note,
            cfg.device_id,
            if cfg.launch_at_login { "on" } else { "off" }
        );
        // Do not reset the read-only status viewport on each unchanged timer tick.
        if message != self.displayed_status {
            SetWindowTextW(GetDlgItem(hwnd, STATUS as i32), wide(&message).as_ptr());
            self.displayed_status = message;
        }
        let floating = self.settings.lock().unwrap().floating;
        if floating && self.float.is_null() {
            self.float = CreateWindowExW(
                WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                wide("KeyTrailFloat12").as_ptr(),
                wide("KeyTrail current hour").as_ptr(),
                WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
                40,
                80,
                300,
                125,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null(),
            );
            SetWindowLongPtrW(self.float, GWLP_USERDATA, self as *mut App as isize);
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                wide("").as_ptr(),
                WS_CHILD | WS_VISIBLE,
                12,
                8,
                275,
                55,
                self.float,
                1usize as HMENU,
                GetModuleHandleW(null()),
                null(),
            );
        } else if !floating && !self.float.is_null() {
            DestroyWindow(self.float);
            self.float = null_mut();
        }
        if !self.manager.is_null() {
            SetWindowTextW(
                GetDlgItem(self.manager, DATA_STATUS as i32),
                wide(&self.data_status).as_ptr(),
            );
            for control in [DATA_ONE, DATA_TEXT, DATA_JOINT, DATA_ALL] {
                EnableWindow(
                    GetDlgItem(self.manager, control as i32),
                    if self.data_job.is_none() { 1 } else { 0 },
                );
            }
        }
        if !self.float.is_null() && self.data_job.is_none() {
            let mut local: SYSTEMTIME = zeroed();
            GetLocalTime(&mut local);
            let now = time();
            let start = match civil_hour_start(now, |epoch| local_hour_key(epoch)) {
                Ok(value) => value,
                Err(e) => {
                    SetWindowTextW(GetDlgItem(self.float, 1), wide(&e).as_ptr());
                    return;
                }
            };
            if let Ok(s) = request(
                &self.engine,
                json!({"op":"summary","start":start,"end":now}),
            ) {
                SetWindowTextW(
                    GetDlgItem(self.float, 1),
                    wide(&format!(
                        "This local hour: {} presses, {} clicks\r\n{} | active {} sec",
                        s["keyPresses"],
                        s["leftClicks"].as_u64().unwrap_or(0)
                            + s["rightClicks"].as_u64().unwrap_or(0)
                            + s["middleClicks"].as_u64().unwrap_or(0),
                        mode,
                        s["totalActiveSeconds"]
                    ))
                    .as_ptr(),
                );
            }
        }
    }
    unsafe fn command(&mut self, hwnd: HWND, id: usize) {
        match id {
            START => {
                if self.data_job.is_some() {
                    *self.status.lock().unwrap() =
                        "Finish or cancel data management before restarting collection.".into();
                    return;
                }
                if self.running() {
                    self.pause()
                } else if !self.demo && self.capture_ready && !self.locked && !self.suspended {
                    self.input.reset();
                    self.enabled = true;
                    *self.status.lock().unwrap() =
                        "Collection started explicitly. Text is a separate opt-in; no clipboard capture.".into()
                }
            }
            DASH => {
                ShellExecuteW(
                    null_mut(),
                    wide("open").as_ptr(),
                    wide(&self.url).as_ptr(),
                    null(),
                    null(),
                    SW_SHOWNORMAL,
                );
            }
            COPY => {
                if OpenClipboard(hwnd) != 0 {
                    EmptyClipboard();
                    let text = wide(&self.viewer_token);
                    let memory = GlobalAlloc(GMEM_MOVEABLE, text.len() * 2);
                    if !memory.is_null() {
                        let target = GlobalLock(memory) as *mut u16;
                        if !target.is_null() {
                            std::ptr::copy_nonoverlapping(text.as_ptr(), target, text.len());
                            GlobalUnlock(memory);
                            if SetClipboardData(13, memory).is_null() {
                                GlobalFree(memory);
                            }
                        }
                    }
                    CloseClipboard();
                    *self.status.lock().unwrap()="Viewer credential copied explicitly. Paste into local viewer login; it expires when the app quits.".into();
                }
            }
            TEXTKEY => {
                let cfg = self.settings.lock().unwrap();
                match protect(&cfg.protected_text_key, true) {
                    Ok(key) => {
                        if let Err(e) = copy_clipboard(hwnd, &B64.encode(key)) {
                            *self.status.lock().unwrap() = e
                        } else {
                            *self.status.lock().unwrap()="Text decryption key copied explicitly. It is not sent to the private server.".into()
                        }
                    }
                    Err(e) => *self.status.lock().unwrap() = e,
                }
            }
            TEXTCLEAR => {
                self.open_manager(hwnd);
            }
            FLOAT => {
                let mut cfg = self.settings.lock().unwrap();
                cfg.floating = !cfg.floating;
                drop(cfg);
                self.persist();
            }
            LOGIN => {
                if self.demo {
                    *self.status.lock().unwrap() =
                        "Demo never changes launch-at-login registration.".into();
                    self.update(hwnd);
                    return;
                }
                let enable = !self.settings.lock().unwrap().launch_at_login;
                match login(enable) {
                    Ok(()) => {
                        self.settings.lock().unwrap().launch_at_login = enable;
                        let result = {
                            let cfg = self.settings.lock().unwrap().clone();
                            finish_login_change(enable, || save(&self.config_path, &cfg))
                        };
                        *self.status.lock().unwrap() = match result {
                            Ok(message) => message,
                            Err(error) => error,
                        };
                    }
                    Err(e) => *self.status.lock().unwrap() = e,
                }
            }
            SAVE => {
                let ep = read_control(hwnd, ENDPOINT);
                let secret = read_control(hwnd, TOKEN);
                let cap = read_control(hwnd, CAP).parse::<u64>();
                let enabled = SendMessageW(GetDlgItem(hwnd, SYNCEN as i32), BM_GETCHECK, 0, 0) == 1;
                if let Err(e) = self.configure(
                    ep,
                    secret,
                    cap,
                    enabled,
                    SendMessageW(GetDlgItem(hwnd, TEXTEN as i32), BM_GETCHECK, 0, 0) == 1,
                    SendMessageW(GetDlgItem(hwnd, TEXTSYNC as i32), BM_GETCHECK, 0, 0) == 1,
                ) {
                    *self.status.lock().unwrap() = e
                } else {
                    SetWindowTextW(GetDlgItem(hwnd, TOKEN as i32), wide("").as_ptr());
                    *self.status.lock().unwrap() =
                        "Settings saved. Private sync is opt-in; storage cap cleanup is explicit."
                            .into()
                }
            }
            SYNC => {
                self.sync_now.store(true, Ordering::Relaxed);
            }
            QUIT => {
                if let Err(error) = self.pause_checked() {
                    *self.status.lock().unwrap() = format!("Quit blocked: data could not be saved ({error}). Collection stays paused. Fix storage and retry Quit.");
                    ShowWindow(hwnd, SW_SHOW);
                    SetForegroundWindow(hwnd);
                    self.update(hwnd);
                    return;
                }
                self.stop.store(true, Ordering::Relaxed);
                PostMessageW(hwnd, DEFERRED_QUIT, 0, 0);
                return;
            }
            _ => {}
        }
        self.update(hwnd);
    }
    fn cleanup(&mut self, bytes: u64) -> Result<Value, String> {
        // Persist pending input without cutting its normal inactivity tail. Only
        // an actual deletion below may end the window and invalidate text state.
        self.flush(false)?;
        let engine_owner = self.engine.clone();
        let text_owner = self.text_archive.clone();
        let stats_path = self.stats_path.clone();
        let mut engine = engine_owner
            .lock()
            .map_err(|_| "Statistics store unavailable")?;
        let mut archive = text_owner.lock().map_err(|_| "Text store unavailable")?;
        archive.retention_together_before_deleting(&stats_path, bytes, || {
            self.capture_active.store(false, Ordering::Relaxed);
            self.text_intent.store(0, Ordering::Relaxed);
            self.text_reset.fetch_add(1, Ordering::Relaxed);
            let advance_allowed = self.session_allows_collection();
            // Both owner locks remain held. Use the held Engine directly rather
            // than self.flush(), which would recursively acquire its mutex.
            flush_activity(
                &mut self.pending,
                &mut self.recovery,
                time(),
                true,
                advance_allowed,
                |value| engine.request(&value.to_string()),
            )?;
            // Preserve physical held keys; only a deletion invalidates the cursor
            // anchor. Failed flush retains the recovery cutoff and skips deletion.
            self.input.clear_cursor();
            Ok(())
        })
    }
    fn configure(
        &mut self,
        ep: String,
        secret: String,
        cap: Result<u64, std::num::ParseIntError>,
        enabled: bool,
        text_enabled: bool,
        text_sync_enabled: bool,
    ) -> Result<(), String> {
        if self.demo && (enabled || text_enabled || text_sync_enabled) {
            return Err("Demo mode never enables real input/text capture or remote sync.".into());
        }
        let mb = cap.map_err(|_| "Cap must be whole MiB (0 = unlimited)")?;
        if mb != 0 && mb < 1 {
            return Err("Minimum cap is 1 MiB".into());
        }
        let bytes = mb.checked_mul(1024 * 1024).ok_or("Cap is too large")?;
        if !ep.is_empty() {
            endpoint(&ep)?;
        }
        if (enabled || text_sync_enabled) && ep.is_empty() {
            return Err("Configure a private HTTPS endpoint before enabling sync".into());
        }
        let mut live = self.settings.lock().map_err(|_| "Settings unavailable")?;
        let mut cfg = live.clone();
        if !secret.is_empty() {
            if secret.len() < 43
                || secret.len() > 256
                || !secret
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            {
                return Err("Use an opaque collector credential (43-256 ASCII characters)".into());
            }
            cfg.protected_token = protect(secret.as_bytes(), false)?;
            cfg.cursor = 0;
            cfg.replica_id.clear();
            cfg.text_cursor = 0;
            cfg.text_replica_id.clear();
        }
        if ep != cfg.endpoint {
            cfg.cursor = 0;
            cfg.replica_id.clear();
            cfg.text_cursor = 0;
            cfg.text_replica_id.clear();
        }
        if (enabled || text_sync_enabled) && cfg.protected_token.is_empty() {
            return Err("A collector credential is required".into());
        }
        cfg.endpoint = ep;
        cfg.cap_bytes = bytes;
        cfg.sync_enabled = enabled;
        cfg.text_enabled = text_enabled;
        cfg.text_sync_enabled = text_sync_enabled;
        save(&self.config_path, &cfg)?;
        if live.text_enabled != text_enabled {
            self.text_reset.fetch_add(1, Ordering::Relaxed);
            self.text_intent.store(0, Ordering::Relaxed);
            self.capture_active.store(false, Ordering::Relaxed);
        }
        *live = cfg;
        drop(live);
        if bytes > 0 {
            let result = self.cleanup(bytes)?;
            if result["limitMet"] != true {
                return Err("Cleanup completed but combined statistics/text metadata and tombstones keep storage above the cap.".into());
            }
        }
        Ok(())
    }
}
#[derive(Clone)]
enum ManagementOperation {
    One(String),
    Text(f64, f64),
    Joint(f64, f64),
    All,
}
struct DataJob {
    operation: ManagementOperation,
    answer: Arc<Mutex<Option<bool>>>,
    result: Arc<Mutex<Option<Result<Value, String>>>>,
    started: bool,
}
fn clock_at(epoch: f64, utc: bool) -> Result<SYSTEMTIME, String> {
    unsafe {
        if !epoch.is_finite() || epoch < 0.0 || epoch >= 1e12 {
            return Err("Invalid clock instant".into());
        }
        let ticks = ((epoch + 11644473600.0) * 10000000.0) as u64;
        let file = FILETIME {
            dwLowDateTime: ticks as u32,
            dwHighDateTime: (ticks >> 32) as u32,
        };
        let mut system: SYSTEMTIME = zeroed();
        if FileTimeToSystemTime(&file, &mut system) == 0 {
            return Err("Clock instant is not representable".into());
        }
        if utc {
            return Ok(system);
        }
        let mut local: SYSTEMTIME = zeroed();
        if SystemTimeToTzSpecificLocalTimeEx(null(), &system, &mut local) == 0 {
            return Err("Local clock conversion failed".into());
        }
        Ok(local)
    }
}
fn clock_fields(epoch: f64, utc: bool) -> String {
    match clock_at(epoch, utc) {
        Ok(c) => format!(
            "{:04}-{:02}-{:02} {:02}:{:02}",
            c.wYear, c.wMonth, c.wDay, c.wHour, c.wMinute
        ),
        Err(_) => "".into(),
    }
}
fn local_hour_key(epoch: f64) -> Result<[u16; 4], String> {
    let c = clock_at(epoch, false)?;
    Ok([c.wYear, c.wMonth, c.wDay, c.wHour])
}
fn parse_management_time(value: &str, utc_mode: bool) -> Result<f64, String> {
    let civil = parse_civil_minute(value)?;
    unsafe {
        let local = SYSTEMTIME {
            wYear: civil.year,
            wMonth: civil.month,
            wDayOfWeek: 0,
            wDay: civil.day,
            wHour: civil.hour,
            wMinute: civil.minute,
            wSecond: 0,
            wMilliseconds: 0,
        };
        let mut utc = local;
        if !utc_mode && TzSpecificLocalTimeToSystemTimeEx(null(), &local, &mut utc) == 0 {
            return Err(
                "Local minute does not exist; use UTC for clock-transition boundaries.".into(),
            );
        }
        let mut file: FILETIME = zeroed();
        if SystemTimeToFileTime(&utc, &mut file) == 0 {
            return Err("Invalid calendar minute".into());
        }
        let ticks = ((file.dwHighDateTime as u64) << 32) | file.dwLowDateTime as u64;
        let unix = ticks
            .checked_sub(116444736000000000)
            .ok_or("Times before 1970 are unsupported")? as f64
            / 10000000.0;
        if unix % 60.0 != 0.0 || unix >= 1e12 {
            return Err("Choose a safe exact minute".into());
        }
        let original = clock_at(unix, utc_mode)?;
        let matches = |c: &SYSTEMTIME| {
            c.wYear == civil.year
                && c.wMonth == civil.month
                && c.wDay == civil.day
                && c.wHour == civil.hour
                && c.wMinute == civil.minute
        };
        if !matches(&original) {
            return Err("That local minute is skipped by a calendar transition; use UTC.".into());
        }
        if !utc_mode {
            for offset in -180..=180 {
                if offset != 0 {
                    let candidate = unix + offset as f64 * 60.0;
                    if candidate >= 0.0
                        && clock_at(candidate, false)
                            .map(|c| matches(&c))
                            .unwrap_or(false)
                    {
                        return Err("This local minute repeats during a clock transition. Use UTC to select an unambiguous interval.".into());
                    }
                }
            }
        }
        Ok(unix)
    }
}
impl App {
    unsafe fn open_manager(&mut self, owner: HWND) {
        if !self.manager.is_null() {
            ShowWindow(self.manager, SW_SHOW);
            SetForegroundWindow(self.manager);
            return;
        }
        let hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW,
            wide("KeyTrailManagement12").as_ptr(),
            wide("KeyTrail - local data management").as_ptr(),
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
            120,
            120,
            740,
            630,
            owner,
            null_mut(),
            GetModuleHandleW(null()),
            null(),
        );
        if hwnd.is_null() {
            *self.status.lock().unwrap() = "Could not open local data management.".into();
            return;
        }
        self.manager = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, self as *mut App as isize);
        let add =
            |class: &str, text: &str, id: usize, x: i32, y: i32, w: i32, h: i32, style: u32| {
                CreateWindowExW(
                    0,
                    wide(class).as_ptr(),
                    wide(text).as_ptr(),
                    WS_CHILD | WS_VISIBLE | style,
                    x,
                    y,
                    w,
                    h,
                    hwnd,
                    id as HMENU,
                    GetModuleHandleW(null()),
                    null(),
                )
            };
        add("STATIC","Local resident controls only. The browser remains read-only.\r\nEvery delete pauses collection; restart explicitly afterward. Deletion receipts are retained for private sync.",0,18,18,680,52,0);
        add(
            "STATIC",
            "Single text record UUID (use Copy record ID in the local dashboard):",
            0,
            18,
            90,
            680,
            24,
            0,
        );
        let id = add(
            "EDIT",
            "",
            DATA_ID,
            18,
            120,
            445,
            30,
            WS_BORDER | ES_AUTOHSCROLL as u32,
        );
        SendMessageW(id, 0x00C5, 36, 0);
        add(
            "BUTTON",
            "Delete one text record...",
            DATA_ONE,
            478,
            120,
            220,
            30,
            BS_PUSHBUTTON as u32,
        );
        add(
            "STATIC",
            "Start inclusive: YYYY-MM-DD HH:MM",
            0,
            18,
            180,
            330,
            24,
            0,
        );
        add(
            "STATIC",
            "End exclusive: YYYY-MM-DD HH:MM",
            0,
            368,
            180,
            330,
            24,
            0,
        );
        let end = (time() / 60.0).floor() * 60.0 + 60.0;
        let range = self
            .text_archive
            .lock()
            .unwrap()
            .last_view_range()
            .filter(|(a, b)| a % 60.0 == 0.0 && b % 60.0 == 0.0 && b > a)
            .unwrap_or((end - 86400.0, end));
        let start = add(
            "EDIT",
            &clock_fields(range.0, false),
            DATA_START,
            18,
            210,
            330,
            30,
            WS_BORDER | ES_AUTOHSCROLL as u32,
        );
        let end = add(
            "EDIT",
            &clock_fields(range.1, false),
            DATA_END,
            368,
            210,
            330,
            30,
            WS_BORDER | ES_AUTOHSCROLL as u32,
        );
        SendMessageW(start, 0x00C5, 16, 0);
        SendMessageW(end, 0x00C5, 16, 0);
        add(
            "BUTTON",
            "Interpret entered values as UTC (unchecked = local; values are not converted)",
            DATA_UTC,
            18,
            254,
            680,
            28,
            BS_AUTOCHECKBOX as u32,
        );
        add("STATIC","Local mode rejects missing or repeated DST minutes. Use UTC to select those boundaries.\r\nText-only deletion keeps physical counters. Joint deletion removes both stores in one transaction.",0,18,296,680,48,0);
        add(
            "BUTTON",
            "Delete text in range...",
            DATA_TEXT,
            18,
            364,
            210,
            34,
            BS_PUSHBUTTON as u32,
        );
        add(
            "BUTTON",
            "Delete statistics + text in range...",
            DATA_JOINT,
            242,
            364,
            290,
            34,
            BS_PUSHBUTTON as u32,
        );
        add(
            "BUTTON",
            "Clear all data...",
            DATA_ALL,
            546,
            364,
            152,
            34,
            BS_PUSHBUTTON as u32,
        );
        add(
            "STATIC",
            &self.data_status,
            DATA_STATUS,
            18,
            438,
            680,
            100,
            0,
        );
    }
    unsafe fn management_action(&mut self, hwnd: HWND, control: usize) {
        if self.data_job.is_some() {
            return;
        }
        let operation = match control {
            DATA_ONE => ManagementOperation::One(read_control(hwnd, DATA_ID)),
            DATA_TEXT | DATA_JOINT => {
                let utc = SendMessageW(GetDlgItem(hwnd, DATA_UTC as i32), BM_GETCHECK, 0, 0) == 1;
                let start = match parse_management_time(&read_control(hwnd, DATA_START), utc) {
                    Ok(value) => value,
                    Err(e) => {
                        self.data_status = e;
                        return;
                    }
                };
                let end = match parse_management_time(&read_control(hwnd, DATA_END), utc) {
                    Ok(value) => value,
                    Err(e) => {
                        self.data_status = e;
                        return;
                    }
                };
                if end <= start {
                    self.data_status = "End must be later than start; ranges are half-open.".into();
                    return;
                }
                if control == DATA_TEXT {
                    ManagementOperation::Text(start, end)
                } else {
                    ManagementOperation::Joint(start, end)
                }
            }
            DATA_ALL => ManagementOperation::All,
            _ => return,
        };
        self.pause();
        if self.recovery.pending().is_some() {
            self.data_status="Deletion was not started: the original activity boundary has not been saved. Resolve the storage error and retry.".into();
            return;
        }
        let preview: Result<String, String> = (|| match &operation {
            ManagementOperation::One(id) => {
                let meta = self
                    .text_archive
                    .lock()
                    .map_err(|_| "Text archive unavailable")?
                    .metadata_for_id(id)?
                    .ok_or("No text record has that UUID")?;
                Ok(format!("Delete exactly one encrypted text record?\r\nID: {}\r\n{}; application {}; {} recorded characters.\r\nPhysical statistics will remain unchanged.",meta.id,human_time(meta.timestamp),meta.app,meta.characters))
            }
            ManagementOperation::Text(start, end) => {
                let count = self
                    .text_archive
                    .lock()
                    .map_err(|_| "Text archive unavailable")?
                    .record_count(Some(*start), Some(*end))?;
                Ok(format!("Delete {count} text records only?\r\n{} inclusive to {} exclusive (local).\r\nUTC: {} to {}.\r\nPhysical statistics will remain unchanged.",human_time(*start),human_time(*end),clock_fields(*start,true),clock_fields(*end,true)))
            }
            ManagementOperation::Joint(start, end) => {
                let stats = request(
                    &self.engine,
                    json!({"op":"summary","start":start,"end":end}),
                )?;
                let minutes = stats["minuteCount"]
                    .as_u64()
                    .ok_or("Statistics count unavailable")?;
                let texts = self
                    .text_archive
                    .lock()
                    .map_err(|_| "Text archive unavailable")?
                    .record_count(Some(*start), Some(*end))?;
                Ok(format!("Atomically delete {minutes} statistical minute rows and {texts} text records?\r\n{} inclusive to {} exclusive (local).\r\nUTC: {} to {}.\r\nStatistics and text are deleted together; a failure on either side removes neither side.",human_time(*start),human_time(*end),clock_fields(*start,true),clock_fields(*end,true)))
            }
            ManagementOperation::All => {
                let stats = request(&self.engine, json!({"op":"storageInfo"}))?;
                let minutes = stats["minuteCount"]
                    .as_u64()
                    .ok_or("Statistics count unavailable")?;
                let texts = self
                    .text_archive
                    .lock()
                    .map_err(|_| "Text archive unavailable")?
                    .record_count(None, None)?;
                Ok(format!("Clear ALL {minutes} statistical minute rows and {texts} encrypted text records?\r\nSettings and encryption keys remain. Small deletion receipts are retained to remove previously synced copies.\r\nCollection will remain paused until you explicitly Start again."))
            }
        })();
        let description=match preview{Ok(value)=>format!("{value}\r\n\r\nThis cannot be undone. Deletions propagate on the next enabled successful sync.\r\nCollection is paused even if you cancel."),Err(e)=>{self.data_status=e;return}};
        let answer = Arc::new(Mutex::new(None));
        let target = answer.clone();
        let owner = hwnd as usize;
        thread::spawn(move || {
            let confirmed = MessageBoxW(
                owner as HWND,
                wide(&description).as_ptr(),
                wide("KeyTrail - confirm local deletion").as_ptr(),
                MB_YESNO | MB_ICONWARNING,
            ) == IDYES;
            *target.lock().unwrap() = Some(confirmed);
        });
        self.data_job = Some(DataJob {
            operation,
            answer,
            result: Arc::new(Mutex::new(None)),
            started: false,
        });
        self.data_status = "Review the native confirmation. Collection is paused.".into();
    }
    fn poll_management(&mut self) {
        let Some(job) = &mut self.data_job else {
            return;
        };
        if !job.started {
            let answer = job.answer.lock().unwrap().take();
            match answer {
                None => return,
                Some(false) => {
                    self.data_status =
                        "Cancelled. No data was deleted; collection remains paused.".into();
                    self.data_job = None;
                    return;
                }
                Some(true) => {
                    job.started = true;
                    let op = job.operation.clone();
                    let result = job.result.clone();
                    let engine = self.engine.clone();
                    let archive = self.text_archive.clone();
                    let path = self.stats_path.clone();
                    thread::spawn(move || {
                        let outcome = (|| {
                            let _owner =
                                engine.lock().map_err(|_| "Statistics store unavailable")?;
                            let mut text = archive.lock().map_err(|_| "Text store unavailable")?;
                            match op {
                                ManagementOperation::One(id) => Ok(
                                    json!({"deletedStatisticsMinutes":0,"deletedTextRecords":if text.delete_id(&id)?{1}else{0}}),
                                ),
                                ManagementOperation::Text(start, end) => Ok(
                                    json!({"deletedStatisticsMinutes":0,"deletedTextRecords":text.delete(start,end)?}),
                                ),
                                ManagementOperation::Joint(start, end) => {
                                    text.delete_together(&path, start, end)
                                }
                                ManagementOperation::All => text.clear_together(&path),
                            }
                        })();
                        *result.lock().unwrap() = Some(outcome);
                    });
                    self.data_status =
                        "Deleting locally in a resident-owned worker. Collection remains paused."
                            .into();
                    return;
                }
            }
        }
        let outcome = job.result.lock().unwrap().take();
        if let Some(outcome) = outcome {
            self.data_status=match outcome{Ok(value)=>format!("Completed: {} statistical minutes and {} text records deleted. Private deletion sync is queued. Collection remains paused; use Start to resume.",value["deletedStatisticsMinutes"],value["deletedTextRecords"]),Err(error)=>format!("The operation did not return a verified result: {error}. Collection remains paused. Check the history before retrying.")};
            self.data_job = None;
        }
    }
}
unsafe extern "system" fn manager_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut App;
    if !pointer.is_null() {
        if message == WM_COMMAND
            && (wparam >> 16) & 0xffff == 0
            && [DATA_ONE, DATA_TEXT, DATA_JOINT, DATA_ALL].contains(&(wparam & 0xffff))
        {
            let app = &mut *pointer;
            app.management_action(hwnd, wparam & 0xffff);
            SetWindowTextW(
                GetDlgItem(hwnd, DATA_STATUS as i32),
                wide(&app.data_status).as_ptr(),
            );
            for control in [DATA_ONE, DATA_TEXT, DATA_JOINT, DATA_ALL] {
                EnableWindow(
                    GetDlgItem(hwnd, control as i32),
                    if app.data_job.is_none() { 1 } else { 0 },
                );
            }
            return 0;
        }
        if message == WM_CLOSE {
            let app = &mut *pointer;
            if app.data_job.is_some() {
                app.data_status =
                    "Finish or cancel the confirmation/operation before closing this window."
                        .into();
                return 0;
            }
            app.manager = null_mut();
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            DestroyWindow(hwnd);
            return 0;
        }
    }
    DefWindowProcW(hwnd, message, wparam, lparam)
}

fn human_time(epoch: f64) -> String {
    unsafe {
        let ticks = ((epoch + 11644473600.0) * 10000000.0) as u64;
        let file = FILETIME {
            dwLowDateTime: ticks as u32,
            dwHighDateTime: (ticks >> 32) as u32,
        };
        let mut utc: SYSTEMTIME = zeroed();
        let mut local: SYSTEMTIME = zeroed();
        if FileTimeToSystemTime(&file, &mut utc) != 0
            && SystemTimeToTzSpecificLocalTimeEx(null(), &utc, &mut local) != 0
        {
            format!(
                "{:04}-{:02}-{:02} {:02}:{:02} local",
                local.wYear, local.wMonth, local.wDay, local.wHour, local.wMinute
            )
        } else {
            "Unrepresentable local date".into()
        }
    }
}
unsafe fn copy_clipboard(hwnd: HWND, text: &str) -> Result<(), String> {
    if OpenClipboard(hwnd) == 0 {
        return Err("Clipboard unavailable".into());
    }
    EmptyClipboard();
    let value = wide(text);
    let memory = GlobalAlloc(GMEM_MOVEABLE, value.len() * 2);
    if memory.is_null() {
        CloseClipboard();
        return Err("Clipboard allocation failed".into());
    }
    let pointer = GlobalLock(memory) as *mut u16;
    if pointer.is_null() {
        GlobalFree(memory);
        CloseClipboard();
        return Err("Clipboard allocation failed".into());
    }
    std::ptr::copy_nonoverlapping(value.as_ptr(), pointer, value.len());
    GlobalUnlock(memory);
    let okay = !SetClipboardData(13, memory).is_null();
    if !okay {
        GlobalFree(memory);
    }
    CloseClipboard();
    if okay {
        Ok(())
    } else {
        Err("Could not copy credential".into())
    }
}
unsafe fn read_control(hwnd: HWND, id: usize) -> String {
    let h = GetDlgItem(hwnd, id as i32);
    let len = GetWindowTextLengthW(h).max(0) as usize;
    let mut text = vec![0u16; len + 1];
    GetWindowTextW(h, text.as_mut_ptr(), text.len() as i32);
    String::from_utf16_lossy(&text[..len]).trim().into()
}
fn login_enabled() -> bool {
    unsafe {
        let mut key = null_mut();
        if RegOpenKeyExW(
            HKEY_CURRENT_USER,
            wide("Software\\Microsoft\\Windows\\CurrentVersion\\Run").as_ptr(),
            0,
            KEY_QUERY_VALUE,
            &mut key,
        ) != 0
        {
            return false;
        }
        let mut kind = 0;
        let mut length = 0;
        let mut text = vec![0u16; 32768];
        let first = RegQueryValueExW(
            key,
            wide("KeyTrail").as_ptr(),
            null(),
            &mut kind,
            null_mut(),
            &mut length,
        );
        let good = first == 0
            && kind == REG_SZ
            && length as usize <= text.len() * 2
            && RegQueryValueExW(
                key,
                wide("KeyTrail").as_ptr(),
                null(),
                &mut kind,
                text.as_mut_ptr() as *mut u8,
                &mut length,
            ) == 0;
        RegCloseKey(key);
        if !good {
            return false;
        }
        let value = String::from_utf16_lossy(&text[..(length as usize / 2).saturating_sub(1)]);
        std::env::current_exe()
            .map(|p| value == format!("\"{}\" --login", p.display()))
            .unwrap_or(false)
    }
}
fn login(enable: bool) -> Result<(), String> {
    unsafe {
        let mut key = null_mut();
        let result = RegCreateKeyExW(
            HKEY_CURRENT_USER,
            wide("Software\\Microsoft\\Windows\\CurrentVersion\\Run").as_ptr(),
            0,
            null(),
            0,
            KEY_SET_VALUE,
            null(),
            &mut key,
            null_mut(),
        );
        if result != 0 {
            return Err("Could not open current-user login settings".into());
        }
        let code = if enable {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            let text = wide(&format!("\"{}\" --login", exe.display()));
            RegSetValueExW(
                key,
                wide("KeyTrail").as_ptr(),
                0,
                REG_SZ,
                text.as_ptr() as *const u8,
                (text.len() * 2) as u32,
            )
        } else {
            let r = RegDeleteValueW(key, wide("KeyTrail").as_ptr());
            if r == ERROR_FILE_NOT_FOUND {
                0
            } else {
                r
            }
        };
        RegCloseKey(key);
        if code != 0 {
            return Err("Could not update current-user login settings".into());
        }
        Ok(())
    }
}
unsafe fn raw(app: &mut App, lparam: LPARAM) {
    let mut raw: RAWINPUT = zeroed();
    let mut size = size_of::<RAWINPUT>() as u32;
    let got = GetRawInputData(
        lparam as HRAWINPUT,
        RID_INPUT,
        &mut raw as *mut _ as *mut c_void,
        &mut size,
        size_of::<RAWINPUTHEADER>() as u32,
    );
    if got == u32::MAX || got < size_of::<RAWINPUTHEADER>() as u32 {
        return;
    }
    if !app.running() {
        app.input.reset();
        return;
    }
    let now = time();
    if raw.header.dwType == RIM_TYPEKEYBOARD {
        let k = raw.data.keyboard;
        if k.Flags & RI_KEY_BREAK as u16 == 0 {
            app.text_intent
                .store((now * 1000.0) as u64, Ordering::Relaxed);
        }
        if k.Flags & RI_KEY_E1 as u16 != 0 {
            return;
        }
        if let Some(label) = app.input.key(
            k.MakeCode,
            k.Flags & RI_KEY_E0 as u16 != 0,
            k.Flags & RI_KEY_BREAK as u16 != 0,
        ) {
            app.record(sample(now, "keyPress", Some(label), 0.0, 0.0));
        }
    } else if raw.header.dwType == RIM_TYPEMOUSE {
        let m = raw.data.mouse;
        let buttons = m.Anonymous.Anonymous.usButtonFlags;
        if buttons
            & (RI_MOUSE_LEFT_BUTTON_DOWN | RI_MOUSE_RIGHT_BUTTON_DOWN | RI_MOUSE_MIDDLE_BUTTON_DOWN)
                as u16
            != 0
        {
            app.text_reset.fetch_add(1, Ordering::Relaxed);
            app.text_intent
                .store((now * 1000.0) as u64, Ordering::Relaxed);
        }
        if buttons & RI_MOUSE_LEFT_BUTTON_DOWN as u16 != 0 {
            app.record(sample(now, "leftClick", None, 0.0, 0.0))
        }
        if buttons & RI_MOUSE_RIGHT_BUTTON_DOWN as u16 != 0 {
            app.record(sample(now, "rightClick", None, 0.0, 0.0))
        }
        if buttons & RI_MOUSE_MIDDLE_BUTTON_DOWN as u16 != 0 {
            app.record(sample(now, "middleClick", None, 0.0, 0.0))
        }
        if buttons & (RI_MOUSE_WHEEL | RI_MOUSE_HWHEEL) as u16 != 0 {
            let delta = m.Anonymous.Anonymous.usButtonData as i16 as f64 / 120.0;
            app.record(sample(now, "scroll", None, 0.0, delta))
        }
        let mut p: POINT = zeroed();
        if GetCursorPos(&mut p) != 0 {
            let dpi = 96; // Process uses the default 96-DPI logical coordinate space; raw HID counts are never used.
            if let Some(distance) = app.input.movement(p.x, p.y, dpi) {
                app.record(sample(now, "mouseMove", None, distance, 0.0));
            }
        }
    }
}
unsafe extern "system" fn float_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_CLOSE {
        let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut App;
        if !ptr.is_null() {
            (*ptr).settings.lock().unwrap().floating = false;
            (*ptr).persist();
            (*ptr).float = null_mut();
        }
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        DestroyWindow(hwnd);
        return 0;
    }
    DefWindowProcW(hwnd, message, wparam, lparam)
}
unsafe extern "system" fn proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == DEFERRED_QUIT {
        DestroyWindow(hwnd);
        return 0;
    }
    if message == WM_COMMAND && (wparam >> 16) & 0xffff != 0 {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    if !matches!(
        message,
        WM_COMMAND
            | WM_INPUT
            | WM_TIMER
            | WM_WTSSESSION_CHANGE
            | WM_POWERBROADCAST
            | TRAY
            | WM_CLOSE
            | WM_DESTROY
    ) {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut App;
    if !ptr.is_null() {
        let app = &mut *ptr;
        match message {
            WM_COMMAND => {
                app.command(hwnd, wparam & 0xffff);
                return 0;
            }
            WM_INPUT => {
                raw(app, lparam);
                return DefWindowProcW(hwnd, message, wparam, lparam);
            }
            WM_TIMER => {
                if app.running() || app.recovery.pending().is_some() {
                    if let Err(e) = app.flush(false) {
                        app.enabled = false;
                        *app.status.lock().unwrap() = format!("Collection paused: {e}")
                    }
                }
                app.ticks = app.ticks.wrapping_add(1);
                if app.ticks % 60 == 0
                    && !app.demo
                    && app.pending.is_empty()
                    && app.data_job.is_none()
                {
                    let cap = app.settings.lock().unwrap().cap_bytes;
                    if cap > 0 {
                        match app.cleanup(cap){Ok(v) if v["limitMet"]==true=>{},Ok(_)=>*app.status.lock().unwrap()="Storage cap remains unmet because metadata/tombstones require space.".into(),Err(e)=>*app.status.lock().unwrap()=format!("Storage cleanup: {e}")}
                    }
                }
                app.update(hwnd);
                return 0;
            }
            WM_WTSSESSION_CHANGE => {
                if matches!(
                    wparam as u32,
                    WTS_SESSION_LOCK
                        | WTS_CONSOLE_DISCONNECT
                        | WTS_REMOTE_DISCONNECT
                        | WTS_SESSION_LOGOFF
                ) {
                    app.capture_active.store(false, Ordering::Relaxed);
                    app.text_reset.fetch_add(1, Ordering::Relaxed);
                    app.text_intent.store(0, Ordering::Relaxed);
                    let _ = app.flush(true);
                    app.locked = true;
                    app.input.reset()
                } else if matches!(
                    wparam as u32,
                    WTS_SESSION_UNLOCK | WTS_CONSOLE_CONNECT | WTS_REMOTE_CONNECT
                ) {
                    app.locked = false;
                    app.input.reset()
                }
                app.update(hwnd);
                return 0;
            }
            WM_POWERBROADCAST => {
                if wparam == PBT_APMSUSPEND as usize {
                    app.capture_active.store(false, Ordering::Relaxed);
                    app.text_reset.fetch_add(1, Ordering::Relaxed);
                    app.text_intent.store(0, Ordering::Relaxed);
                    let _ = app.flush(true);
                    app.suspended = true;
                    app.input.reset()
                } else if wparam == PBT_APMRESUMEAUTOMATIC as usize
                    || wparam == PBT_APMRESUMESUSPEND as usize
                {
                    app.suspended = false;
                    app.input.reset()
                }
                return 1;
            }
            TRAY => {
                if lparam as u32 == WM_LBUTTONUP {
                    ShowWindow(hwnd, SW_SHOW);
                    SetForegroundWindow(hwnd);
                } else if lparam as u32 == WM_RBUTTONUP {
                    let menu = CreatePopupMenu();
                    for (id, label) in [
                        (START, "Start / pause collection"),
                        (DASH, "Open read-only dashboard"),
                        (FLOAT, "Toggle current-hour window"),
                        (TEXTCLEAR, "Manage/delete local data..."),
                        (QUIT, "Quit KeyTrail"),
                    ] {
                        AppendMenuW(menu, MF_STRING, id, wide(label).as_ptr());
                    }
                    let mut point: POINT = zeroed();
                    GetCursorPos(&mut point);
                    SetForegroundWindow(hwnd);
                    let command = TrackPopupMenu(
                        menu,
                        TPM_RETURNCMD | TPM_RIGHTBUTTON,
                        point.x,
                        point.y,
                        0,
                        hwnd,
                        null(),
                    ) as usize;
                    DestroyMenu(menu);
                    if command != 0 {
                        app.command(hwnd, command)
                    }
                }
                return 0;
            }
            WM_CLOSE => {
                ShowWindow(
                    hwnd,
                    if app.tray_available {
                        SW_HIDE
                    } else {
                        SW_MINIMIZE
                    },
                );
                return 0;
            }
            WM_DESTROY => {
                WTSUnRegisterSessionNotification(hwnd);
                let mut icon: NOTIFYICONDATAW = zeroed();
                icon.cbSize = size_of::<NOTIFYICONDATAW>() as u32;
                icon.hWnd = hwnd;
                icon.uID = 1;
                Shell_NotifyIconW(NIM_DELETE, &icon);
                app.stop.store(true, Ordering::Relaxed);
                PostQuitMessage(0);
                return 0;
            }
            _ => {}
        }
    }
    DefWindowProcW(hwnd, message, wparam, lparam)
}
unsafe fn controls(hwnd: HWND, cfg: &Settings) {
    let instance = GetModuleHandleW(null());
    let add = |class: &str, text: &str, id: usize, x: i32, y: i32, w: i32, h: i32, style: u32| {
        CreateWindowExW(
            0,
            wide(class).as_ptr(),
            wide(text).as_ptr(),
            WS_CHILD | WS_VISIBLE | style,
            x,
            y,
            w,
            h,
            hwnd,
            id as HMENU,
            instance,
            null(),
        )
    };
    add(
        "STATIC",
        "KeyTrail 1.2 | personal local-first input statistics",
        0,
        18,
        16,
        560,
        25,
        0,
    );
    add("STATIC","Only Start enables capture; optional text defaults off.\r\nClose hides to tray, or minimizes when no tray is available.\r\nQuit stops resident + workers. No clipboard capture.",0,18,48,570,48,0);
    add(
        "BUTTON",
        "Start collection",
        START,
        18,
        104,
        172,
        32,
        BS_PUSHBUTTON as u32,
    );
    add(
        "BUTTON",
        "Open dashboard",
        DASH,
        202,
        104,
        172,
        32,
        BS_PUSHBUTTON as u32,
    );
    add(
        "BUTTON",
        "Copy viewer credential",
        COPY,
        386,
        104,
        180,
        32,
        BS_PUSHBUTTON as u32,
    );
    add(
        "BUTTON",
        "Toggle current-hour window",
        FLOAT,
        18,
        148,
        260,
        32,
        BS_PUSHBUTTON as u32,
    );
    add(
        "BUTTON",
        "Toggle login startup (default off)",
        LOGIN,
        290,
        148,
        276,
        32,
        BS_PUSHBUTTON as u32,
    );
    add(
        "STATIC",
        "Private HTTPS origin (HTTP allowed only on loopback)",
        0,
        18,
        200,
        550,
        24,
        0,
    );
    add(
        "EDIT",
        &cfg.endpoint,
        ENDPOINT,
        18,
        228,
        548,
        28,
        WS_BORDER | ES_AUTOHSCROLL as u32,
    );
    add(
        "STATIC",
        "Collector credential (blank keeps existing DPAPI-protected credential)",
        0,
        18,
        270,
        550,
        24,
        0,
    );
    add(
        "EDIT",
        "",
        TOKEN,
        18,
        298,
        548,
        28,
        WS_BORDER | ES_PASSWORD as u32 | ES_AUTOHSCROLL as u32,
    );
    add(
        "STATIC",
        "Statistics + text cap (MiB); 0 = unlimited\r\nOldest natural minutes are removed first.",
        0,
        18,
        332,
        550,
        32,
        0,
    );
    add(
        "EDIT",
        &(cfg.cap_bytes / 1024 / 1024).to_string(),
        CAP,
        18,
        368,
        160,
        28,
        WS_BORDER | ES_NUMBER as u32,
    );
    let checkbox = add(
        "BUTTON",
        "Enable private aggregate sync (default off)",
        SYNCEN,
        190,
        368,
        375,
        28,
        BS_AUTOCHECKBOX as u32,
    );
    SendMessageW(
        checkbox,
        BM_SETCHECK,
        if cfg.sync_enabled { 1 } else { 0 },
        0,
    );
    add(
        "BUTTON",
        "Save settings / apply cap",
        SAVE,
        18,
        418,
        220,
        32,
        BS_PUSHBUTTON as u32,
    );
    add(
        "BUTTON",
        "Sync now",
        SYNC,
        250,
        418,
        120,
        32,
        BS_PUSHBUTTON as u32,
    );
    add(
        "BUTTON",
        "Quit KeyTrail",
        QUIT,
        382,
        418,
        184,
        32,
        BS_PUSHBUTTON as u32,
    );
    let text_box = add(
        "BUTTON",
        "Record optional committed text locally (default off)",
        TEXTEN,
        18,
        474,
        548,
        28,
        BS_AUTOCHECKBOX as u32,
    );
    SendMessageW(
        text_box,
        BM_SETCHECK,
        if cfg.text_enabled { 1 } else { 0 },
        0,
    );
    let text_sync = add(
        "BUTTON",
        "Enable independent encrypted text sync (default off)",
        TEXTSYNC,
        18,
        506,
        548,
        28,
        BS_AUTOCHECKBOX as u32,
    );
    SendMessageW(
        text_sync,
        BM_SETCHECK,
        if cfg.text_sync_enabled { 1 } else { 0 },
        0,
    );
    add(
        "BUTTON",
        "Copy text decryption key",
        TEXTKEY,
        18,
        548,
        270,
        30,
        BS_PUSHBUTTON as u32,
    );
    add(
        "BUTTON",
        "Manage/delete local data...",
        TEXTCLEAR,
        300,
        548,
        266,
        30,
        BS_PUSHBUTTON as u32,
    );
    // Read-only, keyboard-focusable status: long errors and wrapped lines remain
    // reachable without growing the fixed control window or exposing editable settings.
    add(
        "EDIT",
        "",
        STATUS,
        18,
        600,
        550,
        115,
        WS_BORDER
            | WS_TABSTOP
            | WS_VSCROLL
            | ES_MULTILINE as u32
            | ES_AUTOVSCROLL as u32
            | ES_READONLY as u32,
    );
}
pub fn show_error(message: &str) {
    unsafe {
        MessageBoxW(
            null_mut(),
            wide(message).as_ptr(),
            wide("KeyTrail").as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}
pub fn run() -> Result<(), String> {
    unsafe {
        let demo = std::env::args().any(|a| a == "--demo");
        let base =
            PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA unavailable")?)
                .join(if demo {
                    "KeyTrail-Demo-v1.2"
                } else {
                    "KeyTrail"
                });
        fs::create_dir_all(&base).map_err(|e| e.to_string())?;
        let config_path = base.join("settings.json");
        let mut cfg: Settings = if config_path.exists() {
            serde_json::from_slice(&fs::read(&config_path).map_err(|e| e.to_string())?)
                .map_err(|_| "Invalid settings; preserve and inspect the file before restarting")?
        } else {
            Settings::default()
        };
        if cfg.device_id.is_empty() {
            cfg.device_id = format!("win-{}", &random()?[..24]);
        }
        if !demo {
            cfg.launch_at_login = login_enabled();
        }
        if demo {
            cfg.sync_enabled = false;
            cfg.launch_at_login = false;
            cfg.cap_bytes = 0;
            cfg.text_enabled = false;
            cfg.text_sync_enabled = false;
        }
        // A share-denied file handle locks this user profile across console/RDP sessions.
        let owner_path = wide(&base.join("owner.lock").to_string_lossy());
        let instance = CreateFileW(
            owner_path.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            0,
            null(),
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        );
        if instance == INVALID_HANDLE_VALUE {
            return Err(
                "Another KeyTrail resident owns this user profile, or the profile is inaccessible."
                    .into(),
            );
        }
        save(&config_path, &cfg)?;
        let engine = Arc::new(Mutex::new(Engine::open(
            base.join("aggregates.sqlite")
                .to_str()
                .ok_or("Invalid database path")?,
        )?));
        if demo {
            let now = time();
            let start = (now / 60.0).floor() * 60.0 - 60.0;
            let samples: Vec<_> = (0..30)
                .map(|i| sample(start + i as f64 * 0.1, "keyPress", Some("A"), 0.0, 0.0))
                .collect();
            request(
                &engine,
                json!({"op":"ingest","samples":samples,"observedThrough":now.max(start+3.0)}),
            )?;
            request(&engine, json!({"op":"end","time":now.max(start+3.0)}))?;
        }
        let text_path = base.join("text-archive.sqlite");
        if cfg.protected_text_key.is_empty() {
            if text_path.exists() {
                return Err("Existing text archive has no saved DPAPI key; preserve the database and recover its key.".into());
            }
            cfg.protected_text_key = protect(&random_key(), false)?;
            save(&config_path, &cfg)?;
        }
        let raw = protect(&cfg.protected_text_key, true)?;
        let text_key: [u8; 32] = raw.try_into().map_err(|_| "Invalid protected text key")?;
        let text_archive = Arc::new(Mutex::new(TextArchive::open(&text_path, text_key)?));
        let viewer_token = random()?;
        let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
        let url = format!(
            "http://{}",
            listener.local_addr().map_err(|e| e.to_string())?
        );
        let service = keytrail_server::Service::local_view(
            engine.clone(),
            viewer_token.clone(),
            cfg.device_id.clone(),
            demo,
        )?
        .with_local_text(text_archive.clone());
        let stop = Arc::new(AtomicBool::new(false));
        let server_stop = stop.clone();
        let server =
            thread::spawn(move || keytrail_server::serve_until(listener, service, server_stop));
        let settings = Arc::new(Mutex::new(cfg.clone()));
        let status = Arc::new(Mutex::new(
            "Ready. Private sync is disabled unless you enable it.".into(),
        ));
        let sync_now = Arc::new(AtomicBool::new(false));
        let sync_status = Arc::new(Mutex::new(
            "Private aggregate/text sync disabled unless enabled explicitly.".into(),
        ));
        let worker = sync::spawn(
            engine.clone(),
            text_archive.clone(),
            settings.clone(),
            config_path.clone(),
            sync_status.clone(),
            stop.clone(),
            sync_now.clone(),
        );
        let capture_active = Arc::new(AtomicBool::new(false));
        let text_status = Arc::new(Mutex::new(
            "Disabled until optional text recording is explicitly enabled.".into(),
        ));
        let text_intent = Arc::new(AtomicU64::new(0));
        let text_reset = Arc::new(AtomicU64::new(0));
        let text_worker = text_capture::spawn(
            text_archive.clone(),
            settings.clone(),
            capture_active.clone(),
            text_intent.clone(),
            text_reset.clone(),
            text_status.clone(),
            stop.clone(),
        );
        let module = GetModuleHandleW(null());
        let mut wc: WNDCLASSW = zeroed();
        wc.lpfnWndProc = Some(proc);
        wc.hInstance = module;
        let class = wide(CLASS);
        wc.lpszClassName = class.as_ptr();
        wc.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
        wc.hbrBackground = (COLOR_WINDOW + 1) as HBRUSH;
        if RegisterClassW(&wc) == 0 {
            return Err("Could not register control window".into());
        }
        let float_class = wide("KeyTrailFloat12");
        let mut fw: WNDCLASSW = zeroed();
        fw.lpfnWndProc = Some(float_proc);
        fw.hInstance = module;
        fw.lpszClassName = float_class.as_ptr();
        fw.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
        fw.hbrBackground = (COLOR_WINDOW + 1) as HBRUSH;
        if RegisterClassW(&fw) == 0 {
            return Err("Could not register floating window".into());
        }
        let manager_class = wide("KeyTrailManagement12");
        let mut mw: WNDCLASSW = zeroed();
        mw.lpfnWndProc = Some(manager_proc);
        mw.hInstance = module;
        mw.lpszClassName = manager_class.as_ptr();
        mw.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
        mw.hbrBackground = (COLOR_WINDOW + 1) as HBRUSH;
        if RegisterClassW(&mw) == 0 {
            return Err("Could not register data management window".into());
        }
        let hwnd = CreateWindowExW(
            0,
            class.as_ptr(),
            wide(if demo {
                "KeyTrail 1.2 — DEMO"
            } else {
                "KeyTrail 1.2 — local collector"
            })
            .as_ptr(),
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_SIZEBOX | WS_MAXIMIZEBOX,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            610,
            790,
            null_mut(),
            null_mut(),
            module,
            null(),
        );
        if hwnd.is_null() {
            return Err("Could not create control window".into());
        }
        let mut app = Box::new(App {
            engine,
            text_archive,
            text_status,
            capture_active,
            text_intent,
            text_reset,
            settings,
            config_path,
            stats_path: base.join("aggregates.sqlite"),
            input: InputState::default(),
            pending: Vec::new(),
            enabled: false,
            recovery: RecoveryCutoff::default(),
            capture_ready: true,
            tray_available: false,
            locked: false,
            suspended: false,
            demo,
            viewer_token,
            url,
            float: null_mut(),
            manager: null_mut(),
            data_job: None,
            data_status: "Deletes pause collection; restart explicitly after completion.".into(),
            displayed_status: String::new(),
            status,
            sync_status,
            stop: stop.clone(),
            sync_now,
            instance,
            ticks: 0,
        });
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, &mut *app as *mut App as isize);
        controls(hwnd, &cfg);
        let devices = [
            RAWINPUTDEVICE {
                usUsagePage: 1,
                usUsage: 6,
                dwFlags: RIDEV_INPUTSINK,
                hwndTarget: hwnd,
            },
            RAWINPUTDEVICE {
                usUsagePage: 1,
                usUsage: 2,
                dwFlags: RIDEV_INPUTSINK,
                hwndTarget: hwnd,
            },
        ];
        if !demo
            && RegisterRawInputDevices(
                devices.as_ptr(),
                devices.len() as u32,
                size_of::<RAWINPUTDEVICE>() as u32,
            ) == 0
        {
            app.capture_ready = false;
            *app.status.lock().unwrap() = "Input registration failed; collection disabled.".into()
        }
        if WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION) == 0 {
            app.capture_ready = false;
            *app.status.lock().unwrap() =
                "Session notification registration failed; collection disabled.".into()
        }
        let mut icon: NOTIFYICONDATAW = zeroed();
        icon.cbSize = size_of::<NOTIFYICONDATAW>() as u32;
        icon.hWnd = hwnd;
        icon.uID = 1;
        icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        icon.uCallbackMessage = TRAY;
        icon.hIcon = LoadIconW(null_mut(), IDI_APPLICATION);
        for (i, c) in "KeyTrail — paused until Start".encode_utf16().enumerate() {
            icon.szTip[i] = c
        }
        app.tray_available = Shell_NotifyIconW(NIM_ADD, &icon) != 0;
        if !app.tray_available {
            *app.status.lock().unwrap() = "Tray icon unavailable; use this window to Quit.".into()
        }
        SetTimer(hwnd, 1, 1000, None);
        app.update(hwnd);
        ShowWindow(hwnd, SW_SHOW);
        let mut message: MSG = zeroed();
        while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        stop.store(true, Ordering::Relaxed);
        if !app.float.is_null() {
            DestroyWindow(app.float);
        }
        let worker_deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !worker.is_finished() && std::time::Instant::now() < worker_deadline {
            thread::sleep(Duration::from_millis(50));
        }
        if worker.is_finished() {
            let _ = worker.join();
        }
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !text_worker.is_finished() && std::time::Instant::now() < deadline {
            thread::sleep(Duration::from_millis(50));
        }
        if text_worker.is_finished() {
            let _ = text_worker.join();
        } // Process exit terminates a provider that ignores UIA's configured timeout.

        let _ = server.join();
        CloseHandle(app.instance);
        Ok(())
    }
}

#[cfg(test)]
#[path = "native_retention_tests.rs"]
mod retention_tests;
