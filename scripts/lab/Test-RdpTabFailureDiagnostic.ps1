# Test actual failure-diagnostic routing without guest controls or input.
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1'),[ref]$null,[ref]$null)
$target=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-RdpTabTrialTarget'},$true))
if($target.Count -ne 1){throw 'The tab diagnostic target function is ambiguous.'}
. ([scriptblock]::Create($target[0].Extent.Text))
$routing=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains('$tabTrialTarget=Get-RdpTabTrialTarget')},$true))
if($routing.Count -ne 1){throw 'The tab diagnostic routing is ambiguous.'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('Laqay.Rdp.Tab.'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $fixture 'run';$path=Join-Path $root 'data/tab-b'
function Invoke-RdpTabTrial($target){$script:called++;[pscustomobject]@{DiagnosticOnly=$true;PngCount=1;Window=$target.Window;Path=$target.Path}}
try{
    [IO.Directory]::CreateDirectory($path)|Out-Null
    $cases=@(0..7|ForEach-Object {[pscustomobject]@{Name='EarlierCase';Passed=$true}})+@([pscustomobject]@{Name='ActiveTabSelection';Passed=$false})
    $message='The expected image was not published in the active guest folder.'
    $template=@{GuestProfile='Windows11EnterpriseEvaluation';IncludeRdp=$true;SessionProtocol=2;Passed=$false;ApplicationClosed=$true;ApplicationExitCode=0;ForcedTermination=$false;Error=$message;Cases=$cases;TabNavigations=@(@{Passed=$true;SelectedTab='tab-b';Window=123;Path=$path});ImagePastes=@(@{CaseIndex=9;ExpectedCount=1;Published=$false;ObservedPngCount=0;Error=$message});CleanupErrors=@();RdpTabTrial=$null}
    foreach($variant in @('normal','console','profile','protocol','passed','alive','forced','exit','other-case','earlier-failure','navigation','sibling','output','occupied')){
        $report=$template|ConvertTo-Json -Depth 8|ConvertFrom-Json
        switch($variant){
            console {$report.IncludeRdp=$false}
            profile {$report.GuestProfile='Windows10ProEsMx'}
            protocol {$report.SessionProtocol=0}
            passed {$report.Passed=$true}
            alive {$report.ApplicationClosed=$false}
            forced {$report.ForcedTermination=$true}
            exit {$report.ApplicationExitCode=1}
            other-case {$report.Cases[8].Name='UnicodePathImagePaste'}
            earlier-failure {$report.Cases[0].Passed=$false}
            navigation {$report.TabNavigations[0].Passed=$false}
            sibling {$report.TabNavigations[0].Path=Join-Path $root 'data-sibling/tab-b'}
            output {$report.ImagePastes[0].ObservedPngCount=1}
            occupied {[IO.File]::WriteAllText((Join-Path $path 'keep.txt'),'Keep')}
        }
        $before=$report|ConvertTo-Json -Depth 8;$script:called=0
        . ([scriptblock]::Create($routing[0].Extent.Text))
        if($variant -ceq 'normal'){
            if($script:called -ne 1 -or -not $report.RdpTabTrial.DiagnosticOnly -or $report.Passed -or $report.Error -cne $message -or $report.Cases[8].Passed -or $report.Cases.Count -ne 9){throw 'Supplementary output changed suite acceptance.'}
        }elseif($script:called -ne 0 -or ($report|ConvertTo-Json -Depth 8) -cne $before){throw ('Rejected diagnostic changed report or reached controls: '+$variant)}
    }
    if([IO.File]::ReadAllText((Join-Path $path 'keep.txt')) -cne 'Keep'){throw 'The scope guard changed existing data.'}
    Write-Output '14 actual tab diagnostic routes passed; supplementary output cannot approve the failed suite.'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    if((Split-Path $resolved -Parent) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'Laqay.Rdp.Tab.*'){throw 'Refusing cleanup outside the owned fixture.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
