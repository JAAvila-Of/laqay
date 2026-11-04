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

The paired-guest RDP suite passed all seventeen cases: the thirteen regressions
in an authenticated protocol-2 session, a remote-created image pasted through
client Ctrl+V, an exact client image delivered through the real clipboard
channel, native file priority, and redirected text in Explorer search. The
controller independently verified the server session and connection owned by
the exact native client process. The explicit CF_DIBV5 fixture passed native
readback in Primary and Peer, and the resulting PNG preserved all six colors.
Both application and client exited normally with code 0, without forced task
stops. Preferences, permissions, credentials, temporary configuration, and
guest shutdown were checked. This covers one Windows 11 Enterprise evaluation
setup (the guests reported zero evaluation grace remaining), not Windows 10,
arbitrary RDP clients, reconnects, or policy-restricted clipboard scenarios.

The separate Primary console lifecycle suite passed its thirteen regressions
plus Explorer restart recovery and exit with a blocked clipboard read. The
shell PID changed while Laqay kept its PID, restored its registered notification
icon, and saved another exact PNG. Two native control-register samples identified
the same application thread in the system clipboard-read stub while the delayed
provider remained owner with unchanged sequence and withheld data. Laqay exited
0 without force in 1,016 ms in that run; the provider then stopped, no output or
staging file remained, preferences/permissions were restored, and both guests
were off. This is bounded validation of the blocked-read case, not a shutdown
benchmark or coverage of actual Windows shutdown and every encoding/write stage.

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
The subsequent automated coverage is described above, including Explorer restart
and application close with a blocked clipboard read. Actual Windows shutdown
and the remaining encoding/write stages still require separate validation.
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

