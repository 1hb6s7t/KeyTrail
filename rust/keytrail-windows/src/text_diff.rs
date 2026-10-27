//! Selection-validated UTF-16 insertion extraction, matching the native Swift contract.
use unicode_segmentation::UnicodeSegmentation;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Selection {
    pub start: usize,
    pub length: usize,
}
#[derive(Default)]
pub struct CommittedDiff {
    focus: Option<String>,
    prior: Option<(String, Selection)>,
}
fn boundary(units: &[u16], n: usize) -> bool {
    n <= units.len()
        && !(n > 0
            && n < units.len()
            && (0xd800..=0xdbff).contains(&units[n - 1])
            && (0xdc00..=0xdfff).contains(&units[n]))
}
pub fn inserted(before: &str, after: &str, old: Selection, new: Selection) -> Option<String> {
    if before.len() > 262144 || after.len() > 262144 || new.length != 0 {
        return None;
    }
    let a: Vec<_> = before.encode_utf16().collect();
    let b: Vec<_> = after.encode_utf16().collect();
    let end = old.start.checked_add(old.length)?;
    if end > a.len() {
        return None;
    }
    let suffix = a.len() - end;
    if b.len() < old.start + suffix {
        return None;
    }
    let new_end = b.len() - suffix;
    if !boundary(&a, old.start)
        || !boundary(&a, end)
        || !boundary(&b, old.start)
        || !boundary(&b, new_end)
        || a[..old.start] != b[..old.start]
        || a[end..] != b[new_end..]
        || new.start != new_end
    {
        return None;
    }
    let text = String::from_utf16(&b[old.start..new_end]).ok()?;
    if text.is_empty() || text.graphemes(true).count() > 16384 {
        None
    } else {
        Some(text)
    }
}
pub fn allows_read(intent_ms: u64, now_ms: u64) -> bool {
    intent_ms > 0 && now_ms >= intent_ms && now_ms - intent_ms <= 2000
}
impl CommittedDiff {
    pub fn ensure_baseline(&mut self, focus: &str, text: &str, selection: Selection, clear: bool) {
        if self.focus.as_deref() != Some(focus) || self.prior.is_none() {
            let _ = self.update(focus, text, selection, false, clear);
        }
    }

    pub fn reset(&mut self) {
        self.focus = None;
        self.prior = None;
    }
    pub fn update(
        &mut self,
        focus: &str,
        text: &str,
        selection: Selection,
        protected: bool,
        composition_clear: bool,
    ) -> Option<String> {
        if protected || text.len() > 262144 {
            self.reset();
            return None;
        }
        if !composition_clear {
            if self.focus.as_deref() != Some(focus) {
                self.reset()
            }
            return None;
        }
        if self.focus.as_deref() != Some(focus) {
            self.focus = Some(focus.into());
            self.prior = Some((text.into(), selection));
            return None;
        }
        let (before, old) = self.prior.replace((text.into(), selection))?;
        inserted(&before, text, old, selection)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn caret(n: usize) -> Selection {
        Selection {
            start: n,
            length: 0,
        }
    }
    #[test]
    fn selection_unicode_combining_and_automatic_updates() {
        assert_eq!(inserted("abc", "Xabc", caret(3), caret(4)), None);
        assert_eq!(
            inserted("e", "e\u{301}", caret(1), caret(2)),
            Some("\u{301}".into())
        );
        assert_eq!(
            inserted(
                "a😀b",
                "a你好b",
                Selection {
                    start: 1,
                    length: 2
                },
                caret(3)
            ),
            Some("你好".into())
        );
        assert_eq!(
            inserted(
                "a😀b",
                "axb",
                Selection {
                    start: 2,
                    length: 1
                },
                caret(2)
            ),
            None
        );
        assert_eq!(inserted("abc", "ab", caret(3), caret(2)), None);
    }
    #[test]
    fn focus_password_composition_and_reset() {
        let mut d = CommittedDiff::default();
        assert_eq!(d.update("a", "old", caret(3), false, true), None);
        assert_eq!(
            d.update("a", "old中", caret(4), false, true),
            Some("中".into())
        );
        assert_eq!(d.update("a", "old中拼音", caret(6), false, false), None);
        assert_eq!(
            d.update("a", "old中文", caret(5), false, true),
            Some("文".into())
        );
        assert_eq!(d.update("password", "secret", caret(6), true, true), None);
        d.reset();
        assert_eq!(d.update("a", "old中文", caret(5), false, true), None);
    }
}
