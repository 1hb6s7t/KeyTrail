use super::*;
use crate::text_diff::CommittedDiff;

#[derive(Clone, Copy)]
enum Race {
    None,
    Begin,
    BeginCommit,
    EqualLengthCommit,
    Selection,
    Context(u8),
}
struct Controlled {
    context: ReadContext,
    payload: ReadPayload,
    clear: bool,
    race: Race,
    calls: Vec<&'static str>,
    markers: Vec<bool>,
    marker_count: usize,
    payload_count: usize,
    context_count: usize,
    fail_at: Option<usize>,
}
fn payload(text: &str) -> ReadPayload {
    ReadPayload {
        text: text.into(),
        selection: Selection {
            start: text.encode_utf16().count(),
            length: 0,
        },
    }
}
impl Controlled {
    fn new(text: &str) -> Self {
        Self {
            context: ReadContext {
                focus: "editor-42".into(),
                process_id: 42,
                foreground_process_id: 42,
                own_process_id: 9,
                kind: ControlKind::Edit,
                password: false,
                enabled: true,
                focusable: true,
            },
            payload: payload(text),
            clear: true,
            race: Race::None,
            calls: vec![],
            markers: vec![],
            marker_count: 0,
            payload_count: 0,
            context_count: 0,
            fail_at: None,
        }
    }
    fn call(&mut self, name: &'static str) -> Result<(), String> {
        self.calls.push(name);
        if self.fail_at == Some(self.calls.len()) {
            return Err("Controlled provider state unavailable".into());
        }
        Ok(())
    }
}
impl SnapshotProvider for Controlled {
    fn context(&mut self) -> Result<ReadContext, String> {
        self.call("context")?;
        self.context_count += 1;
        if self.context_count == 2 {
            if let Race::Context(field) = self.race {
                match field {
                    0 => self.context.focus = "other-control".into(),
                    1 => self.context.process_id = 43,
                    2 => self.context.foreground_process_id = 43,
                    3 => self.context.kind = ControlKind::Document,
                    4 => self.context.password = true,
                    5 => self.context.enabled = false,
                    6 => self.context.focusable = false,
                    _ => self.context.kind = ControlKind::Unsupported,
                }
            }
        }
        Ok(self.context.clone())
    }
    fn marker(&mut self) -> Result<bool, String> {
        self.call("marker")?;
        self.marker_count += 1;
        if self.marker_count == 2
            && matches!(self.race, Race::BeginCommit | Race::EqualLengthCommit)
        {
            self.clear = true;
            self.payload = payload("Hello 你");
        }
        let current = self.clear;
        self.markers.push(current);
        // A legitimate provider changes after the first clear-state read, before
        // the coordinator's first body/selection access. No final snapshot is injected.
        if self.marker_count == 1
            && matches!(
                self.race,
                Race::Begin | Race::BeginCommit | Race::EqualLengthCommit
            )
        {
            self.clear = false;
            self.payload = payload(if matches!(self.race, Race::EqualLengthCommit) {
                "Hello 未"
            } else {
                "Hello ni"
            });
        }
        Ok(current)
    }
    fn payload(&mut self) -> Result<ReadPayload, String> {
        self.call("payload")?;
        self.payload_count += 1;
        if self.payload_count == 2 && matches!(self.race, Race::Selection) {
            self.payload.selection.start -= 1;
        }
        Ok(self.payload.clone())
    }
}
fn baseline() -> CommittedDiff {
    let mut diff = CommittedDiff::default();
    diff.ensure_baseline(
        "editor-42",
        "Hello ",
        Selection {
            start: 6,
            length: 0,
        },
        true,
    );
    diff
}
fn extract(provider: &mut Controlled, diff: &mut CommittedDiff) -> Option<String> {
    match read_stable(provider) {
        Ok(StableRead::Clear { context, payload }) => diff.update(
            &context.focus,
            &payload.text,
            payload.selection,
            false,
            true,
        ),
        Ok(StableRead::Composing(context)) => diff.update(
            &context.focus,
            "",
            Selection {
                start: 0,
                length: 0,
            },
            false,
            false,
        ),
        Err(_) => {
            diff.reset();
            None
        }
    }
}

