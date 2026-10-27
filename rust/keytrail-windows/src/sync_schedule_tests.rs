use super::*;
use keytrail_server::{AccountConfig, Config, Service};
use serde_json::Value;
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
};
static FIXTURE_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
fn source() -> SyncIdentity {
    SyncIdentity {
        endpoint: "http://127.0.0.1:8787".into(),
        device: "fixture-win".into(),
        protected_credential: vec![1],
        aggregate: true,
        text: false,
    }
}
fn at(ms: u64) -> Duration {
    Duration::from_millis(ms)
}
struct Fixture {
    root: PathBuf,
    engine: Arc<Mutex<Engine>>,
    archive: Arc<Mutex<TextArchive>>,
    service: RefCell<Service>,
    cursor: Cell<u64>,
    text_cursor: Cell<u64>,
    replica: RefCell<String>,
    uploads: Cell<usize>,
    probes: Cell<usize>,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "keytrail-sync-schedule-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            FIXTURE_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&root).unwrap();
        let engine = Arc::new(Mutex::new(
            Engine::open(root.join("local.sqlite").to_str().unwrap()).unwrap(),
        ));
        let archive = Arc::new(Mutex::new(
            TextArchive::open(&root.join("text.sqlite"), [7; 32]).unwrap(),
        ));
        let service = RefCell::new(Self::server(&root.join("remote")));
        Self {
            root,
            engine,
            archive,
            service,
            cursor: Cell::new(0),
            text_cursor: Cell::new(0),
            replica: RefCell::new(String::new()),
            uploads: Cell::new(0),
            probes: Cell::new(0),
        }
    }
    fn server(path: &std::path::Path) -> Service {
        Service::open(Config {
            bind: "127.0.0.1:0".into(),
            data_dir: path.to_owned(),
            demo_data: true,
            accounts: vec![AccountConfig {
                id: "fixture".into(),
                device_id: "fixture-win".into(),
                collector_token: "c".repeat(64),
                viewer_token: "v".repeat(64),
            }],
        })
        .unwrap()
    }
    fn call(&self, path: &str, body: Option<Value>) -> Result<Value, String> {
        let method = if body.is_some() { "POST" } else { "GET" };
        let response = self.service.borrow_mut().handle(
            method,
            path,
            Some(&format!("Bearer {}", "c".repeat(64))),
            &body
                .map(|v| serde_json::to_vec(&v).unwrap())
                .unwrap_or_default(),
        );
        let envelope: Value = serde_json::from_slice(&response.body).unwrap();
        if response.status != 200 {
            return Err(format!("fixture HTTP {}", response.status));
        }
        Ok(envelope["result"].clone())
    }
    fn pending(&self, aggregate: bool, text: bool) -> Result<bool, String> {
        local_pending(
            &self.engine,
            &self.archive,
            aggregate,
            self.cursor.get(),
            text,
            self.text_cursor.get(),
        )
    }
    fn sync(&self) -> Result<(), String> {
        self.probes.set(self.probes.get() + 1);
        let remote = self.call("/api/status", None)?;
        let identity = remote["replicaId"].as_str().unwrap();
        if self.replica.borrow().as_str() != identity {
            self.cursor.set(0);
            *self.replica.borrow_mut() = identity.into()
        }
        let page = self.engine.lock().unwrap().request(
            &json!({"op":"syncChanges","after":self.cursor.get(),"limit":128}).to_string(),
        )?;
        if !page["changes"].as_array().unwrap().is_empty() {
            let result = self.call(
                "/api/sync",
                Some(json!({"deviceId":"fixture-win","changes":page["changes"]})),
            )?;
            let sent = page["cursor"].as_u64().unwrap();
            if result["cursor"].as_u64().unwrap() < sent {
                return Err("short ack".into());
            }
            self.cursor.set(sent);
            self.uploads.set(self.uploads.get() + 1);
        }
        Ok(())
    }
    fn ingest(&self, time: f64) {
        self.engine.lock().unwrap().request(&json!({"op":"ingest","samples":[{"timestamp":time,"kind":"keyPress","keyLabel":"A"}],"observedThrough":time}).to_string()).unwrap();
    }
    fn tick(&self, s: &mut SyncSchedule, ms: u64) -> Tick {
        s.tick(
            || at(ms),
            source(),
            false,
            || self.pending(true, false),
            || self.sync(),
        )
        .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn real_journal_driver_uploads_within_flush_plus_one_second_and_idle_has_no_network_poll() {
    let f = Fixture::new();
    let mut s = SyncSchedule::default();
    assert_eq!(f.tick(&mut s, 0), Tick::Synchronized);
    assert_eq!(f.tick(&mut s, 1000), Tick::Idle);
    // Worst phase: timer preflight just ran, then the one-second resident flush commits input.
    f.ingest(1.001);
    for ms in [1250, 1500, 1750] {
        assert_eq!(f.tick(&mut s, ms), Tick::Deferred)
    }
    assert_eq!(f.tick(&mut s, 2000), Tick::Synchronized);
    assert_eq!(f.uploads.get(), 1);
    assert!(f.cursor.get() > 0);
    assert!(!f.pending(true, false).unwrap());
    let summary = f
        .call(
            "/api/query",
            Some(json!({"op":"summary","start":0,"end":60})),
        )
        .unwrap();
    assert_eq!(summary["keyPresses"], 1);
    for ms in (2250..30000).step_by(250) {
        f.tick(&mut s, ms);
    }
    assert_eq!(f.probes.get(), 2); // initial probe and actual upload, no idle HTTP loop
}

#[test]
fn idle_identity_heartbeat_replays_recreated_server_with_no_new_local_input() {
    let f = Fixture::new();
    let mut s = SyncSchedule::default();
    f.ingest(1.0);
    assert_eq!(f.tick(&mut s, 0), Tick::Synchronized);
    assert!(!f.pending(true, false).unwrap());
    *f.service.borrow_mut() = Fixture::server(&f.root.join("replacement"));
    assert_eq!(f.tick(&mut s, 29000), Tick::Idle);
    assert_eq!(f.uploads.get(), 1);
    assert_eq!(f.tick(&mut s, 30000), Tick::Synchronized);
    assert_eq!(f.uploads.get(), 2);
    assert_eq!(
        f.call(
            "/api/query",
            Some(json!({"op":"summary","start":0,"end":60}))
        )
        .unwrap()["keyPresses"],
        1
    );
}

#[test]
fn disabled_scopes_skip_io_and_stream_cursors_include_deletions() {
    let f = Fixture::new();
    f.ingest(1.0);
    f.archive
        .lock()
        .unwrap()
        .append("fixture text", 1.0, "fixture.editor")
        .unwrap();
    assert!(f.pending(true, false).unwrap());
    assert!(f.pending(false, true).unwrap());
    assert!(!f.pending(false, false).unwrap());
    let mut s = SyncSchedule::default();
    let mut off = source();
    off.aggregate = false;
    assert_eq!(
        s.tick(
            || at(0),
            off,
            false,
            || panic!("disabled journal read"),
            || panic!("disabled HTTP")
        ),
        Ok(Tick::Disabled)
    );
    f.sync().unwrap();
    assert!(!f.pending(true, false).unwrap());
    f.engine
        .lock()
        .unwrap()
        .request(r#"{"op":"delete","start":0,"end":60}"#)
        .unwrap();
    assert!(f.pending(true, false).unwrap());
    let page = f.archive.lock().unwrap().changes(0, 1).unwrap();
    f.text_cursor.set(page["cursor"].as_u64().unwrap());
    assert!(!f.pending(false, true).unwrap()); // independent ack, disabled stats never substitutes
    let id = page["changes"][0]["id"].as_str().unwrap();
    assert!(f.archive.lock().unwrap().delete_id(id).unwrap());
    assert!(f.pending(false, true).unwrap());
}

#[test]
fn backoff_uses_completion_clock_and_pending_changes_do_not_bypass_it() {
    let mut s = SyncSchedule::default();
    let clock = Cell::new(at(0));
    assert!(s
        .tick(
            || clock.get(),
            source(),
            false,
            || Ok(true),
            || {
                clock.set(at(20000));
                Err("offline".into())
            }
        )
        .is_err());
    assert_eq!(s.retry_after(at(20000)), Duration::from_secs(60));
    for ms in [20250, 30000, 79999] {
        assert_eq!(
            s.tick(
                || at(ms),
                source(),
                false,
                || panic!("backoff reads"),
                || panic!("backoff HTTP")
            ),
            Ok(Tick::Deferred)
        );
    }
    assert!(s
        .tick(
            || at(80000),
            source(),
            false,
            || Ok(true),
            || Err("still offline".into())
        )
        .is_err());
    assert_eq!(s.retry_after(at(80000)), Duration::from_secs(120));
    assert_eq!(
        s.tick(|| at(80250), source(), true, || Ok(true), || Ok(())),
        Ok(Tick::Synchronized)
    );
    assert_eq!(s.retry_after(at(80250)), Duration::ZERO);
}

#[test]
fn configuration_change_retries_promptly_without_idle_network_loop() {
    let f = Fixture::new();
    let mut s = SyncSchedule::default();
    assert!(s
        .tick(
            || at(0),
            source(),
            false,
            || Ok(true),
            || Err("authorization".into())
        )
        .is_err());
    let mut changed = source();
    changed.protected_credential = vec![2];
    assert_eq!(
        s.tick(|| at(250), changed.clone(), false, || Ok(false), || Ok(())),
        Ok(Tick::Synchronized)
    );
    assert_eq!(
        s.tick(
            || at(1250),
            changed,
            false,
            || f.pending(true, false),
            || panic!("unchanged identity must stay idle")
        ),
        Ok(Tick::Idle)
    );
}
