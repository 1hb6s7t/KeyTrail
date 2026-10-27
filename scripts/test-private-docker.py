#!/usr/bin/env python3
"""Exercise the actual Linux image using an ephemeral private volume and synthetic data."""
import json
import hashlib
import datetime
import os
import pathlib
import secrets
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
IMAGE = os.environ.get("KEYTRAIL_DOCKER_IMAGE", "keytrail-private:1.2")
OUTPUT = pathlib.Path(os.environ.get("KEYTRAIL_DOCKER_OUTPUT", ROOT / "artifacts/private-docker/verification.json"))
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
checks = []
result = {"image": IMAGE, "passed": False, "stage": "preflight", "groups": checks,
          "startedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "data": "temporary synthetic fixture only", "externalTLSorPhoneDevice": "not exercised"}
# Invalidate any previous pass before asset reads, port allocation or Docker calls.
OUTPUT.write_text(json.dumps(result, indent=2) + "\n")
FROZEN_ASSETS = {p.name: p.read_bytes() for p in (ROOT / "web").iterdir() if p.is_file()}
assert len(FROZEN_ASSETS) == 8
name = "kt-fixture-" + uuid.uuid4().hex[:10]
volume = name + "-state"
collector, viewer = secrets.token_hex(32), secrets.token_hex(32)
device = str(uuid.uuid4())


def docker(*args, **kwargs):
    return subprocess.run(["docker", *args], check=True, capture_output=True, **kwargs).stdout


with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]


def request(route, body=None, token=viewer):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}{route}", data=data)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        response = urllib.request.urlopen(req, timeout=3)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read()
        return response.status, json.loads(raw) if route.startswith("/api/") else raw, dict(response.headers)


def ready():
    for _ in range(100):
        try:
            code, value, _ = request("/api/status")
            if code == 200:
                return value["result"]
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    raise AssertionError("container readiness timeout")


