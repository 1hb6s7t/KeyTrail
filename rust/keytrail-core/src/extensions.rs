//! Additive aggregate-only rhythm, storage, and replication support.
use super::*;
use rusqlite::OptionalExtension;
const MAX_MASK: u64 = (1_u64 << 60) - 1;
const MAX_INTEGER: i64 = 9_007_199_254_740_991;

#[derive(Clone, Default)]
pub(super) struct RhythmState {
    last: Option<f64>,
    burst: i64,
}
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct RhythmAggregate {
    interval_count: i64,
    interval_sum_ms: f64,
    burst_peak: i64,
    burst_peak_at: Option<i64>,
    measured_minutes: i64,
}
impl RhythmState {
    pub(super) fn key(&mut self, time: f64, delta: &mut Option<RhythmAggregate>) {
        let value = delta.get_or_insert_with(RhythmAggregate::default);
        value.measured_minutes = 1;
        if let Some(previous) = self.last {
            let milliseconds = (time - previous) * 1000.0;
            // Do not recover ordering from a batch. Equal/backward samples sever continuity.
            if milliseconds <= 0.0 {
                self.last = None;
                self.burst = 0;
                return;
            }
            // Unix floating-point timestamps can differ by ~0.0002 ms at current dates.
            if (30.0 - 0.001..=2000.0 + 0.001).contains(&milliseconds) {
                value.interval_count += 1;
                value.interval_sum_ms += milliseconds.clamp(30.0, 2000.0);
            }
            self.burst = if milliseconds <= 750.0 + 0.001 {
                self.burst + 1
            } else {
                1
            };
        } else {
            self.burst = 1;
        }
        self.last = Some(time);
        if self.burst > value.burst_peak {
            value.burst_peak = self.burst;
            value.burst_peak_at = Some(minute(time));
        }
    }
    pub(super) fn clear(&mut self) {
        *self = Self::default();
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct MinuteRecord {
    keys: i64,
    left_clicks: i64,
    right_clicks: i64,
    middle_clicks: i64,
    distance: f64,
    scroll: f64,
    keyboard_mask: String,
    mouse_mask: String,
    key_counts: BTreeMap<String, i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rhythm: Option<RhythmAggregate>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Change {
    revision: i64,
    minute: i64,
    deleted: bool,
    record: Option<MinuteRecord>,
}

pub(super) fn initialize(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS rhythm_minutes(minute INTEGER PRIMARY KEY REFERENCES minutes(minute) ON DELETE CASCADE,interval_count INTEGER NOT NULL,interval_sum_ms REAL NOT NULL,burst_peak INTEGER NOT NULL,burst_peak_at INTEGER,measured_minutes INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_journal(minute INTEGER PRIMARY KEY,revision INTEGER NOT NULL UNIQUE,deleted INTEGER NOT NULL,record TEXT);
        CREATE TABLE IF NOT EXISTS replica_versions(minute INTEGER PRIMARY KEY,revision INTEGER NOT NULL);")?;
    let initialized: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sync_state WHERE id=1)",
        [],
        |r| r.get(0),
    )?;
    if !initialized {
        db.execute("INSERT INTO sync_state VALUES(1,0)", [])?;
        let mut stmt = db.prepare("SELECT minute FROM minutes ORDER BY minute")?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            journal(db, row.get(0)?, false)?;
        }
    }
    Ok(())
}
pub(super) fn write_rhythm(db: &Connection, m: i64, value: &RhythmAggregate) -> Result<()> {
    db.execute("INSERT INTO rhythm_minutes VALUES(?,?,?,?,?,?) ON CONFLICT(minute) DO UPDATE SET interval_count=interval_count+excluded.interval_count,interval_sum_ms=interval_sum_ms+excluded.interval_sum_ms,burst_peak_at=CASE WHEN excluded.burst_peak>burst_peak THEN excluded.burst_peak_at ELSE burst_peak_at END,burst_peak=MAX(burst_peak,excluded.burst_peak),measured_minutes=1",params![m,value.interval_count,value.interval_sum_ms,value.burst_peak,value.burst_peak_at,value.measured_minutes])?;
    Ok(())
}
fn read_rhythm(db: &Connection, m: i64) -> Result<Option<RhythmAggregate>> {
    Ok(db.query_row("SELECT interval_count,interval_sum_ms,burst_peak,burst_peak_at,measured_minutes FROM rhythm_minutes WHERE minute=?",[m],|r|Ok(RhythmAggregate{interval_count:r.get(0)?,interval_sum_ms:r.get(1)?,burst_peak:r.get(2)?,burst_peak_at:r.get(3)?,measured_minutes:r.get(4)?})).optional()?)
}
fn read_record(db: &Connection, m: i64) -> Result<MinuteRecord> {
    let mut record=db.query_row("SELECT keys,left_clicks,right_clicks,middle_clicks,distance,scroll,keyboard_mask,mouse_mask FROM minutes WHERE minute=?",[m],|r|Ok(MinuteRecord{keys:r.get(0)?,left_clicks:r.get(1)?,right_clicks:r.get(2)?,middle_clicks:r.get(3)?,distance:r.get(4)?,scroll:r.get(5)?,keyboard_mask:r.get::<_,i64>(6)?.to_string(),mouse_mask:r.get::<_,i64>(7)?.to_string(),key_counts:BTreeMap::new(),rhythm:None}))?;
    let mut stmt = db.prepare_cached("SELECT label,count FROM key_histograms WHERE minute=?")?;
    for row in stmt.query_map([m], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))? {
        let (label, count) = row?;
        record.key_counts.insert(label, count);
    }
    record.rhythm = read_rhythm(db, m)?;
    Ok(record)
}
// Coalesce by minute while assigning a fresh durable global revision every time.
// No history of intermediate key histograms is retained to reconstruct input order.
pub(super) fn journal(db: &Connection, m: i64, deleted: bool) -> Result<()> {
    let record = if deleted {
        None
    } else {
        {
            let value = read_record(db, m)?;
            validate_change(&Change {
                revision: 1,
                minute: m,
                deleted: false,
                record: Some(value.clone()),
            })?;
            Some(serde_json::to_string(&value)?)
        }
    };
    let previous: i64 = db.query_row("SELECT revision FROM sync_state WHERE id=1", [], |r| {
        r.get(0)
    })?;
    if previous >= MAX_INTEGER {
        return Err("sync revision exhausted".into());
    }
    let revision = previous + 1;
    db.execute("UPDATE sync_state SET revision=? WHERE id=1", [revision])?;
    db.execute("INSERT INTO sync_journal(minute,revision,deleted,record)VALUES(?,?,?,?) ON CONFLICT(minute) DO UPDATE SET revision=excluded.revision,deleted=excluded.deleted,record=excluded.record",params![m,revision,deleted,record])?;
    Ok(())
}
pub(super) fn journal_deletions(db: &Connection, lower: f64, upper: f64) -> Result<()> {
    let mut stmt =
        db.prepare("SELECT minute FROM minutes WHERE minute>=? AND minute<? ORDER BY minute")?;
    let mut rows = stmt.query(params![lower, upper])?;
    while let Some(row) = rows.next()? {
        journal(db, row.get(0)?, true)?;
    }
    Ok(())
}
fn mask(value: &str) -> Result<i64> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err("activity masks must be decimal strings".into());
    }
    let parsed: u64 = value.parse()?;
    if parsed > MAX_MASK {
        return Err("activity mask exceeds 60 bits".into());
    }
    Ok(parsed as i64)
}
fn count(value: i64) -> Result<()> {
    if !(0..=MAX_INTEGER).contains(&value) {
        Err("aggregate count out of range".into())
    } else {
        Ok(())
    }
}
fn validate_change(change: &Change) -> Result<()> {
    if !(1..=MAX_INTEGER).contains(&change.revision)
        || change.minute < 0
        || change.minute >= 1_000_000_000_000
        || change.minute % 60 != 0
    {
        return Err("invalid revision or UTC minute".into());
    }
    if change.deleted {
        if change.record.is_some() {
            return Err("deletion must not contain a record".into());
        }
        return Ok(());
    }
    let r = change.record.as_ref().ok_or("update requires a record")?;
    for value in [r.keys, r.left_clicks, r.right_clicks, r.middle_clicks] {
        count(value)?;
    }
    if !r.distance.is_finite() || r.distance < 0.0 || !r.scroll.is_finite() || r.scroll < 0.0 {
        return Err("invalid distance or scroll aggregate".into());
    }
    mask(&r.keyboard_mask)?;
    mask(&r.mouse_mask)?;
    let mut keys = 0_i64;
    for (label, value) in &r.key_counts {
        if label != &physical_label(Some(label)) {
            return Err("nonphysical key label rejected".into());
        }
        count(*value)?;
        keys = keys.checked_add(*value).ok_or("histogram overflow")?;
    }
    if keys != r.keys {
        return Err("key count and histogram disagree".into());
    }
    if let Some(rhythm) = &r.rhythm {
        count(rhythm.interval_count)?;
        count(rhythm.burst_peak)?;
        if !(0..=1).contains(&rhythm.measured_minutes)
            || !rhythm.interval_sum_ms.is_finite()
            || rhythm.interval_sum_ms < 30.0 * rhythm.interval_count as f64 - 0.01
            || rhythm.interval_sum_ms > 2000.0 * rhythm.interval_count as f64 + 0.01
            || (rhythm.interval_count == 0 && rhythm.interval_sum_ms != 0.0)
        {
            return Err("invalid rhythm interval aggregate".into());
        }
        if (rhythm.burst_peak == 0 && rhythm.burst_peak_at.is_some())
            || (rhythm.burst_peak > 0 && rhythm.burst_peak_at != Some(change.minute))
        {
            return Err("burst endpoint must be its aggregate minute".into());
        }
        if rhythm.measured_minutes == 0 && (rhythm.interval_count > 0 || rhythm.burst_peak > 0) {
            return Err("unmeasured rhythm has evidence".into());
        }
    }
    Ok(())
}
impl Store {
    pub(super) fn insights(&self, start: f64, end: f64) -> Result<Value> {
        bounds(start, end)?;
        let mut intervals = 0_i64;
        let mut sum = 0.0;
        let mut peak = 0;
        let mut at = None;
        let mut measured = 0;
        if end > start {
            let mut stmt=self.db.prepare_cached("SELECT interval_count,interval_sum_ms,burst_peak,burst_peak_at,measured_minutes FROM rhythm_minutes WHERE minute>=? AND minute<? ORDER BY minute")?;
            let mut rows = stmt.query(params![minute(start), end])?;
            while let Some(row) = rows.next()? {
                intervals = intervals
                    .checked_add(row.get::<_, i64>(0)?)
                    .ok_or("rhythm count overflow")?;
                sum += row.get::<_, f64>(1)?;
                if !sum.is_finite() {
                    return Err("rhythm sum overflow".into());
                }
                measured += row.get::<_, i64>(4)?;
                let candidate: i64 = row.get(2)?;
                let endpoint: Option<i64> = row.get(3)?;
                if candidate > peak
                    && endpoint.is_some_and(|time| time as f64 >= start && (time as f64) < end)
                {
                    peak = candidate;
                    at = endpoint;
                }
            }
        }
        let bpm = if intervals > 0 {
            Some(60000.0 * intervals as f64 / sum)
        } else {
            None
        };
        Ok(
            json!({"intervalCount":intervals,"intervalSumMs":sum,"bpm":bpm,"burstPeak":peak,"burstPeakAt":at,"measuredMinutes":measured}),
        )
    }
    fn database_bytes(&self) -> Result<u64> {
        let pages: u64 = self.db.query_row("PRAGMA page_count", [], |r| r.get(0))?;
        let size: u64 = self.db.query_row("PRAGMA page_size", [], |r| r.get(0))?;
        Ok(pages.checked_mul(size).ok_or("database size overflow")?)
    }
    pub(super) fn storage_info(&self) -> Result<Value> {
        let (count, oldest, newest): (i64, Option<i64>, Option<i64>) = self.db.query_row(
            "SELECT COUNT(*),MIN(minute),MAX(minute) FROM minutes",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
        Ok(
            json!({"databaseBytes":self.database_bytes()?,"minuteCount":count,"oldestMinute":oldest,"newestMinute":newest}),
        )
    }
    pub(super) fn retention(&mut self, max_bytes: u64) -> Result<Value> {
        if max_bytes < 1024 * 1024 {
            return Err("storage cap must be at least 1 MiB".into());
        }
        let mut deleted = 0_usize;
        if self.database_bytes()? > max_bytes {
            self.db.execute_batch("VACUUM")?;
        }
        while self.database_bytes()? > max_bytes {
            let mut minutes: Vec<i64> = {
                let mut stmt = self
                    .db
                    .prepare("SELECT minute FROM minutes ORDER BY minute LIMIT 257")?;
                let values = stmt
                    .query_map([], |r| r.get(0))?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                values
            };
            if minutes.is_empty() {
                break;
            }
            // Look ahead by one row to distinguish a full bulk batch from the
            // final <=256 minutes. Recheck compacted bytes after each tail minute
            // so a small overage cannot erase a newer suffix that would fit.
            minutes.truncate(if minutes.len() <= 256 { 1 } else { 256 });
            let tx = self
                .db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            for m in &minutes {
                journal(&tx, *m, true)?;
                tx.execute("DELETE FROM minutes WHERE minute=?", [m])?;
            }
            tx.commit()?;
            // Changes are durable before compaction; never resurrect removed pending masks.
            let lower = *minutes.first().unwrap() as f64;
            let upper = *minutes.last().unwrap() as f64 + 60.0;
            self.keyboard = subtract(&self.keyboard, lower, upper);
            self.mouse = subtract(&self.mouse, lower, upper);
            self.rhythm.clear();
            deleted += minutes.len();
            self.db.execute_batch("VACUUM")?;
        }
        let bytes = self.database_bytes()?;
        Ok(json!({"deletedMinutes":deleted,"databaseBytes":bytes,"limitMet":bytes<=max_bytes}))
    }
    pub(super) fn sync_changes(&self, after: i64, limit: usize) -> Result<Value> {
        if !(0..=MAX_INTEGER).contains(&after) || !(1..=1000).contains(&limit) {
            return Err("invalid sync cursor or page limit".into());
        }
        let mut stmt=self.db.prepare_cached("SELECT revision,minute,deleted,record FROM sync_journal WHERE revision>? ORDER BY revision LIMIT ?")?;
        let mut rows = stmt.query(params![after, limit + 1])?;
        let mut changes = vec![];
        // Leave room for the page envelope/cursor and separators in a 1 MiB reply.
        let mut encoded_bytes = 4096usize;
        let mut more = false;
        while let Some(row) = rows.next()? {
            if changes.len() == limit {
                more = true;
                break;
            }
            let record: Option<String> = row.get(3)?;
            let change = Change {
                revision: row.get(0)?,
                minute: row.get(1)?,
                deleted: row.get(2)?,
                record: record.map(|s| serde_json::from_str(&s)).transpose()?,
            };
            let size = serde_json::to_vec(&change)?.len() + 1;
            if encoded_bytes + size > 1024 * 1024 {
                if changes.is_empty() {
                    return Err("individual sync record exceeds 1 MiB budget".into());
                }
                more = true;
                break;
            }
            encoded_bytes += size;
            changes.push(change);
        }
        let cursor = changes.last().map_or(after, |c| c.revision);
        Ok(json!({"changes":changes,"cursor":cursor,"hasMore":more}))
    }
    pub(super) fn replica_apply(&mut self, changes: Vec<Change>) -> Result<Value> {
        if changes.len() > 1000 {
            return Err("replication batch exceeds 1000 changes".into());
        }
        for change in &changes {
            validate_change(change)?;
        }
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let mut applied = 0;
        let mut ignored = 0;
        for change in changes {
            let previous: Option<i64> = tx
                .query_row(
                    "SELECT revision FROM replica_versions WHERE minute=?",
                    [change.minute],
                    |r| r.get(0),
                )
                .optional()?;
            if previous.is_some_and(|v| v >= change.revision) {
                ignored += 1;
                continue;
            }
            tx.execute("DELETE FROM minutes WHERE minute=?", [change.minute])?;
            if let Some(r) = change.record {
                tx.execute(
                    "INSERT INTO minutes VALUES(?,?,?,?,?,?,?,?,?)",
                    params![
                        change.minute,
                        r.keys,
                        r.left_clicks,
                        r.right_clicks,
                        r.middle_clicks,
                        r.distance,
                        r.scroll,
                        mask(&r.keyboard_mask)?,
                        mask(&r.mouse_mask)?
                    ],
                )?;
                for (label, count) in r.key_counts {
                    tx.execute(
                        "INSERT INTO key_histograms VALUES(?,?,?)",
                        params![change.minute, label, count],
                    )?;
                }
                if let Some(rhythm) = r.rhythm {
                    write_rhythm(&tx, change.minute, &rhythm)?;
                }
            }
            tx.execute("INSERT INTO replica_versions VALUES(?,?) ON CONFLICT(minute) DO UPDATE SET revision=excluded.revision",params![change.minute,change.revision])?;
            applied += 1;
        }
        tx.commit()?;
        // Replicas are server-side stores. Remote state never continues a local input window.
        self.keyboard.clear();
        self.mouse.clear();
        self.rhythm.clear();
        Ok(json!({"applied":applied,"ignored":ignored}))
    }
}
