use super::*;
use std::sync::atomic::{AtomicU64, Ordering};
const ORIGIN: f64 = 1_735_689_600.0;
fn t(n: f64) -> f64 {
    ORIGIN + n
}
fn key(n: f64, label: &str) -> Sample {
    Sample {
        timestamp: t(n),
        kind: Kind::KeyPress,
        key_label: Some(label.into()),
        distance_points: 0.0,
        scroll_delta: 0.0,
    }
}
fn event(n: f64, kind: Kind, distance: f64, scroll: f64) -> Sample {
    Sample {
        timestamp: t(n),
        kind,
        key_label: None,
        distance_points: distance,
        scroll_delta: scroll,
    }
}
fn mem() -> Store {
    Store::open(":memory:").unwrap()
}
fn sum(s: &Store, a: f64, b: f64) -> Summary {
    s.summary(t(a), t(b)).unwrap()
}
struct Temp(String);
impl Temp {
    fn new() -> Self {
        static SEQ: AtomicU64 = AtomicU64::new(0);
        Self(
            std::env::temp_dir()
                .join(format!(
                    "keytrail-rust-{}-{}.sqlite",
                    std::process::id(),
                    SEQ.fetch_add(1, Ordering::Relaxed)
                ))
                .to_string_lossy()
                .into_owned(),
        )
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
#[test]
fn union_has_no_future_or_query_accrual() {
    let mut s = mem();
    s.ingest(
        vec![
            key(0.0, "A"),
            key(10.0, "A"),
            event(5.0, Kind::LeftClick, 0.0, 0.0),
        ],
        t(15.0),
    )
    .unwrap();
    let a = sum(&s, 0.0, 3600.0);
    assert_eq!(
        (
            a.keyboard_active_seconds,
            a.mouse_active_seconds,
            a.total_active_seconds
        ),
        (15, 10, 15)
    );
    assert_eq!(a, sum(&s, 0.0, 3600.0));
    s.advance(t(100.0), false).unwrap();
    let a = sum(&s, 0.0, 3600.0);
    assert_eq!(
        (
            a.keyboard_active_seconds,
            a.mouse_active_seconds,
            a.total_active_seconds,
            a.key_presses
        ),
        (40, 30, 40, 2)
    );
}
#[test]
fn pause_cuts_windows_and_resume_gap() {
    let mut s = mem();
    s.ingest(vec![key(0.0, "A")], t(0.0)).unwrap();
    s.advance(t(9.0), true).unwrap();
    s.advance(t(300.0), false).unwrap();
    assert_eq!(sum(&s, 0.0, 600.0).total_active_seconds, 9);
    s.ingest(vec![key(300.0, "A")], t(310.0)).unwrap();
    assert_eq!(sum(&s, 0.0, 600.0).total_active_seconds, 19);
}
#[test]
fn restart_does_not_accrue_offline_time() {
    let p = Temp::new();
    {
        let mut s = Store::open(&p.0).unwrap();
        s.ingest(vec![key(0.0, "A")], t(8.0)).unwrap();
    }
    let mut s = Store::open(&p.0).unwrap();
    s.advance(t(3600.0), false).unwrap();
    let a = sum(&s, 0.0, 7200.0);
    assert_eq!((a.key_presses, a.total_active_seconds), (1, 8));
    assert_eq!(a.key_counts.get("A"), Some(&1));
}
#[test]
fn half_open_midnight_windows_and_counters() {
    let mut s = mem();
    s.ingest(
        vec![key(-10.0, "A"), key(0.0, "B"), key(60.0, "C")],
        t(70.0),
    )
    .unwrap();
    let a = sum(&s, -60.0, 0.0);
    assert_eq!((a.key_presses, a.total_active_seconds), (1, 10));
    let a = sum(&s, 0.0, 60.0);
    assert_eq!((a.key_presses, a.total_active_seconds), (1, 30));
    assert_eq!(a.key_counts.get("B"), Some(&1));
    let a = sum(&s, 60.0, 120.0);
    assert_eq!((a.key_presses, a.total_active_seconds), (1, 10));
}
#[test]
fn deletion_does_not_resurrect_pending_minutes() {
    let mut s = mem();
    s.ingest(vec![key(50.0, "A")], t(55.0)).unwrap();
    s.delete(t(0.0), t(60.0)).unwrap();
    s.advance(t(100.0), false).unwrap();
    assert_eq!(sum(&s, 0.0, 60.0), Summary::default());
    assert!(sum(&s, 0.0, 120.0).key_counts.is_empty());
    assert_eq!(sum(&s, 60.0, 120.0).total_active_seconds, 20);
}
#[test]
fn outward_deletion_and_clear_close_pending_windows() {
    let mut s = mem();
    s.ingest(
        vec![key(1.0, "A"), key(61.0, "A"), key(121.0, "A")],
        t(125.0),
    )
    .unwrap();
    s.delete(t(59.0), t(61.0)).unwrap();
    assert_eq!(sum(&s, 0.0, 180.0).key_presses, 1);
    s.clear().unwrap();
    s.advance(t(1000.0), false).unwrap();
    assert_eq!(sum(&s, 0.0, 1200.0), Summary::default());
    assert!(s.buckets(t(0.0), t(1200.0), 60, true).unwrap().is_empty());
}
#[test]
fn fractional_seconds_only_count_fully_elapsed() {
    let mut s = mem();
    s.ingest(vec![key(0.2, "A")], t(1.9)).unwrap();
    assert_eq!(sum(&s, 0.0, 60.0).total_active_seconds, 0);
    s.advance(t(2.1), false).unwrap();
    assert_eq!(sum(&s, 0.0, 60.0).total_active_seconds, 1);
    s.advance(t(3.9), false).unwrap();
    assert_eq!(sum(&s, 0.0, 2.9).total_active_seconds, 1);
    assert_eq!(sum(&s, 0.0, 60.0).total_active_seconds, 2);
}
#[test]
fn batch_order_does_not_change_union_or_counts() {
    let mut a = mem();
    let mut b = mem();
    let events = || {
        vec![
            key(2.0, "A"),
            key(29.0, "A"),
            key(25.0, "A"),
            key(65.0, "A"),
        ]
    };
    a.ingest(events(), t(90.0)).unwrap();
    b.ingest(events().into_iter().rev().collect(), t(90.0))
        .unwrap();
    assert_eq!(
        a.export(t(0.0), t(120.0)).unwrap(),
        b.export(t(0.0), t(120.0)).unwrap()
    );
    assert_eq!(sum(&a, 0.0, 120.0).total_active_seconds, 82);
}
#[test]
fn invalid_batch_and_backward_clock_are_atomic() {
    let mut s = mem();
    assert!(s
        .ingest(vec![key(0.0, "A"), key(100.0, "A")], t(10.0))
        .is_err());
    assert_eq!(sum(&s, 0.0, 120.0).key_presses, 0);
    s.ingest(vec![key(0.0, "A")], t(10.0)).unwrap();
    assert!(s.advance(t(5.0), false).is_err());
    assert_eq!(sum(&s, 0.0, 120.0).total_active_seconds, 10);
}
#[test]
fn physical_labels_mouse_units_csv_and_disk_privacy() {
    let p = Temp::new();
    let mut s = Store::open(&p.0).unwrap();
    s.ingest(
        vec![
            key(0.0, "my secret password"),
            key(1.0, "Cmd"),
            key(2.0, "Num 7"),
            event(3.0, Kind::MouseMove, 17.5, 0.0),
            event(4.0, Kind::Scroll, 0.0, -2.5),
            event(5.0, Kind::RightClick, 0.0, 0.0),
            event(6.0, Kind::MiddleClick, 0.0, 0.0),
        ],
        t(10.0),
    )
    .unwrap();
    let a = sum(&s, 0.0, 60.0);
    assert_eq!(
        a.key_counts,
        BTreeMap::from([("Other".into(), 1), ("Cmd".into(), 1), ("Num 7".into(), 1)])
    );
    assert_eq!(
        (
            a.mouse_distance_points,
            a.scroll_units,
            a.right_clicks + a.middle_clicks
        ),
        (17.5, 2.5, 2)
    );
    let csv = s.export(t(0.0), t(60.0)).unwrap();
    assert!(
        csv.contains("display_points")
            && csv.contains("range_end_exclusive")
            && !csv.contains("my secret password")
    );
    assert!(!String::from_utf8_lossy(&std::fs::read(&p.0).unwrap()).contains("my secret password"));
    #[cfg(unix)]
    assert_eq!(
        std::fs::metadata(&p.0).unwrap().permissions().mode() & 0o777,
        0o600
    );
}
#[test]
fn schema_only_allows_minute_aggregates_and_replication_metadata() {
    let mut s = mem();
    s.ingest(vec![key(0.0, "DO NOT PERSIST TEXT")], t(10.0))
        .unwrap();
    let columns = |q: &str, n: usize| {
        s.db.prepare(q)
            .unwrap()
            .query_map([], |r| r.get::<_, String>(n))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap()
    };
    assert_eq!(columns("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",0),["export_snapshot","key_histograms","minutes","replica_versions","rhythm_minutes","sync_journal","sync_state"]);
    assert_eq!(
        columns("PRAGMA table_info(minutes)", 1),
        [
            "minute",
            "keys",
            "left_clicks",
            "right_clicks",
            "middle_clicks",
            "distance",
            "scroll",
            "keyboard_mask",
            "mouse_mask"
        ]
    );
    assert_eq!(
        columns("PRAGMA table_info(key_histograms)", 1),
        ["minute", "label", "count"]
    );
}
#[test]
fn peak_is_natural_minute_and_empty_ranges_are_empty() {
    let mut s = mem();
    s.ingest(
        vec![
            key(58.0, "A"),
            key(59.0, "A"),
            key(60.0, "A"),
            key(61.0, "A"),
            key(62.0, "A"),
        ],
        t(70.0),
    )
    .unwrap();
    let a = sum(&s, 0.0, 120.0);
    assert_eq!((a.peak_keys_per_minute, a.minute_count), (3, 2));
    assert_eq!(sum(&s, 120.0, 180.0), Summary::default());
    assert!(s.buckets(t(60.0), t(60.0), 60, true).unwrap().is_empty());
}
#[test]
fn local_calendar_dst_bounds_are_not_assumed_24_hours() {
    // America/Los_Angeles 2025-03-09: 08:00 UTC to next day 07:00 UTC.
    let mut s = mem();
    let start = 1_741_507_200.0;
    let end = start + 23.0 * 3600.0;
    let mut a = key(0.0, "A");
    a.timestamp = start;
    let mut b = key(0.0, "B");
    b.timestamp = end;
    s.ingest(vec![a, b], end).unwrap();
    assert_eq!(
        s.summary(start, end).unwrap().key_counts,
        BTreeMap::from([("A".into(), 1)])
    );
}
#[test]
fn v1_database_retains_existing_rows_and_is_bidirectionally_compatible() {
    let p = Temp::new();
    {
        let db = Connection::open(&p.0).unwrap();
        db.execute_batch("CREATE TABLE minutes(minute INTEGER PRIMARY KEY,keys INTEGER NOT NULL DEFAULT 0,left_clicks INTEGER NOT NULL DEFAULT 0,right_clicks INTEGER NOT NULL DEFAULT 0,middle_clicks INTEGER NOT NULL DEFAULT 0,distance REAL NOT NULL DEFAULT 0,scroll REAL NOT NULL DEFAULT 0,keyboard_mask INTEGER NOT NULL DEFAULT 0,mouse_mask INTEGER NOT NULL DEFAULT 0);CREATE TABLE key_histograms(minute INTEGER NOT NULL REFERENCES minutes(minute) ON DELETE CASCADE,label TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(minute,label)) WITHOUT ROWID;PRAGMA user_version=1;").unwrap();
        db.execute(
            "INSERT INTO minutes(minute,keys,keyboard_mask)VALUES(?,7,15)",
            [ORIGIN as i64],
        )
        .unwrap();
        db.execute(
            "INSERT INTO key_histograms VALUES(?,'A',7)",
            [ORIGIN as i64],
        )
        .unwrap();
    }
    let mut s = Store::open(&p.0).unwrap();
    let a = sum(&s, 0.0, 60.0);
    assert_eq!((a.key_presses, a.total_active_seconds), (7, 4));
    s.ingest(vec![key(10.0, "B")], t(12.0)).unwrap();
    drop(s);
    let db = Connection::open(&p.0).unwrap();
    assert_eq!(
        db.query_row("SELECT keys FROM minutes", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        8
    );
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
}
#[test]
fn failed_transaction_keeps_windows_and_counters_retryable() {
    let mut s = mem();
    s.ingest(vec![key(0.0, "A")], t(5.0)).unwrap();
    s.db.execute_batch("CREATE TRIGGER fail_write BEFORE INSERT ON key_histograms WHEN NEW.label='B' BEGIN SELECT RAISE(FAIL,'injected failure'); END;").unwrap();
    assert!(s.ingest(vec![key(8.0, "B")], t(10.0)).is_err());
    assert_eq!(sum(&s, 0.0, 60.0).key_presses, 1);
    assert_eq!(sum(&s, 0.0, 60.0).total_active_seconds, 5);
    s.db.execute_batch("DROP TRIGGER fail_write").unwrap();
    s.ingest(vec![key(8.0, "B")], t(10.0)).unwrap();
    let a = sum(&s, 0.0, 60.0);
    assert_eq!((a.key_presses, a.total_active_seconds), (2, 10));
    assert_eq!(a.key_counts.get("B"), Some(&1));
}
#[test]
fn batch_coalesces_sql_writes_and_idle_tick_has_no_writes() {
    let mut s = mem();
    let initialized = s.db.total_changes();
    s.ingest((0..10000).map(|_| key(0.0, "A")).collect(), t(5.0))
        .unwrap();
    // Five batch-level writes plus three export-revision trigger ticks, still
    // independent of 10,000 inputs. No per-keystroke persistent revision writes.
    assert_eq!(s.db.total_changes() - initialized, 8);
    assert_eq!(sum(&s, 0.0, 60.0).key_presses, 10000);
    s.advance(t(100.0), false).unwrap();
    let changes = s.db.total_changes();
    s.advance(t(200.0), false).unwrap();
    assert_eq!(s.db.total_changes(), changes);
}
#[test]
fn compressed_buckets_preserve_totals_peak_and_histogram_option() {
    let mut s = mem();
    s.ingest(
        vec![
            key(1.0, "A"),
            key(61.0, "B"),
            key(62.0, "B"),
            key(3601.0, "C"),
        ],
        t(3610.0),
    )
    .unwrap();
    let b = s.buckets(t(0.0), t(7200.0), 3600, true).unwrap();
    assert_eq!(b.len(), 2);
    assert_eq!(b[0].summary.key_presses, 3);
    assert_eq!(b[0].summary.peak_keys_per_minute, 2);
    assert_eq!(b[0].summary.key_counts.get("B"), Some(&2));
    let c = s.buckets(t(0.0), t(7200.0), 3600, false).unwrap();
    assert!(c.iter().all(|x| x.summary.key_counts.is_empty()));
    assert_eq!(
        c.iter()
            .map(|x| x.summary.total_active_seconds)
            .sum::<u64>(),
        sum(&s, 0.0, 7200.0).total_active_seconds
    );
    assert!(s.buckets(t(0.0), t(60.0), 61, true).is_err());
}
#[test]
fn ffi_owns_strings_and_reports_errors_without_crossing_boundary() {
    unsafe {
        let mut error = std::ptr::null_mut();
        assert!(keytrail_open(std::ptr::null(), &mut error).is_null());
        assert!(!error.is_null());
        keytrail_string_free(error);
        let path = CString::new(":memory:").unwrap();
        let handle = keytrail_open(path.as_ptr(), &mut error);
        assert!(!handle.is_null());
        assert!(error.is_null());
        for input in [
            "bad JSON",
            "{\"op\":\"unknown\"}",
            "{\"op\":\"summary\",\"start\":0,\"end\":60}",
        ] {
            let input = CString::new(input).unwrap();
            let output = keytrail_request(handle, input.as_ptr());
            let result: Value =
                serde_json::from_str(CStr::from_ptr(output).to_str().unwrap()).unwrap();
            assert_eq!(result["ok"], input.to_str().unwrap().contains("summary"));
            keytrail_string_free(output);
        }
        let output = keytrail_request(std::ptr::null_mut(), std::ptr::null());
        assert!(CStr::from_ptr(output).to_str().unwrap().contains("false"));
        keytrail_string_free(output);
        keytrail_close(handle);
        keytrail_close(std::ptr::null_mut());
        keytrail_string_free(std::ptr::null_mut());
    }
    assert_eq!(
        boundary::<()>(|| panic!("test panic")).unwrap_err(),
        "Rust storage boundary panic"
    );
}
#[test]
fn json_contract_round_trip_defaults_and_errors() {
    let mut s = mem();
    assert_eq!(s.request("{\"op\":\"ingest\",\"samples\":[{\"timestamp\":0,\"kind\":\"keyPress\",\"keyLabel\":\"A\"}],\"observedThrough\":5}").unwrap(),Value::Null);
    let a = s
        .request("{\"op\":\"summary\",\"start\":0,\"end\":60}")
        .unwrap();
    assert_eq!(a["keyPresses"], 1);
    assert_eq!(a["totalActiveSeconds"], 5);
    let b = s
        .request("{\"op\":\"buckets\",\"start\":0,\"end\":60}")
        .unwrap();
    assert_eq!(b[0]["summary"]["keyCounts"]["A"], 1);
    assert!(s
        .request("{\"op\":\"summary\",\"start\":60,\"end\":0}")
        .is_err());
    assert!(s.request("{\"op\":\"advance\",\"time\":1e100}").is_err());
}
#[test]
fn utc_csv_dates_handle_epoch_negative_and_leap_dates() {
    assert_eq!(iso8601(0.0), "1970-01-01T00:00:00Z");
    assert_eq!(iso8601(-1.0), "1969-12-31T23:59:59Z");
    assert_eq!(iso8601(ORIGIN), "2025-01-01T00:00:00Z");
    assert_eq!(iso8601(1_709_164_800.0), "2024-02-29T00:00:00Z");
}

#[test]
fn unsupported_schema_is_rejected_without_destroying_data() {
    let p = Temp::new();
    {
        let db = Connection::open(&p.0).unwrap();
        db.execute_batch("PRAGMA user_version=99; CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES('retained');").unwrap();
    }
    assert!(Store::open(&p.0).is_err());
    let db = Connection::open(&p.0).unwrap();
    assert_eq!(
        db.query_row("SELECT value FROM future_data", [], |r| r
            .get::<_, String>(0))
            .unwrap(),
        "retained"
    );
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        99
    );
}

fn timeline_range(start: f64, end: f64) -> AggregationRange {
    AggregationRange {
        start: t(start),
        end: t(end),
    }
}
#[test]
fn timeline_half_open_boundaries_gaps_zero_buckets_and_fractional_end() {
    let mut store = mem();
    store
        .ingest(
            vec![
                key(59.0, "A"),
                key(60.0, "B"),
                key(120.0, "C"),
                key(180.0, "D"),
            ],
            t(190.0),
        )
        .unwrap();
    let ranges = [
        timeline_range(0.0, 60.0),
        timeline_range(60.0, 70.9),
        timeline_range(180.0, 190.9),
        timeline_range(240.0, 300.0),
    ];
    let before = store.db.total_changes();
    let values = store.timeline(&ranges).unwrap();
    assert_eq!(values.len(), 4);
    for (index, bucket) in values.iter().enumerate() {
        assert_eq!(bucket.start, ranges[index].start);
        let mut expected = store
            .summary(ranges[index].start, ranges[index].end)
            .unwrap();
        expected.key_counts.clear();
        assert_eq!(bucket.summary, expected);
    }
    assert_eq!(values[0].summary.key_presses, 1);
    assert_eq!(values[1].summary.key_presses, 1);
    assert_eq!(values[1].summary.total_active_seconds, 10);
    assert_eq!(values[2].summary.key_presses, 1);
    assert_eq!(values[3].summary, Summary::default());
    assert_eq!(store.db.total_changes(), before);
    assert_eq!(
        store
            .db
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
}
#[test]
fn timeline_calendar_supplied_dst_style_ranges_preserve_all_hour_cells() {
    let mut store = mem();
    // Consecutive local-calendar days with 24, 23, and 25 hourly intervals.
    // Rust sees their UTC instants, including repeated local hours as distinct ranges.
    let mut ranges = Vec::new();
    let mut hour = 0;
    for hours_in_day in [24, 23, 25] {
        for _ in 0..hours_in_day {
            ranges.push(timeline_range(
                (hour * 3600) as f64,
                ((hour + 1) * 3600) as f64,
            ));
            hour += 1;
        }
    }
    let samples = (0..hour).map(|h| key((h * 3600) as f64, "A")).collect();
    store.ingest(samples, t((hour * 3600) as f64)).unwrap();
    let buckets = store.timeline(&ranges).unwrap();
    assert_eq!(buckets.len(), 72);
    assert!(buckets
        .iter()
        .all(|b| b.summary.key_presses == 1 && b.summary.total_active_seconds == 30));
    assert_eq!(
        buckets.iter().map(|b| b.summary.key_presses).sum::<i64>(),
        72
    );
    // A valid non-uniform interval sequence can include a two-hour cell.
    let nonuniform = [
        timeline_range(0.0, 3600.0),
        timeline_range(3600.0, 10800.0),
        timeline_range(10800.0, 12600.5),
    ];
    let buckets = store.timeline(&nonuniform).unwrap();
    assert_eq!(
        buckets
            .iter()
            .map(|b| b.summary.key_presses)
            .collect::<Vec<_>>(),
        [1, 2, 1]
    );
}
#[test]
fn timeline_summary_total_and_natural_minute_peak_match_without_histogram_access() {
    let mut store = mem();
    store
        .ingest(
            vec![
                key(0.0, "A"),
                key(59.0, "A"),
                key(60.0, "B"),
                key(61.0, "B"),
                key(62.0, "B"),
                event(65.0, Kind::MouseMove, 12.5, 0.0),
                event(75.0, Kind::LeftClick, 0.0, 0.0),
            ],
            t(100.0),
        )
        .unwrap();
    let mut expected = sum(&store, 0.0, 120.0);
    expected.key_counts.clear();
    store.db.execute_batch("DROP TABLE key_histograms").unwrap();
    let buckets = store
        .timeline(&[timeline_range(0.0, 60.0), timeline_range(60.0, 120.0)])
        .unwrap();
    let mut total = Summary::default();
    for bucket in buckets {
        assert!(bucket.summary.key_counts.is_empty());
        total.add(bucket.summary).unwrap();
    }
    assert_eq!(total, expected);
    assert_eq!(total.peak_keys_per_minute, 3);
}
#[test]
fn timeline_rejects_invalid_unordered_overlapping_and_oversized_ranges() {
    let store = mem();
    let invalid = vec![
        vec![AggregationRange {
            start: -60.0,
            end: 0.0,
        }],
        vec![timeline_range(1.0, 60.0)],
        vec![timeline_range(0.0, 0.0)],
        vec![timeline_range(60.0, 0.0)],
        vec![timeline_range(0.0, 7200.1)],
        vec![timeline_range(60.0, 120.0), timeline_range(0.0, 60.0)],
        vec![timeline_range(0.0, 61.0), timeline_range(60.0, 120.0)],
        vec![
            timeline_range(0.0, 60.0),
            timeline_range(8.0 * 86400.0, 8.0 * 86400.0 + 1.0),
        ],
        vec![AggregationRange {
            start: f64::NAN,
            end: 60.0,
        }],
        vec![AggregationRange {
            start: 0.0,
            end: f64::INFINITY,
        }],
        (0..201)
            .map(|i| timeline_range((i * 60) as f64, ((i + 1) * 60) as f64))
            .collect(),
    ];
    for ranges in invalid {
        assert!(store.timeline(&ranges).is_err());
    }
    let maximum: Vec<_> = (0..200)
        .map(|i| timeline_range((i * 60) as f64, ((i + 1) * 60) as f64))
        .collect();
    assert_eq!(store.timeline(&maximum).unwrap().len(), 200);
    assert!(store.timeline(&[]).unwrap().is_empty());
    assert_eq!(
        store
            .timeline(&[
                timeline_range(0.0, 7200.0),
                timeline_range(8.0 * 86400.0 - 60.0, 8.0 * 86400.0)
            ])
            .unwrap()
            .len(),
        2
    );
}
#[test]
fn timeline_json_contract_includes_zero_summary_fields() {
    let mut store = mem();
    let value = store
        .request(r#"{"op":"timeline","ranges":[{"start":0,"end":60},{"start":60,"end":62.5}]}"#)
        .unwrap();
    assert_eq!(value.as_array().unwrap().len(), 2);
    assert_eq!(value[1]["start"], 60.0);
    assert_eq!(
        value[1]["summary"],
        serde_json::to_value(Summary::default()).unwrap()
    );
    assert!(store
        .request(r#"{"op":"timeline","ranges":[{"start":60,"end":120},{"start":0,"end":60}]}"#)
        .is_err());
}

#[test]
fn summaries_month_daily_cells_accept_23_and_25_hour_days() {
    let mut store = mem();
    let mut start = 0.0;
    let mut ranges = Vec::new();
    let mut samples = Vec::new();
    for day in 0..31 {
        let hours = match day {
            7 => 23,
            21 => 25,
            _ => 24,
        };
        let end = start + hours as f64 * 3600.0;
        ranges.push(timeline_range(start, end));
        samples.push(key(start, "A"));
        samples.push(key(end - 60.0, "B"));
        start = end;
    }
    store.ingest(samples, t(start)).unwrap();
    let buckets = store.summaries(&ranges).unwrap();
    assert_eq!(buckets.len(), 31);
    assert_eq!(ranges[7].end - ranges[7].start, 23.0 * 3600.0);
    assert_eq!(ranges[21].end - ranges[21].start, 25.0 * 3600.0);
    for (bucket, range) in buckets.iter().zip(&ranges) {
        let mut expected = store.summary(range.start, range.end).unwrap();
        expected.key_counts.clear();
        assert_eq!(bucket.start, range.start);
        assert_eq!(bucket.summary, expected);
        assert_eq!(bucket.summary.key_presses, 2);
        assert_eq!(bucket.summary.total_active_seconds, 60);
    }
    assert_eq!(
        buckets.iter().map(|b| b.summary.key_presses).sum::<i64>(),
        62
    );
}
#[test]
fn summaries_leap_february_keeps_29_days_and_month_end_exclusive() {
    let mut store = mem();
    let start = 1_706_745_600.0; // 2024-02-01 00:00 UTC
    let end = start + 29.0 * 86400.0;
    assert_eq!(iso8601(end), "2024-03-01T00:00:00Z");
    let ranges: Vec<_> = (0..29)
        .map(|d| AggregationRange {
            start: start + d as f64 * 86400.0,
            end: start + (d + 1) as f64 * 86400.0,
        })
        .collect();
    let mut samples: Vec<_> = ranges
        .iter()
        .map(|r| Sample {
            timestamp: r.start,
            kind: Kind::KeyPress,
            key_label: Some("A".into()),
            distance_points: 0.0,
            scroll_delta: 0.0,
        })
        .collect();
    samples.push(Sample {
        timestamp: end,
        kind: Kind::KeyPress,
        key_label: Some("B".into()),
        distance_points: 0.0,
        scroll_delta: 0.0,
    });
    store.ingest(samples, end).unwrap();
    let buckets = store.summaries(&ranges).unwrap();
    assert_eq!(buckets.len(), 29);
    assert!(buckets.iter().all(|b| b.summary.key_presses == 1));
    let whole = store.summaries(&[AggregationRange { start, end }]).unwrap();
    let mut expected = store.summary(start, end).unwrap();
    expected.key_counts.clear();
    assert_eq!(whole[0].summary, expected);
    assert_eq!(expected.key_presses, 29);
    assert_eq!(expected.total_active_seconds, 29 * 30);
}
#[test]
fn summaries_gaps_empty_cells_partial_end_and_no_histogram_reads_or_writes() {
    let mut store = mem();
    store
        .ingest(
            vec![
                key(0.0, "A"),
                key(60.0, "B"),
                key(120.0, "C"),
                key(130.0, "D"),
                key(86400.0, "E"),
            ],
            t(86410.0),
        )
        .unwrap();
    let ranges = [
        timeline_range(0.0, 60.0),
        timeline_range(120.0, 125.9),
        timeline_range(180.0, 240.0),
        timeline_range(86400.0, 86410.5),
    ];
    let expected: Vec<_> = ranges
        .iter()
        .map(|r| {
            let mut s = store.summary(r.start, r.end).unwrap();
            s.key_counts.clear();
            s
        })
        .collect();
    store.db.execute_batch("DROP TABLE key_histograms").unwrap();
    let before = store.db.total_changes();
    let buckets = store.summaries(&ranges).unwrap();
    for (bucket, summary) in buckets.iter().zip(expected) {
        assert_eq!(bucket.summary, summary);
    }
    // Counts remain natural-minute precision; masks clip complete seconds at the exact end.
    assert_eq!(buckets[1].summary.key_presses, 2);
    assert_eq!(buckets[1].summary.total_active_seconds, 5);
    assert_eq!(buckets[2].summary, Summary::default());
    assert_eq!(buckets[3].summary.total_active_seconds, 10);
    assert_eq!(store.db.total_changes(), before);
    assert_eq!(
        store
            .db
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
}
#[test]
fn summaries_limits_do_not_relax_timeline_limits() {
    let store = mem();
    let days = |n| n as f64 * 86400.0;
    let maximum: Vec<_> = (0..32)
        .map(|d| timeline_range(days(d), days(d + 1)))
        .collect();
    assert_eq!(store.summaries(&maximum).unwrap().len(), 32);
    let too_many: Vec<_> = (0..33)
        .map(|d| timeline_range(days(d), days(d + 1)))
        .collect();
    assert!(store.summaries(&too_many).is_err());
    assert!(store.summaries(&[timeline_range(0.0, days(32))]).is_ok());
    assert!(store
        .summaries(&[timeline_range(0.0, days(32) + 0.1)])
        .is_err());
    assert!(store
        .summaries(&[
            timeline_range(0.0, 60.0),
            timeline_range(days(400) - 60.0, days(400))
        ])
        .is_ok());
    assert!(store
        .summaries(&[
            timeline_range(0.0, 60.0),
            timeline_range(days(400), days(400) + 0.1)
        ])
        .is_err());
    for ranges in [
        vec![timeline_range(60.0, 120.0), timeline_range(0.0, 60.0)],
        vec![timeline_range(0.0, 61.0), timeline_range(60.0, 120.0)],
        vec![timeline_range(0.0, 0.0)],
        vec![timeline_range(0.0, -1.0)],
        vec![timeline_range(1.0, 60.0)],
        vec![AggregationRange {
            start: -60.0,
            end: 0.0,
        }],
        vec![AggregationRange {
            start: f64::NAN,
            end: 60.0,
        }],
        vec![AggregationRange {
            start: 0.0,
            end: f64::INFINITY,
        }],
    ] {
        assert!(store.summaries(&ranges).is_err());
    }
    assert!(store.summaries(&[]).unwrap().is_empty());
    assert!(store.timeline(&[timeline_range(0.0, 7200.1)]).is_err());
    assert!(store
        .timeline(&[
            timeline_range(0.0, 60.0),
            timeline_range(days(8), days(8) + 60.0)
        ])
        .is_err());
}
#[test]
fn summaries_json_contract_matches_timeline_for_identical_ranges() {
    let mut store = mem();
    store
        .ingest(
            vec![
                key(0.0, "A"),
                key(60.0, "B"),
                event(61.0, Kind::Scroll, 0.0, 2.5),
            ],
            t(65.0),
        )
        .unwrap();
    let ranges = json!([{"start":t(0.0),"end":t(60.0)},{"start":t(60.0),"end":t(65.5)},{"start":t(120.0),"end":t(180.0)}]);
    let summaries = store
        .request(&json!({"op":"summaries","ranges":ranges}).to_string())
        .unwrap();
    let timeline = store
        .request(&json!({"op":"timeline","ranges":ranges}).to_string())
        .unwrap();
    assert_eq!(summaries, timeline);
    assert_eq!(
        summaries[2]["summary"],
        serde_json::to_value(Summary::default()).unwrap()
    );
}
