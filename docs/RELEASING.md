# Versioning and releases

release-plz is the only tool responsible for package versions, release changelogs,
release PRs, `v<version>` tags, and GitHub releases. Do not bump `Cargo.toml`,
edit generated release notes, or create release tags manually. Dependency updates
do not change Laqay's version outside a release-plz PR.

## Before a release

1. Review the current integration matrix and resolve release-blocking issues.
   Record the tested OS builds, completed scenarios, and known limitations.
2. Ensure the intended source changes are merged and required checks pass.
3. Run the **Release** workflow on `main` with action **prepare**. It validates
   the code and asks release-plz to create or update the release PR.
4. Review that PR, its generated version/changelog, and the compatibility impact.
   Required checks and normal PR rules apply. Do not merge automatically.
5. After merging the release PR, run **Release** on `main` with action **publish**.
   Only commits associated with release PRs are eligible for publication.

Automation-created PR workflows may require a maintainer to approve their runs
in GitHub. Start the required checks when requested; do not bypass them or use
a broader token simply to skip review. See
[GitHub token behavior](https://docs.github.com/en/actions/concepts/security/github_token).

## Validation and assets

The Windows job builds the executable from the exact release tag and uploads
it with SHA-256 checksums. Review workflow success, the tag's commit, release
notes, and asset/checksum names before announcing the release. Do not silently
replace an asset. If publication fails, investigate and document the recovery;
an already published version is not a reusable version number.

The release archive also carries LICENSE, THIRD_PARTY_NOTICES.md, and generated
Cargo license texts, TRADEMARKS.md, and PORTABLE.md. Preserve this archive's
notices when redistributing builds. The delivery contract is:

- `laqay.exe`: AMD64 PE32+ GUI executable, built with the static C runtime.
- `laqay-windows-x86_64.zip`: that exact executable and the five notice/guide
  files, with no nested directories or extra entries.
- `SHA256SUMS.txt`: SHA-256 entries for the executable and ZIP.

Both CI and Release run the same packaging and validation commands. Validation
rejects missing, extra, duplicate, or changed ZIP entries, empty notice files,
an unexpected executable architecture/subsystem, and mismatched checksums.
It reads files without starting the application. Regression tests include the
actual PowerShell packaging command with an inert header fixture on Windows.
The CI development artifact includes all three delivery assets.

The current workflow creates the GitHub release before the asset job runs.
Do not announce or treat it as ready until all three assets have uploaded and
been downloaded and checked. If the asset job fails, preserve its evidence;
do not rerun publication or overwrite existing assets blindly. Investigate the
missing assets and use an explicitly reviewed recovery. A green `prepare` run
only prepares a release PR; it does not validate tag creation or asset upload.

Before `1.0.0`, complete a real `0.x` prepare/review/publish cycle, verify the
tag's commit and downloaded assets, then exercise the portable package in an
isolated guest: launch, paste, startup enabled/disabled across login, replacement
with another verified build after exit, and removal of its startup registration.
Record that first-version replacement is not evidence of cross-version upgrade
compatibility. The [portable guide](PORTABLE.md) defines the user steps; there is
no installer or automatic updater.

An Actions build artifact is a development build, not a published release.
A checksum detects corruption or a mismatch; it is not a code-signing certificate
or a claim that the complete desktop matrix passed. Current releases must state
any remaining engineering-validation limits.

The project is in `0.x`; compatibility may change. Describe breaking behavior
in the PR and generated release notes. Do not promise a stable interface or
support for older versions before the project adopts such a policy.

## Licensing and security

Preserve the project's MIT notice and third-party notices when distributing
builds. Review new dependencies for license compatibility and known security
advisories. Handle undisclosed vulnerabilities through [SECURITY.md](../SECURITY.md).
Release tags are immutable under repository rules; fixes belong in new releases.
