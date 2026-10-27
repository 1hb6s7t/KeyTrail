//! Portable encrypted archive and durable text journal. No plaintext indexes or stored keys.
use aes_gcm::{
    aead::{rand_core::RngCore, Aead, KeyInit, OsRng, Payload},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::Path;
use unicode_segmentation::UnicodeSegmentation;
type Result<T> = std::result::Result<T, String>;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Metadata {
    #[serde(rename = "applicationBundleID")]
    pub app: String,
    #[serde(rename = "characterCount")]
    pub characters: u64,
    pub id: String,
    pub timestamp: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EncryptedRecord {
    pub version: u32,
    pub metadata: Metadata,
    pub sealed_box_base64: String,
    pub aad_base64: String,
}
pub fn random_key() -> [u8; 32] {
    let mut k = [0u8; 32];
    OsRng.fill_bytes(&mut k);
    k
}
fn uuid() -> String {
    let mut b = [0u8; 16];
    OsRng.fill_bytes(&mut b);
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    let h: String = b.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    )
}
fn validate_id(id: &str) -> Result<()> {
    if id.len() != 36
        || !id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
    {
        return Err("A canonical record UUID is required".into());
    }
    Ok(())
}
fn validate_meta(m: &Metadata) -> Result<()> {
    let id = &m.id;
    let valid = id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        });
    if !valid
        || !m.timestamp.is_finite()
        || !(0.0..1e12).contains(&m.timestamp)
        || !(1..=16384).contains(&m.characters)
        || m.app.is_empty()
        || m.app.len() > 255
        || !m
            .app
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
    {
        return Err("Invalid authenticated text metadata".into());
    }
    Ok(())
}
pub fn decrypt(key: &[u8; 32], record: &EncryptedRecord) -> Result<String> {
    if record.version != 1
        || record.sealed_box_base64.len() > 400000
        || record.aad_base64.len() > 4096
    {
        return Err("Invalid encrypted envelope".into());
    }
    validate_meta(&record.metadata)?;
    let aad = B64
        .decode(&record.aad_base64)
        .map_err(|_| "Invalid AAD base64")?;
    let meta: Metadata = serde_json::from_slice(&aad).map_err(|_| "Invalid AAD metadata")?;
    if meta != record.metadata {
        return Err("Authenticated metadata differs from outer envelope".into());
    }
    let combined = B64
        .decode(&record.sealed_box_base64)
        .map_err(|_| "Invalid ciphertext base64")?;
    if combined.len() < 29 {
        return Err("Invalid nonce/body/tag".into());
    };
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| "Invalid key")?;
    let plain = cipher
        .decrypt(
            Nonce::from_slice(&combined[..12]),
            Payload {
                msg: &combined[12..],
                aad: &aad,
            },
        )
        .map_err(|_| "AES-GCM authentication failed")?;
    if plain.len() > 262144 {
        return Err("Text exceeds byte limit".into());
    }
    let text = String::from_utf8(plain).map_err(|_| "Invalid UTF-8")?;
    if text.graphemes(true).count() as u64 != meta.characters {
        return Err("Authenticated character count differs".into());
    }
    Ok(text)
}
pub struct TextArchive {
    pub(crate) db: Connection,
    key: [u8; 32],
    last_query: std::cell::Cell<Option<(f64, f64)>>,
}
impl TextArchive {
    pub fn open(path: &Path, key: [u8; 32]) -> Result<Self> {
        let db = Connection::open(path).map_err(|e| e.to_string())?;
        db.busy_timeout(std::time::Duration::from_secs(3))
            .map_err(|e| e.to_string())?;
        db.execute_batch("PRAGMA secure_delete=ON;PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;CREATE TABLE IF NOT EXISTS text_records(id TEXT PRIMARY KEY,time REAL NOT NULL,char_count INTEGER NOT NULL,record TEXT NOT NULL);CREATE INDEX IF NOT EXISTS text_time ON text_records(time,id);CREATE TABLE IF NOT EXISTS text_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,key_check TEXT);INSERT OR IGNORE INTO text_state VALUES(1,0,NULL);CREATE TABLE IF NOT EXISTS text_journal(id TEXT PRIMARY KEY,revision INTEGER UNIQUE NOT NULL,deleted INTEGER NOT NULL,record TEXT);").map_err(|e|e.to_string())?;
        let archive = Self {
            db,
            key,
            last_query: std::cell::Cell::new(None),
        };
        let check: Option<String> = archive
            .db
            .query_row("SELECT key_check FROM text_state WHERE id=1", [], |r| {
                r.get(0)
            })
            .map_err(|e| e.to_string())?;
        if let Some(check) = check {
            let r: EncryptedRecord =
                serde_json::from_str(&check).map_err(|_| "Invalid archive key check")?;
            if decrypt(&key, &r)? != "KeyTrail archive key verified" {
                return Err("Archive key check differs".into());
            }
        } else {
            let existing: u64 = archive
                .db
                .query_row("SELECT COUNT(*) FROM text_records", [], |r| r.get(0))
                .map_err(|e| e.to_string())?;
            if existing > 0 {
                return Err(
                    "Archive key-check missing while ciphertext exists; recovery required".into(),
                );
            }
            let record = archive.encrypt(
                "KeyTrail archive key verified",
                0.0,
                "com.keytrail.keycheck",
            )?;
            archive
                .db
                .execute(
                    "UPDATE text_state SET key_check=? WHERE id=1",
                    [serde_json::to_string(&record).unwrap()],
                )
                .map_err(|e| e.to_string())?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
                .map_err(|e| e.to_string())?;
        }
        Ok(archive)
    }
    fn encrypt(&self, text: &str, time: f64, app: &str) -> Result<EncryptedRecord> {
        let characters = text.graphemes(true).count();
        if text.len() > 262144
            || !(1..=16384).contains(&characters)
            || !time.is_finite()
            || !(0.0..1e12).contains(&time)
            || app.is_empty()
            || app.len() > 255
            || !app
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
        {
            return Err("Invalid bounded committed text metadata".into());
        }
        let metadata = Metadata {
            app: app.into(),
            characters: characters as u64,
            id: uuid(),
            timestamp: (time * 1000.0).round() / 1000.0,
        };
        let aad = serde_json::to_vec(&metadata).map_err(|e| e.to_string())?;
        let mut nonce = [0u8; 12];
        OsRng.fill_bytes(&mut nonce);
        let cipher = Aes256Gcm::new_from_slice(&self.key).map_err(|_| "Invalid key")?;
        let encrypted = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: text.as_bytes(),
                    aad: &aad,
                },
            )
            .map_err(|_| "Encryption failed")?;
        let mut combined = nonce.to_vec();
        combined.extend(encrypted);
        Ok(EncryptedRecord {
            version: 1,
            metadata,
            sealed_box_base64: B64.encode(combined),
            aad_base64: B64.encode(aad),
        })
    }
    pub fn append(&mut self, text: &str, time: f64, app: &str) -> Result<Metadata> {
        let record = self.encrypt(text, time, app)?;
        let encoded = serde_json::to_string(&record).map_err(|e| e.to_string())?;
        let tx = self.db.transaction().map_err(|e| e.to_string())?;
        tx.execute(
            "INSERT INTO text_records VALUES(?,?,?,?)",
            params![
                record.metadata.id,
                record.metadata.timestamp,
                record.metadata.characters,
                encoded
            ],
        )
        .map_err(|e| e.to_string())?;
        journal(&tx, &record.metadata.id, Some(&encoded))?;
        tx.commit().map_err(|e| e.to_string())?;
        Ok(record.metadata)
    }
    pub fn changes(&self, after: u64, limit: usize) -> Result<Value> {
        if after > 9007199254740991 || !(1..=100).contains(&limit) {
            return Err("Invalid text cursor/page".into());
        }
        let mut stmt=self.db.prepare("SELECT revision,id,deleted,record FROM text_journal WHERE revision>? ORDER BY revision LIMIT ?").map_err(|e|e.to_string())?;
        let rows = stmt
            .query_map(params![after, limit + 1], |r| {
                Ok((
                    r.get::<_, u64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, bool>(2)?,
                    r.get::<_, Option<String>>(3)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut changes = Vec::new();
        let mut bytes = 0;
        let mut more = false;
        for row in rows {
            let (revision, id, deleted, record) = row.map_err(|e| e.to_string())?;
            let cost = record.as_ref().map_or(128, |v| v.len() + 128);
            if changes.len() >= limit || (bytes + cost > 1024 * 1024 && !changes.is_empty()) {
                more = true;
                break;
            }
            bytes += cost;
            let record = record
                .map(|v| serde_json::from_str::<Value>(&v))
                .transpose()
                .map_err(|e| e.to_string())?;
            changes.push(json!({"revision":revision,"id":id,"deleted":deleted,"record":record}));
        }

        let cursor = changes
            .last()
            .and_then(|v| v["revision"].as_u64())
            .unwrap_or(after);
        Ok(json!({"changes":changes,"cursor":cursor,"hasMore":more}))
    }
    pub fn metadata_for_id(&self, id: &str) -> Result<Option<Metadata>> {
        validate_id(id)?;
        let encoded: Option<String> = self
            .db
            .query_row("SELECT record FROM text_records WHERE id=?", [id], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|e| e.to_string())?;
        encoded
            .map(|value| {
                serde_json::from_str::<EncryptedRecord>(&value)
                    .map(|r| r.metadata)
                    .map_err(|_| "Invalid encrypted record metadata".into())
            })
            .transpose()
    }
    pub fn record_count(&self, start: Option<f64>, end: Option<f64>) -> Result<u64> {
        match (start, end) {
            (Some(start), Some(end)) => {
                bounds(start, end)?;
                self.db
                    .query_row(
                        "SELECT COUNT(*) FROM text_records WHERE time>=? AND time<?",
                        params![start, end],
                        |r| r.get(0),
                    )
                    .map_err(|e| e.to_string())
            }
            (None, None) => self
                .db
                .query_row("SELECT COUNT(*) FROM text_records", [], |r| r.get(0))
                .map_err(|e| e.to_string()),
            _ => Err("Both range bounds are required".into()),
        }
    }
    pub fn delete_id(&mut self, id: &str) -> Result<bool> {
        validate_id(id)?;
        let tx = self.db.transaction().map_err(|e| e.to_string())?;
        let exists: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM text_records WHERE id=?)",
                [id],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        if !exists {
            return Ok(false);
        }
        journal(&tx, id, None)?;
        tx.execute("DELETE FROM text_records WHERE id=?", [id])
            .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
        Ok(true)
    }
    pub fn delete(&mut self, start: f64, end: f64) -> Result<usize> {
        bounds(start, end)?;
        let tx = self.db.transaction().map_err(|e| e.to_string())?;
        {
            let mut stmt = tx
                .prepare("SELECT id FROM text_records WHERE time>=? AND time<? ORDER BY time,id")
                .map_err(|e| e.to_string())?;
            let mut rows = stmt.query(params![start, end]).map_err(|e| e.to_string())?;
            while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                let id: String = row.get(0).map_err(|e| e.to_string())?;
                journal(&tx, &id, None)?;
            }
        }
        let deleted = tx
            .execute(
                "DELETE FROM text_records WHERE time>=? AND time<?",
                params![start, end],
            )
            .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
        Ok(deleted)
    }
    pub fn last_view_range(&self) -> Option<(f64, f64)> {
        self.last_query.get()
    }
    pub fn query(&self, value: Value) -> Result<Value> {
        if value.as_object().map_or(true, |v| {
            v.keys()
                .any(|k| !["start", "end", "offset", "limit"].contains(&k.as_str()))
        }) {
            return Err("Unexpected text query fields".into());
        }
        let start = value["start"].as_f64().ok_or("Invalid start")?;
        let end = value["end"].as_f64().ok_or("Invalid end")?;
        bounds(start, end)?;
        self.last_query.set(Some((start, end)));
        let offset = match value.get("offset") {
            Some(v) => v.as_u64().ok_or("Invalid text offset")?,
            None => 0,
        };
        let limit = match value.get("limit") {
            Some(v) => v.as_u64().ok_or("Invalid text limit")?,
            None => 20,
        };
        if offset > 9007199254740991 || !(1..=200).contains(&limit) {
            return Err("Invalid text page".into());
        }
        let(total,characters):(u64,u64)=self.db.query_row("SELECT COUNT(*),COALESCE(SUM(char_count),0) FROM text_records WHERE time>=? AND time<?",params![start,end],|r|Ok((r.get(0)?,r.get(1)?))).map_err(|e|e.to_string())?;
        let mut stmt=self.db.prepare("SELECT record FROM text_records WHERE time>=? AND time<? ORDER BY time,id LIMIT ? OFFSET ?").map_err(|e|e.to_string())?;
        let rows = stmt
            .query_map(params![start, end, limit, offset], |r| {
                r.get::<_, String>(0)
            })
            .map_err(|e| e.to_string())?;
        let mut records = Vec::new();
        let mut size = 0;
        for row in rows {
            let encoded = row.map_err(|e| e.to_string())?;
            if size + encoded.len() > 1500000 && !records.is_empty() {
                break;
            }
            size += encoded.len();
            records.push(serde_json::from_str::<Value>(&encoded).map_err(|e| e.to_string())?);
        }
        let next = offset + records.len() as u64;
        Ok(
            json!({"records":records,"offset":offset,"nextOffset":if next<total{Some(next)}else{None},"hasMore":next<total,"total":total,"totalCharacters":characters}),
        )
    }
}
fn bounds(start: f64, end: f64) -> Result<()> {
    if !start.is_finite() || !end.is_finite() || start < 0.0 || end < start || end >= 1e12 {
        Err("Invalid half-open text range".into())
    } else {
        Ok(())
    }
}
pub(crate) fn journal(db: &Connection, id: &str, record: Option<&str>) -> Result<()> {
    let rev: u64 = db
        .query_row("SELECT revision FROM text_state WHERE id=1", [], |r| {
            r.get(0)
        })
        .map_err(|e| e.to_string())?;
    let rev = rev
        .checked_add(1)
        .filter(|v| *v <= 9007199254740991)
        .ok_or("Text revision exhausted")?;
    db.execute("UPDATE text_state SET revision=? WHERE id=1", [rev])
        .map_err(|e| e.to_string())?;
    db.execute("INSERT INTO text_journal VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,deleted=excluded.deleted,record=excluded.record",params![id,rev,record.is_none(),record]).map_err(|e|e.to_string())?;
    Ok(())
}
impl keytrail_server::LocalTextSource for TextArchive {
    fn version(&self) -> Result<Option<u64>> {
        self.db
            .query_row("SELECT revision FROM text_state WHERE id=1", [], |r| {
                r.get(0)
            })
            .map(Some)
            .map_err(|e| e.to_string())
    }
    fn query_encrypted(&mut self, v: Value) -> Result<Value> {
        self.query(v)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encrypted_unicode_roundtrip_wrong_key_and_no_plaintext() {
        let path = std::env::temp_dir().join(format!("keytrail-win-text-{}.sqlite", uuid()));
        let key = random_key();
        let mut a = TextArchive::open(&path, key).unwrap();
        let text = "合成输入👨‍👩‍👧‍👦é";
        let m = a.append(text, 60.125, "windows.notepad").unwrap();
        assert_eq!(m.characters, 6);
        let page = a
            .query(json!({"start":60,"end":61,"offset":0,"limit":20}))
            .unwrap();
        assert_eq!(page["totalCharacters"], 6);
        let r: EncryptedRecord = serde_json::from_value(page["records"][0].clone()).unwrap();
        assert_eq!(decrypt(&key, &r).unwrap(), text);
        assert!(decrypt(&random_key(), &r).is_err());
        assert!(!std::fs::read(&path)
            .unwrap()
            .windows(text.len())
            .any(|b| b == text.as_bytes()));
        let changes = a.changes(0, 1).unwrap();
        assert_eq!(changes["changes"][0]["deleted"], false);
        assert_eq!(a.delete(60.0, 61.0).unwrap(), 1);
        assert_eq!(a.changes(0, 10).unwrap()["changes"][0]["deleted"], true);
        drop(a);
        assert!(TextArchive::open(&path, random_key()).is_err());
        std::fs::remove_file(path).unwrap();
    }
}

#[cfg(test)]
mod interop_tests {
    use super::*;
    #[test]
    fn actual_swift_cryptokit_fixture_decrypts_and_rejects_tampering() {
        let record: EncryptedRecord =
            serde_json::from_str(include_str!("../tests/fixtures/swift-record.json")).unwrap();
        let raw = B64
            .decode(include_str!("../tests/fixtures/TEST-ONLY-key.base64").trim())
            .unwrap();
        let key: [u8; 32] = raw.try_into().unwrap();
        assert_eq!(
            decrypt(&key, &record).unwrap(),
            include_str!("../tests/fixtures/expected-TEST-ONLY.txt")
        );
        let mut broken = record.clone();
        let mut bytes = B64.decode(&broken.sealed_box_base64).unwrap();
        *bytes.last_mut().unwrap() ^= 1;
        broken.sealed_box_base64 = B64.encode(bytes);
        assert!(decrypt(&key, &broken).is_err());
        let mut changed = record.clone();
        changed.metadata.characters += 1;
        assert!(decrypt(&key, &changed).is_err());
    }
}

#[cfg(test)]
mod deletion_tests {
    use super::*;
    #[test]
    fn individual_delete_is_idempotent_atomic_and_preserves_adjacent_records() {
        let path = std::env::temp_dir().join(format!("keytrail-single-delete-{}.sqlite", uuid()));
        let key = random_key();
        let mut archive = TextArchive::open(&path, key).unwrap();
        let first = archive.append("first", 60.1, "windows.fixture").unwrap();
        let second = archive.append("second", 60.2, "windows.fixture").unwrap();
        assert_eq!(archive.record_count(Some(60.0), Some(120.0)).unwrap(), 2);
        archive.db.execute_batch("CREATE TRIGGER fail_delete BEFORE DELETE ON text_records BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
        assert!(archive.delete_id(&first.id).is_err());
        assert!(archive.metadata_for_id(&first.id).unwrap().is_some());
        assert_eq!(
            archive.changes(0, 100).unwrap()["changes"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|r| r["deleted"] == true)
                .count(),
            0
        );
        archive
            .db
            .execute_batch("DROP TRIGGER fail_delete")
            .unwrap();
        assert!(archive.delete_id(&first.id).unwrap());
        assert!(!archive.delete_id(&first.id).unwrap());
        assert!(archive.metadata_for_id(&second.id).unwrap().is_some());
        assert_eq!(archive.record_count(None, None).unwrap(), 1);
        assert!(archive.delete_id("not-a-uuid").is_err());
        let changes = archive.changes(0, 100).unwrap();
        assert!(changes["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == first.id && r["deleted"] == true));
        drop(archive);
        std::fs::remove_file(path).unwrap();
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CivilMinute {
    pub year: u16,
    pub month: u16,
    pub day: u16,
    pub hour: u16,
    pub minute: u16,
}
pub fn parse_civil_minute(value: &str) -> Result<CivilMinute> {
    let value = value.trim();
    let bytes = value.as_bytes();
    if bytes.len() != 16
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || !matches!(bytes[10], b' ' | b'T')
        || bytes[13] != b':'
    {
        return Err("Use YYYY-MM-DD HH:MM, precise to one minute".into());
    }
    fn number(bytes: &[u8]) -> Result<u16> {
        if !bytes.iter().all(u8::is_ascii_digit) {
            return Err("Date/time fields must be numeric".into());
        }
        std::str::from_utf8(bytes)
            .unwrap()
            .parse()
            .map_err(|_| "Invalid date/time field".into())
    }
    let result = CivilMinute {
        year: number(&bytes[0..4])?,
        month: number(&bytes[5..7])?,
        day: number(&bytes[8..10])?,
        hour: number(&bytes[11..13])?,
        minute: number(&bytes[14..16])?,
    };
    if result.year < 1970
        || !(1..=12).contains(&result.month)
        || result.hour > 23
        || result.minute > 59
    {
        return Err("Invalid local minute".into());
    }
    let leap = result.year % 4 == 0 && (result.year % 100 != 0 || result.year % 400 == 0);
    let max = match result.month {
        2 => {
            if leap {
                29
            } else {
                28
            }
        }
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    if result.day == 0 || result.day > max {
        return Err("Invalid calendar date".into());
    }
    Ok(result)
}
/// Walk actual UTC minutes, preserving civil-hour boundaries across 30-minute DST changes.
pub fn civil_hour_start(
    now: f64,
    mut local_hour: impl FnMut(f64) -> Result<[u16; 4]>,
) -> Result<f64> {
    if !now.is_finite() || now < 0.0 || now >= 1e12 {
        return Err("Invalid observation time".into());
    }
    let mut start = (now / 60.0).floor() * 60.0;
    let key = local_hour(start)?;
    for _ in 0..360 {
        if start < 60.0 {
            return Ok(0.0);
        }
        let previous = start - 60.0;
        if local_hour(previous)? != key {
            return Ok(start);
        }
        start = previous;
    }
    Err("Civil hour exceeds the six-hour safety bound".into())
}
#[cfg(test)]
mod clock_tests {
    use super::*;
    #[test]
    fn minute_parser_validates_calendar_and_precision() {
        assert!(parse_civil_minute("2024-02-29 23:59").is_ok());
        for value in [
            "2023-02-29 12:00",
            "2026-04-31 10:00",
            "2026-01-01 24:00",
            "2026-01-01 00:00:01",
            "1969-12-31 23:59",
        ] {
            assert!(parse_civil_minute(value).is_err(), "{value}")
        }
    }
    #[test]
    fn current_hour_respects_half_hour_forward_and_backward_transitions() {
        let ordinary =
            civil_hour_start(4500.0, |t| Ok([2026, 1, 1, (t / 3600.0).floor() as u16])).unwrap();
        assert_eq!(ordinary, 3600.0);
        let forward = civil_hour_start(135.0 * 60.0, |t| {
            let minutes = (t / 60.0) as u16 + if t >= 120.0 * 60.0 { 30 } else { 0 };
            Ok([2026, 1, 1, minutes / 60])
        })
        .unwrap();
        assert_eq!(forward, 120.0 * 60.0);
        let backward = civil_hour_start(135.0 * 60.0, |t| {
            let minutes = (t / 60.0) as u16 - if t >= 120.0 * 60.0 { 30 } else { 0 };
            Ok([2026, 1, 1, minutes / 60])
        })
        .unwrap();
        assert_eq!(backward, 60.0 * 60.0);
    }
}

/// Called only after the system Run-key operation succeeded; do not hide a preferences I/O failure.
pub fn finish_login_change(enabled: bool, persist: impl FnOnce() -> Result<()>) -> Result<String> {
    persist().map_err(|error|format!("Windows login startup is now {}; saving preferences failed: {error}. The displayed state reflects Windows; retry saving.",if enabled{"enabled"}else{"disabled"}))?;
    Ok(format!(
        "Launch at login {}. Login launch remains paused.",
        if enabled {
            "enabled explicitly"
        } else {
            "disabled"
        }
    ))
}
#[cfg(test)]
mod login_tests {
    use super::*;
    #[test]
    fn system_success_does_not_hide_preferences_save_failure() {
        let directory =
            std::env::temp_dir().join(format!("keytrail-login-save-failure-{}", uuid()));
        std::fs::create_dir_all(&directory).unwrap();
        let error = finish_login_change(true, || {
            std::fs::write(&directory, b"not-a-file").map_err(|e| e.to_string())
        })
        .unwrap_err();
        assert!(error.contains("saving preferences failed"));
        assert!(error.contains("now enabled"));
        let success = finish_login_change(false, || Ok(())).unwrap();
        assert!(success.contains("disabled"));
        assert!(!success.contains("failed"));
        std::fs::remove_dir(directory).unwrap();
    }
}
