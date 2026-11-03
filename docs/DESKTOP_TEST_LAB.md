# Disposable Windows desktop lab

The lab prepares a real Windows desktop for the remaining
[integration scenarios](integration-tests.md). It is separate from component CI
and never marks a scenario as passed merely because a VM was created or booted.
The scripts do not control the host desktop or use its clipboard.

## Prerequisites and boundaries

Use an already enabled Hyper-V host and an explicitly authorized administrator
process. The scripts never elevate themselves, install Windows features, restart
the host, change physical adapters, or enable clipboard sharing. Each guest has
two virtual CPUs, 4 GiB fixed RAM, a dynamic 64 GiB system disk, Secure Boot, and
a local virtual TPM. Starting a guest requires at least 7 GiB currently available
host RAM and 40 GiB free disk space. These admission checks cannot guarantee
unchanged host performance while other applications allocate resources.

Only one guest may run at a time through this initial controller. Two-guest RDP
tests require a separately reviewed memory budget and controller extension.
The owned private switch joins guests only: there is no host virtual adapter,
NAT, gateway, Internet access, or exposure to the physical LAN. UNC and RDP are
enabled inside the guest only for the private `10.77.166.0/24` subnet. OneDrive,
online activation, and redirected RDP clipboard scenarios need additional setup;
they are not covered by an offline guest.

