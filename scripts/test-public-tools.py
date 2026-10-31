"""Regression checks for the contribution and license-collection tools."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


policy = load("public_policy", "check-public-policy.py")
licenses = load("cargo_licenses", "collect-cargo-licenses.py")


class PublicToolsTests(unittest.TestCase):
    def test_conventional_subjects_and_breaking_changes(self):
        for subject in ("fix: preserve paste", "feat(explorer)!: change folder selection", "chore: release v0.1.0 (#12)"):
            policy.check_subject(subject)

    def test_invalid_subjects_and_multiline_titles_are_rejected(self):
        for subject in ("update files", "feat: ", "fix(): empty scope", "fix: text\nextra", "fix: trailing ", "fix: " + "x" * 96):
            with self.subTest(subject=subject), self.assertRaises(ValueError):
                policy.check_subject(subject)

    def test_license_collection_preserves_multiple_original_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "LICENSE-MIT").write_text("Copyright Example\nPermission text.\n", encoding="utf-8")
            (root / "LICENSE-UNICODE").write_text("Unicode notice.\n", encoding="utf-8")
            metadata = {"packages": [{
                "name": "example", "version": "1.0.0", "source": "registry+example",
                "manifest_path": str(root / "Cargo.toml"), "license": "MIT AND Unicode-3.0",
            }]}
            result = licenses.collect(metadata)
            self.assertIn("Copyright Example\nPermission text.\n", result)
            self.assertIn("Unicode notice.\n", result)
            self.assertIn("MIT AND Unicode-3.0", result)
            self.assertNotIn(str(root), result)

    def test_dependency_without_a_notice_fails_instead_of_disappearing(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = {"packages": [{
                "name": "missing-notice", "version": "1.0.0", "source": "registry+example",
                "manifest_path": str(Path(directory) / "Cargo.toml"), "license": "MIT",
            }]}
            with self.assertRaisesRegex(ValueError, "No license text"):
                licenses.collect(metadata)


if __name__ == "__main__":
    unittest.main()
