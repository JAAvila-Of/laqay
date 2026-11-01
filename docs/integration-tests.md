# Windows integration validation

## Current automated coverage

The full matrix remains incomplete. The normal tray application has passed
thirteen local Explorer cases in an isolated Windows 11 Enterprise evaluation
guest (build 26300): image paste, preservation of existing output, multiple native
files with a bitmap present, address/search/rename text, disable/re-enable,
active tabs and windows, Unicode paths, clipboard preservation, and recovery
after denied file creation. A separate real-login cycle verified startup enabled
and disabled across fresh guest boots, including a PNG from the Windows-launched
process and a bounded 180-second absence observation when disabled.

The paired-guest UNC suite passed all thirteen local cases plus three UNC cases:
correct PNG with unchanged clipboard, a second PNG preserving the first, and
native file paste with a bitmap present. Explorer and Laqay ran with a limited
token. The controller verified the actual authenticated SMB 3.1.1 connection was
signed, and the peer independently matched hashes of both PNGs and the binary
file. Application exit, preference/permission restoration, task/credential/share
fixture cleanup, temporary auto-logon removal, and both guests off were checked.
See [the desktop lab procedures](DESKTOP_TEST_LAB.md) for the exact harness and
its limits. This does not validate a disconnected share, OneDrive, an RDP logon
or redirected clipboard in the paired lab, or Windows 10.

## Earlier bounded trials

This matrix has not been completed. One authorized RDP image-paste trial on
Windows 11 25H2 (build 26200.9711) passed the basic T33/T35 path: two Ctrl+V
presses created two valid 613x572 RGBA PNGs in the approved folder. The tester
confirmed correct images without notices or sounds. The initial folder was
empty; its focused Text and exact native List ancestor both exposed read-only
Value. The hook was removed and process exit was verified. This result is
limited to that session and screenshot, not a pass for other matrix scenarios.
A subsequent local-console trial (protocol 0) passed the basic T17/T33 path:
two presses saved two valid 1120x624 RGBA PNGs. The tester confirmed correct
images without notices or sounds; hook removal and process exit were verified.
A local T04 trial also passed for one regular file: native paste preserved its
SHA-256, created no PNG, and produced no unexpected notices or sounds according
to the tester. A local T07/T12 trial preserved text in Notepad and Explorer's
address bar; the observer declined both contexts, created no files, and the
tester confirmed correct text without disturbances. A basic local T14 trial
also preserved text paste in a rename Edit control; Esc cancelled the edit,
the original name/hash remained unchanged, and no PNG was created. The search
part of that trial used an incorrect shortcut and did not validate T13. A
separate T13 trial using Ctrl+F identified the search Edit control outside the
folder view and declined before image access; no files were created, and the
tester confirmed normal text paste. A first T16 two-tab trial saved a valid
PNG only in the approved first folder and explicitly declined the other
folder; the tester confirmed both tabs were in one window. The reverse block
also passed: a valid PNG appeared only in the newly approved second folder,
the first folder's original file/hash stayed unchanged, and the tester reported
no disturbances. This covers deliberate two-tab selection in both directions,
not rapid changes during a paste. Multiple/virtual files, other destinations,
and the remaining matrix were still pending at that point.
These results predate the shared-engine and tray integration. The entry point
now starts the real tray application. A bounded local-console tray trial passed
the basic T28 exit path: the tester toggled Enabled off and on, confirmed the
icon changed blue/gray/blue, and selected Exit. Start with Windows was unavailable
as required in trial mode. Hook removal and process exit were verified, with
no runtime errors or watchdog termination. No paste was attempted in that block.
These earlier trials did not cover execution at login, Explorer restart recovery,
shutdown with pending work, or regression testing of earlier paste results.
The subsequent automated coverage is described above; Explorer restart recovery
and shutdown with pending work remain separate scenarios.
Automated tests cover generation cancellation and preference/command parsing,
plus real registry persistence under an isolated test root. The all-features CI
suite also tests a private native clipboard. They do not exercise the real tray
or interactive Explorer. See [automated validation](AUTOMATED_TESTS.md) for scope,
requirements, and the distinction from desktop integration results.

A subsequent bounded trial of the integrated tray application passed the basic
local T17/T33 image path: one Ctrl+V produced one valid 1140x705 RGBA PNG in the
approved folder. The tester confirmed the screenshot was correct without notices
or sounds. The hook was removed and the process exited with code 0, without
watchdog termination or runtime errors. The observed receipt-to-save time was
222 ms, not a benchmark. This trial used temporary preferences and a restricted
destination; it does not validate unrestricted normal mode,
real preference persistence, or the remaining regression matrix.

A third bounded local trial passed the basic T25 image case: the tester pasted
while disabled with no new PNG, then re-enabled and pasted again to create one
PNG, without notices or sounds. Only one request was queued. The new image was
valid and byte-identical to the previous screenshot; the original was unchanged.
Hook removal and process exit were verified without errors or watchdog use.
This does not cover toggling during in-flight work or persistent preferences.

