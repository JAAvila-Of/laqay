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

`Invoke-RdpSmoke.ps1` runs the native Windows RDP ActiveX client in Primary's
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

The client requires
[server authentication](https://learn.microsoft.com/en-us/windows/win32/termserv/imsrdpclientadvancedsettings4-authenticationlevel)
at level 1 and enables CredSSP. It does not accept certificate warnings, disable
NLA, or store a persistent credential. The distinct peer password is transported
through PowerShell Direct and guest-user DPAPI, imported by the limited client,
and removed before output collection. Clipboard redirection is enabled; audio,
microphone, drives, printers, ports, smart cards, and automatic reconnect are
disabled for this bounded connection. No RDP client or clipboard operation runs
in the host's interactive session.

The client must report a completed native logon. The peer task then requires
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
- `RdpNativeFilePaste`: a local Peer file retains native paste priority when a
  bitmap is also present; its contents remain intact and no extra PNG appears.
- `RdpRedirectedTextPaste`: client text crosses the clipboard channel and reaches
  Peer's native Explorer search control without creating output.

The fixed client command order, all seventeen case names/results, image pixels,
normal application exit, settings restoration, and clean client disconnect are
required. Both unique tasks and the credential file are removed. Client input
has the existing five-minute guest deadline; tasks are limited to seven minutes.
The native control's interfaces and event DISPIDs are checked from its installed
type library during preparation without constructing a control.
Connection startup runs from the client's UI timer and reports each setup stage,
connection state, and heartbeat. After a stalled or failed logon it may retain a
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
