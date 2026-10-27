#!/usr/bin/env python3
"""Isolated SIGPIPE checks. Never starts monitoring or reads production data.

With --app, additionally start that exact packaged executable in headless demo mode
with a temporary database, deliver SIGPIPE to that child only, and verify RPC health.
The standalone IPC child deliberately retains default SIGPIPE disposition to test
existing per-socket protection after a delayed handler outlives its disconnected peer.
"""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def request(path, body, timeout=6):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(str(path))
        client.sendall(json.dumps(body).encode() + b"\n")
        data = b""
        while b"\n" not in data:
            part = client.recv(8192)
            if not part:
                raise AssertionError("RPC closed before a complete response")
            data += part
        return json.loads(data.split(b"\n", 1)[0])


def wait_ready(process, path):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"child exited before readiness: {process.returncode}")
        try:
            return request(path, {"op": "status"}, timeout=.5)
        except (OSError, ValueError, AssertionError):
            time.sleep(.05)
    raise AssertionError("child did not expose temporary socket")


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def ipc_delayed_disconnect(directory):
    source = directory / "main.swift"
    source.write_text('''import Foundation
import Darwin
// The existing socket protection must work independently of agent startup.
signal(SIGPIPE, SIG_DFL)
let socket = URL(fileURLWithPath: CommandLine.arguments[1])
let marker = URL(fileURLWithPath: CommandLine.arguments[2])
let server = try RuntimeServer(url: socket) { request in
    if request["op"] as? String == "delay" {
        try! Data("handler entered".utf8).write(to: marker)
        Thread.sleep(forTimeInterval: 4)
    }
    return ["ok": true, "result": "alive"]
}
server.start()
dispatchMain()
''')
    binary = directory / "ipc-child"
    subprocess.run(["swiftc", str(ROOT / "Sources/KeyTrailIPC/RuntimeClient.swift"),
                    str(ROOT / "Sources/KeyTrailIPC/RuntimeServer.swift"), str(source),
                    "-o", str(binary)], check=True)
    path, marker = directory / "ipc.sock", directory / "entered"
    process = subprocess.Popen([str(binary), str(path), str(marker)])
    try:
        assert wait_ready(process, path)["ok"]
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(path))
            client.sendall(b'{"op":"delay"}\n')
            deadline = time.monotonic() + 3
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            assert marker.exists(), "delayed handler did not enter"
            client.shutdown(socket.SHUT_RDWR)
        # Queue another real request behind the slow handler. Its success proves
        # the server survived writing its first response to a closed socket.
        assert request(path, {"op": "status"}) == {"ok": True, "result": "alive"}
        assert process.poll() is None
        return {"passed": True, "handlerDelaySeconds": 4, "defaultSIGPIPE": True,
                "actualIPCSource": True, "clientDisconnectedDuringHandler": True}
    finally:
        stop(process)


def packaged_agent(app, directory):
    executable = app / "Contents/MacOS/KeyTrail"
    assert executable.is_file(), f"missing packaged agent: {executable}"
    fixture = directory / "agent"
    fixture.mkdir(mode=0o700)
    process = subprocess.Popen([str(executable), "--demo", "--headless", "--test-directory", str(fixture)])
    path = fixture / "engine.sock"
    try:
        before = wait_ready(process, path)
        assert before["ok"] and before["result"]["isDemo"]
        assert before["result"]["monitoring"] is False
        os.kill(process.pid, signal.SIGPIPE)
        after = request(path, {"op": "status"})
        assert after["ok"] and after["result"]["pid"] == process.pid
        assert after["result"]["monitoring"] is False
        for _ in range(3):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(str(path))
                client.sendall(b'{"op":"status"}\n')
                client.shutdown(socket.SHUT_RDWR)
        assert request(path, {"op": "status"})["ok"]
        assert request(path, {"op": "shutdown"})["ok"]
        assert process.wait(timeout=5) == 0
        return {"passed": True, "app": str(app), "directSIGPIPE": True,
                "build": plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"],
                "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                "earlyDisconnects": 3, "normalShutdown": True,
                "isolatedDemoDatabase": True, "inputMonitoringStarted": False}
    except BaseException as error:
        try:
            exit_code = process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            exit_code = None
        print(json.dumps({"packagedAgentFailure": {"app": str(app),
              "childExitCode": exit_code, "error": str(error)}}), flush=True)
        raise
    finally:
        stop(process)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path)
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="kt-pipe-", dir="/tmp") as temporary:
        directory = Path(temporary)
        result = {"ipcDelayedDisconnect": ipc_delayed_disconnect(directory)}
        if arguments.app:
            result["packagedAgent"] = packaged_agent(arguments.app.resolve(), directory)
        else:
            result["packagedAgent"] = {"tested": False, "reason": "Pass --app after packaging"}
        print(json.dumps(result, indent=2))
