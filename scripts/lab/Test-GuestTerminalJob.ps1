# Exercise the actual receiver enrollment in hidden, owned .NET child processes.
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'GuestTerminalReceiver.ps1'),[ref]$null,[ref]$null)
$source=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$containmentSource'},$true))
if($source.Count -ne 1){throw 'The actual receiver containment source is ambiguous.'}
$native=$source[0].Right.Expression.Value
$fixture=@'
public static class ReceiverJobFixture {
    public static int Main(string[] args) {
        try {
            if(!LaqayTerminalSelfContainment.Enter(args[0])) return 3;
            System.Console.WriteLine("Contained");System.Console.Out.Flush();
            if(args[1]=="hold") System.Threading.Thread.Sleep(30000);
            return 0;
        }catch(System.Exception error){System.Console.Error.WriteLine(error.Message);return 2;}
    }
}
'@
$id=[guid]::NewGuid().ToString('N')
$directory=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('LaqayReceiverJobTest-'+$id)))
$executable=Join-Path $directory 'receiver-fixture.exe'
$type=[LaqayGuestDesktop].GetNestedType('RealApplication',[Reflection.BindingFlags]::NonPublic)
$flags=[Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
$create=$type.GetMethod('NewJob',$flags);$active=$type.GetMethod('Active',$flags)
$close=[LaqayGuestDesktop].GetMethod('CloseHandle',$flags)
if(-not $create -or -not $active -or -not $close){throw 'The actual application Job operations are unavailable.'}
[IO.Directory]::CreateDirectory($directory) | Out-Null
$job=[IntPtr]::Zero;$child=$null
function Start-ReceiverFixture([string]$name,[string]$mode){
    $info=[Diagnostics.ProcessStartInfo]::new($executable)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.WorkingDirectory=$directory;$info.Arguments='"'+$name+'" '+$mode
    return [Diagnostics.Process]::Start($info)
}
try{
    Add-Type -TypeDefinition ($native+[Environment]::NewLine+$fixture) -OutputAssembly $executable -OutputType ConsoleApplication
    $name=[LaqayGuestDesktop]::RealTerminalReceiverJobName($id,$id,$PID)
    $child=Start-ReceiverFixture $name 'exit'
    if(-not $child.WaitForExit(5000) -or $child.ExitCode -ne 2){throw 'A receiver entered a Job that the owner had not created.'}
    $child.Dispose();$child=$null
    $job=$create.Invoke($null,[object[]]@($name))
    $rejected=$false;try{$unexpected=$create.Invoke($null,[object[]]@($name))}catch{$rejected=$_.Exception.ToString().Contains('Refusing an existing receiver Job.')}
    if(-not $rejected){if($unexpected -ne [IntPtr]::Zero){$close.Invoke($null,[object[]]@($unexpected)) | Out-Null};throw 'A named Job collision was accepted.'}
    $child=Start-ReceiverFixture $name 'exit'
    if(-not $child.WaitForExit(5000) -or $child.ExitCode -ne 0 -or $child.StandardOutput.ReadToEnd().Trim() -cne 'Contained' -or $active.Invoke($null,[object[]]@($job)) -ne 0){throw 'The actual receiver did not enroll and exit normally.'}
    $child.Dispose();$child=$null
    $child=Start-ReceiverFixture $name 'hold'
    $line=$child.StandardOutput.ReadLineAsync()
    if(-not $line.Wait(5000) -or $line.Result -cne 'Contained' -or $active.Invoke($null,[object[]]@($job)) -ne 1){throw 'The owned live receiver was not accounted in its dedicated Job.'}
    $close.Invoke($null,[object[]]@($job)) | Out-Null;$job=[IntPtr]::Zero
    if(-not $child.WaitForExit(5000)){throw 'The owned receiver survived the owner Job closing.'}
    $child.Dispose();$child=$null
    Write-Output 'Actual receiver enrollment rejected a missing Job and collisions, accounted normal exit, and enforced kill-on-close in owned hidden .NET children.'
}finally{
    if($job -ne [IntPtr]::Zero){$close.Invoke($null,[object[]]@($job)) | Out-Null}
    if($child){if(-not $child.HasExited){$child.Kill();if(-not $child.WaitForExit(5000)){throw 'The exact test child survived cleanup.'}};$child.Dispose()}
    if([IO.Path]::GetFullPath($directory) -ne $directory -or [IO.Path]::GetFileName($directory) -cne ('LaqayReceiverJobTest-'+$id)){throw 'Unexpected receiver-test cleanup path.'}
    [IO.Directory]::Delete($directory,$true)
}
