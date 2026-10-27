//! Real loopback HTTP tests. All accounts, credentials and SQLite files are isolated fixtures.
use super::*;
struct HttpReplica {
    _temp: Temp,
    address: SocketAddr,
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<Result<(), String>>>,
}
struct Reply {
    status: u16,
    value: Value,
    bytes: usize,
}
impl HttpReplica {
    fn new() -> Self {
        let temp = Temp::new();
        let service = Service::open(config(&temp.0)).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let signal = stop.clone();
        let worker = std::thread::spawn(move || serve_until(listener, service, signal));
        Self {
            _temp: temp,
            address,
            stop,
            worker: Some(worker),
        }
    }
    fn post(&self, path: &str, scope: Option<&str>, body: Value) -> Reply {
        let bytes = serde_json::to_vec(&body).unwrap();
        let mut stream = TcpStream::connect(self.address).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(15)))
            .unwrap();
        let auth = scope
            .map(|scope| format!("Authorization: Bearer {}\r\n", token(scope)))
            .unwrap_or_default();
        let header=format!("POST {path} HTTP/1.1\r\nHost: {}\r\n{auth}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",self.address,bytes.len());
        stream.write_all(header.as_bytes()).unwrap();
        stream.write_all(&bytes).unwrap();
        let mut response = Vec::new();
        stream.read_to_end(&mut response).unwrap();
        let split = response.windows(4).position(|b| b == b"\r\n\r\n").unwrap() + 4;
        let headers = std::str::from_utf8(&response[..split]).unwrap();
        assert!(headers.contains("Cache-Control: no-store"));
        assert!(!headers.contains("Access-Control-Allow-Origin"));
        let status = headers.split_whitespace().nth(1).unwrap().parse().unwrap();
        let body = &response[split..];
        Reply {
            status,
            value: serde_json::from_slice(body).unwrap(),
            bytes: body.len(),
        }
    }
    fn query(&self, scope: &str, value: Value) -> Reply {
        self.post("/api/query", Some(scope), value)
    }
    fn sync(&self, scope: &str, device: &str, changes: Value) -> Reply {
        self.post(
            "/api/sync",
            Some(scope),
            json!({"deviceId":device,"changes":changes}),
        )
    }
}
impl Drop for HttpReplica {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            worker.join().unwrap().unwrap();
        }
    }
}
fn sample_changes() -> Value {
    json!((0..5)
        .map(|i| change(i + 1, i * 60, i + 1))
        .collect::<Vec<_>>())
}
fn first_page(http: &HttpReplica) -> Value {
    let reply = http.query(
        "viewerA",
        json!({"op":"exportPage","start":0,"end":300,"limit":2}),
    );
    assert_eq!(reply.status, 200, "{}", reply.value);
    reply.value["result"].clone()
}
#[test]
fn real_http_csv_pages_match_legacy_partial_minutes_and_validate_final_snapshot() {
    let http = HttpReplica::new();
    let changes = sample_changes();
    assert_eq!(
        http.sync("collectorA", "mac-a", changes.clone()).status,
        200
    );
    let mut golden = Engine::open(":memory:").unwrap();
    golden
        .request(&json!({"op":"replicaApply","changes":changes}).to_string())
        .unwrap();
    let expected = golden
        .request(r#"{"op":"export","start":30,"end":270}"#)
        .unwrap();
    let mut cursor = Value::Null;
    let mut output = String::new();
    let mut snapshot = Value::Null;
    let mut rows = 0;
    let mut pages = 0;
    loop {
        let reply = http.query(
            "viewerA",
            json!({"op":"exportPage","start":30,"end":270,"cursor":cursor,"limit":2}),
        );
        assert_eq!(reply.status, 200, "{}", reply.value);
        assert!(reply.bytes <= 1024 * 1024);
        let page = &reply.value["result"];
        if pages == 0 {
            snapshot = page["snapshot"].clone();
            output.push_str(page["header"].as_str().unwrap());
        } else {
            assert_eq!(page["snapshot"], snapshot);
        }
        output.push_str(page["csv"].as_str().unwrap());
        rows += page["rowCount"].as_u64().unwrap();
        assert_eq!(page["totalRows"], 5);
        pages += 1;
        if page["hasMore"] == false {
            assert!(page["nextCursor"].is_null());
            break;
        }
        cursor = page["nextCursor"].clone();
        assert!(cursor.is_object());
    }
    assert_eq!(pages, 3);
    assert_eq!(rows, 5);
    assert_eq!(output, expected.as_str().unwrap());
    let verified = http.query(
        "viewerA",
        json!({"op":"exportValidate","snapshot":snapshot}),
    );
    assert_eq!(verified.status, 200);
    assert!(verified.value["result"].is_null());
    let empty = http.query(
        "viewerA",
        json!({"op":"exportPage","start":60.5,"end":60.5}),
    );
    assert_eq!(empty.status, 200);
    assert_eq!(empty.value["result"]["rowCount"], 0);
    assert_eq!(empty.value["result"]["totalRows"], 0);
    assert_eq!(empty.value["result"]["csv"], "");
}
#[test]
fn real_http_cursor_is_bound_to_range_version_and_account_source() {
    let http = HttpReplica::new();
    assert_eq!(
        http.sync("collectorA", "mac-a", sample_changes()).status,
        200
    );
    assert_eq!(
        http.sync("collectorB", "win-b", sample_changes()).status,
        200
    );
    let first = first_page(&http);
    let cursor = first["nextCursor"].clone();
    assert_eq!(
        http.query(
            "viewerA",
            json!({"op":"exportPage","start":60,"end":300,"cursor":cursor})
        )
        .status,
        400
    );
    assert_eq!(
        http.query(
            "viewerB",
            json!({"op":"exportPage","start":0,"end":300,"cursor":cursor})
        )
        .status,
        400
    );
    assert_eq!(
        http.query(
            "viewerB",
            json!({"op":"exportValidate","snapshot":first["snapshot"]})
        )
        .status,
        400
    );
    let mut altered = cursor.clone();
    altered["snapshot"]["revision"] = json!(first["snapshot"]["revision"].as_u64().unwrap() + 1);
    assert_eq!(
        http.query(
            "viewerA",
            json!({"op":"exportPage","start":0,"end":300,"cursor":altered})
        )
        .status,
        400
    );
    assert_eq!(
        http.sync("collectorA", "mac-a", json!([change(20, 600, 7)]))
            .status,
        200
    );
    assert_eq!(
        http.query(
            "viewerA",
            json!({"op":"exportPage","start":0,"end":300,"cursor":cursor})
        )
        .status,
        400
    );
    assert_eq!(
        http.query(
            "viewerA",
            json!({"op":"exportValidate","snapshot":first["snapshot"]})
        )
        .status,
        400
    );
    let refreshed = first_page(&http);
    assert_eq!(refreshed["snapshot"]["id"], first["snapshot"]["id"]);
    assert!(
        refreshed["snapshot"]["revision"].as_u64().unwrap()
            > first["snapshot"]["revision"].as_u64().unwrap()
    );
}
#[test]
fn real_http_export_reads_do_not_grant_write_scope_or_accept_nested_mutation_fields() {
    let http = HttpReplica::new();
    assert_eq!(
        http.sync("collectorA", "mac-a", sample_changes()).status,
        200
    );
    let first = first_page(&http);
    for op in [
        json!({"op":"exportPage","start":0,"end":300}),
        json!({"op":"exportValidate","snapshot":first["snapshot"]}),
    ] {
        assert_eq!(http.post("/api/query", None, op.clone()).status, 401);
        assert_eq!(http.query("collectorA", op).status, 200);
    }
    assert_eq!(http.sync("viewerA", "mac-a", json!([])).status, 403);
    for op in [
        json!({"op":"exportPage","start":0,"end":300,"changes":[]}),
        json!({"op":"clear"}),
        json!({"op":"delete","start":0,"end":300}),
        json!({"op":"exportValidate","snapshot":{"id":first["snapshot"]["id"],"revision":first["snapshot"]["revision"],"op":"clear"}}),
    ] {
        assert_eq!(http.query("viewerA", op).status, 400)
    }
    for limit in [json!(0), json!(1001), json!(-1), json!(2.5), Value::Null] {
        assert_eq!(
            http.query(
                "viewerA",
                json!({"op":"exportPage","start":0,"end":300,"limit":limit})
            )
            .status,
            400
        )
    }
    let mut cursor = first["nextCursor"].clone();
    cursor["afterMinute"] = json!(61);
    assert_eq!(
        http.query(
            "viewerA",
            json!({"op":"exportPage","start":0,"end":300,"cursor":cursor})
        )
        .status,
        400
    );
    let mut deep = json!(0);
    for _ in 0..8 {
        deep = json!({"nested":deep});
    }
    assert_eq!(
        http.query(
            "viewerA",
            json!({"op":"exportPage","start":0,"end":300,"cursor":deep})
        )
        .status,
        400
    );
    let summary = http.query("viewerA", json!({"op":"summary","start":0,"end":300}));
    assert_eq!(summary.status, 200);
    assert_eq!(summary.value["result"]["keyPresses"], 15);
    assert_eq!(
        http.query(
            "viewerA",
            json!({"op":"exportValidate","snapshot":first["snapshot"]})
        )
        .status,
        200
    );
}
#[test]
fn local_view_export_apis_share_same_source_and_remain_read_only() {
    let engine = Arc::new(Mutex::new(Engine::open(":memory:").unwrap()));
    engine
        .lock()
        .unwrap()
        .request(&json!({"op":"replicaApply","changes":sample_changes()}).to_string())
        .unwrap();
    let token = token("localPages");
    let auth = format!("Bearer {token}");
    let mut local =
        Service::local_view(engine.clone(), token, "local-fixture".into(), true).unwrap();
    let page = local.handle(
        "POST",
        "/api/query",
        Some(&auth),
        br#"{"op":"exportPage","start":0,"end":300,"limit":2}"#,
    );
    assert_eq!(page.status, 200);
    let value: Value = serde_json::from_slice(&page.body).unwrap();
    let validate = local.handle(
        "POST",
        "/api/query",
        Some(&auth),
        &serde_json::to_vec(&json!({"op":"exportValidate","snapshot":value["result"]["snapshot"]}))
            .unwrap(),
    );
    assert_eq!(validate.status, 200);
    for op in [
        json!({"op":"clear"}),
        json!({"op":"replicaApply","changes":[]}),
        json!({"op":"delete","start":0,"end":300}),
    ] {
        assert_eq!(
            local
                .handle(
                    "POST",
                    "/api/query",
                    Some(&auth),
                    &serde_json::to_vec(&op).unwrap()
                )
                .status,
            400
        )
    }
    assert_eq!(
        local.handle("POST", "/api/sync", Some(&auth), b"{}").status,
        403
    );
    engine.lock().unwrap().request(r#"{"op":"clear"}"#).unwrap();
    assert_eq!(
        local
            .handle(
                "POST",
                "/api/query",
                Some(&auth),
                &serde_json::to_vec(
                    &json!({"op":"exportValidate","snapshot":value["result"]["snapshot"]})
                )
                .unwrap()
            )
            .status,
        400
    );
}
#[test]
fn real_http_dense_export_pages_respect_complete_response_json_budget() {
    let http = HttpReplica::new();
    let mut labels: Vec<String> = (b'A'..=b'Z')
        .chain(b'0'..=b'9')
        .map(|v| (v as char).to_string())
        .collect();
    labels.extend((1..=20).map(|v| format!("F{v}")));
    labels.extend(
        [
            "Space",
            "Return",
            "Enter",
            "Tab",
            "Escape",
            "Delete",
            "Backspace",
            "ForwardDelete",
            "CapsLock",
            "Shift",
            "Control",
            "Alt",
            "Windows",
            "Left",
            "Right",
            "Up",
            "Down",
            "Home",
            "End",
            "PageUp",
        ]
        .iter()
        .map(|s| s.to_string()),
    );
    let histogram: serde_json::Map<String, Value> = labels
        .iter()
        .map(|s| (s.clone(), json!(100_000_000_000u64)))
        .collect();
    for chunk in 0..10 {
        let changes: Vec<Value> = (chunk * 100..chunk * 100 + 100)
            .map(|i| {
                let mut row = change(i + 1, i * 60, labels.len() as u64 * 100_000_000_000);
                row["record"]["keyCounts"] = Value::Object(histogram.clone());
                row
            })
            .collect();
        let reply = http.sync("collectorA", "mac-a", json!(changes));
        assert_eq!(reply.status, 200, "{}", reply.value);
    }
    let first = http.query(
        "viewerA",
        json!({"op":"exportPage","start":0,"end":60000,"limit":1000}),
    );
    assert_eq!(first.status, 200, "{}", first.value);
    assert!(first.bytes <= 1024 * 1024);
    let page = &first.value["result"];
    let count = page["rowCount"].as_u64().unwrap();
    assert!(count > 0 && count < 1000);
    assert_eq!(page["hasMore"], true);
    assert_eq!(page["totalRows"], 1000);
    let next = http.query(
        "viewerA",
        json!({"op":"exportPage","start":0,"end":60000,"limit":1000,"cursor":page["nextCursor"]}),
    );
    assert_eq!(next.status, 200);
    assert!(next.bytes <= 1024 * 1024);
    assert_eq!(
        count + next.value["result"]["rowCount"].as_u64().unwrap(),
        1000
    );
    assert_eq!(next.value["result"]["hasMore"], false);
}

#[test]
fn real_http_trend_spans_selected_years_without_write_scope_or_account_leakage() {
    let http = HttpReplica::new();
    let day = 86400u64;
    let end = 3 * 365 * day;
    assert_eq!(http.sync("collectorA", "mac-a", json!([
        change(1, 0, 5), change(2, 400 * day, 7), change(3, 800 * day, 11)
    ])).status, 200);
    let before = http.query("viewerA", json!({"op":"exportPage","start":0,"end":end}));
    assert_eq!(before.status, 200);
    let ranges: Vec<_> = (0..3).map(|i| json!({"start":i * 365 * day,"end":(i+1) * 365 * day})).collect();
    let request = json!({"op":"trend","ranges":ranges});
    for scope in ["viewerA", "collectorA"] {
        let result = http.query(scope, request.clone());
        assert_eq!(result.status, 200, "{}", result.value);
        let values = result.value["result"].as_array().unwrap();
        assert_eq!(values.iter().map(|v| v["summary"]["keyPresses"].as_u64().unwrap()).collect::<Vec<_>>(), vec![5,7,11]);
        assert!(values.iter().all(|v| v["summary"]["keyCounts"] == json!({})));
    }
    let other = http.query("viewerB", request.clone());
    assert_eq!(other.status, 200);
    assert!(other.value["result"].as_array().unwrap().iter().all(|v| v["summary"]["keyPresses"] == 0));
    assert_eq!(http.post("/api/query", None, request).status, 401);
    assert_eq!(http.sync("viewerA", "mac-a", json!([])).status, 403);
    for op in ["delete", "retention", "ingest", "replicaApply"] {
        assert_eq!(http.query("viewerA", json!({"op":op,"ranges":[]})).status, 400);
    }
    let after = http.query("viewerA", json!({"op":"exportPage","start":0,"end":end}));
    assert_eq!(before.value["result"]["snapshot"], after.value["result"]["snapshot"]);
    assert_eq!(before.value["result"]["csv"], after.value["result"]["csv"]);
}

#[test]
fn real_http_trend_keeps_bounded_ranges_and_existing_operation_limits() {
    let http = HttpReplica::new();
    let ranges: Vec<_> = (0..400).map(|i| json!({"start":i*60,"end":(i+1)*60})).collect();
    let reply = http.query("viewerA", json!({"op":"trend","ranges":ranges}));
    assert_eq!(reply.status, 200, "{}", reply.value);
    assert_eq!(reply.value["result"].as_array().unwrap().len(), 400);
    assert_eq!(http.query("viewerA", json!({"op":"trend","ranges":[]})).status, 200);
    for op in ["timeline", "summaries"] {
        assert_eq!(http.query("viewerA", json!({"op":op,"ranges":ranges})).status, 400);
    }
    let too_many: Vec<_> = (0..401).map(|i| json!({"start":i*60,"end":(i+1)*60})).collect();
    let excessive_span = 100u64 * 366 * 86400;
    for invalid in [
        json!({"op":"trend","ranges":too_many}),
        json!({"op":"trend","ranges":[{"start":0,"end":60,"op":"delete"}]}),
        json!({"op":"trend","ranges":[{"start":0,"end":60}],"changes":[]}),
        json!({"op":"trend","ranges":[{"start":1,"end":60}]}),
        json!({"op":"trend","ranges":[{"start":0,"end":120},{"start":60,"end":180}]}),
        json!({"op":"trend","ranges":[{"start":0,"end":368u64*86400}]}),
        json!({"op":"trend","ranges":[{"start":0,"end":60},{"start":excessive_span,"end":excessive_span+60}]}),
    ] {
        assert_eq!(http.query("viewerA", invalid.clone()).status, 400, "accepted: {invalid}");
    }
}
