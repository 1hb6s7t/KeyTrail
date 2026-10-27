#!/usr/bin/env python3
"""Benchmark the production Rust core on a synthetic dense year, never user data.

This replaces the retired Swift-store benchmark. The Rust example verifies exact
results before timing repeated warm queries; it does not measure UI, input capture,
cold filesystem caches, or the resident agent's memory.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="use only cached Cargo dependencies")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    environment = os.environ.copy()
    bundled_cargo = root / ".toolchains/cargo/bin/cargo"
    if bundled_cargo.is_file() and os.access(bundled_cargo, os.X_OK):
        cargo = str(bundled_cargo)
        environment["PATH"] = str(bundled_cargo.parent) + os.pathsep + environment.get("PATH", "")
        environment["CARGO_HOME"] = str(root / ".toolchains/cargo")
        environment["RUSTUP_HOME"] = str(root / ".toolchains/rustup")
    else:
        cargo = shutil.which("cargo")
        if not cargo:
            parser.error("cargo not found; prepare Rust before running this benchmark")
    sources = [root / "rust/Cargo.lock", root / "rust/Cargo.toml", root / "rust/keytrail-core/Cargo.toml"]
    sources.extend(sorted((root / "rust/keytrail-core/src").glob("*.rs")))
    sources.append(root / "rust/keytrail-core/examples/timeline_benchmark.rs")
    hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    command = [cargo, "run", "--release", "--locked", "--manifest-path", str(root / "rust/Cargo.toml"),
               "-p", "keytrail-core", "--example", "timeline_benchmark"]
    if args.offline:
        command.append("--offline")
    # Cargo progress stays on stderr; stdout is one machine-readable result.
    completed = subprocess.run(command, cwd=root, env=environment, stdout=subprocess.PIPE, text=True)
    if completed.returncode:
        return completed.returncode
    result = json.loads(completed.stdout)
    if result.get("verification", {}).get("passed") is not True or result.get("synthetic") is not True:
        raise RuntimeError("benchmark did not verify the expected synthetic fixture")
    if any(hashlib.sha256((root / name).read_bytes()).hexdigest() != digest for name, digest in hashes.items()):
        raise RuntimeError("benchmark source changed during measurement")
    result["backend"] = "current Rust statistics core"
    result["host"] = {"system": platform.system(), "release": platform.release(), "architecture": platform.machine()}
    result["sourceSHA256"] = hashes
    result["lockedDependencies"] = True
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
