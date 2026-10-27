#!/usr/bin/env python3
"""Actual headless macOS agent timers + loopback replica; synthetic journals only.

Measures committed-journal availability to viewer visibility, not OS input capture,
Internet/HTTPS latency, or a universal network SLA. No syncNow RPC is sent.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import secrets
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--agent", type=pathlib.Path, default=ROOT / "artifacts/KeyTrail-preview.app/Contents/MacOS/KeyTrail")
parser.add_argument("--server", type=pathlib.Path, default=ROOT / "rust/target/release/keytrail-server")
parser.add_argument("--output", type=pathlib.Path, default=ROOT / "artifacts/v1.2-auto-sync-latency.json")
args = parser.parse_args()
args.output.parent.mkdir(parents=True, exist_ok=True)
binary_hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest()
                 for name, path in (("agent", args.agent), ("server", args.server))}

with tempfile.TemporaryDirectory(prefix="kt-latency-", dir="/tmp") as temporary:
    folder = pathlib.Path(temporary)
    local = folder / "local"
    local.mkdir(mode=0o700)
    # Prevent generated demo seeding; this is an empty SQLite v1 fixture.
    with sqlite3.connect(local / "activity.sqlite") as db:
        db.executescript("""
        CREATE TABLE minutes(minute INTEGER PRIMARY KEY,keys INTEGER NOT NULL DEFAULT 0,
          left_clicks INTEGER NOT NULL DEFAULT 0,right_clicks INTEGER NOT NULL DEFAULT 0,
          middle_clicks INTEGER NOT NULL DEFAULT 0,distance REAL NOT NULL DEFAULT 0,
          scroll REAL NOT NULL DEFAULT 0,keyboard_mask INTEGER NOT NULL DEFAULT 0,
          mouse_mask INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE key_histograms(minute INTEGER NOT NULL REFERENCES minutes(minute) ON DELETE CASCADE,
          label TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(minute,label)) WITHOUT ROWID;
        PRAGMA user_version=1;
        """)
    with socket.socket() as port_socket:
        port_socket.bind(("127.0.0.1", 0))
        port = port_socket.getsockname()[1]
    collector, viewer, device = secrets.token_hex(32), secrets.token_hex(32), str(uuid.uuid4())
    config = folder / "server.json"
    config.write_text(json.dumps({"bind": f"127.0.0.1:{port}", "demoData": True,
        "dataDir": str(folder / "replica"), "accounts": [{"id": "fixture", "deviceId": device,
        "collectorToken": collector, "viewerToken": viewer}]}))
    config.chmod(0o600)
    processes = []

    def api(route, body=None):
        req = urllib.request.Request(f"http://127.0.0.1:{port}/api/{route}",
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": "Bearer " + viewer, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=1) as response:
            envelope = json.load(response)
        assert envelope["ok"]
        return envelope["result"]

    def rpc(request):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(2)
            client.connect(str(local / "engine.sock"))
            client.sendall(json.dumps(request).encode() + b"\n")
            data = b""
            while b"\n" not in data:
                chunk = client.recv(65536)
                if not chunk:
                    raise RuntimeError("fixture IPC closed")
                data += chunk
        envelope = json.loads(data.split(b"\n", 1)[0])
        assert envelope["ok"], envelope.get("error")
        return envelope["result"]

    def ready(call):
        deadline = time.monotonic() + 10
        while True:
            try:
                return call()
            except (OSError, ValueError):
                if time.monotonic() >= deadline:
                    raise
                assert all(p.poll() is None for p in processes), "fixture process exited"
                time.sleep(0.05)

    try:
        processes.append(subprocess.Popen([str(args.server), "serve", str(config)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        ready(lambda: api("status"))
        processes.append(subprocess.Popen([str(args.agent), "--demo", "--headless", "--test-directory", str(local)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        status = ready(lambda: rpc({"op": "status"}))
        assert status["isDemo"] and not status["monitoring"]
        rpc({"op": "configureSync", "endpoint": f"http://127.0.0.1:{port}", "deviceId": device,
             "token": collector, "enabled": True})
        deadline = time.monotonic() + 10
        while rpc({"op": "syncStatus"})["syncing"]:
            assert time.monotonic() < deadline
            time.sleep(0.05)
        base = 1704067200
        results = []
        for index, phase in enumerate([0.1, 0.4, 0.9], 1):
            time.sleep(phase)
            minute = base + index * 60
            record = {"keys": 1, "leftClicks": 0, "rightClicks": 0, "middleClicks": 0,
                      "distance": 0, "scroll": 0, "keyboardMask": "1", "mouseMask": "0", "keyCounts": {"A": 1}}
            # An atomic fixture commit models an already-flushed collector journal.
            with sqlite3.connect(local / "activity.sqlite") as db:
                db.execute("INSERT INTO minutes(minute,keys,keyboard_mask) VALUES(?,1,1)", [minute])
                db.execute("INSERT INTO key_histograms VALUES(?,'A',1)", [minute])
                db.execute("UPDATE sync_state SET revision=revision+1 WHERE id=1")
                revision = db.execute("SELECT revision FROM sync_state WHERE id=1").fetchone()[0]
                db.execute("INSERT INTO sync_journal VALUES(?,?,0,?)", [minute, revision, json.dumps(record)])
            started = time.monotonic()
            while True:
                summary = api("query", {"op": "summary", "start": base, "end": base + 600})
                elapsed = time.monotonic() - started
                if summary["keyPresses"] == index:
                    break
                assert elapsed < 3, f"automatic journal sync exceeded 3s: {elapsed:.3f}s"
                time.sleep(0.025)
            assert elapsed < 3
            assert rpc({"op": "syncStatus"})["cursor"] >= revision
            results.append({"sample": index, "phaseDelaySeconds": phase, "visibleAfterSeconds": elapsed})
        output = {"verifiedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "agent": str(args.agent), "samples": results, "allUnderThreeSeconds": True,
                  "binarySHA256": binary_hashes,
                  "manualSyncRequests": 0, "synthetic": True,
                  "scope": "Already committed aggregate journal to viewer visibility through actual macOS agent timers and loopback HTTP; excludes input/flush, HTTPS/Internet and offline backoff"}
        args.output.write_text(json.dumps(output, indent=2) + "\n")
        print(json.dumps(output, indent=2))
    finally:
        if len(processes) > 1 and processes[-1].poll() is None:
            try:
                rpc({"op": "shutdown"})
            except OSError:
                pass
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
