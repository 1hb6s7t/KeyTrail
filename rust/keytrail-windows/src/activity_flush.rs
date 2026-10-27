//! Durable portion of the resident's real flush path, shared with fault fixtures.
use crate::RecoveryCutoff;
use serde_json::{json, Value};

/// Preserve pending input until ingest commits, and preserve the first end boundary
/// until end commits. Callers must stop capture first when `end` is requested.
pub fn flush_activity(
    pending: &mut Vec<Value>,
    recovery: &mut RecoveryCutoff,
    now: f64,
    end: bool,
    advance_allowed: bool,
    mut request: impl FnMut(Value) -> Result<Value, String>,
) -> Result<(), String> {
    if end {
        recovery.mark(now);
    }
    let boundary = recovery.pending().unwrap_or(now);
    if !pending.is_empty() {
        request(json!({"op":"ingest","samples":&*pending,"observedThrough":boundary}))?;
        pending.clear();
    }
    if let Some(cutoff) = recovery.pending() {
        request(json!({"op":"end","time":cutoff}))?;
        recovery.complete(cutoff);
        if end {
            return Ok(());
        }
    }
    if advance_allowed {
        request(json!({"op":"advance","time":now}))?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "activity_flush_tests.rs"]
mod tests;
