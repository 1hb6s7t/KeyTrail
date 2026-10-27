"""Publication guard tests use disposable fake source trees only."""
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout
import zipfile

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "export-source.py"
SPEC = importlib.util.spec_from_file_location("keytrail_export", SCRIPT)
EXPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT)


class PublicationChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "source"
        self.root.mkdir()

    def write(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode())
        return path

    def test_allowlist_excludes_local_data_git_binaries_and_unrelated_files(self):
        self.write("README.md", "Public project")
        self.write("Sources/Main.swift", 'let identity = "com.auriel.keytrail"')
        self.write(".github/workflows/check.yml", "name: checks")
        for relative in ["AGENTS.md", "unrelated.html", ".git/objects/object", "artifacts/private.json",
                         ".toolchains/key.txt", "release/old/README.md", "Sources/target-old/cache.rs",
                         "scripts/__pycache__/cache.py", "docs/.local/private.md", "rust/target/cache.rs",
                         "Sources/model.moc3", "Sources/data.sqlite", "Sources/key.pem", "Sources/private.log",
                         "Sources/archive.zip", "Sources/tool.exe", "Sources/Old.app/Contents/private.txt",
                         "Sources/SDK/header.h", "Sources/cat.model3.json", "Sources/models/model.json"]:
            self.write(relative, b"private\x00data")
        files, issues, _ = EXPORT.inspect_source(self.root)
        self.assertEqual(set(files), {"README.md", "Sources/Main.swift", ".github/workflows/check.yml"})
        self.assertFalse(issues)

    def test_secret_and_personal_path_report_contains_locations_not_values(self):
        token = "ghp_" + "A" * 36
        private_path = "/" + "Users" + "/fixture-person/work"
        self.write("Sources/Main.swift", token + "\n" + private_path)
        output = io.StringIO()
        with redirect_stdout(output):
            result = EXPORT.main(["--source", str(self.root), "--check"])
        self.assertEqual(result, 1)
        report = json.loads(output.getvalue())
        self.assertEqual({i["category"] for i in report["issues"]}, {"github-token", "personal-absolute-path"})
        self.assertNotIn(token, output.getvalue())
        self.assertNotIn(private_path, output.getvalue())

    def test_private_key_and_disguised_binary_are_rejected(self):
        self.write("docs/key.txt", "-----BEGIN " + "PRIVATE KEY-----\nfixture")
        self.write("Sources/fake.swift", b"MZ\x00binary")
        _, issues, _ = EXPORT.inspect_source(self.root)
        self.assertEqual({i["category"] for i in issues}, {"private-key", "binary-in-text-format"})

    def test_local_deployment_configuration_is_rejected(self):
        for filename in EXPORT.LOCAL_DEPLOYMENT_FILES:
            self.write("deploy/" + filename, json.dumps({"accounts": []}))
        files, issues, _ = EXPORT.inspect_source(self.root)
        self.assertFalse(files)
        self.assertEqual(len(issues), len(EXPORT.LOCAL_DEPLOYMENT_FILES))
        self.assertEqual({i["category"] for i in issues}, {"local-deployment-config"})

    def test_keytrail_credentials_are_rejected_in_json_yaml_and_source(self):
        token = "synthetic_" + "q" * 55
        for index, field in enumerate(["collectorToken", "viewerToken", "syncToken", "textSyncToken",
                                       "textCollectorToken", "textViewerToken", "collector_token"]):
            self.write(f"docs/fixture{index}.json", json.dumps({field: token}))
        self.write("deploy/fixture.yaml", "viewerToken: " + token + "\n")
        self.write("Sources/fixture.swift", 'let syncToken = "' + token + '"\n')
        output = io.StringIO()
        with redirect_stdout(output):
            result = EXPORT.main(["--source", str(self.root), "--check"])
        self.assertEqual(result, 1)
        issues = json.loads(output.getvalue())["issues"]
        self.assertEqual(len(issues), 9)
        self.assertEqual({i["category"] for i in issues}, {"keytrail-credential"})
        self.assertNotIn(token, output.getvalue())

    def test_quoted_generic_credentials_are_rejected(self):
        self.write("docs/config.json", json.dumps({"apiKey": "fixture_" + "z" * 45}))
        _, issues, _ = EXPORT.inspect_source(self.root)
        self.assertEqual([i["category"] for i in issues], ["credential-assignment"])

    def test_symlink_is_rejected_without_reading_target(self):
        self.write("Sources/Main.swift", "public")
        (self.root / "Sources" / "linked.md").symlink_to(self.root / "does-not-exist")
        _, issues, _ = EXPORT.inspect_source(self.root)
        self.assertEqual(issues, [{"path": "Sources/linked.md", "line": 0, "category": "symlink"}])

    def test_only_named_test_key_is_accepted_and_validated(self):
        self.write(EXPORT.TEST_KEY, base64.b64encode(bytes(range(32))) + b"\n")
        files, issues, _ = EXPORT.inspect_source(self.root)
        self.assertIn(EXPORT.TEST_KEY, files)
        self.assertFalse(issues)
        self.write(EXPORT.TEST_KEY, "invalid")
        self.assertEqual(EXPORT.inspect_source(self.root)[1][0]["category"], "invalid-test-only-key")

    def test_export_inventory_zip_and_existing_output_protection(self):
        self.write("README.md", "Public project")
        self.write("scripts/build.sh", "#!/bin/sh\nexit 0\n")
        files, issues, _ = EXPORT.inspect_source(self.root)
        self.assertFalse(issues)
        target = self.root / "release" / "KeyTrail-source"
        result = EXPORT.export_source(self.root, target, files)
        with zipfile.ZipFile(result["archive"]) as archive:
            self.assertEqual(set(archive.namelist()), {"KeyTrail-source/README.md", "KeyTrail-source/scripts/build.sh", "KeyTrail-source/SHA256SUMS"})
            self.assertEqual(archive.read("KeyTrail-source/README.md"), files["README.md"])
        digest = hashlib.sha256(Path(result["archive"]).read_bytes()).hexdigest()
        self.assertEqual(Path(result["checksum"]).read_text(), digest + "  KeyTrail-source.zip\n")
        inventory = (target / "SHA256SUMS").read_text()
        self.assertIn(hashlib.sha256(files["README.md"]).hexdigest() + "  README.md", inventory)
        with self.assertRaisesRegex(EXPORT.PublicationError, "output-already-exists"):
            EXPORT.export_source(self.root, target, files)
        self.assertEqual((target / "README.md").read_bytes(), files["README.md"])

    def test_output_cannot_pollute_source_or_follow_symlink(self):
        for target in [self.root, self.root / "Sources" / "new"]:
            with self.assertRaises(EXPORT.PublicationError):
                EXPORT.export_source(self.root, target, {})
        link = Path(self.temp.name).resolve() / "linked"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(EXPORT.PublicationError, "output-symlink"):
            EXPORT.export_source(self.root, link / "new", {})


if __name__ == "__main__":
    unittest.main()