#[test]
fn provider_begin_commit_and_equal_length_preedit_never_reach_extraction() {
    for race in [Race::Begin, Race::BeginCommit, Race::EqualLengthCommit] {
        let mut provider = Controlled::new("Hello ");
        provider.race = race;
        assert_eq!(extract(&mut provider, &mut baseline()), None);
        assert_eq!(
            provider.payload_count,
            if matches!(race, Race::Begin) { 1 } else { 2 }
        );
        assert_eq!(
            provider.marker_count,
            if matches!(race, Race::Begin) { 2 } else { 3 }
        );
        if matches!(race, Race::BeginCommit | Race::EqualLengthCommit) {
            // Tail marker alone cannot reject this case: every observed marker is clear.
            assert_eq!(provider.markers, vec![true, true, true]);
        }
        assert!(provider.calls.len() <= 7);
    }
}
#[test]
fn stable_ascii_chinese_unicode_and_active_wait_keep_existing_commit_semantics() {
    for addition in ["abc", "你好", "😀", "👩‍👩‍👧‍👧", "e\u{301}"] {
        let text = format!("Hello {addition}");
        let mut provider = Controlled::new(&text);
        assert_eq!(
            extract(&mut provider, &mut baseline()),
            Some(addition.into())
        );
        assert_eq!(
            provider.calls,
            vec!["context", "marker", "payload", "marker", "payload", "marker", "context"]
        );
        assert_eq!(provider.payload_count, 2);
    }
    let mut diff = baseline();
    let mut composing = Controlled::new("must not be read");
    composing.clear = false;
    assert_eq!(extract(&mut composing, &mut diff), None);
    assert_eq!(composing.payload_count, 0);
    assert_eq!(
        composing.calls,
        vec!["context", "marker", "marker", "marker", "context"]
    );
    assert_eq!(
        extract(&mut Controlled::new("Hello 你"), &mut diff),
        Some("你".into())
    );
}
#[test]
fn changed_context_or_selection_is_rejected_using_utf16_not_utf8_indices() {
    for field in 0..8 {
        let mut provider = Controlled::new("Hello 你");
        provider.race = Race::Context(field);
        assert!(read_stable(&mut provider).is_err());
    }
    let mut changed = Controlled::new("Hello 你");
    changed.race = Race::Selection;
    assert!(read_stable(&mut changed).is_err());
    let mut split = Controlled::new("A😀");
    split.payload.selection.start = 2;
    assert!(read_stable(&mut split).is_err());
    let mut bytes = Controlled::new("A😀");
    bytes.payload.selection.start = "A😀".len();
    assert!(read_stable(&mut bytes).is_err());
    assert!(matches!(
        read_stable(&mut Controlled::new("A😀")).unwrap(),
        StableRead::Clear { .. }
    ));
}
#[test]
fn unavailable_provider_states_and_oversized_reads_fail_closed_without_retry_loop() {
    for call in 1..=7 {
        let mut provider = Controlled::new("Hello 你");
        provider.fail_at = Some(call);
        assert!(read_stable(&mut provider).is_err());
        assert_eq!(provider.calls.len(), call);
        if call == 4 {
            assert_eq!(provider.payload_count, 1);
        }
    }
    let mut too_large = Controlled::new(&"x".repeat(MAX_UTF16_UNITS + 1));
    assert!(read_stable(&mut too_large).is_err());
    assert_eq!(too_large.payload_count, 1);
    let mut overflow = Controlled::new("abc");
    overflow.payload.selection = Selection {
        start: 1,
        length: usize::MAX,
    };
    assert!(read_stable(&mut overflow).is_err());
    let mut protected = Controlled::new("private");
    protected.context.password = true;
    assert!(read_stable(&mut protected).is_err());
    assert_eq!(protected.payload_count, 0);
}
