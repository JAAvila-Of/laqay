# Compile the exact remote inspection block in a fresh, unarmed process.
# Invalid identities must fail before guest metadata, privileges or UI access.
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-DesktopSmoke.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The desktop controller has syntax errors.'}
$blocks=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Command'
},$true) | ForEach-Object {
    $_.CommandElements | Where-Object {
        $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $_.Extent.Text.Contains('::InspectJson(')
    }
})
if($blocks.Count -ne 1){throw 'Expected one remote wait-chain inspection block.'}
if('LaqayGuestWaitChain' -as [type]){throw 'The wait-chain compilation check requires a fresh process.'}
$rejected=$false
try{
    & $blocks[0].ScriptBlock.GetScriptBlock() 'invalid' 'invalid' $PSScriptRoot 0 0 0 0 | Out-Null
}catch{
    if($_.Exception.ToString().Contains('Invalid wait-chain lab identity.')){$rejected=$true}else{throw}
}
if(-not $rejected -or -not ('LaqayGuestWaitChain' -as [type])){throw 'The exact inspection block did not compile and reject an unowned run.'}
Write-Output 'The remote wait-chain helper compiled and rejected invalid ownership before guest access.'
