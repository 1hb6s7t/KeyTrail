#!/usr/bin/env python3
"""Check the shipped nginx fragment over verified TLS using disposable containers.

Uses installed images only. A temporary CA is trusted only by this test's SSL
context; no OS/browser trust settings, real databases, or external hosts change.
"""
import hashlib
import io
import json
import os
import pathlib
import secrets
import socket
import ssl
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[1]
ART = ROOT / "artifacts"
SERVICE_IMAGE = os.environ.get("KEYTRAIL_HTTPS_SERVICE_IMAGE", "keytrail-private:v1.2-followup")
PROXY_IMAGE = os.environ.get("KEYTRAIL_HTTPS_PROXY_IMAGE", "nginx:1.27-alpine")
OUTPUT = pathlib.Path(os.environ.get("KEYTRAIL_HTTPS_OUTPUT", str(ART / "v12-platform/https")))


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, timeout=60, **kwargs).stdout


def docker(*args, **kwargs):
    return run(["docker", *args], **kwargs)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def populate(volume, files):
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        for name, data in files.items():
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode, entry.uid, entry.gid = len(data), 0o600, 10001, 10001
            tar.addfile(entry, io.BytesIO(data))
    docker("run", "--rm", "-i", "--network", "none", "--entrypoint", "sh",
           "--mount", f"type=volume,src={volume},dst=/state", SERVICE_IMAGE,
           "-c", "umask 077; tar -xf - -C /state", input=archive.getvalue())


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    frozen_assets = {file.name: file.read_bytes() for file in (ROOT / "web").iterdir() if file.is_file()}
    assert len(frozen_assets) == 8
    tag = "kt-tls-" + uuid.uuid4().hex[:10]
    service, proxy, network = tag + "-service", tag + "-proxy", tag + "-network"
    state, certificates = tag + "-state", tag + "-certs"
    result = {"verifiedAtUTC": datetime.now(timezone.utc).isoformat(), "passed": False,
              "syntheticDataOnly": True, "externalNetworkTested": False,
              "systemTrustChanged": False, "groups": [], "cleanup": {}}
    credentials = [secrets.token_hex(32), secrets.token_hex(32)]
    collector, viewer = credentials
    device = "tls-synthetic-device"
    resources = []
    with socket.socket() as free:
        free.bind(("127.0.0.1", 0))
        port = free.getsockname()[1]
    try:
        for image in [SERVICE_IMAGE, PROXY_IMAGE]:
            info = json.loads(docker("image", "inspect", image))[0]
            result.setdefault("images", {})[image] = {"id": info["Id"], "architecture": info["Architecture"]}
        with tempfile.TemporaryDirectory(prefix="keytrail-test-ca-") as temporary:
            tmp = pathlib.Path(temporary)
            ext = tmp / "leaf.ext"
            ext.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n")
            openssl = ["/usr/bin/openssl"]
            run(openssl + ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=KeyTrail temporary test CA", "-keyout", str(tmp / "ca.key"), "-out", str(tmp / "ca.pem")])
            run(openssl + ["req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost",
                "-keyout", str(tmp / "leaf.key"), "-out", str(tmp / "leaf.csr")])
            run(openssl + ["x509", "-req", "-days", "1", "-in", str(tmp / "leaf.csr"),
                "-CA", str(tmp / "ca.pem"), "-CAkey", str(tmp / "ca.key"), "-CAcreateserial",
                "-extfile", str(ext), "-out", str(tmp / "leaf.pem")])
            context = ssl.create_default_context(cafile=str(tmp / "ca.pem"))
            fragment = (ROOT / "deploy/nginx-private.conf.example").read_bytes()
            result["nginxFragmentSHA256"] = sha(fragment)
            nginx = b"""pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 64; }
http {
  access_log off;
  client_body_temp_path /tmp/client_body;
  proxy_temp_path /tmp/proxy;
  fastcgi_temp_path /tmp/fastcgi;
  uwsgi_temp_path /tmp/uwsgi;
  scgi_temp_path /tmp/scgi;
  server {
    listen 8443 ssl;
    server_name localhost;
    ssl_certificate /fixture/leaf.pem;
    ssl_certificate_key /fixture/leaf.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    include /fixture/private.conf;
  }
}
"""
            config = {"bind": "127.0.0.1:8787", "dataDir": "/state/data", "demoData": True,
                      "accounts": [{"id": "tls", "deviceId": device, "collectorToken": collector, "viewerToken": viewer}]}
            for volume in [state, certificates]:
                resources.append(("volume", volume))
                docker("volume", "create", volume)
            populate(state, {"config.json": json.dumps(config).encode()})
            populate(certificates, {"nginx.conf": nginx, "private.conf": fragment,
                "leaf.pem": (tmp / "leaf.pem").read_bytes(), "leaf.key": (tmp / "leaf.key").read_bytes()})
            resources.append(("network", network))
            # Docker internal networks suppress the host port mapping on this
            # host. Use a fresh bridge without outbound IP masquerading; only
            # the TLS port is published, and only on host loopback.
            docker("network", "create", "--opt", "com.docker.network.bridge.enable_ip_masquerade=false", network)
            resources.append(("container", service))
            docker("run", "-d", "--name", service, "--network", network,
                "--read-only", "--cap-drop=ALL", "--pids-limit=32", "--memory=256m",
                "--security-opt=no-new-privileges:true", "-p", f"127.0.0.1:{port}:8443",
                "--mount", f"type=volume,src={state},dst=/state", SERVICE_IMAGE)
            resources.append(("container", proxy))
            docker("run", "-d", "--name", proxy, "--network", "container:" + service,
                "--user", "10001:10001", "--read-only", "--cap-drop=ALL", "--pids-limit=32",
                "--memory=128m", "--security-opt=no-new-privileges:true", "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m",
                "--mount", f"type=volume,src={certificates},dst=/fixture,readonly",
                "--entrypoint", "nginx", PROXY_IMAGE, "-c", "/fixture/nginx.conf", "-g", "daemon off;")
            origin = f"https://127.0.0.1:{port}"

            def request(path, body=None, token=viewer):
                data = None if body is None else json.dumps(body).encode()
                req = urllib.request.Request(origin + path, data=data)
                if token is not None:
                    req.add_header("Authorization", "Bearer " + token)
                if data is not None:
                    req.add_header("Content-Type", "application/json")
                try:
                    response = urllib.request.urlopen(req, context=context, timeout=5)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    raw = response.read(20 * 1024 * 1024)
                    return response.status, json.loads(raw) if path.startswith("/api/") else raw, dict(response.headers)

            ready = False
            for _ in range(80):
                try:
                    if request("/api/status")[0] == 200:
                        ready = True
                        break
                except (OSError, ValueError) as error:
                    result["lastReadinessError"] = str(error)
                time.sleep(0.1)
            if not ready:
                result["readinessDiagnostics"] = {}
                for label, name in [("service", service), ("proxy", proxy)]:
                    data = json.loads(docker("inspect", name))[0]
                    result["readinessDiagnostics"][label] = {"state": data["State"], "ports": data["NetworkSettings"].get("Ports"), "networks": data["NetworkSettings"].get("Networks")}
                probe = subprocess.run(["docker", "exec", proxy, "wget", "-qO-", "http://127.0.0.1:8787/api/status"], capture_output=True, timeout=10)
                result["readinessDiagnostics"]["upstreamProbeExit"] = probe.returncode
                probe = subprocess.run(["docker", "exec", proxy, "sh", "-c", "cat /proc/net/tcp /proc/net/tcp6"], capture_output=True, text=True, timeout=10)
                result["readinessDiagnostics"]["proxySockets"] = probe.stdout
            assert ready, "TLS proxy did not become ready"
            result.pop("lastReadinessError", None)
            assert context.verify_mode == ssl.CERT_REQUIRED and context.check_hostname
            with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
                with context.wrap_socket(connection, server_hostname="localhost") as tls:
                    result["negotiatedTLS"] = tls.version()
            for label, tls_context, hostname in [("untrustedCA", ssl.create_default_context(), "localhost"),
                                                 ("wrongHostname", context, "unrelated.invalid")]:
                refused = False
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
                        with tls_context.wrap_socket(connection, server_hostname=hostname):
                            pass
                except ssl.SSLCertVerificationError:
                    refused = True
                assert refused, label + " unexpectedly trusted"
                result[label + "Rejected"] = True
            result["groups"].append("Temporary test CA and hostname verified; unknown CA and wrong hostname refused")
            assets = {}
            for name, expected in frozen_assets.items():
                code, raw, headers = request("/" + name, token=None)
                assert code == 200 and raw == expected, "stale embedded web asset: " + name
                assert headers.get("Strict-Transport-Security") == "max-age=31536000"
                assert "Content-Security-Policy" in headers
                assets[name] = sha(raw)
            assert frozen_assets == {file.name: file.read_bytes() for file in (ROOT / "web").iterdir() if file.is_file()}, "web source changed during TLS verification"
            result["embeddedWebSHA256"] = assets
            result["currentSourceAssetsVerified"] = True
            assert len(assets) == 8
            for token in [None, "invalid-test-token"]:
                code, _, headers = request("/api/status", token=token)
                assert code == 401 and headers.get("Cache-Control") == "no-store"
                assert "Access-Control-Allow-Origin" not in headers
            result["groups"].append("Unmodified nginx fragment serves all eight current assets with CSP/HSTS and preserves API refusals")
            minute = 1704067200
            change = {"revision": 1, "minute": minute, "deleted": False, "record": {
                "keys": 2, "leftClicks": 1, "rightClicks": 0, "middleClicks": 0, "distance": 12.5,
                "scroll": 0, "keyboardMask": "3", "mouseMask": "2", "keyCounts": {"A": 2}}}
            body = {"deviceId": device, "changes": [change]}
            assert request("/api/sync", body)[0] == 403
            assert request("/api/sync", body, collector)[1]["result"]["applied"] == 1
            assert request("/api/sync", body, collector)[1]["result"]["ignored"] == 1
            query = {"op": "summary", "start": minute, "end": minute + 60}
            assert request("/api/query", query)[1]["result"]["keyPresses"] == 2
            page = request("/api/query", {**query, "op": "exportPage", "limit": 1})[1]["result"]
            assert page["rowCount"] == page["totalRows"] == 1 and "A:2" in page["csv"]
            assert request("/api/query", {"op": "exportValidate", "snapshot": page["snapshot"]})[0] == 200
            trend_query = {"op": "trend", "ranges": [{"start": minute, "end": minute + 60},
                                                       {"start": minute + 60, "end": minute + 120}]}
            for role in [viewer, collector]:
                trend = request("/api/query", trend_query, role)
                assert trend[0] == 200
                assert [cell["summary"]["keyPresses"] for cell in trend[1]["result"]] == [2, 0]
                assert all(cell["summary"]["keyCounts"] == {} for cell in trend[1]["result"])
            assert request("/api/query", {"op": "trend", "ranges": [{"start": minute + 1, "end": minute + 60}]})[0] == 400
            assert request("/api/query", {"op": "delete", "start": minute, "end": minute + 60})[0] == 400
            result["groups"].append("Current trend query returns ordered populated/empty cells, omits key histograms and refuses malformed ranges through TLS")
            result["groups"].append("Authenticated aggregate sync/read/export traverses TLS proxy; viewer writes forbidden and replay idempotent")
            record = json.loads((ART / "text-interop/swift-record.json").read_text())
            text_change = {"revision": 1, "id": record["metadata"]["id"], "deleted": False, "record": record}
            assert request("/api/text-sync", {"deviceId": device, "changes": [text_change]}, viewer)[0] == 403
            assert request("/api/text-sync", {"deviceId": device, "changes": [text_change]}, collector)[0] == 200
            stamp = record["metadata"]["timestamp"]
            text_query = {"start": stamp - 1, "end": stamp + 1, "limit": 10}
            assert request("/api/text-query", text_query)[1]["result"]["records"] == [record]
            assert request("/api/text-query", text_query, collector)[0] == 403
            result["groups"].append("Synthetic CryptoKit ciphertext passes HTTPS unchanged with separate text roles")
            deletion = {"revision": 2, "minute": minute, "deleted": True, "record": None}
            assert request("/api/sync", {"deviceId": device, "changes": [deletion]}, collector)[0] == 200
            assert request("/api/query", query)[1]["result"]["keyPresses"] == 0
            assert request("/api/query", {"op": "exportValidate", "snapshot": page["snapshot"]})[0] == 400
            text_change.update(revision=2, deleted=True, record=None)
            assert request("/api/text-sync", {"deviceId": device, "changes": [text_change]}, collector)[0] == 200
            assert request("/api/text-query", text_query)[1]["result"]["total"] == 0
            result["groups"].append("Aggregate/text tombstones and CSV invalidation remain effective through HTTPS")
            inspection = json.loads(docker("inspect", service, proxy))
            assert all(i["Config"]["User"] == "10001:10001" and i["HostConfig"]["ReadonlyRootfs"] for i in inspection)
            assert inspection[0]["HostConfig"]["PortBindings"]["8443/tcp"][0]["HostIp"] == "127.0.0.1"
            result["nonRootReadOnlyContainers"] = True
            result["loopbackPublishedOnly"] = True
            result["passed"] = True
    except Exception as error:
        message = str(error)
        for secret in credentials:
            message = message.replace(secret, "[test-credential]")
        result["error"] = type(error).__name__ + ": " + message
        for name in [service, proxy]:
            log = subprocess.run(["docker", "logs", name], capture_output=True, text=True, timeout=10)
            value = log.stdout + log.stderr
            for secret in credentials:
                value = value.replace(secret, "[test-credential]")
            (OUTPUT / ("v1.2-https-" + ("proxy" if name == proxy else "service") + "-diagnostic.log")).write_text(value)
    finally:
        for kind, name in reversed(resources):
            args = ["docker", "rm", "-f", name] if kind == "container" else ["docker", kind, "rm", name]
            try:
                removed = subprocess.run(args, capture_output=True, timeout=20)
                inspect = ["docker", "inspect", name] if kind == "container" else ["docker", kind, "inspect", name]
                absent = subprocess.run(inspect, capture_output=True, timeout=10)
                result["cleanup"][name] = absent.returncode != 0 and (removed.returncode == 0 or b"No such" in removed.stderr)
            except subprocess.TimeoutExpired:
                result["cleanup"][name] = False
        result["passed"] = result["passed"] and all(result["cleanup"].values())
        result["scope"] = "Local verified TLS through the shipped nginx fragment, actual Linux service and synthetic records; no public certificate, external VPN/Internet, mobile OS trust or real collector HTTPS acceptance claimed."
        (OUTPUT / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
