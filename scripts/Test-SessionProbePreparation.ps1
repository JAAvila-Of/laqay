$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-PreferencesProbe.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The preferences/session probe has syntax errors.'}
function Get-Guard([string]$message){
    $matches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains($message)},$true))
    if($matches.Count -ne 1){throw 'The actual probe guard is missing or ambiguous.'}
    [scriptblock]::Create($matches[0].Extent.Text)
}
$explicit=Get-Guard 'Session notification checks require the explicit isolated automated mode.'
$hosted=Get-Guard 'Automated normal-mode application checks require a GitHub-hosted isolated runner.'
function Check-Guard($guard,[bool]$mustReject){
    $rejected=$false;try{& $guard}catch{$rejected=$true}
    if($rejected -ne $mustReject){throw 'The actual session probe scope guard accepted or rejected the wrong mode.'}
}
$previousActions=$env:GITHUB_ACTIONS;$previousRunner=$env:RUNNER_ENVIRONMENT
try{
    $Scenario='SessionEnd';$Automated=$false;Check-Guard $explicit $true
    $Automated=$true;Check-Guard $explicit $false
    $Scenario='Enabled';$Automated=$false;Check-Guard $explicit $false
    $Automated=$true;$env:GITHUB_ACTIONS='false';$env:RUNNER_ENVIRONMENT='github-hosted';Check-Guard $hosted $true
    $env:GITHUB_ACTIONS='true';$env:RUNNER_ENVIRONMENT='self-hosted';Check-Guard $hosted $true
    $env:RUNNER_ENVIRONMENT='github-hosted';Check-Guard $hosted $false
}finally{$env:GITHUB_ACTIONS=$previousActions;$env:RUNNER_ENVIRONMENT=$previousRunner}
Write-Output 'Six actual session-probe scope checks passed without launching an application or sending messages.'