A 15-second local tray trial passed the basic T26 path for two consecutive
launches in the same interactive session. After the first announced readiness,
the second exited with code 0 within three seconds, without entering the engine's
startup diagnostics. The first remained active and later exited normally,
removing its hook. Both owned processes were confirmed absent; no errors,
watchdog termination, or new files occurred. This does not cover simultaneous
startup or separate sessions. The runner can repeat this check with
`-Tray -CheckSecondInstance` and a duration of at least ten seconds.

Use `Invoke-PasteProbe.ps1 -Tray` for a separately agreed, 30-second maximum
trial restricted to one approved folder. Trial Enabled changes are temporary,
Start with Windows is unavailable, and preferences are never read or written.
CI covers normal-mode persistence and startup registration with the actual app
through native commands; executing it at login still needs separate validation.
Check icon disappearance and owned process exit after every desktop block.
Run the matrix on Windows 10 and Windows 11 and record the OS build and results.

## Preparing real preference trials

For unattended validation, use the [automated suites](AUTOMATED_TESTS.md) first.
The following optional trials specifically exercise the real tray and user
preferences and still require an agreed desktop window.

`scripts/Invoke-PreferencesProbe.ps1` prepares separate, consented normal-mode
checks. Unlike `--trial`, these launch the real application with persistent
preferences and no destination restriction. Do not paste during these checks.
The runner observes only Laqay's Enabled and Run values, backs them up, closes
its owned processes, restores both values, and verifies the restored state.
An initially absent, newly created Laqay preference key is removed only if empty;
the shared Run key is never deleted. Backup/report files belong in a private
output directory. No login or restart of Windows is automated.

Inspecting preferences and compiling the C# window-close helper do not launch
Laqay or write registry preferences:

```powershell
powershell -NoProfile -File ./scripts/Invoke-PreferencesProbe.ps1 -InspectOnly
powershell -NoProfile -File ./scripts/Invoke-PreferencesProbe.ps1 -PrepareOnly
```

Prepare the helper with the same PowerShell runtime as the live test. The helper
cache is keyed by source hash and runtime. Compile it before acquiring any Rust
runtime lease; the live script only loads the resulting assembly.

After agreeing on a block of at most 30 seconds, run one scenario:

```powershell
powershell -NoProfile -File ./scripts/Invoke-PreferencesProbe.ps1 -Scenario Enabled -Seconds 30 -OutputDirectory <private-log-directory>
```

Toggle Enabled once and select Exit. The runner detects the saved DWORD,
relaunches within the original deadline, and leaves time to confirm the persisted
tray state. It then closes the application and restores the initial preferences.
The registry/restart assertions do not replace the tester's visual confirmation.

The separately agreed `-Scenario Startup` block requires an initially absent Run
entry. Turn Start with Windows on, then off. The runner verifies the exact quoted
executable and subsequent deletion, then closes the app and restores settings.
Neither scenario proves actual execution at login. Both application/controller
scenarios are automated with `-Automated` in the isolated CI VM; visual menu
checks and actual login behavior remain separate desktop validations.

| ID | Scenario | Required result |
| --- | --- | --- |
| T01 | Region screenshot | PNG in active folder |
| T02 | Full-screen screenshot | PNG in active folder |
| T03 | PNG with alpha | Exact dimensions and alpha preserved |
| T04 | Regular copied file | Native paste |
| T05 | Multiple copied files | Native paste |
| T06 | Text clipboard | Native behavior |
| T07 | Notepad | Native paste |
| T08 | VS Code | Native paste |
| T09 | Rider | Native paste |
| T10 | Windows Terminal | Native paste |
| T11 | Browser | Native paste |
| T12 | Explorer address bar | Native paste |
| T13 | Explorer search | Native paste |
| T14 | Rename field | Native paste |
| T15 | Multiple Explorer windows | Correct foreground folder |
| T16 | Windows 11 tabs | Active tab or safe rejection |
| T17 | Local directory | PNG created |
| T18 | Writable UNC directory | PNG created |
| T19 | Read-only directory | Safe failure, no incomplete file |
| T20 | Virtual folder | Native behavior |
| T21 | Rapid paste and key repeat | No overwrite or unintended duplicates |
| T22 | Empty clipboard | Native behavior |
| T23 | Locked clipboard | Safe failure |
| T24 | Large image | No UI freeze |
| T25 | Disabled | Native behavior |
| T26 | Second instance | No duplicate hook |
| T27 | Startup preference | Starts on login only when enabled |
| T28 | Tray exit | Clean resource teardown |
| T29 | Tab changes during paste | No write to unintended folder |
| T30 | Clipboard changes during paste | No stale image write |
| T31 | Virtual files with image formats | Native Shell transfer |
| T32 | Disk full or share disconnected | No incomplete output |
| T33 | Empty folder with focused static Text inside its native List | PNG created in that folder |
| T34 | Text inside an editor or outside the native folder List | Native behavior, no image file |
| T35 | Screenshot captured inside an RDP session | PNG created in the remote folder |
| T36 | Client screenshot shared through RDP clipboard | PNG when image data is available; safe rejection otherwise |

For the initial diagnostic, compare reported paths and focus against the real UI
with multiple tabs, address/search fields, rename controls, and virtual folders.
Never use a cached diagnostic snapshot to suppress a later key event.
