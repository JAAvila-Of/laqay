# Using the portable Windows build

Laqay is an engineering preview for Windows x64. It saves clipboard images as
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

Automated desktop evidence covers one Windows 11 Enterprise evaluation setup,
including local Explorer, real login startup, an authenticated UNC share, RDP
clipboard redirection, Explorer restart, and exit during a blocked clipboard
read. The full matrix remains incomplete. Windows 10, every storage failure,
RDP reconnects, and all shutdown/encoding stages have not been validated.
The initial release delivery and portable update/removal lifecycle must also
be checked separately from development artifacts.

Report reproducible problems at https://github.com/JAAvila-Of/laqay/issues.
For undisclosed security issues, use the repository's private vulnerability
reporting channel described in SECURITY.md, rather than a public issue.
