//! Cross-database retention. Callers hold both owner mutexes and end transient
//! activity only in the callback before the first deletion. Never discard durable
//! deletion tombstones to fake a cap.
use crate::text_archive::{journal, TextArchive};
use rusqlite::{params, Connection, TransactionBehavior};
use serde_json::{json, Value};
use std::path::Path;
type Result<T> = std::result::Result<T, String>;
const MAX_REVISION: i64 = 9_007_199_254_740_991;
fn integer(db: &Connection, sql: &str) -> Result<i64> {
    db.query_row(sql, [], |r| r.get(0))
        .map_err(|e| e.to_string())
}
fn bytes(db: &Connection, schema: &str) -> Result<i64> {
    integer(db, &format!("PRAGMA {schema}.page_count"))?
        .checked_mul(integer(db, &format!("PRAGMA {schema}.page_size"))?)
        .ok_or_else(|| "Database size overflow".into())
}
// Called only above the cap or after a deletion. VACUUM can reclaim both free
// pages and partially filled pages, so freelist_count alone is not a safe gate.
fn compact(db: &Connection) -> Result<()> {
    db.execute_batch("VACUUM main;VACUUM stats")
        .map_err(|e| e.to_string())
}
fn attached<T>(
    db: &mut Connection,
    stats: &Path,
    write: bool,
    work: impl FnOnce(&mut Connection) -> Result<T>,
) -> Result<T> {
    let main: String = db
        .query_row(
            "SELECT file FROM pragma_database_list WHERE name='main'",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    if main.is_empty()
        || !stats.is_file()
        || std::fs::canonicalize(&main).map_err(|e| e.to_string())?
            == std::fs::canonicalize(stats).map_err(|e| e.to_string())?
    {
        return Err("Two distinct persistent databases are required".into());
    }
    if write {
        db.execute_batch("PRAGMA foreign_keys=ON")
            .map_err(|e| e.to_string())?;
    }
    db.execute(
        "ATTACH DATABASE ? AS stats",
        [stats.to_str().ok_or("Invalid statistics path")?],
    )
    .map_err(|e| e.to_string())?;
    let result = (|| {
        if write {
            for schema in ["main", "stats"] {
                let mode: String = db
                    .query_row(&format!("PRAGMA {schema}.journal_mode"), [], |r| r.get(0))
                    .map_err(|e| e.to_string())?;
                if mode.to_lowercase() != "delete" {
                    return Err("Atomic combined retention requires DELETE journals".into());
                }
            }
            db.execute_batch("PRAGMA main.secure_delete=ON;PRAGMA stats.secure_delete=ON;PRAGMA main.synchronous=FULL;PRAGMA stats.synchronous=FULL;").map_err(|e|e.to_string())?;
        }
        work(db)
    })();
    let detach = db
        .execute_batch("DETACH DATABASE stats")
        .map_err(|e| e.to_string());
    match result {
        Ok(value) => {
            detach?;
            Ok(value)
        }
        Err(error) => Err(error),
    }
}
fn info(db: &Connection) -> Result<Value> {
    let statistics = bytes(db, "stats")?;
    let text = bytes(db, "main")?;
    let combined = statistics
        .checked_add(text)
        .ok_or("Combined size overflow")?;
    Ok(
        json!({"databaseBytes":statistics,"textBytes":text,"combinedBytes":combined,"textRecordCount":integer(db,"SELECT COUNT(*) FROM text_records")?,"minuteCount":integer(db,"SELECT COUNT(*) FROM stats.minutes")?}),
    )
}
// Shared atomic operation for explicit deletion and oldest-first retention.
fn delete_attached(
    db: &mut Connection,
    lower: Option<f64>,
    upper: Option<f64>,
) -> Result<(i64, i64)> {
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| e.to_string())?;
    {
        let mut stmt=tx.prepare("SELECT id FROM text_records WHERE (?1 IS NULL OR time>=?1) AND (?2 IS NULL OR time<?2) ORDER BY time,id").map_err(|e|e.to_string())?;
        let mut rows = stmt
            .query(params![lower, upper])
            .map_err(|e| e.to_string())?;
        while let Some(row) = rows.next().map_err(|e| e.to_string())? {
            journal(
                &tx,
                &row.get::<_, String>(0).map_err(|e| e.to_string())?,
                None,
            )?;
        }
    }
    {
        let mut stmt=tx.prepare("SELECT minute FROM stats.minutes WHERE (?1 IS NULL OR minute>=?1) AND (?2 IS NULL OR minute<?2) ORDER BY minute").map_err(|e|e.to_string())?;
        let mut rows = stmt
            .query(params![lower, upper])
            .map_err(|e| e.to_string())?;
        while let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let minute: i64 = row.get(0).map_err(|e| e.to_string())?;
            let prior = integer(&tx, "SELECT revision FROM stats.sync_state WHERE id=1")?;
            if !(0..MAX_REVISION).contains(&prior) {
                return Err("Statistics revision exhausted".into());
            }
            let revision = prior + 1;
            tx.execute(
                "UPDATE stats.sync_state SET revision=? WHERE id=1",
                [revision],
            )
            .map_err(|e| e.to_string())?;
            tx.execute("INSERT INTO stats.sync_journal(minute,revision,deleted,record) VALUES(?,?,1,NULL) ON CONFLICT(minute) DO UPDATE SET revision=excluded.revision,deleted=1,record=NULL",params![minute,revision]).map_err(|e|e.to_string())?;
        }
    }
    let text = tx
        .execute(
            "DELETE FROM text_records WHERE (?1 IS NULL OR time>=?1) AND (?2 IS NULL OR time<?2)",
            params![lower, upper],
        )
        .map_err(|e| e.to_string())? as i64;
    let minutes=tx.execute("DELETE FROM stats.minutes WHERE (?1 IS NULL OR minute>=?1) AND (?2 IS NULL OR minute<?2)",params![lower,upper]).map_err(|e|e.to_string())? as i64;
    tx.commit().map_err(|e| e.to_string())?;
    Ok((minutes, text))
}
impl TextArchive {
    pub fn storage_combined(&self, stats: &Path) -> Result<Value> {
        // A separate read connection avoids requiring mutable access just to inspect sizes.
        let path = self.db.path().ok_or("Persistent text database required")?;
        if path.is_empty() {
            return Err("Persistent text database required".into());
        }
        let mut reader =
            Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|e| e.to_string())?;
        attached(&mut reader, stats, false, |db| info(db))
    }
    /// Caller stops transient activity and invalidates pending text snapshots first.
    pub fn delete_together(&mut self, stats: &Path, start: f64, end: f64) -> Result<Value> {
        if !start.is_finite()
            || !end.is_finite()
            || start < 0.0
            || end <= start
            || end >= 1e12
            || start % 60.0 != 0.0
            || end % 60.0 != 0.0
        {
            return Err(
                "Deletion requires a finite, positive, minute-aligned half-open range".into(),
            );
        }
        attached(&mut self.db, stats, true, |db| {
            let (minutes, text) = delete_attached(db, Some(start), Some(end))?;
            let mut value = info(db)?;
            value["deletedStatisticsMinutes"] = json!(minutes);
            value["deletedTextRecords"] = json!(text);
            Ok(value)
        })
    }
    /// Does not reset keys, revisions, acknowledgements or either deletion journal.
    pub fn clear_together(&mut self, stats: &Path) -> Result<Value> {
        attached(&mut self.db, stats, true, |db| {
            let (minutes, text) = delete_attached(db, None, None)?;
            let mut value = info(db)?;
            value["deletedStatisticsMinutes"] = json!(minutes);
            value["deletedTextRecords"] = json!(text);
            Ok(value)
        })
    }
    /// Convenience for callers that already have no live activity window.
    pub fn retention_together(&mut self, stats: &Path, max_bytes: u64) -> Result<Value> {
        self.retention_together_before_deleting(stats, max_bytes, || Ok(()))
    }
    /// Flush normally before calling. Invoke `before_deleting` exactly once only
    /// if data must be deleted, with no active SQLite statement or transaction.
    /// The callback may commit the live Engine window through its owner connection;
    /// size, counts and the oldest boundary are then read again before deletion.
    pub fn retention_together_before_deleting(
        &mut self,
        stats: &Path,
        max_bytes: u64,
        mut before_deleting: impl FnMut() -> Result<()>,
    ) -> Result<Value> {
        if max_bytes < 1_048_576 || max_bytes > i64::MAX as u64 {
            return Err("Retention cap must be at least 1 MiB and fit SQLite integer".into());
        }
        attached(&mut self.db, stats, true, |db| {
            if info(db)?["combinedBytes"].as_u64().ok_or("Invalid size")? > max_bytes {
                compact(db)?;
            }
            let mut prepared_for_deletion = false;
            let mut removed_minutes = 0i64;
            let mut removed_text = 0i64;
            loop {
                let current = info(db)?;
                if current["combinedBytes"].as_u64().ok_or("Invalid size")? <= max_bytes {
                    break;
                }
                let remaining = current["minuteCount"].as_u64().ok_or("Invalid count")?
                    + current["textRecordCount"].as_u64().ok_or("Invalid count")?;
                if remaining == 0 {
                    break;
                }
                if !prepared_for_deletion {
                    before_deleting()?;
                    prepared_for_deletion = true;
                    // The callback can add/remove records or free pages. No read
                    // statement survives across it; recompute every decision.
                    if info(db)?["combinedBytes"].as_u64().ok_or("Invalid size")? > max_bytes {
                        compact(db)?;
                    }
                    continue;
                }
                // Do not delete the entire final batch for a small byte excess:
                // compact/recheck after each complete natural minute in the tail.
                // Earlier batches retain their bounded throughput, while the tail
                // can preserve newer records whenever a prefix alone meets the cap.
                let batch_limit = if remaining <= 256 { 1 } else { 256 };
                let boundary:Option<f64>=db.query_row("SELECT MAX(time) FROM (SELECT time FROM (SELECT minute AS time FROM stats.minutes UNION ALL SELECT time FROM text_records) ORDER BY time LIMIT ?)",[batch_limit],|r|r.get(0)).map_err(|e|e.to_string())?;
                let Some(boundary) = boundary else {
                    break;
                };
                let upper = (boundary / 60.0).floor() * 60.0 + 60.0;
                if !upper.is_finite() {
                    return Err("Invalid oldest retention boundary".into());
                }
                let (minutes, text) = delete_attached(db, None, Some(upper))?;
                removed_text += text;
                removed_minutes += minutes;
                compact(db)?;
                if text == 0 && minutes == 0 {
                    break;
                }
            }
            let mut result = info(db)?;
            result["deletedStatisticsMinutes"] = json!(removed_minutes);
            result["deletedTextRecords"] = json!(removed_text);
            result["limitMet"] =
                json!(result["combinedBytes"].as_u64().ok_or("Invalid size")? <= max_bytes);
            Ok(result)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use keytrail_core::Engine;
    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "keytrail-win-retention-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn populate(f: &Fixture) -> (TextArchive, Engine, std::path::PathBuf) {
        let stats = f.0.join("stats.sqlite");
        let mut engine = Engine::open(stats.to_str().unwrap()).unwrap();
        let samples: Vec<_> = (0..300)
            .map(|i| json!({"timestamp":600+i*60,"kind":"keyPress","keyLabel":"A"}))
            .collect();
        engine
            .request(&json!({"op":"ingest","samples":samples,"observedThrough":18600}).to_string())
            .unwrap();
        engine.request(r#"{"op":"end","time":18600}"#).unwrap();
        let mut archive = TextArchive::open(&f.0.join("text.sqlite"), [9; 32]).unwrap();
        for i in 0..300 {
            archive
                .append(&"x".repeat(16384), (600 + i * 60) as f64, "fixture.editor")
                .unwrap();
        }
        (archive, engine, stats)
    }
    #[test]
    fn under_cap_check_does_not_rewrite_either_database() {
        let f = Fixture::new();
        let stats = f.0.join("stats.sqlite");
        let _engine = Engine::open(stats.to_str().unwrap()).unwrap();
        let text = f.0.join("text.sqlite");
        let mut archive = TextArchive::open(&text, [9; 32]).unwrap();
        let before_stats = std::fs::read(&stats).unwrap();
        let before_text = std::fs::read(&text).unwrap();
        let result = archive.retention_together(&stats, 1024 * 1024).unwrap();
        assert_eq!(result["deletedStatisticsMinutes"], 0);
        assert_eq!(result["deletedTextRecords"], 0);
        assert!(
            before_stats == std::fs::read(&stats).unwrap(),
            "under-cap maintenance rewrote statistics database"
        );
        assert!(
            before_text == std::fs::read(&text).unwrap(),
            "under-cap maintenance rewrote text database"
        );
    }
    fn live_tail(f: &Fixture) -> (TextArchive, Engine, std::path::PathBuf) {
        let stats = f.0.join("stats.sqlite");
        let mut engine = Engine::open(stats.to_str().unwrap()).unwrap();
        engine.request(r#"{"op":"ingest","samples":[{"timestamp":59,"kind":"keyPress","keyLabel":"A"}],"observedThrough":60}"#).unwrap();
        (
            TextArchive::open(&f.0.join("text.sqlite"), [9; 32]).unwrap(),
            engine,
            stats,
        )
    }
    fn tail_seconds(engine: &mut Engine) -> Value {
        engine.request(r#"{"op":"advance","time":89}"#).unwrap();
        engine
            .request(r#"{"op":"summary","start":0,"end":120}"#)
            .unwrap()["totalActiveSeconds"]
            .clone()
    }
    #[test]
    fn non_deleting_retention_keeps_full_activity_tail() {
        let f = Fixture::new();
        let (mut archive, mut engine, stats) = live_tail(&f);
        let mut calls = 0;
        let result = archive
            .retention_together_before_deleting(&stats, 1024 * 1024, || {
                calls += 1;
                engine.request(r#"{"op":"end","time":60}"#).map(|_| ())
            })
            .unwrap();
        assert_eq!(calls, 0);
        assert_eq!(result["limitMet"], true);
        assert_eq!(tail_seconds(&mut engine), 30);
    }
    #[test]
    fn compaction_without_deletion_keeps_full_activity_tail() {
        let f = Fixture::new();
        let (mut archive, mut engine, stats) = live_tail(&f);
        archive.db.execute_batch("CREATE TABLE discarded(payload BLOB); INSERT INTO discarded VALUES(zeroblob(2097152)); DROP TABLE discarded;").unwrap();
        assert!(
            archive.storage_combined(&stats).unwrap()["combinedBytes"]
                .as_u64()
                .unwrap()
                > 1024 * 1024
        );
        let mut calls = 0;
        let result = archive
            .retention_together_before_deleting(&stats, 1024 * 1024, || {
                calls += 1;
                engine.request(r#"{"op":"end","time":60}"#).map(|_| ())
            })
            .unwrap();
        assert_eq!(calls, 0);
        assert_eq!(result["limitMet"], true);
        assert_eq!(result["deletedStatisticsMinutes"], 0);
        assert_eq!(result["deletedTextRecords"], 0);
        assert_eq!(tail_seconds(&mut engine), 30);
    }
    #[test]
    fn deletion_ends_once_without_read_lock_and_deleted_minutes_do_not_return() {
        let f = Fixture::new();
        let (mut archive, mut engine, stats) = populate(&f);
        engine.request(r#"{"op":"ingest","samples":[{"timestamp":20039,"kind":"keyPress","keyLabel":"B"}],"observedThrough":20040}"#).unwrap();
        let mut calls = 0;
        let result = archive
            .retention_together_before_deleting(&stats, 2 * 1024 * 1024, || {
                calls += 1;
                // Writes through a second connection while stats is attached: this
                // would fail with SQLITE_BUSY if the retention SELECT were still live.
                engine.request(r#"{"op":"end","time":20040}"#).map(|_| ())
            })
            .unwrap();
        assert_eq!(calls, 1);
        assert!(result["deletedStatisticsMinutes"].as_u64().unwrap() > 0);
        assert!(result["deletedTextRecords"].as_u64().unwrap() > 0);
        engine.request(r#"{"op":"advance","time":20069}"#).unwrap();
        assert_eq!(
            engine
                .request(r#"{"op":"summary","start":20000,"end":20100}"#)
                .unwrap()["totalActiveSeconds"],
            1
        );
        assert_eq!(
            engine
                .request(r#"{"op":"summary","start":600,"end":660}"#)
                .unwrap()["keyPresses"],
            0
        );
        let db = Connection::open(&stats).unwrap();
        assert!(integer(&db, "SELECT COUNT(*) FROM sync_journal WHERE deleted=1").unwrap() > 0);
        assert!(
            integer(
                &archive.db,
                "SELECT COUNT(*) FROM text_journal WHERE deleted=1"
            )
            .unwrap()
                > 0
        );
    }
    #[test]
    fn failed_before_delete_callback_preserves_both_records_and_journals() {
        let f = Fixture::new();
        let (mut archive, _engine, stats) = populate(&f);
        let db = Connection::open(&stats).unwrap();
        let stats_revision = integer(&db, "SELECT revision FROM sync_state").unwrap();
        let text_revision = integer(&archive.db, "SELECT revision FROM text_state").unwrap();
        let mut calls = 0;
        let error = archive
            .retention_together_before_deleting(&stats, 2 * 1024 * 1024, || {
                calls += 1;
                Err("fixture flush failure".into())
            })
            .unwrap_err();
        assert_eq!(error, "fixture flush failure");
        assert_eq!(calls, 1);
        assert_eq!(integer(&db, "SELECT COUNT(*) FROM minutes").unwrap(), 300);
        assert_eq!(
            integer(&archive.db, "SELECT COUNT(*) FROM text_records").unwrap(),
            300
        );
        assert_eq!(
            integer(&db, "SELECT revision FROM sync_state").unwrap(),
            stats_revision
        );
        assert_eq!(
            integer(&archive.db, "SELECT revision FROM text_state").unwrap(),
            text_revision
        );
    }
    #[test]
    fn metadata_only_unmet_cap_does_not_end_activity() {
        let f = Fixture::new();
        let stats = f.0.join("stats.sqlite");
        let _engine = Engine::open(stats.to_str().unwrap()).unwrap();
        let mut archive = TextArchive::open(&f.0.join("text.sqlite"), [9; 32]).unwrap();
        archive.db.execute_batch("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<20000) INSERT INTO text_journal(id,revision,deleted,record) SELECT printf('00000000-0000-4000-8000-%012x',x),100000+x,1,NULL FROM n").unwrap();
        let mut calls = 0;
        let result = archive
            .retention_together_before_deleting(&stats, 1024 * 1024, || {
                calls += 1;
                Err("no records must mean no callback".into())
            })
            .unwrap();
        assert_eq!(calls, 0);
        assert_eq!(result["limitMet"], false);
        assert_eq!(
            integer(&archive.db, "SELECT COUNT(*) FROM text_journal").unwrap(),
            20000
        );
    }
    #[test]
    fn combined_cap_removes_oldest_preserves_newest_cascades_and_journals() {
        let f = Fixture::new();
        let (mut archive, mut engine, stats) = populate(&f);
        let before = archive.storage_combined(&stats).unwrap();
        assert_eq!(before["textRecordCount"], 300);
        assert_eq!(
            before["combinedBytes"].as_u64().unwrap(),
            std::fs::metadata(&stats).unwrap().len()
                + std::fs::metadata(f.0.join("text.sqlite")).unwrap().len()
        );
        let result = archive.retention_together(&stats, 2 * 1024 * 1024).unwrap();
        assert_eq!(result["limitMet"], true);
        assert!(result["deletedTextRecords"].as_u64().unwrap() > 0);
        assert!(result["textRecordCount"].as_u64().unwrap() > 0);
        assert_eq!(
            archive.query(json!({"start":18540,"end":18600})).unwrap()["total"],
            1
        );
        let db = Connection::open(&stats).unwrap();
        assert_eq!(
            integer(&db, "SELECT COUNT(*) FROM key_histograms").unwrap(),
            result["minuteCount"].as_i64().unwrap()
        );
        assert_eq!(
            integer(&db, "SELECT COUNT(*) FROM rhythm_minutes").unwrap(),
            result["minuteCount"].as_i64().unwrap()
        );
        let changes = engine
            .request(r#"{"op":"syncChanges","after":0,"limit":1000}"#)
            .unwrap();
        assert!(changes["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["deleted"] == true));
        assert!(archive.changes(0, 100).unwrap()["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["deleted"] == true));
    }
    #[test]
    fn cap_keeps_newest_records_when_a_partial_tail_can_fit() {
        let original = Fixture::new();
        let (mut archive, _engine, stats) = populate(&original);
        let oracle = Fixture::new();
        let oracle_stats = oracle.0.join("stats.sqlite");
        let oracle_text = oracle.0.join("text.sqlite");
        std::fs::copy(&stats, &oracle_stats).unwrap();
        std::fs::copy(original.0.join("text.sqlite"), &oracle_text).unwrap();
        let mut expected = TextArchive::open(&oracle_text, [9; 32]).unwrap();
        let cap = 2 * 1024 * 1024;
        // Reproduce the two 128-minute bulk batches, then prove with exact
        // one-minute transactions that the final 44 records need not all go.
        expected
            .delete_together(&oracle_stats, 600.0, 15960.0)
            .unwrap();
        attached(&mut expected.db, &oracle_stats, true, |db| {
            db.execute_batch("VACUUM main;VACUUM stats")
                .map_err(|e| e.to_string())?;
            Ok(())
        })
        .unwrap();
        let mut upper = 15960.0;
        let tail = expected.storage_combined(&oracle_stats).unwrap();
        while expected.storage_combined(&oracle_stats).unwrap()["combinedBytes"]
            .as_u64()
            .unwrap()
            > cap
        {
            expected
                .delete_together(&oracle_stats, upper, upper + 60.0)
                .unwrap();
            upper += 60.0;
            attached(&mut expected.db, &oracle_stats, true, |db| {
                db.execute_batch("VACUUM main;VACUUM stats")
                    .map_err(|e| e.to_string())?;
                Ok(())
            })
            .unwrap();
            assert!(upper < 18600.0, "Fixture cap cannot retain any new data");
        }
        let retained = expected.storage_combined(&oracle_stats).unwrap();
        eprintln!("retention tail oracle: before={tail}, fitting={retained}");
        assert!(retained["textRecordCount"].as_u64().unwrap() > 0);
        let result = archive.retention_together(&stats, cap).unwrap();
        assert_eq!(result["limitMet"], true);
        assert!(
            result["textRecordCount"].as_u64().unwrap()
                >= retained["textRecordCount"].as_u64().unwrap(),
            "must not discard newest tail that fits: {result}"
        );
    }
    #[test]
    fn either_database_failure_rolls_back_both_journals_and_records() {
        let f = Fixture::new();
        let (mut archive, _engine, stats) = populate(&f);
        let db = Connection::open(&stats).unwrap();
        let stats_revision = integer(&db, "SELECT revision FROM sync_state").unwrap();
        let text_revision = integer(&archive.db, "SELECT revision FROM text_state").unwrap();
        for text_failure in [false, true] {
            let target = if text_failure { &archive.db } else { &db };
            let table = if text_failure {
                "text_records"
            } else {
                "minutes"
            };
            target.execute_batch(&format!("CREATE TRIGGER fail_retention BEFORE DELETE ON {table} BEGIN SELECT RAISE(ABORT,'fixture');END")).unwrap();
            assert!(archive.retention_together(&stats, 2 * 1024 * 1024).is_err());
            assert_eq!(integer(&db, "SELECT COUNT(*) FROM minutes").unwrap(), 300);
            assert_eq!(
                integer(&archive.db, "SELECT COUNT(*) FROM text_records").unwrap(),
                300
            );
            assert_eq!(
                integer(&db, "SELECT revision FROM sync_state").unwrap(),
                stats_revision
            );
            assert_eq!(
                integer(&archive.db, "SELECT revision FROM text_state").unwrap(),
                text_revision
            );
            (if text_failure { &archive.db } else { &db })
                .execute_batch("DROP TRIGGER fail_retention")
                .unwrap();
        }
    }
    #[test]
    fn retained_metadata_can_prevent_cap_and_unsupported_journal_is_rejected() {
        let f = Fixture::new();
        let (mut archive, _engine, stats) = populate(&f);
        archive.db.execute_batch("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<20000) INSERT INTO text_journal(id,revision,deleted,record) SELECT printf('00000000-0000-4000-8000-%012x',x),100000+x,1,NULL FROM n").unwrap();
        let result = archive.retention_together(&stats, 1048576).unwrap();
        assert_eq!(result["limitMet"], false);
        assert!(
            integer(
                &archive.db,
                "SELECT COUNT(*) FROM text_journal WHERE deleted=1"
            )
            .unwrap()
                >= 20000
        );
        let db = Connection::open(&stats).unwrap();
        db.execute_batch("PRAGMA journal_mode=WAL").unwrap();
        assert!(archive.retention_together(&stats, 1048576).is_err());
    }
    #[test]
    fn explicit_range_and_clear_are_atomic_half_open_and_keep_journals() {
        let f = Fixture::new();
        let (mut archive, mut engine, stats) = populate(&f);
        let db = Connection::open(&stats).unwrap();
        let key_check: String = archive
            .db
            .query_row("SELECT key_check FROM text_state", [], |r| r.get(0))
            .unwrap();
        let original_text_revision =
            integer(&archive.db, "SELECT revision FROM text_state").unwrap();
        let result = archive.delete_together(&stats, 600.0, 660.0).unwrap();
        assert_eq!(result["deletedStatisticsMinutes"], 1);
        assert_eq!(result["deletedTextRecords"], 1);
        assert_eq!(
            archive.query(json!({"start":600,"end":660})).unwrap()["total"],
            0
        );
        assert_eq!(
            archive.query(json!({"start":660,"end":720})).unwrap()["total"],
            1
        );
        assert_eq!(
            integer(&db, "SELECT COUNT(*) FROM key_histograms").unwrap(),
            299
        );
        assert_eq!(
            integer(&db, "SELECT COUNT(*) FROM rhythm_minutes").unwrap(),
            299
        );
        engine.request(r#"{"op":"advance","time":19000}"#).unwrap();
        assert_eq!(
            engine
                .request(r#"{"op":"summary","start":600,"end":660}"#)
                .unwrap()["keyPresses"],
            0
        );
        assert_eq!(
            archive.delete_together(&stats, 600.0, 660.0).unwrap()["deletedTextRecords"],
            0
        );
        for (start, end) in [
            (600.1, 660.0),
            (600.0, 659.0),
            (660.0, 600.0),
            (600.0, 600.0),
            (-60.0, 0.0),
            (0.0, f64::INFINITY),
        ] {
            assert!(archive.delete_together(&stats, start, end).is_err());
        }
        let cleared = archive.clear_together(&stats).unwrap();
        assert_eq!(cleared["deletedStatisticsMinutes"], 299);
        assert_eq!(cleared["deletedTextRecords"], 299);
        assert_eq!(
            integer(&db, "SELECT COUNT(*) FROM sync_journal WHERE deleted=1").unwrap(),
            300
        );
        assert_eq!(
            integer(
                &archive.db,
                "SELECT COUNT(*) FROM text_journal WHERE deleted=1"
            )
            .unwrap(),
            300
        );
        assert!(
            integer(&archive.db, "SELECT revision FROM text_state").unwrap()
                > original_text_revision
        );
        assert_eq!(
            archive
                .db
                .query_row("SELECT key_check FROM text_state", [], |r| r
                    .get::<_, String>(0))
                .unwrap(),
            key_check
        );
        assert_eq!(
            archive.clear_together(&stats).unwrap()["deletedStatisticsMinutes"],
            0
        );
    }
    #[test]
    fn explicit_delete_and_clear_rollback_either_database_failure() {
        let f = Fixture::new();
        let (mut archive, _engine, stats) = populate(&f);
        let db = Connection::open(&stats).unwrap();
        let stats_revision = integer(&db, "SELECT revision FROM sync_state").unwrap();
        let text_revision = integer(&archive.db, "SELECT revision FROM text_state").unwrap();
        for text_failure in [false, true] {
            let target = if text_failure { &archive.db } else { &db };
            let table = if text_failure {
                "text_records"
            } else {
                "minutes"
            };
            target.execute_batch(&format!("CREATE TRIGGER fail_manual BEFORE DELETE ON {table} BEGIN SELECT RAISE(ABORT,'fixture');END")).unwrap();
            assert!(archive.delete_together(&stats, 600.0, 660.0).is_err());
            assert!(archive.clear_together(&stats).is_err());
            assert_eq!(integer(&db, "SELECT COUNT(*) FROM minutes").unwrap(), 300);
            assert_eq!(
                integer(&archive.db, "SELECT COUNT(*) FROM text_records").unwrap(),
                300
            );
            assert_eq!(
                integer(&db, "SELECT revision FROM sync_state").unwrap(),
                stats_revision
            );
            assert_eq!(
                integer(&archive.db, "SELECT revision FROM text_state").unwrap(),
                text_revision
            );
            (if text_failure { &archive.db } else { &db })
                .execute_batch("DROP TRIGGER fail_manual")
                .unwrap();
        }
    }
}
