[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [string]$OutputDirectory,
    [string]$PythonPath,
    [string]$CoordinatorPath,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($PrepareOnly){& (Join-Path $PSScriptRoot 'Invoke-DesktopSmoke.ps1') -PrepareOnly;return}
if(-not $LabId -or -not $CycleId -or -not $ExpectedExecutableSha256 -or -not $OutputDirectory -or -not $PythonPath -or -not $CoordinatorPath){throw 'Lab/cycle identities, executable hash, output directory, Python, and RustWork coordinator paths are required.'}
if($env:RUST_WORK_JOB){throw 'The cycle orchestrator must run outside a Rust lease; it coordinates each runtime phase separately.'}
if(-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An explicitly authorized administrator process is required. This script never elevates itself.'}
foreach($file in @($PythonPath,$CoordinatorPath)){if(-not (Test-Path -LiteralPath $file -PathType Leaf)){throw 'A configured coordinator executable or script is missing.'}}
$labRoot=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA ('LaqayTestLab/'+$LabId)))
$manifest=Get-Content -LiteralPath (Join-Path $labRoot 'lab.json') -Raw | ConvertFrom-Json
if($manifest.Kind -ne 'LaqayDesktopTestLab' -or $manifest.LabId -ne $LabId -or $manifest.Root -ne $labRoot){throw 'Lab ownership mismatch.'}
$entries=@($manifest.VMs | Where-Object Role -eq Primary)
if($entries.Count -ne 1){throw 'Exactly one owned primary guest is required.'}
$entry=$entries[0]
$vm=Get-VM -Id ([guid]$entry.Id)
if($vm.Name -ne $entry.Name -or $vm.Notes -ne ('Laqay disposable desktop lab '+$LabId) -or $vm.State -ne 'Off'){throw 'The owned primary guest must initially be off.'}
$expectedDisk=Join-Path $labRoot 'vms/Primary/system.vhdx'
$drives=@(Get-VMHardDiskDrive -VM $vm)
if($entry.DiskPath -ne $expectedDisk -or $drives.Count -ne 1 -or $drives[0].Path -ne $expectedDisk){throw 'Unexpected guest disk layout.'}
$credential=Import-Clixml -LiteralPath (Join-Path (Split-Path $expectedDisk) 'credential.xml')
$output=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$reportPath=Join-Path $output 'cycle-report.json'
if(Test-Path -LiteralPath $reportPath){throw 'Refusing to reuse a cycle report.'}
$control=Join-Path $PSScriptRoot 'Invoke-DesktopTestLab.ps1'
$suite=Join-Path $PSScriptRoot 'Invoke-DesktopSmoke.ps1'
$vmTouched=$false;$logonArmed=$false;$settingsTouched=$false
$report=[ordered]@{LabId=$LabId;CycleId=$CycleId;Process=$PID;Passed=$false;Error=$null;Stage='Starting';Phases=@();
    SettingsRestored=$true;AutoLogonDisabled=$false;VmOff=$false;CleanupErrors=@();StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
function Save-Cycle([string]$stage){$report.Stage=$stage;$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8}
function Start-Guest {
    $script:vmTouched=$true
    & $control -Action Start -LabId $LabId | Out-Null
    $until=[DateTime]::UtcNow.AddMinutes(5)
    do{
        $status=& $control -Action Status -LabId $LabId | ConvertFrom-Json
        if($status.Guest -and $status.Guest.Ready){return}
        Start-Sleep -Seconds 2
    }while([DateTime]::UtcNow -lt $until)
    throw 'The owned guest did not become ready within five minutes.'
}
function Stop-Guest {
    & $control -Action Stop -LabId $LabId | Out-Null
    $status=& $control -Action Status -LabId $LabId | ConvertFrom-Json
    if($status.State -ne 'Off'){throw 'The owned guest did not shut down.'}
}
function Set-LabLogon([bool]$enabled){
    Invoke-Command -VMId $vm.Id -Credential $credential -ArgumentList $LabId,$enabled,$credential -ScriptBlock {
        param($labId,$enabled,$labCredential)
        $ErrorActionPreference='Stop'
        $ready=Get-Content -LiteralPath 'C:/LaqayLab/ready.json' -Raw | ConvertFrom-Json
        $computer=Get-CimInstance Win32_ComputerSystem
        if($ready.LabId -ne $labId -or $ready.Role -ne 'Primary' -or -not $ready.Ready -or $computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine' -or (Get-CimInstance Win32_OperatingSystem).Caption -notlike '*Windows 11 Enterprise*'){throw 'Refusing logon configuration outside the owned guest.'}
        $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon',$true)
        try{
            if($enabled){
                $key.SetValue('DefaultUserName','LaqayLab',[Microsoft.Win32.RegistryValueKind]::String)
                $key.SetValue('DefaultDomainName',$env:COMPUTERNAME,[Microsoft.Win32.RegistryValueKind]::String)
                # The temporary guest credential is never returned or logged.
                $key.SetValue('DefaultPassword',$labCredential.GetNetworkCredential().Password,[Microsoft.Win32.RegistryValueKind]::String)
                $key.SetValue('AutoLogonCount',3,[Microsoft.Win32.RegistryValueKind]::DWord)
                $key.SetValue('AutoAdminLogon','1',[Microsoft.Win32.RegistryValueKind]::String)
            }else{
                if($key.GetValue('DefaultUserName') -ne 'LaqayLab'){throw 'Unexpected auto-logon user; refusing to change it.'}
                $key.SetValue('AutoAdminLogon','0',[Microsoft.Win32.RegistryValueKind]::String)
                $key.DeleteValue('DefaultPassword',$false);$key.DeleteValue('AutoLogonCount',$false)
                if($key.GetValue('AutoAdminLogon') -ne '0' -or $key.GetValueNames() -contains 'DefaultPassword' -or $key.GetValueNames() -contains 'AutoLogonCount'){throw 'Temporary auto-logon cleanup failed.'}
            }
        }finally{if($key){$key.Dispose()}}
    }
}
function Invoke-Phase([string]$phase){
    Save-Cycle ('Running '+$phase)
    $runId=[guid]::NewGuid().ToString('N')
    $directory=Join-Path $output $phase
    New-Item -ItemType Directory -Path $directory | Out-Null
    $receipt=Join-Path $directory 'rust-work.json'
    $previous=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        & $PythonPath $CoordinatorPath --project laqay-startup-cycle --receipt $receipt --family rust -- (Join-Path $PSHOME 'powershell.exe') -NoProfile -File $suite -LabId $LabId -RunId $runId -CycleId $CycleId -StartupPhase $phase -ExpectedExecutableSha256 $ExpectedExecutableSha256 -OutputDirectory $directory *> (Join-Path $directory 'runtime.log')
        $exitCode=$LASTEXITCODE
    }finally{$ErrorActionPreference=$previous}
    $entryReport=[pscustomobject]@{Phase=$phase;RunId=$runId;ExitCode=$exitCode;Passed=$false;Report=$null}
    $report.Phases+=@($entryReport)
    if(Test-Path -LiteralPath (Join-Path $directory 'host-report.json')){$entryReport.Report=Get-Content -LiteralPath (Join-Path $directory 'host-report.json') -Raw | ConvertFrom-Json}
    $entryReport.Passed=$exitCode -eq 0 -and $entryReport.Report -and $entryReport.Report.Passed -and $entryReport.Report.TaskRemoved
    Save-Cycle ('Finished '+$phase)
    if(-not $entryReport.Passed){throw ('Startup phase failed: '+$phase+'. Inspect its private logs and reports.')}
}
try{
    Save-Cycle 'Starting the owned guest'
    Start-Guest
    $logonArmed=$true
    Set-LabLogon $true
    # Reboot only the owned guest to establish a fresh, bounded lab logon.
    Save-Cycle 'Establishing the initial lab logon';Stop-Guest;Start-Guest
    $settingsTouched=$true;$report.SettingsRestored=$false
    Invoke-Phase 'Enable'
    Save-Cycle 'Booting with startup enabled';Stop-Guest;Start-Guest
    Invoke-Phase 'Verify'
    Save-Cycle 'Booting with startup disabled';Stop-Guest;Start-Guest
    Invoke-Phase 'Absent'
    $report.SettingsRestored=$true
    $report.Passed=$true
}catch{$report.Error=$_.Exception.Message}finally{
    if($vmTouched){
        $current=Get-VM -Id $vm.Id
        if($current.State -eq 'Running'){
            if($settingsTouched -and -not $report.SettingsRestored){try{
                Invoke-Phase 'Cleanup';$report.SettingsRestored=$true
            }catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}}
            if($logonArmed){try{Set-LabLogon $false;$report.AutoLogonDisabled=$true}catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}}
            try{Save-Cycle 'Shutting down the owned guest';Stop-Guest}catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}
        }
        $report.VmOff=(Get-VM -Id $vm.Id).State -eq 'Off'
    }
    if(-not $report.VmOff -or -not $report.AutoLogonDisabled -or -not $report.SettingsRestored){$report.Passed=$false}
    $report.FinishedUtc=[DateTime]::UtcNow.ToString('o');Save-Cycle 'Finished'
}
if(-not $report.Passed){throw ('Startup cycle failed: '+$report.Error+' '+($report.CleanupErrors -join '; '))}
Write-Output 'Real guest login startup passed; settings restored, temporary auto-logon disabled, and VM off.'
