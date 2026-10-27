use super::*;
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let p =
            std::env::temp_dir().join(format!("keytrail-server-test-{}", random_hex().unwrap()));
        Self(p)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn token(s: &str) -> String {
    format!("{s}{}", "x".repeat(64))
}
fn config(path: &Path) -> Config {
    Config {
        bind: "127.0.0.1:0".into(),
        demo_data: true,
        data_dir: path.to_path_buf(),
        accounts: vec![
            AccountConfig {
                id: "a".into(),
                device_id: "mac-a".into(),
                collector_token: token("collectorA"),
                viewer_token: token("viewerA"),
            },
            AccountConfig {
                id: "b".into(),
                device_id: "win-b".into(),
                collector_token: token("collectorB"),
                viewer_token: token("viewerB"),
            },
        ],
    }
}
fn call(s: &mut Service, method: &str, path: &str, which: &str, body: Value) -> (u16, Value) {
    let credential = format!("Bearer {}", token(which));
    let r = s.handle(
        method,
        path,
        Some(&credential),
        &serde_json::to_vec(&body).unwrap(),
    );
    (r.status, serde_json::from_slice(&r.body).unwrap())
}
fn change(rev: u64, minute: u64, keys: u64) -> Value {
    json!({"revision":rev,"minute":minute,"deleted":false,"record":{"keys":keys,"leftClicks":2,"rightClicks":1,"middleClicks":0,"distance":15.5,"scroll":2.0,"keyboardMask":"3","mouseMask":"6","keyCounts":{"A":keys}}})
}
fn upload(s: &mut Service, changes: Value) -> (u16, Value) {
    call(
        s,
        "POST",
        "/api/sync",
        "collectorA",
        json!({"deviceId":"mac-a","changes":changes}),
    )
}
fn total(s: &mut Service, which: &str, start: u64, end: u64) -> Value {
    let (status, v) = call(
        s,
        "POST",
        "/api/query",
        which,
        json!({"op":"summary","start":start,"end":end}),
    );
    assert_eq!(status, 200, "{v}");
    v["result"].clone()
}
#[test]
fn authentication_scopes_account_isolation_and_bound_device() {
    let temp = Temp::new();
    let mut s = Service::open(config(&temp.0)).unwrap();
    assert_eq!(s.handle("GET", "/api/status", None, b"").status, 401);
    assert_eq!(
        s.handle("GET", "/api/status", Some("Bearer fake"), b"")
            .status,
        401
    );
    assert_eq!(
        call(
            &mut s,
            "POST",
            "/api/sync",
            "viewerA",
            json!({"deviceId":"mac-a","changes":[]})
        )
        .0,
        403
    );
    assert_eq!(
        call(
            &mut s,
            "POST",
            "/api/sync",
            "collectorA",
            json!({"deviceId":"win-b","changes":[]})
        )
        .0,
        403
    );
    assert_eq!(upload(&mut s, json!([change(1, 60, 5)])).0, 200);
    assert_eq!(total(&mut s, "viewerA", 0, 120)["keyPresses"], 5);
    assert_eq!(total(&mut s, "viewerB", 0, 120)["keyPresses"], 0);
    for which in ["viewerA", "collectorA"] {
        assert_eq!(
            call(&mut s, "GET", "/api/status", which, Value::Null).0,
            200
        )
    }
    for op in [
        "ingest",
        "clear",
        "delete",
        "retention",
        "replicaApply",
        "syncChanges",
    ] {
        assert_eq!(
            call(
                &mut s,
                "POST",
                "/api/query",
                "viewerA",
                json!({"op":op,"start":0,"end":120})
            )
            .0,
            400
        )
    }
}
#[test]
fn retry_tombstones_out_of_order_and_persistent_identity() {
    let temp = Temp::new();
    let mut s = Service::open(config(&temp.0)).unwrap();
    let before = call(&mut s, "GET", "/api/status", "viewerA", Value::Null).1;
    assert_eq!(before["result"]["lastSyncedAt"], Value::Null);
    let payload = json!([change(1, 60, 5), change(2, 120, 8)]);
    assert_eq!(upload(&mut s, payload.clone()).1["result"]["applied"], 2);
    let retry = upload(&mut s, payload);
    assert_eq!(retry.1["result"]["ignored"], 2);
    assert_eq!(retry.1["result"]["cursor"], 2);
    assert_eq!(
        upload(
            &mut s,
            json!([{"revision":3,"minute":60,"deleted":true,"record":null}])
        )
        .0,
        200
    );
    assert_eq!(
        upload(&mut s, json!([change(1, 60, 100)])).1["result"]["ignored"],
        1
    );
    assert_eq!(total(&mut s, "viewerA", 0, 180)["keyPresses"], 8);
    let status = call(&mut s, "GET", "/api/status", "viewerA", Value::Null).1;
    assert_eq!(status["result"]["cursor"], 3);
    drop(s);
    let mut reopened = Service::open(config(&temp.0)).unwrap();
    assert_eq!(
        call(&mut reopened, "GET", "/api/status", "viewerA", Value::Null).1,
        status
    );
    assert_eq!(total(&mut reopened, "viewerA", 0, 180)["keyPresses"], 8);
    assert_eq!(
        upload(&mut reopened, json!([change(2, 60, 50)])).1["result"]["ignored"],
        1
    );
    drop(reopened);
    fs::remove_file(temp.0.join("a/replica.sqlite")).unwrap();
    let mut rebuilt = Service::open(config(&temp.0)).unwrap();
    assert_ne!(
        call(&mut rebuilt, "GET", "/api/status", "viewerA", Value::Null).1["result"]["replicaId"],
        status["result"]["replicaId"]
    );
}
#[test]
fn half_open_totals_and_large_masks() {
    let temp = Temp::new();
    let mut s = Service::open(config(&temp.0)).unwrap();
    let mut a = change(1, 60, 5);
    a["record"]["keyboardMask"] = json!("1152921504606846975");
    assert_eq!(upload(&mut s, json!([a, change(2, 120, 8)])).0, 200);
    let first = total(&mut s, "viewerA", 60, 120);
    assert_eq!(first["keyPresses"], 5);
    assert_eq!(first["totalActiveSeconds"], 60);
    assert_eq!(first["mouseDistancePoints"], 15.5);
    assert_eq!(total(&mut s, "viewerA", 120, 180)["keyPresses"], 8);
    assert_eq!(total(&mut s, "viewerA", 0, 60)["keyPresses"], 0);
    let result = call(
        &mut s,
        "POST",
        "/api/query",
        "viewerA",
        json!({"op":"timeline","ranges":[{"start":60,"end":120},{"start":120,"end":180}]}),
    );
    assert_eq!(result.0, 200);
    assert_eq!(result.1["result"][1]["summary"]["keyPresses"], 8);
}
#[test]
fn malformed_batches_rejected_atomically() {
    let temp = Temp::new();
    let mut s = Service::open(config(&temp.0)).unwrap();
    let cases = [
        json!({"revision":0,"minute":60,"deleted":true,"record":null}),
        json!({"revision":1,"minute":61,"deleted":true,"record":null}),
        json!({"revision":1,"minute":60,"deleted":true,"record":{}}),
        {
            let mut c = change(1, 60, 5);
            c["record"]["keyboardMask"] = json!(1152921504606846975u64);
            c
        },
        {
            let mut c = change(1, 60, 5);
            c["record"]["keys"] = json!(-1);
            c
        },
        {
            let mut c = change(1, 60, 5);
            c["record"]["keyCounts"] = json!({"<script>":5});
            c
        },
    ];
    for c in cases {
        assert_eq!(upload(&mut s, json!([change(5, 120, 7), c])).0, 400);
        assert_eq!(total(&mut s, "viewerA", 0, 180)["keyPresses"], 0)
    }
    assert_eq!(
        s.handle(
            "POST",
            "/api/sync",
            Some(&format!("Bearer {}", token("collectorA"))),
            b"{"
        )
        .status,
        400
    );
    assert_eq!(upload(&mut s, json!(vec![change(1, 60, 1); 1001])).0, 400);
    assert_eq!(
        call(
            &mut s,
            "POST",
            "/api/query",
            "viewerA",
            json!({"op":"summary","start":0,"end":120,"file":"/etc/passwd"})
        )
        .0,
        400
    );
    assert_eq!(
        call(
            &mut s,
            "POST",
            "/api/query",
            "viewerA",
            json!({"op":"buckets","start":0,"end":1000000,"stepSeconds":60})
        )
        .0,
        400
    );
}
#[test]
fn init_private_config_and_distinct_secrets() {
    let temp = Temp::new();
    let path = temp.0.join("config.json");
    initialize(
        &path,
        temp.0.join("data"),
        "127.0.0.1:0".into(),
        "personal".into(),
        "macbook".into(),
    )
    .unwrap();
    let c = load_config(&path).unwrap();
    assert_ne!(c.accounts[0].viewer_token, c.accounts[0].collector_token);
    assert_eq!(c.accounts[0].collector_token.len(), 64);
    assert!(initialize(
        &path,
        temp.0.join("data"),
        "127.0.0.1:0".into(),
        "personal".into(),
        "macbook".into()
    )
    .is_err());
    #[cfg(unix)]
    {
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(load_config(&path).is_err())
    }
}
fn parse_http(bytes: &[u8]) -> Result<RequestParts, u16> {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let payload = bytes.to_vec();
    let writer = std::thread::spawn(move || {
        let mut s = TcpStream::connect(addr).unwrap();
        let _ = s.write_all(&payload);
        let _ = s.shutdown(std::net::Shutdown::Write);
    });
    let (mut socket, _) = listener.accept().unwrap();
    let r = read_request(&mut socket);
    writer.join().unwrap();
    r
}
#[test]
fn bounded_http_rejects_ambiguous_framing_and_url_tokens() {
    for request in [b"POST /api/sync HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n".as_slice(),b"POST /api/sync HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",b"GET /api/status?token=secret HTTP/1.1\r\n\r\n",b"POST /api/sync HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}",b"POST /api/sync HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 999999999\r\n\r\n"]{assert!(parse_http(request).is_err())}
    let valid=parse_http(b"POST /api/query HTTP/1.1\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 2\r\n\r\n{}").unwrap();
    assert_eq!(valid.3, b"{}");
    let oversized = format!(
        "GET / HTTP/1.1\r\nX-Pad: {}\r\n\r\n",
        "x".repeat(MAX_HEADER)
    );
    assert_eq!(parse_http(oversized.as_bytes()).unwrap_err(), 431)
}
#[test]
fn shell_static_only_and_no_cacheable_api_response() {
    let temp = Temp::new();
    let mut s = Service::open(config(&temp.0)).unwrap();
    assert_eq!(s.handle("GET", "/", None, b"").status, 200);
    for path in [
        "/../config.json",
        "/metadata.json",
        "/api/status/",
        "/api/query",
    ] {
        assert_ne!(s.handle("GET", path, None, b"").status, 200)
    }
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let receiver = std::thread::spawn(move || {
        let mut c = TcpStream::connect(addr).unwrap();
        let mut output = String::new();
        c.read_to_string(&mut output).unwrap();
        output
    });
    let (mut socket, _) = listener.accept().unwrap();
    send_response(&mut socket, success(json!({"deviceId":"demo"}))).unwrap();
    drop(socket);
    let http = receiver.join().unwrap();
    assert!(http.contains("Cache-Control: no-store"));
    assert!(http.contains("frame-ancestors 'none'"));
    assert!(!http.contains("Access-Control-Allow-Origin"));
}

