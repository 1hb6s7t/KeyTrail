//! Bounded consistency sampling, shared by the real UIA adapter and providers in tests.
//! This reduces cross-call races; it is not an atomic OS snapshot or an ABA guarantee.
use crate::text_diff::Selection;

pub const MAX_UTF16_UNITS: usize = 262_144;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlKind {
    Edit,
    Document,
    Unsupported,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadContext {
    pub focus: String,
    pub process_id: u32,
    pub foreground_process_id: u32,
    pub own_process_id: u32,
    pub kind: ControlKind,
    pub password: bool,
    pub enabled: bool,
    pub focusable: bool,
}
impl ReadContext {
    pub fn validate(&self) -> Result<(), String> {
        if self.focus.is_empty()
            || self.focus.len() > 2048
            || self.process_id == 0
            || self.process_id == self.own_process_id
            || self.process_id != self.foreground_process_id
            || self.password
            || !self.enabled
            || !self.focusable
            || !matches!(self.kind, ControlKind::Edit | ControlKind::Document)
        {
            return Err("Protected, background or unsupported focused control; skipped".into());
        }
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadPayload {
    pub text: String,
    pub selection: Selection,
}
impl ReadPayload {
    fn validate(&self) -> Result<(), String> {
        let units: Vec<u16> = self.text.encode_utf16().collect();
        let end = self
            .selection
            .start
            .checked_add(self.selection.length)
            .ok_or("Selection overflow")?;
        let boundary = |n: usize| {
            n <= units.len()
                && !(n > 0
                    && n < units.len()
                    && (0xd800..=0xdbff).contains(&units[n - 1])
                    && (0xdc00..=0xdfff).contains(&units[n]))
        };
        if units.len() > MAX_UTF16_UNITS || !boundary(self.selection.start) || !boundary(end) {
            return Err("Invalid UTF-16 selection or focused-text budget; skipped".into());
        }
        Ok(())
    }
}
pub trait SnapshotProvider {
    fn context(&mut self) -> Result<ReadContext, String>;
    /// True only when both composition and conversion states are known clear.
    fn marker(&mut self) -> Result<bool, String>;
    fn payload(&mut self) -> Result<ReadPayload, String>;
}
#[derive(Debug, PartialEq, Eq)]
pub enum StableRead {
    Composing(ReadContext),
    Clear {
        context: ReadContext,
        payload: ReadPayload,
    },
}
pub fn read_stable(provider: &mut impl SnapshotProvider) -> Result<StableRead, String> {
    let before = provider.context()?;
    before.validate()?;
    let first = provider.marker()?;
    if !first {
        // Preserve the old waiting path without reading any preedit payload.
        let second = provider.marker()?;
        let third = provider.marker()?;
        let after = provider.context()?;
        after.validate()?;
        if !second && !third && before == after {
            return Ok(StableRead::Composing(before));
        }
        return Err("Focused composition/context changed during sampling; skipped".into());
    }
    let one = provider.payload()?;
    one.validate()?;
    let second = provider.marker()?;
    if !second {
        return Err("Composition began during text sampling; skipped".into());
    }
    let two = provider.payload()?;
    two.validate()?;
    let third = provider.marker()?;
    let after = provider.context()?;
    after.validate()?;
    if !third || before != after || one != two {
        return Err(
            "Focused text, selection or composition changed during sampling; skipped".into(),
        );
    }
    Ok(StableRead::Clear {
        context: before,
        payload: one,
    })
}

#[cfg(test)]
#[path = "text_snapshot_tests.rs"]
mod tests;
