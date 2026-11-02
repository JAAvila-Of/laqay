"""Bind the one-time v0.1.1 recovery build to its reviewed source and builder."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tomllib


spec = importlib.util.spec_from_file_location("delivery", Path(__file__).with_name("finalize-release.py"))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


def git(path, *arguments):
    return subprocess.check_output(["git", "-C", str(path), *arguments], text=True, encoding="utf-8").strip()


def prepare(source, builder, output):
    repository = "JAAvila-Of/laqay"
    delivery.require(os.environ.get("GITHUB_REPOSITORY") == repository
                     and os.environ.get("GITHUB_REF") == "refs/heads/main"
                     and os.environ.get("GITHUB_WORKFLOW_REF") == f"{repository}/{delivery.RECOVERY_WORKFLOW}@refs/heads/main",
                     "Recovery requires the reviewed main-branch workflow")
    builder_commit = os.environ.get("GITHUB_SHA", "")
    delivery.require(len(builder_commit) == 40 and git(builder, "rev-parse", "HEAD") == builder_commit,
                     "Recovery control checkout differs from the workflow commit")
    delivery.require(git(source, "rev-parse", "HEAD") == delivery.RECOVERY_SOURCE,
                     "Recovery application checkout differs from the approved v0.1.1 commit")
    for path in (source, builder):
        delivery.require(not git(path, "status", "--porcelain", "--untracked-files=no"), "Modified recovery checkout")
    package = tomllib.loads((source / "Cargo.toml").read_text(encoding="utf-8"))["package"]
    delivery.require(package["name"] == "laqay" and package["version"] == "0.1.1", "Recovery package mismatch")
    release = json.loads(delivery.gh("api", f"repos/{repository}/releases/{delivery.RECOVERY_RELEASE_ID}"))
    delivery.check_draft(release, "v0.1.1")
    delivery.require(not release["assets"], "Recovery draft must still be empty")
    delivery.check_tag(f"repos/{repository}", "v0.1.1", delivery.RECOVERY_SOURCE)
    binding = delivery.source_binding(repository, "v0.1.1", delivery.RECOVERY_SOURCE, builder_commit)
    output.write_text(json.dumps(binding, indent=2) + "\n", encoding="utf-8")
    print("Reviewed recovery source, builder, empty draft, and tag verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "builder", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    prepare(**vars(parser.parse_args()))
