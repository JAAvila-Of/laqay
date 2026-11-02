"""Test publication gates with an offline GitHub fixture; never publish a release."""

import copy
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("delivery", Path(__file__).with_name("finalize-release.py"))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)
recovery_spec = importlib.util.spec_from_file_location("recovery", Path(__file__).with_name("prepare-release-recovery.py"))
recovery = importlib.util.module_from_spec(recovery_spec)
recovery_spec.loader.exec_module(recovery)


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
        self.repository = "example/project"
        self.tag = "v0.2.0"
        self.expected_commit = self.commit
        self.recovery_builder = None
        self.bad_binding = False
        self.missing_binding = False
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
            if "/releases/tags/" in args[1]:
                raise RuntimeError("By-tag REST lookup does not return draft releases")
            if "PATCH" in args:
                self.release.update(draft=False, immutable=self.published_immutable)
                return "{}"
            if "/git/ref/" in args[1]:
                return json.dumps({"object": {"type": "tag", "sha": "b" * 40}})
            if "/git/tags/" in args[1]:
                return json.dumps({"object": {"type": "commit", "sha": self.commit}})
            return json.dumps(copy.deepcopy(self.release))
        if args[:2] == ("release", "view"):
            return json.dumps({"databaseId": self.release["id"]})
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
        elif args[0] == "attestation" and "--predicate-type" in args:
            if self.missing_binding:
                return "[]"
            predicate = delivery.source_binding(self.repository, self.tag, self.expected_commit, self.recovery_builder)
            if self.bad_binding:
                predicate["sourceCommit"] = "f" * 40
            return json.dumps([{"verificationResult": {"statement": {
                "predicateType": delivery.SOURCE_PREDICATE, "predicate": predicate}}}])
        return ""

    def finalize(self):
        delivery.finalize(self.repository, self.tag, self.expected_commit,
                          self.files["laqay.exe"], self.files["laqay-windows-x86_64.zip"],
                          Path("unused-notice-fixture"), self.files["SHA256SUMS.txt"],
                          immutability_confirmed=self.confirmed, recovery_builder_commit=self.recovery_builder)

    def use_reviewed_recovery(self):
        self.repository, self.tag = "JAAvila-Of/laqay", "v0.1.1"
        self.commit = self.expected_commit = delivery.RECOVERY_SOURCE
        self.recovery_builder = "d" * 40
        self.release.update(id=delivery.RECOVERY_RELEASE_ID, tag_name=self.tag)

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

    def test_recovery_requires_signed_binding_for_every_asset(self):
        self.use_reviewed_recovery()
        with contextlib.redirect_stdout(io.StringIO()):
            self.finalize()
        bindings = [command for command in self.commands if "--predicate-type" in command]
        self.assertEqual(len(bindings), 3)
        for command in bindings:
            self.assertIn(self.recovery_builder, command)
            self.assertIn(f"{self.repository}/{delivery.RECOVERY_WORKFLOW}", command)

    def test_wrong_recovery_source_binding_never_publishes(self):
        self.use_reviewed_recovery()
        self.bad_binding = True
        with self.assertRaisesRegex(ValueError, "bind the expected"):
            self.finalize()
        self.assert_unpublished()

    def test_missing_recovery_binding_never_publishes(self):
        self.use_reviewed_recovery()
        self.missing_binding = True
        with self.assertRaisesRegex(ValueError, "bind the expected"):
            self.finalize()
        self.assert_unpublished()

    def test_recovery_cannot_select_another_release(self):
        self.recovery_builder = "d" * 40
        with self.assertRaisesRegex(ValueError, "restricted"):
            self.finalize()
        self.assert_unpublished()

    def test_recreated_recovery_draft_is_rejected(self):
        self.use_reviewed_recovery()
        self.release["id"] += 1
        with self.assertRaisesRegex(ValueError, "draft ID changed"):
            self.finalize()
        self.assert_unpublished()


class RecoveryBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source, self.builder = self.root / "source", self.root / "control"
        self.source.mkdir()
        self.builder.mkdir()
        (self.source / "Cargo.toml").write_text('[package]\nname = "laqay"\nversion = "0.1.1"\n', encoding="utf-8")
        self.release = {"id": delivery.RECOVERY_RELEASE_ID, "tag_name": "v0.1.1", "draft": True,
                        "immutable": False, "prerelease": True, "assets": []}
        self.source_commit = delivery.RECOVERY_SOURCE
        self.modified = False
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"GITHUB_REPOSITORY": "JAAvila-Of/laqay", "GITHUB_REF": "refs/heads/main",
                               "GITHUB_WORKFLOW_REF": f"JAAvila-Of/laqay/{delivery.RECOVERY_WORKFLOW}@refs/heads/main",
                               "GITHUB_SHA": "d" * 40}).start()
        patch.object(recovery, "git", side_effect=self.git).start()
        patch.object(recovery.delivery, "gh", side_effect=self.github).start()

    def git(self, path, *arguments):
        if arguments[0] == "status":
            return " M Cargo.toml" if self.modified else ""
        return self.source_commit if path == self.source else "d" * 40

    def github(self, *arguments):
        if "/git/ref/" in arguments[1]:
            return json.dumps({"object": {"type": "commit", "sha": delivery.RECOVERY_SOURCE}})
        return json.dumps(self.release)

    def prepare(self):
        with contextlib.redirect_stdout(io.StringIO()):
            recovery.prepare(self.source, self.builder, self.root / "binding.json")

    def test_binding_records_distinct_reviewed_source_and_builder(self):
        self.prepare()
        binding = json.loads((self.root / "binding.json").read_text())
        self.assertEqual(binding, delivery.source_binding("JAAvila-Of/laqay", "v0.1.1", delivery.RECOVERY_SOURCE, "d" * 40))

    def test_wrong_workflow_or_source_is_refused(self):
        with patch.dict(os.environ, {"GITHUB_REF": "refs/heads/unreviewed"}):
            with self.assertRaisesRegex(ValueError, "reviewed main"):
                self.prepare()
        self.source_commit = "f" * 40
        with self.assertRaisesRegex(ValueError, "approved v0.1.1"):
            self.prepare()

    def test_modified_checkout_is_refused(self):
        self.modified = True
        with self.assertRaisesRegex(ValueError, "Modified recovery checkout"):
            self.prepare()

    def test_wrong_version_is_refused(self):
        (self.source / "Cargo.toml").write_text('[package]\nname = "laqay"\nversion = "0.1.2"\n', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "package mismatch"):
            self.prepare()

    def test_populated_draft_is_refused(self):
        self.release["assets"] = [{"name": "unexpected"}]
        with self.assertRaisesRegex(ValueError, "still be empty"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
