//! Run with cargo run --release --locked --example timeline_benchmark.
//! Synthetic temporary SQLite only. stdout is a JSON evidence artifact.
use keytrail_core::{keytrail_close, keytrail_open, keytrail_request, keytrail_string_free};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::{
    error::Error,
    ffi::{CStr, CString},
    os::raw::c_void,
    path::PathBuf,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const MINUTES: i64 = 525_600;
const START: i64 = 1_735_689_600;
struct TemporaryDatabase(PathBuf);
impl TemporaryDatabase {
    fn new() -> Result<Self> {
        let directory = std::env::temp_dir().join(format!(
            "keytrail-aggregate-benchmark-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
        ));
        std::fs::create_dir(&directory)?;
        Ok(Self(directory.join("synthetic.sqlite")))
    }
}
impl Drop for TemporaryDatabase {
    fn drop(&mut self) {
        if let Some(parent) = self.0.parent() {
            let _ = std::fs::remove_dir_all(parent);
        }
    }
}
struct Engine(*mut c_void);
impl Engine {
    fn open(path: &std::path::Path) -> Result<Self> {
        let path = CString::new(path.to_str().ok_or("temporary path is not UTF8")?)?;
        let mut error = std::ptr::null_mut();
        let handle = unsafe { keytrail_open(path.as_ptr(), &mut error) };
        if handle.is_null() {
            let message = if error.is_null() {
                "null store".into()
            } else {
                unsafe {
                    let value = CStr::from_ptr(error).to_string_lossy().into_owned();
                    keytrail_string_free(error);
                    value
                }
            };
            return Err(message.into());
        }
        Ok(Self(handle))
    }
    fn request(&self, input: &Value) -> Result<Value> {
        let input = CString::new(input.to_string())?;
        let output = unsafe { keytrail_request(self.0, input.as_ptr()) };
        if output.is_null() {
            return Err("null response".into());
        }
        let bytes = unsafe {
            let bytes = CStr::from_ptr(output).to_bytes().to_vec();
            keytrail_string_free(output);
            bytes
        };
        let envelope: Value = serde_json::from_slice(&bytes)?;
        if envelope["ok"] != true {
            return Err(envelope["error"].to_string().into());
        }
        Ok(envelope["result"].clone())
    }
}
impl Drop for Engine {
    fn drop(&mut self) {
        unsafe {
            keytrail_close(self.0);
        }
    }
}
fn key_total(first: i64, minutes: i64) -> i64 {
    (first..first + minutes).map(|i| i % 120 + 1).sum()
}
fn assert_summary(value: &Value, first: i64, minutes: i64, histogram: bool) {
    assert_eq!(value["keyPresses"], key_total(first, minutes));
    assert_eq!(value["leftClicks"], minutes);
    assert_eq!(value["rightClicks"], 0);
    assert_eq!(value["middleClicks"], 0);
    assert_eq!(value["mouseDistancePoints"], minutes as f64 * 12.5);
    assert_eq!(value["scrollUnits"], minutes as f64 * 2.0);
    assert_eq!(value["keyboardActiveSeconds"], minutes * 30);
    assert_eq!(value["mouseActiveSeconds"], minutes * 30);
    assert_eq!(value["totalActiveSeconds"], minutes * 45);
    assert_eq!(value["minuteCount"], minutes);
    assert_eq!(
        value["peakKeysPerMinute"],
        (first..first + minutes)
            .map(|i| i % 120 + 1)
            .max()
            .unwrap_or(0)
    );
    if histogram {
        assert_eq!(value["keyCounts"], json!({"A":key_total(first,minutes)}));
    } else {
        assert_eq!(value["keyCounts"], json!({}));
    }
}
fn measure(engine: &Engine, request: &Value) -> Result<Value> {
    let mut samples = Vec::new();
    for _ in 0..9 {
        let before = Instant::now();
        let response = engine.request(request)?;
        std::hint::black_box(response);
        samples.push(before.elapsed().as_secs_f64() * 1000.0);
    }
    let mut sorted = samples.clone();
    sorted.sort_by(f64::total_cmp);
    Ok(
        json!({"iterations":samples.len(),"milliseconds":samples,"medianMs":sorted[sorted.len()/2],"p95Ms":sorted[sorted.len()-1],"minMs":sorted[0],"maxMs":sorted[sorted.len()-1]}),
    )
}
fn main() -> Result<()> {
    let temporary = TemporaryDatabase::new()?;
    drop(Engine::open(&temporary.0)?);
    let seed_started = Instant::now();
    {
        let mut db = Connection::open(&temporary.0)?;
        db.execute_batch(
            "PRAGMA foreign_keys=ON;PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;",
        )?;
        let tx = db.transaction()?;
        {
            let mut minutes=tx.prepare("INSERT INTO minutes(minute,keys,left_clicks,distance,scroll,keyboard_mask,mouse_mask)VALUES(?,?,1,12.5,2,?,?)")?;
            let mut histograms =
                tx.prepare("INSERT INTO key_histograms(minute,label,count)VALUES(?,'A',?)")?;
            let mask = (1_i64 << 30) - 1;
            for index in 0..MINUTES {
                let time = START + index * 60;
                let keys = index % 120 + 1;
                minutes.execute(params![time, keys, mask, mask << 15])?;
                histograms.execute(params![time, keys])?;
            }
        }
        tx.commit()?;
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))?,
            1
        );
    }
    let seed_ms = seed_started.elapsed().as_secs_f64() * 1000.0;
    let engine = Engine::open(&temporary.0)?;
    let annual = json!({"op":"summary","start":START,"end":START+MINUTES*60});
    let first = MINUTES - 7 * 24 * 60;
    let weekly = json!({"op":"summary","start":START+first*60,"end":START+MINUTES*60});
    let ranges: Vec<_> = (0..168)
        .map(|h| json!({"start":START+(first+h*60)*60,"end":START+(first+(h+1)*60)*60}))
        .collect();
    let timeline = json!({"op":"timeline","ranges":ranges});
    let verify_started = Instant::now();
    assert_summary(&engine.request(&annual)?, 0, MINUTES, true);
    assert_summary(&engine.request(&weekly)?, first, 10080, true);
    let buckets = engine.request(&timeline)?;
    let buckets = buckets.as_array().ok_or("timeline not array")?;
    assert_eq!(buckets.len(), 168);
    for (index, bucket) in buckets.iter().enumerate() {
        assert_eq!(
            bucket["start"].as_f64().unwrap(),
            (START + (first + index as i64 * 60) * 60) as f64
        );
        assert_summary(&bucket["summary"], first + index as i64 * 60, 60, false);
    }
    assert_eq!(
        buckets
            .iter()
            .map(|b| b["summary"]["keyPresses"].as_i64().unwrap())
            .sum::<i64>(),
        key_total(first, 10080)
    );
    let month_first = MINUTES - 31 * 1440;
    let monthly = json!({"op":"summary","start":START+month_first*60,"end":START+MINUTES*60});
    let day_ranges: Vec<_> = (0..31).map(|day|json!({"start":START+(month_first+day*1440)*60,"end":START+(month_first+(day+1)*1440)*60})).collect();
    let monthly_summaries = json!({"op":"summaries","ranges":day_ranges});
    assert_summary(&engine.request(&monthly)?, month_first, 31 * 1440, true);
    let day_buckets = engine.request(&monthly_summaries)?;
    let day_buckets = day_buckets.as_array().ok_or("summaries not array")?;
    assert_eq!(day_buckets.len(), 31);
    for (index, bucket) in day_buckets.iter().enumerate() {
        assert_eq!(
            bucket["start"].as_f64().unwrap(),
            (START + (month_first + index as i64 * 1440) * 60) as f64
        );
        assert_summary(
            &bucket["summary"],
            month_first + index as i64 * 1440,
            1440,
            false,
        );
    }
    assert_eq!(
        day_buckets
            .iter()
            .map(|b| b["summary"]["keyPresses"].as_i64().unwrap())
            .sum::<i64>(),
        key_total(month_first, 31 * 1440)
    );
    let verification_ms = verify_started.elapsed().as_secs_f64() * 1000.0;
    let result = json!({"schemaVersion":1,"synthetic":true,"usesUserApplicationSupport":false,"temporaryDatabaseRemovedOnExit":true,"minuteRows":MINUTES,"histogramRows":MINUTES,"databaseBytes":std::fs::metadata(&temporary.0)?.len(),"seedMs":seed_ms,"verification":{"passed":true,"annualKeys":key_total(0,MINUTES),"weeklyKeys":key_total(first,10080),"hourlyCells":168,"monthlyKeys":key_total(month_first,31*1440),"dailyCells":31,"allSummaryFieldsVerified":true,"durationMs":verification_ms},"measurementScope":"release Rust FFI JSON serialization and parse, system SQLite, warm repeated queries after correctness verification; excludes Swift/UI/socket; no cache flush","annualSummary":measure(&engine,&annual)?,"weeklySummary":measure(&engine,&weekly)?,"weeklyTimeline":measure(&engine,&timeline)?,"monthlySummary":measure(&engine,&monthly)?,"monthlySummaries":measure(&engine,&monthly_summaries)?});
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}
