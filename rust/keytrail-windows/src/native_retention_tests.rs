//! Runs the real resident cleanup method in a Windows PE test, using temporary
//! stores and no window, input registration, user database, DPAPI or network.
use super::*;

struct Fixture {
    app: Option<App>,
    root: PathBuf,
    stamp: f64,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "keytrail-native-retention-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let stats_path = root.join("stats.sqlite");
        let engine = Arc::new(Mutex::new(
            Engine::open(stats_path.to_str().unwrap()).unwrap(),
        ));
        let text_archive = Arc::new(Mutex::new(
            TextArchive::open(&root.join("text.sqlite"), [9; 32]).unwrap(),
        ));
        let stamp = time().floor() - 1.0;
        let mut input = InputState::default();
        assert_eq!(input.key(30, false, false), Some("A"));
        input.movement(10, 0, 96);
        let app = App {
            engine,
            text_archive,
            text_status: Arc::new(Mutex::new(String::new())),
            capture_active: Arc::new(AtomicBool::new(true)),
            text_intent: Arc::new(AtomicU64::new(77)),
            text_reset: Arc::new(AtomicU64::new(7)),
            settings: Arc::new(Mutex::new(Settings::default())),
            config_path: root.join("settings.json"),
            stats_path,
            input,
            pending: vec![json!({"timestamp":stamp,"kind":"keyPress","keyLabel":"A"})],
            enabled: true,
            recovery: RecoveryCutoff::default(),
            capture_ready: true,
            tray_available: false,
            locked: false,
            suspended: false,
            demo: false,
            viewer_token: String::new(),
            url: String::new(),
            float: null_mut(),
            manager: null_mut(),
            data_job: None,
            data_status: String::new(),
            displayed_status: String::new(),
            status: Arc::new(Mutex::new(String::new())),
            sync_status: Arc::new(Mutex::new(String::new())),
            stop: Arc::new(AtomicBool::new(false)),
            sync_now: Arc::new(AtomicBool::new(false)),
            instance: null_mut(),
            ticks: 0,
        };
        Self {
            app: Some(app),
            root,
            stamp,
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.app.take();
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn assert_uninterrupted(app: &mut App, stamp: f64) {
    assert!(app.capture_active.load(Ordering::Relaxed));
    assert_eq!(app.text_intent.load(Ordering::Relaxed), 77);
    assert_eq!(app.text_reset.load(Ordering::Relaxed), 7);
    assert_eq!(app.input.key(30, false, false), None);
    assert_eq!(app.input.movement(20, 0, 96), Some(10.0));
    request(&app.engine, json!({"op":"advance","time":stamp+30.0})).unwrap();
    let summary = request(
        &app.engine,
        json!({"op":"summary","start":stamp-1.0,"end":stamp+60.0}),
    )
    .unwrap();
    assert_eq!(summary["totalActiveSeconds"], 30);
    assert_eq!(summary["keyPresses"], 1);
}
#[test]
fn real_cleanup_under_cap_preserves_capture_text_and_activity_tail() {
    let mut f = Fixture::new();
    let app = f.app.as_mut().unwrap();
    let result = app.cleanup(1024 * 1024).unwrap();
    assert_eq!(result["limitMet"], true);
    assert_eq!(result["deletedStatisticsMinutes"], 0);
    assert_eq!(result["deletedTextRecords"], 0);
    assert_uninterrupted(app, f.stamp);
}
#[test]
fn real_cleanup_compaction_only_preserves_capture_text_and_activity_tail() {
    let mut f = Fixture::new();
    let db = rusqlite::Connection::open(f.root.join("text.sqlite")).unwrap();
    db.execute_batch("CREATE TABLE discarded(payload BLOB); INSERT INTO discarded VALUES(zeroblob(2097152)); DROP TABLE discarded;").unwrap();
    drop(db);
    let app = f.app.as_mut().unwrap();
    let result = app.cleanup(1024 * 1024).unwrap();
    assert_eq!(result["limitMet"], true);
    assert_eq!(result["deletedStatisticsMinutes"], 0);
    assert_eq!(result["deletedTextRecords"], 0);
    assert_uninterrupted(app, f.stamp);
}
#[test]
fn real_cleanup_deletion_resets_once_preserves_held_keys_and_ends_tail() {
    let mut f = Fixture::new();
    let app = f.app.as_mut().unwrap();
    for i in 0..100 {
        app.text_archive
            .lock()
            .unwrap()
            .append(
                &"x".repeat(16384),
                600.0 + i as f64 * 60.0,
                "fixture.editor",
            )
            .unwrap();
    }
    let stamp = time().floor() - 1.0;
    app.pending[0]["timestamp"] = json!(stamp);
    let result = app.cleanup(1024 * 1024).unwrap();
    assert!(result["deletedTextRecords"].as_u64().unwrap() > 0);
    assert!(!app.capture_active.load(Ordering::Relaxed));
    assert_eq!(app.text_intent.load(Ordering::Relaxed), 0);
    assert_eq!(app.text_reset.load(Ordering::Relaxed), 8);
    assert_eq!(app.input.key(30, false, false), None);
    assert_eq!(app.input.movement(20, 0, 96), None);
    request(&app.engine, json!({"op":"advance","time":stamp+30.0})).unwrap();
    let summary = request(
        &app.engine,
        json!({"op":"summary","start":stamp-1.0,"end":stamp+60.0}),
    )
    .unwrap();
    assert!(summary["totalActiveSeconds"].as_u64().unwrap() < 30);
}
