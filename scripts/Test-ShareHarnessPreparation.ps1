# Evaluate only the actual pure runner guard and plan, never SMB operations.
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-ShareFailure.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Assert-ShareRunner','Get-SharePlan')){
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($functions.Count -ne 1){throw 'The actual share planning function is ambiguous.'}
    . ([scriptblock]::Create($functions[0].Extent.Text))
}
foreach($case in @(@('','github-hosted','Windows',$true),@('true','self-hosted','Windows',$true),@('true','github-hosted','Linux',$true),@('true','github-hosted','Windows',$false))){
    $rejected=$false;try{Assert-ShareRunner @case}catch{$rejected=$true}
    if(-not $rejected){throw 'An unsupported runner passed the share guard.'}
}
Assert-ShareRunner 'true' 'github-hosted' 'Windows' $true
$token='0123456789abcdef0123456789abcdef'
$plan=Get-SharePlan 'C:\runner temp' $token
if($plan.Name -cne ('LaqayShare-'+$token) -or $plan.Unc -cne ('\\127.0.0.1\LaqayShare-'+$token) -or $plan.Data -cne ('C:\runner temp\Laqay.Share.'+$token+'\data') -or $plan.Control -cne ('C:\runner temp\Laqay.Share.'+$token+'\control')){throw 'The share plan changed its loopback or owned control/data identity.'}
foreach($case in @(@('relative',$token),@('C:\temp','../escape'),@(('C:\temp'+[char]10+'escape'),$token),@('C:\temp"quoted',$token))){
    $rejected=$false;try{Get-SharePlan @case | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'An unsafe share plan was accepted.'}
}
Write-Output 'Actual share runner guards and loopback ownership plan passed without SMB changes, network connections or Cargo.'
