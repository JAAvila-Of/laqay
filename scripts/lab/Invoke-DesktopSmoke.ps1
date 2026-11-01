[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [string]$OutputDirectory,
    [ValidateSet('Explorer','Enable','Verify','Absent','Cleanup')][string]$StartupPhase='Explorer',
    [ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [switch]$StartGuestForStartup,
    [switch]$IncludeUnc,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($PrepareOnly){& (Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly;& (Join-Path $PSScriptRoot 'Invoke-GuestStartup.ps1') -PrepareOnly;return}
if(-not $LabId -or -not $RunId -or -not $ExpectedExecutableSha256 -or -not $OutputDirectory){throw 'Lab/run IDs, expected executable SHA-256, and a private output directory are required.'}
if($StartupPhase -ne 'Explorer' -and -not $CycleId){throw 'A startup cycle identity is required.'}
if($IncludeUnc -and $StartupPhase -ne 'Explorer'){throw 'UNC cases require the Explorer suite.'}
if($StartGuestForStartup -and $StartupPhase -notin @('Verify','Absent')){throw 'Only a real startup verification phase may boot its guest inside the runtime lease.'}
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
$expectedState=if($StartGuestForStartup){'Off'}else{'Running'}
if($vm.State.ToString() -ne $expectedState -or $vm.Name -ne $entry.Name -or $vm.Notes -ne ('Laqay disposable desktop lab '+$LabId)){throw ('The owned lab guest must be '+$expectedState+'.')}
$drives=@(Get-VMHardDiskDrive -VM $vm)
if($drives.Count -ne 1 -or $drives[0].Path -ne $entry.DiskPath){throw 'Unexpected primary guest disk attachment.'}
$credential=Import-Clixml -LiteralPath (Join-Path (Split-Path $entry.DiskPath) 'credential.xml')
$guestRoot='C:\LaqayLab\Runs\'+$RunId
$taskName='Laqay.Smoke.'+$RunId
$session=$null
$registered=$false
$peerSession=$null
$peerCredential=$null
$peerFixtureReserved=$false
$smbVerified=$false
$summary=[ordered]@{LabId=$LabId;RunId=$RunId;StartupPhase=$StartupPhase;CycleId=$CycleId;Passed=$false;Error=$null;GuestReport=$null;TaskRemoved=$false;
    IncludeUnc=[bool]$IncludeUnc;SmbConnection=$null;ServerFilesVerified=$false;ServerFixtureRemoved=(-not $IncludeUnc);CredentialRemoved=(-not $IncludeUnc);CleanupErrors=@();StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath (Join-Path $output 'host-report.json')){throw 'Refusing to reuse an existing host run report.'}
try{
    if($IncludeUnc){
        $peers=@($manifest.VMs | Where-Object Role -eq Peer)
        if($manifest.VMs.Count -ne 2 -or $peers.Count -ne 1 -or $peers[0].Id -eq $entry.Id){throw 'Exactly two distinct owned guests are required for UNC.'}
        $peer=$peers[0];$peerVm=Get-VM -Id ([guid]$peer.Id)
        $peerDisk=Join-Path $root 'vms/Peer/system.vhdx'
        $peerDrives=@(Get-VMHardDiskDrive -VM $peerVm)
        $switch=Get-VMSwitch -Id ([guid]$manifest.SwitchId)
        if($peerVm.State -ne 'Running' -or $peerVm.Name -ne $peer.Name -or $peerVm.Notes -ne ('Laqay disposable desktop lab '+$LabId) -or $peer.DiskPath -ne $peerDisk -or $peerDrives.Count -ne 1 -or $peerDrives[0].Path -ne $peerDisk -or $switch.SwitchType -ne 'Private' -or $switch.Notes -ne ('Laqay disposable desktop lab '+$LabId)){throw 'Unexpected peer ownership or private switch.'}
        foreach($ownedVm in @($vm,$peerVm)){
            $adapters=@(Get-VMNetworkAdapter -VM $ownedVm)
            if($adapters.Count -ne 1 -or $adapters[0].SwitchId -ne $switch.Id){throw 'Unexpected paired guest adapter.'}
        }
        if(@(Get-VM | Where-Object {$_.Id.ToString() -notin @($manifest.VMs.Id)} | Get-VMNetworkAdapter | Where-Object SwitchId -eq $switch.Id).Count){throw 'An unowned guest is attached to the private switch.'}
        $peerCredential=Import-Clixml -LiteralPath (Join-Path (Split-Path $peerDisk) 'credential.xml')
        $peerSession=New-PSSession -VMId $peerVm.Id -Credential $peerCredential
        $peerName=Invoke-Command -Session $peerSession -ArgumentList $LabId,$RunId -ScriptBlock {
            param($labId,$runId)
            $ErrorActionPreference='Stop'
            $ready=Get-Content -LiteralPath 'C:/LaqayLab/ready.json' -Raw | ConvertFrom-Json
            $share=Get-SmbShare -Name LaqayLab
            if($ready.LabId -ne $labId -or $ready.Role -ne 'Peer' -or -not $ready.Ready -or $share.Path -ne 'C:\LaqayLab\Share' -or ((Get-Item -LiteralPath $share.Path).Attributes -band [IO.FileAttributes]::ReparsePoint) -or $env:COMPUTERNAME -notmatch '^LQW11-[A-Z0-9]{8}$'){throw 'Peer share identity mismatch.'}
            if(Test-Path -LiteralPath ('C:\LaqayLab\Share\Paste-'+$runId)){throw 'Refusing an existing server paste fixture.'}
            New-Item -ItemType Directory -Path ('C:\LaqayLab\Share\Paste-'+$runId) | Out-Null
            $env:COMPUTERNAME
        }
        $peerFixtureReserved=$true
        $peerCredential=[PSCredential]::new(($peerName+'\LaqayLab'),$peerCredential.Password)
    }
    if($StartGuestForStartup){
        $control=Join-Path $PSScriptRoot 'Invoke-DesktopTestLab.ps1'
        & $control -Action Start -LabId $LabId | Out-Null
        $bootLimit=[DateTime]::UtcNow.AddMinutes(5)
        do{
            $status=& $control -Action Status -LabId $LabId | ConvertFrom-Json
            if($status.Guest -and $status.Guest.Ready){break}
            Start-Sleep -Seconds 2
        }while([DateTime]::UtcNow -lt $bootLimit)
        if(-not $status.Guest -or -not $status.Guest.Ready){throw 'The startup guest did not become ready within five minutes.'}
    }
    $session=New-PSSession -VMId $vm.Id -Credential $credential
    Invoke-Command -Session $session -ArgumentList $LabId,$RunId,$guestRoot,$StartupPhase -ScriptBlock {
        param($labId,$runId,$runRoot,$startupPhase)
        $ErrorActionPreference='Stop'
        $ready=Get-Content -LiteralPath 'C:/LaqayLab/ready.json' -Raw | ConvertFrom-Json
        if($ready.LabId -ne $labId -or $ready.Role -ne 'Primary' -or -not $ready.Ready){throw 'Guest readiness/identity mismatch.'}
        if($runRoot -ne ('C:\LaqayLab\Runs\'+$runId) -or (Test-Path -LiteralPath $runRoot)){throw 'Unexpected or existing guest run directory.'}
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $acl=Get-Acl -LiteralPath $runRoot
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(($env:COMPUTERNAME+'\LaqayLab'),'Modify','ContainerInherit,ObjectInherit','None','Allow'))
        Set-Acl -LiteralPath $runRoot -AclObject $acl
        if($startupPhase -eq 'Enable'){
            $startupRoot='C:\LaqayLab\Startup'
            New-Item -ItemType Directory -Path $startupRoot -Force | Out-Null
            $acl=Get-Acl -LiteralPath $startupRoot
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(($env:COMPUTERNAME+'\LaqayLab'),'Modify','ContainerInherit,ObjectInherit','None','Allow'))
            Set-Acl -LiteralPath $startupRoot -AclObject $acl
        }
    }
    foreach($file in @('Invoke-GuestDesktopSmoke.ps1','Invoke-GuestStartup.ps1','GuestDesktopControls.cs')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $guestRoot -ToSession $session}
    if($IncludeUnc){
        Invoke-Command -Session $session -ArgumentList $guestRoot,$peerCredential -ScriptBlock {
            param($runRoot,$peerCredential)
            $ErrorActionPreference='Stop'
            if(@(Get-SmbConnection | Where-Object ServerName -eq '10.77.166.11').Count){throw 'Refusing an existing peer connection before the interactive task.'}
            # Encrypt on the guest for the same user that owns the limited interactive task.
            $peerCredential | Export-Clixml -LiteralPath (Join-Path $runRoot 'peer-credential.xml')
        }
    }
    Invoke-Command -Session $session -ArgumentList $LabId,$RunId,$ExpectedExecutableSha256,$guestRoot,$taskName,$StartupPhase,$CycleId,[bool]$IncludeUnc -ScriptBlock {
        param($labId,$runId,$sha,$runRoot,$taskName,$startupPhase,$cycleId,$includeUnc)
        $ErrorActionPreference='Stop'
        $launcher=@'
$ErrorActionPreference='Stop'
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy RemoteSigned -File '@@ROOT@@\@@DRIVER@@' -LabId '@@LAB@@' -RunId '@@RUN@@' -ExpectedExecutableSha256 '@@SHA@@' @@EXTRA@@ *> '@@ROOT@@\console.log'
exit $LASTEXITCODE
'@
        $launcher=$launcher.Replace('@@ROOT@@',$runRoot).Replace('@@LAB@@',$labId).Replace('@@RUN@@',$runId).Replace('@@SHA@@',$sha)
        $driver='Invoke-GuestDesktopSmoke.ps1';$extra=''
        if($startupPhase -ne 'Explorer'){$driver='Invoke-GuestStartup.ps1';$extra="-CycleId '$cycleId' -Phase '$startupPhase'"}
        if($includeUnc){$extra='-IncludeUnc'}
        $launcher=$launcher.Replace('@@DRIVER@@',$driver).Replace('@@EXTRA@@',$extra)
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
        if($IncludeUnc -and $result.Report.UncConnectionReady -and -not $smbVerified){
            $summary.SmbConnection=Invoke-Command -Session $session -ArgumentList $LabId,$RunId,$guestRoot,$peerCredential.UserName -ScriptBlock {
                param($labId,$runId,$runRoot,$peerUser)
                $ErrorActionPreference='Stop'
                $connections=@(Get-SmbConnection | Where-Object {$_.ServerName -eq '10.77.166.11' -and $_.ShareName -eq 'LaqayLab'})
                if($connections.Count -ne 1 -or -not $connections[0].Signed -or $connections[0].UserName -ne ($env:COMPUTERNAME+'\LaqayLab') -or $connections[0].Credential -ne $peerUser){throw 'The limited user does not have the expected signed, authenticated peer connection.'}
                $proof=[pscustomobject]@{LabId=$labId;RunId=$runId;Signed=$true;UserName=$connections[0].UserName;Credential=$connections[0].Credential;Dialect=[string]$connections[0].Dialect}
                $proofPath=Join-Path $runRoot 'smb-proof.json'
                if(Test-Path -LiteralPath $proofPath){throw 'Refusing an existing SMB verification file.'}
                $temporary=Join-Path $runRoot 'smb-proof.tmp'
                $proof | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
                Move-Item -LiteralPath $temporary -Destination $proofPath
                $proof
            }
            $smbVerified=$true
        }
        if($result.Report -and $result.Report.FinishedUtc -and $result.State -ne 'Running'){break}
        if($result.State -eq 'Ready' -and $result.LastResult -ne 267009 -and $result.LastResult -ne 267011 -and $result.LastResult -ne 0){throw ('Guest task failed before completing its report: '+$result.LastResult)}
        Start-Sleep -Seconds 1
    }while([DateTime]::UtcNow -lt $limit)
    if(-not $result.Report -or -not $result.Report.FinishedUtc){throw 'The guest smoke suite did not finish within its deadline.'}
    $guest=$result.Report
    if($StartupPhase -ne 'Explorer'){
        $required=switch($StartupPhase){
            Enable {@('StartupRegistered')}
            Verify {@('LaunchedAtLogin','StartupImagePaste','StartupDisabled')}
            Absent {@('NoStartupWithinObservationWindow','SettingsRestored')}
            Cleanup {@('SettingsRestored')}
        }
        $names=@($guest.Cases | ForEach-Object Name)
        if($guest.LabId -ne $LabId -or $guest.RunId -ne $RunId -or $guest.CycleId -ne $CycleId -or $guest.Phase -ne $StartupPhase -or $guest.ExecutableSha256 -ne $ExpectedExecutableSha256 -or -not $guest.Passed -or -not $guest.ApplicationClosed -or $guest.ApplicationExitCode -ne 0 -or $guest.ForcedTermination -or $guest.SessionId -le 0 -or @($guest.CleanupErrors).Count -ne 0 -or @($guest.Cases).Count -ne @($required).Count -or @(Compare-Object @($required) $names).Count -ne 0 -or @($guest.Cases | Where-Object {-not $_.Passed}).Count -ne 0 -or $result.LastResult -ne 0){throw ('Startup validation failed: '+$guest.Error)}
        if($StartupPhase -in @('Enable','Verify') -and -not $guest.ApplicationStarted){throw 'The startup phase did not own its application.'}
        if($StartupPhase -in @('Absent','Cleanup') -and -not $guest.SettingsRestored){throw 'Startup settings were not restored.'}
        if($StartupPhase -eq 'Absent' -and $guest.ObservationSeconds -lt 180){throw 'The disabled observation window was incomplete.'}
    }else{
    $required=@('ImagePaste','CollisionPreservation','NativeFilePaste','AddressBarText','SearchText','RenameText','DisabledImageDoesNotSave','ReenabledImageSaves','ActiveTabSelection','UnicodePathImagePaste','ClipboardPreservedAfterImagePaste','ActiveWindowSelection','DeniedWriteRecovery')
    if($IncludeUnc){$required+=@('UncImagePaste','UncExistingImagePreserved','UncNativeFilePaste')}
    $names=@($guest.Cases | ForEach-Object Name)
    if(-not $guest.PermissionsRestored){throw 'Guest fixture permissions were not restored.'}
    if($guest.LabId -ne $LabId -or $guest.RunId -ne $RunId -or -not $guest.Passed -or -not $guest.ApplicationClosed -or -not $guest.PreferencesRestored -or $guest.SessionId -le 0 -or $guest.ForcedTermination -or @($guest.CleanupErrors).Count -ne 0 -or @($guest.Cases).Count -ne $required.Count -or @(Compare-Object $required $names).Count -ne 0 -or @($guest.Cases | Where-Object { -not $_.Passed }).Count -ne 0 -or $result.LastResult -ne 0){throw ('Guest validation failed: '+$guest.Error)}
    }
    if($IncludeUnc){
        if(-not $smbVerified -or -not $guest.IncludeUnc -or -not $guest.SmbSigned -or -not $guest.PeerDisconnected -or -not $guest.CredentialRemoved -or $guest.UncFiles.Count -ne 3 -or $guest.ApplicationExitCode -ne 0){throw 'UNC cleanup, signed connection, or application exit validation failed.'}
        $verified=Invoke-Command -Session $peerSession -ArgumentList $RunId,@($guest.UncFiles) -ScriptBlock {
            param($runId,$files)
            $ErrorActionPreference='Stop'
            $fixture='C:\LaqayLab\Share\Paste-'+$runId
            if(((Get-Item -LiteralPath $fixture).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected server fixture reparse point.'}
            $directories=@(Get-ChildItem -LiteralPath $fixture -Force)
            if($directories.Count -ne 2 -or @($directories | Where-Object {-not $_.PSIsContainer -or $_.Name -notin @('images','files') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Unexpected server fixture directories.'}
            $all=@($directories)
            foreach($directory in $directories){$all+=@(Get-ChildItem -LiteralPath $directory.FullName -Force)}
            if($all.Count -ne 5 -or @($all | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count -or @($all | Where-Object {-not $_.PSIsContainer}).Count -ne 3){throw 'Unexpected server fixture contents.'}
            $names=@($files.RelativePath)
            if(@($names | Select-Object -Unique).Count -ne 3 -or @($names | Where-Object {$_ -notmatch '^(images\\Screenshot_\d{8}_\d{6}(_\d{3,})?\.png|files\\two\.bin)$'}).Count -or @($names | Where-Object {$_ -like 'images\*'}).Count -ne 2 -or $names -notcontains 'files\two.bin'){throw 'Unexpected server fixture paths.'}
            foreach($file in $files){if((Get-FileHash -LiteralPath (Join-Path $fixture $file.RelativePath) -Algorithm SHA256).Hash -ne $file.Sha256){throw 'Server and interactive client hashes differ.'}}
            $true
        }
        if(-not $verified){throw 'Server verification did not complete.'}
        $summary.ServerFilesVerified=$true
    }
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
        if($IncludeUnc){
            try{
                $summary.CredentialRemoved=Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {
                    param($runRoot)
                    $path=Join-Path $runRoot 'peer-credential.xml'
                    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -ErrorAction Stop}
                    -not (Test-Path -LiteralPath $path)
                }
                if(-not $summary.CredentialRemoved){throw 'Guest peer credential cleanup failed.'}
            }catch{$summary.CleanupErrors+=@($_.Exception.Message);$summary.Passed=$false}
        }
        try{
            if($IncludeUnc -and -not $summary.CredentialRemoved){throw 'Refusing to collect output while the credential remains.'}
            Copy-Item -Path ($guestRoot+'\*') -Destination $output -FromSession $session -Recurse
        }catch{$summary.CleanupErrors+=@($_.Exception.Message);$summary.Passed=$false}
        Remove-PSSession -Session $session
    }
    if($peerSession -and $peerFixtureReserved){
        try{
            $summary.ServerFixtureRemoved=Invoke-Command -Session $peerSession -ArgumentList $RunId -ScriptBlock {
                param($runId)
                $ErrorActionPreference='Stop'
                $fixture='C:\LaqayLab\Share\Paste-'+$runId
                if(Test-Path -LiteralPath $fixture){
                    if(((Get-Item -LiteralPath $fixture).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Refusing a server fixture reparse point.'}
                    $directories=@(Get-ChildItem -LiteralPath $fixture -Force)
                    if(@($directories | Where-Object {-not $_.PSIsContainer -or $_.Name -notin @('images','files') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Refusing unexpected server directories.'}
                    $all=@($directories)
                    foreach($directory in $directories){
                        $children=@(Get-ChildItem -LiteralPath $directory.FullName -Force)
                        if(@($children | Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Refusing nested server directories or reparse points.'}
                        $all+=@($children)
                    }
                    foreach($item in @((Get-Item -LiteralPath $fixture))+$all){
                        $relative=$item.FullName.Substring($fixture.Length)
                        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($relative -and $relative -notmatch '^\\(images|files)(\\(Screenshot_\d{8}_\d{6}(_\d{3,})?\.png|two\.bin))?$')){throw 'Refusing to delete unexpected server contents.'}
                    }
                    foreach($item in @($all | Where-Object {-not $_.PSIsContainer})){Remove-Item -LiteralPath $item.FullName}
                    foreach($item in @($all | Where-Object PSIsContainer | Sort-Object {$_.FullName.Length} -Descending)){[IO.Directory]::Delete($item.FullName)}
                    [IO.Directory]::Delete($fixture)
                }
                -not (Test-Path -LiteralPath $fixture)
            }
            if(-not $summary.ServerFixtureRemoved){throw 'Server fixture cleanup failed.'}
        }catch{$summary.CleanupErrors+=@($_.Exception.Message);$summary.Passed=$false}
    }
    if($peerSession){Remove-PSSession -Session $peerSession}
    $summary.FinishedUtc=[DateTime]::UtcNow.ToString('o')
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'host-report.json') -Encoding UTF8
}
if(-not $summary.Passed){throw ('Guest smoke validation failed: '+$summary.Error+' '+($summary.CleanupErrors -join '; '))}
Write-Output ('Guest suite passed: '+$StartupPhase+'. Owned applications exited and the guest task was removed.')
