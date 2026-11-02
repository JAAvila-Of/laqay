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


def gh(*arguments):
    result = subprocess.run(["gh", *map(str, arguments)], capture_output=True, text=True, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "GitHub CLI command failed")
    return result.stdout.strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_draft(release, tag):
    require(release["tag_name"] == tag and release["draft"] and not release.get("immutable", False),
            "Expected an unpublished release-plz draft; do not modify a published release")
    require(release["prerelease"], "Engineering releases must remain pre-releases")


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


def verify_published(*arguments):
    # Release attestations may take a moment to become readable after publication.
    for attempt in range(3):
        try:
            return gh(*arguments)
        except RuntimeError:
            if attempt == 2:
                raise
            time.sleep(2)


def finalize(repository, tag, commit, binary, archive, licenses, checksums):
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid repository")
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", tag), "Invalid release tag")
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "Expected a full source commit")
    distribution.check(binary, archive, licenses, checksums)
    api = f"repos/{repository}"
    require(json.loads(gh("api", f"{api}/immutable-releases"))["enabled"],
            "Enable repository release immutability before publication")
    check_tag(api, tag, commit)
    release = json.loads(gh("api", f"{api}/releases/tags/{tag}"))
    check_draft(release, tag)
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
            gh("attestation", "verify", downloaded / name, "--repo", repository,
               "--signer-workflow", f"{repository}/.github/workflows/release.yml",
               "--source-digest", commit, "--source-ref", "refs/heads/main", "--deny-self-hosted-runners")
        current = json.loads(gh("api", release_api))
        check_draft(current, tag)
        check_assets(current, files)
        check_tag(api, tag, commit)
        require(json.loads(gh("api", f"{api}/immutable-releases"))["enabled"],
                "Repository release immutability was disabled before publication")
        # release-plz owns version/tag/notes and created this draft. Only now expose it.
        gh("api", "--method", "PATCH", release_api, "-F", "draft=false", "-f", "make_latest=false")
        published = json.loads(gh("api", release_api))
        require(published["tag_name"] == tag and not published["draft"] and published["immutable"]
                and published["prerelease"], "Publication did not produce the expected immutable pre-release")
        check_assets(published, files)
        verify_published("release", "verify", tag, "--repo", repository)
        for name in sorted(ASSET_NAMES):
            verify_published("release", "verify-asset", tag, downloaded / name, "--repo", repository)
    print(f"Immutable release {tag}, downloaded assets, and build/release attestations verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repository", "tag", "commit"):
        parser.add_argument(f"--{name}", required=True)
    for name in ("binary", "archive", "licenses", "checksums"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    finalize(**vars(args))


if __name__ == "__main__":
    main()
