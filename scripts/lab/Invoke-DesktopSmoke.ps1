[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [string]$OutputDirectory,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($PrepareOnly){& (Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly;return}
if(-not $LabId -or -not $RunId -or -not $ExpectedExecutableSha256 -or -not $OutputDirectory){throw 'Lab/run IDs, expected executable SHA-256, and a private output directory are required.'}
if(-not $env:RUST_WORK_JOB){throw 'Run the Rust application suite through the shared RustWork coordinator with --family rust.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An authorized administrator process is required for PowerShell Direct.'}
$root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA ('LaqayTestLab/'+$LabId)))
$manifest=Get-Content -LiteralPath (Join-Path $root 'lab.json') -Raw | ConvertFrom-Json
if($manifest.Kind -ne 'LaqayDesktopTestLab' -or $manifest.LabId -ne $LabId -or $manifest.Root -ne $root){throw 'Invalid lab ownership manifest.'}
$entry=@($manifest.VMs | Where-Object Role -eq Primary)
if($entry.Count -ne 1){throw 'Exactly one owned primary guest is required.'}
$entry=$entry[0]
$expectedDisk=Join-Path $root 'vms/Primary/system.vhdx'
if([IO.Path]::GetFullPath($entry.DiskPath) -ne [IO.Path]::GetFullPath($expectedDisk)){throw 'Unexpected primary disk path.'}
$vm=Get-VM -Id ([guid]$entry.Id)
if($vm.State -ne 'Running' -or $vm.Name -ne $entry.Name -or $vm.Notes -ne ('Laqay disposable desktop lab '+$LabId)){throw 'The owned lab guest must already be running.'}
$drives=@(Get-VMHardDiskDrive -VM $vm)
if($drives.Count -ne 1 -or $drives[0].Path -ne $entry.DiskPath){throw 'Unexpected primary guest disk attachment.'}
$credential=Import-Clixml -LiteralPath (Join-Path (Split-Path $entry.DiskPath) 'credential.xml')
$guestRoot='C:\LaqayLab\Runs\'+$RunId
$taskName='Laqay.Smoke.'+$RunId
$session=$null
$registered=$false
$summary=[ordered]@{LabId=$LabId;RunId=$RunId;Passed=$false;Error=$null;GuestReport=$null;TaskRemoved=$false;CleanupErrors=@();StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath (Join-Path $output 'host-report.json')){throw 'Refusing to reuse an existing host run report.'}
try{
    $session=New-PSSession -VMId $vm.Id -Credential $credential
    Invoke-Command -Session $session -ArgumentList $LabId,$RunId,$guestRoot -ScriptBlock {
        param($labId,$runId,$runRoot)
        $ErrorActionPreference='Stop'
        $ready=Get-Content -LiteralPath 'C:/LaqayLab/ready.json' -Raw | ConvertFrom-Json
        if($ready.LabId -ne $labId -or $ready.Role -ne 'Primary' -or -not $ready.Ready){throw 'Guest readiness/identity mismatch.'}
        if($runRoot -ne ('C:\LaqayLab\Runs\'+$runId) -or (Test-Path -LiteralPath $runRoot)){throw 'Unexpected or existing guest run directory.'}
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $acl=Get-Acl -LiteralPath $runRoot
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(($env:COMPUTERNAME+'\LaqayLab'),'Modify','ContainerInherit,ObjectInherit','None','Allow'))
        Set-Acl -LiteralPath $runRoot -AclObject $acl
    }
    foreach($file in @('Invoke-GuestDesktopSmoke.ps1','GuestDesktopControls.cs')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $guestRoot -ToSession $session}
    Invoke-Command -Session $session -ArgumentList $LabId,$RunId,$ExpectedExecutableSha256,$guestRoot,$taskName -ScriptBlock {
        param($labId,$runId,$sha,$runRoot,$taskName)
        $ErrorActionPreference='Stop'
        $launcher=@'
$ErrorActionPreference='Stop'
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy RemoteSigned -File '@@ROOT@@\Invoke-GuestDesktopSmoke.ps1' -LabId '@@LAB@@' -RunId '@@RUN@@' -ExpectedExecutableSha256 '@@SHA@@' *> '@@ROOT@@\console.log'
exit $LASTEXITCODE
'@
        $launcher=$launcher.Replace('@@ROOT@@',$runRoot).Replace('@@LAB@@',$labId).Replace('@@RUN@@',$runId).Replace('@@SHA@@',$sha)
        Set-Content -LiteralPath (Join-Path $runRoot 'Launch.ps1') -Value $launcher -Encoding UTF8
        if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'Refusing to replace an existing task.'}
        $action=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ('-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$runRoot+'\Launch.ps1"')
        $principal=New-ScheduledTaskPrincipal -UserId ($env:COMPUTERNAME+'\LaqayLab') -LogonType Interactive -RunLevel Limited
        $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(7)) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
    }
    $registered=$true
    Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {param($taskName) Start-ScheduledTask -TaskName $taskName}
    $limit=[DateTime]::UtcNow.AddMinutes(8)
    $result=$null
    do{
        $result=Invoke-Command -Session $session -ArgumentList $guestRoot,$taskName -ScriptBlock {
            param($runRoot,$taskName)
            $ErrorActionPreference='Stop'
            $task=Get-ScheduledTask -TaskName $taskName
            $info=Get-ScheduledTaskInfo -TaskName $taskName
            $report=$null
            $path=Join-Path $runRoot 'report.json'
            if(Test-Path -LiteralPath $path){try{$report=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json}catch{}}
            [pscustomobject]@{State=$task.State.ToString();LastResult=$info.LastTaskResult;Report=$report}
        }
        $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'progress.json') -Encoding UTF8
        if($result.Report -and $result.Report.FinishedUtc -and $result.State -ne 'Running'){break}
        if($result.State -eq 'Ready' -and $result.LastResult -ne 267009 -and $result.LastResult -ne 267011 -and $result.LastResult -ne 0){throw ('Guest task failed before completing its report: '+$result.LastResult)}
        Start-Sleep -Seconds 1
    }while([DateTime]::UtcNow -lt $limit)
    if(-not $result.Report -or -not $result.Report.FinishedUtc){throw 'The guest smoke suite did not finish within its deadline.'}
    $guest=$result.Report
    $required=@('ImagePaste','CollisionPreservation','NativeFilePaste','AddressBarText','SearchText','RenameText','DisabledImageDoesNotSave','ReenabledImageSaves','ActiveTabSelection')
    $names=@($guest.Cases | ForEach-Object Name)
    if($guest.LabId -ne $LabId -or $guest.RunId -ne $RunId -or -not $guest.Passed -or -not $guest.ApplicationClosed -or -not $guest.PreferencesRestored -or $guest.SessionId -le 0 -or $guest.ForcedTermination -or @($guest.CleanupErrors).Count -ne 0 -or @($guest.Cases).Count -ne $required.Count -or @(Compare-Object $required $names).Count -ne 0 -or @($guest.Cases | Where-Object { -not $_.Passed }).Count -ne 0 -or $result.LastResult -ne 0){throw ('Guest validation failed: '+$guest.Error)}
    $summary.GuestReport=$guest
    $summary.Passed=$true
}catch{$summary.Error=$_.Exception.Message}finally{
    if($session){
        try{
            if($registered){
            Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {
                param($taskName)
                $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if($task){if($task.State -eq 'Running'){Stop-ScheduledTask -TaskName $taskName};Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
            }
            $summary.TaskRemoved=$true
            }
        }catch{$summary.CleanupErrors+=@($_.Exception.Message);$summary.Passed=$false}
        try{Copy-Item -Path ($guestRoot+'\*') -Destination $output -FromSession $session -Recurse}catch{$summary.CleanupErrors+=@($_.Exception.Message);$summary.Passed=$false}
        Remove-PSSession -Session $session
    }
    $summary.FinishedUtc=[DateTime]::UtcNow.ToString('o')
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'host-report.json') -Encoding UTF8
}
if(-not $summary.Passed){throw ('Guest smoke validation failed: '+$summary.Error+' '+($summary.CleanupErrors -join '; '))}
Write-Output 'All nine guest Explorer smoke cases passed; the owned application exited and the guest task was removed.'
