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

release-plz creates the version, tag, notes, and a draft GitHub release. The
Windows job builds the executable from that exact release tag and uploads
it with SHA-256 checksums. The checked-out commit must match the reviewed
workflow commit. Review workflow success, the tag's commit, release
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

The asset job generates a GitHub build-provenance attestation for all three
files using OIDC and a short-lived signing identity; no signing key is stored
in repository secrets. It downloads the uploaded draft assets and verifies
their exact bytes, package contents, API digests, and provenance. Verification
requires this repository's Release workflow, the expected source commit,
`refs/heads/main`, and GitHub-hosted runners.

Only after those checks does `scripts/finalize-release.py` publish the existing
release-plz draft, preserving its version, tag, title, and generated notes. The
repository must have release immutability enabled. Publication locks its assets
and tag and creates GitHub's separate release attestation. The job then verifies
that attestation and each downloaded asset with `gh release verify` and
`gh release verify-asset`. This final draft transition does not create a release
or choose a version outside release-plz.

If a check before publication fails, the release stays a draft. Preserve its
evidence; the script refuses published releases or drafts that already have
assets. Do not rerun publication or overwrite assets blindly. An inspected
recovery must identify the draft, source commit, and existing files. If a check
after publication fails, the release may already be immutable: investigate
without trying to replace its files. A green `prepare` run only prepares a
release PR; it does not validate tag creation, asset upload, or publication.

Release immutability applies to future publications, not retroactively.
`v0.1.0` predates this flow and has checksums but no build/release attestations
or immutable-release protection. Do not replace its files to add these claims.

## Verify a downloaded release

Use a current GitHub CLI. Substitute the release tag and its full commit SHA:

```powershell
$tag = 'vX.Y.Z'
$releaseCommit = 'FULL_COMMIT_SHA_FROM_THE_RELEASE_TAG'
gh release verify $tag --repo JAAvila-Of/laqay
gh release verify-asset $tag .\laqay-windows-x86_64.zip --repo JAAvila-Of/laqay
gh attestation verify .\laqay-windows-x86_64.zip --repo JAAvila-Of/laqay --signer-workflow JAAvila-Of/laqay/.github/workflows/release.yml --source-digest $releaseCommit --source-ref refs/heads/main --deny-self-hosted-runners
```

Run the asset/provenance checks for `laqay.exe` and `SHA256SUMS.txt` as well.
The release attestation binds the tag, commit, and published files; build
provenance identifies the workflow and source. Neither establishes that the
software is free of bugs or replaces Windows Authenticode signing.

CI also attests and verifies the three development-build files after successful
pushes to `main`, in a separate job with narrowly scoped OIDC/attestation
permissions. PRs do not run that job. Development attestations identify
`.github/workflows/ci.yml`; they do not prove a published release.

See [GitHub build attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
and [immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).

## Delivery validation before stable releases

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

During engineering validation, release-plz marks GitHub releases as pre-releases
and does not select them as latest. Its configured release body includes the
validation limits and links to the guide and matrix at that release's tag.
The release PR uses a plain review template with the generated changelog.
Revisit these settings explicitly when engineering validation is complete;
changing the package version alone does not promote a release to production.

## Licensing and security

Preserve the project's MIT notice and third-party notices when distributing
builds. Review new dependencies for license compatibility and known security
advisories. Handle undisclosed vulnerabilities through [SECURITY.md](../SECURITY.md).
Release tags are immutable under repository rules; fixes belong in new releases.
