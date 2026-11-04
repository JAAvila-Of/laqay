[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [Parameter(Mandatory=$true)][ValidateSet('Boot','Old','New','Enable','Verify','Absent','Removed','Adverse')][string]$Phase,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$IncludeRealApplications
)
$ErrorActionPreference='Stop'
if($IncludeRealApplications -and $Phase -ne 'Adverse'){throw 'Real applications require the explicit adverse phase.'}
if(-not $env:RUST_WORK_JOB){throw 'A RustWork runtime lease is required before any guest boot or application suite.'}
$control=Join-Path $PSScriptRoot 'Invoke-DesktopTestLab.ps1'
$suite=Join-Path $PSScriptRoot 'Invoke-DesktopSmoke.ps1'
$report=[ordered]@{LabId=$LabId;CycleId=$CycleId;Phase=$Phase;IncludeRealApplications=[bool]$IncludeRealApplications;Passed=$false;BootPerformed=$false;Suites=@();Error=$null}
$reportPath=Join-Path $OutputDirectory 'phase-report.json'
if(Test-Path -LiteralPath $reportPath){throw 'Refusing a reused runtime phase.'}
function Run-Suite([string]$name,[hashtable]$extra){
    $runId=[guid]::NewGuid().ToString('N');$destination=Join-Path $OutputDirectory $name
    & $suite -LabId $LabId -RunId $runId -CycleId $CycleId -ExpectedExecutableSha256 $ExpectedExecutableSha256 -OutputDirectory $destination @extra | Out-Null
    $result=Get-Content -LiteralPath (Join-Path $destination 'host-report.json') -Raw | ConvertFrom-Json
    $report.Suites+=@($result)
    if(-not $result.Passed -or -not $result.TaskRemoved -or $result.TaskStopped -or $result.GuestReport.ExecutableSha256 -ne $ExpectedExecutableSha256 -or $result.GuestReport.ApplicationExitCode -ne 0){throw ('Published-package suite failed: '+$name)}
}
try{
    $status=& $control -Action Status -LabId $LabId | ConvertFrom-Json
    if($status.State -eq 'Off'){
        & $control -Action Start -LabId $LabId | Out-Null
        $report.BootPerformed=$true
    }elseif($status.State -ne 'Running'){throw 'The owned guest must be off or running.'}
    $limit=[DateTime]::UtcNow.AddMinutes(5)
    do{
        $status=& $control -Action Status -LabId $LabId | ConvertFrom-Json
        if($status.Guest -and $status.Guest.Ready){break};Start-Sleep -Seconds 2
    }while([DateTime]::UtcNow -lt $limit)
    if(-not $status.Guest -or -not $status.Guest.Ready){throw 'The owned guest did not become ready.'}
    if(([long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory*1KB) -lt 3GB){throw 'The host memory reserve is below three GiB.'}
    switch($Phase){
        Boot {
            # Recovery can follow a failed enabled-startup phase. Close only an app
            # that the existing startup driver can adopt with its recorded identity.
            $labRoot=Join-Path $env:LOCALAPPDATA ('LaqayTestLab/'+$LabId)
            $credential=Import-Clixml -LiteralPath (Join-Path $labRoot 'vms/Primary/credential.xml')
            $manifest=Get-Content -LiteralPath (Join-Path $labRoot 'lab.json') -Raw | ConvertFrom-Json
            $entry=@($manifest.VMs | Where-Object Role -eq Primary)[0]
            $startupState=Invoke-Command -VMId ([guid]$entry.Id) -Credential $credential -ArgumentList $LabId,$CycleId -ScriptBlock {
                param($labId,$cycleId)
                $ready=Get-Content -LiteralPath 'C:\LaqayLab\ready.json' -Raw | ConvertFrom-Json
                if($ready.LabId -ne $labId -or $ready.Role -ne 'Primary' -or -not $ready.Ready){throw 'Unexpected recovery guest.'}
                $path='C:\LaqayLab\Startup\'+$cycleId+'\state.json'
                if(Test-Path -LiteralPath $path){-not (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Restored}else{$false}
            }
            if($startupState){Run-Suite 'startup-cleanup' @{StartupPhase='Cleanup'}}
            $remaining=Invoke-Command -VMId ([guid]$entry.Id) -Credential $credential -ScriptBlock {@(Get-Process laqay -ErrorAction SilentlyContinue).Count}
            if($remaining -ne 0){throw 'A guest application remained after the boot-only phase.'}
        }
        Old {Run-Suite 'explorer' @{};Run-Suite 'portable' @{PortablePhase='Old'}}
        New {Run-Suite 'portable' @{PortablePhase='New'};Run-Suite 'explorer' @{}}
        Enable {Run-Suite 'startup' @{StartupPhase='Enable'}}
        Verify {Run-Suite 'startup' @{StartupPhase='Verify'}}
        Absent {Run-Suite 'startup' @{StartupPhase='Absent'}}
        Removed {Run-Suite 'portable' @{PortablePhase='Removed'}}
        Adverse {Run-Suite 'adverse' @{IncludeAdverse=$true;IncludeRealApplications=[bool]$IncludeRealApplications}}
    }
    $report.Passed=$true
}catch{
    $report.Error=$_.Exception.Message
    # Do not release the Rust runtime lease with an unaccounted guest app alive.
    try{& $control -Action Stop -LabId $LabId | Out-Null}catch{$report.Error+='; Guest shutdown failed: '+$_.Exception.Message}
}finally{
    $report | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
if(-not $report.Passed){throw ('Portable runtime phase failed: '+$report.Error)}
