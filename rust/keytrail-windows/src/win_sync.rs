use super::*;
use keytrail_windows::sync_schedule::{
    local_pending, SyncIdentity, SyncSchedule, Tick, WORKER_POLL,
};
use windows_sys::Win32::Networking::WinHttp::*;
fn identity(cfg: &Settings) -> SyncIdentity {
    SyncIdentity {
        endpoint: cfg.endpoint.clone(),
        device: cfg.device_id.clone(),
        protected_credential: cfg.protected_token.clone(),
        aggregate: cfg.sync_enabled,
        text: cfg.text_sync_enabled,
    }
}
struct Handle(*mut c_void);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            if !self.0.is_null() {
                WinHttpCloseHandle(self.0);
            }
        }
    }
}
fn http(cfg: &Settings, path: &str, body: Option<&Value>) -> Result<Value, String> {
    let ep = endpoint(&cfg.endpoint)?;
    let protected = protect(&cfg.protected_token, true)?;
    let token = String::from_utf8(protected).map_err(|_| "Invalid saved credential")?;
    unsafe {
        let session = Handle(WinHttpOpen(
            wide("KeyTrail/1.2").as_ptr(),
            WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            null(),
            null(),
            0,
        ));
        if session.0.is_null() {
            return Err("Could not initialize Windows HTTPS".into());
        }
        WinHttpSetTimeouts(session.0, 5000, 5000, 10000, 10000);
        let connection = Handle(WinHttpConnect(
            session.0,
            wide(&ep.host).as_ptr(),
            ep.port,
            0,
        ));
        if connection.0.is_null() {
            return Err("Could not connect private endpoint".into());
        }
        let method = if body.is_some() { "POST" } else { "GET" };
        let request = Handle(WinHttpOpenRequest(
            connection.0,
            wide(method).as_ptr(),
            wide(path).as_ptr(),
            null(),
            null(),
            null(),
            if ep.secure { WINHTTP_FLAG_SECURE } else { 0 },
        ));
        if request.0.is_null() {
            return Err("Could not create private request".into());
        }
        let redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        if WinHttpSetOption(
            request.0,
            WINHTTP_OPTION_REDIRECT_POLICY,
            &redirect as *const _ as *mut c_void,
            size_of::<u32>() as u32,
        ) == 0
        {
            return Err("Could not disable redirects; private request refused.".into());
        }
        let headers = wide(&format!(
            "Authorization: Bearer {token}\r\nContent-Type: application/json\r\n"
        ));
        let payload = body.map(Value::to_string).unwrap_or_default().into_bytes();
        if payload.len() > 2 * 1024 * 1024 {
            return Err("Sync page exceeds request limit".into());
        }
        if WinHttpSendRequest(
            request.0,
            headers.as_ptr(),
            u32::MAX,
            if payload.is_empty() {
                null()
            } else {
                payload.as_ptr() as *const c_void
            },
            payload.len() as u32,
            payload.len() as u32,
            0,
        ) == 0
            || WinHttpReceiveResponse(request.0, null_mut()) == 0
        {
            return Err("Private HTTPS request failed (network, certificate, or timeout). Retained changes will retry.".into());
        }
        let mut status = 0u32;
        let mut length = size_of::<u32>() as u32;
        if WinHttpQueryHeaders(
            request.0,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            null(),
            &mut status as *mut _ as *mut c_void,
            &mut length,
            null_mut(),
        ) == 0
        {
            return Err("Could not read private response status".into());
        }
        if status == 401 || status == 403 {
            return Err("Authorization rejected (401/403). Check collector credential and bound device; retry backed off.".into());
        }
        if status != 200 {
            return Err(format!(
                "Private server returned HTTP {status}; cursor retained."
            ));
        }
        let mut bytes = Vec::new();
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        loop {
            if std::time::Instant::now() > deadline {
                return Err("Private response exceeded total read deadline.".into());
            }
            let mut block = [0u8; 8192];
            let mut read = 0;
            if WinHttpReadData(
                request.0,
                block.as_mut_ptr() as *mut c_void,
                block.len() as u32,
                &mut read,
            ) == 0
            {
                return Err("Private response was interrupted; cursor retained.".into());
            }
            if read == 0 {
                break;
            }
            if bytes.len() + read as usize > 2 * 1024 * 1024 {
                return Err("Private response too large".into());
            }
            bytes.extend_from_slice(&block[..read as usize]);
        }
        let value: Value =
            serde_json::from_slice(&bytes).map_err(|_| "Invalid private JSON response")?;
        if value["ok"] != true {
            return Err("Private server rejected request; cursor retained.".into());
        }
        Ok(value["result"].clone())
    }
}
fn round(
    engine: &Arc<Mutex<Engine>>,
    archive: &Arc<Mutex<TextArchive>>,
    settings: &Arc<Mutex<Settings>>,
    config_path: &Path,
    status: &Arc<Mutex<String>>,
    stop: &AtomicBool,
) -> Result<(), String> {
    let mut cfg = settings.lock().map_err(|_| "Settings unavailable")?.clone();
    if stop.load(Ordering::Relaxed) || (!cfg.sync_enabled && !cfg.text_sync_enabled) {
        return Ok(());
    }
    *status.lock().map_err(|_| "Status unavailable")? =
        "Checking private connection and pending changes...".into();
    let remote = http(&cfg, "/api/status", None)?;
    if remote["deviceId"].as_str() != Some(&cfg.device_id) {
        return Err("Private server is bound to a different device.".into());
    }
    let replica = remote["replicaId"]
        .as_str()
        .ok_or("Private server has no replica identity")?;
    if replica != cfg.replica_id {
        cfg.cursor = 0;
        cfg.replica_id = replica.into();
    }
    if cfg.sync_enabled {
        for _ in 0..8 {
            let page = request(
                engine,
                json!({"op":"syncChanges","after":cfg.cursor,"limit":128}),
            )?;
            let changes = page["changes"].as_array().ok_or("Invalid local changes")?;
            if changes.is_empty() {
                break;
            }
            let sent = page["cursor"].as_u64().ok_or("Invalid local cursor")?;
            {
                let latest = settings.lock().map_err(|_| "Settings unavailable")?;
                if stop.load(Ordering::Relaxed) || identity(&latest) != identity(&cfg) {
                    return Ok(());
                }
            }
            let result = http(
                &cfg,
                "/api/sync",
                Some(&json!({"deviceId":cfg.device_id,"changes":changes})),
            )?;
            if result["cursor"].as_u64().unwrap_or(0) < sent {
                return Err("Private acknowledgement is behind sent page; cursor retained.".into());
            }
            cfg.cursor = sent;
            {
                let mut latest = settings.lock().map_err(|_| "Settings unavailable")?; // Do not overwrite a concurrent endpoint/credential/enable change.
                if stop.load(Ordering::Relaxed) || identity(&latest) != identity(&cfg) {
                    return Ok(());
                }
                let mut saved = latest.clone();
                saved.cursor = cfg.cursor;
                saved.replica_id = cfg.replica_id.clone();
                save(config_path, &saved)?;
                *latest = saved;
            }
            if page["hasMore"] != true {
                break;
            }
        }
    }
    if cfg.text_sync_enabled {
        let text_replica = remote["textReplicaId"]
            .as_str()
            .ok_or("Private server has no text replica identity")?;
        if text_replica != cfg.text_replica_id {
            cfg.text_replica_id = text_replica.into();
            cfg.text_cursor = 0;
        }
        for _ in 0..8 {
            let page = archive
                .lock()
                .map_err(|_| "Text store unavailable")?
                .changes(cfg.text_cursor, 1)?;
            let changes = page["changes"]
                .as_array()
                .ok_or("Invalid local text changes")?;
            if changes.is_empty() {
                break;
            }
            let sent = page["cursor"].as_u64().ok_or("Invalid text cursor")?;
            {
                let latest = settings.lock().map_err(|_| "Settings unavailable")?;
                if stop.load(Ordering::Relaxed) || identity(&latest) != identity(&cfg) {
                    return Ok(());
                }
            }
            let result = http(
                &cfg,
                "/api/text-sync",
                Some(&json!({"deviceId":cfg.device_id,"changes":changes})),
            )?;
            if result["cursor"].as_u64().unwrap_or(0) < sent {
                return Err("Private text acknowledgement is behind sent page".into());
            }
            cfg.text_cursor = sent;
            {
                let mut latest = settings.lock().map_err(|_| "Settings unavailable")?;
                if stop.load(Ordering::Relaxed) || identity(&latest) != identity(&cfg) {
                    return Ok(());
                }
                let mut saved = latest.clone();
                saved.text_cursor = sent;
                saved.text_replica_id = cfg.text_replica_id.clone();
                save(config_path, &saved)?;
                *latest = saved;
            }
            if page["hasMore"] != true {
                break;
            }
        }
    }
    let latest = settings.lock().map_err(|_| "Settings unavailable")?;
    if !stop.load(Ordering::Relaxed) && identity(&latest) == identity(&cfg) {
        *status.lock().map_err(|_| "Status unavailable")? = format!(
            "Private sync checked at Unix second {} (aggregate {}, encrypted text {}).",
            time().floor() as u64,
            cfg.sync_enabled,
            cfg.text_sync_enabled
        );
    }
    Ok(())
}
pub(super) fn spawn(
    engine: Arc<Mutex<Engine>>,
    archive: Arc<Mutex<TextArchive>>,
    settings: Arc<Mutex<Settings>>,
    config_path: PathBuf,
    status: Arc<Mutex<String>>,
    stop: Arc<AtomicBool>,
    now: Arc<AtomicBool>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let start = std::time::Instant::now();
        let mut schedule = SyncSchedule::default();
        while !stop.load(Ordering::Relaxed) {
            thread::sleep(WORKER_POLL);
            if stop.load(Ordering::Relaxed) {
                break;
            }
            let cfg = match settings.lock() {
                Ok(cfg) => cfg.clone(),
                Err(_) => break,
            };
            let source = identity(&cfg);
            let result = schedule.tick(
                || start.elapsed(),
                source.clone(),
                now.swap(false, Ordering::Relaxed),
                || {
                    local_pending(
                        &engine,
                        &archive,
                        cfg.sync_enabled,
                        cfg.cursor,
                        cfg.text_sync_enabled,
                        cfg.text_cursor,
                    )
                },
                || round(&engine, &archive, &settings, &config_path, &status, &stop),
            );
            // A response from a superseded configuration must not overwrite its new status.
            if stop.load(Ordering::Relaxed)
                || settings
                    .lock()
                    .map(|s| identity(&s) != source)
                    .unwrap_or(true)
            {
                continue;
            }
            match result {
                Ok(Tick::Disabled) => {
                    *status.lock().unwrap() =
                        "Private aggregate/text sync disabled; no network requests.".into()
                }
                Ok(_) => {}
                Err(e) => {
                    *status.lock().unwrap() = format!("{e} Automatic retry in {} seconds; retained changes stay local. Sync now can retry explicitly.", schedule.retry_after(start.elapsed()).as_secs()+1);
                }
            }
        }
    })
}
