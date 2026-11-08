# Privacy and keyboard observation

Laqay recognizes Ctrl+V to save clipboard images in supported physical Windows
Explorer folders. It has no account, telemetry, clipboard history, or keyboard
history. It does not send keystrokes or images to an application server.

## Keyboard events

While enabled, Laqay installs a Windows low-level keyboard hook on its desktop.
Windows delivers keyboard events globally to this callback; it does not deliver
only Ctrl+V. The callback discards other letters and retains only the current
modifier-key state and whether V is held, to recognize Ctrl+V without repeats.
It does not translate keys into text, reconstruct what you type, or record
passwords. Aggregate event counters are not a sequence of recorded keystrokes.

The hook always passes input to the next Windows handler. It does not suppress,
replace, or synthesize input, and it does not inject code into other processes.
Turning **Enabled** off removes the hook; **Exit** closes the application.
Raw Input is not enabled in normal operation; bounded diagnostic modes may
enable it to compare input delivery.

## Clipboard and files

A recognized paste request first needs an eligible Explorer process, focused
folder view, and physical destination. Laqay then checks that the clipboard
sequence is still the requested one before reading a supported image format.
It does not read clipboard text as part of this operation. Copied files and
virtual-file transfers retain native paste behavior.

Image conversion and saving happen on your computer under your Windows account.
Saving to a UNC share uses Windows file sharing to the destination you selected.
Windows clipboard redirection, cloud clipboard, folder synchronization, and other
applications can transfer data independently of Laqay.

Supported PNG clipboard data is validated and preserved without re-encoding.
This also preserves any metadata already present, such as textual or EXIF
chunks. Laqay does not anonymize images or remove sensitive pixels or metadata.
Temporary encoded files are staged in the destination folder. Failed operations
attempt to clean up their own staging data; interruptions or unavailable storage
can leave a temporary file. Saved PNGs remain until you remove them.

The writer holds the directory chain against renaming, verifies
the staging file's resolved parent by handle before writing image data, and
keeps the original staging handle open through publication. If the required
access or sharing guarantees cannot be obtained, saving fails rather than
relaxing the locks.
This does not make Explorer's focus check atomic with the file operation, and
it cannot protect against an administrator, kernel-level changes, or a remote
file server that does not enforce Windows sharing semantics. These filesystem
changes are not present in the published 1.0.0 executable.

## Preferences and diagnostics

Laqay stores its Enabled preference in `HKCU\Software\Laqay`. **Start with
Windows** defaults to off; enabling it creates Laqay's own value in your account's
Windows startup registry key. There is no service, driver, or automatic updater.
See [portable operation and removal](PORTABLE.md).

Normal operation does not enable verbose diagnostic output. Explicitly enabling
`LAQAY_DIAGNOSTICS=1` or a diagnostic probe can expose output paths, window and
focus identifiers, event counts, timings, and Windows session/desktop metadata.
`LAQAY_DIAGNOSTICS=failures` enables limited rejection/error diagnostics. These
modes do not record typed text. Probe output folders may also contain synthetic
test data and reports. Inspect and sanitize all diagnostics before sharing them;
never attach private clipboard contents or unsanitized paths to a public issue.

## Trust and reporting

Run Laqay as a normal user, without administrator privileges, and keep Windows
updated: the application processes untrusted image data using Windows codecs.
The portable executable is not Authenticode-signed. Checksums and GitHub
attestations help verify the distribution but do not add a Windows publisher
signature. No signing method guarantees the absence of antivirus warnings.

Report suspected unintended disclosure privately through [the security
policy](../SECURITY.md). See [development documentation](DEVELOPMENT.md) for
diagnostic commands and [validation coverage](integration-tests.md) for limits.
