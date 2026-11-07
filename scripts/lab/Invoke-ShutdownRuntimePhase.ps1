[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [ValidateSet('Shutdown')][string]$Phase='Shutdown',
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [string]$OutputDirectory,
    [ValidateSet('Windows11EnterpriseEvaluation')][string]$GuestProfile='Windows11EnterpriseEvaluation',
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PrepareOnly){ & (Join-Path $PSScriptRoot 'Invoke-GuestShutdown.ps1') -PrepareOnly; return }
if(-not $env:RUST_WORK_JOB -or -not $LabId -or -not $CycleId -or -not $ExpectedExecutableSha256 -or -not $OutputDirectory){throw 'The exact runtime lease and shutdown scope are required.'}
if(-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An authorized elevated VM controller is required.'}
$labRoot=Join-Path $env:LOCALAPPDATA ('LaqayTestLab/'+$LabId)
$manifest=Get-Content -LiteralPath (Join-Path $labRoot 'lab.json') -Raw | ConvertFrom-Json
$entries=@($manifest.VMs|Where-Object Role -ceq 'Primary')
if($entries.Count -ne 1 -or $manifest.VMs.Count -ne 2){throw 'The shutdown scope requires one Primary in the existing two-guest lab.'}
$vmId=[guid]$entries[0].Id
if((Get-VM -Id $vmId).State -ne 'Running'){throw 'The owned guest must already be booted.'}
if(([long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory*1KB) -lt 3GB){throw 'The host memory reserve is below three GiB.'}
$credential=Import-Clixml -LiteralPath (Join-Path $labRoot 'vms/Primary/credential.xml')
$root='C:\LaqayLab\Shutdown\'+$CycleId;$runRoot='C:\LaqayLab\Runs\'+$CycleId;$taskName='LaqayShutdown-'+$CycleId
$path=Join-Path $OutputDirectory 'phase-report.json'
if(Test-Path -LiteralPath $path){throw 'Refusing a reused shutdown phase.'}
$r=[ordered]@{LabId=$LabId;CycleId=$CycleId;Phase=$Phase;GuestProfile=$GuestProfile;BootPerformed=$false;IncludeRealApplications=$false;IncludeWindowsTerminal=$false;Suites=@();Passed=$false;AcceptancePending=$true;OffObserved=$false;TaskCreated=$false;PendingWaitProof=$null;Guest=$null;Error=$null;CleanupErrors=@();StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
function Save {$r|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $path -Encoding UTF8}
$session=$null
try{
    Save
    $session=New-PSSession -VMId $vmId -Credential $credential
    Invoke-Command -Session $session -ArgumentList $LabId,$CycleId,$root,$runRoot -ScriptBlock {
        param($lab,$cycle,$root,$runRoot)
        $ErrorActionPreference='Stop'
        $ready=Get-Content 'C:\LaqayLab\ready.json' -Raw|ConvertFrom-Json
        $machine=Get-CimInstance Win32_ComputerSystem;$os=Get-CimInstance Win32_OperatingSystem
        if($ready.LabId -cne $lab -or $ready.Role -cne 'Primary' -or -not $ready.Ready -or $cycle -cnotmatch '^[a-f0-9]{32}$' -or
            $machine.Manufacturer -cne 'Microsoft Corporation' -or $machine.Model -cne 'Virtual Machine' -or $os.Caption -cne 'Microsoft Windows 11 Enterprise Evaluation' -or $os.BuildNumber -cne '26300'){throw 'Unexpected shutdown guest.'}
        foreach($p in @('C:\LaqayLab','C:\LaqayLab\Shutdown','C:\LaqayLab\Runs')){
            if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse point in shutdown scope.'}
        }
        if((Test-Path -LiteralPath $root) -or (Test-Path -LiteralPath $runRoot)){throw 'Refusing reused guest shutdown data.'}
        New-Item -ItemType Directory -Path $root,$runRoot -ErrorAction Stop|Out-Null
    }
    foreach($name in @('ShutdownEvidence.ps1','Complete-GuestShutdown.ps1','Invoke-GuestShutdown.ps1','Invoke-GuestDesktopSmoke.ps1','SmokeGuestProfile.ps1','GuestDesktopControls.cs','GuestLifecycleControls.cs','GuestAdverseControls.cs','GuestVirtualFileControls.cs','GuestRealApplicationControls.cs')){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $runRoot $name) -ToSession $session
    }
    Invoke-Command -Session $session -ArgumentList $LabId,$CycleId,$runRoot,$taskName,$ExpectedExecutableSha256 -ScriptBlock {
        param($lab,$cycle,$runRoot,$task,$sha)
        $ErrorActionPreference='Stop'
        . (Join-Path $runRoot 'ShutdownEvidence.ps1')
        [void](Assert-ShutdownGuest $lab $cycle)
        if(@(Get-Process laqay -ErrorAction SilentlyContinue).Count -or (Get-FileHash 'C:\LaqayLab\App\laqay.exe').Hash -ine $sha){throw 'The shutdown application baseline changed.'}
        if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'The shutdown task already exists.'}
        Start-ShutdownTrace $lab $cycle
        $arguments='-NoProfile -NonInteractive -STA -WindowStyle Hidden -File "'+$runRoot+'\Invoke-GuestShutdown.ps1" -LabId '+$lab+' -CycleId '+$cycle+' -ExpectedExecutableSha256 '+$sha
        $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
        $principal=New-ScheduledTaskPrincipal -UserId ($env:COMPUTERNAME+'\LaqayLab') -LogonType Interactive -RunLevel Limited
        $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -ErrorAction Stop|Out-Null
    }
    $r.TaskCreated=$true;Save
    Invoke-Command -Session $session -ArgumentList $taskName -ScriptBlock {param($name) Start-ScheduledTask -TaskName $name -ErrorAction Stop}
    $timer=[Diagnostics.Stopwatch]::StartNew();$verified=$false;$shutdownAt=$null
    while($timer.Elapsed.TotalSeconds -lt 150){
        if((Get-VM -Id $vmId).State -eq 'Off'){
            if(-not $verified -or -not $shutdownAt){throw 'The guest powered off before the pending-work fence.'}
            $r.OffObserved=$true;$r.Passed=$true;break
        }
        try{
            $guest=Invoke-Command -Session $session -ArgumentList $root -ScriptBlock {param($root) $p=Join-Path $root 'guest.json';if(Test-Path -LiteralPath $p){Get-Content -LiteralPath $p -Raw|ConvertFrom-Json}}
            if($guest){
                if($guest.LabId -cne $LabId -or $guest.CycleId -cne $CycleId -or $guest.ExecutableSha256 -ine $ExpectedExecutableSha256){throw 'Unexpected shutdown report identity.'}
                $r.Guest=$guest;Save
                if($guest.Status -eq 'Failed'){throw ('Guest shutdown fixture failed: '+$guest.Error)}
                if($guest.Status -eq 'Pending' -and -not $verified){
                    $proofJson=Invoke-Command -Session $session -ArgumentList $LabId,$CycleId,$runRoot,$guest.ApplicationPid,$guest.Provider.ProviderPid,$guest.Provider.ProviderThreadId,$guest.SessionId -ScriptBlock {
                        param($lab,$cycle,$runRoot,$appPid,$providerPid,$thread,$sid)
                        $ErrorActionPreference='Stop'
                        if(-not ('LaqayGuestWaitChain' -as [type])){& (Join-Path $runRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly|Out-Null}
                        [LaqayGuestWaitChain]::InspectJson($lab,$cycle,$appPid,$providerPid,$thread,$sid)
                    }
                    $proof=$proofJson|ConvertFrom-Json
                    if($proof.Confirmed){
                        $r.PendingWaitProof=$proof;Save
                        Invoke-Command -Session $session -ArgumentList $runRoot,$root,$proof -ScriptBlock {
                            param($runRoot,$root,$proof)
                            . (Join-Path $runRoot 'ShutdownEvidence.ps1')
                            if(Test-Path -LiteralPath (Join-Path $root 'pending-proof.json')){throw 'Duplicate shutdown pending proof.'}
                            Write-ShutdownSnapshot (Join-Path $root 'pending-proof.json') $proof
                        }
                        $verified=$true
                    }
                }
                if($guest.Status -eq 'ShutdownRequested'){$shutdownAt=$guest.ShutdownRequestedUtc}
            }
        }catch [System.Management.Automation.Remoting.PSRemotingTransportException]{
            if(-not $verified){throw}
            # PowerShell Direct can disappear before the final guest snapshot is
            # fetched. The persisted snapshot is mandatory at collection time.
            if(-not $shutdownAt){$shutdownAt='AwaitingPersistedSnapshot'}
        }
        if($verified -and $timer.Elapsed.TotalSeconds -gt 120){throw 'The guest shutdown exceeded its bounded phase.'}
        Start-Sleep -Milliseconds 250
    }
    if(-not $r.Passed){throw 'The guest did not power off within the shutdown phase.'}
}catch{$r.Error=$_.Exception.Message}
finally{
    if($session){Remove-PSSession -Session $session -ErrorAction SilentlyContinue}
    $r.FinishedUtc=[DateTime]::UtcNow.ToString('o');Save
}
if(-not $r.Passed){throw ('Guest shutdown phase failed: '+$r.Error)}
