# Exercise the real normal-mode launch and log routing with inert controls.
$ErrorActionPreference='Stop'
if(-not ('LaqayGuestDesktop' -as [type])){& (Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly}
$flags=[Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
$factory=[LaqayGuestDesktop].GetMethod('ApplicationStartInfo',$flags)
$before=[Environment]::GetEnvironmentVariable('LAQAY_DIAGNOSTICS')
foreach($diagnostic in @($false,$true)){
    $info=$factory.Invoke($null,@('C:\LaqayLab\App\laqay.exe','',$diagnostic,$diagnostic))
    if($info.Arguments -cne '' -or $info.UseShellExecute -or -not $info.CreateNoWindow -or $info.RedirectStandardOutput -ne $diagnostic -or $info.RedirectStandardError -ne $diagnostic){throw 'Normal diagnostic launch changed application mode or stream ownership.'}
    if($diagnostic){if($info.EnvironmentVariables['LAQAY_DIAGNOSTICS'] -cne '1'){throw 'The child did not receive explicit diagnostics.'}}
    elseif($info.EnvironmentVariables.ContainsKey('LAQAY_DIAGNOSTICS')){throw 'The ordinary child inherited diagnostic opt-in.'}
}
if([Environment]::GetEnvironmentVariable('LAQAY_DIAGNOSTICS') -cne $before){throw 'The child launch changed the parent environment.'}
$failureFactory=[LaqayGuestDesktop].GetMethod('FailureAwareStartInfo',$flags)
$failureInfo=$failureFactory.Invoke($null,@('C:\LaqayLab\App\laqay.exe','',$true,$true,$true))
if($failureInfo.EnvironmentVariables['LAQAY_DIAGNOSTICS'] -cne 'failures' -or $failureInfo.Arguments -cne '' -or -not $failureInfo.RedirectStandardOutput -or -not $failureInfo.RedirectStandardError){throw 'The failure-only diagnostic child changed its mode or stream capture.'}
$rejected=$false;try{$failureFactory.Invoke($null,@('fixture','',$true,$false,$true))|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Failure diagnostics without explicit diagnostic capture were accepted.'}
if([Environment]::GetEnvironmentVariable('LAQAY_DIAGNOSTICS') -cne $before){throw 'Failure diagnostics changed the parent environment.'}
$rejected=$false;try{[LaqayGuestDesktop]::StartNormalRdpDiagnosticApplication('invalid')|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Unarmed normal-mode diagnostics were accepted.'}
Add-Type @'
public class NormalRdpLogReceipt {
    public string Output;
    public bool Drained;
    public bool Truncated;
    public int MaximumCharacters;
}
public static class NormalRdpLogFixture {
    public static int ApplicationExitCode=0;
    public static bool WasApplicationForced=false;
    public static bool Drained=true;
    public static string Output="normal original";
    public static int StartApplication(string path) {return 11;}
    public static int StartNormalRdpDiagnosticApplication(string path) {return 22;}
    public static bool CloseApplication() {return true;}
    public static object CoreTrialLog() {return new NormalRdpLogReceipt {Output=Output,Drained=Drained,Truncated=false,MaximumCharacters=262144};}
}
'@
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1'),[ref]$null,[ref]$null)
$launch=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($IncludeRdp)') -and $n.Extent.Text.Contains('StartNormalRdpDiagnosticApplication')},$true))
$close=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($applicationStarted)') -and $n.Extent.Text.Contains('NormalModeLog')},$true))
$trial=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains('$tabTrialTarget=Get-RdpTabTrialTarget')},$true))
if($launch.Count -ne 1 -or $close.Count -ne 1 -or $trial.Count -ne 1 -or $close[0].Extent.EndOffset -ge $trial[0].Extent.StartOffset){throw 'Normal logs must be collected before the supplementary trial can replace the capture buffer.'}
foreach($rdp in @($false,$true)){
    $IncludeRdp=$rdp;$report=@{Passed=$false;Error='Original failure';NormalModeLog=$null;CleanupErrors=@()};$applicationStarted=$true;$executable='inert'
    . ([scriptblock]::Create($launch[0].Extent.Text.Replace('[LaqayGuestDesktop]','[NormalRdpLogFixture]')))
    if($report.ApplicationPid -ne $(if($rdp){22}else{11})){throw 'The actual launch selected the wrong application entry point.'}
    [NormalRdpLogFixture]::Output='normal original'
    . ([scriptblock]::Create($close[0].Extent.Text.Replace('[LaqayGuestDesktop]','[NormalRdpLogFixture]')))
    [NormalRdpLogFixture]::Output='supplementary trial'
    if($report.Passed -or $report.Error -cne 'Original failure' -or $report.CleanupErrors.Count){throw 'Log collection changed the original failed result.'}
    if($rdp){if($report.NormalModeLog.Output -cne 'normal original'){throw 'A supplementary capture replaced the original normal-mode log.'}}
    elseif($report.NormalModeLog){throw 'The ordinary suite collected an RDP log.'}
}
[NormalRdpLogFixture]::Drained=$false;$IncludeRdp=$true;$report=@{Passed=$true;CleanupErrors=@()}
. ([scriptblock]::Create($close[0].Extent.Text.Replace('[LaqayGuestDesktop]','[NormalRdpLogFixture]')))
if($report.Passed -or $report.CleanupErrors.Count -ne 1){throw 'Undrained diagnostic readers were accepted as a clean suite.'}
# Exercise both actual bounded-buffer limits without starting an application.
$maximum=[LaqayGuestDesktop].GetField('trialLogMaximum',$flags);$buffer=[LaqayGuestDesktop].GetField('trialLog',$flags);$truncated=[LaqayGuestDesktop].GetField('trialLogTruncated',$flags)
$capture=[LaqayGuestDesktop].GetMethod('CaptureTrialLine',$flags)
$oldMaximum=$maximum.GetValue($null);$oldBuffer=$buffer.GetValue($null);$oldTruncated=$truncated.GetValue($null)
$done=[Threading.ManualResetEvent]::new($false)
try{
    foreach($limit in @(65536,262144)){
        $maximum.SetValue($null,$limit);$buffer.SetValue($null,[Text.StringBuilder]::new());$truncated.SetValue($null,$false)
        $capture.Invoke($null,@('fixture',('x'*($limit+1)),$done))|Out-Null
        $log=[LaqayGuestDesktop]::CoreTrialLog()
        if($log.Output.Length -ne $limit -or $log.MaximumCharacters -ne $limit -or -not $log.Truncated){throw 'A diagnostic buffer exceeded or lost its declared bound.'}
    }
}finally{$maximum.SetValue($null,$oldMaximum);$buffer.SetValue($null,$oldBuffer);$truncated.SetValue($null,$oldTruncated);$done.Dispose()}
Write-Output 'Normal diagnostic launch, child-only verbose/failure opt-in, preserved original failure/log, reader drain, and both capture bounds passed without input.'