#[test]
fn local_view_shares_resident_engine_and_can_never_write() {
    let engine = Arc::new(Mutex::new(Engine::open(":memory:").unwrap()));
    let credential = token("ephemeralLocal");
    let mut viewer = Service::local_view(
        engine.clone(),
        credential.clone(),
        "local-fixture".into(),
        true,
    )
    .unwrap();
    let auth = format!("Bearer {credential}");
    let before = viewer.handle(
        "POST",
        "/api/query",
        Some(&auth),
        br#"{"op":"summary","start":0,"end":60}"#,
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&before.body).unwrap()["result"]["keyPresses"],
        0
    );
    engine.lock().unwrap().request(r#"{"op":"ingest","observedThrough":30,"samples":[{"timestamp":1,"kind":"keyPress","keyLabel":"A"}]}"#).unwrap();
    let after = viewer.handle(
        "POST",
        "/api/query",
        Some(&auth),
        br#"{"op":"summary","start":0,"end":60}"#,
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&after.body).unwrap()["result"]["keyPresses"],
        1
    );
    assert_eq!(
        viewer
            .handle(
                "POST",
                "/api/sync",
                Some(&auth),
                br#"{"deviceId":"local-fixture","changes":[]}"#
            )
            .status,
        403
    );
    assert_eq!(
        viewer
            .handle("POST", "/api/query", Some(&auth), br#"{"op":"clear"}"#)
            .status,
        400
    );
}

