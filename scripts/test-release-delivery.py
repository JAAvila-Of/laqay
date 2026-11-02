"""Test publication gates with an offline GitHub fixture; never publish a release."""

import copy
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("delivery", Path(__file__).with_name("finalize-release.py"))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class ReleaseDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.files = {name: root / name for name in delivery.ASSET_NAMES}
        for name, path in self.files.items():
            path.write_bytes(f"Inert fixture: {name}".encode())
        self.release = {"id": 17, "tag_name": "v0.2.0", "draft": True, "prerelease": True,
                        "immutable": False, "assets": []}
        self.commands = []
        self.confirmed = True
        self.published_immutable = True
        self.commit = "a" * 40
        self.corrupt_download = False
        self.bad_attestation = False
        self.extra_asset = False
        self.addCleanup(patch.stopall)
        patch.object(delivery, "gh", side_effect=self.github).start()
        # Archive/PE validation has its own real-file suite. Here test publication gating.
        patch.object(delivery.distribution, "check").start()

    def github(self, *arguments):
        args = tuple(map(str, arguments))
        self.commands.append(args)
        if args[0] == "api":
            if "PATCH" in args:
                self.release.update(draft=False, immutable=self.published_immutable)
                return "{}"
            if "/git/ref/" in args[1]:
                return json.dumps({"object": {"type": "tag", "sha": "b" * 40}})
            if "/git/tags/" in args[1]:
                return json.dumps({"object": {"type": "commit", "sha": self.commit}})
            return json.dumps(copy.deepcopy(self.release))
        if args[:2] == ("release", "upload"):
            self.release["assets"] = [
                {"name": name, "state": "uploaded", "size": path.stat().st_size,
                 "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()}
                for name, path in self.files.items()
            ]
            if self.extra_asset:
                self.release["assets"].append({"name": "unexpected.log"})
        elif args[:2] == ("release", "download"):
            destination = Path(args[args.index("--dir") + 1])
            for name, path in self.files.items():
                data = path.read_bytes()
                (destination / name).write_bytes(data + b"changed" if self.corrupt_download else data)
        elif args[0] == "attestation" and self.bad_attestation:
            raise RuntimeError("Untrusted provenance")
        return ""

    def finalize(self):
        delivery.finalize("example/project", "v0.2.0", "a" * 40,
                          self.files["laqay.exe"], self.files["laqay-windows-x86_64.zip"],
                          Path("unused-notice-fixture"), self.files["SHA256SUMS.txt"],
                          immutability_confirmed=self.confirmed)

    def assert_unpublished(self):
        self.assertFalse(any("PATCH" in command for command in self.commands))

    def test_publish_only_after_download_and_all_provenance_checks(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.finalize()
        publish = next(i for i, command in enumerate(self.commands) if "PATCH" in command)
        attestations = [i for i, command in enumerate(self.commands) if command[0] == "attestation"]
        self.assertEqual(len(attestations), 3)
        self.assertLess(max(attestations), publish)
        self.assertTrue(any(command[:2] == ("release", "verify-asset") for command in self.commands[publish:]))
        for i in attestations:
            command = self.commands[i]
            self.assertIn("example/project/.github/workflows/release.yml", command)
            self.assertIn("--source-digest", command)
            self.assertIn("--deny-self-hosted-runners", command)

    def test_changed_download_never_publishes(self):
        self.corrupt_download = True
        with self.assertRaisesRegex(ValueError, "Downloaded bytes"):
            self.finalize()
        self.assert_unpublished()

    def test_invalid_provenance_never_publishes(self):
        self.bad_attestation = True
        with self.assertRaisesRegex(RuntimeError, "Untrusted"):
            self.finalize()
        self.assert_unpublished()

    def test_wrong_tag_commit_never_uploads_or_publishes(self):
        self.commit = "c" * 40
        with self.assertRaisesRegex(ValueError, "reviewed source"):
            self.finalize()
        self.assertFalse(any(command[:2] == ("release", "upload") for command in self.commands))
        self.assert_unpublished()

    def test_missing_administrative_preflight_never_publishes(self):
        self.confirmed = False
        with self.assertRaisesRegex(ValueError, "administrator"):
            self.finalize()
        self.assert_unpublished()

    def test_mutable_publication_cannot_report_success(self):
        self.published_immutable = False
        with self.assertRaisesRegex(ValueError, "immutable pre-release"):
            self.finalize()

    def test_published_release_and_existing_assets_are_not_reused(self):
        for mutation in ({"draft": False}, {"assets": [{"name": "existing"}]}, {"prerelease": False}):
            with self.subTest(mutation=mutation):
                original = copy.deepcopy(self.release)
                self.release.update(mutation)
                with self.assertRaises(ValueError):
                    self.finalize()
                self.assert_unpublished()
                self.release = original

    def test_unexpected_remote_asset_never_publishes(self):
        self.extra_asset = True
        with self.assertRaisesRegex(ValueError, "release assets"):
            self.finalize()
        self.assert_unpublished()

    def test_remote_digest_mismatch_is_rejected(self):
        assets = [{"name": name, "state": "uploaded", "size": path.stat().st_size,
                   "digest": "sha256:" + "0" * 64} for name, path in self.files.items()]
        with self.assertRaisesRegex(ValueError, "verified build"):
            delivery.check_assets({"assets": assets}, self.files)


if __name__ == "__main__":
    unittest.main()
