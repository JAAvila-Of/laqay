# Windows integration validation

## Acceptance policy

Release acceptance prioritizes core risks: correct Explorer destination and
input ownership, native file/text/virtual-file precedence, clipboard and image
validation, cancellation, collision preservation, failed-write cleanup, recovery
and lifecycle/resource ownership. These requirements remain in force.

Applications provide representative non-interference checks rather than an
exhaustive compatibility list. Existing bounded Notepad, Edge, Terminal and
native Edit/RichEdit results remain useful references. VS Code (T08) and Rider
(T09) are supplementary spot checks, currently unexecuted; neither requires a
dedicated deep automation fixture or independently blocks release. A spot check
compares native paste with Laqay disabled/enabled and checks that image paste
does not create Explorer output. Any observed interference still requires
investigation; supplementary coverage does not waive the core behavior.

The existing 29/33/35-case suites retain every case and assertion. This policy
does not turn absent tests into passes or establish compatibility with every
application, shell profile or version. Windows 10 and Windows 11 platform
coverage and the remaining core-risk matrix stay separate requirements.

The writer regression for generation cancellation between occupied-name
publication attempts exercises the real file writer and Activity generation:
the original file survives, the cancelled operation leaves no staging/output
file, and a new valid request can publish without replacing the original.
This deterministic test is not a desktop focus or clipboard-race acceptance.

## Opt-in Windows 10 provisioning

The lab provisioning script accepts `-GuestProfile Windows10ProEsMx` for a
Windows 10 Pro 22H2 x64 Spanish (Mexico) installation image. The default remains
Windows 11 Enterprise Evaluation in English. Use a new LabId and repeat the
explicit profile on every management command; mixed profiles in one manifest
are rejected. Existing manifests without a profile retain the Windows 11 default.

The opt-in profile selects image index 4 and es-MX in unattended setup. Elevated
provisioning first verifies the supplied ISO hash and inspects that image with
DISM: exact Pro name/edition, AMD64, language and compatible base build are
required before VM or switch creation. Only its own temporary read-only ISO
mount without a drive letter is detached, including on metadata failure;
an already mounted ISO is refused. The installed guest must report build 19045,
Professional edition and es-MX before initialization succeeds. This does not
determine license entitlement or transfer a host key. The opt-in retail Pro
answer file supplies only the public generic Pro edition-selection key in
windowsPE/UserData, with no key in Shell-Setup and no activation call. The
evaluation profile remains key-free.

Pure preparation tests cover both plans, wrong edition/index/architecture/
language/build rejection, unattended image selection and mocked mount ownership
and cleanup. They never mount installation media or create VMs. The first actual Windows
10 attempt stopped in Setup with a ProductKey answer-file error before
installation. The edition-selection key corrects that missing setup input;
the second run reached the desktop and independently reported Pro build 19045,
Professional edition and es-MX. Initialization produced a ready report, but its
Windows profile field was overwritten with a network profile name. That variable
collision is corrected and covered by a regression executing the actual metadata
assignments/publication with inert adapters. Full readiness and controlled closure
acceptance remain pending; the installed guest has not been reinstalled with the
corrected initializer. Existing desktop, network, RDP and lifecycle suites still
require Windows 11; Windows 10 product coverage needs a separate
reviewed adaptation and real execution. Provisioning alone is not acceptance.

## Current automated coverage

### Isolated SMB withdrawal regression

An explicit hosted-Windows CI step creates a uniquely named temporary SMB
share over synthetic data and accesses it only through loopback. Local and
self-hosted execution is rejected before SMB changes. It neither stops the
server service nor changes adapters, firewall rules, credentials or other shares.

The real writer finishes encoding and closes its staging file before an owned
native test signals the controller through a separate local directory. After
observing the SMB connection and complete staging data, the controller removes
only its share and confirms the UNC path is unavailable. Publication must fail
with a native network-path error and leave the original PNG unchanged without
publishing an incomplete PNG. The controller recreates the same owned share;
a fresh request must publish a different valid image after access returns.

An unavailable destination can prevent best-effort staging deletion. The test
records any staging left after reconnection, and controller removal is reported
separately from core cleanup. It does not claim automatic deferred cleanup.
The native process has bounded acknowledgements and owned-process teardown;
cleanup must remove the share and fixture.

The hosted run for PR #30 passed over SMB 3.1.1: both the unavailable-path
probe and publication returned Windows error 67. The original PNG survived and
a new image was published after restoration. One complete staging `.tmp`
remained after reconnection and was removed by the controller. Share and fixture
removal passed without forced termination. This does not establish automatic
core cleanup after disconnection or complete failed-write cleanup acceptance.
This tests share withdrawal,
not packet loss, a physical network outage, Explorer input or Windows 10.

### Isolated storage capacity regression

The explicit hosted-Windows CI storage step creates a unique 64 MiB scratch
VHD and formats only that image as NTFS. The harness refuses local and
self-hosted runners before disk operations, uses an unused R-Z drive letter,
and verifies image/partition/volume identity. Pure preparation tests exercise
its actual guards and command plan without mounting or filling any disk.

