use super::*;
use keytrail_core::Engine;
use rusqlite::Connection;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "keytrail-quit-fault-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn database(&self) -> PathBuf {
        self.0.join("activity.sqlite")
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn flush(
    engine: &mut Engine,
    pending: &mut Vec<Value>,
    recovery: &mut RecoveryCutoff,
    now: f64,
) -> Result<(), String> {
    // Exactly the shared path used by pause_checked/QUIT, with a real database.
    flush_activity(pending, recovery, now, true, false, |v| {
        engine.request(&v.to_string())
    })
}
fn assert_durable_once_and_no_paused_activity(mut engine: Engine, database: &std::path::Path) {
    engine.request(r#"{"op":"advance","time":200}"#).unwrap();
    let live = engine
        .request(r#"{"op":"summary","start":0,"end":240}"#)
        .unwrap();
    assert_eq!(live["keyPresses"], 1);
    assert_eq!(live["totalActiveSeconds"], 10);
    drop(engine);
    let mut reopened = Engine::open(database.to_str().unwrap()).unwrap();
    let persisted = reopened
        .request(r#"{"op":"summary","start":0,"end":240}"#)
        .unwrap();
    assert_eq!(persisted["keyPresses"], 1);
    assert_eq!(persisted["totalActiveSeconds"], 10);
}
#[test]
fn quit_flush_ingest_failure_retains_pending_and_original_cutoff_until_durable_retry() {
    let f = Fixture::new();
    let path = f.database();
    let mut engine = Engine::open(path.to_str().unwrap()).unwrap();
    let db = Connection::open(&path).unwrap();
    db.execute_batch("CREATE TRIGGER fail_write BEFORE INSERT ON minutes BEGIN SELECT RAISE(ABORT,'fixture full disk');END;").unwrap();
    let mut pending = vec![json!({"timestamp":10,"kind":"keyPress","keyLabel":"A"})];
    let original = pending.clone();
    let mut recovery = RecoveryCutoff::default();
    assert!(flush(&mut engine, &mut pending, &mut recovery, 20.0).is_err());
    assert_eq!(pending, original);
    assert_eq!(recovery.pending(), Some(20.0));
    assert_eq!(
        engine
            .request(r#"{"op":"summary","start":0,"end":240}"#)
            .unwrap()["keyPresses"],
        0
    );
    // A second failed exit cannot move the first stopped boundary forward.
    assert!(flush(&mut engine, &mut pending, &mut recovery, 80.0).is_err());
    assert_eq!(pending, original);
    assert_eq!(recovery.pending(), Some(20.0));
    db.execute_batch("DROP TRIGGER fail_write").unwrap();
    drop(db);
    flush(&mut engine, &mut pending, &mut recovery, 100.0).unwrap();
    assert!(pending.is_empty());
    assert!(recovery.pending().is_none());
    assert_durable_once_and_no_paused_activity(engine, &path);
}
#[test]
fn quit_flush_end_failure_retains_cutoff_and_does_not_duplicate_already_committed_input() {
    let f = Fixture::new();
    let path = f.database();
    let mut engine = Engine::open(path.to_str().unwrap()).unwrap();
    engine.request(r#"{"op":"ingest","samples":[{"timestamp":10,"kind":"keyPress","keyLabel":"A"}],"observedThrough":10}"#).unwrap();
    let db = Connection::open(&path).unwrap();
    db.execute_batch("CREATE TRIGGER fail_end BEFORE INSERT ON minutes BEGIN SELECT RAISE(ABORT,'fixture end I/O failure');END;").unwrap();
    let mut pending = vec![];
    let mut recovery = RecoveryCutoff::default();
    assert!(flush(&mut engine, &mut pending, &mut recovery, 20.0).is_err());
    assert!(pending.is_empty());
    assert_eq!(recovery.pending(), Some(20.0));
    let before = engine
        .request(r#"{"op":"summary","start":0,"end":240}"#)
        .unwrap();
    assert_eq!(before["keyPresses"], 1);
    assert_eq!(before["totalActiveSeconds"], 0);
    db.execute_batch("DROP TRIGGER fail_end").unwrap();
    drop(db);
    flush(&mut engine, &mut pending, &mut recovery, 100.0).unwrap();
    assert!(pending.is_empty());
    assert!(recovery.pending().is_none());
    assert_durable_once_and_no_paused_activity(engine, &path);
}
