//! UI Automation snapshots only from controls that expose an explicit TextEdit composition state.
use super::*;
use keytrail_windows::{
    text_archive::TextArchive,
    text_diff::{allows_read, CommittedDiff, Selection},
    text_snapshot::{
        read_stable, ControlKind, ReadContext, ReadPayload, SnapshotProvider, StableRead,
        MAX_UTF16_UNITS,
    },
};
use windows::{
    core::Interface,
    Win32::{System::Com::*, UI::Accessibility::*},
};
#[link(name = "oleaut32")]
extern "system" {
    fn SafeArrayGetDim(array: *mut c_void) -> u32;
    fn SafeArrayGetLBound(array: *mut c_void, dim: u32, bound: *mut i32) -> i32;
    fn SafeArrayGetUBound(array: *mut c_void, dim: u32, bound: *mut i32) -> i32;
    fn SafeArrayAccessData(array: *mut c_void, data: *mut *mut c_void) -> i32;
    fn SafeArrayUnaccessData(array: *mut c_void) -> i32;
    fn SafeArrayDestroy(array: *mut c_void) -> i32;
}
unsafe fn focus_id(element: &IUIAutomationElement) -> Result<String, String> {
    let array = element
        .GetRuntimeId()
        .map_err(|_| "Focused control has no stable runtime identity")?;
    if array.is_null() {
        return Err("Focused control has no runtime identity".into());
    }
    let ptr = array as *mut c_void;
    let mut low = 0;
    let mut high = 0;
    let good = SafeArrayGetDim(ptr) == 1
        && SafeArrayGetLBound(ptr, 1, &mut low) >= 0
        && SafeArrayGetUBound(ptr, 1, &mut high) >= 0
        && high >= low
        && high - low < 128;
    let mut data = null_mut();
    if !good || SafeArrayAccessData(ptr, &mut data) < 0 {
        SafeArrayDestroy(ptr);
        return Err("Focused control runtime identity is invalid".into());
    }
    let ids = std::slice::from_raw_parts(data as *const i32, (high - low + 1) as usize);
    let value = ids.iter().map(i32::to_string).collect::<Vec<_>>().join("-");
    SafeArrayUnaccessData(ptr);
    SafeArrayDestroy(ptr);
    Ok(value)
}
unsafe fn composition_clear(edit: &IUIAutomationTextEditPattern) -> Result<bool, String> {
    let mut range = null_mut();
    let hr = (edit.vtable().GetActiveComposition)(edit.as_raw(), &mut range);
    if hr.is_err() {
        return Err("Control cannot prove IME composition state; skipped".into());
    }
    if !range.is_null() {
        let _: windows::core::IUnknown = windows::core::Interface::from_raw(range);
        return Ok(false);
    }
    let mut target = null_mut();
    let hr = (edit.vtable().GetConversionTarget)(edit.as_raw(), &mut target);
    if hr.is_err() {
        return Err("Control cannot prove IME conversion state; skipped".into());
    }
    if !target.is_null() {
        let _: windows::core::IUnknown = windows::core::Interface::from_raw(target);
        return Ok(false);
    }
    Ok(true)
}
unsafe fn app_id(pid: u32) -> Result<String, String> {
    let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    if process.is_null() {
        return Err("Protected process: application identity unavailable".into());
    }
    let mut name = vec![0u16; 32768];
    let mut length = name.len() as u32;
    let good = QueryFullProcessImageNameW(process, 0, name.as_mut_ptr(), &mut length) != 0;
    CloseHandle(process);
    if !good {
        return Err("Application identity unavailable".into());
    }
    let value = String::from_utf16_lossy(&name[..length as usize]);
    let name = Path::new(&value)
        .file_name()
        .ok_or("Application identity unavailable")?
        .to_string_lossy();
    let clean: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || ".-_".contains(c) {
                c
            } else {
                '_'
            }
        })
        .take(200)
        .collect();
    Ok(format!("windows.{clean}"))
}
struct Snapshot {
    context: ReadContext,
    focus: String,
    pid: u32,
    text: String,
    app: String,
    clear: bool,
    selection: Selection,
}
unsafe fn focused_context(
    automation: &IUIAutomation,
) -> Result<(IUIAutomationElement, ReadContext), String> {
    let element = automation
        .GetFocusedElement()
        .map_err(|_| "Focused control unavailable (secure desktop or unsupported provider)")?;
    let password = element
        .CurrentIsPassword()
        .map_err(|_| "Password protection state unavailable; skipped")?
        .as_bool();
    let enabled = element
        .CurrentIsEnabled()
        .map_err(|_| "Control enablement unknown")?
        .as_bool();
    let focusable = element
        .CurrentIsKeyboardFocusable()
        .map_err(|_| "Control focusability unknown")?
        .as_bool();
    let kind = element
        .CurrentControlType()
        .map_err(|_| "Control type unavailable")?;
    let kind = if kind == UIA_EditControlTypeId {
        ControlKind::Edit
    } else if kind == UIA_DocumentControlTypeId {
        ControlKind::Document
    } else {
        ControlKind::Unsupported
    };
    let pid = element
        .CurrentProcessId()
        .map_err(|_| "Process identity unavailable")? as u32;
    let mut foreground = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &mut foreground);
    let context = ReadContext {
        focus: focus_id(&element)?,
        process_id: pid,
        foreground_process_id: foreground,
        own_process_id: GetCurrentProcessId(),
        kind,
        password,
        enabled,
        focusable,
    };
    context.validate()?;
    Ok((element, context))
}
unsafe fn payload(edit: &IUIAutomationTextEditPattern) -> Result<ReadPayload, String> {
    let range = edit
        .DocumentRange()
        .map_err(|_| "Committed document range unavailable")?;
    let selected = edit
        .GetSelection()
        .map_err(|_| "Selection evidence unavailable")?;
    if selected
        .Length()
        .map_err(|_| "Selection evidence unavailable")?
        != 1
    {
        return Err("Multiple/unknown selection: skipped".into());
    }
    let selection = selected
        .GetElement(0)
        .map_err(|_| "Selection evidence unavailable")?;
    let prefix = range
        .Clone()
        .map_err(|_| "Selection baseline unavailable")?;
    prefix
        .MoveEndpointByRange(
            TextPatternRangeEndpoint_End,
            &selection,
            TextPatternRangeEndpoint_Start,
        )
        .map_err(|_| "Selection start unavailable")?;
    let start = prefix
        .GetText(262145)
        .map_err(|_| "Selection start unavailable")?
        .len();
    let prefix = range
        .Clone()
        .map_err(|_| "Selection baseline unavailable")?;
    prefix
        .MoveEndpointByRange(
            TextPatternRangeEndpoint_End,
            &selection,
            TextPatternRangeEndpoint_End,
        )
        .map_err(|_| "Selection end unavailable")?;
    let end = prefix
        .GetText(262145)
        .map_err(|_| "Selection end unavailable")?
        .len();
    let value = range
        .GetText(262145)
        .map_err(|_| "Committed text unavailable")?;
    if value.len() > MAX_UTF16_UNITS || end < start || end > value.len() {
        return Err("Focused text budget or UTF-16 selection invalid; skipped".into());
    }
    let text = String::from_utf16(value.as_wide())
        .map_err(|_| "Focused text is not valid UTF-16; skipped")?;
    Ok(ReadPayload {
        text,
        selection: Selection {
            start,
            length: end - start,
        },
    })
}
struct UIAProvider<'a> {
    automation: &'a IUIAutomation,
    pinned: ReadContext,
    edit: IUIAutomationTextEditPattern,
}
impl SnapshotProvider for UIAProvider<'_> {
    fn context(&mut self) -> Result<ReadContext, String> {
        let (_, current) = unsafe { focused_context(self.automation)? };
        // The pattern was obtained from this exact eligible focus, not a later one.
        if current != self.pinned {
            return Err("Focused context changed before/during sampling; skipped".into());
        }
        Ok(current)
    }
    fn marker(&mut self) -> Result<bool, String> {
        unsafe { composition_clear(&self.edit) }
    }
    fn payload(&mut self) -> Result<ReadPayload, String> {
        unsafe { payload(&self.edit) }
    }
}
unsafe fn snapshot(automation: &IUIAutomation) -> Result<Snapshot, String> {
    let (element, pinned) = focused_context(automation)?;
    let edit = element
        .GetCurrentPatternAs(UIA_TextEditPatternId)
        .map_err(|_| {
            "Control lacks TextEdit composition evidence; fail-closed (legacy/IME-unknown control)"
        })?;
    let mut provider = UIAProvider {
        automation,
        pinned,
        edit,
    };
    match read_stable(&mut provider)? {
        StableRead::Composing(context) => Ok(Snapshot {
            focus: context.focus.clone(),
            pid: context.process_id,
            context,
            text: String::new(),
            app: String::new(),
            clear: false,
            selection: Selection {
                start: 0,
                length: 0,
            },
        }),
        StableRead::Clear { context, payload } => Ok(Snapshot {
            focus: context.focus.clone(),
            pid: context.process_id,
            app: app_id(context.process_id)?,
            context,
            text: payload.text,
            clear: true,
            selection: payload.selection,
        }),
    }
}
pub(super) fn spawn(
    archive: Arc<Mutex<TextArchive>>,
    settings: Arc<Mutex<Settings>>,
    active: Arc<AtomicBool>,
    intent: Arc<AtomicU64>,
    reset: Arc<AtomicU64>,
    status: Arc<Mutex<String>>,
    stop: Arc<AtomicBool>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || unsafe {
        // Default-off text mode never initializes UI Automation or reads a control.
        while !stop.load(Ordering::Relaxed)
            && (!active.load(Ordering::Relaxed) || !settings.lock().unwrap().text_enabled)
        {
            thread::sleep(Duration::from_millis(250));
        }
        if stop.load(Ordering::Relaxed) {
            return;
        }
        if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
            *status.lock().unwrap() =
                "UI Automation COM initialization failed; text capture unavailable".into();
            return;
        }
        let automation: std::result::Result<IUIAutomation, _> =
            CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER);
        let automation = match automation {
            Ok(v) => v,
            Err(_) => {
                *status.lock().unwrap() =
                    "UI Automation unavailable; text capture remains disabled".into();
                CoUninitialize();
                return;
            }
        };
        if let Ok(v2) = automation.cast::<IUIAutomation2>() {
            let _ = v2.SetConnectionTimeout(1000);
            let _ = v2.SetTransactionTimeout(1000);
        }
        let mut diff = CommittedDiff::default();
        let mut previous_reset = 0;
        let mut latest = 0;
        let mut last_activity = 0;
        while !stop.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(50));
            if !active.load(Ordering::Relaxed) || !settings.lock().unwrap().text_enabled {
                diff.reset();
                latest = 0;
                intent.store(0, Ordering::Relaxed);
                *status.lock().unwrap() =
                    "Optional text capture off, or collection paused/locked.".into();
                continue;
            }
            let reset_now = reset.load(Ordering::Relaxed);
            if reset_now != previous_reset {
                diff.reset();
                previous_reset = reset_now;
                latest = 0;
            }
            let input = intent.load(Ordering::Relaxed);
            let now = (time() * 1000.0) as u64;
            if !allows_read(input, now) {
                if now.saturating_sub(last_activity) > 2000 {
                    diff.reset();
                }
                latest = 0;
                continue;
            }
            last_activity = input;
            match snapshot(&automation) {
                Ok(s) => {
                    if input != latest {
                        if latest == 0 {
                            diff.ensure_baseline(&s.focus, &s.text, s.selection, s.clear);
                        }
                        latest = input;
                        continue;
                    }
                    if now.saturating_sub(input) < 200 {
                        continue;
                    }
                    if let Some(text) = diff.update(&s.focus, &s.text, s.selection, false, s.clear)
                    {
                        if !active.load(Ordering::Relaxed) || !settings.lock().unwrap().text_enabled
                        {
                            diff.reset();
                            continue;
                        }
                        let mut archive = archive.lock().unwrap();
                        let mut foreground = 0;
                        GetWindowThreadProcessId(GetForegroundWindow(), &mut foreground);
                        let still_focused_and_clear = focused_context(&automation)
                            .and_then(|(element, context)| {
                                if context != s.context {
                                    return Err("Focused context changed before append".into());
                                }
                                let edit: IUIAutomationTextEditPattern =
                                    element.GetCurrentPatternAs(UIA_TextEditPatternId).map_err(
                                        |_| "Composition evidence unavailable before append",
                                    )?;
                                composition_clear(&edit)
                            })
                            .unwrap_or(false);
                        if reset.load(Ordering::Relaxed) != reset_now
                            || !allows_read(input, (time() * 1000.0) as u64)
                            || foreground != s.pid
                            || !still_focused_and_clear
                            || !active.load(Ordering::Relaxed)
                            || !settings.lock().unwrap().text_enabled
                        {
                            diff.reset();
                            continue;
                        }
                        let result = archive.append(&text, time(), &s.app);
                        *status.lock().unwrap() = match result {
                            Ok(meta) => format!(
                                "Recorded {} committed characters locally (encrypted).",
                                meta.characters
                            ),
                            Err(e) => format!("Text archive error: {e}"),
                        };
                    } else {
                        *status.lock().unwrap() = if s.clear {
                            "Supported committed-text control; baseline/reset or no new text".into()
                        } else {
                            "IME composition/conversion active: not recorded".into()
                        };
                    }
                    if s.clear {
                        let _ =
                            intent.compare_exchange(input, 0, Ordering::Relaxed, Ordering::Relaxed);
                        latest = 0;
                    }
                }
                Err(e) => {
                    let _ = intent.compare_exchange(input, 0, Ordering::Relaxed, Ordering::Relaxed);
                    latest = 0;
                    diff.reset();
                    *status.lock().unwrap() = e;
                }
            }
        }
        drop(automation);
        CoUninitialize();
    })
}
