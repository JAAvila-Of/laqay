[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [string]$OldArchivePath,
    [string]$NewArchivePath,
    [string]$OutputDirectory,
    [string]$PythonPath,
    [string]$CoordinatorPath,
    [switch]$AdverseOnly,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PrepareOnly){& (Join-Path $PSScriptRoot 'Invoke-DesktopSmoke.ps1') -PrepareOnly;return}
if(-not $LabId -or -not $CycleId -or -not $OldArchivePath -or -not $NewArchivePath -or -not $OutputDirectory -or -not $PythonPath -or -not $CoordinatorPath){throw 'Cycle identities, verified published archives, output and coordinator paths are required.'}
if($env:RUST_WORK_JOB){throw 'The mixed orchestrator must run outside a Rust lease.'}
if(-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An explicitly authorized administrator process is required. This script never elevates itself.'}
$root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA ('LaqayTestLab/'+$LabId)))
$manifest=Get-Content -LiteralPath (Join-Path $root 'lab.json') -Raw | ConvertFrom-Json
if($manifest.Kind -ne 'LaqayDesktopTestLab' -or $manifest.LabId -ne $LabId -or $manifest.Root -ne $root){throw 'Lab manifest ownership mismatch.'}
$primary=@($manifest.VMs | Where-Object Role -eq Primary);$peers=@($manifest.VMs | Where-Object Role -eq Peer)
if($primary.Count -ne 1 -or $peers.Count -ne 1 -or $manifest.VMs.Count -ne 2){throw 'The existing isolated two-guest lab is required; only Primary will run.'}
$primary=$primary[0];$peer=$peers[0];$vm=Get-VM -Id ([guid]$primary.Id)
foreach($entry in @($primary,$peer)){
    $owned=Get-VM -Id ([guid]$entry.Id);$disk=Join-Path $root ('vms/'+$entry.Role+'/system.vhdx');$drives=@(Get-VMHardDiskDrive -VM $owned)
    if($owned.State -ne 'Off' -or $owned.Name -ne $entry.Name -or $owned.Notes -ne ('Laqay disposable desktop lab '+$LabId) -or $entry.DiskPath -ne $disk -or $drives.Count -ne 1 -or $drives[0].Path -ne $disk){throw 'Both owned guests must initially be off with their original disks.'}
}
foreach($path in @($OldArchivePath,$NewArchivePath,$PythonPath,$CoordinatorPath)){if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'A required verified input is missing.'}}
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem,System.Web.Extensions
Add-Type -Path (Join-Path $PSScriptRoot 'PortablePackageFiles.cs') -ReferencedAssemblies @('System.Core.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll','System.Web.Extensions.dll')
$oldExe='61b7051456e0a75a8002e8ddbeff493c68e37270d20a4a53020d90cea849d92b'
$newExe='3e73ff0b35661c23064101049f481dadeceb41bc31db21a0dcba7ec1aaf9632f'
[LaqayPortableFiles]::Archive($OldArchivePath,'1ad8b8fc002ae1b259702ccb567b12f4d28f3a0a6011b843c9e23b6a73263fa7',$oldExe) | Out-Null
[LaqayPortableFiles]::Archive($NewArchivePath,'ba02df3dccebc34543bfae93c3a80ff4195d6c6f143d775e45621463309f9c23',$newExe) | Out-Null
$credential=Import-Clixml -LiteralPath (Join-Path (Split-Path $primary.DiskPath) 'credential.xml')
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $output){throw 'A portable cycle requires a new output directory.'}
[IO.Directory]::CreateDirectory($output) | Out-Null
$reportPath=Join-Path $output 'cycle-report.json'
$control=Join-Path $PSScriptRoot 'Invoke-DesktopTestLab.ps1'
$worker=Join-Path $PSScriptRoot 'Invoke-PortableRuntimePhase.ps1'
$files=Join-Path $PSScriptRoot 'Invoke-PortableGuestFiles.ps1'
$guestRoot='C:\LaqayLab\Portable\'+$CycleId
$maximumBoots=if($AdverseOnly){3}else{6}
$session=$null;$touched=$false;$staged=$false;$stageAttempted=$false;$bootAttempts=0
$report=[ordered]@{LabId=$LabId;CycleId=$CycleId;Process=$PID;Passed=$false;Error=$null;Phases=@();FileActions=@();
    AdverseOnly=[bool]$AdverseOnly;BaselineRestored=$false;AutoLogonRestored=$false;PrimaryOff=$false;PeerOff=$false;CleanupErrors=@();BootAttempts=0;StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
function Save-Report {$report.BootAttempts=$script:bootAttempts;$report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $reportPath -Encoding UTF8}
function Assert-PeerOff {if((Get-VM -Id ([guid]$peer.Id)).State -ne 'Off'){throw 'Peer must remain off throughout the portable cycle.'}}
function Connect-Guest {
    if($script:session){Remove-PSSession -Session $script:session;$script:session=$null}
    $script:session=New-PSSession -VMId $vm.Id -Credential $credential
}
function Run-Files([string]$action){
    Assert-PeerOff
    if(-not $script:session){Connect-Guest}
    $result=& $files -Session $script:session -LabId $LabId -CycleId $CycleId -Action $action -Credential $credential
    $report.FileActions+=@($result);Save-Report
    if(-not $result.Passed){throw ('Guest file action failed: '+$action)}
}
function Stop-Guest {
    if($script:session){Remove-PSSession -Session $script:session;$script:session=$null}
    & $control -Action Stop -LabId $LabId | Out-Null
    if((Get-VM -Id $vm.Id).State -ne 'Off'){throw 'Primary did not shut down normally.'}
}
function Run-Phase([string]$phase,[string]$sha){
    Assert-PeerOff
    if((Get-VM -Id $vm.Id).State -eq 'Off'){
        if($script:bootAttempts -ge $maximumBoots){throw 'The bounded boot limit, including recovery, was reached.'}
        $script:bootAttempts++
    }
    $script:touched=$true
    $directory=Join-Path $output ((@($report.Phases).Count.ToString('D2'))+'-'+$phase)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $receipt=Join-Path $directory 'rust-work.json'
    $previous=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        & $PythonPath $CoordinatorPath --project laqay-portable-cycle --receipt $receipt --family rust -- (Join-Path $PSHOME 'powershell.exe') -NoProfile -File $worker -LabId $LabId -CycleId $CycleId -Phase $phase -ExpectedExecutableSha256 $sha -OutputDirectory $directory *> (Join-Path $directory 'runtime.log')
        $code=$LASTEXITCODE
    }finally{$ErrorActionPreference=$previous}
    $path=Join-Path $directory 'phase-report.json';$phaseReport=$null
    if(Test-Path -LiteralPath $path){$phaseReport=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json}
    $report.Phases+=@([pscustomobject]@{Phase=$phase;ExitCode=$code;Report=$phaseReport});Save-Report
    if($code -ne 0 -or -not $phaseReport.Passed){throw ('Portable cycle phase failed: '+$phase)}
}
function Next-Boot {Run-Files 'Logon';Stop-Guest}
try{
    Run-Phase 'Boot' $oldExe
    Connect-Guest
    Invoke-Command -Session $session -ArgumentList $LabId,$CycleId -ScriptBlock {
        param($labId,$cycleId)
        $ErrorActionPreference='Stop'
        $ready=Get-Content -LiteralPath 'C:\LaqayLab\ready.json' -Raw | ConvertFrom-Json
        $computer=Get-CimInstance Win32_ComputerSystem
        if($ready.LabId -ne $labId -or $ready.Role -ne 'Primary' -or -not $ready.Ready -or $computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine'){throw 'Refusing fixture reservation outside the owned guest.'}
        $path='C:\LaqayLab\Portable\'+$cycleId
        foreach($candidate in @('C:\LaqayLab','C:\LaqayLab\Portable',$path)){
            if(Test-Path -LiteralPath $candidate){if((Get-Item -LiteralPath $candidate).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A fixture ancestor is a reparse point.'}}
        }
        if(Test-Path -LiteralPath $path){throw 'Refusing an existing portable fixture.'}
        New-Item -ItemType Directory -Path $path | Out-Null
    }
    Copy-Item -LiteralPath $OldArchivePath -Destination (Join-Path $guestRoot 'old.zip') -ToSession $session
    Copy-Item -LiteralPath $NewArchivePath -Destination (Join-Path $guestRoot 'new.zip') -ToSession $session
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'PortablePackageFiles.cs') -Destination $guestRoot -ToSession $session
    $stageAttempted=$true;Run-Files 'Stage';$staged=$true
    if($AdverseOnly){
        # Reuse byte-pinned package staging and full baseline restoration. Only
        # the published new executable is run by this separate console suite.
        Run-Files 'Upgrade'
        Next-Boot
        Run-Phase 'Adverse' $newExe
    }else{
    Next-Boot
    Run-Phase 'Old' $oldExe
    Run-Files 'Upgrade'
    Run-Phase 'New' $newExe
    Run-Phase 'Enable' $newExe
    Next-Boot
    Run-Phase 'Verify' $newExe
    Next-Boot
    Run-Phase 'Absent' $newExe
    Run-Files 'Remove'
    Next-Boot
    Run-Phase 'Removed' $newExe
    }
    $report.Passed=$true
}catch{$report.Error=$_.Exception.Message}finally{
    if($touched){
        try{
            if($stageAttempted -and (Get-VM -Id $vm.Id).State -eq 'Off'){Run-Phase 'Boot' $newExe}
            if((Get-VM -Id $vm.Id).State -eq 'Running'){
                Connect-Guest
                $hasState=Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {param($path) Test-Path -LiteralPath (Join-Path $path 'state.json')}
                if($hasState){
                    try{Run-Files 'ClearLogon';$report.AutoLogonRestored=$true}catch{$report.CleanupErrors+=@($_.Exception.Message)}
                    try{Run-Files 'Restore';$report.BaselineRestored=$true}catch{$report.CleanupErrors+=@($_.Exception.Message)}
                }elseif(-not $staged){$report.AutoLogonRestored=$true;$report.BaselineRestored=$true}
                if($hasState){Copy-Item -LiteralPath (Join-Path $guestRoot 'state.json') -Destination (Join-Path $output 'guest-state.json') -FromSession $session}
            }
        }catch{$report.CleanupErrors+=@($_.Exception.Message)}
        try{Stop-Guest}catch{$report.CleanupErrors+=@($_.Exception.Message)}
    }
    if($session){Remove-PSSession -Session $session}
    $report.PrimaryOff=(Get-VM -Id $vm.Id).State -eq 'Off';$report.PeerOff=(Get-VM -Id ([guid]$peer.Id)).State -eq 'Off'
    if(-not $report.BaselineRestored -or -not $report.AutoLogonRestored -or -not $report.PrimaryOff -or -not $report.PeerOff -or $report.CleanupErrors.Count){$report.Passed=$false}
    $report.FinishedUtc=[DateTime]::UtcNow.ToString('o');Save-Report
}
if(-not $report.Passed){throw ('Portable package cycle failed: '+$report.Error+' '+($report.CleanupErrors -join '; '))}
Write-Output 'The selected published-package cycle passed with baseline restoration and both guests off.'
