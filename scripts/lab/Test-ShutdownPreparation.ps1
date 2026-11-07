$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ShutdownEvidence.ps1')
$cycle='0123456789abcdef0123456789abcdef'
$arguments=Get-ShutdownArguments $cycle
if(($arguments -join '|') -cne ('/s|/t|0|/d|p:0:0|/c|Laqay shutdown '+$cycle)){throw 'Normal shutdown arguments changed.'}
function Must-Reject([scriptblock]$Action){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'Invalid shutdown evidence was accepted.'}}
Must-Reject {Get-ShutdownArguments 'invalid'}
Must-Reject {Assert-ShutdownGuest $cycle $cycle}
$action=[pscustomobject]@{Arguments='-File "C:\LaqayLab\Runs\'+$cycle+'\Invoke-GuestShutdown.ps1"'}
foreach($triggers in @($null,@())){
    $task=[pscustomobject]@{Actions=@($action);Triggers=$triggers}
    if(-not (Test-ShutdownTaskOwnership $task $cycle)){throw 'A triggerless owned task was rejected.'}
}
foreach($task in @(
    [pscustomobject]@{Actions=@($action);Triggers=@([pscustomobject]@{Enabled=$true})},
    [pscustomobject]@{Actions=@($action,$action);Triggers=$null},
    [pscustomobject]@{Actions=$null;Triggers=$null},
    [pscustomobject]@{Actions=@([pscustomobject]@{Arguments='-File unrelated.ps1'});Triggers=$null}
)){
    if(Test-ShutdownTaskOwnership $task $cycle){throw 'An unrelated or triggered task was accepted.'}
}
$created='2026-01-01T01:00:00.0000000Z'
$requested='2026-01-01T01:00:10.0000000Z'
function Event-Xml([int]$Id,[string]$Extra){
    return '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="Microsoft-Windows-Kernel-Process" Guid="{22fb2cd6-0e7b-422b-a0c7-2fad1fd0e716}"/><EventID>'+ $Id + '</EventID></System><EventData><Data Name="ProcessID">42</Data><Data Name="CreateTime">'+$created+'</Data>'+ $Extra + '</EventData></Event>'
}
$startXml=Event-Xml 1 '<Data Name="ParentProcessID">41</Data><Data Name="SessionID">1</Data><Data Name="ImageName">C:\LaqayLab\App\laqay.exe</Data>'
$stopXml=Event-Xml 2 '<Data Name="ExitTime">2026-01-01T01:00:13.0000000Z</Data><Data Name="ExitCode">0</Data>'
$events=@((Convert-ShutdownProcessEvent $startXml),(Convert-ShutdownProcessEvent $stopXml))
$expected=[pscustomobject]@{Pid=42;ParentPid=41;SessionId=1;CreatedUtc=$created;ShutdownRequestedUtc=$requested}
$proof=Test-ShutdownProcessEvidence $events $expected
if(-not $proof.Passed -or $proof.ExitCode -ne 0){throw 'The complete synthetic lifetime was not accepted.'}
foreach($bad in @(
    $startXml.Replace('Microsoft-Windows-Kernel-Process','Unrelated'),
    $startXml.Replace('22fb2cd6-0e7b-422b-a0c7-2fad1fd0e716','00000000-0000-0000-0000-000000000000'),
    $startXml.Replace('<Data Name="SessionID">1</Data>',''),
    $startXml.Replace('</EventData>','<Data Name="ProcessID">43</Data></EventData>'),
    $stopXml.Replace('>0</Data>','>invalid</Data>')
)){Must-Reject {Convert-ShutdownProcessEvent $bad}}
foreach($change in @(
    @{Text=$startXml;Old='>41<';New='>40<';Index=0},
    @{Text=$startXml;Old='Name="SessionID">1<';New='Name="SessionID">2<';Index=0},
    @{Text=$startXml;Old='laqay.exe';New='unrelated.exe';Index=0},
    @{Text=$stopXml;Old='>0</Data>';New='>1</Data>';Index=1},
    @{Text=$stopXml;Old=$created;New='2026-01-01T00:00:00.0000000Z';Index=1},
    @{Text=$stopXml;Old='01:00:13';New='01:00:09';Index=1},
    @{Text=$stopXml;Old='01:00:13';New='01:02:00';Index=1}
)){
    $bad=@($events);$bad[$change.Index]=Convert-ShutdownProcessEvent ($change.Text.Replace($change.Old,$change.New))
    Must-Reject {Test-ShutdownProcessEvidence $bad $expected}
}
Must-Reject {Test-ShutdownProcessEvidence @($events[0]) $expected}
Must-Reject {Test-ShutdownProcessEvidence @($events[0],$events[1],$events[1]) $expected}
Must-Reject {Convert-ShutdownProcessEvent ('<!DOCTYPE Event [<!ENTITY bad SYSTEM "file:///not-read">]>'+$startXml)}
$root=Join-Path ([IO.Path]::GetTempPath()) ('LaqayShutdownFixture-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$path=Join-Path $root 'state.json'
try{
    Write-ShutdownSnapshot $path @{Text=('first-'+[char]0x03a9)}
    $reader=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{
        Write-ShutdownSnapshot $path @{Text='second'}
        $text=[IO.StreamReader]::new($reader,[Text.Encoding]::UTF8)
        try{if(($text.ReadToEnd()|ConvertFrom-Json).Text -cne ('first-'+[char]0x03a9)){throw 'The old reader lost its complete snapshot.'}}finally{$text.Dispose()}
    }finally{$reader.Dispose()}
    $lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{Must-Reject {Write-ShutdownSnapshot $path @{Text='blocked'}}}finally{$lock.Dispose()}
    if((Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json).Text -cne 'second' -or @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count){throw 'Failed publication changed evidence or left staging.'}
    Write-ShutdownSnapshot $path @{Text='recovered'}
}finally{
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
    [IO.Directory]::Delete($root,$false)
}
& (Join-Path $PSScriptRoot 'Invoke-GuestShutdown.ps1') -PrepareOnly
& (Join-Path $PSScriptRoot 'Invoke-ShutdownRuntimePhase.ps1') -PrepareOnly
Write-Output 'Shutdown protocol preparation passed: exact lifetime, nonzero/missing/reused process rejection, normal arguments and unarmed desktop guards; no trace, shutdown or input executed.'
