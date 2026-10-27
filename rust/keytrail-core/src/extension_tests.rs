use super::*;
use std::sync::atomic::{AtomicU64, Ordering};
fn store() -> Store {
    Store::open(":memory:").unwrap()
}
fn key(time: f64) -> Sample {
    Sample {
        timestamp: time,
        kind: Kind::KeyPress,
        key_label: Some("A".into()),
        distance_points: 0.0,
        scroll_delta: 0.0,
    }
}
fn call(s: &mut Store, value: Value) -> Value {
    s.request(&value.to_string()).unwrap()
}
fn changes(s: &mut Store, after: i64) -> Value {
    call(s, json!({"op":"syncChanges","after":after,"limit":1000}))
}
fn insight(s: &mut Store, start: f64, end: f64) -> Value {
    call(s, json!({"op":"insights","start":start,"end":end}))
}
struct File(String);
impl File {
    fn new() -> Self {
        static N: AtomicU64 = AtomicU64::new(0);
        Self(
            std::env::temp_dir()
                .join(format!(
                    "keytrail-extensions-{}-{}.sqlite",
                    std::process::id(),
                    N.fetch_add(1, Ordering::Relaxed)
                ))
                .to_string_lossy()
                .into_owned(),
        )
    }
}
impl Drop for File {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
fn record(keys: i64) -> Value {
    json!({"keys":keys,"leftClicks":0,"rightClicks":0,"middleClicks":0,"distance":0.0,"scroll":0.0,"keyboardMask":"0","mouseMask":"0","keyCounts":{"A":keys}})
}
fn change(revision: i64, minute: i64) -> Value {
    json!({"revision":revision,"minute":minute,"deleted":false,"record":record(1)})
}
fn deletion(revision: i64, minute: i64) -> Value {
    json!({"revision":revision,"minute":minute,"deleted":true,"record":null})
}
#[test]
fn rhythm_thresholds_bpm_and_burst_use_distinct_gap_rules() {
    let mut s = store();
    s.ingest(
        [0.0, 0.03, 0.78, 1.531, 3.531, 5.532]
            .into_iter()
            .map(key)
            .collect(),
        6.0,
    )
    .unwrap();
    let r = insight(&mut s, 0.0, 60.0);
    assert_eq!(r["intervalCount"], 4);
    assert!((r["intervalSumMs"].as_f64().unwrap() - 3531.0).abs() < 0.001);
    assert!((r["bpm"].as_f64().unwrap() - 240000.0 / 3531.0).abs() < 0.001);
    assert_eq!(r["burstPeak"], 3);
    assert_eq!(r["burstPeakAt"], 0);
    assert_eq!(r["measuredMinutes"], 1);
    let before = r;
    s.advance(1000.0, false).unwrap();
    assert_eq!(insight(&mut s, 0.0, 60.0), before);
}
#[test]
fn rhythm_nonincreasing_samples_break_continuity_and_pause_clears_it() {
    let mut s = store();
    s.ingest(
        [0.0, 0.1, 0.1, 0.2, 0.15, 0.3]
            .into_iter()
            .map(key)
            .collect(),
        0.4,
    )
    .unwrap();
    assert_eq!(insight(&mut s, 0.0, 60.0)["intervalCount"], 1);
    s.advance(0.5, true).unwrap();
    s.ingest(vec![key(0.6)], 0.6).unwrap();
    assert_eq!(insight(&mut s, 0.0, 60.0)["intervalCount"], 1);
    let mut fast = store();
    fast.ingest(vec![key(0.0), key(0.02)], 0.03).unwrap();
    let r = insight(&mut fast, 0.0, 60.0);
    assert_eq!(r["intervalCount"], 0);
    assert!(r["bpm"].is_null());
    assert_eq!(r["burstPeak"], 2);
}
#[test]
fn rhythm_minute_endpoints_cross_minute_deletion_and_restart() {
    let file = File::new();
    let mut s = Store::open(&file.0).unwrap();
    s.ingest([59.9, 60.0, 60.5].into_iter().map(key).collect(), 60.6)
        .unwrap();
    assert_eq!(insight(&mut s, 0.0, 60.0)["burstPeak"], 1);
    let r = insight(&mut s, 60.0, 120.0);
    assert_eq!(r["intervalCount"], 2);
    assert_eq!(r["burstPeak"], 3);
    assert_eq!(r["burstPeakAt"], 60);
    assert_eq!(insight(&mut s, 60.1, 120.0)["burstPeak"], 0);
    drop(s);
    let mut s = Store::open(&file.0).unwrap();
    s.ingest(vec![key(60.7)], 60.8).unwrap();
    assert_eq!(insight(&mut s, 60.0, 120.0)["intervalCount"], 2);
    s.delete(60.0, 61.0).unwrap();
    assert_eq!(insight(&mut s, 60.0, 120.0)["measuredMinutes"], 0);
    s.ingest(vec![key(60.9)], 61.0).unwrap();
    assert_eq!(insight(&mut s, 60.0, 120.0)["intervalCount"], 0);
}
#[test]
fn old_v1_rows_bootstrap_once_without_fabricated_timing() {
    let file = File::new();
    {
        let db = Connection::open(&file.0).unwrap();
        db.execute_batch("CREATE TABLE minutes(minute INTEGER PRIMARY KEY,keys INTEGER NOT NULL DEFAULT 0,left_clicks INTEGER NOT NULL DEFAULT 0,right_clicks INTEGER NOT NULL DEFAULT 0,middle_clicks INTEGER NOT NULL DEFAULT 0,distance REAL NOT NULL DEFAULT 0,scroll REAL NOT NULL DEFAULT 0,keyboard_mask INTEGER NOT NULL DEFAULT 0,mouse_mask INTEGER NOT NULL DEFAULT 0);CREATE TABLE key_histograms(minute INTEGER NOT NULL REFERENCES minutes(minute) ON DELETE CASCADE,label TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(minute,label)) WITHOUT ROWID;INSERT INTO minutes(minute,keys)VALUES(0,5),(60,7);INSERT INTO key_histograms VALUES(0,'A',5),(60,'B',7);PRAGMA user_version=1;").unwrap();
    }
    let mut s = Store::open(&file.0).unwrap();
    let r = insight(&mut s, 0.0, 120.0);
    assert_eq!(r["measuredMinutes"], 0);
    assert!(r["bpm"].is_null());
    let sync = changes(&mut s, 0);
    assert_eq!(sync["changes"].as_array().unwrap().len(), 2);
    assert!(sync["changes"][0]["record"].get("rhythm").is_none());
    let cursor = sync["cursor"].as_i64().unwrap();
    drop(s);
    let mut s = Store::open(&file.0).unwrap();
    assert!(changes(&mut s, cursor)["changes"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(s.summary(0.0, 120.0).unwrap().key_presses, 12);
    assert_eq!(
        s.db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
}
#[test]
fn journal_failure_rolls_back_counters_timing_cursor_and_transient_state() {
    let mut s = store();
    s.ingest(vec![key(0.0)], 0.0).unwrap();
    let before = changes(&mut s, 0);
    s.db.execute_batch("CREATE TRIGGER reject_sync BEFORE INSERT ON sync_journal BEGIN SELECT RAISE(FAIL,'fixture'); END").unwrap();
    assert!(s.ingest(vec![key(0.1)], 0.1).is_err());
    assert_eq!(s.summary(0.0, 60.0).unwrap().key_presses, 1);
    assert_eq!(changes(&mut s, 0), before);
    assert_eq!(insight(&mut s, 0.0, 60.0)["intervalCount"], 0);
    s.db.execute_batch("DROP TRIGGER reject_sync").unwrap();
    s.ingest(vec![key(0.1)], 0.1).unwrap();
    assert_eq!(insight(&mut s, 0.0, 60.0)["intervalCount"], 1);
    assert_eq!(s.summary(0.0, 60.0).unwrap().key_presses, 2);
}
#[test]
fn sync_pages_coalesce_and_keep_updates_after_an_acknowledged_cursor() {
    let file = File::new();
    let mut s = Store::open(&file.0).unwrap();
    s.ingest(vec![key(0.0), key(60.0), key(120.0)], 120.0)
        .unwrap();
    let page = call(&mut s, json!({"op":"syncChanges","after":0,"limit":1}));
    assert_eq!(page["hasMore"], true);
    let cursor = page["cursor"].as_i64().unwrap();
    s.ingest(vec![key(0.1)], 120.1).unwrap();
    let remaining = changes(&mut s, cursor);
    assert_eq!(remaining["changes"].as_array().unwrap().len(), 3);
    let minute_zero = remaining["changes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["minute"] == 0)
        .unwrap();
    assert_eq!(minute_zero["record"]["keys"], 2);
    assert!(minute_zero["revision"].as_i64().unwrap() > cursor);
    assert_eq!(
        s.db.query_row("SELECT COUNT(*) FROM sync_journal", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        3
    );
    let all = changes(&mut s, 0);
    drop(s);
    let mut reopened = Store::open(&file.0).unwrap();
    assert_eq!(changes(&mut reopened, 0), all);
    assert!(reopened
        .request(r#"{"op":"syncChanges","after":-1,"limit":1}"#)
        .is_err());
    assert!(reopened
        .request(r#"{"op":"syncChanges","after":0,"limit":1001}"#)
        .is_err());
}
#[test]
fn replicas_roundtrip_all_sixty_mask_bits_and_aggregate_timing() {
    let mut replica = store();
    let mut update = change(1, 0);
    update["record"]["keyboardMask"] = json!("1152921504606846975");
    update["record"]["mouseMask"] = json!("576460752303423488");
    update["record"]["rhythm"] = json!({"intervalCount":1,"intervalSumMs":100.0,"burstPeak":2,"burstPeakAt":0,"measuredMinutes":1});
    assert_eq!(
        call(
            &mut replica,
            json!({"op":"replicaApply","changes":[update]})
        )["applied"],
        1
    );
    let summary = replica.summary(0.0, 60.0).unwrap();
    assert_eq!(summary.keyboard_active_seconds, 60);
    assert_eq!(summary.mouse_active_seconds, 1);
    assert_eq!(summary.total_active_seconds, 60);
    assert_eq!(insight(&mut replica, 0.0, 60.0)["bpm"], 600.0);
}
#[test]
fn replicas_duplicate_out_of_order_tombstones_survive_restart() {
    let file = File::new();
    let mut s = Store::open(&file.0).unwrap();
    assert_eq!(
        call(
            &mut s,
            json!({"op":"replicaApply","changes":[change(10,0),change(10,0),change(8,0)]})
        ),
        json!({"applied":1,"ignored":2})
    );
    call(
        &mut s,
        json!({"op":"replicaApply","changes":[deletion(12,0)]}),
    );
    drop(s);
    let mut s = Store::open(&file.0).unwrap();
    assert_eq!(
        call(
            &mut s,
            json!({"op":"replicaApply","changes":[change(11,0),change(10,0),deletion(12,0)]})
        ),
        json!({"applied":0,"ignored":3})
    );
    assert_eq!(s.summary(0.0, 60.0).unwrap().key_presses, 0);
    assert_eq!(
        call(
            &mut s,
            json!({"op":"replicaApply","changes":[change(14,0),deletion(13,0)]})
        ),
        json!({"applied":1,"ignored":1})
    );
    assert_eq!(s.summary(0.0, 60.0).unwrap().key_presses, 1);
}
#[test]
fn replica_validation_is_atomic_and_rejects_text_invalid_counts_masks_and_timing() {
    let mut s = store();
    let mut cases = vec![];
    let mut c = change(2, 60);
    c["record"]["keyCounts"] = json!({"secret typed content":1});
    cases.push(c);
    let mut c = change(2, 60);
    c["record"]["keyboardMask"] = json!(1);
    cases.push(c);
    let mut c = change(2, 60);
    c["record"]["keyboardMask"] = json!("1152921504606846976");
    cases.push(c);
    let mut c = change(2, 60);
    c["record"]["keys"] = json!(-1);
    cases.push(c);
    let mut c = change(2, 60);
    c["record"]["distance"] = json!(-0.1);
    cases.push(c);
    let mut c = change(2, 60);
    c["record"]["keyCounts"] = json!({"A":2});
    cases.push(c);
    let mut c = change(2, 60);
    c["record"]["rhythm"] = json!({"intervalCount":1,"intervalSumMs":10,"burstPeak":2,"burstPeakAt":61,"measuredMinutes":1});
    cases.push(c);
    let mut c = change(2, 60);
    c["record"]["rawText"] = json!("forbidden");
    cases.push(c);
    let mut c = deletion(2, 60);
    c["record"] = record(1);
    cases.push(c);
    cases.push(change(0, 60));
    cases.push(change(2, 61));
    for invalid in cases {
        assert!(s
            .request(&json!({"op":"replicaApply","changes":[change(1,0),invalid]}).to_string())
            .is_err());
        assert_eq!(s.summary(0.0, 120.0).unwrap().key_presses, 0);
    }
    assert_eq!(
        s.db.query_row("SELECT COUNT(*) FROM replica_versions", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
}
#[test]
fn replica_sql_failure_rolls_back_rows_and_revision_receipts() {
    let mut s = store();
    s.db.execute_batch("CREATE TRIGGER reject_replica BEFORE INSERT ON minutes WHEN NEW.minute=60 BEGIN SELECT RAISE(FAIL,'fixture'); END").unwrap();
    let request = json!({"op":"replicaApply","changes":[change(1,0),change(2,60)]});
    assert!(s.request(&request.to_string()).is_err());
    assert_eq!(s.summary(0.0, 120.0).unwrap().key_presses, 0);
    assert_eq!(
        s.db.query_row("SELECT COUNT(*) FROM replica_versions", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    s.db.execute_batch("DROP TRIGGER reject_replica").unwrap();
    assert_eq!(call(&mut s, request)["applied"], 2);
}
#[test]
fn local_delete_and_clear_sync_tombstones_remove_remote_rows_and_payloads() {
    let mut source = store();
    let mut target = store();
    source.ingest(vec![key(0.0), key(60.0)], 65.0).unwrap();
    let first = changes(&mut source, 0);
    call(
        &mut target,
        json!({"op":"replicaApply","changes":first["changes"]}),
    );
    let cursor = first["cursor"].as_i64().unwrap();
    source.delete(1.0, 2.0).unwrap();
    source.clear().unwrap();
    let removed = changes(&mut source, cursor);
    assert!(removed["changes"]
        .as_array()
        .unwrap()
        .iter()
        .all(|c| c["deleted"] == true && c["record"].is_null()));
    call(
        &mut target,
        json!({"op":"replicaApply","changes":removed["changes"]}),
    );
    call(
        &mut target,
        json!({"op":"replicaApply","changes":first["changes"]}),
    );
    assert_eq!(target.summary(0.0, 120.0).unwrap().key_presses, 0);
    assert_eq!(
        source
            .db
            .query_row(
                "SELECT COUNT(*) FROM sync_journal WHERE record IS NOT NULL",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
}
#[test]
fn storage_retention_deletes_oldest_and_journals_tombstones_without_resurrection() {
    let file = File::new();
    let mut s = Store::open(&file.0).unwrap();
    let samples = (0..5000).map(|i| key(i as f64 * 60.0)).collect();
    s.ingest(samples, 4999.0 * 60.0).unwrap();
    let before = s.storage_info().unwrap();
    assert!(before["databaseBytes"].as_u64().unwrap() > 1024 * 1024);
    let cursor = changes(&mut s, 0)["cursor"].as_i64().unwrap();
    let export_snapshot = call(
        &mut s,
        json!({"op":"exportPage","start":0,"end":5000*60,"limit":1}),
    )["snapshot"]
        .clone();
    let result = s.retention(1024 * 1024).unwrap();
    assert!(s
        .request(&json!({"op":"exportValidate","snapshot":export_snapshot}).to_string())
        .is_err());
    assert!(result["deletedMinutes"].as_u64().unwrap() > 0);
    assert_eq!(result["limitMet"], true);
    let after = s.storage_info().unwrap();
    assert!(after["oldestMinute"].as_i64().unwrap() > 0);
    assert_eq!(after["newestMinute"], 4999 * 60);
    assert!(after["databaseBytes"].as_u64().unwrap() <= 1024 * 1024);
    let deleted: i64 =
        s.db.query_row(
            "SELECT COUNT(*) FROM sync_journal WHERE deleted=1 AND record IS NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(deleted as u64, result["deletedMinutes"].as_u64().unwrap());
    assert!(!changes(&mut s, cursor)["changes"]
        .as_array()
        .unwrap()
        .is_empty());
    s.advance(5001.0 * 60.0, false).unwrap();
    assert_eq!(s.summary(0.0, 60.0).unwrap().key_presses, 0);
    assert!(s.retention(1024 * 1024 - 1).is_err());
}
#[test]
fn retention_reports_unmet_metadata_limit_truthfully() {
    let mut s = store();
    s.db.execute_batch("CREATE TABLE metadata_fixture(payload BLOB);INSERT INTO metadata_fixture VALUES(zeroblob(2097152))").unwrap();
    let value = s.retention(1024 * 1024).unwrap();
    assert_eq!(value["deletedMinutes"], 0);
    assert_eq!(value["limitMet"], false);
    assert!(value["databaseBytes"].as_u64().unwrap() > 1024 * 1024);
}
#[test]
fn retention_tail_preserves_a_proven_fitting_suffix_instead_of_clearing_all() {
    let file = File::new();
    let oracle_file = File::new();
    let mut s = Store::open(&file.0).unwrap();
    let mut labels: Vec<String> = (b'A'..=b'Z')
        .chain(b'0'..=b'9')
        .map(|v| (v as char).to_string())
        .collect();
    labels.extend((1..=20).map(|n| format!("F{n}")));
    labels.extend((0..=9).map(|n| format!("Num {n}")));
    labels.extend(
        [
            "Space",
            "Return",
            "Enter",
            "Tab",
            "Escape",
            "Esc",
            "Delete",
            "Backspace",
            "Forward Delete",
            "ForwardDelete",
            "Caps Lock",
            "CapsLock",
            "Caps",
            "Shift",
            "Control",
            "Ctrl",
            "Option",
            "Alt",
            "Windows",
            "Command",
            "Cmd",
            "Fn",
            "Left",
            "Right",
            "Up",
            "Down",
            "Home",
            "End",
            "Page Up",
            "Page Down",
            "PageUp",
            "PageDown",
            "Clear",
            "Help",
            "Other",
            "-",
            "=",
            "[",
            "]",
            "\\",
            ";",
            "'",
            ",",
            ".",
            "/",
            "`",
            "+",
            "*",
            "←",
            "→",
            "↑",
            "↓",
        ]
        .map(String::from),
    );
    let per_key = 50_000_000_000_000i64;
    {
        let tx = s.db.transaction().unwrap();
        tx.execute_batch("CREATE TABLE metadata_fixture(payload BLOB);INSERT INTO metadata_fixture VALUES(zeroblob(1048576))").unwrap();
        for n in 0..44i64 {
            tx.execute(
                "INSERT INTO minutes(minute,keys) VALUES(?,?)",
                params![n * 60, per_key * labels.len() as i64],
            )
            .unwrap();
            for label in &labels {
                assert_eq!(physical_label(Some(label)), *label);
                tx.execute(
                    "INSERT INTO key_histograms VALUES(?,?,?)",
                    params![n * 60, label, per_key],
                )
                .unwrap();
            }
            extensions::journal(&tx, n * 60, false).unwrap();
        }
        tx.commit().unwrap();
    }
    s.db.execute_batch("VACUUM").unwrap();
    let before = s.storage_info().unwrap()["databaseBytes"].as_u64().unwrap();
    std::fs::copy(&file.0, &oracle_file.0).unwrap();
    let mut oracle = Store::open(&oracle_file.0).unwrap();
    oracle.delete(0.0, 60.0).unwrap();
    oracle.db.execute_batch("VACUUM").unwrap();
    let cap = oracle.storage_info().unwrap()["databaseBytes"]
        .as_u64()
        .unwrap();
    assert!(
        cap >= 1024 * 1024 && cap < before,
        "fixture must prove deleting one minute saves bytes: {before} -> {cap}"
    );
    // Verify a failure in that one-minute tail transaction retains both rows and
    // journals; then the successful run must leave exactly the oracle's 43 rows.
    let revision =
        s.db.query_row("SELECT revision FROM sync_state", [], |r| {
            r.get::<_, i64>(0)
        })
        .unwrap();
    s.db.execute_batch("CREATE TRIGGER fail_tail BEFORE DELETE ON minutes BEGIN SELECT RAISE(ABORT,'fixture');END;").unwrap();
    assert!(s.retention(cap).is_err());
    assert_eq!(
        s.db.query_row("SELECT COUNT(*) FROM minutes", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        44
    );
    assert_eq!(
        s.db.query_row("SELECT revision FROM sync_state", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        revision
    );
    s.db.execute_batch("DROP TRIGGER fail_tail").unwrap();
    let result = s.retention(cap).unwrap();
    assert_eq!(result["limitMet"], true);
    assert_eq!(result["deletedMinutes"], 1);
    assert_eq!(
        s.db.query_row("SELECT COUNT(*) FROM minutes", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        43
    );
    assert_eq!(
        s.db.query_row(
            "SELECT COUNT(*) FROM sync_journal WHERE deleted=1 AND record IS NULL",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
    assert_eq!(
        s.summary(43.0 * 60.0, 44.0 * 60.0).unwrap().key_presses,
        per_key * labels.len() as i64
    );
}
#[test]
fn safe_engine_reports_request_errors_without_leaking_rust_internals() {
    let mut engine = Engine::open(":memory:").unwrap();
    assert!(engine.request("not json").is_err());
    assert_eq!(
        engine.request(r#"{"op":"storageInfo"}"#).unwrap()["minuteCount"],
        0
    );
    assert!(engine
        .request(r#"{"op":"ingest","samples":[],"observedThrough":-1e100}"#)
        .is_err());
    assert!(engine
        .request(r#"{"op":"replicaApply","changes":[]}"#)
        .is_ok());
}

#[test]
fn retention_cuts_an_active_minute_before_later_advance() {
    let mut s = store();
    s.ingest(vec![key(50.0)], 55.0).unwrap();
    s.db.execute_batch("CREATE TABLE metadata_fixture(payload BLOB);INSERT INTO metadata_fixture VALUES(zeroblob(2097152))").unwrap();
    let result = s.retention(1024 * 1024).unwrap();
    assert_eq!(result["deletedMinutes"], 1);
    assert_eq!(result["limitMet"], false);
    s.advance(100.0, false).unwrap();
    assert_eq!(s.summary(0.0, 60.0).unwrap().total_active_seconds, 0);
    assert_eq!(s.summary(0.0, 60.0).unwrap().key_presses, 0);
    // Its not-deleted next-minute tail can remain, matching explicit minute deletion.
    assert_eq!(s.summary(60.0, 120.0).unwrap().total_active_seconds, 20);
    assert_eq!(insight(&mut s, 0.0, 120.0)["measuredMinutes"], 0);
    let journal = changes(&mut s, 0);
    assert!(journal["changes"]
        .as_array()
        .unwrap()
        .iter()
        .any(|c| c["minute"] == 0 && c["deleted"] == true));
}

#[test]
fn additive_schema_keeps_only_minute_precision_and_latest_private_safe_snapshots() {
    let mut s = store();
    s.ingest(vec![key(0.1), key(0.2)], 0.3).unwrap();
    s.ingest(
        vec![Sample {
            timestamp: 0.4,
            kind: Kind::KeyPress,
            key_label: Some("Never store my raw text".into()),
            distance_points: 0.0,
            scroll_delta: 0.0,
        }],
        0.5,
    )
    .unwrap();
    let columns = |table: &str| {
        s.db.prepare(&format!("PRAGMA table_info({table})"))
            .unwrap()
            .query_map([], |r| r.get::<_, String>(1))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap()
    };
    assert_eq!(
        columns("rhythm_minutes"),
        [
            "minute",
            "interval_count",
            "interval_sum_ms",
            "burst_peak",
            "burst_peak_at",
            "measured_minutes"
        ]
    );
    assert_eq!(
        columns("sync_journal"),
        ["minute", "revision", "deleted", "record"]
    );
    assert_eq!(columns("replica_versions"), ["minute", "revision"]);
    let snapshot: String =
        s.db.query_row("SELECT record FROM sync_journal", [], |r| r.get(0))
            .unwrap();
    assert!(!snapshot.contains("Never store my raw text"));
    let value: Value = serde_json::from_str(&snapshot).unwrap();
    assert_eq!(value["rhythm"]["burstPeakAt"], 0);
    assert_eq!(value["keyCounts"]["Other"], 1);
    assert_eq!(
        s.db.query_row("SELECT COUNT(*) FROM sync_journal", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn range_totals_fail_closed_on_integer_or_floating_overflow() {
    let mut s = store();
    // Valid individual remote counts can still exceed i64 in a large query.
    let mut records = Vec::new();
    for index in 0..1000 {
        let mut value = change(index + 1, index * 60);
        value["record"] = record(9_007_199_254_740_991);
        records.push(value);
    }
    call(&mut s, json!({"op":"replicaApply","changes":records}));
    let mut records = Vec::new();
    for index in 1000..1025 {
        let mut value = change(index + 1, index * 60);
        value["record"] = record(9_007_199_254_740_991);
        records.push(value);
    }
    call(&mut s, json!({"op":"replicaApply","changes":records}));
    assert!(s.summary(0.0, 100000.0).is_err());
    let mut a = Summary {
        mouse_distance_points: f64::MAX,
        ..Summary::default()
    };
    assert!(a
        .add(Summary {
            mouse_distance_points: f64::MAX,
            ..Summary::default()
        })
        .is_err());
}

#[test]
fn windows_physical_modifier_labels_survive_replication() {
    let mut source = store();
    let mut target = store();
    let samples = ["Alt", "Windows"]
        .into_iter()
        .enumerate()
        .map(|(i, label)| Sample {
            timestamp: i as f64,
            kind: Kind::KeyPress,
            key_label: Some(label.into()),
            distance_points: 0.0,
            scroll_delta: 0.0,
        })
        .collect();
    source.ingest(samples, 2.0).unwrap();
    let sync = changes(&mut source, 0);
    call(
        &mut target,
        json!({"op":"replicaApply","changes":sync["changes"]}),
    );
    assert_eq!(
        target.summary(0.0, 60.0).unwrap().key_counts,
        BTreeMap::from([("Alt".into(), 1), ("Windows".into(), 1)])
    );
}

#[test]
fn export_is_byte_bounded_during_construction_without_truncation() {
    let s = store();
    s.db.execute_batch("BEGIN;WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<239999) INSERT INTO minutes(minute,keys) SELECT x*60,1 FROM n;INSERT INTO key_histograms(minute,label,count) SELECT minute,'A',1 FROM minutes;COMMIT;").unwrap();
    let small = s.export(0.0, 120.0).unwrap();
    assert_eq!(
        small
            .lines()
            .filter(|line| line.contains("\"A:1\""))
            .count(),
        2
    );
    let error = s
        .export(0.0, 240000.0 * 60.0)
        .err()
        .expect("oversized export must fail without returning a truncated CSV")
        .to_string();
    assert!(error.contains("8 MiB"));
    assert_eq!(
        s.db.query_row("SELECT COUNT(*) FROM minutes", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        240000
    );
}

#[test]
fn sync_pages_bound_actual_json_bytes_and_preserve_every_revision() {
    let mut source = store();
    let mut target = store();
    let mut labels: Vec<String> = (b'A'..=b'Z')
        .chain(b'0'..=b'9')
        .map(|b| (b as char).to_string())
        .collect();
    labels.extend((1..=20).map(|n| format!("F{n}")));
    labels.extend((0..=9).map(|n| format!("Num {n}")));
    labels.extend(
        [
            "Space",
            "Return",
            "Enter",
            "Tab",
            "Escape",
            "Esc",
            "Delete",
            "Backspace",
            "Forward Delete",
            "ForwardDelete",
            "Caps Lock",
            "CapsLock",
            "Caps",
            "Shift",
            "Control",
            "Ctrl",
            "Option",
            "Alt",
            "Windows",
            "Command",
            "Cmd",
            "Fn",
            "Left",
            "Right",
            "Up",
            "Down",
            "Home",
            "End",
            "Page Up",
            "Page Down",
            "PageUp",
            "PageDown",
            "Clear",
            "Help",
            "Other",
            "←",
            "→",
            "↑",
            "↓",
        ]
        .map(String::from),
    );
    let per_key = 50_000_000_000_000i64;
    {
        let tx = source.db.transaction().unwrap();
        for n in 0..600i64 {
            tx.execute(
                "INSERT INTO minutes(minute,keys) VALUES(?,?)",
                params![n * 60, labels.len() as i64 * per_key],
            )
            .unwrap();
            for label in &labels {
                tx.execute(
                    "INSERT INTO key_histograms VALUES(?,?,?)",
                    params![n * 60, label, per_key],
                )
                .unwrap();
            }
            extensions::journal(&tx, n * 60, false).unwrap();
        }
        tx.commit().unwrap();
    }
    let mut after = 0;
    let mut seen = 0;
    loop {
        let page = source.sync_changes(after, 500).unwrap();
        assert!(serde_json::to_vec(&page).unwrap().len() <= 1024 * 1024);
        let records = page["changes"].as_array().unwrap();
        if after == 0 {
            assert!(records.len() < 500);
            assert_eq!(page["hasMore"], true);
        }
        for c in records {
            assert!(c["revision"].as_i64().unwrap() > after);
        }
        seen += records.len();
        call(&mut target, json!({"op":"replicaApply","changes":records}));
        let cursor = page["cursor"].as_i64().unwrap();
        if page["hasMore"] != true {
            break;
        }
        assert!(cursor > after);
        after = cursor;
    }
    assert_eq!(seen, 600);
    assert_eq!(
        source.summary(0.0, 36000.0).unwrap(),
        target.summary(0.0, 36000.0).unwrap()
    );
}