#[test]
fn long_scalar_ranges_are_independent_of_output_and_bucket_budgets() {
    let temp = Temp::new();
    let mut service = Service::open(config(&temp.0)).unwrap();
    assert_eq!(upload(&mut service, json!([change(1, 60, 5)])).0, 200);
    let century = 100u64 * 366 * 86400;
    for operation in ["summary", "insights", "export"] {
        let (status, value) = call(
            &mut service,
            "POST",
            "/api/query",
            "viewerA",
            json!({"op":operation,"start":0,"end":century}),
        );
        assert_eq!(status, 200, "{operation}: {value}");
        if operation == "summary" {
            assert_eq!(value["result"]["keyPresses"], 5);
        }
        assert_eq!(
            call(
                &mut service,
                "POST",
                "/api/query",
                "viewerA",
                json!({"op":operation,"start":0,"end":century+60})
            )
            .0,
            400
        );
    }
    assert_eq!(call(&mut service,"POST","/api/query","viewerA",json!({"op":"buckets","start":0,"end":century*2,"stepSeconds":366*86400,"includeKeyCounts":false})).0,200);
    assert_eq!(
        validate_query(&json!({"op":"buckets","start":0,"end":600000,"stepSeconds":60})),
        Ok(())
    );
    assert!(
        validate_query(&json!({"op":"buckets","start":0,"end":600060,"stepSeconds":60})).is_err()
    );
    assert!(validate_query(&json!({"op":"summary","start":1e12-120.0,"end":1e12})).is_err());
    assert!(validate_query(&json!({"op":"buckets","start":0,"end":60,"stepSeconds":-1})).is_err());
}

#[path = "export_http_tests.rs"]
mod export_http_tests;
