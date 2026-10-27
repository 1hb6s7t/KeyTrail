use super::*;

#[test]
fn multi_decade_trend_streams_three_hundred_thousand_hours_into_bounded_cells() {
    let mut s = Store::open(":memory:").unwrap();
    s.db.execute_batch("BEGIN;WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<299999) INSERT INTO minutes(minute,keys,keyboard_mask) SELECT x*3600,x%7+1,1 FROM n;COMMIT;DROP TABLE key_histograms;").unwrap();
    let end = 300000.0 * 3600.0;
    let year = 365.0 * 86400.0;
    let ranges: Vec<_> = (0..35)
        .filter_map(|n| {
            let start = n as f64 * year;
            (start < end).then_some(AggregationRange {
                start,
                end: ((n + 1) as f64 * year).min(end),
            })
        })
        .collect();
    let values = s.trend(&ranges).unwrap();
    assert_eq!(values.len(), 35);
    assert_eq!(
        values.iter().map(|b| b.summary.key_presses).sum::<i64>(),
        (0..300000i64).map(|n| n % 7 + 1).sum::<i64>()
    );
    assert_eq!(
        values.iter().map(|b| b.summary.minute_count).sum::<u64>(),
        300000
    );
    assert_eq!(
        values
            .iter()
            .map(|b| b.summary.keyboard_active_seconds)
            .sum::<u64>(),
        300000
    );
    assert_eq!(
        values.iter().map(|b| b.summary.peak_keys_per_minute).max(),
        Some(7)
    );
    assert!(values.iter().all(|b| b.summary.key_counts.is_empty()));
    let bytes = serde_json::to_vec(&values).unwrap();
    assert!(bytes.len() < 20000);
    assert_eq!(
        s.db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    // Public request retains zero buckets and partial-second activity semantics.
    let value = s
        .request(r#"{"op":"trend","ranges":[{"start":0,"end":0.5},{"start":60,"end":120}]}"#)
        .unwrap();
    assert_eq!(value[0]["summary"]["keyPresses"], 1);
    assert_eq!(value[0]["summary"]["totalActiveSeconds"], 0);
    assert_eq!(value[1]["summary"]["minuteCount"], 0);
}

#[test]
fn trend_has_independent_limits_without_expanding_existing_queries() {
    let s = Store::open(":memory:").unwrap();
    let cells: Vec<_> = (0..400)
        .map(|n| AggregationRange {
            start: n as f64 * 60.0,
            end: (n + 1) as f64 * 60.0,
        })
        .collect();
    assert_eq!(s.trend(&cells).unwrap().len(), 400);
    assert!(s.timeline(&cells).is_err());
    assert!(s.summaries(&cells).is_err());
    let mut too_many = cells.clone();
    too_many.push(AggregationRange {
        start: 24000.0,
        end: 24060.0,
    });
    assert!(s.trend(&too_many).is_err());
    assert!(s
        .trend(&[AggregationRange {
            start: 0.0,
            end: 367.0 * 86400.0
        }])
        .is_ok());
    for ranges in [
        vec![AggregationRange {
            start: 0.0,
            end: 367.0 * 86400.0 + 0.1,
        }],
        vec![
            AggregationRange {
                start: 0.0,
                end: 60.0,
            },
            AggregationRange {
                start: 100.0 * 366.0 * 86400.0,
                end: 100.0 * 366.0 * 86400.0 + 60.0,
            },
        ],
        vec![
            AggregationRange {
                start: 60.0,
                end: 120.0,
            },
            AggregationRange {
                start: 0.0,
                end: 60.0,
            },
        ],
        vec![
            AggregationRange {
                start: 0.0,
                end: 120.0,
            },
            AggregationRange {
                start: 60.0,
                end: 180.0,
            },
        ],
        vec![AggregationRange {
            start: 1.0,
            end: 60.0,
        }],
        vec![AggregationRange {
            start: -60.0,
            end: 60.0,
        }],
    ] {
        assert!(s.trend(&ranges).is_err());
    }
    assert!(s.trend(&[]).unwrap().is_empty());
}
