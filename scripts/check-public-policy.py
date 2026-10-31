"""Validate commit subjects and the repository's public contribution surface."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
SUBJECT = re.compile(
    r"(?:feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)"
    r"(?:\([a-zA-Z0-9_./-]+\))?!?: \S[^\r\n]*"
)
REQUIRED = (
    "LICENSE", "README.md", "CONTRIBUTING.md", "TRADEMARKS.md", "SECURITY.md",
    "CODE_OF_CONDUCT.md", "GOVERNANCE.md", "SUPPORT.md", "docs/RELEASING.md",
    "THIRD_PARTY_NOTICES.md", "deny.toml",
    ".github/CODEOWNERS", ".github/PULL_REQUEST_TEMPLATE.md",
    ".github/ISSUE_TEMPLATE/bug.yml", ".github/ISSUE_TEMPLATE/proposal.yml",
    ".github/ISSUE_TEMPLATE/question.yml", ".github/ISSUE_TEMPLATE/config.yml",
    ".github/dependabot.yml", ".github/rulesets/main.json",
    ".github/rulesets/release-tags.json",
)


def check_subject(subject):
    if len(subject) > 100 or not SUBJECT.fullmatch(subject) or subject != subject.rstrip():
        raise ValueError(f"Expected a Conventional Commit subject of at most 100 characters: {subject!r}")


def git(*arguments):
    return subprocess.check_output(
        ["git", *arguments], cwd=ROOT, text=True, encoding="utf-8"
    ).strip()


def main():
    for filename in REQUIRED:
        if not (ROOT / filename).is_file() or not (ROOT / filename).stat().st_size:
            raise ValueError(f"Missing or empty public file: {filename}")
    for filename in ("main.json", "release-tags.json"):
        json.loads((ROOT / ".github/rulesets" / filename).read_text(encoding="utf-8"))

    # Check tracked Markdown only; build outputs and private directories are not
    # part of the public surface. External URLs are not fetched by this check.
    for filename in git("ls-files", "-z").split("\0"):
        if not filename.endswith(".md"):
            continue
        path = ROOT / filename
        for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", path.read_text(encoding="utf-8")):
            target = target.split("#", 1)[0]
            if not target or re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:", target):
                continue
            destination = (path.parent / unquote(target)).resolve()
            if not destination.is_relative_to(ROOT) or not destination.exists():
                raise ValueError(f"Invalid local link in {filename}: {target}")

    title = os.environ.get("PR_TITLE", "")
    if title:
        number = os.environ.get("PR_NUMBER", "")
        if not number.isdecimal():
            raise ValueError("Missing PR number for squash-subject validation")
        check_subject(f"{title} (#{number})")
        base, head = os.environ.get("PR_BASE", ""), os.environ.get("PR_HEAD", "")
        if not all(re.fullmatch(r"[0-9a-f]{40}", value) for value in (base, head)):
            raise ValueError("Expected full commit IDs for the pull request range")
        commits = git("rev-list", f"{base}..{head}").splitlines()
        if not commits:
            raise ValueError("The pull request contains no commits")
    else:
        commits = ["HEAD"]
    for commit in commits:
        check_subject(git("show", "-s", "--format=%s", commit))
    print("Public files, local links, and commit subjects passed.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Policy check failed: {error}", file=sys.stderr)
        sys.exit(1)
