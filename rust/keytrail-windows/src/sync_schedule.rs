//! Shared by the real Windows worker and host integration fixtures.
//! Local journals are checked promptly; idle polling never becomes network polling.
use crate::text_archive::TextArchive;
use keytrail_core::Engine;
use serde_json::json;
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};

pub const LOCAL_CHECK: Duration = Duration::from_secs(1);
pub const IDENTITY_PROBE: Duration = Duration::from_secs(30);
pub const WORKER_POLL: Duration = Duration::from_millis(250);

/// Deliberately excludes acknowledgement cursors and last-success timestamps.
#[derive(Clone, PartialEq, Eq)]
pub struct SyncIdentity {
    pub endpoint: String,
    pub device: String,
    pub protected_credential: Vec<u8>,
    pub aggregate: bool,
    pub text: bool,
}
impl SyncIdentity {
    pub fn enabled(&self) -> bool {
        self.aggregate || self.text
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Tick {
    Disabled,
    Deferred,
    Idle,
    Synchronized,
}

#[derive(Default)]
pub struct SyncSchedule {
    identity: Option<SyncIdentity>,
    next_check: Duration,
    next_probe: Duration,
    retry_at: Duration,
    failures: u32,
}
impl SyncSchedule {
    pub fn retry_after(&self, now: Duration) -> Duration {
        self.retry_at.saturating_sub(now)
    }
    /// `clock` comes from Instant::elapsed in production, never the wall clock.
    /// This is the exact driver used by the Windows worker, with injectable I/O.
    pub fn tick(
        &mut self,
        clock: impl Fn() -> Duration,
        identity: SyncIdentity,
        force: bool,
        pending: impl FnOnce() -> Result<bool, String>,
        upload: impl FnOnce() -> Result<(), String>,
    ) -> Result<Tick, String> {
        let now = clock();
        if self.identity.as_ref() != Some(&identity) {
            self.identity = Some(identity.clone());
            self.next_check = now;
            self.next_probe = now;
            self.retry_at = now;
            self.failures = 0;
        }
        if !identity.enabled() {
            return Ok(Tick::Disabled);
        }
        if !force && (now < self.next_check || now < self.retry_at) {
            return Ok(Tick::Deferred);
        }
        self.next_check = now + LOCAL_CHECK;
        let result = (|| {
            if !force && now < self.next_probe && !pending()? {
                return Ok(Tick::Idle);
            }
            upload()?;
            self.next_probe = clock() + IDENTITY_PROBE;
            self.retry_at = clock();
            self.failures = 0;
            Ok(Tick::Synchronized)
        })();
        if result.is_err() {
            self.failures = self.failures.saturating_add(1);
            self.retry_at = clock() + Duration::from_secs(30u64 * (1u64 << self.failures.min(4)));
        }
        result
    }
}

/// An empty preflight does not contact the server. Use each stream's saved cursor.
pub fn local_pending(
    engine: &Arc<Mutex<Engine>>,
    archive: &Arc<Mutex<TextArchive>>,
    aggregate: bool,
    cursor: u64,
    text: bool,
    text_cursor: u64,
) -> Result<bool, String> {
    if aggregate {
        let page = engine
            .lock()
            .map_err(|_| "Store unavailable")?
            .request(&json!({"op":"syncChanges","after":cursor,"limit":1}).to_string())?;
        if page["changes"]
            .as_array()
            .ok_or("Invalid local changes")?
            .len()
            > 0
        {
            return Ok(true);
        }
    }
    if text {
        let page = archive
            .lock()
            .map_err(|_| "Text store unavailable")?
            .changes(text_cursor, 1)?;
        if page["changes"]
            .as_array()
            .ok_or("Invalid local text changes")?
            .len()
            > 0
        {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
#[path = "sync_schedule_tests.rs"]
mod tests;
