#!/usr/bin/env python3
"""Disposable TLS fixture for the Android test; never changes host trust.

Reuse the existing HTTPS test's Docker/tar utilities and exact shipped nginx
fragment. stdin accepts restart/stop only; stdout contains no credentials.
"""
import importlib.util
import json
import pathlib
import socket
import ssl
import time
import urllib.request
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("keytrail_https", ROOT / "scripts/test-private-https.py")
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def main():
    private = pathlib.Path(sys.argv[1])
    config = json.loads((private / "config.json").read_text())
    frozen_assets = {file.name: file.read_bytes() for file in (ROOT / "web").iterdir() if file.is_file()}
    assert len(frozen_assets) == 8
    tag = "kt-android-tls-" + uuid.uuid4().hex[:10]
    service, proxy, network = tag + "-service", tag + "-proxy", tag + "-network"
    state, certs = tag + "-state", tag + "-certs"
    resources = []
    cleanup = {}
    with socket.socket() as free:
        free.bind(("127.0.0.1", 0))
        port = free.getsockname()[1]

    def event(value):
        print(json.dumps(value), flush=True)

    def launch():
        shared.docker("run", "-d", "--name", service, "--network", network,
                      "--read-only", "--cap-drop=ALL", "--pids-limit=32", "--memory=256m",
                      "--security-opt=no-new-privileges:true", "-p", f"127.0.0.1:{port}:8443",
                      "--mount", f"type=volume,src={state},dst=/state", shared.SERVICE_IMAGE)
        shared.docker("run", "-d", "--name", proxy, "--network", "container:" + service,
                      "--user", "10001:10001", "--read-only", "--cap-drop=ALL",
                      "--pids-limit=32", "--memory=128m", "--security-opt=no-new-privileges:true",
                      "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m",
                      "--mount", f"type=volume,src={certs},dst=/fixture,readonly",
                      "--entrypoint", "nginx", shared.PROXY_IMAGE,
                      "-c", "/fixture/nginx.conf", "-g", "daemon off;")
        images = {}
        for image in [shared.SERVICE_IMAGE, shared.PROXY_IMAGE]:
            info = json.loads(shared.docker("image", "inspect", image))[0]
            images[image] = {"id": info["Id"], "architecture": info["Architecture"]}
        context = ssl.create_default_context(cafile=str(private / "KeyTrail-Android-TLS-CA.crt"))
        for attempt in range(80):
            try:
                for name, expected in frozen_assets.items():
                    with urllib.request.urlopen(f"https://127.0.0.1:{port}/{name}", context=context, timeout=5) as response:
                        assert response.status == 200 and response.read() == expected, "stale embedded asset: " + name
                        assert response.headers.get("Strict-Transport-Security") == "max-age=31536000"
                        assert response.headers.get("Content-Security-Policy")
                break
            except OSError:
                if attempt == 79:
                    raise
                time.sleep(0.1)
        assert frozen_assets == {file.name: file.read_bytes() for file in (ROOT / "web").iterdir() if file.is_file()}, "web source changed during TLS startup"
        return images

    try:
        ca_config = private / "ca.cnf"
        ca_config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=v3_ca\nprompt=no\n"
                             f"[dn]\nCN=KeyTrail Android temporary CA {tag}\n[v3_ca]\n"
                             "basicConstraints=critical,CA:TRUE,pathlen:0\n"
                             "keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n")
        openssl = ["/usr/bin/openssl"]
        shared.run(openssl + ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                             "-days", "1", "-config", str(ca_config), "-keyout", str(private / "ca.key"),
                             "-out", str(private / "KeyTrail-Android-TLS-CA.crt")])
        shared.run(openssl + ["req", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=localhost",
                             "-keyout", str(private / "leaf.key"), "-out", str(private / "leaf.csr")])
        extension = private / "leaf.ext"
        extension.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                             "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n")
        shared.run(openssl + ["x509", "-req", "-sha256", "-days", "1", "-in", str(private / "leaf.csr"),
                             "-CA", str(private / "KeyTrail-Android-TLS-CA.crt"), "-CAkey", str(private / "ca.key"),
                             "-CAcreateserial", "-extfile", str(extension), "-out", str(private / "leaf.pem")])
        fragment = (ROOT / "deploy/nginx-private.conf.example").read_bytes()
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
        for name in [state, certs]:
            shared.docker("volume", "create", name)
            resources.append(("volume", name))
        shared.populate(state, {"config.json": json.dumps(config).encode()})
        shared.populate(certs, {"nginx.conf": nginx, "private.conf": fragment,
                               "leaf.pem": (private / "leaf.pem").read_bytes(),
                               "leaf.key": (private / "leaf.key").read_bytes()})
        shared.docker("network", "create", "--opt", "com.docker.network.bridge.enable_ip_masquerade=false", network)
        resources.append(("network", network))
        resources.extend([("container", service), ("container", proxy)])
        images = launch()
        event({"event": "ready", "origin": f"https://127.0.0.1:{port}", "port": port,
               "caPath": str(private / "KeyTrail-Android-TLS-CA.crt"), "images": images,
               "nginxFragmentSHA256": shared.sha(fragment),
               "embeddedWebSHA256": {name: shared.sha(data) for name, data in frozen_assets.items()},
               "verifiedTLSAssets": True})
        for line in sys.stdin:
            action = json.loads(line).get("action")
            if action == "stop":
                break
            if action == "restart":
                for name in [proxy, service]:
                    shared.docker("rm", "-f", name)
                event({"event": "restarted", "images": launch()})
            else:
                raise ValueError("Unknown fixture action")
    except Exception as error:
        event({"event": "error", "message": type(error).__name__ + ": TLS fixture operation failed"})
    finally:
        for kind, name in reversed(resources):
            args = ["docker", "rm", "-f", name] if kind == "container" else ["docker", kind, "rm", name]
            subprocess.run(args, capture_output=True, timeout=30)
            inspect = ["docker", "inspect", name] if kind == "container" else ["docker", kind, "inspect", name]
            cleanup[name] = subprocess.run(inspect, capture_output=True, timeout=10).returncode != 0
        event({"event": "stopped", "cleanup": cleanup})


if __name__ == "__main__":
    main()
