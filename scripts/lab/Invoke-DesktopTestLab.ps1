[CmdletBinding()]
param(
    [ValidateSet('Plan','Provision','Start','Status','Stop','Remove')][string]$Action = 'Plan',
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidateSet('Primary','Peer')][string]$Role = 'Primary',
    [string]$WindowsIso,
    [string]$IsoSha256,
    [string]$ApplicationArchive
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$base = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'LaqayTestLab'))
$root = [IO.Path]::GetFullPath((Join-Path $base $LabId))
$manifestPath = Join-Path $root 'lab.json'
$switchName = 'Laqay.Test.' + $LabId.Substring(0,12)
$vmName = $switchName + '.' + $Role
$owner = 'Laqay disposable desktop lab ' + $LabId

function Assert-OwnedPath([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    if ($full -ne $root -and -not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Path escapes the disposable lab root.'
    }
    $part = $full
    while ($part) {
        if (Test-Path -LiteralPath $part) {
            if (((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Reparse points are not permitted in lab paths.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($part)
        if ($part -eq $parent) { break }
        $part = $parent
    }
    return $full
}
function Save-Manifest {
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}
function Get-OwnedVM($entry) {
    $vm = Get-VM -Id ([guid]$entry.Id) -ErrorAction SilentlyContinue
    if ($vm -and ($vm.Notes -ne $owner -or $vm.Name -ne $entry.Name)) { throw 'VM ownership no longer matches the manifest.' }
    return $vm
}
[void](Assert-OwnedPath $root)
$plan = [ordered]@{
    Kind='LaqayDesktopTestLab'; Schema=1; LabId=$LabId; Root=$root; Temporary=$true
    Name=$vmName; Generation=2; CpuCount=2; MemoryBytes=4GB; MaximumDiskBytes=64GB
    HostMemoryReserveBytes=3GB; HostDiskReserveBytes=40GB; Network='Private'
    SwitchName=$switchName; HostDesktopControl=$false; HostReboot=$false
    Internet=$false; WindowsVersion='Windows 11 Enterprise Evaluation'; Role=$Role
}
if ($Action -eq 'Plan') { $plan | ConvertTo-Json -Depth 5; return }
$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Kind -ne $plan.Kind -or $manifest.Schema -ne 1 -or $manifest.LabId -ne $LabId -or $manifest.Root -ne $root) {
        throw 'Invalid disposable lab manifest.'
    }
} elseif ($Action -ne 'Provision') { throw 'A provisioned lab manifest is required.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'An explicitly authorized administrator process is required; this script never elevates itself.'
}
Import-Module Hyper-V

if ($Action -eq 'Provision') {
    if (-not $WindowsIso -or $IsoSha256 -notmatch '^[a-fA-F0-9]{64}$' -or -not $ApplicationArchive) {
        throw 'An ISO, its expected SHA-256, and the validated application archive are required.'
    }
    $iso = Assert-OwnedPath $WindowsIso
    $archive = Assert-OwnedPath $ApplicationArchive
    if ((Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash -ne $IsoSha256) { throw 'ISO SHA-256 mismatch.' }
    if ((Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($root).Substring(0,1))).SizeRemaining -lt 50GB) { throw 'Insufficient host disk headroom.' }
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { throw 'Refusing to replace an existing VM.' }
    if ($manifest -and @($manifest.VMs | Where-Object Role -eq $Role).Count) { throw 'This guest role already has a manifest entry.' }
    if (-not $manifest) {
        if (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue) { throw 'Refusing to reuse an unowned switch.' }
        $existing = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | Where-Object Name -ne 'media')
        if ($existing.Count) { throw 'The uninitialized lab root contains unexpected files.' }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in @($identity.User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        }
        Set-Acl -LiteralPath $root -AclObject $acl
        $manifest = [pscustomobject]@{Kind=$plan.Kind;Schema=1;LabId=$LabId;Root=$root;Temporary=$true;SwitchId=$null;SwitchName=$switchName;VMs=@();Phase='Preparing'}
        Save-Manifest
        $switch = New-VMSwitch -Name $switchName -SwitchType Private -Notes $owner
        $manifest.SwitchId = $switch.Id.ToString()
        Save-Manifest
    } else {
        $switch = Get-VMSwitch -Id ([guid]$manifest.SwitchId)
        if ($switch.Name -ne $switchName -or $switch.SwitchType -ne 'Private' -or $switch.Notes -ne $owner) { throw 'Private switch ownership changed.' }
    }
    $guestRoot = Assert-OwnedPath (Join-Path $root ('vms/' + $Role))
    $seedRoot = Join-Path $guestRoot 'seed'
    New-Item -ItemType Directory -Path $seedRoot -Force | Out-Null
    $random = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    $password = 'Lq!' + ([BitConverter]::ToString($random).Replace('-',''))
    $credential = [PSCredential]::new('LaqayLab',(ConvertTo-SecureString $password -AsPlainText -Force))
    $credential | Export-Clixml -LiteralPath (Join-Path $guestRoot 'credential.xml')
    $label = 'LQ' + $LabId.Substring(0,12).ToUpperInvariant()
    [ordered]@{LabId=$LabId;Role=$Role;Temporary=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $seedRoot 'guest.json') -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Initialize-Guest.ps1') -Destination $seedRoot
    Copy-Item -LiteralPath $archive -Destination (Join-Path $seedRoot 'Laqay.zip')
    $bootstrap = @'
$ErrorActionPreference='Stop'
if((Get-CimInstance Win32_ComputerSystem).Model -ne 'Virtual Machine'){throw 'Guest initialization requires a virtual machine.'}
$source=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | Where-Object VolumeName -eq '@@LABEL@@')
if($source.Count -ne 1){throw 'Expected one lab seed DVD.'}
$sourcePath=$source[0].DeviceID+'\'
$marker=Get-Content -LiteralPath ($sourcePath+'guest.json') -Raw | ConvertFrom-Json
if($marker.LabId -ne '@@LAB_ID@@' -or $marker.Role -ne '@@ROLE@@'){throw 'Unexpected lab seed.'}
if(Test-Path -LiteralPath 'C:\LaqayLab'){throw 'Guest lab directory already exists.'}
New-Item -ItemType Directory -Path 'C:\LaqayLab' | Out-Null
foreach($file in @('guest.json','Initialize-Guest.ps1','Laqay.zip')){Copy-Item -LiteralPath ($sourcePath+$file) -Destination 'C:\LaqayLab'}
& 'C:\LaqayLab\Initialize-Guest.ps1' -LabId '@@LAB_ID@@' -Role '@@ROLE@@'
'@
    $bootstrap = $bootstrap.Replace('@@LABEL@@',$label).Replace('@@LAB_ID@@',$LabId).Replace('@@ROLE@@',$Role)
    [IO.File]::WriteAllText((Join-Path $seedRoot 'Bootstrap.ps1'),$bootstrap,[Text.UTF8Encoding]::new($false))
    $command = 'powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -Command "& ((Get-Volume|? FileSystemLabel -eq ''' + $label + ''').DriveLetter+'':\Bootstrap.ps1'')"'
    if ($command.Length -gt 259) { throw 'First-logon command is too long.' }
    $answer = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Autounattend.xml.template') -Raw
    $answer = $answer.Replace('@@PASSWORD@@',[Security.SecurityElement]::Escape($password)).Replace('@@COMPUTER_NAME@@',('LQW11-' + $LabId.Substring(0,7) + $(if($Role -eq 'Peer'){'P'}else{'A'}))).Replace('@@FIRST_LOGON_COMMAND@@',[Security.SecurityElement]::Escape($command))
    [void][xml]$answer
    [IO.File]::WriteAllText((Join-Path $seedRoot 'Autounattend.xml'),$answer,[Text.UTF8Encoding]::new($false))
    $seedIso = Join-Path $guestRoot 'seed.iso'
    & (Join-Path $PSScriptRoot 'New-SeedIso.ps1') -SourceDirectory $seedRoot -Destination $seedIso -VolumeLabel $label
    $disk = Join-Path $guestRoot 'system.vhdx'
    $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 4GB -NewVHDPath $disk -NewVHDSizeBytes 64GB -Path $guestRoot -SwitchName $switchName
    # Journal the returned VM ID immediately. Only this ID can be removed later.
    $entry = [pscustomobject]@{Id=$vm.Id.ToString();Name=$vmName;Role=$Role;DiskPath=$disk;SeedIso=$seedIso;IsoPath=$iso;IsoSha256=$IsoSha256;InstallStarted=$false;InitialDiskBytes=(Get-Item -LiteralPath $disk).Length}
    $manifest.VMs = @($manifest.VMs) + @($entry)
    Save-Manifest
    Set-VM -VM $vm -Notes $owner -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -CheckpointType Disabled
    Set-VMProcessor -VM $vm -Count 2
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes 4GB
    Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
    Enable-VMTPM -VM $vm
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    Add-VMDvdDrive -VM $vm -Path $iso
    Add-VMDvdDrive -VM $vm -Path $seedIso
    $installDvd = Get-VMDvdDrive -VM $vm | Where-Object Path -eq $iso
    Set-VMFirmware -VM $vm -FirstBootDevice $installDvd
    $manifest.Phase = 'ProvisionedOff'
    Save-Manifest
    [ordered]@{Provisioned=$true;Started=$false;Name=$vmName;Id=$vm.Id.ToString();LabId=$LabId} | ConvertTo-Json
    return
}

if ($Action -eq 'Remove') {
    # Validate every target before deleting anything. Never follow links or
    # remove a shared switch that another VM has started using.
    $resolved = (Resolve-Path -LiteralPath $root).Path
    if ($resolved -ne $root -or [IO.Path]::GetDirectoryName($resolved) -ne $base -or [IO.Path]::GetFileName($resolved) -ne $LabId) { throw 'Unexpected removal root.' }
    [void](Assert-OwnedPath $resolved)
    $links = @(Get-ChildItem -LiteralPath $resolved -Force -Recurse | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($links.Count) { throw 'Refusing recursive deletion through a reparse point.' }
    $owned = @()
    foreach ($entry in @($manifest.VMs)) {
        [void](Assert-OwnedPath $entry.DiskPath)
        $vm = Get-OwnedVM $entry
        if ($vm) {
            if ($vm.State -ne 'Off') { throw 'Shut down owned guests before removing the lab.' }
            foreach ($drive in @(Get-VMHardDiskDrive -VM $vm)) {
                if (-not $drive.Path -or (Assert-OwnedPath $drive.Path) -ne $entry.DiskPath) { throw 'Unexpected guest disk attachment.' }
            }
            $owned += $vm
        }
    }
    $switch = $null
    if ($manifest.SwitchId) {
        $switch = Get-VMSwitch -Id ([guid]$manifest.SwitchId) -ErrorAction SilentlyContinue
        if ($switch -and ($switch.Notes -ne $owner -or $switch.Name -ne $switchName -or $switch.SwitchType -ne 'Private')) { throw 'Switch ownership changed.' }
        $foreign = @(Get-VM | Where-Object { $_.Id -notin @($owned.Id) } | Get-VMNetworkAdapter | Where-Object { $_.SwitchId -eq [guid]$manifest.SwitchId })
        if ($foreign.Count) { throw 'Another VM uses the lab switch; preserve it.' }
    }
    foreach ($vm in $owned) { Remove-VM -VM $vm -Force }
    if ($switch) { Remove-VMSwitch -VMSwitch $switch -Force }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    [ordered]@{Removed=$true;LabId=$LabId} | ConvertTo-Json
    return
}

$entry = @($manifest.VMs | Where-Object Role -eq $Role)
if ($entry.Count -ne 1) { throw 'Expected exactly one owned guest for this role.' }
$vm = Get-OwnedVM $entry[0]
if (-not $vm) { throw 'The owned guest no longer exists.' }
if ($Action -eq 'Start') {
    if (@(Get-VM | Where-Object { $_.Notes -eq $owner -and $_.State -ne 'Off' }).Count) { throw 'Start one lab guest at a time until the two-guest memory budget is reviewed.' }
    $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
    if ($free -lt 7GB) { throw 'Starting this guest would leave less than 3 GiB of current host memory headroom.' }
    if ((Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($root).Substring(0,1))).SizeRemaining -lt 40GB) { throw 'Insufficient host disk headroom.' }
    $drives = @(Get-VMHardDiskDrive -VM $vm)
    if ($drives.Count -ne 1 -or $drives[0].Path -ne (Assert-OwnedPath $entry[0].DiskPath)) { throw 'Unexpected guest disk layout; do not boot unattended setup.' }
    $firstInstall = -not $entry[0].InstallStarted
    if ($firstInstall) {
        if ((Get-Item -LiteralPath $entry[0].DiskPath).Length -ne $entry[0].InitialDiskBytes) { throw 'The new guest disk changed before unattended setup; do not wipe it.' }
        $entry[0].InstallStarted = $true
        Save-Manifest
    }
    Start-VM -VM $vm
    if ($firstInstall) {
        Start-Sleep -Seconds 3
        # Hyper-V's virtual keyboard targets this owned VM ID only. This is not
        # host SendInput, a foreground window, or a physical desktop key press.
        $system = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -Filter ("Name='" + $vm.Id + "'")
        $keyboard = Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_Keyboard
        $keyResult = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{keyCode=[uint32]32}
        if ($keyResult.ReturnValue -ne 0) { throw 'The owned VM did not accept its DVD boot key.' }
    }
} elseif ($Action -eq 'Stop') {
    Stop-VM -VM $vm -Confirm:$false
} elseif ($Action -eq 'Status') {
    $ready = $null
    if ($vm.State -eq 'Running') {
        $credential = Import-Clixml -LiteralPath (Join-Path (Split-Path $entry[0].DiskPath) 'credential.xml')
        try {
            $ready = Invoke-Command -VMId $vm.Id -Credential $credential -ScriptBlock {
                if (Test-Path -LiteralPath 'C:/LaqayLab/ready.json') { Get-Content -LiteralPath 'C:/LaqayLab/ready.json' -Raw }
            } -ErrorAction Stop
            if ($ready) {
                $ready = $ready | ConvertFrom-Json
                if ($ready.LabId -ne $LabId -or $ready.Role -ne $Role) { throw 'Guest identity mismatch.' }
            }
        } catch { $ready = $null }
    }
    if ($ready -and $ready.Ready) {
        # Prevent any later test reboot from returning to unattended setup.
        foreach ($dvd in @(Get-VMDvdDrive -VM $vm)) { Set-VMDvdDrive -VMDvdDrive $dvd -Path $null }
        Set-VMFirmware -VM $vm -FirstBootDevice (Get-VMHardDiskDrive -VM $vm)
    }
    [ordered]@{LabId=$LabId;Name=$vm.Name;State=$vm.State.ToString();Guest=$ready;TestsExecuted=$false} | ConvertTo-Json -Depth 6
}
