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
    [switch]$IncludeLifecycle,
    [switch]$IncludeAdverse,
    [ValidateSet('Old','New','Removed')][string]$PortablePhase,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($PrepareOnly){& (Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly;& (Join-Path $PSScriptRoot 'Invoke-GuestStartup.ps1') -PrepareOnly;& (Join-Path $PSScriptRoot 'Invoke-GuestPortableSession.ps1') -PrepareOnly;return}
if($IncludeAdverse -and ($IncludeUnc -or $IncludeLifecycle -or $PortablePhase -or $StartupPhase -ne 'Explorer')){throw 'Adverse cases require a separate console Explorer suite.'}
if($PortablePhase -and (-not $CycleId -or $StartupPhase -ne 'Explorer' -or $IncludeUnc -or $IncludeLifecycle -or $StartGuestForStartup)){throw 'Portable phases require their own cycle and running console guest.'}
if(-not $LabId -or -not $RunId -or -not $ExpectedExecutableSha256 -or -not $OutputDirectory){throw 'Lab/run IDs, expected executable SHA-256, and a private output directory are required.'}
if($StartupPhase -ne 'Explorer' -and -not $CycleId){throw 'A startup cycle identity is required.'}
if($IncludeUnc -and $StartupPhase -ne 'Explorer'){throw 'UNC cases require the Explorer suite.'}
if($IncludeLifecycle -and ($IncludeUnc -or $StartupPhase -ne 'Explorer')){throw 'Lifecycle cases require a separate console Explorer suite.'}
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
$pendingVerified=$false
$summary=[ordered]@{LabId=$LabId;RunId=$RunId;StartupPhase=$StartupPhase;CycleId=$CycleId;Passed=$false;Error=$null;GuestReport=$null;TaskRemoved=$false;TaskStopped=$false;
    IncludeLifecycle=[bool]$IncludeLifecycle;PendingWaitProof=$null;IncludeUnc=[bool]$IncludeUnc;SmbConnection=$null;ServerFilesVerified=$false;ServerFixtureRemoved=(-not $IncludeUnc);CredentialRemoved=(-not $IncludeUnc);CleanupErrors=@();StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
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
    foreach($file in @('Invoke-GuestDesktopSmoke.ps1','Invoke-GuestStartup.ps1','Invoke-GuestPortableSession.ps1','Invoke-GuestAdverseCases.ps1','GuestDesktopControls.cs','GuestLifecycleControls.cs','GuestAdverseControls.cs')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $guestRoot -ToSession $session}
    if($IncludeUnc){
        Invoke-Command -Session $session -ArgumentList $guestRoot,$peerCredential -ScriptBlock {
            param($runRoot,$peerCredential)
            $ErrorActionPreference='Stop'
            if(@(Get-SmbConnection | Where-Object ServerName -eq '10.77.166.11').Count){throw 'Refusing an existing peer connection before the interactive task.'}
            # Encrypt on the guest for the same user that owns the limited interactive task.
            $peerCredential | Export-Clixml -LiteralPath (Join-Path $runRoot 'peer-credential.xml')
        }
    }
    Invoke-Command -Session $session -ArgumentList @($LabId,$RunId,$ExpectedExecutableSha256,$guestRoot,$taskName,$StartupPhase,$CycleId,([bool]$IncludeUnc),([bool]$IncludeLifecycle),$PortablePhase,([bool]$IncludeAdverse)) -ScriptBlock {
        param($labId,$runId,$sha,$runRoot,$taskName,$startupPhase,$cycleId,$includeUnc,$includeLifecycle,$portablePhase,$includeAdverse)
        $ErrorActionPreference='Stop'
        if($includeUnc -isnot [bool] -or $includeLifecycle -isnot [bool]){throw 'Guest launch options must be Boolean values.'}
        if($includeAdverse -isnot [bool]){throw 'The adverse option must be Boolean.'}
        $launcher=@'
$ErrorActionPreference='Stop'
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy RemoteSigned -File '@@ROOT@@\@@DRIVER@@' -LabId '@@LAB@@' -RunId '@@RUN@@' -ExpectedExecutableSha256 '@@SHA@@' @@EXTRA@@ *> '@@ROOT@@\console.log'
exit $LASTEXITCODE
'@
        $launcher=$launcher.Replace('@@ROOT@@',$runRoot).Replace('@@LAB@@',$labId).Replace('@@RUN@@',$runId).Replace('@@SHA@@',$sha)
        $driver='Invoke-GuestDesktopSmoke.ps1';$extra=''
        if($startupPhase -ne 'Explorer'){$driver='Invoke-GuestStartup.ps1';$extra="-CycleId '$cycleId' -Phase '$startupPhase'"}
        if($includeUnc){$extra='-IncludeUnc'}
        if($includeLifecycle){$extra='-IncludeLifecycle'}
        if($includeAdverse){$extra='-IncludeAdverse'}
        if($portablePhase){$driver='Invoke-GuestPortableSession.ps1';$extra="-CycleId '$cycleId' -Phase '$portablePhase'"}
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
        if(($IncludeLifecycle -or $IncludeAdverse) -and $result.Report.PendingClipboard.Requested -and -not $result.Report.ProviderStopped -and -not $result.Report.FinishedUtc -and -not $pendingVerified){
            $pending=$result.Report.PendingClipboard
            $proofJson=Invoke-Command -Session $session -ArgumentList $LabId,$RunId,$guestRoot,$result.Report.ApplicationPid,$pending.ProviderPid,$pending.ProviderThreadId,$result.Report.SessionId -ScriptBlock {
                param($labId,$runId,$runRoot,$appPid,$providerPid,$providerThread,$sessionId)
                $ErrorActionPreference='Stop'
                if(-not ('LaqayGuestWaitChain' -as [type])){
                    Add-Type -AssemblyName System.Windows.Forms,System.Drawing,System.Management,System.Web.Extensions,UIAutomationClient,UIAutomationTypes,WindowsBase
                    $references=@([Windows.Forms.Clipboard].Assembly.Location,[Drawing.Bitmap].Assembly.Location,[Management.ManagementObjectSearcher].Assembly.Location,
                        [Web.Script.Serialization.JavaScriptSerializer].Assembly.Location,[Windows.Automation.AutomationElement].Assembly.Location,
                        [Windows.Automation.ControlType].Assembly.Location,[Windows.Rect].Assembly.Location,[Diagnostics.Process].Assembly.Location,'System.Core.dll') | Select-Object -Unique
                    Add-Type -Path @((Join-Path $runRoot 'GuestDesktopControls.cs'),(Join-Path $runRoot 'GuestLifecycleControls.cs')) -ReferencedAssemblies $references
                }
                [LaqayGuestWaitChain]::InspectJson($labId,$runId,$appPid,$providerPid,$providerThread,$sessionId)
            }
            $proof=$proofJson | ConvertFrom-Json
            $proofJson | Set-Content -LiteralPath (Join-Path $output ('pending-wait-chain-'+[DateTime]::UtcNow.Ticks+'.json')) -Encoding UTF8
            if(-not $proof.ProcessExited){$proofJson | Set-Content -LiteralPath (Join-Path $output 'pending-wait-chain.json') -Encoding UTF8}
            if($proof.Confirmed){
                $summary.PendingWaitProof=$proof
                Invoke-Command -Session $session -ArgumentList $guestRoot,$proof -ScriptBlock {
                    param($runRoot,$proof)
                    $path=Join-Path $runRoot 'pending-proof.json';if(Test-Path -LiteralPath $path){throw 'Refusing a repeated pending-work proof.'}
                    $proof | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ($path+'.tmp') -Encoding UTF8
                    Move-Item -LiteralPath ($path+'.tmp') -Destination $path
                }
                $pendingVerified=$true
            }
        }
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
    if($PortablePhase){
        $required=switch($PortablePhase){Old {@('OldDisabledPreference','OldStartupRoundTrip')} New {@('UpgradePreservesDisabled','UpgradeImagePaste')} Removed {@('RemovedStaysAbsent')}}
        $names=@($guest.Cases | ForEach-Object Name)
        if($guest.LabId -ne $LabId -or $guest.RunId -ne $RunId -or $guest.CycleId -ne $CycleId -or $guest.Phase -ne $PortablePhase -or $guest.ExecutableSha256 -ne $ExpectedExecutableSha256 -or -not $guest.Passed -or -not $guest.ApplicationClosed -or $guest.ApplicationExitCode -ne 0 -or $guest.ForcedTermination -or $guest.SessionId -le 0 -or @($guest.CleanupErrors).Count -or @($guest.Cases).Count -ne @($required).Count -or @(Compare-Object @($required) $names).Count -or @($guest.Cases | Where-Object {-not $_.Passed}).Count -or $result.LastResult -ne 0){throw ('Portable session validation failed: '+$guest.Error)}
        if($PortablePhase -ne 'Removed' -and -not $guest.ApplicationStarted){throw 'The portable phase did not own its application.'}
        if($PortablePhase -eq 'Removed' -and $guest.ObservationSeconds -lt 180){throw 'The removed-package observation was incomplete.'}
    }elseif($StartupPhase -ne 'Explorer'){
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
    if($IncludeLifecycle){$required+=@('ExplorerRestartRecovery','ExitWithPendingClipboard')}
    if($IncludeAdverse){$required+=@('EmptyClipboardNoOutput','LockedClipboardRecovery','PngAlphaExact','LargePngResponsive','HeldPasteSingleImage','RapidPastePreservesImages','SecondInstanceExits','VirtualFolderDeclines','NativeEditNativeText','NativeEditImageDoesNotWrite','RichEditNativeText','RichEditImageDoesNotWrite','IdleResponsivenessSample','SerialPasteResourceSample','RenderedPngReferencePaste','TabSwitchCancelsPendingImage')}
    $names=@($guest.Cases | ForEach-Object Name)
    if(-not $guest.PermissionsRestored){throw 'Guest fixture permissions were not restored.'}
    if($guest.LabId -ne $LabId -or $guest.RunId -ne $RunId -or -not $guest.Passed -or -not $guest.ApplicationClosed -or -not $guest.PreferencesRestored -or $guest.SessionId -le 0 -or $guest.ForcedTermination -or @($guest.CleanupErrors).Count -ne 0 -or @($guest.Cases).Count -ne $required.Count -or @(Compare-Object $required $names).Count -ne 0 -or @($guest.Cases | Where-Object { -not $_.Passed }).Count -ne 0 -or $result.LastResult -ne 0){throw ('Guest validation failed: '+$guest.Error)}
    if($IncludeLifecycle -and (-not $pendingVerified -or -not $summary.PendingWaitProof.Confirmed -or -not $guest.IncludeLifecycle -or -not $guest.PendingWaitVerified -or -not $guest.ProviderStopped -or $guest.SessionProtocol -ne 0 -or $guest.ApplicationExitCode -ne 0 -or $guest.ExecutableSha256 -ne $ExpectedExecutableSha256 -or -not $guest.ExplorerRestart.IconRegistered -or -not $guest.ExplorerRestart.ImageVerified -or $guest.ExplorerRestart.ApplicationPid -ne $guest.ApplicationPid -or $guest.ExplorerRestart.OldPid -le 0 -or $guest.ExplorerRestart.NewPid -le 0 -or $guest.ExplorerRestart.OldPid -eq $guest.ExplorerRestart.NewPid)){throw 'The exact lifecycle cases and pending-work proof did not pass.'}
    if($IncludeAdverse -and (-not $guest.IncludeAdverse -or -not $guest.AdverseFixturesClosed -or $guest.ApplicationExitCode -ne 0 -or $guest.ExecutableSha256 -ne $ExpectedExecutableSha256 -or $guest.ResourceSamples.Count -ne 4 -or $guest.SecondInstance.ExitCode -ne 0 -or $guest.SecondInstance.Forced -or $guest.SecondInstance.OriginalPid -ne $guest.ApplicationPid)){throw 'The complete adverse suite, resources, or owned-fixture cleanup did not pass.'}
    if($IncludeAdverse){
        $race=$guest.TabClipboardRace;$proof=$summary.PendingWaitProof
        if(-not $pendingVerified -or -not $proof.Confirmed -or -not $guest.PendingWaitVerified -or -not $guest.ProviderStopped -or $guest.SessionProtocol -ne 0 -or -not $race.SameWindow -or -not $race.TabChanged -or -not $race.FenceVerified -or -not $race.OriginalFoldersEmpty -or -not $race.FreshPasteVerified -or -not $race.ProviderStopped){throw 'The held clipboard tab-switch proof and recovery are incomplete.'}
        foreach($state in @($race.Reference,$race.AfterRender,$race.AfterFence)){
            if(-not $state.Requested -or -not $state.Released -or -not $state.Rendered -or -not $state.OwnerMatches -or $state.PayloadBytes -le 0 -or $state.Sequence -ne $state.PublishedSequence -or $state.Error -or $state.TimedOut){throw 'The delayed PNG did not supply valid bytes with unchanged clipboard sequence.'}
        }
        foreach($state in @($race.BeforeSwitch,$race.AfterSwitch)){
            if(-not $state.Requested -or $state.Released -or $state.Rendered -or -not $state.OwnerMatches -or $state.Error -or $state.TimedOut -or $state.Sequence -ne $state.PublishedSequence -or $state.ProviderPid -ne $proof.ProviderPid -or $state.ProviderThreadId -ne $proof.ProviderThreadId -or $proof.ApplicationPid -ne $guest.ApplicationPid -or $proof.SessionId -ne $guest.SessionId){throw 'The observed clipboard barrier did not survive the tab switch.'}
        }
        if(@($guest.EditorSenderComparison).Count -ne 0){throw 'An editor failure required a diagnostic comparison; it is not a passing suite.'}
        if(@($guest.ReferenceHookProof).Count -ne 0){throw 'A passive-hook diagnostic cannot replace an editor failure.'}
        $imagePastes=@($guest.ImagePastes)
        if($imagePastes.Count -eq 0){throw 'The Explorer image paste observations are missing.'}
        foreach($entry in $imagePastes){
            if(-not $entry.Published -or $entry.Error -or $entry.ObservedPngCount -ne $entry.ExpectedCount -or -not $entry.Before -or -not $entry.After){throw 'An Explorer image paste observation is incomplete or failed.'}
        }
        $serial=@($guest.SerialPastes)
        if($serial.Count -ne 12){throw 'The twelve serial paste observations are incomplete.'}
        for($index=0;$index -lt 12;$index++){
            $entry=$serial[$index]
            if($entry.Index -ne ($index+1) -or -not $entry.Published -or $entry.Error -or $entry.ObservedPngCount -ne ($index+1)){throw 'A serial paste observation did not confirm exactly one new image.'}
            foreach($state in @($entry.Before,$entry.After)){
                if(-not $state.Foreground -or -not $state.FocusWithinWindow -or ($state.GuiFlags -band 0x1e) -ne 0 -or $state.MenuOwner -ne 0){throw 'The serial sample did not retain native Explorer focus outside menu/move mode.'}
            }
        }
        $editors=@($guest.EditorProof)
        if($editors.Count -ne 4){throw 'The native editor references are incomplete.'}
        foreach($control in @('NativeEdit','RichEdit')){
            $pair=@($editors | Where-Object Control -eq $control)
            if($pair.Count -ne 2 -or $pair[0].LaqayEnabled -or -not $pair[1].LaqayEnabled){throw 'The disabled/enabled editor comparison is missing.'}
            foreach($entry in $pair){
                if(-not $entry.TextMatched){throw 'Native editor text did not match.'}
                foreach($state in @($entry.Before,$entry.After)){
                    if(-not $state.Foreground -or -not $state.Focused -or -not $state.InputReady -or ($state.GuiFlags -band 0x1e) -ne 0 -or -not $state.Visible -or -not $state.Enabled -or $state.ReadOnly -or $state.ControlWindow -eq 0 -or $state.ControlWindow -ne $state.FocusWindow){throw 'The editor child did not retain native keyboard focus outside menu/move mode.'}
                }
            }
        }
        $stages=@($guest.ClipboardLeaseProof | ForEach-Object Stage)
        if($stages.Count -ne 3 -or @(Compare-Object @('BeforeKey','AfterKey','AfterObservation') $stages).Count -ne 0 -or @($guest.ClipboardLeaseProof | Where-Object {-not $_.Proof.Held -or -not $_.Proof.ProbeRejected -or $_.Proof.Expired -or $_.Proof.Error -or $_.Proof.OwnerPid -eq $guest.ApplicationPid}).Count -ne 0){throw 'The clipboard-lock test did not preserve its independently observed barrier.'}
    }
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
    if(($IncludeLifecycle -or $IncludeAdverse) -and $registered -and $session -and -not $summary.Passed){try{
        Invoke-Command -Session $session -ArgumentList $LabId,$RunId,$guestRoot -ScriptBlock {
            param($labId,$runId,$runRoot)
            $path=Join-Path $runRoot 'pending-abort.json'
            if(-not (Test-Path -LiteralPath $path)){
                [pscustomobject]@{LabId=$labId;RunId=$runId;Abort=$true} | ConvertTo-Json | Set-Content -LiteralPath ($path+'.tmp') -Encoding UTF8
                Move-Item -LiteralPath ($path+'.tmp') -Destination $path
            }
        }
        $grace=[DateTime]::UtcNow.AddSeconds(30)
        do{
            $finished=Invoke-Command -Session $session -ArgumentList $taskName,$guestRoot -ScriptBlock {
                param($taskName,$runRoot)
                $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if($task -and $task.State -eq 'Running'){return $false}
                $path=Join-Path $runRoot 'report.json'
                if(Test-Path -LiteralPath $path){try{return [bool](Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).FinishedUtc}catch{}}
                $false
            }
            if($finished){break};Start-Sleep -Milliseconds 200
        }while([DateTime]::UtcNow -lt $grace)
    }catch{$summary.CleanupErrors+=@($_.Exception.Message)}}
    if($session){
        try{
            if($registered){
            $summary.TaskStopped=[bool](Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {
                param($taskName)
                $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                $stopped=$false
                if($task){if($task.State -eq 'Running'){Stop-ScheduledTask -TaskName $taskName;$stopped=$true};Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
                $stopped
            })
            if($summary.TaskStopped){$summary.Passed=$false;$summary.CleanupErrors+=@('The owned guest task required a fallback stop.')}
            $summary.TaskRemoved=$true
            }
        }catch{$summary.CleanupErrors+=@($_.Exception.Message);$summary.Passed=$false}
        if($IncludeUnc){
            try{
                $summary.CredentialRemoved=[bool](Invoke-Command -Session $session -ArgumentList $guestRoot -ScriptBlock {
                    param($runRoot)
                    $path=Join-Path $runRoot 'peer-credential.xml'
                    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -ErrorAction Stop}
                    -not (Test-Path -LiteralPath $path)
                })
                if(-not $summary.CredentialRemoved){throw 'Guest peer credential cleanup failed.'}
            }catch{$summary.CleanupErrors+=@($_.Exception.Message);$summary.Passed=$false}
        }
        try{
            if($IncludeUnc -and -not $summary.CredentialRemoved){throw 'Refusing to collect output while the credential remains.'}
            Copy-Item -Path ($guestRoot+'\*') -Destination $output -FromSession $session -Recurse
            $collected=Join-Path $output 'report.json'
            if(Test-Path -LiteralPath $collected){
                $latest=Get-Content -LiteralPath $collected -Raw | ConvertFrom-Json
                if($latest.LabId -ne $LabId -or $latest.RunId -ne $RunId){throw 'Unexpected collected guest report identity.'}
                $summary.GuestReport=$latest
            }
        }catch{$summary.CleanupErrors+=@($_.Exception.Message);$summary.Passed=$false}
        Remove-PSSession -Session $session
    }
    if($peerSession -and $peerFixtureReserved){
        try{
            $summary.ServerFixtureRemoved=[bool](Invoke-Command -Session $peerSession -ArgumentList $RunId -ScriptBlock {
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
            })
            if(-not $summary.ServerFixtureRemoved){throw 'Server fixture cleanup failed.'}
        }catch{$summary.CleanupErrors+=@($_.Exception.Message);$summary.Passed=$false}
    }
    if($peerSession){Remove-PSSession -Session $peerSession}
    $summary.FinishedUtc=[DateTime]::UtcNow.ToString('o')
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'host-report.json') -Encoding UTF8
}
if(-not $summary.Passed){throw ('Guest smoke validation failed: '+$summary.Error+' '+($summary.CleanupErrors -join '; '))}
Write-Output ('Guest suite passed: '+$StartupPhase+'. Owned applications exited and the guest task was removed.')
