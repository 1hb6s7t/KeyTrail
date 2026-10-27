use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

fn call(s: &mut Store, v: Value) -> Value {
    s.request(&v.to_string()).unwrap()
}
fn page(s: &mut Store, start: f64, end: f64, limit: usize, cursor: Value) -> Value {
    call(
        s,
        json!({"op":"exportPage","start":start,"end":end,"limit":limit,"cursor":cursor}),
    )
}
fn validate(s: &mut Store, snapshot: &Value) -> Result<Value> {
    s.request(&json!({"op":"exportValidate","snapshot":snapshot}).to_string())
}
fn read_all(s: &mut Store, start: f64, end: f64, limit: usize) -> (String, usize) {
    let mut output = String::new();
    let mut cursor = Value::Null;
    let mut expected = None;
    let mut count = 0;
    loop {
        let value = page(s, start, end, limit, cursor);
        assert!(serde_json::to_vec(&value).unwrap().len() <= 1024 * 1024);
        if let Some(snapshot) = &expected {
            assert_eq!(&value["snapshot"], snapshot);
        } else {
            expected = Some(value["snapshot"].clone());
            output.push_str(value["header"].as_str().unwrap());
        }
        output.push_str(value["csv"].as_str().unwrap());
        count += value["rowCount"].as_u64().unwrap() as usize;
        if value["hasMore"] == false {
            assert_eq!(count as u64, value["totalRows"].as_u64().unwrap());
            assert!(value["nextCursor"].is_null());
            break;
        }
        assert!(value["rowCount"].as_u64().unwrap() > 0);
        cursor = value["nextCursor"].clone();
    }
    assert!(validate(s, expected.as_ref().unwrap()).unwrap().is_null());
    (output, count)
}
struct File(String);
impl File {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        Self(
            std::env::temp_dir()
                .join(format!(
                    "keytrail-export-pages-{}-{}.sqlite",
                    std::process::id(),
                    NEXT.fetch_add(1, Ordering::Relaxed)
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
fn seed(s: &Store) {
    s.db.execute_batch("INSERT INTO minutes(minute,keys,keyboard_mask,mouse_mask,distance,scroll) VALUES(0,3,1152921504606846975,15,3.5,1.25),(60,2,1152921504606846975,31,1.5,4.5),(180,1,3,7,0,0);INSERT INTO key_histograms VALUES(0,'Z',1),(0,'A',2),(60,'Quote\"',2),(180,'A',1);").unwrap();
}

#[test]
fn csv_pages_match_legacy_format_half_open_mask_clipping_and_histogram_order() {
    let mut s = Store::open(":memory:").unwrap();
    seed(&s);
    for (start, end) in [
        (0.0, 240.0),
        (0.5, 61.5),
        (60.0, 180.0),
        (61.0, 61.0),
        (120.0, 180.0),
    ] {
        let legacy = s.export(start, end).unwrap();
        let (stream, _) = read_all(&mut s, start, end, 1);
        assert_eq!(stream, legacy, "range {start}..{end}");
    }
    let first = page(&mut s, 0.5, 61.5, 1, Value::Null);
    assert!(first["csv"]
        .as_str()
        .unwrap()
        .contains(",59,3,59,\"A:2;Z:1\"\r\n"));
    assert_eq!(first["totalRows"], 2);
}

#[test]
fn csv_cursor_binds_range_source_and_revision_and_survives_reopen() {
    let file = File::new();
    let mut s = Store::open(&file.0).unwrap();
    seed(&s);
    let first = page(&mut s, 0.0, 240.0, 1, Value::Null);
    let cursor = first["nextCursor"].clone();
    let version = first["snapshot"].clone();
    drop(s);
    let mut s = Store::open(&file.0).unwrap();
    assert!(validate(&mut s, &version).is_ok());
    assert_eq!(page(&mut s, 0.0, 240.0, 1, cursor.clone())["rowCount"], 1);
    for (start, end) in [(1.0, 240.0), (0.0, 241.0)] {
        assert!(s
            .request(
                &json!({"op":"exportPage","start":start,"end":end,"cursor":cursor}).to_string()
            )
            .is_err());
    }
    let mut other = Store::open(":memory:").unwrap();
    seed(&other);
    assert_eq!(
        s.export(0.0, 240.0).unwrap(),
        other.export(0.0, 240.0).unwrap()
    );
    assert!(validate(&mut other, &version).is_err());
    assert!(other
        .request(&json!({"op":"exportPage","start":0,"end":240,"cursor":cursor}).to_string())
        .is_err());
    drop(s);
    std::fs::remove_file(&file.0).unwrap();
    let mut rebuilt = Store::open(&file.0).unwrap();
    seed(&rebuilt);
    assert!(validate(&mut rebuilt, &version).is_err());
}

#[test]
fn csv_versions_cover_all_statistic_tables_and_rollback_without_sync_clock() {
    let mut s = Store::open(":memory:").unwrap();
    seed(&s);
    let sync_before: i64 =
        s.db.query_row("SELECT revision FROM sync_state", [], |r| r.get(0))
            .unwrap();
    for mutation in [
        "UPDATE minutes SET keys=keys WHERE minute=0",
        "UPDATE key_histograms SET count=count+1 WHERE minute=0 AND label='A'",
        "INSERT INTO rhythm_minutes VALUES(0,0,0,1,0,1)",
        "UPDATE rhythm_minutes SET burst_peak=2 WHERE minute=0",
        "DELETE FROM rhythm_minutes WHERE minute=0",
        "DELETE FROM key_histograms WHERE minute=0 AND label='Z'",
        "INSERT INTO key_histograms VALUES(0,'Z',1)",
        "DELETE FROM minutes WHERE minute=180",
        "INSERT INTO minutes(minute,keys) VALUES(180,1)",
    ] {
        let p = page(&mut s, 0.0, 240.0, 1, Value::Null);
        s.db.execute_batch(mutation).unwrap();
        assert!(validate(&mut s, &p["snapshot"]).is_err(), "{mutation}");
    }
    assert_eq!(
        sync_before,
        s.db.query_row("SELECT revision FROM sync_state", [], |r| r
            .get::<_, i64>(0))
            .unwrap()
    );
    let p = page(&mut s, 0.0, 240.0, 1, Value::Null);
    s.db.execute_batch("BEGIN;DELETE FROM minutes;ROLLBACK;")
        .unwrap();
    assert!(validate(&mut s, &p["snapshot"]).is_ok());
    assert_eq!(
        page(&mut s, 0.0, 240.0, 1, p["nextCursor"].clone())["totalRows"],
        3
    );
    s.db.execute_batch("CREATE TRIGGER fail_export_fixture BEFORE DELETE ON minutes BEGIN SELECT RAISE(ABORT,'fixture');END;").unwrap();
    assert!(s.delete(0.0, 60.0).is_err());
    assert!(validate(&mut s, &p["snapshot"]).is_ok());
}

#[test]
fn csv_external_attach_mutations_are_transactional_and_invalidate_cached_totals() {
    let file = File::new();
    let mut s = Store::open(&file.0).unwrap();
    seed(&s);
    let p = page(&mut s, 0.0, 240.0, 1, Value::Null);
    let connection = Connection::open_in_memory().unwrap();
    connection
        .execute("ATTACH DATABASE ? AS stats", [&file.0])
        .unwrap();
    connection.execute_batch("PRAGMA foreign_keys=ON;BEGIN IMMEDIATE;DELETE FROM stats.minutes WHERE minute=0;ROLLBACK;").unwrap();
    assert!(validate(&mut s, &p["snapshot"]).is_ok());
    connection
        .execute_batch("BEGIN IMMEDIATE;DELETE FROM stats.minutes WHERE minute=0;COMMIT;")
        .unwrap();
    assert!(validate(&mut s, &p["snapshot"]).is_err());
    assert_eq!(page(&mut s, 0.0, 240.0, 1, Value::Null)["totalRows"], 2);
    assert_eq!(
        s.db.query_row(
            "SELECT COUNT(*) FROM key_histograms WHERE minute=0",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    assert_eq!(
        s.db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn csv_replica_apply_lower_source_revision_changes_snapshot() {
    let mut s = Store::open(":memory:").unwrap();
    let change = |minute, revision| json!({"minute":minute,"revision":revision,"deleted":false,"record":{"keys":1,"leftClicks":0,"rightClicks":0,"middleClicks":0,"distance":0.0,"scroll":0.0,"keyboardMask":"1","mouseMask":"0","keyCounts":{"A":1}}});
    call(
        &mut s,
        json!({"op":"replicaApply","changes":[change(0,100)]}),
    );
    let p = page(&mut s, 0.0, 240.0, 1, Value::Null);
    call(
        &mut s,
        json!({"op":"replicaApply","changes":[change(60,1)]}),
    );
    assert!(validate(&mut s, &p["snapshot"]).is_err());
    let p = page(&mut s, 0.0, 240.0, 1, Value::Null);
    call(
        &mut s,
        json!({"op":"replicaApply","changes":[change(60,1)]}),
    );
    assert!(validate(&mut s, &p["snapshot"]).is_ok()); // ignored replay performs no data writes
    call(
        &mut s,
        json!({"op":"replicaApply","changes":[{"minute":60,"revision":2,"deleted":true}]}),
    );
    assert!(validate(&mut s, &p["snapshot"]).is_err());
}

#[test]
fn csv_dense_history_exceeds_eight_mib_with_bounded_complete_pages() {
    let mut s = Store::open(":memory:").unwrap();
    let mut labels: Vec<String> = (b'A'..=b'Z')
        .chain(b'0'..=b'9')
        .map(|b| (b as char).to_string())
        .collect();
    labels.extend((1..=20).map(|n| format!("F{n}")));
    labels.extend((0..=9).map(|n| format!("Num {n}")));
    labels.extend(["←", "→", "↑", "↓"].map(String::from));
    labels.sort();
    let per_key = 50_000_000_000_000i64;
    s.db.execute_batch("CREATE TEMP TABLE fixture_labels(label TEXT PRIMARY KEY);BEGIN")
        .unwrap();
    for label in &labels {
        assert_eq!(&physical_label(Some(label)), label);
        s.db.execute("INSERT INTO fixture_labels VALUES(?)", [label])
            .unwrap();
    }
    s.db.execute("WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<7999) INSERT INTO minutes(minute,keys) SELECT x*60,? FROM n",[per_key*labels.len() as i64]).unwrap();
    s.db.execute(
        "INSERT INTO key_histograms SELECT minute,label,? FROM minutes,fixture_labels",
        [per_key],
    )
    .unwrap();
    s.db.execute_batch("COMMIT;DROP TABLE fixture_labels")
        .unwrap();
    assert!(s
        .export(0.0, 480000.0)
        .unwrap_err()
        .to_string()
        .contains("8 MiB"));
    let first = page(&mut s, 0.0, 480000.0, 1000, Value::Null);
    assert!(first["rowCount"].as_u64().unwrap() < 1000); // actual byte budget, not row limit
    let (stream, count) = read_all(&mut s, 0.0, 480000.0, 1000);
    assert_eq!(count, 8000);
    assert!(stream.len() > 8 * 1024 * 1024);
    let data: Vec<_> = stream.lines().skip(3).collect();
    assert_eq!(data.len(), 8000);
    let histogram = format!(
        "\"{}\"",
        labels
            .iter()
            .map(|v| format!("{v}:{per_key}"))
            .collect::<Vec<_>>()
            .join(";")
    );
    for (i, row) in data.iter().enumerate() {
        assert!(row.starts_with(&format!(
            "{},{}",
            iso8601((i * 60) as f64),
            per_key * labels.len() as i64
        )));
        assert!(row.ends_with(&histogram)); // every count and lexical UTF-8 label, no missing row
    }
}

#[test]
fn csv_invalid_cursor_limits_and_single_giant_row_fail_without_advancing() {
    let mut s = Store::open(":memory:").unwrap();
    seed(&s);
    for value in [
        json!({"op":"exportPage","start":0,"end":60,"limit":0}),
        json!({"op":"exportPage","start":0,"end":60,"limit":1001}),
        json!({"op":"exportPage","start":-1,"end":60}),
        json!({"op":"exportPage","start":60,"end":0}),
    ] {
        assert!(s.request(&value.to_string()).is_err());
    }
    let mut c = page(&mut s, 0.0, 240.0, 1, Value::Null)["nextCursor"].clone();
    c["afterMinute"] = json!(1);
    assert!(s
        .request(&json!({"op":"exportPage","start":0,"end":240,"cursor":c}).to_string())
        .is_err());
    let giant = "\"".repeat(1024 * 1024);
    s.db.execute("INSERT INTO key_histograms VALUES(0,?,1)", [giant])
        .unwrap();
    let before: i64 =
        s.db.query_row("SELECT revision FROM export_snapshot", [], |r| r.get(0))
            .unwrap();
    assert!(s
        .request(r#"{"op":"exportPage","start":0,"end":60}"#)
        .unwrap_err()
        .to_string()
        .contains("single CSV row"));
    assert_eq!(
        before,
        s.db.query_row("SELECT revision FROM export_snapshot", [], |r| r
            .get::<_, i64>(0))
            .unwrap()
    );
}

#[test]
fn csv_v1_database_gains_tracking_without_rewriting_history() {
    let file = File::new();
    {
        let db = Connection::open(&file.0).unwrap();
        db.execute_batch("PRAGMA user_version=1;CREATE TABLE minutes(minute INTEGER PRIMARY KEY,keys INTEGER NOT NULL DEFAULT 0,left_clicks INTEGER NOT NULL DEFAULT 0,right_clicks INTEGER NOT NULL DEFAULT 0,middle_clicks INTEGER NOT NULL DEFAULT 0,distance REAL NOT NULL DEFAULT 0,scroll REAL NOT NULL DEFAULT 0,keyboard_mask INTEGER NOT NULL DEFAULT 0,mouse_mask INTEGER NOT NULL DEFAULT 0);CREATE TABLE key_histograms(minute INTEGER NOT NULL REFERENCES minutes(minute) ON DELETE CASCADE,label TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(minute,label)) WITHOUT ROWID;INSERT INTO minutes(minute,keys,keyboard_mask) VALUES(60,7,3);INSERT INTO key_histograms VALUES(60,'A',7);").unwrap();
    }
    let mut s = Store::open(&file.0).unwrap();
    assert_eq!(
        s.db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    let p = page(&mut s, 0.0, 120.0, 100, Value::Null);
    assert_eq!(p["rowCount"], 1);
    assert_eq!(p["snapshot"]["revision"], 0);
    assert_eq!(
        format!(
            "{}{}",
            p["header"].as_str().unwrap(),
            p["csv"].as_str().unwrap()
        ),
        s.export(0.0, 120.0).unwrap()
    );
    assert!(p["csv"].as_str().unwrap().ends_with(",2,0,2,\"A:7\"\r\n"));
    assert_eq!(
        s.db.query_row("SELECT COUNT(*) FROM rhythm_minutes", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
}

#[test]
fn csv_public_collection_advance_delete_and_clear_invalidate_snapshots() {
    let mut s = Store::open(":memory:").unwrap();
    let p = page(&mut s, 0.0, 240.0, 100, Value::Null);
    call(
        &mut s,
        json!({"op":"ingest","samples":[{"timestamp":0,"kind":"keyPress","keyLabel":"A"}],"observedThrough":0}),
    );
    assert!(validate(&mut s, &p["snapshot"]).is_err());
    let p = page(&mut s, 0.0, 240.0, 100, Value::Null);
    call(&mut s, json!({"op":"advance","time":10}));
    assert!(validate(&mut s, &p["snapshot"]).is_err());
    let p = page(&mut s, 0.0, 240.0, 100, Value::Null);
    call(&mut s, json!({"op":"delete","start":0,"end":60}));
    assert!(validate(&mut s, &p["snapshot"]).is_err());
    let p = page(&mut s, 0.0, 240.0, 100, Value::Null);
    assert_eq!(p["totalRows"], 0);
    call(
        &mut s,
        json!({"op":"ingest","samples":[{"timestamp":60,"kind":"keyPress","keyLabel":"B"}],"observedThrough":61}),
    );
    let p = page(&mut s, 0.0, 240.0, 100, Value::Null);
    call(&mut s, json!({"op":"clear"}));
    assert!(validate(&mut s, &p["snapshot"]).is_err());
    assert_eq!(page(&mut s, 0.0, 240.0, 100, Value::Null)["totalRows"], 0);
}