An opt-in Rust test validates the hosted-runner environment, owner marker,
volume label, filesystem and small capacity before writing. It fills only the
owned volume with a bounded filler, requires a real Windows disk-full error,
and exercises the real image encoder and file writer. It checks that a failed
write preserves an existing PNG and leaves no staging or final output, then
releases the filler and verifies a new PNG without overwriting the original.
The controller validates native evidence, detaches the image and removes its
owned fixture in a finally block; cleanup failure fails CI. Logs and the JSON
report are retained separately from distributable artifacts.

Normal cargo test runs leave this fixture-dependent test ignored. Only the
explicit CI harness enables it; developer commands do not mount disks or gain
new local tool requirements.

The real-capacity test passed on 2026-11-04 UTC on the hosted windows-2022
runner. Both the bounded filler and the real writer returned Windows error 112
(disk full), with 12,288 bytes free. The original PNG remained unchanged, no
staging or incomplete output remained, and a new PNG passed validation after
the filler was removed. The harness confirmed the NTFS volume mapping, detached
the image and removed the image and owned directory without cleanup errors.
The image was bounded to 64 MiB plus its container metadata. This is a writer
regression, not an Explorer gesture, disconnected-share or Windows 10 acceptance.

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
Run applicable core scenarios on Windows 10 and Windows 11 and record the OS
build and results. Application spot checks follow the representative policy
above; record unexecuted references explicitly.

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
| T08 | VS Code (supplementary spot check) | Native paste |
| T09 | Rider (supplementary spot check) | Native paste |
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
`EdgeRealImageDoesNotWrite`) for 33 total. A Windows 11 guest run passed all
33 cases with independent verification; the final acceptance follows the
earlier failed attempts recorded below.
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

The ninth attempt passed 26 cases, including all four real-application cases
with normal application/worker closure and empty Jobs. Notepad's original
`LocalState` fingerprint was restored. Administrative Edge policy restoration
verified the original values/types and removed its created key. The suite then
failed before the tab switch because the delayed provider received no render
request. Its positive PNG reference passed, but the initial race input state
was not retained, so this result does not establish an input or product cause.
Final recovery restored the guest and stopped both VMs.
The initial race input now records native/semantic focus, formats, modifiers,
Shell path, fresh provider state and A/B/C file counts even if the request wait
fails. It must establish a fresh, stable provider and a ready source folder
before its single Ctrl+V. No extra input, stabilization delay or longer request
wait is added. All 33 cases remain mandatory.

### Real-application extension: 33 cases verified

On November 4, 2026, an opt-in guest cycle passed all 33 cases with the
published v0.1.1 executable, two normal boots and no recovery boot. Microsoft
Notepad 11.2312.18.0 and Edge 152.0.4191.66 received exact clipboard text with
Laqay disabled and enabled. Notepad saved the exact document, and both image
cases preserved previous files with exactly one later Explorer recovery PNG.
Both applications exited normally with code zero, empty owned Jobs, stopped
automation workers and removed fixtures/profiles. The original Notepad
`LocalState` fingerprint was restored; the administrative controller verified
the original Edge policy values/types and removed its temporary key.

The tab race established the initial input and fresh provider, retained the
same clipboard owner/sequence across the tab change, completed through the
same-clipboard fence and recovered with a new image. Native thread contexts
confirmed the consumer's clipboard read; WCT did not confirm that wait. The
twelve serial pastes each produced exactly one new image. Independent report
checks confirmed the required case set, sources, contexts, executable/script
hashes, real Jobs, resource admission, baseline/logon restoration, both guests
off and no remaining owned helpers. The shared host Rust coordinator was
unchanged and its queue was not used by the private VM-only controller.

This is one bounded acceptance of these application versions and the pinned
executable. Earlier failures remain failures; the successful repetition does
not establish their cause or prove long-term stability. It does not complete
the other applications, clipboard/publication races, storage failures,
Windows 10 or sustained-load matrix.

### Optional Windows Terminal reference: 35-case acceptance

Adding -IncludeWindowsTerminal to -AdverseOnly -IncludeRealApplications
selects 35 cases, including TerminalRealText and TerminalRealImageDoesNotWrite.
The default 29 cases and the existing 33-case selection keep their prerequisites
and commands. The full opt-in suite passed on 2026-11-04 UTC using lab source
09e53aa and the pinned published v0.1.1 executable. Compilation and planning
alone do not prove compatibility.

The helper revalidates the registered Microsoft Terminal package and executable,
requires a new owned window/process and pre-resume Job containment, and refuses
an existing Terminal session before isolating its guest-user LocalState.
The reference settings explicitly bind Terminal's native paste action to
Ctrl+V. Terminal 1.18's default action bindings instead include Ctrl+Shift+V
and Shift+Insert; shells can also handle Ctrl+V themselves. This fixture tests
Terminal's native action with an explicit isolated binding, not every shell
or default user profile.

