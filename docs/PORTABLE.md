# Using the portable Windows build

Laqay is a portable application for Windows x64. It saves clipboard images as
PNG files when you press Ctrl+V in a physical Windows Explorer folder. There is
no installer, service, driver, or automatic updater. The executable requests no
administrator access. Windows may show a reputation warning for an unsigned
download; SHA-256 checksums do not provide publisher authentication.

## Download and start

Download `laqay-windows-x86_64.zip` and `SHA256SUMS.txt` from the same GitHub
release at https://github.com/JAAvila-Of/laqay/releases. Compare the archive's
SHA-256 with its entry in the checksum file before extracting:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\laqay-windows-x86_64.zip
```

Releases produced by the protected publication flow also provide build
provenance and immutable-release attestations. Use a current GitHub CLI to
verify the release and your downloaded ZIP, replacing `vX.Y.Z` with its tag:

```powershell
gh release verify vX.Y.Z --repo JAAvila-Of/laqay
gh release verify-asset vX.Y.Z .\laqay-windows-x86_64.zip --repo JAAvila-Of/laqay
```

The repository's `docs/RELEASING.md` explains how to verify build provenance
against the exact workflow and source commit. `v0.1.0` predates these protections
and only provides checksums. These attestations do not add a Windows publisher
signature or guarantee that SmartScreen will accept the executable.

Extract all files to a permanent folder writable by your account, and run
`laqay.exe`. Preserve the accompanying licenses and notices. The separately
provided `laqay.exe` asset is the same executable included in the ZIP; use the
ZIP to retain the distribution's notices.

The tray menu provides **Enabled**, **Start with Windows**, and **Exit**.
Enabled defaults to on; startup defaults to off. Capture or copy an image,
focus a physical Explorer folder, and press Ctrl+V. Native file and text pastes
keep their normal behavior. Virtual folders and editable controls are excluded.

## Update or move

Download and verify the new release. Turn **Start with Windows** off if enabled,
then choose **Exit** before replacing the files. Extract the complete new ZIP,
launch its executable, and enable startup again if desired. This also refreshes
the saved startup path when moving the folder. Keep a previous verified ZIP if
you need to return to that version; compatibility across `0.x` is not guaranteed.

## Remove

Turn **Start with Windows** off and choose **Exit** before deleting the extracted
folder. This removes Laqay's startup registration. The per-user Enabled preference
may remain under `HKCU\Software\Laqay`; to remove that preference too, delete only
that key after exiting. Saved PNGs belong to you and remain in their folders.

## Validation limits and support

Recorded desktop evidence for 1.0.0 covers Windows 11 Enterprise evaluation
and basic Windows 10 Pro scenarios, with separate UNC, RDP and pending-read
shutdown results. The writer changes prepared for 1.0.1 passed directed native,
real disk-full and SMB recovery checks and CI application preference tests.
The complete interactive guest matrix was not repeated for those changes.

Consult the release's tagged validation matrix for exact source/artifact
identities, OS builds and remaining limits; the repository's current matrix is
at https://github.com/JAAvila-Of/laqay/blob/main/docs/integration-tests.md.
Coverage does not establish every application, filesystem, reconnect or
shutdown/encoding stage. Published downloads and their lifecycle must be checked
separately from development artifacts. See the keyboard and data-handling policy
at https://github.com/JAAvila-Of/laqay/blob/main/docs/PRIVACY.md.

Report reproducible problems at https://github.com/JAAvila-Of/laqay/issues.
For undisclosed security issues, use the repository's private vulnerability
reporting channel described in SECURITY.md, rather than a public issue.
