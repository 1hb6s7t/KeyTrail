//! Platform-independent physical input normalization; no text, sequence, or position storage.
pub mod activity_flush;
pub mod sync_schedule;
pub mod text_archive;
pub mod text_diff;
mod text_retention;
pub mod text_snapshot;
use serde_json::{json, Value};
use std::collections::BTreeSet;
#[derive(Default, Clone)]
pub struct InputState {
    held: BTreeSet<(u16, bool)>,
    cursor: Option<(i32, i32)>,
}
impl InputState {
    pub fn clear_cursor(&mut self) {
        self.cursor = None;
    }
    pub fn reset(&mut self) {
        self.held.clear();
        self.cursor = None;
    }
    pub fn key(&mut self, scan: u16, extended: bool, released: bool) -> Option<&'static str> {
        if released {
            self.held.remove(&(scan, extended));
            return None;
        }
        if scan == 0 || scan == 255 || !self.held.insert((scan, extended)) {
            return None;
        }
        Some(physical_key(scan, extended))
    }
    /// Positions live only in this transient baseline; return a scalar 96-DPI display-point distance.
    pub fn movement(&mut self, x: i32, y: i32, dpi: u32) -> Option<f64> {
        let old = self.cursor.replace((x, y));
        old.map(|(a, b)| {
            let dx = x as f64 - a as f64;
            let dy = y as f64 - b as f64;
            dx.hypot(dy) * 96.0 / dpi.max(96) as f64
        })
        .filter(|v| *v > 0.0)
    }
}
pub fn physical_key(scan: u16, extended: bool) -> &'static str {
    // Windows Scan 1 Make codes identify physical keys independently of Num Lock/layout.
    // https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input
    // `extended` is RI_KEY_E0; native.rs excludes E1 (Pause) before this boundary.
    if extended {
        return match scan {
            0x1c => "Num Enter",
            0x1d => "Control",
            0x35 => "Num /",
            0x37 => "PrintScreen",
            0x38 => "Alt",
            0x47 => "Home",
            0x48 => "Up",
            0x49 => "PageUp",
            0x4b => "Left",
            0x4d => "Right",
            0x4f => "End",
            0x50 => "Down",
            0x51 => "PageDown",
            0x52 => "Insert",
            0x53 => "ForwardDelete",
            0x5b | 0x5c => "Windows",
            _ => "Other",
        };
    }
    match scan {
        1 => "Escape",
        2 => "1",
        3 => "2",
        4 => "3",
        5 => "4",
        6 => "5",
        7 => "6",
        8 => "7",
        9 => "8",
        10 => "9",
        11 => "0",
        12 => "-",
        13 => "=",
        14 => "Backspace",
        15 => "Tab",
        16 => "Q",
        17 => "W",
        18 => "E",
        19 => "R",
        20 => "T",
        21 => "Y",
        22 => "U",
        23 => "I",
        24 => "O",
        25 => "P",
        26 => "[",
        27 => "]",
        28 => "Return",
        29 => "Control",
        30 => "A",
        31 => "S",
        32 => "D",
        33 => "F",
        34 => "G",
        35 => "H",
        36 => "J",
        37 => "K",
        38 => "L",
        39 => ";",
        40 => "'",
        41 => "`",
        42 | 54 => "Shift",
        43 => "\\",
        44 => "Z",
        45 => "X",
        46 => "C",
        47 => "V",
        48 => "B",
        49 => "N",
        50 => "M",
        51 => ",",
        52 => ".",
        53 => "/",
        55 => "Num *",
        56 => "Alt",
        57 => "Space",
        58 => "CapsLock",
        59 => "F1",
        60 => "F2",
        61 => "F3",
        62 => "F4",
        63 => "F5",
        64 => "F6",
        65 => "F7",
        66 => "F8",
        67 => "F9",
        68 => "F10",
        69 => "NumLock",
        70 => "ScrollLock",
        71 => "Num 7",
        72 => "Num 8",
        73 => "Num 9",
        74 => "Num -",
        75 => "Num 4",
        76 => "Num 5",
        77 => "Num 6",
        78 => "Num +",
        79 => "Num 1",
        80 => "Num 2",
        81 => "Num 3",
        82 => "Num 0",
        83 => "Num .",
        84 => "PrintScreen", // SysRq scan emitted by Alt+Print Screen.
        87 => "F11",
        88 => "F12",
        89 => "Num =",
        _ => "Other",
    }
}
pub fn sample(time: f64, kind: &str, label: Option<&str>, distance: f64, scroll: f64) -> Value {
    json!({"timestamp":time,"kind":kind,"keyLabel":label,"distancePoints":distance,"scrollDelta":scroll})
}
#[derive(Clone, Debug, PartialEq)]
pub struct Endpoint {
    pub secure: bool,
    pub host: String,
    pub port: u16,
}
pub fn endpoint(value: &str) -> Result<Endpoint, String> {
    let (secure, rest) = if let Some(r) = value.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = value.strip_prefix("http://") {
        (false, r)
    } else {
        return Err("Use HTTPS, or HTTP on loopback only.".into());
    };
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    if rest.is_empty() || rest.contains(['/', '?', '#', '@', '\\']) {
        return Err("Use an origin only, without path, credentials, query, or fragment.".into());
    }
    let (host, port) = if rest.starts_with('[') {
        let end = rest.find(']').ok_or("Invalid IPv6 host")?;
        let host = &rest[1..end];
        let suffix = &rest[end + 1..];
        let port = if suffix.is_empty() {
            if secure {
                443
            } else {
                80
            }
        } else {
            suffix
                .strip_prefix(':')
                .ok_or("Invalid port")?
                .parse::<u16>()
                .map_err(|_| "Invalid port")?
        };
        (host, port)
    } else {
        let mut parts = rest.split(':');
        let host = parts.next().unwrap_or("");
        let port = parts
            .next()
            .map(str::parse::<u16>)
            .transpose()
            .map_err(|_| "Invalid port")?
            .unwrap_or(if secure { 443 } else { 80 });
        if parts.next().is_some() {
            return Err("Invalid host".into());
        }
        (host, port)
    };
    if host.is_empty()
        || !host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-:".contains(&b))
        || port == 0
    {
        return Err("Invalid host or port".into());
    }
    let loopback = host.eq_ignore_ascii_case("localhost") || host == "127.0.0.1" || host == "::1";
    if !secure && !loopback {
        return Err("HTTP is restricted to loopback; use your private HTTPS endpoint.".into());
    }
    Ok(Endpoint {
        secure,
        host: host.into(),
        port,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn autorepeat_release_reset_and_physical_scan() {
        let mut s = InputState::default();
        assert_eq!(s.key(30, false, false), Some("A"));
        assert_eq!(s.key(30, false, false), None);
        assert_eq!(s.key(30, false, true), None);
        assert_eq!(s.key(30, false, false), Some("A"));
        assert_eq!(s.key(28, true, false), Some("Num Enter"));
        s.reset();
        assert_eq!(s.key(30, false, false), Some("A"));
        assert_eq!(physical_key(56, false), "Alt");
        assert_eq!(physical_key(91, true), "Windows");
        assert_eq!(physical_key(65535, false), "Other")
    }
    #[test]
    fn keypad_physical_keys_stay_distinct_from_typing_and_navigation_keys() {
        // Each pair shares a character or a Num Lock navigation function, but is
        // a different physical key. E0, rather than translated virtual-key text,
        // distinguishes the navigation cluster from the keypad.
        for (scan, typing_scan, label) in [
            (0x52, 0x0b, "Num 0"),
            (0x4f, 0x02, "Num 1"),
            (0x50, 0x03, "Num 2"),
            (0x51, 0x04, "Num 3"),
            (0x4b, 0x05, "Num 4"),
            (0x4c, 0x06, "Num 5"),
            (0x4d, 0x07, "Num 6"),
            (0x47, 0x08, "Num 7"),
            (0x48, 0x09, "Num 8"),
            (0x49, 0x0a, "Num 9"),
            (0x53, 0x34, "Num ."),
            (0x4a, 0x0c, "Num -"),
            (0x59, 0x0d, "Num ="),
        ] {
            assert_eq!(physical_key(scan, false), label);
            assert_ne!(physical_key(scan, false), physical_key(typing_scan, false));
        }
        for (scan, keypad, cluster) in [
            (0x1c, "Return", "Num Enter"),
            (0x35, "/", "Num /"),
            (0x37, "Num *", "PrintScreen"),
            (0x47, "Num 7", "Home"),
            (0x48, "Num 8", "Up"),
            (0x49, "Num 9", "PageUp"),
            (0x4b, "Num 4", "Left"),
            (0x4d, "Num 6", "Right"),
            (0x4f, "Num 1", "End"),
            (0x50, "Num 2", "Down"),
            (0x51, "Num 3", "PageDown"),
            (0x52, "Num 0", "Insert"),
            (0x53, "Num .", "ForwardDelete"),
        ] {
            let mut input = InputState::default();
            assert_eq!(input.key(scan, false, false), Some(keypad));
            assert_eq!(input.key(scan, true, false), Some(cluster));
            assert_eq!(input.key(scan, false, false), None);
            assert_eq!(input.key(scan, true, false), None);
            input.key(scan, false, true);
            assert_eq!(input.key(scan, false, false), Some(keypad));
            assert_eq!(input.key(scan, true, false), None);
            input.reset();
            assert_eq!(input.key(scan, true, false), Some(cluster));
        }
        assert_eq!(physical_key(0x4e, false), "Num +");
        assert_eq!(physical_key(0x45, false), "NumLock");
        assert_eq!(physical_key(0x46, false), "ScrollLock");
        assert_eq!(physical_key(0x54, false), "PrintScreen");
        for scan in [0x1d, 0x38] {
            assert_eq!(physical_key(scan, false), physical_key(scan, true));
        }
        assert_eq!(physical_key(0x5c, true), "Windows");
        assert_eq!(physical_key(0xffff, true), "Other");
    }
    #[test]
    fn normalized_windows_labels_survive_histogram_export_and_replication() {
        use keytrail_core::Engine;
        let mut source = Engine::open(":memory:").unwrap();
        let mut target = Engine::open(":memory:").unwrap();
        let mut input = InputState::default();
        let mut samples = Vec::new();
        let mut expected = serde_json::Map::new();
        // Includes all corrected keypad labels and their formerly merged labels.
        for (scan, extended) in [
            (0x02, false),
            (0x03, false),
            (0x04, false),
            (0x05, false),
            (0x06, false),
            (0x07, false),
            (0x08, false),
            (0x09, false),
            (0x0a, false),
            (0x0b, false),
            (0x0c, false),
            (0x0d, false),
            (0x1c, false),
            (0x34, false),
            (0x35, false),
            (0x37, false),
            (0x45, false),
            (0x46, false),
            (0x47, false),
            (0x48, false),
            (0x49, false),
            (0x4a, false),
            (0x4b, false),
            (0x4c, false),
            (0x4d, false),
            (0x4e, false),
            (0x4f, false),
            (0x50, false),
            (0x51, false),
            (0x52, false),
            (0x53, false),
            (0x59, false),
            (0x1c, true),
            (0x35, true),
            (0x37, true),
            (0x52, true),
        ] {
            let label = input.key(scan, extended, false).unwrap();
            expected.insert(label.into(), json!(1));
            samples.push(sample(
                samples.len() as f64,
                "keyPress",
                Some(label),
                0.0,
                0.0,
            ));
            assert_eq!(input.key(scan, extended, false), None);
            input.key(scan, extended, true);
        }
        // Existing historical "Enter" and scalar operator rows retain their IDs.
        for label in ["Enter", "*", "+"] {
            expected.insert(label.into(), json!(1));
            samples.push(sample(
                samples.len() as f64,
                "keyPress",
                Some(label),
                0.0,
                0.0,
            ));
        }
        let rejected_label = "Num private text";
        samples.push(sample(
            samples.len() as f64,
            "keyPress",
            Some(rejected_label),
            0.0,
            0.0,
        ));
        expected.insert("Other".into(), json!(1));
        source
            .request(&json!({"op":"ingest","samples":samples,"observedThrough":40}).to_string())
            .unwrap();
        let summary_request = r#"{"op":"summary","start":0,"end":60}"#;
        let expected = Value::Object(expected);
        let summary = source.request(summary_request).unwrap();
        assert_eq!(summary["keyCounts"], expected);
        assert_eq!(summary["keyPresses"], 40);
        let export_request = r#"{"op":"export","start":0,"end":60}"#;
        let csv = source.request(export_request).unwrap();
        for label in expected.as_object().unwrap().keys() {
            assert!(
                csv.as_str().unwrap().contains(&format!("{label}:1")),
                "{label}"
            );
        }
        assert!(!csv.as_str().unwrap().contains(rejected_label));
        let changes = source
            .request(r#"{"op":"syncChanges","after":0,"limit":1000}"#)
            .unwrap();
        assert_eq!(changes["changes"][0]["record"]["keyCounts"], expected);
        target
            .request(&json!({"op":"replicaApply","changes":changes["changes"]}).to_string())
            .unwrap();
        assert_eq!(target.request(summary_request).unwrap(), summary);
        assert_eq!(target.request(export_request).unwrap(), csv);
        for invalid in [
            "Num 10",
            "NumLock secret",
            "PrintScreen secret",
            "Insert secret",
            "Num private text",
        ] {
            let mut forged = changes["changes"].clone();
            forged[0]["revision"] = json!(100);
            forged[0]["record"]["keyCounts"] = json!({invalid:40});
            assert!(target
                .request(&json!({"op":"replicaApply","changes":forged}).to_string())
                .is_err());
            assert_eq!(target.request(summary_request).unwrap(), summary);
        }
    }
    #[test]
    fn cursor_distance_is_scalar_display_points_and_resets() {
        let mut s = InputState::default();
        assert_eq!(s.movement(100, 100, 144), None);
        assert!((s.movement(103, 104, 144).unwrap() - 10.0 / 3.0).abs() < 0.000001);
        assert_eq!(s.movement(103, 104, 144), None);
        s.reset();
        assert_eq!(s.movement(-1000, -1000, 96), None)
    }
    #[test]
    fn private_endpoint_validation() {
        assert_eq!(endpoint("https://stats.example:8443/").unwrap().port, 8443);
        assert!(endpoint("http://127.0.0.1:8787").is_ok());
        assert!(endpoint("http://[::1]:8787").is_ok());
        for bad in [
            "http://public.example",
            "https://x/a",
            "https://token@x",
            "https://x?token=secret",
            "https://x#secret",
            "https://x:0",
            "https://x\n",
        ] {
            assert!(endpoint(bad).is_err(), "{bad}")
        }
    }
    #[test]
    fn samples_have_no_content_or_coordinates() {
        let s = sample(60.0, "mouseMove", None, 12.0, 0.0);
        assert_eq!(s["distancePoints"], 12.0);
        assert!(s.get("text").is_none());
        assert!(s.get("x").is_none());
    }
}

/// Sticky first pause/lock/sleep boundary. Do not advance past it until end succeeds.
#[derive(Default)]
pub struct RecoveryCutoff(Option<f64>);
impl RecoveryCutoff {
    pub fn mark(&mut self, time: f64) {
        if self.0.is_none() {
            self.0 = Some(time)
        }
    }
    pub fn pending(&self) -> Option<f64> {
        self.0
    }
    pub fn complete(&mut self, cutoff: f64) {
        if self.0 == Some(cutoff) {
            self.0 = None;
        }
    }
}
#[cfg(test)]
mod recovery_tests {
    use super::*;
    #[test]
    fn failed_end_retries_original_boundary_without_sleep_activity() {
        let dir = std::env::temp_dir().join(format!("keytrail-win-cutoff-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("fixture.sqlite");
        let _ = std::fs::remove_file(&path);
        let mut engine = keytrail_core::Engine::open(path.to_str().unwrap()).unwrap();
        engine.request(r#"{"op":"ingest","samples":[{"timestamp":10,"kind":"keyPress","keyLabel":"A"}],"observedThrough":10}"#).unwrap();
        let db = rusqlite::Connection::open(&path).unwrap();
        db.execute_batch("CREATE TRIGGER fail_pause BEFORE INSERT ON minutes BEGIN SELECT RAISE(ABORT,'fixture');END;").unwrap();
        let mut cutoff = RecoveryCutoff::default();
        cutoff.mark(20.0);
        assert!(engine
            .request(&serde_json::json!({"op":"end","time":cutoff.pending()}).to_string())
            .is_err());
        cutoff.mark(100.0);
        assert_eq!(cutoff.pending(), Some(20.0));
        db.execute_batch("DROP TRIGGER fail_pause").unwrap();
        engine
            .request(&serde_json::json!({"op":"end","time":cutoff.pending()}).to_string())
            .unwrap();
        cutoff.complete(20.0);
        assert!(cutoff.pending().is_none());
        engine.request(r#"{"op":"advance","time":100}"#).unwrap();
        let total = engine
            .request(r#"{"op":"summary","start":0,"end":120}"#)
            .unwrap();
        assert_eq!(total["totalActiveSeconds"], 10);
        drop(db);
        drop(engine);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
