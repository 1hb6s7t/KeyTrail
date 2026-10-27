//! Opaque authenticated-envelope storage. This module never receives a decryption key.
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::{path::Path, time::Duration};
type Result<T> = std::result::Result<T, String>;
const MAX_REVISION: u64 = 9_007_199_254_740_991;
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Metadata {
    id: String,
    timestamp: f64,
    #[serde(rename = "applicationBundleID")]
    application_bundle_id: String,
    character_count: u64,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    version: u32,
    metadata: Metadata,
    sealed_box_base64: String,
    aad_base64: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Change {
    revision: u64,
    id: String,
    deleted: bool,
    record: Option<Record>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Query {
    start: f64,
    end: f64,
    #[serde(default)]
    offset: u64,
    #[serde(default = "default_limit")]
    limit: u64,
}
fn default_limit() -> u64 {
    50
}
fn uuid(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn base64(input: &str, limit: usize) -> Result<Vec<u8>> {
    if input.len() > limit.div_ceil(3) * 4 || input.len() % 4 != 0 {
        return Err("invalid bounded base64 length".into());
    }
    fn digit(c: u8) -> Result<u32> {
        Ok(match c {
            b'A'..=b'Z' => (c - b'A') as u32,
            b'a'..=b'z' => (c - b'a' + 26) as u32,
            b'0'..=b'9' => (c - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            _ => return Err("invalid base64 alphabet".into()),
        })
    }
    let mut output = Vec::with_capacity(input.len() / 4 * 3);
    for (i, q) in input.as_bytes().chunks_exact(4).enumerate() {
        let padding = if q[2] == b'=' {
            if q[3] != b'=' {
                return Err("invalid base64 padding".into());
            }
            2
        } else if q[3] == b'=' {
            1
        } else {
            0
        };
        if padding > 0 && i + 1 != input.len() / 4 {
            return Err("base64 padding is not final".into());
        }
        let a = digit(q[0])?;
        let b = digit(q[1])?;
        let c = if padding == 2 { 0 } else { digit(q[2])? };
        let d = if padding > 0 { 0 } else { digit(q[3])? };
        if (padding == 2 && b & 15 != 0) || (padding == 1 && c & 3 != 0) {
            return Err("noncanonical base64 padding bits".into());
        }
        let bits = (a << 18) | (b << 12) | (c << 6) | d;
        output.push((bits >> 16) as u8);
        if padding < 2 {
            output.push((bits >> 8) as u8);
        }
        if padding == 0 {
            output.push(bits as u8);
        }
    }
    if output.len() > limit {
        return Err("decoded envelope too large".into());
    }
    Ok(output)
}
fn validate(change: &Change) -> Result<()> {
    if change.revision == 0 || change.revision > MAX_REVISION || !uuid(&change.id) {
        return Err("invalid text revision or UUID".into());
    }
    if change.deleted {
        return if change.record.is_none() {
            Ok(())
        } else {
            Err("text tombstone contains a record".into())
        };
    }
    let record = change
        .record
        .as_ref()
        .ok_or("text update requires ciphertext")?;
    let meta = &record.metadata;
    if record.version != 1
        || meta.id != change.id
        || !meta.timestamp.is_finite()
        || !(0.0..1e12).contains(&meta.timestamp)
        || !(1..=16_384).contains(&meta.character_count)
        || meta.application_bundle_id.is_empty()
        || meta.application_bundle_id.len() > 255
        || !meta
            .application_bundle_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || [b'.', b'-', b'_'].contains(&b))
    {
        return Err("invalid encrypted text metadata".into());
    }
    let sealed = base64(&record.sealed_box_base64, 262_144 + 28)?;
    if sealed.len() < 29 {
        return Err("AES-GCM envelope lacks nonce/body/tag".into());
    }
    let aad = base64(&record.aad_base64, 3072)?;
    let authenticated: Metadata =
        serde_json::from_slice(&aad).map_err(|_| "invalid text AAD metadata")?;
    if authenticated != *meta {
        return Err("AAD metadata differs from envelope".into());
    }
    // Only the client with its explicit key can verify the GCM tag/decrypt the body.
    Ok(())
}
pub(crate) struct TextReplica {
    db: Connection,
    identity: String,
}
impl TextReplica {
    pub(crate) fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            #[cfg(unix)]
            std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))
                .map_err(|e| e.to_string())?;
        }
        let mut db = Connection::open(path).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
        db.busy_timeout(Duration::from_secs(3))
            .map_err(|e| e.to_string())?;
        db.execute_batch(
            "PRAGMA secure_delete=ON;PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;",
        )
        .map_err(|e| e.to_string())?;
        let tx = db.transaction().map_err(|e| e.to_string())?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS text_state(id INTEGER PRIMARY KEY CHECK(id=1),identity TEXT NOT NULL,cursor INTEGER NOT NULL);CREATE TABLE IF NOT EXISTS text_items(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,time REAL,deleted INTEGER NOT NULL,record TEXT);CREATE INDEX IF NOT EXISTS text_query ON text_items(deleted,time,id);").map_err(|e|e.to_string())?;
        let has_count: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM pragma_table_info('text_items') WHERE name='character_count')",[],|r|r.get(0)).map_err(|e|e.to_string())?;
        if !has_count {
            tx.execute_batch("ALTER TABLE text_items ADD COLUMN character_count INTEGER NOT NULL DEFAULT 0; UPDATE text_items SET character_count=COALESCE(json_extract(record,'$.metadata.characterCount'),0);").map_err(|e|e.to_string())?;
        }
        let existing: Option<String> = tx
            .query_row("SELECT identity FROM text_state WHERE id=1", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|e| e.to_string())?;
        let identity = match existing {
            Some(value) => value,
            None => {
                let value = super::replica_id()?;
                tx.execute("INSERT INTO text_state VALUES(1,?,0)", [&value])
                    .map_err(|e| e.to_string())?;
                value
            }
        };
        tx.commit().map_err(|e| e.to_string())?;
        Ok(Self { db, identity })
    }
    pub(crate) fn identity(&self) -> &str {
        &self.identity
    }
    pub(crate) fn cursor(&self) -> Result<u64> {
        self.db
            .query_row("SELECT cursor FROM text_state WHERE id=1", [], |r| r.get(0))
            .map_err(|e| e.to_string())
    }
    pub(crate) fn apply(&mut self, changes: Value) -> Result<Value> {
        let changes: Vec<Change> = serde_json::from_value(changes).map_err(|e| e.to_string())?;
        if changes.len() > 1000 {
            return Err("at most 1000 encrypted text changes per batch".into());
        }
        for change in &changes {
            validate(change)?;
        }
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|e| e.to_string())?;
        let mut applied = 0;
        let mut ignored = 0;
        let mut cursor: u64 = tx
            .query_row("SELECT cursor FROM text_state WHERE id=1", [], |r| r.get(0))
            .map_err(|e| e.to_string())?;
        for change in changes {
            cursor = cursor.max(change.revision);
            let previous: Option<u64> = tx
                .query_row(
                    "SELECT revision FROM text_items WHERE id=?",
                    [&change.id],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|e| e.to_string())?;
            if previous.is_some_and(|v| v >= change.revision) {
                ignored += 1;
                continue;
            }
            let time = change.record.as_ref().map(|r| r.metadata.timestamp);
            let record = change
                .record
                .as_ref()
                .map(serde_json::to_string)
                .transpose()
                .map_err(|e| e.to_string())?;
            let count = change
                .record
                .as_ref()
                .map_or(0, |r| r.metadata.character_count);
            tx.execute("INSERT INTO text_items(id,revision,time,deleted,record,character_count) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,time=excluded.time,deleted=excluded.deleted,record=excluded.record,character_count=excluded.character_count",params![change.id,change.revision,time,change.deleted,record,count]).map_err(|e|e.to_string())?;
            applied += 1;
        }
        tx.execute("UPDATE text_state SET cursor=? WHERE id=1", [cursor])
            .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
        Ok(json!({"applied":applied,"ignored":ignored,"cursor":cursor}))
    }
    pub(crate) fn query(&self, request: Value) -> Result<Value> {
        let query: Query = serde_json::from_value(request).map_err(|e| e.to_string())?;
        if !query.start.is_finite()
            || !query.end.is_finite()
            || query.start < 0.0
            || query.end < query.start
            || query.end >= 1e12
            || query.offset > MAX_REVISION
            || !(1..=200).contains(&query.limit)
        {
            return Err("invalid encrypted-text query range/page".into());
        }
        let (total,total_characters): (u64,u64) = self
            .db
            .query_row(
                "SELECT COUNT(*),COALESCE(SUM(character_count),0) FROM text_items WHERE deleted=0 AND time>=? AND time<?",
                params![query.start, query.end],
                |r| Ok((r.get(0)?,r.get(1)?)),
            )
            .map_err(|e| e.to_string())?;
        let mut stmt=self.db.prepare_cached("SELECT record FROM text_items WHERE deleted=0 AND time>=? AND time<? ORDER BY time,id LIMIT ? OFFSET ?").map_err(|e|e.to_string())?;
        let mut rows = stmt
            .query(params![query.start, query.end, query.limit, query.offset])
            .map_err(|e| e.to_string())?;
        let mut records = vec![];
        let mut bytes = 0;
        while let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let text: String = row.get(0).map_err(|e| e.to_string())?;
            if !records.is_empty() && bytes + text.len() > 8 * 1024 * 1024 - 4096 {
                break;
            }
            bytes += text.len();
            records.push(serde_json::from_str::<Value>(&text).map_err(|e| e.to_string())?);
        }
        let next = query.offset + records.len() as u64;
        let more = next < total;
        Ok(
            json!({"records":records,"offset":query.offset,"nextOffset":if more{Some(next)}else{None},"hasMore":more,"total":total,"totalCharacters":total_characters}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            static N: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "keytrail-text-server-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::Relaxed)
            ));
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn encode(bytes: &[u8]) -> String {
        const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for q in bytes.chunks(3) {
            let bits = ((q[0] as u32) << 16)
                | ((q.get(1).copied().unwrap_or(0) as u32) << 8)
                | q.get(2).copied().unwrap_or(0) as u32;
            out.push(A[((bits >> 18) & 63) as usize] as char);
            out.push(A[((bits >> 12) & 63) as usize] as char);
            out.push(if q.len() > 1 {
                A[((bits >> 6) & 63) as usize] as char
            } else {
                '='
            });
            out.push(if q.len() > 2 {
                A[(bits & 63) as usize] as char
            } else {
                '='
            });
        }
        out
    }
    fn id(n: u64) -> String {
        format!("00000000-0000-4000-8000-{n:012x}")
    }
    fn update(rev: u64, n: u64, time: f64) -> Value {
        let metadata = json!({"id":id(n),"timestamp":time,"applicationBundleID":"fixture.editor","characterCount":1});
        json!({"revision":rev,"id":id(n),"deleted":false,"record":{"version":1,"metadata":metadata,"sealedBoxBase64":encode(&[7;29]),"aadBase64":encode(metadata.to_string().as_bytes())}})
    }
    #[test]
    fn opaque_roundtrip_exact_aad_half_open_paging_and_account_isolation() {
        let f = Fixture::new();
        let mut a = TextReplica::open(&f.0.join("a/text.sqlite")).unwrap();
        let b = TextReplica::open(&f.0.join("b/text.sqlite")).unwrap();
        let values = json!([update(1, 1, 10.25), update(2, 2, 10.5), update(3, 3, 11.0)]);
        assert_eq!(a.apply(values.clone()).unwrap()["applied"], 3);
        let page = a
            .query(json!({"start":10.25,"end":11.0,"limit":1}))
            .unwrap();
        assert_eq!(page["total"], 2);
        assert_eq!(page["totalCharacters"], 2);
        assert_eq!(page["hasMore"], true);
        assert_eq!(page["records"][0], values[0]["record"]);
        assert_eq!(
            a.query(json!({"start":10.25,"end":11.0,"limit":1,"offset":1}))
                .unwrap()["records"][0],
            values[1]["record"]
        );
        assert_eq!(b.query(json!({"start":0,"end":100})).unwrap()["total"], 0);
    }
    #[test]
    fn tombstones_revision_cursor_and_identity_survive_restart_and_rebuild() {
        let f = Fixture::new();
        let path = f.0.join("text.sqlite");
        let mut a = TextReplica::open(&path).unwrap();
        let identity = a.identity().to_owned();
        a.apply(json!([update(3, 1, 1.0)])).unwrap();
        assert_eq!(
            a.apply(json!([update(3, 1, 1.0), update(2, 1, 1.0)]))
                .unwrap()["ignored"],
            2
        );
        a.apply(json!([{"revision":5,"id":id(1),"deleted":true,"record":null}]))
            .unwrap();
        drop(a);
        let mut a = TextReplica::open(&path).unwrap();
        assert_eq!(a.identity(), identity);
        assert_eq!(a.cursor().unwrap(), 5);
        assert_eq!(a.apply(json!([update(4, 1, 1.0)])).unwrap()["ignored"], 1);
        assert_eq!(a.query(json!({"start":0,"end":10})).unwrap()["total"], 0);
        drop(a);
        std::fs::remove_file(&path).unwrap();
        assert_ne!(TextReplica::open(&path).unwrap().identity(), identity);
    }
    #[test]
    fn malformed_oversize_plaintext_or_mismatched_metadata_is_atomic() {
        let f = Fixture::new();
        let mut a = TextReplica::open(&f.0.join("text.sqlite")).unwrap();
        let mut bad = update(2, 2, 2.0);
        bad["record"]["metadata"]["characterCount"] = json!(2);
        assert!(a.apply(json!([update(1, 1, 1.0), bad])).is_err());
        assert_eq!(a.cursor().unwrap(), 0);
        let mut bad = update(1, 1, 1.0);
        bad["record"]["plaintext"] = json!("never accepted");
        assert!(a.apply(json!([bad])).is_err());
        for value in ["!AAA", "====", "A===", "AB==", "AAA=AAAA"] {
            let mut bad = update(1, 1, 1.0);
            bad["record"]["sealedBoxBase64"] = json!(value);
            assert!(a.apply(json!([bad])).is_err());
        }
        let mut bad = update(1, 1, 1.0);
        bad["record"]["sealedBoxBase64"] = json!("A".repeat(400_000));
        assert!(a.apply(json!([bad])).is_err());
        assert_eq!(a.query(json!({"start":0,"end":10})).unwrap()["total"], 0);
    }
    #[test]
    fn sql_failure_rolls_back_ciphertext_and_ack_cursor() {
        let f = Fixture::new();
        let mut a = TextReplica::open(&f.0.join("text.sqlite")).unwrap();
        a.db.execute_batch(&format!("CREATE TRIGGER fail BEFORE INSERT ON text_items WHEN NEW.id='{}' BEGIN SELECT RAISE(FAIL,'fixture');END",id(2))).unwrap();
        assert!(a
            .apply(json!([update(1, 1, 1.0), update(2, 2, 2.0)]))
            .is_err());
        assert_eq!(a.cursor().unwrap(), 0);
        assert_eq!(a.query(json!({"start":0,"end":10})).unwrap()["total"], 0);
    }
    #[test]
    fn encrypted_pages_are_bounded_by_bytes_as_well_as_record_count() {
        let f = Fixture::new();
        let mut a = TextReplica::open(&f.0.join("text.sqlite")).unwrap();
        let cipher = encode(&vec![7; 250_000]);
        let values: Vec<_> = (0..40)
            .map(|i| {
                let mut value = update(i + 1, i + 1, i as f64);
                value["record"]["sealedBoxBase64"] = json!(cipher);
                value
            })
            .collect();
        a.apply(json!(values)).unwrap();
        let page = a.query(json!({"start":0,"end":100,"limit":200})).unwrap();
        let count = page["records"].as_array().unwrap().len();
        assert!(count > 0 && count < 40);
        assert_eq!(page["nextOffset"], count);
        assert_eq!(page["hasMore"], true);
        assert!(page.to_string().len() < 8 * 1024 * 1024);
        let rest = a
            .query(json!({"start":0,"end":100,"limit":200,"offset":count}))
            .unwrap();
        assert_eq!(count + rest["records"].as_array().unwrap().len(), 40);
        assert_eq!(rest["hasMore"], false);
    }
}
