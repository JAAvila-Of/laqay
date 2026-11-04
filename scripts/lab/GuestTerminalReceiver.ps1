[CmdletBinding()]
param([string]$LabId,[string]$RunId,[int]$OwnerPid)
$ErrorActionPreference='Stop'
if($LabId -notmatch '^[a-f0-9]{32}$' -or $RunId -notmatch '^[a-f0-9]{32}$' -or $OwnerPid -le 0 -or $PSScriptRoot -cne ('C:\LaqayLab\Runs\'+$RunId+'\real-apps\Terminal')){throw 'Unexpected Terminal receiver identity.'}
$ready=Get-Content -LiteralPath 'C:\LaqayLab\ready.json' -Raw | ConvertFrom-Json
$machine=Get-CimInstance Win32_ComputerSystem
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
$process=[Diagnostics.Process]::GetCurrentProcess()
if($ready.LabId -ne $LabId -or $ready.Role -ne 'Primary' -or -not $ready.Ready -or $machine.Manufacturer -ne 'Microsoft Corporation' -or $machine.Model -ne 'Virtual Machine' -or $identity.Name -ne ($env:COMPUTERNAME+'\LaqayLab') -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $process.SessionId -le 0){throw 'The Terminal receiver requires the limited disposable Primary session.'}
for($directory=Get-Item -LiteralPath $PSScriptRoot;$null -ne $directory;$directory=$directory.Parent){if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A Terminal receiver ancestor is a reparse point.'}}
if([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'owner.txt')) -cne ('LaqayRealApplication:'+$RunId+':Terminal:'+$OwnerPid)){throw 'The Terminal receiver owner does not match.'}
$owner=Get-Process -Id $OwnerPid
if($owner.SessionId -ne $process.SessionId -or $owner.ProcessName -ne 'powershell'){throw 'The Terminal receiver has no matching guest helper.'}
$reportPath=Join-Path $PSScriptRoot 'receiver.json'
if(Test-Path -LiteralPath $reportPath){throw 'Refusing a reused Terminal receiver report.'}
$report=[ordered]@{LabId=$LabId;RunId=$RunId;Pid=$PID;OwnerPid=$OwnerPid;SessionId=$process.SessionId;Executable=$process.MainModule.FileName;ScriptSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash;Ready=$true;Inputs=@();Finished=$false;Error=$null}
function Save-Receiver {
    $temporary=$reportPath+'.tmp'
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
    if(Test-Path -LiteralPath $reportPath){[IO.File]::Replace($temporary,$reportPath,$null)}else{[IO.File]::Move($temporary,$reportPath)}
}
try{
    [Console]::WriteLine('Laqay Terminal clipboard receiver. Input is stored as data only.')
    Save-Receiver
    for($index=1;$index -le 2;$index++){
        [Console]::WriteLine('Input '+$index+':')
        $line=[Console]::ReadLine()
        if($null -eq $line){throw 'The Terminal receiver input ended before both references.'}
        $report.Inputs+=@([pscustomobject]@{Index=$index;Text=$line})
        Save-Receiver
    }
    [Console]::WriteLine('Ready for the image reference.')
    $deadline=[DateTime]::UtcNow.AddMinutes(5)
    while(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'stop.txt'))){if([DateTime]::UtcNow -ge $deadline){throw 'The Terminal receiver shutdown deadline expired.'};Start-Sleep -Milliseconds 50}
    if([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stop.txt')) -cne $RunId){throw 'Unexpected Terminal shutdown marker.'}
    $report.Finished=$true
}catch{$report.Error=$_.Exception.Message;throw}finally{Save-Receiver}