try:
    result["stage"] = "container-checks"
    docker("volume", "create", volume)
    config = {"bind": "0.0.0.0:8787", "dataDir": "/state/data", "demoData": True,
              "accounts": [{"id": "fixture", "deviceId": device, "collectorToken": collector, "viewerToken": viewer}]}
    # stdin keeps the test credentials out of argv, logs and tool output.
    docker("run", "--rm", "-i", "--entrypoint", "sh", "-v", volume + ":/state", IMAGE,
           "-c", "umask 077; cat > /state/config.json", input=json.dumps(config).encode())
    docker("run", "-d", "--name", name, "--read-only", "--cap-drop=ALL", "--pids-limit=32",
           "--memory=256m", "--security-opt=no-new-privileges:true", "-p", f"127.0.0.1:{port}:8787",
           "-v", volume + ":/state", IMAGE)
    status = ready()
    inspection = json.loads(docker("inspect", name))[0]
    assert inspection["Config"]["User"] == "10001:10001"
    assert inspection["HostConfig"]["ReadonlyRootfs"]
    assert inspection["HostConfig"]["PortBindings"]["8787/tcp"][0]["HostIp"] == "127.0.0.1"
    assert inspection["HostConfig"]["CapDrop"] == ["ALL"]
    assert request("/api/status", token=None)[0] == 401
    code, html, headers = request("/", token=None)
    assert code == 200 and b"KEYTRAIL" in html and "Content-Security-Policy" in headers
    assets = {}
    for filename, expected in FROZEN_ASSETS.items():
        code, served, _ = request("/" + filename, token=None)
        assert code == 200 and served == expected, "image has stale embedded web asset: " + filename
        assets[filename] = hashlib.sha256(served).hexdigest()
    checks.append("non-root/read-only/loopback container, authenticated API and embedded CSP viewer")
    change = {"revision": 1, "minute": 1704067200, "deleted": False, "record": {
        "keys": 2, "leftClicks": 1, "rightClicks": 0, "middleClicks": 0, "distance": 12.5,
        "scroll": 0, "keyboardMask": "3", "mouseMask": "2", "keyCounts": {"A": 2}}}
    body = {"deviceId": device, "changes": [change]}
    assert request("/api/sync", body)[0] == 403
    assert request("/api/sync", body, collector)[1]["result"]["applied"] == 1
    assert request("/api/sync", body, collector)[1]["result"]["ignored"] == 1
    query = {"op": "summary", "start": 1704067200, "end": 1704067260}
    assert request("/api/query", query)[1]["result"]["keyPresses"] == 2
    csv_query = {"op": "exportPage", "start": 1704067200, "end": 1704067260, "limit": 1}
    csv_page = request("/api/query", csv_query)[1]["result"]
    assert csv_page["rowCount"] == csv_page["totalRows"] == 1 and not csv_page["hasMore"]
    assert "minute_utc," in csv_page["header"] and "A:2" in csv_page["csv"]
    csv_validation = {"op": "exportValidate", "snapshot": csv_page["snapshot"]}
    assert request("/api/query", csv_validation)[0] == 200
    # Both credentials may read this account's aggregate statistics; only viewer
    # credentials may query encrypted text. Keep the established role contract.
    collector_csv = request("/api/query", csv_query, collector)
    assert collector_csv[0] == 200 and collector_csv[1]["result"] == csv_page
    checks.append("role isolation and idempotent aggregate ingest")
    record = json.loads((ROOT / "artifacts/text-interop/swift-record.json").read_text())
    text_change = {"revision": 1, "id": record["metadata"]["id"], "deleted": False, "record": record}
    assert request("/api/text-sync", {"deviceId": device, "changes": [text_change]}, collector)[0] == 200
    stamp = record["metadata"]["timestamp"]
    text_query = {"start": stamp - 1, "end": stamp + 1, "limit": 10}
    assert request("/api/text-query", text_query)[1]["result"]["records"] == [record]
    assert request("/api/text-query", text_query, collector)[0] == 403
    checks.append("Swift authenticated ciphertext traverses Linux replica unchanged; text roles isolated")
    docker("restart", name)
    restarted = ready()
    assert restarted["replicaId"] == status["replicaId"]
    assert restarted["textReplicaId"] == status["textReplicaId"]
    assert request("/api/query", query)[1]["result"]["keyPresses"] == 2
    checks.append("container restart retains independent replica identities and data")
    assert request("/api/query", csv_validation)[0] == 200
    deletion = {"revision": 2, "minute": 1704067200, "deleted": True, "record": None}
    assert request("/api/sync", {"deviceId": device, "changes": [deletion]}, collector)[0] == 200
    assert request("/api/sync", body, collector)[1]["result"]["ignored"] == 1
    assert request("/api/query", query)[1]["result"]["keyPresses"] == 0
    assert request("/api/query", csv_validation)[0] == 400
    csv_empty = request("/api/query", csv_query)[1]["result"]
    assert csv_empty["rowCount"] == csv_empty["totalRows"] == 0 and csv_empty["csv"] == ""
    checks.append("CSV page reads are role-isolated; snapshot survives restart and expires on deletion")
    text_change.update(revision=2, deleted=True, record=None)
    assert request("/api/text-sync", {"deviceId": device, "changes": [text_change]}, collector)[0] == 200
    assert request("/api/text-query", text_query)[1]["result"]["total"] == 0
    checks.append("aggregate and ciphertext tombstones delete and reject old replay")
    image = json.loads(docker("image", "inspect", IMAGE))[0]
    assert FROZEN_ASSETS == {p.name: p.read_bytes() for p in (ROOT / "web").iterdir() if p.is_file()}, "web source changed during fixture"
    result.update(passed=True, imageBytes=image["Size"], imageID=image["Id"],
                  architecture=image["Architecture"], embeddedWebSHA256=assets)
except Exception as error:
    # Exception text may contain transport details; do not copy credentials or
    # request bodies to the report. The failing stage remains visible in groups.
    result["errorType"] = type(error).__name__
    raise
finally:
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    subprocess.run(["docker", "volume", "rm", volume], capture_output=True)
    try:
        # A failed inspect can also mean daemon failure, so require successful
        # inventories before claiming the owned resources were removed.
        containers = docker("container", "ls", "-a", "--format", "{{.Names}}").decode().splitlines()
        volumes = docker("volume", "ls", "--format", "{{.Name}}").decode().splitlines()
        result["cleanup"] = {"ownedContainerRemoved": name not in containers, "ownedVolumeRemoved": volume not in volumes}
    except Exception:
        result["cleanup"] = {"verified": False}
    result["passed"] = result["passed"] and all(result["cleanup"].values())
    result["stage"] = "complete" if result["passed"] else "failed"
    result["finishedAtUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    OUTPUT.write_text(json.dumps(result, indent=2) + "\n")
if not result["passed"]:
    raise SystemExit("Private Docker fixture or cleanup failed; see verification report")
print(f"Passed {len(checks)} actual Linux-container integration groups; owned fixture resources removed")
