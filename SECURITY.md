# Security policy

## Private reports

Report suspected vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/JAAvila-Of/laqay/security/advisories/new).
Do not put exploit details, secrets, or private clipboard data in an issue,
discussion, or pull request. The advisory is the channel for coordinating
investigation and disclosure with the maintainer and invited collaborators.

Include the affected version or commit, Windows build, a minimal reproduction
using synthetic data, expected and actual behavior, and the security impact.
Useful reports include writing outside the intended destination, overwriting
files, memory-safety failures when decoding clipboard data, privilege-boundary
failures, and unintended disclosure of clipboard contents or private metadata.
An ordinary feature defect belongs in the public bug form after sanitization.

## Supported code

Security fixes target the latest stable release and current
`main` for the next release. Older releases and unofficial builds have no
backport commitment. A development build or passing CI is not evidence that
the full desktop validation matrix has passed.

## Handling and disclosure

There is no guaranteed response time or bounty program. The maintainer will
assess reports privately, request missing evidence when necessary, and coordinate
publication of an advisory and fix. Please agree on disclosure timing in the
advisory. A report does not authorize testing on another person's machine or data.

## Safe operation

The application runs as the current user and does not require elevation. It
handles untrusted image data and filesystem destinations; run supported Windows
updates, keep Laqay current, and avoid using development builds with irreplaceable
data. Download official releases from this repository, verify published checksums,
and review the stated validation limits. See [release handling](docs/RELEASING.md).

See [privacy and keyboard observation](docs/PRIVACY.md) for the input hook,
clipboard access, optional diagnostics, and image metadata. Run Laqay without
administrator privileges. Release checksums and GitHub attestations do not
constitute Windows Authenticode signing or a guarantee of antivirus acceptance.
