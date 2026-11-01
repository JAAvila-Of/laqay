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

Nine required cases exercise real Ctrl+V through guest SendInput and inspect
observable results: exact 2x2 image colors/dimensions, preserving existing images,
multiple-file paste with simultaneous bitmap data, text-plus-image clipboard
exclusion in address/search/rename fields, disabled/re-enabled behavior, and
active-tab selection in both directions within one Explorer window. Enabled uses
the normal application's owned menu command handler. Preferences are restored.
The application runs with normal permissions in an owned KillOnJobClose process
job. The suite has a five-minute input deadline, a seven-minute guest task limit,
and an eight-minute host deadline. It closes its Explorer windows and application;
the controller removes the task and retains reports, logs, and synthetic output.
The calling host operation must shut down the owned guest in its final cleanup.

Successful transport, a started task, or a partial report cannot pass: the host
requires every named case, clean application shutdown, restored preferences,
no forced termination, no cleanup errors, and task result zero. These smoke
cases do not cover audio, every notification, other applications, rapid tab or
clipboard races, UNC failures, OneDrive, RDP, or actual Windows login startup.
Record completed scenarios and OS builds without expanding their scope.
