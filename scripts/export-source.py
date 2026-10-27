#!/usr/bin/env python3
"""Export only reviewed source formats; never use the local Git object database.

Run --check before publication. With no --check, write a new source directory,
ZIP and SHA-256 inventory. Existing outputs are never replaced. This static
check is a publication guard, not proof that arbitrary prose contains no PII.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import zipfile

TOP_FILES = frozenset({
    "README.md", "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md",
    "SECURITY.md", "Package.swift", ".gitignore", ".dockerignore",
})
SOURCE_DIRS = frozenset({"Sources", "Tests", "rust", "web", "deploy", "scripts", "docs", ".github"})
EXCLUDED_DIRS = frozenset({
    ".git", ".toolchains", ".build", "artifacts", "release", ".local-archive",
    "node_modules", "__pycache__", ".agents", ".codex", ".aws", "venv", ".venv",
})
TEXT_SUFFIXES = frozenset({
    ".swift", ".h", ".c", ".modulemap", ".rs", ".toml", ".md", ".json", ".txt",
    ".html", ".js", ".css", ".webmanifest", ".yaml", ".yml", ".sh", ".py", ".ps1",
})
EXACT_TEXT = frozenset({
    "rust/Cargo.lock", "deploy/Dockerfile", "deploy/nginx-private.conf.example",
    "scripts/windows-wine.Dockerfile", "scripts/windows-wine-ui.Dockerfile",
    "scripts/package-windows.Dockerfile",
    "rust/keytrail-windows/tests/fixtures/TEST-ONLY-key.base64",
})
PNG_RESOURCE = "Sources/KeyTrailApp/Resources/journal-keycaps.png"
MAX_FILE_BYTES = 5 * 1024 * 1024
# Known fixed interop material is public synthetic data. Other files receive the
# same credential checks even when their names contain 'test' or 'fixture'.
TEST_KEY = "rust/keytrail-windows/tests/fixtures/TEST-ONLY-key.base64"
LOCAL_DEPLOYMENT_FILES = frozenset({"config.json", "server.json", "settings.json", "credentials.json"})
PATTERNS = (
    ("personal-absolute-path", re.compile(r"/Users/[A-Za-z0-9_.-]+/|/home/[A-Za-z0-9_.-]+/|[A-Za-z]:\\+Users\\+[A-Za-z0-9_.-]+\\")),
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----")),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b")),
    ("api-token", re.compile(r"(?<![A-Za-z0-9_/-])sk-(?:proj-|ant-api\d+-)?[A-Za-z0-9_-]{32,}")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b")),
    ("credential-assignment", re.compile(r'''(?i)\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password)["']?\s*[:=]\s*["']?([A-Za-z0-9_+/.~=-]{24,})(?=["'\s,}\]]|$)''')),
    ("keytrail-credential", re.compile(r'''(?i)\b(?:text[_-]?)?(?:collector|viewer|sync)[_-]?token["']?\s*[:=]\s*["']?([A-Za-z0-9_+/.~=-]{24,})(?=["'\s,}\]]|$)''')),
)


class PublicationError(Exception):
    pass


def _excluded_directory(name: str) -> bool:
    lowered = name.lower()
    return name in EXCLUDED_DIRS or name.startswith("target") or lowered in {"sdk", "sdks", "live2dcubismsdk", "models"} or lowered.endswith((".app", ".framework", ".xcframework", ".sdk")) or name.startswith(".")


def _allowed_file(relative: str) -> bool:
    path = Path(relative)
    if path.name == "AGENTS.md":
        return False
    if path.name.lower().endswith((".model3.json", ".motion3.json", ".physics3.json", ".cdi3.json", ".exp3.json")):
        return False
    if relative in TOP_FILES or relative in EXACT_TEXT or relative == PNG_RESOURCE:
        return True
    return not path.name.startswith(".") and path.suffix in TEXT_SUFFIXES


def inspect_source(source: Path) -> tuple[dict[str, bytes], list[dict], list[str]]:
    """Snapshot selected files only. Never open excluded files or follow links."""
    files: dict[str, bytes] = {}
    issues: list[dict] = []
    excluded: list[str] = []

    def issue(relative: str, category: str, line: int = 0):
        issues.append({"path": relative, "line": line, "category": category})

    def visit(path: Path, relative: str):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            issue(relative, "symlink")
            return
        if stat.S_ISDIR(mode):
            for child in sorted(path.iterdir(), key=lambda p: p.name):
                child_relative = relative + "/" + child.name
                # Known local/generated directories are excluded before traversal.
                # A symlink with any other name is rejected before file selection.
                if _excluded_directory(child.name):
                    excluded.append(child_relative)
                    continue
                visit(child, child_relative)
            return
        if not stat.S_ISREG(mode):
            issue(relative, "special-file")
            return
        if not _allowed_file(relative):
            excluded.append(relative)
            return
        if Path(relative).parts[0] == "deploy" and path.name.lower() in LOCAL_DEPLOYMENT_FILES:
            issue(relative, "local-deployment-config")
            return
        if path.stat().st_size > MAX_FILE_BYTES:
            issue(relative, "oversized-source")
            return
        # Refuse replacement by a symlink between directory traversal and read.
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor, "rb") as stream:
            data = stream.read(MAX_FILE_BYTES + 1)
        if len(data) > MAX_FILE_BYTES:
            issue(relative, "oversized-source")
            return
        if relative == PNG_RESOURCE:
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                issue(relative, "invalid-approved-image")
                return
        else:
            try:
                text = data.decode("utf-8")
                if "\x00" in text:
                    raise UnicodeError()
            except UnicodeError:
                issue(relative, "binary-in-text-format")
                return
            for number, line in enumerate(text.splitlines(), 1):
                for category, pattern in PATTERNS:
                    if pattern.search(line):
                        issue(relative, category, number)
            if relative == TEST_KEY:
                # This exception allows only a single base64-encoded 32-byte key;
                # no arbitrary prose, path or credential exemptions are granted.
                import base64
                try:
                    if len(base64.b64decode(text.strip(), validate=True)) != 32:
                        raise ValueError()
                except (ValueError, base64.binascii.Error):
                    issue(relative, "invalid-test-only-key")
        files[relative] = data

    for child in sorted(source.iterdir(), key=lambda p: p.name):
        if child.name in TOP_FILES or child.name in SOURCE_DIRS:
            visit(child, child.name)
        else:
            excluded.append(child.name)
    return files, issues, excluded


def export_source(source: Path, output: Path, files: dict[str, bytes]) -> dict:
    # Reject symlink ancestors before resolving, including a symlink output name.
    output = Path(os.path.abspath(output))
    for component in (output, *output.parents):
        if component.is_symlink():
            raise PublicationError("output-symlink")
    if output == source or source in output.parents and output.relative_to(source).parts[0] != "release":
        raise PublicationError("output-must-be-outside-source-or-under-release")
    archive = output.with_name(output.name + ".zip")
    checksum = archive.with_name(archive.name + ".sha256")
    if any(path.exists() for path in (output, archive, checksum)):
        raise PublicationError("output-already-exists")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir()  # exclusive creation; never merge or replace existing output
    hashes = []
    for relative, data in sorted(files.items()):
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as stream:
            stream.write(data)
        # Only source scripts need executable permissions; no host modes copied.
        if destination.suffix in {".sh", ".py"}:
            destination.chmod(0o755)
        hashes.append(f"{hashlib.sha256(data).hexdigest()}  {relative}\n")
    inventory = "".join(hashes).encode()
    (output / "SHA256SUMS").write_bytes(inventory)
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as bundle:
        for relative, data in sorted({**files, "SHA256SUMS": inventory}.items()):
            entry = zipfile.ZipInfo(output.name + "/" + relative, (2020, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = (0o100755 if Path(relative).suffix in {".sh", ".py"} else 0o100644) << 16
            bundle.writestr(entry, data)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    with checksum.open("x") as stream:
        stream.write(f"{digest}  {archive.name}\n")
    return {"output": str(output), "archive": str(archive), "checksum": str(checksum), "files": len(files), "sha256": digest}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1], help="source root; defaults to this checkout")
    parser.add_argument("--check", action="store_true", help="scan only, without writing an export")
    parser.add_argument("--output", type=Path, help="new output directory; default: SOURCE/release/KeyTrail-source")
    args = parser.parse_args(argv)
    try:
        source = args.source.resolve(strict=True)
        files, issues, excluded = inspect_source(source)
        report = {"ok": not issues, "selectedFiles": len(files), "excludedEntries": len(excluded), "issues": issues}
        if not issues and not args.check:
            report["export"] = export_source(source, args.output or source / "release" / "KeyTrail-source", files)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 1 if issues else 0
    except (OSError, PublicationError) as error:
        # Never print source content, exception arguments, or credential-bearing
        # filenames from operating-system messages.
        category = str(error) if isinstance(error, PublicationError) else "filesystem-error"
        print(json.dumps({"ok": False, "category": category}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
