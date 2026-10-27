//! Private, bounded HTTP replica service. No event collection is present here.
mod encrypted_text;
use encrypted_text::TextReplica;
use keytrail_core::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::{
    collections::BTreeMap,
    fs,
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
const MAX_BODY: usize = 2 * 1024 * 1024;
const MAX_HEADER: usize = 8192;
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AccountConfig {
    pub id: String,
    pub device_id: String,
    pub collector_token: String,
    pub viewer_token: String,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub bind: String,
    #[serde(default)]
    pub demo_data: bool,
    pub data_dir: PathBuf,
    pub accounts: Vec<AccountConfig>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Metadata {
    replica_id: String,
    last_synced_at: Option<u64>,
    cursor: u64,
}
struct Account {
    config: AccountConfig,
    engine: Engine,
    meta: Metadata,
    meta_path: PathBuf,
    text: TextReplica,
}
pub struct Service {
    local: Option<LocalView>,
    demo_data: bool,
    accounts: Vec<Account>,
}
pub trait LocalTextSource: Send {
    fn version(&self) -> Result<Option<u64>, String> {
        Ok(None)
    }
    fn query_encrypted(&mut self, request: Value) -> Result<Value, String>;
}
struct LocalView {
    engine: Arc<Mutex<Engine>>,
    token: String,
    device_id: String,
    text: Option<Arc<Mutex<dyn LocalTextSource>>>,
}
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
    pub content_type: &'static str,
}
fn response(status: u16, value: Value) -> Response {
    Response {
        status,
        body: serde_json::to_vec(&value).unwrap(),
        content_type: "application/json; charset=utf-8",
    }
}
fn error(status: u16, message: &str) -> Response {
    response(status, json!({"ok":false,"error":message}))
}
fn success(value: Value) -> Response {
    let reply = response(200, json!({"ok":true,"result":value}));
    if reply.body.len() > 16 * 1024 * 1024 {
        error(413, "result too large; choose a smaller range")
    } else {
        reply
    }
}
fn identifier(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 80
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn equal(a: &str, b: &str) -> bool {
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        diff |= (a.as_bytes().get(i).copied().unwrap_or(0)
            ^ b.as_bytes().get(i).copied().unwrap_or(0)) as usize;
    }
    diff == 0
}
fn private_dir(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    Ok(())
}
fn write_private(path: &Path, bytes: &[u8], create_new: bool) -> Result<(), String> {
    let mut o = fs::OpenOptions::new();
    o.write(true);
    if create_new {
        o.create_new(true);
    } else {
        o.create(true).truncate(true);
    }
    #[cfg(unix)]
    o.mode(0o600);
    let mut f = o.open(path).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    f.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|e| e.to_string())?;
    f.write_all(bytes)
        .and_then(|_| f.sync_all())
        .map_err(|e| e.to_string())
}
fn save_meta(path: &Path, meta: &Metadata) -> Result<(), String> {
    let tmp = path.with_extension("new");
    write_private(
        &tmp,
        &serde_json::to_vec(meta).map_err(|e| e.to_string())?,
        false,
    )?;
    fs::rename(tmp, path).map_err(|e| e.to_string())
}
fn replica_id() -> Result<String, String> {
    let h = random_hex()?;
    Ok(format!(
        "{}-{}-4{}-a{}-{}",
        &h[..8],
        &h[8..12],
        &h[13..16],
        &h[17..20],
        &h[20..32]
    ))
}
fn random_hex() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    #[cfg(unix)]
    fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .map_err(|_| "secure OS random source unavailable".to_string())?;
    #[cfg(windows)]
    {
        #[link(name = "bcrypt")]
        extern "system" {
            fn BCryptGenRandom(
                algorithm: *mut std::ffi::c_void,
                buffer: *mut u8,
                length: u32,
                flags: u32,
            ) -> i32;
        }
        if unsafe { BCryptGenRandom(std::ptr::null_mut(), bytes.as_mut_ptr(), 32, 2) } != 0 {
            return Err("secure OS random source unavailable".into());
        }
    }
    #[cfg(not(any(unix, windows)))]
    return Err("unsupported secure random source".into());
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
pub fn initialize(
    path: &Path,
    data_dir: PathBuf,
    bind: String,
    account: String,
    device: String,
) -> Result<(), String> {
    if !identifier(&account) || !identifier(&device) {
        return Err("account/device ID must be ASCII letters, digits, - or _, max 80".into());
    }
    bind.parse::<SocketAddr>()
        .map_err(|_| "bind must be an explicit IP:port".to_string())?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let cfg = Config {
        bind,
        demo_data: false,
        data_dir,
        accounts: vec![AccountConfig {
            id: account,
            device_id: device,
            collector_token: random_hex()?,
            viewer_token: random_hex()?,
        }],
    };
    write_private(path, &serde_json::to_vec_pretty(&cfg).unwrap(), true)
}
pub fn load_config(path: &Path) -> Result<Config, String> {
    #[cfg(unix)]
    {
        let m = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
        if !m.is_file() || m.permissions().mode() & 0o077 != 0 {
            return Err("configuration must be a regular file with mode 0600".into());
        }
    }
    let bytes = fs::read(path).map_err(|e| e.to_string())?;
    if bytes.len() > 65536 {
        return Err("configuration too large".into());
    }
    serde_json::from_slice(&bytes).map_err(|_| "invalid configuration".into())
}
impl Service {
    /// Embed a viewer in a resident owner process. No second SQLite handle and no write API.
    pub fn local_view(
        engine: Arc<Mutex<Engine>>,
        viewer_token: String,
        device_id: String,
        demo_data: bool,
    ) -> Result<Self, String> {
        if viewer_token.len() < 43
            || viewer_token.len() > 256
            || !viewer_token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err("invalid local viewer credential".into());
        }
        Ok(Self {
            local: Some(LocalView {
                engine,
                token: viewer_token,
                device_id,
                text: None,
            }),
            demo_data,
            accounts: Vec::new(),
        })
    }
    pub fn with_local_text(mut self, source: Arc<Mutex<dyn LocalTextSource>>) -> Self {
        if let Some(local) = &mut self.local {
            local.text = Some(source)
        }
        self
    }
    pub fn open(config: Config) -> Result<Self, String> {
        if config.accounts.is_empty() || config.accounts.len() > 32 {
            return Err("configure 1-32 accounts".into());
        }
        private_dir(&config.data_dir)?;
        let mut accounts = Vec::new();
        let mut ids = Vec::new();
        let mut tokens = Vec::new();
        for c in config.accounts {
            if !identifier(&c.id) || !identifier(&c.device_id) || ids.contains(&c.id) {
                return Err("invalid or duplicate account/device identity".into());
            }
            ids.push(c.id.clone());
            for token in [&c.collector_token, &c.viewer_token] {
                if token.len() < 43
                    || token.len() > 256
                    || !token
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
                    || tokens.contains(token)
                {
                    return Err(
                        "credentials must be unique opaque secrets, 43-256 ASCII characters".into(),
                    );
                }
                tokens.push(token.clone());
            }
            let dir = config.data_dir.join(&c.id);
            private_dir(&dir)?;
            let database = dir.join("replica.sqlite");
            let meta_path = dir.join("metadata.json"); // New database means a new replica identity, even if old metadata remains.
            let meta = if fs::metadata(&database)
                .map(|m| m.len() > 0)
                .unwrap_or(false)
                && meta_path.exists()
            {
                serde_json::from_slice(&fs::read(&meta_path).map_err(|e| e.to_string())?)
                    .map_err(|_| "invalid replica metadata")?
            } else {
                Metadata {
                    replica_id: replica_id()?,
                    last_synced_at: None,
                    cursor: 0,
                }
            };
            let engine = Engine::open(database.to_str().ok_or("invalid database path")?)?;
            save_meta(&meta_path, &meta)?;
            let text = TextReplica::open(&dir.join("encrypted-text.sqlite"))?;
            accounts.push(Account {
                config: c,
                engine,
                meta,
                meta_path,
                text,
            });
        }
        Ok(Self {
            local: None,
            demo_data: config.demo_data,
            accounts,
        })
    }
    pub fn handle(
        &mut self,
        method: &str,
        path: &str,
        authorization: Option<&str>,
        body: &[u8],
    ) -> Response {
        if path.starts_with("/api/") {
            let token = match authorization.and_then(|s| s.strip_prefix("Bearer ")) {
                Some(t) if t.len() <= 256 => t,
                _ => return error(401, "bearer credential required"),
            };
            if let Some(local) = &self.local {
                if !equal(token, &local.token) {
                    return error(401, "invalid credential");
                }
                if method == "GET" && path == "/api/status" {
                    let version = match &local.text {
                        Some(source) => match source.lock() {
                            Ok(source) => match source.version() {
                                Ok(v) => v,
                                Err(_) => return error(500, "text source unavailable"),
                            },
                            Err(_) => return error(500, "text source unavailable"),
                        },
                        None => None,
                    };
                    return success(
                        json!({"deviceId":local.device_id,"replicaId":"local-owner","lastSyncedAt":null,"cursor":0,"readOnly":true,"demoData":self.demo_data,"localOnly":true,"textEnabled":local.text.is_some(),"textCursor":version}),
                    );
                }
                if method == "POST" && path == "/api/text-query" {
                    if body.len() > MAX_BODY {
                        return error(413, "request too large");
                    }
                    let v = match serde_json::from_slice(body) {
                        Ok(v) => v,
                        Err(_) => return error(400, "invalid JSON"),
                    };
                    return match &local.text {
                        Some(text) => match text.lock() {
                            Ok(mut source) => match source.query_encrypted(v) {
                                Ok(value) => success(value),
                                Err(_) => error(400, "invalid text query"),
                            },
                            Err(_) => error(500, "text source unavailable"),
                        },
                        None => error(404, "local text archive is disabled"),
                    };
                }
                if method != "POST" || path != "/api/query" {
                    return error(403, "local viewer is read-only");
                }
                if body.len() > MAX_BODY {
                    return error(413, "request too large");
                }
                let value: Value = match serde_json::from_slice(body) {
                    Ok(v) => v,
                    Err(_) => return error(400, "invalid JSON"),
                };
                if let Err(message) = validate_query(&value) {
                    return error(400, &message);
                }
                return match local.engine.lock() {
                    Ok(mut engine) => match engine.request(&value.to_string()) {
                        Ok(v) => success(v),
                        Err(e) if e == "export exceeds 8 MiB; choose a smaller range" => {
                            error(413, "export exceeds 8 MiB; choose a smaller range")
                        }
                        Err(_) => error(400, "invalid query"),
                    },
                    Err(_) => error(500, "local store unavailable"),
                };
            }
            let found = self.accounts.iter_mut().find_map(|a| {
                let collector = equal(token, &a.config.collector_token);
                let viewer = equal(token, &a.config.viewer_token);
                if collector || viewer {
                    Some((a, collector))
                } else {
                    None
                }
            });
            let (a, collector) = match found {
                Some(v) => v,
                None => return error(401, "invalid credential"),
            };
            if method == "GET" && path == "/api/status" {
                let text_cursor = match a.text.cursor() {
                    Ok(v) => v,
                    Err(_) => return error(500, "text replica unavailable"),
                };
                return success(
                    json!({"replicaId":a.meta.replica_id,"lastSyncedAt":a.meta.last_synced_at,"deviceId":a.config.device_id,"cursor":a.meta.cursor,"readOnly":!collector,"demoData":self.demo_data,"textCursor":text_cursor,"textReplicaId":a.text.identity(),"textEnabled":true}),
                );
            }
            if method != "POST" {
                return error(405, "method not allowed");
            };
            if body.len() > MAX_BODY {
                return error(413, "request too large");
            };
            let value: Value = match serde_json::from_slice(body) {
                Ok(v) => v,
                Err(_) => return error(400, "invalid JSON"),
            };
            if path == "/api/text-query" {
                if collector {
                    return error(403, "viewer credential required for text viewing");
                }
                return match a.text.query(value) {
                    Ok(v) => success(v),
                    Err(_) => error(400, "invalid encrypted text query"),
                };
            }
            if path == "/api/text-sync" {
                if !collector {
                    return error(403, "collector credential required");
                }
                if value.as_object().map_or(true, |o| o.len() != 2)
                    || value["deviceId"].as_str() != Some(&a.config.device_id)
                {
                    return error(403, "bound device required");
                }
                let changes = match value.get("changes") {
                    Some(v) => v.clone(),
                    None => return error(400, "encrypted changes required"),
                };
                return match a.text.apply(changes) {
                    Ok(v) => success(v),
                    Err(_) => error(400, "invalid encrypted text changes"),
                };
            }
            if path == "/api/query" {
                if let Err(message) = validate_query(&value) {
                    return error(400, &message);
                }
                return match a.engine.request(&value.to_string()) {
                    Ok(v) => success(v),
                    Err(e) if e == "export exceeds 8 MiB; choose a smaller range" => {
                        error(413, "export exceeds 8 MiB; choose a smaller range")
                    }
                    Err(_) => error(400, "invalid query"),
                };
            }
            if path == "/api/sync" {
                if !collector {
                    return error(403, "collector credential required");
                };
                let obj = match value.as_object() {
                    Some(o) => o,
                    None => return error(400, "sync object required"),
                };
                if obj.len() != 2 || value["deviceId"].as_str() != Some(&a.config.device_id) {
                    return error(403, "bound device required");
                };
                let changes = match value["changes"].as_array() {
                    Some(c) if c.len() <= 1000 => c,
                    _ => return error(400, "changes must contain at most 1000 entries"),
                };
                let mut request_cursor = 0;
                let mut cursor = a.meta.cursor;
                for c in changes {
                    let r = match c["revision"].as_u64() {
                        Some(r) if r > 0 && r <= i64::MAX as u64 => r,
                        _ => return error(400, "invalid revision"),
                    };
                    cursor = cursor.max(r);
                    request_cursor = request_cursor.max(r);
                }
                let result = match a
                    .engine
                    .request(&json!({"op":"replicaApply","changes":changes}).to_string())
                {
                    Ok(v) => v,
                    Err(_) => return error(400, "invalid aggregate changes"),
                };
                a.meta.cursor = cursor;
                a.meta.last_synced_at = Some(
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs(),
                );
                if save_meta(&a.meta_path, &a.meta).is_err() {
                    return error(500, "could not persist sync acknowledgement");
                };
                return success(
                    json!({"applied":result["applied"],"ignored":result["ignored"],"cursor":if request_cursor>0 {request_cursor} else {cursor}}),
                );
            }
            return error(404, "not found");
        }
        if method != "GET" {
            return error(405, "method not allowed");
        };
        let (content_type, data): (&str, &[u8]) = match path {
            "/" | "/index.html" => (
                "text/html; charset=utf-8",
                include_bytes!("../../../web/index.html"),
            ),
            "/metrics.js" => (
                "text/javascript; charset=utf-8",
                include_bytes!("../../../web/metrics.js"),
            ),
            "/text.js" => (
                "text/javascript; charset=utf-8",
                include_bytes!("../../../web/text.js"),
            ),
            "/csv.js" => (
                "text/javascript; charset=utf-8",
                include_bytes!("../../../web/csv.js"),
            ),
            "/app.js" => (
                "text/javascript; charset=utf-8",
                include_bytes!("../../../web/app.js"),
            ),
            "/style.css" => (
                "text/css; charset=utf-8",
                include_bytes!("../../../web/style.css"),
            ),
            "/sw.js" => (
                "text/javascript; charset=utf-8",
                include_bytes!("../../../web/sw.js"),
            ),
            "/manifest.webmanifest" => (
                "application/manifest+json",
                include_bytes!("../../../web/manifest.webmanifest"),
            ),
            _ => return error(404, "not found"),
        };
        Response {
            status: 200,
            body: data.to_vec(),
            content_type,
        }
    }
}
const MAX_SAFE_REVISION: u64 = 9_007_199_254_740_991;
fn query_shape(value: &Value, depth: usize, nodes: &mut usize) -> Result<(), String> {
    *nodes += 1;
    if depth > 4 || *nodes > 2048 {
        return Err("query JSON nesting or node budget exceeded".into());
    }
    match value {
        Value::Array(values) => {
            for value in values {
                query_shape(value, depth + 1, nodes)?;
            }
        }
        Value::Object(values) => {
            for (key, value) in values {
                if key.len() > 64 {
                    return Err("query field name too long".into());
                }
                query_shape(value, depth + 1, nodes)?;
            }
        }
        Value::String(value) if value.len() > 512 => return Err("query string too long".into()),
        _ => {}
    }
    Ok(())
}
fn exact_fields<'a>(
    value: &'a Value,
    fields: &[&str],
) -> Result<&'a serde_json::Map<String, Value>, String> {
    let object = value.as_object().ok_or("query object required")?;
    if object.len() != fields.len() || object.keys().any(|key| !fields.contains(&key.as_str())) {
        return Err("unexpected or missing cursor/snapshot fields".into());
    }
    Ok(object)
}
fn validate_snapshot(value: &Value) -> Result<(), String> {
    exact_fields(value, &["id", "revision"])?;
    let id = value["id"].as_str().ok_or("snapshot id required")?;
    if id.len() != 32
        || !id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err("snapshot id must be 32 lowercase hex characters".into());
    }
    if value["revision"]
        .as_u64()
        .filter(|v| *v <= MAX_SAFE_REVISION)
        .is_none()
    {
        return Err("snapshot revision must be a JSON-safe nonnegative integer".into());
    }
    Ok(())
}
fn export_bounds(value: &Value) -> Result<(f64, f64), String> {
    let start = value["start"].as_f64().ok_or("invalid export start")?;
    let end = value["end"].as_f64().ok_or("invalid export end")?;
    if !start.is_finite() || !end.is_finite() || start < 0.0 || end < start || end >= 1e12 {
        return Err(
            "export range must be finite, nonnegative and half-open below epoch 1e12".into(),
        );
    }
    Ok((start, end))
}
fn validate_query(v: &Value) -> Result<(), String> {
    query_shape(v, 0, &mut 0)?;
    let obj = v.as_object().ok_or("query object required")?;
    let op = v["op"].as_str().ok_or("query operation required")?;
    let fields: &[&str] = match op {
        "exportPage" => &["op", "start", "end", "cursor", "limit"],
        "exportValidate" => &["op", "snapshot"],
        "summary" | "insights" | "export" => &["op", "start", "end"],
        "buckets" => &["op", "start", "end", "stepSeconds", "includeKeyCounts"],
        "timeline" | "summaries" | "trend" => &["op", "ranges"],
        _ => return Err("read operation not allowed".into()),
    };
    if obj.keys().any(|k| !fields.contains(&k.as_str())) {
        return Err("unexpected query fields".into());
    }
    if op == "exportValidate" {
        if obj.len() != 2 {
            return Err("snapshot validation requires only op and snapshot".into());
        }
        return validate_snapshot(&v["snapshot"]);
    }
    if op == "exportPage" {
        export_bounds(v)?;
        if let Some(limit) = v.get("limit") {
            if limit
                .as_u64()
                .filter(|value| (1..=1000).contains(value))
                .is_none()
            {
                return Err("export page limit must be an integer from 1 to 1000".into());
            }
        }
        if let Some(cursor) = v.get("cursor").filter(|value| !value.is_null()) {
            exact_fields(cursor, &["snapshot", "start", "end", "afterMinute"])?;
            validate_snapshot(&cursor["snapshot"])?;
            export_bounds(cursor)?;
            let minute = cursor["afterMinute"]
                .as_u64()
                .ok_or("cursor minute must be a nonnegative integer")?;
            if minute >= 1_000_000_000_000 || minute % 60 != 0 {
                return Err("cursor minute must be a safe UTC minute start".into());
            }
        }
        return Ok(());
    }
    if op == "timeline" || op == "summaries" || op == "trend" {
        let limit = if op == "trend" { 400 } else { 200 };
        if v["ranges"].as_array().map_or(true, |a| a.len() > limit) {
            return Err("bounded ranges required".into());
        }
        if op == "trend" {
            // The core enforces ordering, duration/span and minute alignment.
            // The public route additionally rejects unknown nested fields.
            for range in v["ranges"].as_array().unwrap() {
                exact_fields(range, &["start", "end"])?;
            }
        }
    } else {
        let start = v["start"].as_f64().ok_or("invalid start")?;
        let end = v["end"].as_f64().ok_or("invalid end")?;
        if !start.is_finite()
            || !end.is_finite()
            || start < 0.0
            || end <= start
            || end >= 1e12
            || (op != "buckets" && end - start > 100.0 * 366.0 * 86400.0)
            || start % 60.0 != 0.0
        {
            return Err("range must be minute-aligned, positive, half-open, below epoch 1e12; scalar queries allow up to 100 elapsed years".into());
        }
        if op == "buckets" {
            let step = match v.get("stepSeconds") {
                Some(value) => value.as_u64().ok_or("invalid bucket step")?,
                None => 60,
            };
            if step < 60
                || step > i64::MAX as u64
                || step % 60 != 0
                || ((end - start) / step as f64).ceil() > 10000.0
            {
                return Err("too many buckets or invalid step".into());
            }
        }
    }
    Ok(())
}
pub fn serve(listener: TcpListener, service: Service) -> Result<(), String> {
    serve_until(listener, service, Arc::new(AtomicBool::new(false)))
}
/// Nonblocking accept lets the resident owner stop every owned server thread on quit.
pub fn serve_until(
    listener: TcpListener,
    mut service: Service,
    stop: Arc<AtomicBool>,
) -> Result<(), String> {
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((mut stream, _)) => {
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
                let reply = match read_request(&mut stream) {
                    Ok((method, path, headers, body)) => service.handle(
                        &method,
                        &path,
                        headers.get("authorization").map(String::as_str),
                        &body,
                    ),
                    Err(status) => error(status, "invalid or oversized HTTP request"),
                };
                let _ = send_response(&mut stream, reply);
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(40))
            }
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}
type RequestParts = (String, String, BTreeMap<String, String>, Vec<u8>);
fn read_request(stream: &mut TcpStream) -> Result<RequestParts, u16> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut raw = Vec::new();
    let end;
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(408u16)?;
        stream
            .set_read_timeout(Some(remaining))
            .map_err(|_| 408u16)?;
        let mut b = [0; 1];
        if stream.read(&mut b).map_err(|_| 408u16)? == 0 {
            return Err(400);
        }
        raw.push(b[0]);
        if raw.ends_with(b"\r\n\r\n") {
            end = raw.len();
            break;
        }
        if raw.len() > MAX_HEADER {
            return Err(431);
        }
    }
    let text = std::str::from_utf8(&raw).map_err(|_| 400u16)?;
    let mut lines = text.split("\r\n");
    let parts: Vec<_> = lines.next().unwrap_or("").split(' ').collect();
    if parts.len() != 3
        || parts[2] != "HTTP/1.1"
        || parts[1].contains('?')
        || parts[1].contains('#')
    {
        return Err(400);
    }
    let method = parts[0].to_string();
    let path = parts[1].to_string();
    let mut headers = BTreeMap::new();
    for line in lines.filter(|s| !s.is_empty()) {
        let (k, v) = line.split_once(':').ok_or(400u16)?;
        if k.is_empty() || !k.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            return Err(400);
        }
        let k = k.to_ascii_lowercase();
        if headers.insert(k, v.trim().to_string()).is_some() {
            return Err(400);
        }
    }
    if headers.contains_key("transfer-encoding") {
        return Err(400);
    }
    if method == "POST"
        && path.starts_with("/api/")
        && headers.get("content-type").map(|s| {
            s.split(';')
                .next()
                .unwrap_or("")
                .trim()
                .eq_ignore_ascii_case("application/json")
        }) != Some(true)
    {
        return Err(415);
    }
    let length = headers
        .get("content-length")
        .map(|s| s.parse::<usize>())
        .transpose()
        .map_err(|_| 400u16)?
        .unwrap_or(0);
    if length > MAX_BODY {
        return Err(413);
    }
    raw.resize(end + length, 0);
    let mut offset = end;
    while offset < raw.len() {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(408u16)?;
        stream
            .set_read_timeout(Some(remaining))
            .map_err(|_| 408u16)?;
        let n = stream.read(&mut raw[offset..]).map_err(|_| 408u16)?;
        if n == 0 {
            return Err(400);
        }
        offset += n;
    }
    Ok((method, path, headers, raw[end..].to_vec()))
}
fn send_response(stream: &mut TcpStream, response: Response) -> std::io::Result<()> {
    let reason = match response.status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        431 => "Request Header Fields Too Large",
        _ => "Internal Server Error",
    };
    write!(stream,"HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n",response.status,reason,response.content_type,response.body.len())?;
    stream.write_all(&response.body)
}
#[cfg(test)]
mod tests;