The [published portable cycle](DESKTOP_TEST_LAB.md#published-portable-package-cycle)
adds a separate release-package gate: v0.1.0 to v0.1.1 replacement at the same
path, persistence of Disabled, exact image paste after re-enabling, real login
startup enabled/disabled, and removal followed by a clean login observation.
Preparation is automated in CI. The published-package cycle passed all 37
assertions on 2026-11-03 in an explicitly authorized isolated Windows 11
Enterprise evaluation console, with five guest boots, normal application exits,
restored baseline/preferences/logon configuration, both guests off and owned
helper/coordinator processes exited. This is a scoped package-cycle result;
it does not complete every scenario in the desktop integration matrix.

The separate [27-case adverse suite](DESKTOP_TEST_LAB.md#additional-console-adverse-checks)
passed on 2026-11-03 using published v0.1.1 in the isolated Windows 11 Enterprise
evaluation console. It completed two guest boots, normal application exit,
baseline/preferences/logon restoration, both guests off and owned-process exit.
Native Edit/RichEdit text passed with Laqay disabled and enabled, with confirmed
child focus outside menu/move mode. The fixture activates its own form without
synthetic Alt; earlier failed attempts remain failures. These helper controls
do not establish compatibility with the real applications listed above, and
the bounded resource samples do not establish sustained-load or leak results.

The serial fixture now keeps the initial Explorer Items View focus for all
twelve Ctrl+V inputs instead of reactivating and clicking the folder between
inputs. Each step records its index, native foreground/focus/menu state,
clipboard sequence, publication result and observed PNG count, including on
failure. The host requires all twelve observations and the existing exact
image/content checks; the wait limit and number of inputs are unchanged.
The revised fixture passed all 27 cases on 2026-11-03 with published v0.1.1,
including twelve successful serial observations, two guest boots, normal
application exit and complete baseline/preferences/logon restoration. Both
guests were off and owned helper processes had exited after the run. Earlier
timeouts remain recorded failures; this pass does not establish their cause.
The shared image-paste helper also records input state before activation,
before Ctrl+V and after its publication wait. Structural UI Automation focus,
modifier state and native clipboard-format availability aid diagnosis without
reading control text. A failed paste additionally retains clipboard fixture
diagnostics; it remains a failure and is not retried automatically. The inert
preparation gate exercises the actual serial invocation expressions with a
Shell-shaped object, requiring native-handle binding before the unarmed guard.

The next adverse revision adds `RenderedPngReferencePaste` and
`TabSwitchCancelsPendingImage` (29 cases total). Both passed with the complete
29-case suite on 2026-11-04 UTC using published v0.1.1. A valid magenta PNG first proves the delayed-render source can publish
with stable focus. The race then prepares three tabs before publishing that
source, requires independent native evidence of Laqay waiting for its provider,
and switches from A to B before releasing bytes. The provider records ownership,
sequence and release/render state on both sides of the switch.
The source also publishes a materialized metadata marker before advertising its
delayed PNG. It records the actual sequence after closing that initial
publication. This does not assume sequence stability: the reference and every
race stage must confirm it, since Windows can defer sequence changes until
[rendering occurs](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getclipboardsequencenumber).

A later paste into C uses the same clipboard without republishing or clearing
it. For the pinned v0.1.1 single FIFO paste worker, C's exact PNG is a completion
fence for the earlier request. A and B must then contain no files, including
staging files. After retiring the provider, a fresh, visually distinct image
must paste correctly into B. This avoids treating a quiet-time delay or missing
source bytes as cancellation evidence. The fence must be revised if the worker
becomes concurrent. The rendering handler follows
[WM_RENDERFORMAT](https://learn.microsoft.com/en-us/windows/win32/dataxchg/wm-renderformat):
it supplies its memory handle without opening the consumer's clipboard lock.
The existing exit-with-pending-work provider retains its cancel-only behavior.

The new held-read cases run before the editor regressions so their evidence is
retained even if a later case fails; all 29 cases remain required. The first
expanded run stopped in `NativeEditNativeText` with Laqay disabled, before the
held-read cases were reached. Its alternate sender-thread diagnostic succeeded,
but the original run remains failed and does not establish a cause.
Editor text sources now publish materialized `CF_UNICODETEXT` memory with exact
native readback, hash, length, owner and pre-input sequence evidence. This
removes a possible OLE/STA source dependency while retaining the original
SendInput caller and disabled/enabled text assertions. The revised fixture
passed all four NativeEdit/RichEdit disabled/enabled references in that run,
with native source evidence and no diagnostic sender substitution.
Native thread-context samples confirmed the held clipboard read; Windows wait
chain traversal did not confirm it. Source ownership and sequence remained
stable through rendering and the later completion-fence paste. The run used
two guest boots, normal application exit, full baseline/preferences/logon
restoration, both guests off and no remaining owned helper processes.
This covers a tab change during clipboard reading, not every encoding or
publication race in T29–T30 or the real-application compatibility matrix.

The optional `-AdverseOnly -IncludeRealApplications` cycle adds four cases
(`NotepadRealText`, `NotepadRealImageDoesNotWrite`, `EdgeRealText`, and
`EdgeRealImageDoesNotWrite`) for 33 total. Its guest runtime result is pending.
The default adverse suite remains 29 cases, and Cargo/CI commands do not require
these applications. The extension requires registered Microsoft Notepad and an
installed Edge executable in the guest; it fails when a prerequisite is missing.

Notepad opens an owned temporary text file through the Windows launcher and
must expose the registered runtime package identity and executable path. It
uses the disposable guest user's application settings. Edge opens a local HTML
textarea with a new run-specific profile and accessibility enabled, without a
browser extension or a debugging connection. A configured
[UserDataDir policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/userdatadir)
is rejected before Edge starts, since it can override the profile flag. The
helper rejects an existing Notepad session and does not use host profiles.

Each app must receive exact native clipboard text with Laqay disabled and
enabled; Notepad must also save the exact owned document before normal closure.
An image paste in the real editor is followed by a same-clipboard Explorer
paste as a completion fence for the pinned FIFO worker. All previous files
under the Explorer fixtures must retain their hashes, with exactly one new PNG
in the recovery folder and no extra staging files. The launcher enters a Job
before resume; any separately activated Notepad process must be independently
identified and contained before input. Cleanup requires normal application
exit, empty owned Jobs and removal of the run-specific files/profile. Forced
cleanup remains a failure. Only the disposable guest's Notepad `LocalState` is
isolated and restored; this does not claim a rollback of all package settings
or compatibility with other application versions.

In the opt-in mode, the four real-application cases run immediately after the
thirteen basic Explorer cases, before the remaining adverse regressions. All
33 are still required. The first expanded attempt stopped after 22 cases at
the later same-clipboard completion paste, before reaching either application;
it remains a failed attempt with restoration complete. The fence now records
native/semantic focus, modifier state, PNG availability, Shell folder path,
application responsiveness and A/B/C file counts even on failure. The single
Ctrl+V and its publication wait are unchanged; an input-context prerequisite
failure cannot count as a successful cancellation.

The second expanded attempt passed the thirteen basic cases, then failed to
identify the tagged Notepad window before any real-application paste. Its
fixture directory was still in use during cleanup; final recovery restored the
baseline and logon settings, stopped both guests and left no owned helpers.
Window matching now uses the unique filename stem while retaining executable,
package, session and process-start checks. Bounded diagnostics include windows
of the expected executable even when their titles do not match. The launcher
uses the parent run directory as its working directory, and fixture cleanup
errors are retained alongside the original test failure. A fresh 33-case pass
is still required.

The third attempt identified the expected Notepad executable, runtime package
and tagged window, then failed with `E_UNEXPECTED` during UI Automation before
any real-application paste. Notepad exited normally and its fixture was removed;
final recovery restored the baseline/logon settings and stopped both guests.
Real-application UI Automation now runs on a dedicated persistent MTA thread,
separate from the helper's STA Shell/clipboard work, following Microsoft's
[threading guidance](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading).
Automation elements remain on that thread; callers receive plain values.
Calls have a ten-second bound, diagnostics retain the stage and full exception,
and acceptance requires the automation thread to stop during cleanup. Native
clipboard publication and SendInput remain on their original helper thread.
This design correction does not establish the cause of the earlier COM error;
the 33-case guest result remains pending.

A fourth attempt reproduced the error on the dedicated MTA worker. Its full
stack identifies the managed `FindAll` call while looking for Notepad tabs;
moving that call to MTA alone did not resolve it. Application and worker cleanup
were normal, and final recovery restored the guest with both VMs off.
The next diagnostic probes the same verified application window through native
`IUIAutomation`, on the same MTA worker, before the managed editor lookup.
It reads only that window's subtree, records root PID, element count, bounded
editor/tab metadata and full errors, and releases its COM references on the
worker. It sends no input and cannot substitute for any of the 33 required
cases. This comparison is intended to distinguish client paths before changing
the editor automation; it is not compatibility evidence.

The fifth attempt completed the native probe (33 elements, including the
Notepad editor). The following managed lookup also succeeded, but correctly
rejected four restored tabs before any paste. This does not establish why the
earlier COM failure disappeared. Application/worker cleanup and final recovery
were normal. The next run temporarily moves the disposable guest's Notepad
`LocalState` into its owned fixture before launch, preserving the original
directory/file fingerprint and a recovery journal. It retains the single-tab
requirement. After the contained app closes, it removes only the generated
state and restores the original, requiring the same fingerprint. Reparse
points, unexpected profile paths or a changed backup are rejected. Failed
restoration retains the backup and fails acceptance; it cannot count as a
successful cleanup. Package settings outside `LocalState` are not reset.

The sixth attempt passed all four real-application paste cases (17 cases in
total). Both applications received exact text with Laqay disabled/enabled and
the image/recovery checks preserved previous files. Notepad saved its document,
exited normally and restored the original `LocalState` fingerprint. Edge's main
process exited with code zero, but six processes remained in its owned Job
after the six-second grace period. Closing the Job forced their cleanup, so
the suite failed before the remaining regressions; this is not a 33-case pass.
Final recovery restored the guest and left both VMs off with no owned helpers.

Before another attempt, the helper releases its managed automation references
and configures temporary guest-user `StartupBoostEnabled=0` and
`BackgroundModeEnabled=0` policies. See Microsoft's
[startup boost](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/startupboostenabled)
and [background mode](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/backgroundmodeenabled)
documentation. It rejects conflicting mandatory machine policy, journals
the original user values/types and newly created
keys, and requires their restoration. Pending Job process IDs/names/images
are captured before forced cleanup if needed. This does not establish the
cause of the six remaining processes. The shutdown grace period is unchanged,
and forced cleanup remains a failure.

The seventh attempt passed fifteen cases, including both Notepad cases, then
stopped before launching Edge because the initial policy precondition rejected
an existing Edge process. It did not test the revised Edge shutdown. Final
recovery restored the guest and left no owned helpers. The helper now records
pre-existing guest-session Edge process IDs/images and visible-window handles,
without sending them input, closing them or adopting them. The test must create
a new process outside that inventory, with the owned profile, unique window
tag and pre-resume Job containment. Temporary background policies apply to
the whole disposable guest user and are restored; they never affect the host.
This permits independent Edge instances while retaining input and cleanup
ownership checks. A full 33-case pass is still pending.

The eighth attempt passed fifteen cases, then the limited interactive helper
was denied write access to the Edge policy key before launching the browser.
No policy value writes were reached. The attempt remains failed; final recovery
restored the guest and stopped both VMs with no owned helpers.
Policy preparation/restoration now belongs to the existing administrative
PowerShell Direct session inside Primary. Its literal scoped block checks the
guest marker, VM hardware, exact run path, administrative token and the
`LaqayLab` user SID before accessing that user's policy hive. It journals
original values/types and created keys before mutation and verifies restoration
in the controller's `finally`, after task cleanup and before report collection.
The interactive helper only reads the prepared policies; its token, Laqay's
token and registry ACLs remain unchanged. Acceptance requires both the guest
readback and the separate administrative restoration result. Invalid scope
arguments are rejected locally before any registry operations.