Obtain a Windows 11 Enterprise Evaluation ISO from the
[Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise).
Observe the evaluation terms and expiry; evaluation media is not a perpetual
Windows license. Keep the source URL, exact image size, and calculated SHA-256 in
private evidence, and compare against [Microsoft's published digest](https://aka.ms/VerifyWindowsISO).
A locally calculated hash alone records identity, not independent verification
against a publisher-provided digest. Do not substitute a Server,
LTSC, or different Windows version and report it as ordinary Windows 10/11.

## Plan and provision

All state belongs under `%LOCALAPPDATA%\LaqayTestLab\<32-lowercase-hex-lab-id>`.
The `media` directory contains the Windows ISO and an application ZIP from a
validated Laqay CI run. Nothing in this directory belongs in Git. Provisioning
restricts the runtime root to its user, SYSTEM, and Administrators.

```powershell
$labId = [guid]::NewGuid().ToString('N')
./scripts/lab/Invoke-DesktopTestLab.ps1 -Action Plan -LabId $labId
```

Plan writes nothing and needs no administrator privileges. After reviewing the
plan and placing the media in that root, use an authorized administrator process:

```powershell
./scripts/lab/Invoke-DesktopTestLab.ps1 -Action Provision -LabId $labId `
    -WindowsIso <private-iso-path> -IsoSha256 <expected-sha256> `
    -ApplicationArchive <private-validated-zip-path>
./scripts/lab/Invoke-DesktopTestLab.ps1 -Action Start -LabId $labId
./scripts/lab/Invoke-DesktopTestLab.ps1 -Action Status -LabId $labId
```

Provision creates an off VM. Start accepts only the single, newly created lab
VHDX; unattended Setup wipes **guest disk 0**. A first-boot Space key is sent
through Hyper-V's virtual keyboard for that owned VM ID, never through host
input. The installation flag is recorded before starting; later starts do not
send another DVD boot key. Once Status verifies the ready marker through
PowerShell Direct, it ejects both DVDs and sets the system disk first in boot
order so later login tests cannot reinstall Windows.

The seed ISO carries a generated temporary local password and unattended answer
file. The credential retained for PowerShell Direct is protected with user-scoped
DPAPI. The restricted runtime root and seed media remain private and must be
deleted with the lab. First-logon initialization uses RemoteSigned for its guest
PowerShell process; it does not change the host's execution policy, disable UAC,
or disable security software. The guest automatically logs into its temporary
lab account with `LogonCount=3`. Windows documents an
[off-by-one behavior](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon-logoncount)
for this setting; do not treat it as an exact logon limit. No personal Microsoft
account is copied.

Status returns `TestsExecuted: false`; `Guest.Ready` means guest initialization
finished, not that the Explorer matrix passed. The executable is unpacked in
`C:\LaqayLab\App` but is not automatically started. Desktop automation must run
inside the guest's interactive session, with the matching lab marker. PowerShell
Direct itself does not prove an interactive desktop or keyboard gesture.

## Teardown

```powershell
./scripts/lab/Invoke-DesktopTestLab.ps1 -Action Stop -LabId $labId
./scripts/lab/Invoke-DesktopTestLab.ps1 -Action Remove -LabId $labId
```

Stop requests guest shutdown. Remove requires off guests, validates VM IDs and
ownership notes, verifies every attached disk lies in the owned runtime root,
rejects reparse points and malformed manifests, and preserves a switch if an
unowned VM uses it. Only then does it remove the owned VMs, private switch, and
exact lab directory, including downloaded media and credentials. Retain needed
test evidence in a separate private location before teardown. Existing unrelated
VMs and switches are never adopted by name.

Preparation checks run with `scripts/lab/Test-LabPreparation.ps1`. They validate
planning, invalid ownership/path rejection, unattended XML, and creation of a
small seed ISO without creating, booting, or removing any VM. Actual provisioning,
installation, shutdown, and teardown still require validation on a suitable host.

## Explorer smoke suite

`Invoke-DesktopSmoke.ps1` transports a bounded suite into an already running,
owned primary guest through PowerShell Direct. It requires the host's shared
RustWork runtime lease (`--family rust`); VM start/shutdown remain separate
phases. Supply a fresh run ID, the expected executable SHA-256, and a private
output directory. The controller never elevates itself.

The suite runs as the guest's logged-on `LaqayLab` user through an
Interactive/Limited scheduled task. A guard checks lab identity, Windows 11
Enterprise on a Microsoft virtual machine, a nonzero session, a non-elevated
token, STA, and an unlocked Default input desktop before enabling controls.
The helper does not operate the host clipboard or foreground window. Compile-only
checks explicitly reject unarmed controls and invalid/unowned lab identities.

Thirteen required cases exercise real Ctrl+V through guest SendInput and inspect
observable results: exact 2x2 image colors/dimensions, preserving existing images,
multiple-file paste with simultaneous bitmap data, text-plus-image clipboard
exclusion in address/search/rename fields, disabled/re-enabled behavior, and
active-tab selection in both directions within one Explorer window. Four further
cases cover spaces and Unicode in destination paths, clipboard sequence and pixel
preservation, A/B/A selection across distinct windows, and recovery from denied
file creation. Enabled uses
the normal application's owned menu command handler. Preferences are restored.
The application runs with normal permissions in an owned KillOnJobClose process
job. The suite has a five-minute input deadline, a seven-minute guest task limit,
and an eight-minute host deadline. It closes its Explorer windows and application;
the controller removes the task and retains reports, logs, and synthetic output.
The calling host operation must shut down the owned guest in its final cleanup.

Successful transport, a started task, or a partial report cannot pass: the host
requires every named case, clean application shutdown, restored preferences,
restored fixture permissions, no forced termination, no cleanup errors, and task
result zero. The denied-write case applies a non-inherited `CreateFiles` deny
rule only to its newly created guest fixture folder for the current guest user.
It verifies that file creation actually fails, checks that paste leaves no output
or temporary files, and restores and compares the original access descriptor in
`finally`. A subsequent paste into that same folder must produce a valid PNG.
The clipboard case renders and validates the fixture before recording its
[clipboard sequence](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getclipboardsequencenumber)
so initial delayed rendering is not confused with a paste-time mutation.
See the documented
[file access rights](https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.filesystemrights)
for the fixture's permission boundary. These smoke
cases do not cover audio, every notification, other applications, rapid tab or
clipboard races, UNC failures, OneDrive, RDP, or actual Windows login startup.
Record completed scenarios and OS builds without expanding their scope.

## Real login startup cycle

`Invoke-StartupCycle.ps1` validates startup across actual boots and logons of the
owned primary guest. It requires that guest to start off, an explicitly authorized
administrator process, private output storage, the expected application SHA-256,
and explicit Python/RustWork paths. It never elevates itself or restarts, signs
out, locks, or sends input to the host.

The cycle boots the guest to configure its temporary local lab account for three
automatic logons, then reboots that guest to establish the initial test session.
Only the guest Winlogon configuration receives the temporary lab credential;
it is never printed, passed on a command line, or included in reports.

1. Enable startup through the normal tray application's command handler. Require
   the exact quoted executable in its own HKCU Run value and a clean app exit.
   Existing startup registrations are refused, not replaced. Snapshot Enabled.
2. Shut down and boot the guest. The verifier never starts the application:
   it waits for Windows, then checks the single process's executable, start time
   after this boot, session, user, and non-elevated token before adopting it into
   an owned KillOnJobClose job. Require actual Ctrl+V in Explorer to produce the
   correct synthetic PNG. Disable startup through that same application and exit.
3. Shut down and boot the guest again. Require its Run value to remain absent
   and observe no Laqay process for 180 seconds in the interactive guest session.
   Restore Enabled and verify the original preference and absence of Run.
4. Run all thirteen Explorer regression cases through the default transport in
   that same guest session, then restore its preferences again.

Each runtime phase gets its own RustWork lease and unique interactive task.
The enabled/disabled verification boots occur inside their runtime leases:
Windows may launch the Rust application before the interactive verifier starts.
Setup boots, shutdown, and guest logon configuration stay outside those leases. The
existing desktop guard and five/seven/eight-minute input/task/host deadlines
apply. Reports include boot/start times, PID, session, parent PID, exact named
cases, exit status, restoration, and the observation duration. A changed boot
time is required between phases; re-running a task in the same boot cannot pass.

Windows [does not guarantee prompt execution of Run entries](https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys).
The enabled wait and disabled observation are each bounded at 180 seconds;
failure to start within that interval fails this test, and an absent process
only proves absence during the recorded interval. This does not cover startup
disabled externally in Task Manager, arbitrary policies, or every Windows build.

On failure, the cycle attempts a separate guest cleanup task. Final cleanup
disables the guest's temporary auto-logon, deletes its Winlogon password/count
values, and shuts down only the owned VM. The report cannot pass without app
settings restored, auto-logon disabled, tasks removed, normal application exits,
and the VM confirmed off. The lab credential remains in its protected temporary
provisioning storage until teardown. Future cycles explicitly re-arm guest logon.

## Paired private guests

Single-guest operation remains the default. After explicitly agreeing on a
two-guest resource budget, start the owned Primary and Peer guests with
`-MaximumRunningGuests 2`. Both roles must be present with distinct manifest IDs,
matching ownership, fixed 4 GiB RAM, two CPUs, one owned disk, and one adapter on
the same owned private switch. Foreign attachments to that switch are refused.
No host adapter, NAT, external switch, or physical LAN connection is added.

The admission check reserves capacity for the remaining guests plus 3 GiB for
the host: at least 11 GiB currently free before the first paired start and 7 GiB
before the second. Every start also requires 40 GiB free disk. Exact boundaries,
insufficient reserves, and concurrency limits are tested without creating VMs.
Provision/install a new Peer separately first; do not run two installers together.

The initializer grants the temporary guest account NTFS Modify on its own share
directory, in addition to its existing SMB share permission, and configures the
guest Remote Desktop service for automatic startup. It does not change SMB signing, guest authentication,
NLA, or host security settings. Each guest has its own generated credential.

An unidentified guest network can use the Public profile after a reboot. The
lab's two inbound rules therefore apply across guest profiles, while requiring
the single lab interface, the exact role IP (10.77.166.10 or 10.77.166.11), and
source 10.77.166.0/24. No machine-wide network category policy is changed.
`Set-GuestLabFirewall.ps1` can create or migrate only those owned rules from its
fixed `C:\LaqayLab` location after checking the marker, virtual machine, OS,
administrator token, sole adapter, expected address, and absence of a default
IPv4 route. Unexpected existing rules are refused. New seeds include this helper;
existing guests need it copied and invoked through their guarded admin session.

With both owned guests already running, `Test-PrivateLabNetwork.ps1` checks their
markers, addresses, absence of an IPv4 default route, and private attachments.
It probes Primary-to-Peer TCP 445/3389 and Peer-to-Primary TCP 445, then transfers
four synthetic bytes over authenticated, signed SMB using only the Peer account.
The bytes are read back and hashes compared from both guests. The temporary
session drive and exact newly allocated fixture are removed; unexpected remaining
content prevents directory deletion. Reports belong in private output storage.

This preparation script does not boot or stop guests, launch Laqay, manipulate
desktops/clipboards, or test Explorer paste or an RDP logon. A calling operation
must stop both guests in its final cleanup. TCP connectivity and an SMB round trip
are prerequisites, not evidence that the corresponding paste scenarios pass.

## Explorer paste over UNC

`Invoke-DesktopSmoke.ps1 -IncludeUnc` adds three real Explorer cases to the
thirteen local cases. Both owned guests must already be running, and Primary
must have an unlocked interactive LaqayLab logon. Run this transport through
RustWork with `--family rust`, as for the local suite. A calling operation must
explicitly establish the temporary guest logon, enforce paired resource limits,
remove temporary auto-logon credentials, and stop both guests in final cleanup.
The transport itself never elevates, boots, logs on, or shuts down a guest.

The limited Primary task authenticates directly to `\\10.77.166.11\LaqayLab`
using the distinct Peer credential. The host sends it only through PowerShell
Direct; it is exported with guest-user DPAPI protection in the owned run folder,
imported by the same user, and deleted before result collection. Passwords are
never command-line arguments or report fields. The native helper creates only
this fixed, temporary, deviceless connection using
[WNetAddConnection2](https://learn.microsoft.com/en-us/windows/win32/api/winnetwk/nf-winnetwk-wnetaddconnection2w).
The administrative transport refuses existing peer connections before starting
the interactive task. Once Explorer opens the UNC folder, a bounded handshake
lets that transport verify the actual connection's signed state, local user,
and distinct peer credential. The limited task does not call administrative SMB
cmdlets, and neither Explorer nor Laqay is elevated. Cleanup disconnects
only the connection it created, without forcing open handles closed.

The host reserves a new `Paste-<RunId>` directory on Peer. Explorer opens its
actual UNC subdirectories, and synthesized Ctrl+V checks:

- `UncImagePaste`: a PNG with the fixture's dimensions and pixels, an unchanged
  clipboard, and an authenticated signed SMB connection.
- `UncExistingImagePreserved`: a second correct PNG without changing the first
  file or leaving temporary output. This does not force a timestamp collision.
- `UncNativeFilePaste`: the native file is copied intact when the clipboard also
  contains a bitmap, with no extra PNG.

Peer independently reads the resulting two PNGs and one binary file and checks
their SHA-256 against the interactive client's hashes. Cleanup removes only the
reserved fixture and its expected files, rejects reparse points or unexpected
content, removes the task and credential file, and requires normal application
exit. A partial case list, server mismatch, or cleanup error fails the run.
This covers a healthy authenticated UNC share; it does not simulate network loss,
server restart, offline files, OneDrive, or an RDP logon/clipboard transfer.

## Isolated RDP and clipboard validation

`Invoke-RdpSmoke.ps1` runs the native Windows `mstsc.exe` client in Primary's
limited console session and the application suite in Peer's limited RDP session.
Both owned guests must already be running on the private switch. Invoke the
transport through RustWork with `--family rust`. It does not elevate itself,
boot guests, change trust, or configure automatic logon. A calling operation
must prepare the guest session, restore temporary configuration, and stop both
guests in final cleanup. This suite is prepared; type checks and compilation
alone do not constitute a successful RDP run.

Before the runtime phase, `Set-RdpLabTrust.ps1 -Action ExportPeer` reads Peer's
existing public Remote Desktop certificate and requires its existing NLA/TLS
configuration. It does not export a private key or change the listener.
`-Action PreparePrimary` temporarily trusts exactly that certificate in Primary's
machine root store and adds the single peer name/address to Primary's hosts
file. The owned state records original bytes/hash, prepared hash, and whether
trust was added. An existing name mapping, reparse point, ambiguous certificate,
or unexpected listener certificate is refused. Run these configuration actions
outside the Rust lease and only against the explicitly owned running role.

An owned RDP file requires server authentication at level 1 and enables CredSSP.
The client does not accept certificate warnings or disable NLA. The distinct
peer password is transported through PowerShell Direct and guest-user DPAPI,
then placed in the guest user's credential set with
[session-only persistence](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentialw)
for the exact `TERMSRV/<peer>` target. Existing credentials are refused. The
owned entry is deleted during cleanup; it also expires at guest logoff. Neither
the RDP file nor command-line arguments contain a password. The DPAPI transport
file is removed before output collection. Clipboard redirection is enabled; audio,
microphone, drives, printers, ports, smart cards, and automatic reconnect are
disabled for this bounded connection. No RDP client or clipboard operation runs
in the host's interactive session.

A visible client window is insufficient: the server must expose a new active
RDP session for the expected account and private client address, and Primary
must have an established TCP 3389 connection owned by the exact native client
process, executable path, account, and console session. This bounded server
proof enables the client command loop. The peer task then requires
session protocol 2, client address 10.77.166.10, an unlocked guest desktop, and a
non-elevated token.
The task launcher selects the unique active guest console/RDP session using
read-only WTS metadata and binds the task to that exact session with RunEx.
Reports from a different session are refused. It runs the thirteen cases inside
that remote session, then four cases using Ctrl+V sent through the actual client:

- `RdpSessionImagePaste`: a 2x2 image created in Peer, pasted through client input.
- `RdpRedirectedImagePaste`: a distinct 3x2 image created only in Primary must
  appear in Peer's clipboard before client Ctrl+V creates its exact PNG. The
  controller relays command metadata and acknowledgements, never image pixels.
  The client publishes an explicit CF_DIBV5 with an owned message-only window
  and requires exact native source readback before acknowledging the command.
  The verifier reads native DIB headers and channel masks; preparation checks
  header variants, row orientation, altered pixels, masks, and truncation.
- `RdpNativeFilePaste`: a local Peer file retains native paste priority when a
  bitmap is also present; its contents remain intact and no extra PNG appears.
- `RdpRedirectedTextPaste`: client text crosses the clipboard channel and reaches
  Peer's native Explorer search control without creating output.

The fixed client command order, all seventeen case names/results, image pixels,
normal application exit, settings restoration, and clean client disconnect are
required. After all cases, the controller disconnects only the pinned Peer RDP
session, checks its disconnected state, and requires the owned client to exit
with code 0 without forced termination. Both unique tasks, the transport file,
and the session credential are removed. A failed connected suite also requests
controlled client close and disconnects only that verified session before
removing tasks; the original test failure remains a failure. Any fallback task
stop is recorded separately. On redirected-image checks, private diagnostics
record available clipboard formats, dimensions, pixel format, and bounded RGB
and ARGB hashes at each endpoint. These observations never supply image data to
the other guest or relax the exact fixture check. Client input
has the existing five-minute guest deadline; tasks are limited to seven minutes.
Preparation checks that the native client exists and compiles the guarded input
and read-only session helpers without launching it. The command loop reports
setup stage, native process/window state, and heartbeat. After a failed logon it may retain a
diagnostic screenshot of Primary's disposable desktop in private output only;
the same guest identity, role, and unlocked-desktop guards apply. No host desktop
is captured. A diagnostic image is not evidence that a paste case passed.

`Set-RdpLabTrust.ps1 -Action Cleanup` removes only trust added by this run and
restores the exact original hosts bytes/hash and timestamp. Unexpected edits
prevent overwrite and fail cleanup. A calling cycle must also remove its own
temporary Primary auto-logon password/count, confirm both guests off, and retain
private evidence. Preparation can run one guest at a time; queue the paired
runtime with both guests off, then apply the same 11/7 GiB admission limits.
This does not test client-to-server file transfer, disconnection/reconnection,
clipboard policy restrictions, Windows 10, or arbitrary RDP client versions.

### Explicit consent for the owned guest RDP file

Windows can require a first-use account acknowledgement and per-connection
resource consent when opening RDP files. With separate, explicit permission,
`-AllowGuestRdpFileConsent` recognizes only the owned native client dialogs,
checks that the locally generated RDP file is unchanged and the peer name
matches, acknowledges first use, and selects only Clipboard. Other resource
checkboxes remain off. It does not accept certificate warnings or revert
Windows security dialog policies. See the
[Windows dialog description](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/understanding-security-warnings).

The first-use acknowledgement remains only in the disposable LaqayLab guest
account until the VM is removed; disclose this when obtaining permission.
Without the switch, no consent is accepted automatically. Setup also records
current OS/client versions and evaluation licensing status as read-only private
diagnostics; it never changes activation, clocks, license keys, or network access.

## Isolated Explorer lifecycle checks

`Invoke-DesktopSmoke.ps1 -IncludeLifecycle` extends the thirteen console cases
with `ExplorerRestartRecovery` and `ExitWithPendingClipboard`. This is a separate
Primary-only run; do not combine it with startup, UNC, or RDP cases. Arrange an
explicitly authorized guest interactive logon and acquire RustWork before guest
boot/runtime. Peer remains off. Preparation compiles helpers and checks guards
without starting a VM, restarting Explorer, or reading the host clipboard.

The restart case identifies the actual shell PID in the disposable console,
checks its executable/session, and refuses separately hosted owned folder
windows. It terminates only that guest shell, waits for a different shell PID,
requires the same Laqay PID and a registered notification icon, and pastes a new
image with exact PNG validation. It does not restart the host shell.

The pending-work case advertises only a delayed PNG from an owned message-only
window. Its provider thread withholds data for at most sixty seconds. After
the render request arrives, the privileged guest controller inspects only the
exact Laqay PID. It accepts a wait-chain dependency on the owned provider, or
two native x64 thread-context snapshots, at least 100 ms apart, that show the
same thread in the actual system clipboard-read syscall stub. The syscall
export must have a recognized instruction layout and reside in the matching
system module. A missing/unknown layout declines proof; these implementation
details are diagnostic constraints, not a production API dependency.
Snapshots capture only thread information and control registers: no address
space clone, application memory pages, or dump file. Snapshots/walk markers are
freed after each sample. The task also requires the provider to remain the
clipboard owner, its sequence unchanged, and its data withheld before close.
Guest identity, process owners, paths, and session are validated. The guest
controller temporarily enables and restores SeDebugPrivilege for the diagnostic;
no policy is modified. Missing proof remains a failure. WCT observations are
retained because clipboard waits may not expose an object/owner chain.

Only after the bound proof does the limited task request normal application
close. It requires exit 0 without forced termination while the provider remains
blocked, then cancels and joins its own provider, checks the destination contains
no PNG or staging file, and restores preferences/permissions. The host requires
all fifteen cases, the wait proof, provider cleanup, and task removal. The caller
must remove temporary guest logon configuration and confirm the guests are off.
This validates close during a blocked clipboard read; it does not claim coverage
of every encoding/write stage or an actual Windows shutdown. Runtime validation
passed all fifteen cases in the owned Windows 11 evaluation console, including
the native context proof, normal application exit, and complete cleanup.

## Published portable package cycle

`Invoke-PortablePackageCycle.ps1` prepares a Primary-only upgrade and removal
check using the published v0.1.0 and v0.1.1 ZIP bytes. This cycle **passed all
37 assertions on 2026-11-03 in the isolated Windows 11 Enterprise evaluation
console**, using five guest boots. The original App, preferences and temporary
logon configuration were restored; both guests were shut down and all owned
helper/coordinator processes exited. These results use the actual published
packages. The cycle does not publish or change versions.

The first isolated attempt passed all thirteen v0.1.0 Explorer assertions but
stopped because the launch controller incorrectly sent disabled Boolean options
as nonempty strings, enabling an unintended lifecycle case. It restored the
baseline and temporary logon configuration, shut down both guests and exited
its owned processes. That failed attempt does not pass this gate. Desktop and
RDP option transport now uses explicitly grouped Boolean values and rejects
non-Boolean input. CI captures the actual launch argument expressions against a
local remoting mock across enabled/disabled options and portable phases, without
contacting a guest. The subsequent fresh full-cycle run passed, including both
180-second absence observations, normal application exits and complete cleanup.

Obtain the releases separately and verify their source/release provenance before
authorizing the administrator process. The harness additionally pins both archive
and executable hashes. v0.1.0 has no artifact attestations and is mutable; its
previously reviewed byte hashes are the baseline identity, not an attestation.
v0.1.1 was built by the recovery workflow: its builder commit differs from the
application tag. Verify both its standard build attestation and release-source
binding, plus the immutable release attestation. See [PORTABLE.md](PORTABLE.md).

The administrator invokes the mixed orchestrator outside a RustWork lease:

```powershell
./scripts/lab/Invoke-PortablePackageCycle.ps1 -LabId <lab-id> -CycleId <new-guid-N> -OldArchivePath <verified-v0.1.0-zip> -NewArchivePath <verified-v0.1.1-zip> -OutputDirectory <new-private-directory> -PythonPath <python-executable> -CoordinatorPath <rust-work.py>
```

It never requests elevation itself. Obtain explicit permission first. Both guests
must initially be off; Peer stays off throughout. Primary retains 2 CPUs, 4 GiB
fixed RAM, its owned disk and private network. Existing admission guards reserve
3 GiB of host RAM and 40 GiB of free disk. Every boot and runtime phase enters
the shared RustWork coordinator **before** starting the VM. File, registry and
shutdown operations run separately. The cycle requires five normal boots and
allows at most one additional recovery boot. A failed runtime phase attempts
normal guest shutdown before releasing its lease.

The sequence checks 37 interactive assertions: thirteen Explorer cases on each
release, the old version's saved Disabled setting and startup registration round
trip, the upgrade preserving Disabled and subsequently saving an exact PNG,
six actual login-startup assertions, and a fresh post-removal boot with no app,
startup entry or preferences for 180 seconds. The startup-disabled observation
also lasts 180 seconds. Interactive tasks run with the existing limited guest
token and guarded disposable console; no host input or clipboard is used.

The original development App tree moves to an owned backup outside App. Inventories
include file hashes and empty directories, reject reparse points and prevent
recursive deletion of unexpected contents. Old and new packages occupy the same
path. Original preferences and nonsecret Winlogon values are snapshotted before
changes. Each temporary guest login has a one-login count and cycle ownership
marker; its password is neither returned nor logged. Final cleanup removes the
temporary login password/count/marker, verifies the restored App inventory and
preferences, removes verified archive inputs, and requires both guests off.
Changed or partially installed content is preserved and makes cleanup fail rather
than overwriting it. Inspect private reports and resolve any failed cleanup before
another run. Reports include normal application exits, task removal, runtime
receipts, file actions and final guest states. Confirm the elevated helper and
its coordinator children have exited after collecting the final report.

`Test-LabPreparation.ps1` runs inert archive/file safety cases, compiles the guest
helpers and parses the scripts in CI without creating a VM or running Laqay.
That preparation does not prove the interactive cycle passed. This cycle does
not cover Windows 10, Authenticode signing, every image format, or the complete
desktop integration matrix.

## Additional console adverse checks

`Invoke-PortablePackageCycle.ps1 -AdverseOnly` selects a separate 27-case suite:
the thirteen Explorer regressions plus empty clipboard, externally locked
clipboard and recovery, exact PNG alpha, a 2048x2048 PNG with bounded tray-window
responsiveness checks, held-key repeat, rapid paste preservation, a real second
instance, This PC namespace rejection, native Edit/RichEdit fixtures, and idle/
serial resource samples. This suite **passed all 27 cases on 2026-11-03** using
published v0.1.1 in the isolated Windows 11 Enterprise evaluation console. The
normal two-boot cycle completed application exit, baseline/preferences/logon
restoration, both guest shutdowns and owned helper/coordinator process exit.

The lock fixture retires old input requests, opens the clipboard with its
own message-only window, and records exact window/process/thread ownership plus
a rejected second open before Ctrl+V, after Ctrl+V and after observation. All
three observations are required. See the Windows descriptions of
[OpenClipboard](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openclipboard)
and [GetOpenClipboardWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getopenclipboardwindow).
All three ownership observations and the subsequent recovery passed.

It reuses the byte-pinned published v0.1.1 executable and the original App/
preference/logon backup and restoration policy. v0.1.0 is staged only as an
unexecuted file fixture before installing v0.1.1. Primary uses two normal boots,
with at most one recovery boot, under RustWork; Peer stays off. Explicitly
authorize the new administrator process before execution. No host input,
clipboard, window or session is controlled. Normal application exits, all
27 named cases, four resource records, owned editor/clipboard-lock teardown,
baseline restoration and both guests off are required.

Before queuing any new boot, the mixed orchestrator waits up to two minutes for
the unchanged seven-GiB host-memory admission budget, outside a Rust lease. This
can accommodate memory reclamation after guest shutdown; actual start still
rechecks all ownership, memory and disk guards. It does not guarantee capacity
will remain available during the queue. A rejected recovery leaves the original
snapshot intact and requires a separately authorized restoration before retest.
The first attempt's restoration was completed in that separate operation, with
both guests off and its helper/coordinator processes exited; the failed test
result remains preserved.

The editor fixtures are a separate helper window containing native TextBox and
RichTextBox controls. They select the child after activating their own form,
without synthetic Alt, and require native focus outside menu/move mode. Exact
text passed with Laqay disabled and enabled, retaining GUI thread state and
bounded Ctrl/V queue observations. Earlier editor failures disappeared after
removing Alt from fixture activation; no production code changed. Failure-only
sender-thread and forwarding-hook diagnostics preserve the original failure
and were not needed in the passing run. The reference hook has a ten-second
timer and explicit owned unregistration/cleanup.
These controls do not stand in for Notepad, VS Code, Rider, Terminal
or a browser. Resource samples record CPU, memory, handles and threads and
window-message responsiveness; they do not claim a sustained-load benchmark
or leak test. Clipboard lock rejection may safely finish with one complete PNG
after release; no staging files or overwritten images are allowed. Rapid input
may be safely coalesced, while a held V key must create exactly one image.

Preparation compiles the guarded helper, rejects its unarmed controls, checks
real launch argument binding and independently decodes the synthetic PNG alpha/
corner pixels without opening a clipboard or desktop. Actual application
compatibility, deterministic focus/clipboard races, OLE virtual-file transfer,
full-volume/disconnected-share recovery and long-running resource tests remain
separate pending portions of the integration matrix. Windows 10 is not covered.

## Read-only application inventory

`Get-GuestApplicationInventory.ps1 -Session <owned-primary-session> -LabId <id>`
collects fixed-path executable metadata and registered/provisioned Notepad and
Terminal package metadata before planning real application paste tests. It
rejects missing/wrong lab markers, Peer, non-VM hardware and unsupported OS
before collection. No application, task, clipboard operation or installation
is started. Execution aliases are reported without following their targets.

Missing applications are inventory results, not failed compatibility tests.
A launcher file or registered package does not prove the application opens or
pastes correctly. Partial package-query errors remain explicit. Boot Primary
only with authorization, ownership/resource guards and RustWork; keep Peer off
and shut Primary down afterward. The inventory itself runs outside the Rust
lease and does not require an interactive guest login or temporary auto-logon.
