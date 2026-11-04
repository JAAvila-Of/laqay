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
$jobName='Local\LaqayTerminalReceiver-'+$LabId+'-'+$RunId+'-'+$OwnerPid
$containmentSource=@'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
public static class LaqayTerminalSelfContainment {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenJobObjectW(uint access,bool inherit,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool contained);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static bool Enter(string name) {
        if(name==null || !Regex.IsMatch(name,@"^Local\\LaqayTerminalReceiver-[a-f0-9]{32}-[a-f0-9]{32}-[1-9][0-9]*$")) throw new ArgumentException("Unexpected receiver Job name.");
        IntPtr job=OpenJobObjectW(5,false,name);
        if(job==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"The pre-created receiver Job is unavailable.");
        try {
            if(!AssignProcessToJobObject(job,GetCurrentProcess())) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot enter the pre-created receiver Job.");
            bool contained;
            if(!IsProcessInJob(GetCurrentProcess(),job,out contained) || !contained) throw new InvalidOperationException("The receiver did not enter its dedicated Job.");
            return true;
        }finally{CloseHandle(job);}
    }
}
'@
Add-Type -TypeDefinition $containmentSource
$contained=[LaqayTerminalSelfContainment]::Enter($jobName)
$report=[ordered]@{LabId=$LabId;RunId=$RunId;Pid=$PID;OwnerPid=$OwnerPid;SessionId=$process.SessionId;Executable=$process.MainModule.FileName;ScriptSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash;JobName=$jobName;ContainedBeforeReady=$contained;Ready=$true;Inputs=@();Finished=$false;Error=$null}
function Save-Receiver {
    $temporary=$reportPath+'.tmp'
    if([IO.File]::Exists($temporary)){throw 'Refusing an existing report publication file.'}
    try{
        [IO.File]::WriteAllText($temporary,($report | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
        $deadline=[DateTime]::UtcNow.AddSeconds(2)
        while($true){
            try{
                if([IO.File]::Exists($reportPath)){[IO.File]::Replace($temporary,$reportPath,[NullString]::Value)}
                else{[IO.File]::Move($temporary,$reportPath)}
                break
            }catch [IO.IOException]{
                $code=$_.Exception.GetBaseException().HResult -band 0xFFFF
                if($code -notin @(32,33) -or [DateTime]::UtcNow -ge $deadline){throw}
                Start-Sleep -Milliseconds 20
            }
        }
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Assert-True($condition,[string]$message){if(-not $condition){throw $message}}
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
