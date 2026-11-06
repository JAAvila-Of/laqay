# Exercise the actual reader and publisher using owned temporary files only.
$ErrorActionPreference='Stop'
function Get-FixtureFunction([string]$file,[string]$name){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'A receipt fixture source has syntax errors.'}
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if($functions.Count -ne 1){throw ('Expected one fixture function: '+$name)}
    return $functions[0].Extent.Text
}
. ([scriptblock]::Create((Get-FixtureFunction 'Invoke-GuestRealApplicationCases.ps1' 'Read-TerminalReceiver')))
$publisherSource=Get-FixtureFunction 'GuestTerminalReceiver.ps1' 'Save-Receiver'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public sealed class LaqayReceiptReadLock : IDisposable {
    readonly ManualResetEvent ready=new ManualResetEvent(false), release=new ManualResetEvent(false);
    readonly Thread worker;
    Exception error;
    public LaqayReceiptReadLock(string path,int milliseconds) {
        worker=new Thread(delegate() {
            try {using(var file=File.Open(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None)) {ready.Set();release.WaitOne(milliseconds);}}
            catch(Exception failure) {error=failure;ready.Set();}
        });
        worker.IsBackground=true;worker.Start();
        if(!ready.WaitOne(5000)) {Dispose();throw new Exception("The fixture lock did not start.");}
        if(error!=null) {Dispose();throw new Exception("The fixture lock failed.",error);}
    }
    public void Dispose() {release.Set();if(!worker.Join(5000)) throw new Exception("The fixture lock did not close.");ready.Dispose();release.Dispose();}
}
'@
$id=[guid]::NewGuid().ToString('N')
$root=Join-Path ([IO.Path]::GetTempPath()) ('LaqayReceiptRead-'+$id)
$directory=Join-Path $root 'real-apps/Terminal';$path=Join-Path $directory 'receiver.json'
$lock=$null;$publisher=$null;$pending=$null;$ready=$null
try{
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $reportPath=$path;$report=[ordered]@{Stage=1;Text=('Unicode '+[char]0x00F1+[char]0x6D4B);Passed=$false}
    . ([scriptblock]::Create($publisherSource))
    Save-Receiver
    if((Read-TerminalReceiver).Text -cne $report.Text){throw 'The Unicode receipt changed.'}
    $lock=[LaqayReceiptReadLock]::new($path,200)
    if((Read-TerminalReceiver).Stage -ne 1){throw 'The reader did not recover from a temporary sharing violation.'}
    $lock.Dispose();$lock=$null
    $lock=[LaqayReceiptReadLock]::new($path,10000);$rejected=$false;$watch=[Diagnostics.Stopwatch]::StartNew()
    try{Read-TerminalReceiver | Out-Null}catch [IO.IOException]{$rejected=($_.Exception.GetBaseException().HResult -band 0xFFFF) -eq 32}
    if(-not $rejected -or $watch.Elapsed.TotalSeconds -lt 1.8 -or $watch.Elapsed.TotalSeconds -gt 5){throw 'A retained lock did not fail within the read deadline.'}
    $lock.Dispose();$lock=$null
    if((Read-TerminalReceiver).Stage -ne 1){throw 'The receipt did not recover after lock release.'}
    [IO.File]::WriteAllText($path,'{broken');$rejected=$false
    try{Read-TerminalReceiver | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Malformed receipt JSON was accepted.'}
    [IO.File]::Delete($path);$rejected=$false;$watch.Restart()
    try{Read-TerminalReceiver | Out-Null}catch [IO.IOException]{$rejected=($_.Exception.GetBaseException().HResult -band 0xFFFF) -eq 2}
    if(-not $rejected -or $watch.Elapsed.TotalSeconds -lt 1.8 -or $watch.Elapsed.TotalSeconds -gt 5){throw 'A missing receipt did not fail within the read deadline.'}
    [IO.Directory]::CreateDirectory($path) | Out-Null;$rejected=$false;$watch.Restart()
    try{Read-TerminalReceiver | Out-Null}catch [UnauthorizedAccessException]{$rejected=$true}
    if(-not $rejected -or $watch.Elapsed.TotalSeconds -gt 1){throw 'An access failure was accepted or retried.'}
    [IO.Directory]::Delete($path)
    Save-Receiver
    $ready=[Threading.ManualResetEvent]::new($false)
    $publisher=[powershell]::Create()
    $code="param(`$source,`$reportPath,`$ready)`n . ([scriptblock]::Create(`$source));`n"+@'
$ErrorActionPreference='Stop'
try{
    for($stage=2;$stage -le 101;$stage++){
        $report=[ordered]@{Stage=$stage;Text=('Receipt '+$stage);Passed=$false}
        Save-Receiver
        $ready.Set() | Out-Null
        Start-Sleep -Milliseconds 1
    }
}finally{$ready.Set() | Out-Null}
'@
    [void]$publisher.AddScript($code).AddArgument($publisherSource).AddArgument($path).AddArgument($ready)
    $pending=$publisher.BeginInvoke()
    if(-not $ready.WaitOne(5000)){throw 'The concurrent publisher did not start.'}
    for($n=0;$n -lt 100;$n++){
        try{$snapshot=Read-TerminalReceiver}catch{
            $publisher.EndInvoke($pending) | Out-Null;$pending=$null
            if($publisher.HadErrors){throw ('Concurrent publication failed: '+($publisher.Streams.Error -join '; '))}
            throw
        }
        if($snapshot.Stage -lt 2 -or $snapshot.Stage -gt 101 -or $snapshot.Text -cne ('Receipt '+$snapshot.Stage)){throw 'A concurrent read returned an incomplete or mixed snapshot.'}
    }
    $publisher.EndInvoke($pending) | Out-Null;$pending=$null
    if($publisher.HadErrors -or (Read-TerminalReceiver).Stage -ne 101){throw 'The actual concurrent publisher failed or stopped early.'}
    Write-Output 'Terminal receipt reads passed Unicode, temporary/retained locks, recovery, malformed/missing data, and concurrent publication checks.'
}finally{
    if($lock){$lock.Dispose()}
    if($publisher){if($pending -and -not $pending.IsCompleted){$publisher.Stop()};$publisher.Dispose()}
    if($ready){$ready.Dispose()}
    if([IO.Path]::GetFullPath($root) -ne $root -or [IO.Path]::GetFileName($root) -cne ('LaqayReceiptRead-'+$id)){throw 'Unexpected receipt-test cleanup path.'}
    if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}
}
