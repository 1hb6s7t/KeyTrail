"""Packaging output protections, using fake products and signing tools in temporary trees."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGERS = {
    "package-app.sh": "KEYTRAIL_APP_OUTPUT",
    "package-cat-app.sh": "KEYTRAIL_CAT_APP_OUTPUT",
    "package-dashboard.sh": "KEYTRAIL_DASHBOARD_APP_OUTPUT",
    "package-float-app.sh": "KEYTRAIL_FLOAT_APP_OUTPUT",
}
PROTECTED = ("KeyTrail-Cat-validation.app", "KeyTrail-Dashboard-fixed.app", "KeyTrail-Float-validation.app")


class AppOutputChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="keytrail-package-guard-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        scripts = self.repo / "scripts"
        scripts.mkdir(parents=True)
        for name in [*PACKAGERS, "app-output-guard.sh"]:
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        resource = self.repo / "Sources/KeyTrailApp/Resources/journal-keycaps.png"
        resource.parent.mkdir(parents=True)
        resource.write_bytes(b"synthetic image")
        docs = self.repo / "docs"
        docs.mkdir()
        (docs / "bongo-cat-assets.md").write_text("Synthetic license fixture")
        self.products = self.root / "isolated-products"
        self.products.mkdir()
        for name in ["KeyTrailAgent", "KeyTrailDashboard", "KeyTrailPet", "KeyTrailFloat"]:
            item = self.products / name
            item.write_text("#!/bin/sh\nexit 0\n")
            item.chmod(0o755)
        self.sdk = self.root / "sdk"
        core = self.sdk / "Core/dll/macos/libLive2DCubismCore.dylib"
        core.parent.mkdir(parents=True)
        core.write_bytes(b"synthetic SDK")
        assets = self.repo / "artifacts/bongo-assets"
        (assets / "standard").mkdir(parents=True)
        for name in ["cat.model3.json", "demomodel.moc3"]:
            (assets / "standard" / name).write_text("synthetic model")
        (assets / "LICENSE.upstream").write_text("Synthetic license")
        (assets / "manifest.json").write_text("{}")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.calls = self.root / "tool-calls"
        for name in ["swift", "codesign"]:
            tool = self.tools / name
            tool.write_text('#!/bin/sh\nprintf "%s\\n" "$0" "$@" >> "$KEYTRAIL_TEST_TOOL_CALLS"\nexit 0\n')
            tool.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("KEYTRAIL_")}
        self.env.update(PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                        KEYTRAIL_BUILD_PRODUCTS=str(self.products), KEYTRAIL_CUBISM_SDK=str(self.sdk),
                        KEYTRAIL_TEST_TOOL_CALLS=str(self.calls))

    def guard(self, output, replace="0"):
        env = dict(self.env, KEYTRAIL_REPLACE_OUTPUT=replace)
        return subprocess.run(["sh", "-c", '. "$1"; keytrail_validate_app_output "$2"',
                               "guard", str(self.repo / "scripts/app-output-guard.sh"), str(output)],
                              env=env, text=True, capture_output=True)

    def package(self, name, output=None, **environment):
        env = dict(self.env, **environment)
        if output is not None:
            env[PACKAGERS[name]] = str(output)
        return subprocess.run(["sh", str(self.repo / "scripts" / name)], env=env,
                              text=True, capture_output=True)

    def test_new_absolute_output_validation_creates_nothing(self):
        output = self.root / "missing-parent/new.app"
        result = self.guard(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(output))
        self.assertFalse(output.parent.exists())

    def test_invalid_output_shapes_are_rejected(self):
        for output in ["", "relative.app", str(self.root / "plain"), str(self.root / ".app"),
                       str(self.root) + "/../escape.app", str(self.root / "bad\nname.app")]:
            with self.subTest(output=output):
                self.assertNotEqual(self.guard(output).returncode, 0)

    def test_existing_output_requires_explicit_replacement(self):
        output = self.root / "existing.app"
        output.mkdir()
        sentinel = output / "sentinel"
        sentinel.write_text("keep")
        self.assertNotEqual(self.guard(output).returncode, 0)
        self.assertEqual(self.guard(output, "1").returncode, 0)
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertNotEqual(self.guard(output, "yes").returncode, 0)

    def test_existing_regular_file_cannot_be_replaced(self):
        output = self.root / "plain.app"
        output.write_text("keep")
        self.assertNotEqual(self.guard(output, "1").returncode, 0)
        self.assertEqual(output.read_text(), "keep")

    def test_symlinks_and_symlink_ancestors_rejected_with_replacement(self):
        real = self.root / "real"
        real.mkdir()
        link = self.root / "linked.app"
        link.symlink_to(real, target_is_directory=True)
        dangling = self.root / "dangling.app"
        dangling.symlink_to(self.root / "absent", target_is_directory=True)
        ancestor = self.root / "linked-parent"
        ancestor.symlink_to(real, target_is_directory=True)
        for output in [link, dangling, ancestor / "child.app"]:
            with self.subTest(output=output):
                self.assertNotEqual(self.guard(output, "1").returncode, 0)
        self.assertTrue(link.is_symlink())
        self.assertFalse((real / "child.app").exists())

    def test_protected_names_always_rejected(self):
        for name in PROTECTED:
            for spelling in [name, name.lower()]:
                with self.subTest(name=spelling):
                    self.assertNotEqual(self.guard(self.root / spelling, "1").returncode, 0)

    def test_every_packager_rejects_protected_output_before_build_or_write(self):
        for script in PACKAGERS:
            for name in PROTECTED:
                output = self.root / name
                with self.subTest(script=script, name=name):
                    result = self.package(script, output, KEYTRAIL_REPLACE_OUTPUT="1")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("protected", result.stderr)
                    self.assertFalse(output.exists())
                    self.assertFalse(self.calls.exists(), "Build or signing tool ran before protection")

    def test_every_packager_rejects_existing_output_without_modification(self):
        for script in PACKAGERS:
            output = self.root / (script + ".app")
            output.mkdir()
            sentinel = output / "sentinel"
            sentinel.write_text("keep")
            with self.subTest(script=script):
                result = self.package(script, output)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("already exists", result.stderr)
                self.assertEqual(sentinel.read_text(), "keep")
                self.assertFalse(self.calls.exists())

    def test_every_packager_rejects_symlink_before_build_or_write(self):
        real = self.root / "outside"
        real.mkdir()
        sentinel = real / "sentinel"
        sentinel.write_text("keep")
        output = self.root / "output.app"
        output.symlink_to(real, target_is_directory=True)
        for script in PACKAGERS:
            with self.subTest(script=script):
                result = self.package(script, output, KEYTRAIL_REPLACE_OUTPUT="1")
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(output.is_symlink())
                self.assertEqual(sentinel.read_text(), "keep")
                self.assertFalse(self.calls.exists())

    def test_default_outputs_use_isolated_products_and_preserve_bundle_ids(self):
        expected = {
            "package-app.sh": ("KeyTrail-v1.2-candidate.app", "com.auriel.keytrail"),
            "package-cat-app.sh": ("KeyTrail-Cat-dev.app", "com.auriel.keytrail.validation"),
            "package-dashboard.sh": ("KeyTrail-Dashboard-dev.app", "com.auriel.keytrail.validation.dashboard.repaired"),
            "package-float-app.sh": ("KeyTrail-Float-validation-dev.app", "com.auriel.keytrail.float.validation"),
        }
        for script, (name, identifier) in expected.items():
            with self.subTest(script=script):
                result = self.package(script, KEYTRAIL_SKIP_BUILD="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                info = plistlib.loads((self.repo / "artifacts" / name / "Contents/Info.plist").read_bytes())
                self.assertEqual(info["CFBundleIdentifier"], identifier)
        self.assertNotIn("swift", self.calls.read_text())

    def test_explicit_replacement_only_recreates_disposable_output(self):
        for script in PACKAGERS:
            output = self.root / (script + ".app")
            output.mkdir()
            sentinel = output / "obsolete"
            sentinel.write_text("old generated content")
            with self.subTest(script=script):
                result = self.package(script, output, KEYTRAIL_SKIP_BUILD="1", KEYTRAIL_REPLACE_OUTPUT="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(sentinel.exists())
                self.assertTrue((output / "Contents/Info.plist").is_file())

    def test_collector_and_cat_profiles_retain_legacy_ids(self):
        scenarios = [("package-app.sh", {"KEYTRAIL_PREVIEW": "1"}, "com.auriel.keytrail.preview"),
                     ("package-app.sh", {"KEYTRAIL_VALIDATION": "1"}, "com.auriel.keytrail.validation"),
                     ("package-cat-app.sh", {"KEYTRAIL_CAT_PREVIEW": "1"}, "com.auriel.keytrail.preview")]
        for index, (script, profile, identifier) in enumerate(scenarios):
            output = self.root / ("profile-" + str(index) + ".app")
            result = self.package(script, output, KEYTRAIL_SKIP_BUILD="1", **profile)
            self.assertEqual(result.returncode, 0, result.stderr)
            info = plistlib.loads((output / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], identifier)

    def test_float_profiles_retain_data_profiles_and_ids(self):
        for profile, data in {"validation": "KeyTrail Validation", "normal": "KeyTrail", "demo": "KeyTrail Demo"}.items():
            output = self.root / (profile + ".app")
            result = self.package("package-float-app.sh", output, KEYTRAIL_SKIP_BUILD="1", KEYTRAIL_FLOAT_PROFILE=profile)
            self.assertEqual(result.returncode, 0, result.stderr)
            info = plistlib.loads((output / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], "com.auriel.keytrail.float." + profile)
            self.assertEqual(info["KeyTrailDataProfile"], data)
            collector = self.repo / "artifacts" / {"validation": "KeyTrail-Cat-dev.app", "normal": "KeyTrail-v1.2-candidate.app", "demo": "KeyTrail-preview.app"}[profile]
            dashboard = (self.repo / "artifacts/KeyTrail-Dashboard-dev.app" if profile == "validation"
                         else collector / "Contents/Helpers/KeyTrailDashboard.app")
            self.assertEqual(info["KeyTrailCollectorApp"], str(collector))
            self.assertEqual(info["KeyTrailDashboardApp"], str(dashboard))


    def test_float_link_overrides_only_write_metadata(self):
        collector = self.root / "KeyTrail-Cat-validation.app"
        dashboard = self.root / "KeyTrail-Dashboard-fixed.app"
        for target in [collector, dashboard]:
            target.mkdir()
            (target / "sentinel").write_text("existing app stays unchanged")
        for profile in ["validation", "normal", "demo"]:
            output = self.root / (profile + ".app")
            result = self.package("package-float-app.sh", output, KEYTRAIL_SKIP_BUILD="1", KEYTRAIL_FLOAT_PROFILE=profile,
                                  KEYTRAIL_FLOAT_COLLECTOR_APP=str(collector), KEYTRAIL_FLOAT_DASHBOARD_APP=str(dashboard))
            self.assertEqual(result.returncode, 0, result.stderr)
            info = plistlib.loads((output / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["KeyTrailCollectorApp"], str(collector))
            self.assertEqual(info["KeyTrailDashboardApp"], str(dashboard))
            for target in [collector, dashboard]:
                self.assertEqual(list(target.iterdir()), [target / "sentinel"])
                self.assertEqual((target / "sentinel").read_text(), "existing app stays unchanged")
                self.assertNotIn(str(target), self.calls.read_text())

    def test_float_output_cannot_overlap_launch_targets(self):
        target = self.root / "existing.app"
        target.mkdir()
        sentinel = target / "sentinel"
        sentinel.write_text("keep")
        for output in [target, target / "nested.app", self.root / "container.app"]:
            collector = target if output != self.root / "container.app" else output / "nested.app"
            result = self.package("package-float-app.sh", output, KEYTRAIL_REPLACE_OUTPUT="1",
                                  KEYTRAIL_FLOAT_COLLECTOR_APP=str(collector))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), "keep")
            self.assertFalse(self.calls.exists())

    def test_float_invalid_link_override_fails_before_build(self):
        for variable in ["KEYTRAIL_FLOAT_COLLECTOR_APP", "KEYTRAIL_FLOAT_DASHBOARD_APP"]:
            for value in ["", "relative.app", str(self.root / "missing-suffix")]:
                result = self.package("package-float-app.sh", self.root / "new.app", **{variable: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "new.app").exists())
                self.assertFalse(self.calls.exists())

    def test_dashboard_profiles_retain_legacy_ids(self):
        profiles = {"normal": "com.auriel.keytrail.dashboard", "journal": "com.auriel.keytrail.journal.dashboard",
                    "preview": "com.auriel.keytrail.preview.dashboard", "validation": "com.auriel.keytrail.validation.dashboard.repaired"}
        for profile, identifier in profiles.items():
            output = self.root / (profile + ".app")
            result = self.package("package-dashboard.sh", output, KEYTRAIL_SKIP_BUILD="1", KEYTRAIL_DASHBOARD_PROFILE=profile)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(plistlib.loads((output / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"], identifier)


if __name__ == "__main__":
    unittest.main()