A PowerShell -NoProfile console receiver inside the owned Terminal reads two
lines with Console.ReadLine, storing pasted content as data without evaluating
commands. The test sends actual Ctrl+V, observes Terminal's TermControl text
pattern, and submits each line to that receiver. Independent receipts must
match the run, receiver PID/session, contained executable and script hash,
with exact text while Laqay is disabled/enabled. A later Explorer output fences
the image reference as in the other app cases. A stop marker requests normal
receiver exit; acceptance requires zero exit codes, empty Jobs, worker shutdown,
removed fixtures and the original Terminal LocalState fingerprint restored.
Other package settings are outside this rollback; if first use creates the
package data container, the test does not claim to remove that whole container.

The first 35-case attempt stopped after 17 passing cases: Terminal rejected an
existing session before isolating LocalState. Restoration completed, both VMs
were off and owned controller Jobs were empty. This attempt did not validate
Terminal. The opt-in task now explicitly hosts the driver in headless conhost
with handoff disabled, keeping console delegation separate from the application
under test. Any remaining prior Terminal process still fails the test, with
process identity diagnostics; it is never adopted or terminated by this guard.
The second attempt passed eight cases before ActiveTabSelection failed to
navigate its new Explorer tab. Terminal cases were not reached. Recovery
restored the baseline and temporary logon, shut down both VMs and left no owned
controller processes. This does not validate the console-delegation change.
Navigation now records focus, clipboard metadata, observed address text,
selected tab and Shell folder paths, including on failure. It requires the
exact pasted address before submitting Enter, without retrying input or
skipping cases.

The third attempt passed 15 cases, including tabs and both Notepad references,
before report publication failed with a sharing violation in Save-Report.
Terminal was not reached. Recovery restored the baseline and temporary logon,
both VMs were off and no owned controller processes remained. The exact reader
that held the original file was not identified.

The guest report and Terminal receiver now publish complete temporary snapshots
by atomic replacement, retrying only sharing/lock violations for at most two
seconds. Other errors and persistent locks still fail. Windows PowerShell uses
an explicit null string for the absent backup path. Inert preparation tests
exercise both actual publisher functions: Unicode, an old reader retaining a
complete snapshot, a persistent incompatible reader, unchanged prior output on
failure, recovery after reader release and refusal to overwrite a temporary
publication file.

The fourth attempt passed 17 cases and launched the registered Terminal with
its tagged window and TermControl text target. Binding the PowerShell receiver
then failed the combined session/start/image/Job check before any reference
input was sent. Terminal exited normally and its LocalState fingerprint was
restored; recovery restored the baseline and temporary logon, both VMs were off
and no owned controller processes remained. The receiver check now reports each
observed value and retains the initial receiver receipt before binding, with
protocol identity validated first. Every ownership requirement still applies.
That attempt did not establish which condition failed; the next attempt
collected the individual native Job result.

The fifth attempt isolated that failure: the receiver's session, executable and
start time matched, and the native Job query succeeded, but it was outside the
frontend Job. The attempt stopped after 17 passing cases and completed recovery
with both VMs off and no owned controller processes. This establishes the
failed condition without identifying Windows' internal launch mechanism.

The controller now creates a unique dedicated receiver Job with kill-on-close
before launching Terminal. After validating its disposable guest context, the
receiver assigns itself to that existing Job and verifies membership before
publishing Ready. The controller independently checks that same Job before
reference input; the frontend retains its original pre-resume containment.
Both Jobs must become empty before normal cleanup, and receiver Job closure is
checked. No unrelated process is adopted.

Preparation exercises the actual enrollment code and controller Job operations
in owned hidden .NET children: missing Job rejection, name collision rejection,
verified membership, normal exit accounting and kill-on-close. These tests use
no desktop input, clipboard or VM.

The complete **35-case suite passed on 2026-11-04 UTC** in two normal guest
boots, including all twelve serial pastes. Independent report and isolation
validators confirmed the registered Terminal package 1.18.10301.0 (file version
1.18.2401.30001), both exact receiver inputs with Laqay disabled/enabled,
image exclusion with the later Explorer fence, and the dedicated receiver Job
before readiness. Terminal and the receiver exited normally with code 0;
both Jobs were empty before closing, the receiver Job closed, automation stopped
and owned fixtures were removed. Terminal LocalState was restored to its
original fingerprint. Notepad and Edge also exited normally with their state
and temporary policies restored. The original Laqay baseline and temporary
logon were restored, both VMs were off and no owned controllers remained.
The shared host Rust coordinator was unchanged and its queue was not used.

This acceptance uses the published v0.1.1 executable SHA-256
3e73ff0b35661c23064101049f481dadeceb41bc31db21a0dcba7ec1aaf9632f.
It covers these installed application versions and the explicit Terminal
Ctrl+V profile, not default shell bindings, arbitrary profiles, every real
application, Windows 10 or sustained load. Earlier failures remain failures.
