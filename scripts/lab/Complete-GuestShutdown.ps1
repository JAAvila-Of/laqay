param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [switch]$CleanupOnly
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ShutdownEvidence.ps1')
$root=Assert-ShutdownGuest $LabId $CycleId
$r=[ordered]@{LabId=$LabId;CycleId=$CycleId;Passed=$false;CleanupOnly=[bool]$CleanupOnly;Error=$null;PreferencesRestored=$false;TaskRemoved=$false;TraceStopped=$false;Restored=$false;ApplicationAbsent=$false;CrashEventCount=$null;ProcessEvidence=$null;KernelEvents=@();ShutdownEvent=$null;CleanStopEvent=$null;BootUtc=$null;PendingEmpty=$false;ReferencePreserved=$false;CleanupErrors=@()}
function Read-Events([hashtable]$Filter){
    try{return @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop)}catch{if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){return @()};throw}
}
try{
    if(@(Get-Process laqay -ErrorAction SilentlyContinue).Count){throw 'A product process remains in the collection boot.'}
    $r.ApplicationAbsent=$true
    if(-not $CleanupOnly){
        $guest=Get-Content -LiteralPath (Join-Path $root 'guest.json') -Raw|ConvertFrom-Json
        $trace=Get-Content -LiteralPath (Join-Path $root 'trace.json') -Raw|ConvertFrom-Json
        if($guest.LabId -cne $LabId -or $guest.CycleId -cne $CycleId -or $guest.Status -cne 'ShutdownRequested' -or $guest.Error -or $guest.CleanupErrors.Count -or
            $guest.ExecutableSha256 -ine $ExpectedExecutableSha256 -or $trace.LabId -cne $LabId -or $trace.CycleId -cne $CycleId -or -not $trace.Started -or
            $trace.Path -cne (Join-Path $root 'process.etl') -or $trace.Name -cne ('LaqayShutdown-'+$CycleId) -or $trace.PersistedCollector){throw 'Unexpected guest shutdown scope or state.'}
        $held=$guest.PendingAtShutdown;$proof=$guest.PendingWaitProof
        if(-not $guest.Reference.Passed -or -not $held.Requested -or $held.Released -or $held.Rendered -or $held.TimedOut -or $held.Error -or -not $held.OwnerMatches -or
            $held.PayloadBytes -le 0 -or $held.Sequence -ne $held.PublishedSequence -or $held.ProviderPid -ne $guest.ParentPid -or -not $proof.Confirmed -or
            $proof.LabId -cne $LabId -or $proof.RunId -cne $CycleId -or $proof.ApplicationPid -ne $guest.ApplicationPid -or $proof.ProviderPid -ne $guest.ParentPid -or
            $proof.ProviderThreadId -ne $held.ProviderThreadId -or $proof.SessionId -ne $guest.SessionId){throw 'Pending image ownership or native read was not established.'}
        if(($guest.ShutdownCommand -join '|') -cne ((Get-ShutdownArguments $CycleId)-join '|')){throw 'The shutdown command was not the non-forced command.'}
        $r.BootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        if([DateTimeOffset]::Parse($r.BootUtc) -le [DateTimeOffset]::Parse($guest.ShutdownRequestedUtc) -or
            [DateTimeOffset]::Parse($guest.CreatedUtc) -lt [DateTimeOffset]::Parse($trace.StartedUtc)){throw 'Trace, process and subsequent boot chronology differs.'}
        $file=Get-Item -LiteralPath $trace.Path
        if($file.Length -le 0 -or $file.Length -gt 34MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The trace file is empty, unbounded or redirected.'}
        $raw=@(Get-WinEvent -Path $trace.Path -Oldest -MaxEvents 4097 -ErrorAction Stop)
        if($raw.Count -gt 4096){throw 'Too many trace events for bounded validation.'}
        $events=@($raw|Where-Object {$_.ProviderName -ceq 'Microsoft-Windows-Kernel-Process' -and $_.Id -in @(1,2)})
        $converted=@($events|ForEach-Object {Convert-ShutdownProcessEvent $_.ToXml()})
        $r.KernelEvents=@($converted|Where-Object Pid -eq $guest.ApplicationPid)
        $expected=[pscustomobject]@{Pid=$guest.ApplicationPid;CreatedUtc=$guest.CreatedUtc;ParentPid=$guest.ParentPid;SessionId=$guest.SessionId;ShutdownRequestedUtc=$guest.ShutdownRequestedUtc}
        $r.ProcessEvidence=Test-ShutdownProcessEvidence $converted $expected
        $from=[DateTimeOffset]::Parse($trace.StartedUtc).UtcDateTime
        $shutdowns=@(Read-Events @{LogName='System';Id=1074;StartTime=$from}|Where-Object {
            if($_.ProviderName -cne 'User32'){return $false}
            $x=[xml]$_.ToXml();@($x.Event.EventData.Data|Where-Object { $_.InnerText -ceq ('Laqay shutdown '+$CycleId) }).Count -eq 1
        })
        if($shutdowns.Count -ne 1){throw 'The exact Windows shutdown event is missing or ambiguous.'}
        $r.ShutdownEvent=$shutdowns[0].ToXml()
        $clean=@(Read-Events @{LogName='System';ProviderName='EventLog';Id=6006;StartTime=$from}|Where-Object {$_.TimeCreated.ToUniversalTime() -lt [DateTimeOffset]::Parse($r.BootUtc).UtcDateTime})
        $crashes=@(Read-Events @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Power';Id=41;StartTime=$from})
        $r.CrashEventCount=$crashes.Count
        if($clean.Count -ne 1 -or $crashes.Count){throw 'Clean guest shutdown without a crash was not established.'}
        $r.CleanStopEvent=$clean[0].ToXml()
        $runRoot='C:\LaqayLab\Runs\'+$CycleId
        $pending=Join-Path $runRoot 'pending';$reference=Join-Path $runRoot 'control'
        foreach($folder in @($runRoot,$pending,$reference)){
            if(-not (Test-Path -LiteralPath $folder -PathType Container) -or ((Get-Item -LiteralPath $folder).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected post-shutdown fixture directory.'}
        }
        $r.PendingEmpty=@(Get-ChildItem -LiteralPath $pending -Force).Count -eq 0
        $files=@(Get-ChildItem -LiteralPath $reference -Force)
        $r.ReferencePreserved=$files.Count -eq 1 -and -not $files[0].PSIsContainer -and $files[0].FullName -ieq $guest.Reference.Path -and (Get-FileHash -LiteralPath $files[0].FullName).Hash -ieq $guest.Reference.Sha256
        if(-not $r.PendingEmpty -or -not $r.ReferencePreserved){throw 'Pending output or reference preservation differs.'}
        $r.Passed=$true
    }
}catch{$r.Error=$_.Exception.Message}
finally{
    try{
        $savedPath=Join-Path $root 'preferences-before.json'
        if(Test-Path -LiteralPath $savedPath){
            $saved=Get-Content -LiteralPath $savedPath -Raw|ConvertFrom-Json
            if($saved.LabId -cne $LabId -or $saved.CycleId -cne $CycleId -or $saved.Sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Unexpected preference snapshot ownership.'}
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay',$true)
            if(-not $key){throw 'The scoped preferences disappeared.'}
            try{
                if($saved.EnabledExisted){
                    if($saved.Kind -notin @('DWord','String')){throw 'Unexpected saved preference type.'}
                    $value=if($saved.Kind -eq 'DWord'){[int]$saved.Value}else{[string]$saved.Value}
                    $key.SetValue('Enabled',$value,([Enum]::Parse([Microsoft.Win32.RegistryValueKind],$saved.Kind)))
                    if([string]$key.GetValueKind('Enabled') -cne $saved.Kind -or $key.GetValue('Enabled') -cne $value){throw 'Preference restoration differs.'}
                }else{$key.DeleteValue('Enabled',$false);if($key.GetValueNames() -contains 'Enabled'){throw 'Temporary Enabled value remains.'}}
                $empty=$key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
            }finally{$key.Dispose()}
            if(-not $saved.KeyExisted){
                if(-not $empty){throw 'The newly created preference key is not empty.'}
                $software=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software',$true)
                try{$software.DeleteSubKey('Laqay',$false)}finally{$software.Dispose()}
            }
        }
        $r.PreferencesRestored=$true
    }catch{$r.CleanupErrors+=@($_.Exception.Message)}
    try{
        $name='LaqayShutdown-'+$CycleId;$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if($task){
            if(-not (Test-ShutdownTaskOwnership $task $CycleId)){throw 'Unexpected task ownership.'}
            if($task.State -eq 'Running'){throw 'The shutdown task unexpectedly survived into collection.'}
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        }
        $r.TaskRemoved=$null -eq (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)
    }catch{$r.CleanupErrors+=@($_.Exception.Message)}
    try{Stop-ShutdownTrace $LabId $CycleId;$r.TraceStopped=$true}catch{$r.CleanupErrors+=@($_.Exception.Message)}
    $r.Restored=$r.PreferencesRestored -and $r.TaskRemoved -and $r.TraceStopped -and $r.CleanupErrors.Count -eq 0
    if(-not $r.Restored){$r.Passed=$false}
    Write-ShutdownSnapshot (Join-Path $root 'collected.json') $r
}
[pscustomobject]$r
