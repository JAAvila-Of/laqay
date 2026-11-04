# Load only the actual pure planning/guard functions; never run the harness body.
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-StorageFailure.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Assert-StorageRunner','Get-StoragePlan')){
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($functions.Count -ne 1){throw 'The actual storage planning function is ambiguous.'}
    . ([scriptblock]::Create($functions[0].Extent.Text))
}
foreach($case in @(@('','github-hosted','Windows',$true),@('true','self-hosted','Windows',$true),@('true','github-hosted','Linux',$true),@('true','github-hosted','Windows',$false))){
    $rejected=$false;try{Assert-StorageRunner @case}catch{$rejected=$true}
    if(-not $rejected){throw 'An unsupported runner passed the storage guard.'}
}
Assert-StorageRunner 'true' 'github-hosted' 'Windows' $true
$token='0123456789abcdef0123456789abcdef'
$plan=Get-StoragePlan 'C:\runner temp' $token 'R'
if($plan.MaximumBytes -ne 64MB -or $plan.Commands.Count -ne 7 -or $plan.Image -cne ('C:\runner temp\Laqay.Storage.'+$token+'\scratch.vhd') -or $plan.Data -cne ('R:\LaqayStorageTest-'+$token) -or $plan.Commands[0] -cne ('create vdisk file="'+$plan.Image+'" maximum=64 type=expandable') -or ($plan.Commands -join ' ') -match '\b(select disk|clean|delete|expand vdisk)\b'){throw 'The bounded storage plan changed its identity, capacity or command scope.'}
foreach($case in @(@('relative',$token,'R'),@('C:\temp','../escape','R'),@('C:\temp',$token,'C'),@(('C:\temp'+[char]10+'exit'),$token,'R'),@('C:\temp"quoted',$token,'R'))){
    $rejected=$false;try{Get-StoragePlan @case | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'An unsafe storage plan was accepted.'}
}
Write-Output 'Actual storage runner guards and bounded VHD plan passed without mounting, formatting, writing filler or invoking Cargo.'
