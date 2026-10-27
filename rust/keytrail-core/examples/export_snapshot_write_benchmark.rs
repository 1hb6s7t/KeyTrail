//! One paired synthetic write measurement, not OS capture or a before/after binary
//! comparison. Baseline differs only by disabling export triggers in a fresh temp DB.
//! cargo run --release --locked -p keytrail-core --example export_snapshot_write_benchmark
use keytrail_core::Engine;
use rusqlite::Connection;
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

const BATCHES: usize = 1000;
const SAMPLES: usize = 32;
struct Temporary(PathBuf);
impl Temporary {
    fn new() -> Result<Self, Box<dyn std::error::Error>> {
        let path = std::env::temp_dir().join(format!(
            "keytrail-export-write-bench-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
        ));
        std::fs::create_dir(&path)?;
        Ok(Self(path))
    }
}
impl Drop for Temporary {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn run(inputs: &[String], enabled: bool) -> Result<Value, Box<dyn std::error::Error>> {
    let directory = Temporary::new()?;
    let path = directory.0.join("synthetic.sqlite");
    let mut engine = Engine::open(path.to_str().ok_or("non UTF8 temp path")?)?;
    let reader = Connection::open(&path)?;
    if !enabled {
        // Only the temporary fixture is modified; Engine remains open so it does
        // not recreate these triggers. Aggregate/sync/rhythm work stays identical.
        for table in ["minutes", "key_histograms", "rhythm_minutes"] {
            for operation in ["insert", "update", "delete"] {
                reader.execute_batch(&format!("DROP TRIGGER export_{table}_{operation}"))?;
            }
        }
    }
    let journal: String = reader.query_row("PRAGMA journal_mode", [], |r| r.get(0))?;
    assert_eq!(journal, "delete");
    let mut latencies = Vec::with_capacity(inputs.len());
    let whole = Instant::now();
    for input in inputs {
        let start = Instant::now();
        engine.request(input)?;
        latencies.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    let elapsed = whole.elapsed().as_secs_f64();
    let end = 1_735_689_600.0 + BATCHES as f64 * 2.0;
    let summary =
        engine.request(&json!({"op":"summary","start":1_735_689_600,"end":end}).to_string())?;
    assert_eq!(summary["keyPresses"], (BATCHES * SAMPLES) as u64);
    assert_eq!(
        summary["keyCounts"]
            .as_object()
            .unwrap()
            .values()
            .map(|v| v.as_u64().unwrap())
            .sum::<u64>(),
        (BATCHES * SAMPLES) as u64
    );
    let revision: i64 =
        reader.query_row("SELECT revision FROM export_snapshot", [], |r| r.get(0))?;
    assert_eq!(revision > 0, enabled);
    latencies.sort_by(|a, b| a.total_cmp(b));
    let percentile = |p: f64| latencies[((latencies.len() - 1) as f64 * p).round() as usize];
    Ok(
        json!({"exportTriggersEnabled":enabled,"batches":inputs.len(),"samples":BATCHES*SAMPLES,"syntheticSeconds":BATCHES*2,"elapsedSeconds":elapsed,"batchesPerSecond":inputs.len() as f64/elapsed,"millisecondsPerBatch":{"mean":elapsed*1000.0/inputs.len() as f64,"p50":percentile(0.5),"p95":percentile(0.95),"p99":percentile(0.99)},"databaseBytes":std::fs::metadata(path)?.len(),"snapshotRevision":revision,"exactKeyTotal":summary["keyPresses"],"journalMode":journal,"engineSynchronous":"FULL"}),
    )
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let inputs:Vec<String>=(0..BATCHES).map(|batch|{
        let start=1_735_689_600.0+batch as f64*2.0;
        let samples:Vec<Value>=(0..SAMPLES).map(|n|json!({"kind":"keyPress","timestamp":start+n as f64*2.0/SAMPLES as f64,"keyLabel":((b'A'+(n%8) as u8)as char).to_string()})).collect();
        json!({"op":"ingest","samples":samples,"observedThrough":start+2.0}).to_string()
    }).collect();
    let baseline = run(&inputs, false)?;
    let tracked = run(&inputs, true)?;
    let ratio =
        tracked["elapsedSeconds"].as_f64().unwrap() / baseline["elapsedSeconds"].as_f64().unwrap();
    println!(
        "{}",
        serde_json::to_string_pretty(
            &json!({"fixtureOnly":true,"measurement":"single paired sequential run, baseline then tracked; current binary, baseline disables only 9 export triggers in isolated temporary database; not production/OS capture/previous-release performance","inputConstructionExcluded":true,"includes":"JSON request parsing, minute/rhythm aggregation, sync journaling, DELETE/FULL SQLite commits; no sleeps between replayed batches","baseline":baseline,"tracked":tracked,"elapsedRatioTrackedOverBaseline":ratio})
        )?
    );
    Ok(())
}
