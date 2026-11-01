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
if($PrepareOnly){& (Join-Path $PSScriptRoot 'Invoke-GuestRdpClient.ps1') -PrepareOnly;return}
if(-not $LabId -or -not $RunId -or -not $ExpectedExecutableSha256 -or -not $OutputDirectory){throw 'Lab/run identities, executable hash, and private output directory are required.'}
if(-not $env:RUST_WORK_JOB){throw 'Run the RDP application suite through RustWork with --family rust.'}
if(-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An authorized administrator process is required for PowerShell Direct.'}
$root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA ('LaqayTestLab/'+$LabId)))
$manifest=Get-Content -LiteralPath (Join-Path $root 'lab.json') -Raw | ConvertFrom-Json
if($manifest.Kind -ne 'LaqayDesktopTestLab' -or $manifest.LabId -ne $LabId -or $manifest.Root -ne $root -or $manifest.VMs.Count -ne 2 -or (@($manifest.VMs.Role | Sort-Object) -join ',') -ne 'Peer,Primary' -or @($manifest.VMs.Id | Select-Object -Unique).Count -ne 2){throw 'Expected two distinct owned guests.'}
$switch=Get-VMSwitch -Id ([guid]$manifest.SwitchId)
if($switch.SwitchType -ne 'Private' -or $switch.Notes -ne ('Laqay disposable desktop lab '+$LabId)){throw 'Expected the owned private switch.'}
if(@(Get-VM | Where-Object {$_.Id.ToString() -notin @($manifest.VMs.Id)} | Get-VMNetworkAdapter | Where-Object SwitchId -eq $switch.Id).Count){throw 'An unowned guest is attached to the private switch.'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$reportPath=Join-Path $output 'rdp-report.json'
if(Test-Path -LiteralPath $reportPath){throw 'Refusing to reuse an RDP report.'}
$guestRoot='C:\LaqayLab\Runs\'+$RunId
$taskName='Laqay.Rdp.'+$RunId
$sessions=@{};$credentials=@{};$registered=@{};$allocated=@{};$targetSessions=@{}
$report=[ordered]@{LabId=$LabId;RunId=$RunId;Passed=$false;Error=$null;Client=$null;Peer=$null;RelayedOperations=@();TasksRemoved=@{};
    CredentialRemoved=$false;CleanupErrors=@();StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
$expectedOperations=@('Paste','Image','Paste','Paste','Text','Paste')
function Save-Report {$report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reportPath -Encoding UTF8}
function Read-Task([string]$role){
    Invoke-Command -Session $sessions[$role] -ArgumentList $taskName,$guestRoot,$role -ScriptBlock {
        param($taskName,$runRoot,$role)
        $ErrorActionPreference='Stop'
        $task=Get-ScheduledTask -TaskName $taskName
        $info=Get-ScheduledTaskInfo -TaskName $taskName
        $name=if($role -eq 'Primary'){'client-report.json'}else{'report.json'}
        $path=Join-Path $runRoot $name
        $data=$null
        if(Test-Path -LiteralPath $path){
            $stream=$null;$reader=$null
            try{
                $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                $reader=[IO.StreamReader]::new($stream);$data=$reader.ReadToEnd() | ConvertFrom-Json
            }catch{}finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
        }
        [pscustomobject]@{State=$task.State.ToString();LastResult=$info.LastTaskResult;Report=$data}
    }
}
function Write-ClientCommand([int]$sequence,[string]$operation){
    Invoke-Command -Session $sessions.Primary -ArgumentList $LabId,$RunId,$guestRoot,$sequence,$operation -ScriptBlock {
        param($labId,$runId,$runRoot,$sequence,$operation)
        $ErrorActionPreference='Stop'
        $path=Join-Path $runRoot ('command-{0:0000}.json' -f $sequence)
        if(Test-Path -LiteralPath $path){throw 'Refusing to repeat a client command.'}
        $temporary=$path+'.tmp'
        [pscustomobject]@{LabId=$labId;RunId=$runId;Sequence=$sequence;Operation=$operation} | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $path
    }
}
function Assert-Task($task,[string]$role){
    if($task.Report -and ($task.Report.LabId -ne $LabId -or $task.Report.RunId -ne $RunId)){throw ('Unexpected '+$role+' report identity.')}
    if($task.Report.Error){throw ($role+' failed: '+$task.Report.Error)}
    if($task.State -ne 'Running' -and $task.LastResult -notin @(0,267009,267011)){throw ($role+' task failed: '+$task.LastResult)}
}
function Start-GuestTask([string]$role){
    $target=Invoke-Command -Session $sessions[$role] -ArgumentList $guestRoot,$taskName,$role -ScriptBlock {
        param($runRoot,$taskName,$role)
        $ErrorActionPreference='Stop'
        if(-not ('LaqayGuestSessionQuery' -as [type])){Add-Type -Path (Join-Path $runRoot 'GuestSessionQuery.cs')}
        $protocol=if($role -eq 'Primary'){0}else{2}
        $until=[DateTime]::UtcNow.AddSeconds(30)
        do{
            $ids=@([LaqayGuestSessionQuery]::FindActive($protocol,'LaqayLab',$env:COMPUTERNAME))
            if($ids.Count){break};Start-Sleep -Milliseconds 500
        }while([DateTime]::UtcNow -lt $until)
        if($ids.Count -ne 1){throw 'Expected exactly one active owned guest session of the required protocol.'}
        $scheduler=New-Object -ComObject Schedule.Service
        $folder=$null;$task=$null;$running=$null
        try{
            $scheduler.Connect();$folder=$scheduler.GetFolder('\');$task=$folder.GetTask($taskName)
            # TASK_RUN_USE_SESSION_ID binds input to this exact console/RDP logon.
            $running=$task.RunEx($null,4,$ids[0],$null)
            [int]$ids[0]
        }finally{
            foreach($instance in @($running,$task,$folder,$scheduler)){if($instance){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($instance)}}
        }
    }
    $targetSessions[$role]=[int]$target
}
try{
    Save-Report
    foreach($entry in $manifest.VMs){
        $role=$entry.Role;$vm=Get-VM -Id ([guid]$entry.Id)
        $disk=Join-Path $root ('vms/'+$role+'/system.vhdx')
        $drives=@(Get-VMHardDiskDrive -VM $vm);$adapters=@(Get-VMNetworkAdapter -VM $vm)
        if($vm.State -ne 'Running' -or $vm.Name -ne $entry.Name -or $vm.Notes -ne ('Laqay disposable desktop lab '+$LabId) -or $entry.DiskPath -ne $disk -or $drives.Count -ne 1 -or $drives[0].Path -ne $disk -or $adapters.Count -ne 1 -or $adapters[0].SwitchId -ne $switch.Id){throw 'Unexpected paired guest ownership or attachment.'}
        $credentials[$role]=Import-Clixml -LiteralPath (Join-Path (Split-Path $disk) 'credential.xml')
        $sessions[$role]=New-PSSession -VMId $vm.Id -Credential $credentials[$role]
        $name=Invoke-Command -Session $sessions[$role] -ArgumentList $LabId,$RunId,$role,$guestRoot -ScriptBlock {
            param($labId,$runId,$role,$runRoot)
            $ErrorActionPreference='Stop'
            $ready=Get-Content -LiteralPath 'C:/LaqayLab/ready.json' -Raw | ConvertFrom-Json
            $computer=Get-CimInstance Win32_ComputerSystem
            $adapters=@(Get-NetAdapter -Physical)
            $expected=if($role -eq 'Primary'){'10.77.166.10'}else{'10.77.166.11'}
            if($ready.LabId -ne $labId -or $ready.Role -ne $role -or -not $ready.Ready -or $computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine' -or (Get-CimInstance Win32_OperatingSystem).Caption -notlike '*Windows 11 Enterprise*' -or $adapters.Count -ne 1 -or $env:COMPUTERNAME -notmatch '^LQW11-[A-Z0-9]{8}$'){throw 'Guest identity mismatch.'}
            if(@(Get-NetIPAddress -InterfaceIndex $adapters[0].ifIndex -AddressFamily IPv4 | Where-Object {$_.IPAddress -eq $expected -and $_.PrefixLength -eq 24}).Count -ne 1 -or @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count){throw 'Guest address or isolation changed.'}
            if($role -eq 'Primary'){
                $state=Get-Content -LiteralPath ('C:\LaqayLab\RdpTrust\'+$runId+'.json') -Raw | ConvertFrom-Json
                if($state.LabId -ne $labId -or $state.RunId -ne $runId -or -not $state.Prepared -or $state.Restored){throw 'The bounded guest trust/name setup is not prepared.'}
            }else{
                $settings=Get-CimInstance -Namespace root/cimv2/terminalservices -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-tcp'"
                if($settings.UserAuthenticationRequired -ne 1 -or $settings.SecurityLayer -notin @(1,2)){throw 'The peer must require NLA and negotiate TLS.'}
            }
            if($runRoot -ne ('C:\LaqayLab\Runs\'+$runId) -or (Test-Path -LiteralPath $runRoot)){throw 'Unexpected or reused guest run root.'}
            New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
            $acl=Get-Acl -LiteralPath $runRoot
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(($env:COMPUTERNAME+'\LaqayLab'),'Modify','ContainerInherit,ObjectInherit','None','Allow'))
            Set-Acl -LiteralPath $runRoot -AclObject $acl
            $env:COMPUTERNAME
        }
        $allocated[$role]=$true
        $credentials[$role]=[PSCredential]::new(($name+'\LaqayLab'),$credentials[$role].Password)
        foreach($file in @('GuestDesktopControls.cs','GuestSessionQuery.cs','Invoke-GuestDesktopSmoke.ps1','Invoke-GuestRdpClient.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $guestRoot -ToSession $sessions[$role]}
        Invoke-Command -Session $sessions[$role] -ArgumentList $LabId,$RunId,$ExpectedExecutableSha256,$guestRoot,$taskName,$role -ScriptBlock {
            param($labId,$runId,$sha,$runRoot,$taskName,$role)
            $ErrorActionPreference='Stop'
            $launcher=@'
$ErrorActionPreference='Stop'
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy RemoteSigned -File '@@ROOT@@\@@DRIVER@@' -LabId '@@LAB@@' -RunId '@@RUN@@' @@EXTRA@@ *> '@@ROOT@@\console.log'
exit $LASTEXITCODE
'@
            $driver=if($role -eq 'Primary'){'Invoke-GuestRdpClient.ps1'}else{'Invoke-GuestDesktopSmoke.ps1'}
            $extra=if($role -eq 'Peer'){"-IncludeRdp -ExpectedExecutableSha256 '$sha'"}else{''}
            $launcher=$launcher.Replace('@@ROOT@@',$runRoot).Replace('@@DRIVER@@',$driver).Replace('@@LAB@@',$labId).Replace('@@RUN@@',$runId).Replace('@@EXTRA@@',$extra)
            Set-Content -LiteralPath (Join-Path $runRoot 'Launch.ps1') -Value $launcher -Encoding UTF8
            if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'Refusing to replace an existing task.'}
            $action=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ('-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$runRoot+'\Launch.ps1"')
            $principal=New-ScheduledTaskPrincipal -UserId ($env:COMPUTERNAME+'\LaqayLab') -LogonType Interactive -RunLevel Limited
            $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(7)) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
        }
        $registered[$role]=$true
    }
    Invoke-Command -Session $sessions.Primary -ArgumentList $guestRoot,$credentials.Peer -ScriptBlock {
        param($runRoot,$peerCredential)
        $ErrorActionPreference='Stop'
        $peerCredential | Export-Clixml -LiteralPath (Join-Path $runRoot 'peer-credential.xml')
    }
    Start-GuestTask Primary
    $until=[DateTime]::UtcNow.AddSeconds(90)
    do{
        $client=Read-Task Primary;Assert-Task $client Primary
        $report.Client=$client.Report;Save-Report
        if($client.Report.LoggedOn){break}
        if($client.Report.FinishedUtc){throw 'The RDP client finished without a successful logon.'}
        Start-Sleep -Milliseconds 500
    }while([DateTime]::UtcNow -lt $until)
    if(-not $client.Report.LoggedOn){throw 'RDP logon did not complete within ninety seconds.'}
    Start-GuestTask Peer
    $until=[DateTime]::UtcNow.AddMinutes(5);$handled=0;$pending=$null
    do{
        $client=Read-Task Primary;$peer=Read-Task Peer
        Assert-Task $client Primary;Assert-Task $peer Peer
        $report.Client=$client.Report;$report.Peer=$peer.Report;Save-Report
        if($client.Report.FinishedUtc){throw 'The RDP client closed before the peer suite finished.'}
        $request=$peer.Report.ClientRequest
        if(-not $pending -and $request -and $request.Sequence -gt $handled){
            if($request.LabId -ne $LabId -or $request.RunId -ne $RunId -or $request.Sequence -ne ($handled+1) -or $handled -ge $expectedOperations.Count -or $request.Operation -ne $expectedOperations[$handled]){throw 'Unexpected RDP input request or order.'}
            Write-ClientCommand $request.Sequence $request.Operation
            $pending=$request
        }
        if($pending -and $client.Report.AckSequence -ge $pending.Sequence){
            if($client.Report.AckSequence -ne $pending.Sequence -or @($client.Report.Operations).Count -ne $pending.Sequence -or $client.Report.Operations[$pending.Sequence-1] -ne $pending.Operation){throw 'Unexpected RDP client acknowledgement.'}
            Invoke-Command -Session $sessions.Peer -ArgumentList $LabId,$RunId,$guestRoot,$pending.Sequence,$pending.Operation -ScriptBlock {
                param($labId,$runId,$runRoot,$sequence,$operation)
                $ErrorActionPreference='Stop'
                $path=Join-Path $runRoot ('client-ack-'+$sequence+'.json')
                if(Test-Path -LiteralPath $path){throw 'Refusing to repeat an acknowledgement.'}
                $temporary=$path+'.tmp'
                [pscustomobject]@{LabId=$labId;RunId=$runId;Sequence=$sequence;Operation=$operation;Passed=$true} | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
                Move-Item -LiteralPath $temporary -Destination $path
            }
            $handled++;$report.RelayedOperations+=@($pending.Operation);$pending=$null
        }
        if($peer.Report.FinishedUtc -and $peer.State -ne 'Running'){break}
        Start-Sleep -Milliseconds 200
    }while([DateTime]::UtcNow -lt $until)
    $required=@('ImagePaste','CollisionPreservation','NativeFilePaste','AddressBarText','SearchText','RenameText','DisabledImageDoesNotSave','ReenabledImageSaves','ActiveTabSelection','UnicodePathImagePaste','ClipboardPreservedAfterImagePaste','ActiveWindowSelection','DeniedWriteRecovery','RdpSessionImagePaste','RdpRedirectedImagePaste','RdpNativeFilePaste','RdpRedirectedTextPaste')
    $guest=$peer.Report
    if($guest.SessionId -ne $targetSessions.Peer -or $client.Report.SessionId -ne $targetSessions.Primary){throw 'A task ran in a different guest session than requested.'}
    if(-not $guest.FinishedUtc -or -not $guest.Passed -or -not $guest.IncludeRdp -or $guest.SessionProtocol -ne 2 -or $guest.RdpClientAddress -ne '10.77.166.10' -or $guest.ExecutableSha256 -ne $ExpectedExecutableSha256 -or $guest.Cases.Count -ne 17 -or @(Compare-Object $required @($guest.Cases.Name)).Count -or @($guest.Cases | Where-Object {-not $_.Passed}).Count -or -not $guest.ApplicationClosed -or $guest.ApplicationExitCode -ne 0 -or $guest.ForcedTermination -or -not $guest.PreferencesRestored -or -not $guest.PermissionsRestored -or @($guest.CleanupErrors).Count -or $peer.LastResult -ne 0 -or $handled -ne 6 -or $pending){throw 'The complete limited RDP suite did not pass.'}
    Write-ClientCommand 7 Close
    $until=[DateTime]::UtcNow.AddSeconds(30)
    do{
        $client=Read-Task Primary;Assert-Task $client Primary
        $report.Client=$client.Report;Save-Report
        if($client.Report.FinishedUtc -and $client.State -ne 'Running'){break}
        Start-Sleep -Milliseconds 200
    }while([DateTime]::UtcNow -lt $until)
    $expectedAll=@($expectedOperations)+@('Close')
    if(-not $client.Report.FinishedUtc -or -not $client.Report.Passed -or -not $client.Report.LoggedOn -or -not $client.Report.Disconnected -or $client.Report.AuthenticationLevel -ne 1 -or -not $client.Report.CredSsp -or -not $client.Report.ClipboardRedirection -or $client.Report.SessionId -le 0 -or $client.Report.AckSequence -ne 7 -or @($client.Report.Operations).Count -ne 7 -or ([string]::Join(',',@($client.Report.Operations))) -ne ([string]::Join(',',$expectedAll)) -or $client.LastResult -ne 0){throw 'The RDP client did not complete its exact command sequence and clean disconnect.'}
    $report.Passed=$true
}catch{$report.Error=$_.Exception.Message}finally{
    foreach($role in @('Peer','Primary')){
        if(-not $sessions[$role]){continue}
        if($registered[$role]){try{
            Invoke-Command -Session $sessions[$role] -ArgumentList $taskName -ScriptBlock {
                param($taskName)
                $ErrorActionPreference='Stop'
                $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if($task){if($task.State -eq 'Running'){Stop-ScheduledTask -TaskName $taskName};Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
            }
            $report.TasksRemoved[$role]=$true
        }catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}}
        if($role -eq 'Primary' -and $allocated[$role]){try{
            $report.CredentialRemoved=[bool](Invoke-Command -Session $sessions[$role] -ArgumentList $guestRoot -ScriptBlock {
                param($runRoot)
                $ErrorActionPreference='Stop'
                $path=Join-Path $runRoot 'peer-credential.xml'
                if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
                -not (Test-Path -LiteralPath $path)
            })
            if(-not $report.CredentialRemoved){throw 'The temporary peer credential remains.'}
        }catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}}
        if($allocated[$role]){try{
            if($role -eq 'Primary' -and -not $report.CredentialRemoved){throw 'Refusing output collection with a credential present.'}
            $destination=Join-Path $output $role;New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Copy-Item -Path ($guestRoot+'\*') -Destination $destination -FromSession $sessions[$role] -Recurse
        }catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}}
        Remove-PSSession -Session $sessions[$role]
    }
    if(-not $report.TasksRemoved.Primary -or -not $report.TasksRemoved.Peer -or -not $report.CredentialRemoved){$report.Passed=$false}
    $report.FinishedUtc=[DateTime]::UtcNow.ToString('o');Save-Report
}
if(-not $report.Passed){throw ('RDP validation failed: '+$report.Error+' '+($report.CleanupErrors -join '; '))}
Write-Output 'Seventeen limited RDP cases passed; native client disconnected and both guest tasks were removed.'
