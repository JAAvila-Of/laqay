$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'Invoke-RdpSmoke.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The RDP runner did not parse.'}
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-RdpTaskSessionComparison'},$true)
if(-not $function){throw 'The actual task session comparison is missing.'}
Invoke-Expression $function.Extent.Text
function Assert-True($condition,[string]$message){if(-not $condition){throw $message}}
$client=[pscustomobject]@{SessionId=1};$peer=[pscustomobject]@{SessionId=2}
$result=Get-RdpTaskSessionComparison $client $peer 1 2 2
Assert-True ($result.Complete -and $result.Matches -and $result.ObservedPrimary -eq 1 -and $result.ObservedPeer -eq 2) 'Matching sessions were not accepted or retained.'
foreach($pair in @(@($null,$peer),@($client,$null),@($null,$null))){
    $result=Get-RdpTaskSessionComparison $pair[0] $pair[1] 1 2 2
    Assert-True (-not $result.Complete -and -not $result.Matches) 'Missing reports were treated as a completed comparison.'
}
foreach($pair in @(@([pscustomobject]@{SessionId=9},$peer),@($client,[pscustomobject]@{SessionId=9}),@([pscustomobject]@{},$peer),@($client,[pscustomobject]@{}))){
    $result=Get-RdpTaskSessionComparison $pair[0] $pair[1] 1 2 2
    Assert-True ($result.Complete -and -not $result.Matches) 'A wrong or missing reported session ID was accepted or deferred.'
}
$result=Get-RdpTaskSessionComparison $client $peer 1 2 3
Assert-True ($result.Complete -and -not $result.Matches) 'A server-session mismatch was accepted.'
foreach($ids in @(@(0,2,2),@(1,0,2),@(1,2,0))){
    $rejected=$false;try{Get-RdpTaskSessionComparison $client $peer $ids[0] $ids[1] $ids[2] | Out-Null}catch{$rejected=$true}
    Assert-True $rejected 'Unbound expected session IDs were accepted.'
}
# Execute the real loop-completion branch with a missing then valid report.
$completion=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$peer.Report.FinishedUtc -and $peer.State -ne ''Running'''},$true)
if(-not $completion){throw 'The actual completion branch is missing.'}
$report=@{ServerSessionId=2};$targetSessions=@{Primary=1;Peer=2};$script:saves=0
function Save-Report {$script:saves++}
$peer=[pscustomobject]@{State='Ready';Report=[pscustomobject]@{SessionId=2;FinishedUtc='finished'}}
$script:iterations=0
$body=[scriptblock]::Create('foreach($snapshot in @($null,[pscustomobject]@{SessionId=1})){ $script:iterations++;$client=[pscustomobject]@{Report=$snapshot};'+$completion.Extent.Text+'}')
& $body
Assert-True ($script:iterations -eq 2 -and $script:saves -eq 2 -and $report.TaskSessionComparison.Matches) 'A transient missing report ended the poll or its final comparison was lost.'
$script:iterations=0
$body=[scriptblock]::Create('foreach($snapshot in @([pscustomobject]@{SessionId=9},[pscustomobject]@{SessionId=1})){ $script:iterations++;$client=[pscustomobject]@{Report=$snapshot};'+$completion.Extent.Text+'}')
& $body
Assert-True ($script:iterations -eq 1 -and -not $report.TaskSessionComparison.Matches) 'A valid wrong-session report was retried into a passing comparison.'
$pending=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '-not $report.TaskSessionComparison.Complete'},$true)
$mismatch=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '-not $report.TaskSessionComparison.Matches'},$true)
if(-not $pending -or -not $mismatch){throw 'The final session identity guards are missing.'}
$guards=[scriptblock]::Create($pending.Extent.Text+"`n"+$mismatch.Extent.Text)
foreach($scenario in @(
    @{Complete=$false;Matches=$false;Error='The final task session reports were unavailable before the deadline.'},
    @{Complete=$true;Matches=$false;Error='A task ran in a different guest session than requested.'},
    @{Complete=$true;Matches=$true;Error=$null}
)){
    $report.TaskSessionComparison=[pscustomobject]$scenario;$observed=$null
    try{& $guards}catch{$observed=$_.Exception.Message}
    Assert-True ($observed -ceq $scenario.Error) 'The actual final guard accepted an invalid comparison or mislabeled pending reports.'
}
Write-Output '17 task-session comparison and actual completion/final-guard scenarios passed; no VM or input was used.'
