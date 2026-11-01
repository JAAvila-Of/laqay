[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
if(-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An authorized administrator process is required for PowerShell Direct.'}
$root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA ('LaqayTestLab/'+$LabId)))
$manifest=Get-Content -LiteralPath (Join-Path $root 'lab.json') -Raw | ConvertFrom-Json
if($manifest.Kind -ne 'LaqayDesktopTestLab' -or $manifest.LabId -ne $LabId -or $manifest.Root -ne $root){throw 'Invalid lab ownership.'}
$roles=@($manifest.VMs.Role | Sort-Object)
if($roles.Count -ne 2 -or $roles[0] -ne 'Peer' -or $roles[1] -ne 'Primary' -or @($manifest.VMs.Id | Select-Object -Unique).Count -ne 2){throw 'Exactly two distinct owned lab guests are required.'}
$switch=Get-VMSwitch -Id ([guid]$manifest.SwitchId)
if($switch.SwitchType -ne 'Private' -or $switch.Notes -ne ('Laqay disposable desktop lab '+$LabId)){throw 'The lab switch is not owned and private.'}
$foreign=@(Get-VM | Where-Object { $_.Id.ToString() -notin @($manifest.VMs.Id) } | Get-VMNetworkAdapter | Where-Object SwitchId -eq $switch.Id)
if($foreign.Count){throw 'An unowned guest is attached to the lab network.'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$reportPath=Join-Path $output 'network-report.json'
if(Test-Path -LiteralPath $reportPath){throw 'Refusing to reuse a network report.'}
$sessions=@{};$credentials=@{};$details=@{};$fixtureCreated=$false
$report=[ordered]@{LabId=$LabId;RunId=$RunId;Passed=$false;Error=$null;TcpChecks=@();SmbRoundTrip=$false;Signed=$false;FixtureRemoved=$false;
    TestsExplorerPaste=$false;TestsRdpLogon=$false;CleanupErrors=@();StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
try{
    foreach($entry in $manifest.VMs){
        $vm=Get-VM -Id ([guid]$entry.Id)
        $disk=Join-Path $root ('vms/'+$entry.Role+'/system.vhdx')
        $drives=@(Get-VMHardDiskDrive -VM $vm);$adapters=@(Get-VMNetworkAdapter -VM $vm)
        if($vm.State -ne 'Running' -or $vm.Name -ne $entry.Name -or $vm.Notes -ne ('Laqay disposable desktop lab '+$LabId) -or $entry.DiskPath -ne $disk -or $drives.Count -ne 1 -or $drives[0].Path -ne $disk -or $adapters.Count -ne 1 -or $adapters[0].SwitchId -ne $switch.Id){throw 'Unexpected guest ownership, state, disk, or adapter.'}
        $credentials[$entry.Role]=Import-Clixml -LiteralPath (Join-Path (Split-Path $disk) 'credential.xml')
        $sessions[$entry.Role]=New-PSSession -VMId $vm.Id -Credential $credentials[$entry.Role]
        $details[$entry.Role]=Invoke-Command -Session $sessions[$entry.Role] -ArgumentList $LabId,$entry.Role -ScriptBlock {
            param($labId,$role)
            $ErrorActionPreference='Stop'
            $ready=Get-Content -LiteralPath 'C:/LaqayLab/ready.json' -Raw | ConvertFrom-Json
            $computer=Get-CimInstance Win32_ComputerSystem
            $expected=if($role -eq 'Primary'){'10.77.166.10'}else{'10.77.166.11'}
            $adapters=@(Get-NetAdapter -Physical)
            if($ready.LabId -ne $labId -or $ready.Role -ne $role -or -not $ready.Ready -or $computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine' -or (Get-CimInstance Win32_OperatingSystem).Caption -notlike '*Windows 11 Enterprise*' -or $adapters.Count -ne 1){throw 'Guest identity mismatch.'}
            $addresses=@(Get-NetIPAddress -InterfaceIndex $adapters[0].ifIndex -AddressFamily IPv4 | Where-Object {$_.IPAddress -eq $expected -and $_.PrefixLength -eq 24})
            if($addresses.Count -ne 1 -or @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count){throw 'Guest addresses or default routes changed.'}
            $share=Get-SmbShare -Name LaqayLab
            if($share.Path -ne 'C:\LaqayLab\Share' -or ((Get-Item -LiteralPath $share.Path).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $env:COMPUTERNAME -notmatch '^[A-Za-z0-9-]{1,15}$'){throw 'Unexpected guest share or computer name.'}
            [pscustomobject]@{ComputerName=$env:COMPUTERNAME;Address=$expected;Build=$ready.Build}
        }
    }
    foreach($check in @(@{From='Primary';To='Peer';Port=445},@{From='Primary';To='Peer';Port=3389},@{From='Peer';To='Primary';Port=445})){
        $result=Invoke-Command -Session $sessions[$check.From] -ArgumentList $details[$check.To].Address,$check.Port -ScriptBlock {
            param($address,$port)
            $client=[Net.Sockets.TcpClient]::new();$pending=$null
            try{$pending=$client.BeginConnect($address,$port,$null,$null);if(-not $pending.AsyncWaitHandle.WaitOne(5000)){throw 'Private lab TCP connection timed out.'};$client.EndConnect($pending);$true}
            finally{if($pending){$pending.AsyncWaitHandle.Close()};$client.Dispose()}
        }
        if(-not $result){throw 'A required private lab TCP connection failed.'}
        $report.TcpChecks+=@([pscustomobject]@{From=$check.From;To=$check.To;Port=$check.Port;Passed=$true})
    }
    Invoke-Command -Session $sessions.Peer -ArgumentList $RunId -ScriptBlock {
        param($runId)
        $ErrorActionPreference='Stop'
        $parent='C:\LaqayLab\Share\Connectivity'
        if(Test-Path -LiteralPath $parent){if(((Get-Item -LiteralPath $parent).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Unexpected fixture reparse point.'}}else{New-Item -ItemType Directory -Path $parent | Out-Null}
        $directory=Join-Path $parent $runId
        if(Test-Path -LiteralPath $directory){throw 'Refusing to reuse a peer fixture.'}
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $fixtureCreated=$true
    $peerAuth=[PSCredential]::new(($details.Peer.ComputerName+'\LaqayLab'),$credentials.Peer.Password)
    $copy=Invoke-Command -Session $sessions.Primary -ArgumentList $RunId,$peerAuth -ScriptBlock {
        param($runId,$peerAuth)
        $ErrorActionPreference='Stop'
        $name='Lq'+$runId.Substring(0,12);$created=$false
        try{
            if(Get-PSDrive -Name $name -ErrorAction SilentlyContinue){throw 'Unexpected existing test drive.'}
            New-PSDrive -Name $name -PSProvider FileSystem -Root '\\10.77.166.11\LaqayLab' -Credential $peerAuth -Scope Local | Out-Null
            $created=$true
            $path='\\10.77.166.11\LaqayLab\Connectivity\'+$runId+'\probe.bin'
            $bytes=[byte[]]@(0,1,127,255)
            $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew)
            try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
            $actual=[IO.File]::ReadAllBytes($path)
            if([Convert]::ToBase64String($actual) -ne [Convert]::ToBase64String($bytes)){throw 'SMB fixture read-back changed bytes.'}
            $connections=@(Get-SmbConnection | Where-Object {$_.ShareName -eq 'LaqayLab' -and $_.ServerName -in @('10.77.166.11',$peerAuth.UserName.Split('\')[0])})
            if($connections.Count -lt 1 -or @($connections | Where-Object {-not $_.Signed}).Count){throw 'The synthetic transfer did not use signed SMB.'}
            [pscustomobject]@{Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Signed=$true}
        }finally{if($created){Remove-PSDrive -Name $name -Force}}
    }
    $peerHash=Invoke-Command -Session $sessions.Peer -ArgumentList $RunId -ScriptBlock {param($runId) (Get-FileHash -LiteralPath ('C:\LaqayLab\Share\Connectivity\'+$runId+'\probe.bin') -Algorithm SHA256).Hash}
    if($copy.Hash -ne $peerHash -or -not $copy.Signed){throw 'The peer fixture hash did not match the client.'}
    $report.SmbRoundTrip=$true;$report.Signed=$true;$report.Passed=$true
}catch{$report.Error=$_.Exception.Message}finally{
    if($fixtureCreated){try{
        Invoke-Command -Session $sessions.Peer -ArgumentList $RunId -ScriptBlock {
            param($runId)
            $ErrorActionPreference='Stop'
            $parent='C:\LaqayLab\Share\Connectivity'
            $directory=[IO.Path]::GetFullPath((Join-Path $parent $runId))
            if($runId -notmatch '^[a-f0-9]{32}$' -or [IO.Path]::GetDirectoryName($directory) -ne $parent -or ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Unexpected fixture cleanup path.'}
            $file=Join-Path $directory 'probe.bin'
            if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}
            # Non-recursive removal refuses any unexpected remaining content.
            [IO.Directory]::Delete($directory,$false)
        }
        $report.FixtureRemoved=$true
    }catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}}
    foreach($session in @($sessions.Values)){Remove-PSSession -Session $session}
    if(-not $report.FixtureRemoved){$report.Passed=$false}
    $report.FinishedUtc=[DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
if(-not $report.Passed){throw ('Private lab network validation failed: '+$report.Error+' '+($report.CleanupErrors -join '; '))}
Write-Output 'Private lab TCP and signed SMB fixture checks passed. Explorer paste and RDP logon were not tested.'
