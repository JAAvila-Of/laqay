"""Verify a release-plz draft before publishing its immutable delivery."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time


spec = importlib.util.spec_from_file_location("distribution", Path(__file__).with_name("check-distribution.py"))
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)
ASSET_NAMES = {"laqay.exe", "laqay-windows-x86_64.zip", "SHA256SUMS.txt"}
RECOVERY_SOURCE = "d0b0c24e1892878db3095d24a57ca52894d29988"
RECOVERY_RELEASE_ID = 431972518
RECOVERY_WORKFLOW = ".github/workflows/recover-release.yml"
SOURCE_PREDICATE = "https://github.com/JAAvila-Of/laqay/attestations/release-source/v1"


def gh(*arguments):
    result = subprocess.run(["gh", *map(str, arguments)], capture_output=True, text=True, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "GitHub CLI command failed")
    return result.stdout.strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_channel(tag, channel):
    require(channel in ("preview", "stable"), "Unknown release channel")
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", tag), "Invalid release tag")
    if channel == "stable":
        require(re.fullmatch(r"v[1-9][0-9]*\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", tag),
                "Stable delivery requires a final version at or above 1.0.0")


def check_draft(release, tag, channel="preview"):
    check_channel(tag, channel)
    require(release["tag_name"] == tag and release["draft"] and not release.get("immutable", False),
            "Expected an unpublished release-plz draft; do not modify a published release")
    require(release["prerelease"] is (channel == "preview"),
            "Draft prerelease flag does not match the explicit release channel")


def check_assets(release, files):
    assets = release["assets"]
    require(len(assets) == 3 and {item["name"] for item in assets} == ASSET_NAMES,
            "Unexpected, duplicate, or missing release assets")
    for item in assets:
        data = files[item["name"]].read_bytes()
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        require(item["state"] == "uploaded" and item["size"] == len(data) and item.get("digest") == digest,
                f"Uploaded asset does not match the verified build: {item['name']}")


def check_tag(api, tag, commit):
    reference = json.loads(gh("api", f"{api}/git/ref/tags/{tag}"))["object"]
    for _ in range(5):
        if reference["type"] == "commit":
            require(reference["sha"] == commit, "Release tag does not match the reviewed source commit")
            return
        require(reference["type"] == "tag", "Unexpected release tag object")
        reference = json.loads(gh("api", f"{api}/git/tags/{reference['sha']}"))["object"]
    raise ValueError("Too many annotated tag indirections")


def source_binding(repository, tag, source_commit, builder_commit):
    return {"repository": repository, "tag": tag, "sourceCommit": source_commit, "builderCommit": builder_commit}


def check_source_binding(verified, expected):
    require(any(item.get("verificationResult", {}).get("statement", {}).get("predicateType") == SOURCE_PREDICATE
                and item["verificationResult"]["statement"].get("predicate") == expected for item in verified),
            "Verified recovery attestation does not bind the expected tag, source, and builder")


def verify_published(*arguments):
    # Release attestations may take a moment to become readable after publication.
    for attempt in range(3):
        try:
            return gh(*arguments)
        except RuntimeError:
            if attempt == 2:
                raise
            time.sleep(2)


def finalize(repository, tag, commit, binary, archive, licenses, checksums, immutability_confirmed=False,
             recovery_builder_commit=None, channel="preview"):
    # The repository setting requires Administration read, unavailable to GITHUB_TOKEN.
    require(immutability_confirmed, "An administrator must confirm release immutability before dispatch")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid repository")
    check_channel(tag, channel)
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "Expected a full source commit")
    signer = ".github/workflows/release.yml"
    builder = commit
    if recovery_builder_commit is not None:
        require(channel == "preview", "Historical recovery must remain a preview")
        require(repository == "JAAvila-Of/laqay" and tag == "v0.1.1" and commit == RECOVERY_SOURCE,
                "Recovery is restricted to the reviewed v0.1.1 source")
        require(re.fullmatch(r"[0-9a-f]{40}", recovery_builder_commit), "Expected a full recovery builder commit")
        signer, builder = RECOVERY_WORKFLOW, recovery_builder_commit
    distribution.check(binary, archive, licenses, checksums)
    api = f"repos/{repository}"
    check_tag(api, tag, commit)
    # The by-tag REST endpoint only returns published releases. CLI discovery also finds drafts.
    release_id = json.loads(gh("release", "view", tag, "--repo", repository, "--json", "databaseId"))["databaseId"]
    require(type(release_id) is int and release_id > 0, "Invalid discovered release ID")
    if recovery_builder_commit is not None:
        require(release_id == RECOVERY_RELEASE_ID, "Recovery draft ID changed")
    release = json.loads(gh("api", f"{api}/releases/{release_id}"))
    check_draft(release, tag, channel)
    require(not release["assets"], "Draft already has assets; inspect it before an explicit recovery")
    release_api = f"{api}/releases/{release['id']}"
    files = {path.name: path for path in (binary, archive, checksums)}
    require(set(files) == ASSET_NAMES, "Unexpected local delivery names")
    gh("release", "upload", tag, *files.values(), "--repo", repository)
    with tempfile.TemporaryDirectory() as directory:
        downloaded = Path(directory)
        gh("release", "download", tag, "--repo", repository, "--dir", downloaded)
        require({path.name for path in downloaded.iterdir()} == ASSET_NAMES, "Unexpected downloaded assets")
        for name, path in files.items():
            require((downloaded / name).read_bytes() == path.read_bytes(), f"Downloaded bytes differ: {name}")
        distribution.check(downloaded / binary.name, downloaded / archive.name, licenses, downloaded / checksums.name)
        for name in sorted(ASSET_NAMES):
            policy = ("--repo", repository, "--signer-workflow", f"{repository}/{signer}",
                      "--source-digest", builder, "--source-ref", "refs/heads/main", "--deny-self-hosted-runners")
            gh("attestation", "verify", downloaded / name, *policy)
            if recovery_builder_commit is not None:
                verified = json.loads(gh("attestation", "verify", downloaded / name, *policy,
                                         "--predicate-type", SOURCE_PREDICATE, "--format", "json"))
                check_source_binding(verified, source_binding(repository, tag, commit, builder))
        current = json.loads(gh("api", release_api))
        check_draft(current, tag, channel)
        check_assets(current, files)
        check_tag(api, tag, commit)
        # release-plz owns version/tag/notes and created this draft. Only now expose it.
        gh("api", "--method", "PATCH", release_api, "-F", "draft=false", "-f",
           "make_latest=" + ("true" if channel == "stable" else "false"))
        published = json.loads(gh("api", release_api))
        require(published["tag_name"] == tag and not published["draft"] and published["immutable"]
                and published["prerelease"] is (channel == "preview"),
                "Publication did not produce the expected immutable release channel")
        check_assets(published, files)
        verify_published("release", "verify", tag, "--repo", repository)
        for name in sorted(ASSET_NAMES):
            verify_published("release", "verify-asset", tag, downloaded / name, "--repo", repository)
    print(f"Immutable release {tag}, downloaded assets, and build/release attestations verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--immutability-confirmed", action="store_true")
    parser.add_argument("--recovery-builder-commit")
    parser.add_argument("--channel", choices=("preview", "stable"), default="preview")
    for name in ("repository", "tag", "commit"):
        parser.add_argument(f"--{name}", required=True)
    for name in ("binary", "archive", "licenses", "checksums"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    finalize(**vars(args))


if __name__ == "__main__":
    main()
