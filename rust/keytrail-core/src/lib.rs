//! KeyTrail's single-caller aggregate store. No ordered input or coordinates are persisted.
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::{
    collections::BTreeMap,
    ffi::{CStr, CString},
    os::raw::{c_char, c_void},
    panic::{catch_unwind, AssertUnwindSafe},
    path::Path,
    time::Duration,
};

/// A single-caller safe Rust API. It owns SQLite and all transient input state.
/// Private servers must allowlist read-only viewer operations outside this API.
pub struct Engine {
    store: Store,
}
impl Engine {
    pub fn open(path: &str) -> std::result::Result<Self, String> {
        boundary(|| {
            Ok(Self {
                store: Store::open(path)?,
            })
        })
    }
    pub fn request(&mut self, input: &str) -> std::result::Result<Value, String> {
        boundary(|| self.store.request(input))
    }
}

mod export_pages;
mod extensions;
use extensions::{RhythmAggregate, RhythmState};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Kind {
    KeyPress,
    MouseMove,
    LeftClick,
    RightClick,
    MiddleClick,
    Scroll,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Sample {
    timestamp: f64,
    kind: Kind,
    key_label: Option<String>,
    #[serde(default)]
    distance_points: f64,
    #[serde(default)]
    scroll_delta: f64,
}
#[derive(Default, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Summary {
    key_presses: i64,
    left_clicks: i64,
    right_clicks: i64,
    middle_clicks: i64,
    mouse_distance_points: f64,
    scroll_units: f64,
    keyboard_active_seconds: u64,
    mouse_active_seconds: u64,
    total_active_seconds: u64,
    key_counts: BTreeMap<String, i64>,
    minute_count: u64,
    peak_keys_per_minute: i64,
}
impl Summary {
    fn add(&mut self, rhs: Self) -> Result<()> {
        macro_rules! add { ($($field:ident),*) => { $(self.$field=self.$field.checked_add(rhs.$field).ok_or("aggregate integer overflow")?;)* }; }
        add!(
            key_presses,
            left_clicks,
            right_clicks,
            middle_clicks,
            keyboard_active_seconds,
            mouse_active_seconds,
            total_active_seconds,
            minute_count
        );
        self.mouse_distance_points += rhs.mouse_distance_points;
        self.scroll_units += rhs.scroll_units;
        if !self.mouse_distance_points.is_finite() || !self.scroll_units.is_finite() {
            return Err("aggregate floating-point overflow".into());
        }
        self.peak_keys_per_minute = self.peak_keys_per_minute.max(rhs.peak_keys_per_minute);
        for (label, count) in rhs.key_counts {
            let value = self.key_counts.entry(label).or_default();
            *value = value.checked_add(count).ok_or("histogram overflow")?;
        }
        Ok(())
    }
}
#[derive(Serialize)]
struct Bucket {
    start: f64,
    summary: Summary,
}
#[derive(Clone, Copy)]
struct Window {
    start: f64,
    end: f64,
}
#[derive(Default)]
struct Delta {
    keys: i64,
    left: i64,
    right: i64,
    middle: i64,
    distance: f64,
    scroll: f64,
    keyboard: u64,
    mouse: u64,
    hist: BTreeMap<String, i64>,
    rhythm: Option<RhythmAggregate>,
}
struct Store {
    db: Connection,
    keyboard: Vec<Window>,
    mouse: Vec<Window>,
    observed: Option<f64>,
    rhythm: RhythmState,
    export_totals: Option<export_pages::Totals>,
}
impl Store {
    fn open(path: &str) -> Result<Self> {
        if path != ":memory:" {
            if let Some(parent) = Path::new(path)
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
            {
                let mut builder = std::fs::DirBuilder::new();
                builder.recursive(true);
                #[cfg(unix)]
                builder.mode(0o700);
                builder.create(parent)?;
            }
        }
        let mut db = Connection::open(path)?;
        if path != ":memory:" {
            #[cfg(unix)]
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        }
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version != 0 && version != 1 {
            return Err("数据库版本不受支持。".into());
        }
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS minutes (minute INTEGER PRIMARY KEY, keys INTEGER NOT NULL DEFAULT 0, left_clicks INTEGER NOT NULL DEFAULT 0, right_clicks INTEGER NOT NULL DEFAULT 0, middle_clicks INTEGER NOT NULL DEFAULT 0, distance REAL NOT NULL DEFAULT 0, scroll REAL NOT NULL DEFAULT 0, keyboard_mask INTEGER NOT NULL DEFAULT 0, mouse_mask INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS key_histograms (minute INTEGER NOT NULL REFERENCES minutes(minute) ON DELETE CASCADE, label TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(minute,label)) WITHOUT ROWID; PRAGMA user_version=1;")?;
        extensions::initialize(&tx)?;
        export_pages::initialize(&tx)?;
        tx.commit()?;
        Ok(Self {
            db,
            keyboard: vec![],
            mouse: vec![],
            observed: None,
            rhythm: RhythmState::default(),
            export_totals: None,
        })
    }
    fn observation(&self, time: f64) -> Result<()> {
        valid_time(time)?;
        if self.observed.is_some_and(|previous| time < previous) {
            return Err("观察时间不得倒退；系统时间改变后请重新启动采集。".into());
        }
        Ok(())
    }
    fn ingest(&mut self, samples: Vec<Sample>, now: f64) -> Result<()> {
        self.observation(now)?;
        let mut deltas: BTreeMap<i64, Delta> = BTreeMap::new();
        let mut keyboard = self.keyboard.clone();
        let mut mouse = self.mouse.clone();
        let mut rhythm = self.rhythm.clone();
        for sample in samples {
            valid_time(sample.timestamp)?;
            if sample.timestamp > now
                || !sample.distance_points.is_finite()
                || sample.distance_points < 0.0
                || !sample.scroll_delta.is_finite()
            {
                return Err("输入样本包含未来时间或无效数值。".into());
            }
            let delta = deltas.entry(minute(sample.timestamp)).or_default();
            let window = Window {
                start: sample.timestamp,
                end: sample.timestamp + 30.0,
            };
            match sample.kind {
                Kind::KeyPress => {
                    delta.keys += 1;
                    rhythm.key(sample.timestamp, &mut delta.rhythm);
                    *delta
                        .hist
                        .entry(physical_label(sample.key_label.as_deref()))
                        .or_default() += 1;
                    keyboard.push(window);
                }
                kind => {
                    mouse.push(window);
                    match kind {
                        Kind::LeftClick => delta.left += 1,
                        Kind::RightClick => delta.right += 1,
                        Kind::MiddleClick => delta.middle += 1,
                        Kind::MouseMove => delta.distance += sample.distance_points,
                        Kind::Scroll => delta.scroll += sample.scroll_delta.abs(),
                        _ => unreachable!(),
                    }
                }
            }
            if !delta.distance.is_finite() || !delta.scroll.is_finite() {
                return Err("输入累计数值溢出。".into());
            }
        }
        keyboard = merged(keyboard);
        mouse = merged(mouse);
        add_activity(&mut deltas, &keyboard, now, true);
        add_activity(&mut deltas, &mouse, now, false);
        // Transaction and in-memory state commit together. A failed write leaves pending windows intact.
        if !deltas.is_empty() {
            let tx = self
                .db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            {
                let mut counters = tx.prepare_cached("INSERT INTO minutes(minute,keys,left_clicks,right_clicks,middle_clicks,distance,scroll,keyboard_mask,mouse_mask) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(minute) DO UPDATE SET keys=keys+excluded.keys,left_clicks=left_clicks+excluded.left_clicks,right_clicks=right_clicks+excluded.right_clicks,middle_clicks=middle_clicks+excluded.middle_clicks,distance=distance+excluded.distance,scroll=scroll+excluded.scroll,keyboard_mask=keyboard_mask|excluded.keyboard_mask,mouse_mask=mouse_mask|excluded.mouse_mask")?;
                let mut hist = tx.prepare_cached("INSERT INTO key_histograms(minute,label,count) VALUES(?,?,?) ON CONFLICT(minute,label) DO UPDATE SET count=count+excluded.count")?;
                for (start, delta) in deltas {
                    counters.execute(params![
                        start,
                        delta.keys,
                        delta.left,
                        delta.right,
                        delta.middle,
                        delta.distance,
                        delta.scroll,
                        delta.keyboard as i64,
                        delta.mouse as i64
                    ])?;
                    for (label, count) in delta.hist {
                        hist.execute(params![start, label, count])?;
                    }
                    if let Some(value) = delta.rhythm {
                        extensions::write_rhythm(&tx, start, &value)?;
                    }
                    extensions::journal(&tx, start, false)?;
                }
            }
            tx.commit()?;
        }
        self.keyboard = remainder(keyboard, now);
        self.mouse = remainder(mouse, now);
        self.observed = Some(now);
        self.rhythm = rhythm;
        Ok(())
    }
    fn advance(&mut self, now: f64, end: bool) -> Result<()> {
        self.ingest(vec![], now)?;
        if end {
            self.keyboard.clear();
            self.mouse.clear();
            self.rhythm.clear();
        }
        Ok(())
    }
    fn read_minute_rows(
        &self,
        start: f64,
        end: f64,
        mut visit: impl FnMut(&rusqlite::Row<'_>) -> Result<()>,
    ) -> Result<()> {
        bounds(start, end)?;
        if start == end {
            return Ok(());
        }
        let mut stmt = self.db.prepare_cached("SELECT minute,keys,left_clicks,right_clicks,middle_clicks,distance,scroll,keyboard_mask,mouse_mask FROM minutes WHERE minute>=? AND minute<? ORDER BY minute")?;
        let mut rows = stmt.query(params![minute(start), end])?;
        while let Some(row) = rows.next()? {
            visit(row)?;
        }
        Ok(())
    }
    fn read_minutes(
        &self,
        start: f64,
        end: f64,
        mut visit: impl FnMut(i64, Summary) -> Result<()>,
    ) -> Result<()> {
        self.read_minute_rows(start, end, |row| {
            visit(row.get(0)?, minute_summary(row, start, end)?)
        })
    }
    fn timeline(&self, ranges: &[AggregationRange]) -> Result<Vec<Bucket>> {
        self.ranged_summaries(ranges, RangeLimits::TIMELINE)
    }
    fn summaries(&self, ranges: &[AggregationRange]) -> Result<Vec<Bucket>> {
        self.ranged_summaries(ranges, RangeLimits::SUMMARIES)
    }
    fn trend(&self, ranges: &[AggregationRange]) -> Result<Vec<Bucket>> {
        self.ranged_summaries(ranges, RangeLimits::TREND)
    }
    fn ranged_summaries(
        &self,
        ranges: &[AggregationRange],
        limits: RangeLimits,
    ) -> Result<Vec<Bucket>> {
        validate_ranges(ranges, limits)?;
        let mut output: Vec<Bucket> = ranges
            .iter()
            .map(|range| Bucket {
                start: range.start,
                summary: Summary::default(),
            })
            .collect();
        let Some(first) = ranges.first() else {
            return Ok(output);
        };
        let mut index = 0;
        // One ordered minute cursor and one monotonically advancing range cursor.
        // No histogram query and no per-cell SQL; gaps remain deliberately empty.
        self.read_minute_rows(first.start, ranges.last().unwrap().end, |row| {
            let time = row.get::<_, i64>(0)? as f64;
            while index < ranges.len() && time >= ranges[index].end {
                index += 1;
            }
            if let Some(range) = ranges.get(index) {
                if time >= range.start {
                    output[index]
                        .summary
                        .add(minute_summary(row, range.start, range.end)?)?;
                }
            }
            Ok(())
        })?;
        Ok(output)
    }
    fn summary(&self, start: f64, end: f64) -> Result<Summary> {
        let mut result = Summary::default();
        self.read_minutes(start, end, |_, s| {
            result.add(s)?;
            Ok(())
        })?;
        if end > start {
            let mut stmt = self.db.prepare_cached("SELECT label,SUM(count) FROM key_histograms WHERE minute>=? AND minute<? GROUP BY label")?;
            let mut rows = stmt.query(params![minute(start), end])?;
            while let Some(row) = rows.next()? {
                result.key_counts.insert(row.get(0)?, row.get(1)?);
            }
        }
        Ok(result)
    }
    fn buckets(&self, start: f64, end: f64, step: i64, include_hist: bool) -> Result<Vec<Bucket>> {
        if step < 60 || step % 60 != 0 {
            return Err("stepSeconds must be a positive minute multiple".into());
        }
        // Use natural minutes at the default precision. Coarser buckets anchor to the requested start.
        let anchor = if step == 60 {
            minute(start) as f64
        } else {
            start
        };
        let index = |m: i64| ((m as f64 - anchor) / step as f64).floor() as i64;
        let mut result = BTreeMap::<i64, Summary>::new();
        self.read_minutes(start, end, |m, s| {
            result.entry(index(m)).or_default().add(s)?;
            Ok(())
        })?;
        if include_hist && end > start {
            let mut stmt = self.db.prepare_cached("SELECT minute,label,count FROM key_histograms WHERE minute>=? AND minute<? ORDER BY minute,label")?;
            let mut rows = stmt.query(params![minute(start), end])?;
            while let Some(row) = rows.next()? {
                let m: i64 = row.get(0)?;
                let label: String = row.get(1)?;
                let count: i64 = row.get(2)?;
                if let Some(s) = result.get_mut(&index(m)) {
                    *s.key_counts.entry(label).or_default() += count;
                }
            }
        }
        Ok(result
            .into_iter()
            .map(|(idx, summary)| Bucket {
                start: anchor + idx as f64 * step as f64,
                summary,
            })
            .collect())
    }
    fn delete(&mut self, start: f64, end: f64) -> Result<()> {
        bounds(start, end)?;
        if end == start {
            return Ok(());
        }
        let lower = minute(start) as f64;
        let upper = (end / 60.0).ceil() * 60.0;
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        extensions::journal_deletions(&tx, lower, upper)?;
        tx.execute(
            "DELETE FROM minutes WHERE minute>=? AND minute<?",
            params![lower, upper],
        )?;
        tx.commit()?;
        self.keyboard = subtract(&self.keyboard, lower, upper);
        self.mouse = subtract(&self.mouse, lower, upper);
        self.rhythm.clear();
        Ok(())
    }
    fn clear(&mut self) -> Result<()> {
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        extensions::journal_deletions(&tx, -1e12, 1e12)?;
        tx.execute("DELETE FROM minutes", [])?;
        tx.commit()?;
        self.keyboard.clear();
        self.mouse.clear();
        self.rhythm.clear();
        Ok(())
    }
    fn export(&self, start: f64, end: f64) -> Result<String> {
        bounds(start, end)?;
        let mut csv = export_pages::header(start, end);
        use std::fmt::Write;
        // Two ordered cursors keep export working memory bounded by a single histogram.
        let mut hist_stmt = self.db.prepare_cached("SELECT minute,label,count FROM key_histograms WHERE minute>=? AND minute<? ORDER BY minute,label")?;
        let mut hist_rows = hist_stmt.query(params![minute(start), end])?;
        let mut next_hist: Option<(i64, String, i64)> = match hist_rows.next()? {
            Some(r) => Some((r.get(0)?, r.get(1)?, r.get(2)?)),
            None => None,
        };
        self.read_minutes(start, end, |m, s| {
            let mut histogram = Vec::new();
            let mut histogram_bytes = 0;
            while let Some((hm, label, count)) = &next_hist {
                if *hm > m {
                    break;
                }
                if *hm == m {
                    let item = format!("{label}:{count}");
                    histogram_bytes += item.len() + 1;
                    if histogram_bytes > 8 * 1024 * 1024 {
                        return Err("export exceeds 8 MiB; choose a smaller range".into());
                    }
                    histogram.push(item);
                }
                next_hist = match hist_rows.next()? {
                    Some(r) => Some((r.get(0)?, r.get(1)?, r.get(2)?)),
                    None => None,
                };
            }
            let hist = histogram.join(";").replace('"', "\"\"");
            write!(
                csv,
                "{},{},{},{},{},{},{},{},{},{},\"{}\"\r\n",
                iso8601(m as f64),
                s.key_presses,
                s.left_clicks,
                s.right_clicks,
                s.middle_clicks,
                s.mouse_distance_points,
                s.scroll_units,
                s.keyboard_active_seconds,
                s.mouse_active_seconds,
                s.total_active_seconds,
                hist
            )?;
            if csv.len() > 8 * 1024 * 1024 {
                return Err("export exceeds 8 MiB; choose a smaller range".into());
            }
            Ok(())
        })?;
        Ok(csv)
    }
    fn request(&mut self, input: &str) -> Result<Value> {
        let request: Request = serde_json::from_str(input)?;
        Ok(match request {
            Request::Insights { start, end } => self.insights(start, end)?,
            Request::StorageInfo => self.storage_info()?,
            Request::Retention { max_bytes } => self.retention(max_bytes)?,
            Request::SyncChanges { after, limit } => self.sync_changes(after, limit)?,
            Request::ReplicaApply { changes } => self.replica_apply(changes)?,
            Request::Ingest {
                samples,
                observed_through,
            } => {
                self.ingest(samples, observed_through)?;
                Value::Null
            }
            Request::Advance { time } => {
                self.advance(time, false)?;
                Value::Null
            }
            Request::End { time } => {
                self.advance(time, true)?;
                Value::Null
            }
            Request::Summaries { ranges } => serde_json::to_value(self.summaries(&ranges)?)?,
            Request::Trend { ranges } => serde_json::to_value(self.trend(&ranges)?)?,
            Request::Timeline { ranges } => serde_json::to_value(self.timeline(&ranges)?)?,
            Request::Summary { start, end } => serde_json::to_value(self.summary(start, end)?)?,
            Request::Buckets {
                start,
                end,
                step_seconds,
                include_key_counts,
            } => {
                serde_json::to_value(self.buckets(start, end, step_seconds, include_key_counts)?)?
            }
            Request::Delete { start, end } => {
                self.delete(start, end)?;
                Value::Null
            }
            Request::Clear => {
                self.clear()?;
                Value::Null
            }
            Request::ExportPage {
                start,
                end,
                cursor,
                limit,
            } => self.export_page(start, end, cursor, limit)?,
            Request::ExportValidate { snapshot } => {
                self.export_validate(&snapshot)?;
                Value::Null
            }
            Request::Export { start, end } => Value::String(self.export(start, end)?),
        })
    }
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", rename_all_fields = "camelCase")]
enum Request {
    Insights {
        start: f64,
        end: f64,
    },
    StorageInfo,
    Retention {
        max_bytes: u64,
    },
    SyncChanges {
        after: i64,
        limit: usize,
    },
    ReplicaApply {
        changes: Vec<extensions::Change>,
    },
    Summaries {
        ranges: Vec<AggregationRange>,
    },
    Trend {
        ranges: Vec<AggregationRange>,
    },
    Timeline {
        ranges: Vec<AggregationRange>,
    },
    Ingest {
        samples: Vec<Sample>,
        observed_through: f64,
    },
    Advance {
        time: f64,
    },
    End {
        time: f64,
    },
    Summary {
        start: f64,
        end: f64,
    },
    Buckets {
        start: f64,
        end: f64,
        #[serde(default = "default_step")]
        step_seconds: i64,
        #[serde(default = "default_true")]
        include_key_counts: bool,
    },
    Delete {
        start: f64,
        end: f64,
    },
    Clear,
    ExportPage {
        start: f64,
        end: f64,
        cursor: Option<export_pages::Cursor>,
        #[serde(default = "export_pages::default_limit")]
        limit: usize,
    },
    ExportValidate {
        snapshot: export_pages::Snapshot,
    },
    Export {
        start: f64,
        end: f64,
    },
}
#[derive(Clone, Copy, Deserialize)]
struct AggregationRange {
    start: f64,
    end: f64,
}

#[derive(Clone, Copy)]
struct RangeLimits {
    name: &'static str,
    count: usize,
    duration: f64,
    span: f64,
}
impl RangeLimits {
    const TIMELINE: Self = Self {
        name: "timeline",
        count: 200,
        duration: 7200.0,
        span: 8.0 * 86400.0,
    };
    const SUMMARIES: Self = Self {
        name: "summaries",
        count: 32,
        duration: 32.0 * 86400.0,
        span: 400.0 * 86400.0,
    };
    const TREND: Self = Self {
        name: "trend",
        count: 400,
        duration: 367.0 * 86400.0,
        span: 100.0 * 366.0 * 86400.0,
    };
}
fn validate_ranges(ranges: &[AggregationRange], limits: RangeLimits) -> Result<()> {
    if ranges.len() > limits.count {
        return Err(format!("{} accepts at most {} ranges", limits.name, limits.count).into());
    }
    let mut previous_end = None;
    for range in ranges {
        bounds(range.start, range.end)?;
        if range.start < 0.0
            || range.start % 60.0 != 0.0
            || range.end <= range.start
            || range.end - range.start > limits.duration
        {
            return Err(format!("{} requires nonnegative minute-aligned starts and positive durations up to {} seconds", limits.name, limits.duration).into());
        }
        if previous_end.is_some_and(|end| range.start < end) {
            return Err(
                format!("{} ranges must be ordered and non-overlapping", limits.name).into(),
            );
        }
        previous_end = Some(range.end);
    }
    if let (Some(first), Some(last)) = (ranges.first(), ranges.last()) {
        if last.end - first.start > limits.span {
            return Err(format!("{} span exceeds {} seconds", limits.name, limits.span).into());
        }
    }
    Ok(())
}

fn minute_summary(row: &rusqlite::Row<'_>, start: f64, end: f64) -> rusqlite::Result<Summary> {
    let minute: i64 = row.get(0)?;
    let mask = second_mask(
        start.max(minute as f64),
        end.min((minute + 60) as f64),
        minute,
    );
    let keyboard = row.get::<_, i64>(7)? as u64 & mask;
    let mouse = row.get::<_, i64>(8)? as u64 & mask;
    Ok(Summary {
        key_presses: row.get(1)?,
        left_clicks: row.get(2)?,
        right_clicks: row.get(3)?,
        middle_clicks: row.get(4)?,
        mouse_distance_points: row.get(5)?,
        scroll_units: row.get(6)?,
        keyboard_active_seconds: keyboard.count_ones() as u64,
        mouse_active_seconds: mouse.count_ones() as u64,
        total_active_seconds: (keyboard | mouse).count_ones() as u64,
        minute_count: 1,
        peak_keys_per_minute: row.get(1)?,
        ..Summary::default()
    })
}

fn default_step() -> i64 {
    60
}
fn default_true() -> bool {
    true
}
fn valid_time(t: f64) -> Result<()> {
    if t.is_finite() && t.abs() < 1e12 {
        Ok(())
    } else {
        Err("无效时间。".into())
    }
}
fn bounds(start: f64, end: f64) -> Result<()> {
    valid_time(start)?;
    valid_time(end)?;
    if end < start {
        Err("无效查询区间。".into())
    } else {
        Ok(())
    }
}
fn minute(time: f64) -> i64 {
    ((time / 60.0).floor() * 60.0) as i64
}
fn second_mask(start: f64, end: f64, m: i64) -> u64 {
    let lower = (start - m as f64).ceil().clamp(0.0, 60.0) as u32;
    let upper = (end - m as f64).floor().clamp(0.0, 60.0) as u32;
    if upper <= lower {
        0
    } else {
        ((1u64 << (upper - lower)) - 1) << lower
    }
}
fn merged(mut windows: Vec<Window>) -> Vec<Window> {
    windows.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut result: Vec<Window> = vec![];
    for w in windows {
        if let Some(last) = result.last_mut() {
            if w.start <= last.end {
                last.end = last.end.max(w.end);
                continue;
            }
        }
        result.push(w);
    }
    result
}
fn remainder(windows: Vec<Window>, now: f64) -> Vec<Window> {
    windows
        .into_iter()
        .filter(|w| w.end > now)
        .map(|w| Window {
            start: w.start.max(now.floor()),
            end: w.end,
        })
        .collect()
}
fn subtract(windows: &[Window], lower: f64, upper: f64) -> Vec<Window> {
    let mut out = vec![];
    for &w in windows {
        if w.start >= upper || w.end <= lower {
            out.push(w);
        } else {
            if w.start < lower {
                out.push(Window {
                    start: w.start,
                    end: lower,
                });
            }
            if w.end > upper {
                out.push(Window {
                    start: upper,
                    end: w.end,
                });
            }
        }
    }
    out
}
fn add_activity(deltas: &mut BTreeMap<i64, Delta>, windows: &[Window], now: f64, keyboard: bool) {
    for w in windows {
        let end = w.end.min(now);
        if end.floor() <= w.start.ceil() {
            continue;
        }
        let mut m = minute(w.start);
        while (m as f64) < end {
            let mask = second_mask(w.start, end, m);
            if mask != 0 {
                let d = deltas.entry(m).or_default();
                if keyboard {
                    d.keyboard |= mask;
                } else {
                    d.mouse |= mask;
                }
            }
            m += 60;
        }
    }
}
fn physical_label(label: Option<&str>) -> String {
    let Some(s) = label else {
        return "Other".into();
    };
    const LABELS: &[&str] = &[
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
        "NumLock",
        "ScrollLock",
        "Insert",
        "PrintScreen",
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
    ];
    if LABELS.contains(&s)
        || (s.len() == 1
            && (s.as_bytes()[0].is_ascii_uppercase() || s.as_bytes()[0].is_ascii_digit()))
    {
        return s.into();
    }
    if let Some(n) = s.strip_prefix("Num ") {
        if [
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "*", "+", "/", "Enter", "-", "=",
        ]
        .contains(&n)
        {
            return s.into();
        }
    }
    if let Some(n) = s.strip_prefix('F').and_then(|n| n.parse::<u8>().ok()) {
        if (1..=20).contains(&n) {
            return format!("F{n}");
        }
    }
    "Other".into()
}
// Gregorian conversion of a Unix day; UTC output avoids a timezone or locale dependency.
fn iso8601(seconds: f64) -> String {
    let seconds = seconds.floor() as i64;
    let day = seconds.div_euclid(86400);
    let tod = seconds.rem_euclid(86400);
    let z = day + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += if month <= 2 { 1 } else { 0 };
    format!(
        "{year:04}-{month:02}-{d:02}T{:02}:{:02}:{:02}Z",
        tod / 3600,
        (tod / 60) % 60,
        tod % 60
    )
}
fn owned_string(value: String) -> *mut c_char {
    CString::new(value.replace('\0', "\\u0000"))
        .expect("NUL escaped")
        .into_raw()
}
fn boundary<T>(f: impl FnOnce() -> Result<T>) -> std::result::Result<T, String> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("Rust storage boundary panic".into()),
    }
}
/// # Safety
/// `path` must be a live NUL-terminated UTF-8 string; `error_out`, when non-null,
/// must point to writable pointer storage. Returned handle is single-caller only.
#[no_mangle]
pub unsafe extern "C" fn keytrail_open(
    path: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_void {
    if !error_out.is_null() {
        *error_out = std::ptr::null_mut();
    }
    match boundary(|| {
        if path.is_null() {
            return Err("null database path".into());
        }
        Store::open(CStr::from_ptr(path).to_str()?)
    }) {
        Ok(store) => Box::into_raw(Box::new(store)).cast(),
        Err(error) => {
            if !error_out.is_null() {
                *error_out = owned_string(error);
            }
            std::ptr::null_mut()
        }
    }
}
/// # Safety
/// `handle` must be a live handle from `keytrail_open` and accessed serially.
/// `input` must be a live NUL-terminated UTF-8 string. Free the result exactly once.
#[no_mangle]
pub unsafe extern "C" fn keytrail_request(
    handle: *mut c_void,
    input: *const c_char,
) -> *mut c_char {
    let result = boundary(|| {
        if handle.is_null() || input.is_null() {
            return Err("null request or handle".into());
        }
        (&mut *handle.cast::<Store>()).request(CStr::from_ptr(input).to_str()?)
    });
    owned_string(
        match result {
            Ok(value) => json!({"ok":true,"result":value}),
            Err(error) => json!({"ok":false,"error":error}),
        }
        .to_string(),
    )
}
/// # Safety
/// `value` is null or an unreleased pointer returned by this library.
#[no_mangle]
pub unsafe extern "C" fn keytrail_string_free(value: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !value.is_null() {
            drop(CString::from_raw(value));
        }
    }));
}
/// # Safety
/// `handle` is null or an unreleased handle from `keytrail_open`; no concurrent calls.
#[no_mangle]
pub unsafe extern "C" fn keytrail_close(handle: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !handle.is_null() {
            drop(Box::from_raw(handle.cast::<Store>()));
        }
    }));
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod extension_tests;

#[cfg(test)]
mod export_page_tests;

#[cfg(test)]
mod trend_tests;
