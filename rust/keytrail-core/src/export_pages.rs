//! Bounded, seek-based CSV export. The persistent identity and transactional
//! revision are independent of collector/replica sync numbering.
use super::*;
use std::fmt::Write;

const JSON_BUDGET: usize = 1024 * 1024;
const MAX_REVISION: i64 = 9_007_199_254_740_991;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(super) struct Snapshot {
    id: String,
    revision: i64,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Cursor {
    snapshot: Snapshot,
    start: f64,
    end: f64,
    after_minute: i64,
}
pub(super) struct Totals {
    snapshot: Snapshot,
    start: f64,
    end: f64,
    count: i64,
}
pub(super) fn default_limit() -> usize {
    500
}

pub(super) fn initialize(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS export_snapshot(id INTEGER PRIMARY KEY CHECK(id=1),source_id TEXT NOT NULL,revision INTEGER NOT NULL);INSERT OR IGNORE INTO export_snapshot VALUES(1,lower(hex(randomblob(16))),0);")?;
    // These triggers also run from another connection's ATTACH transaction and
    // on replicaApply, whose source revisions must not be used as export clocks.
    // A no-op UPDATE deliberately invalidates a page; rollback undoes its tick.
    for table in ["minutes", "key_histograms", "rhythm_minutes"] {
        for operation in ["INSERT", "UPDATE", "DELETE"] {
            db.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS export_{table}_{} AFTER {operation} ON {table} BEGIN SELECT CASE WHEN (SELECT revision FROM export_snapshot WHERE id=1)>={MAX_REVISION} THEN RAISE(ABORT,'export snapshot revision exhausted') END;UPDATE export_snapshot SET revision=revision+1 WHERE id=1;END;",operation.to_lowercase()))?;
        }
    }
    Ok(())
}

fn snapshot(db: &Connection) -> Result<Snapshot> {
    Ok(db.query_row(
        "SELECT source_id,revision FROM export_snapshot WHERE id=1",
        [],
        |r| {
            Ok(Snapshot {
                id: r.get(0)?,
                revision: r.get(1)?,
            })
        },
    )?)
}
fn check_snapshot(db: &Connection, expected: &Snapshot) -> Result<()> {
    if expected.id.len() != 32
        || !expected
            .id
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
        || !(0..=MAX_REVISION).contains(&expected.revision)
        || snapshot(db)? != *expected
    {
        return Err("export snapshot changed; restart the export".into());
    }
    Ok(())
}
pub(super) fn header(start: f64, end: f64) -> String {
    format!("# KeyTrail minute aggregates; timestamps=UTC; cursor_distance=display_points; scroll=absolute_event_delta; activity=complete_seconds; peak=natural_minute\r\n# range_start={}; range_end_exclusive={}\r\nminute_utc,key_presses,left_clicks,right_clicks,middle_clicks,cursor_distance_points,scroll_units,keyboard_active_seconds,mouse_active_seconds,total_active_seconds,key_histogram\r\n",iso8601(start),iso8601(end))
}
impl Store {
    pub(super) fn export_validate(&self, expected: &Snapshot) -> Result<()> {
        check_snapshot(&self.db, expected)
    }
    pub(super) fn export_page(
        &mut self,
        start: f64,
        end: f64,
        cursor: Option<Cursor>,
        limit: usize,
    ) -> Result<Value> {
        bounds(start, end)?;
        if start < 0.0 || !(1..=1000).contains(&limit) {
            return Err("exportPage requires nonnegative bounds and limit 1..1000".into());
        }
        let tx = self.db.unchecked_transaction()?;
        let current = snapshot(&tx)?;
        if let Some(c) = &cursor {
            check_snapshot(&tx, &c.snapshot)?;
            if c.start != start
                || c.end != end
                || c.after_minute < minute(start)
                || c.after_minute as f64 >= end
                || c.after_minute % 60 != 0
            {
                return Err("export cursor does not belong to this range".into());
            }
        }
        let total = if let Some(cached) = self
            .export_totals
            .as_ref()
            .filter(|v| v.start == start && v.end == end && v.snapshot == current)
        {
            cached.count
        } else {
            let count = if start == end {
                0
            } else {
                tx.query_row(
                    "SELECT COUNT(*) FROM minutes WHERE minute>=? AND minute<?",
                    params![minute(start), end],
                    |r| r.get::<_, i64>(0),
                )?
            };
            self.export_totals = Some(Totals {
                snapshot: current.clone(),
                start,
                end,
                count,
            });
            count
        };
        let header = header(start, end);
        let mut csv = String::new();
        // Account for actual JSON string escaping, not just raw CSV UTF-8 bytes.
        // The fixed envelope/cursor is <1 KiB; reserve 4 KiB then check the entire
        // encoded result once more before returning it.
        let mut encoded_bytes = 4096 + serde_json::to_string(&header)?.len() + 2;
        let mut row_count = 0usize;
        let mut last_minute = None;
        let mut more = false;
        if start < end {
            let lower = cursor
                .as_ref()
                .map_or(minute(start), |c| c.after_minute + 60);
            let mut minutes=tx.prepare_cached("SELECT minute,keys,left_clicks,right_clicks,middle_clicks,distance,scroll,keyboard_mask,mouse_mask FROM minutes WHERE minute>=? AND minute<? ORDER BY minute LIMIT ?")?;
            let mut rows = minutes.query(params![lower, end, (limit + 1) as i64])?;
            // Two ordered cursors: no histogram query for each exported minute.
            let mut histograms=tx.prepare_cached("SELECT minute,label,count FROM key_histograms WHERE minute>=? AND minute<? ORDER BY minute,label")?;
            let mut hist_rows = histograms.query(params![lower, end])?;
            let mut next_hist = hist_rows.next()?;
            while let Some(row) = rows.next()? {
                if row_count >= limit {
                    more = true;
                    break;
                }
                let m: i64 = row.get(0)?;
                let summary = minute_summary(row, start, end)?;
                let mut histogram = String::new();
                while let Some(h) = next_hist {
                    let hm: i64 = h.get(0)?;
                    if hm > m {
                        break;
                    }
                    if hm == m {
                        let label = h.get_ref(1)?.as_str()?;
                        if histogram.len() + label.len().saturating_mul(2) + 32 > JSON_BUDGET {
                            return Err("single CSV row exceeds export page budget".into());
                        }
                        if !histogram.is_empty() {
                            histogram.push(';');
                        }
                        write!(
                            &mut histogram,
                            "{}:{}",
                            label.replace('"', "\"\""),
                            h.get::<_, i64>(2)?
                        )?;
                    }
                    next_hist = hist_rows.next()?;
                }
                let line = format!(
                    "{},{},{},{},{},{},{},{},{},{},\"{}\"\r\n",
                    iso8601(m as f64),
                    summary.key_presses,
                    summary.left_clicks,
                    summary.right_clicks,
                    summary.middle_clicks,
                    summary.mouse_distance_points,
                    summary.scroll_units,
                    summary.keyboard_active_seconds,
                    summary.mouse_active_seconds,
                    summary.total_active_seconds,
                    histogram
                );
                let line_bytes = serde_json::to_string(&line)?.len() - 2;
                if encoded_bytes + line_bytes > JSON_BUDGET {
                    if row_count == 0 {
                        return Err("single CSV row exceeds export page budget".into());
                    }
                    more = true;
                    break;
                }
                encoded_bytes += line_bytes;
                csv.push_str(&line);
                row_count += 1;
                last_minute = Some(m);
            }
        }
        let next = if more {
            Some(Cursor {
                snapshot: current.clone(),
                start,
                end,
                after_minute: last_minute.ok_or("export page did not advance")?,
            })
        } else {
            None
        };
        let value = json!({"header":header,"csv":csv,"rowCount":row_count,"totalRows":total,"snapshot":current,"nextCursor":next,"hasMore":more});
        if serde_json::to_vec(&value)?.len() > JSON_BUDGET {
            return Err("export page exceeds JSON byte budget".into());
        }
        tx.commit()?;
        Ok(value)
    }
}
