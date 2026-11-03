$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot 'Get-GuestApplicationInventory.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Inventory script parsing failed.'}
$command=$ast.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Command'},$true)
$block=@($command.CommandElements | Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]})[0].ScriptBlock.GetScriptBlock()
$labId=[guid]::NewGuid().ToString('N');$script:mode='Missing';$script:metadataTouched=$false
# Execute the actual guest block against inert identity fixtures. Reject before
# any file inventory, package query, application launch, or real remoting.
function Test-Path {param($LiteralPath) if($LiteralPath -ne 'C:\LaqayLab\ready.json'){throw 'Unexpected file inspection.'};$script:mode -ne 'Missing'}
function Get-Content {param($LiteralPath,[switch]$Raw)
    if($LiteralPath -ne 'C:\LaqayLab\ready.json'){throw 'Unexpected file read.'}
    @{LabId=$(if($script:mode -eq 'WrongLab'){'00000000000000000000000000000000'}else{$labId});Role=$(if($script:mode -eq 'WrongRole'){'Peer'}else{'Primary'});Ready=$true} | ConvertTo-Json
}
function Get-CimInstance {param($ClassName)
    if($ClassName -eq 'Win32_ComputerSystem'){
        if($script:mode -eq 'Physical'){return [pscustomobject]@{Manufacturer='Inert fixture';Model='Physical'}}
        return [pscustomobject]@{Manufacturer='Microsoft Corporation';Model='Virtual Machine'}
    }
    if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{Caption='Inert unsupported operating system'}}
    throw 'Unexpected metadata query.'
}
function Get-Process {$script:metadataTouched=$true;throw 'Unexpected process query.'}
function Get-AppxPackage {$script:metadataTouched=$true;throw 'Unexpected package query.'}
foreach($mode in @('Missing','WrongLab','WrongRole','Physical','WrongOs')){
    $script:mode=$mode;$rejected=$false
    try{& $block $labId | Out-Null}catch{
        if($_.Exception.Message -notlike 'Unexpected inventory guest *'){throw};$rejected=$true
    }
    if(-not $rejected -or $script:metadataTouched){throw ('Inventory identity rejection failed: '+$mode)}
}
Write-Output 'Actual guest inventory block rejected missing/wrong marker, peer, physical hardware and unsupported OS before metadata collection.'
