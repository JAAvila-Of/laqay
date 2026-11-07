$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'VirtualFileProof.ps1')
$bytes=[Text.Encoding]::UTF8.GetBytes("Laqay virtual file fixture.`r`n")
$sha=[Security.Cryptography.SHA256]::Create()
try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
function New-Proofs {
    @($false,$true) | ForEach-Object {
        $before=[pscustomobject]@{Current=$true;OwnerPid=41;SourcePid=41;SourceThread=10;Expired=$false;Error=$null;HasPng=$true;HasDescriptor=$true;HasContents=$true;HasFileDrop=$false;FileName='virtual-fixture.txt';Length=$bytes.Length;Sha256=$hash;ContentReads=0}
        $after=$before | ConvertTo-Json | ConvertFrom-Json;$after.ContentReads=1
        [pscustomobject]@{LaqayEnabled=$_;Before=$before;After=$after;Input=[pscustomobject]@{Foreground=$true;FocusWithinWindow=$true};ProviderClosed=$true;OnlyExpectedFile=$true;FileSha256=$hash;Error=$null}
    }
}
Assert-VirtualFileProof @(New-Proofs) 42
$mutations=@(
    {param($p) $p[1].LaqayEnabled=$false},
    {param($p) $p[1].Before.HasPng=$false},
    {param($p) $p[1].Before.HasFileDrop=$true},
    {param($p) $p[1].After.Current=$false},
    {param($p) $p[1].After.ContentReads=0},
    {param($p) $p[1].After.SourceThread=11},
    {param($p) $p[1].After.Expired=$true},
    {param($p) $p[1].ProviderClosed=$false},
    {param($p) $p[1].OnlyExpectedFile=$false},
    {param($p) $p[1].FileSha256='changed'},
    {param($p) $p[1].Before.Length=999},
    {param($p) $p[1].Input.Foreground=$false},
    {param($p) $p[1].Error='failed'}
)
foreach($mutation in $mutations){$proofs=@(New-Proofs);& $mutation $proofs;$rejected=$false;try{Assert-VirtualFileProof $proofs 42}catch{$rejected=$true};if(-not $rejected){throw 'A corrupted virtual-file proof was accepted.'}}
Write-Output 'Virtual-file report acceptance and 13 evidence-corruption rejections passed without clipboard access.'
function New-Stress {
    $frames=@(1..12 | ForEach-Object {[pscustomobject]@{Index=$_;File=('Screenshot_20260102_030405_'+('{0:D3}' -f $_)+'.png');Sha256=('A'*64);Responsive=$true;ElapsedMilliseconds=100;Input=[pscustomobject]@{Foreground=$true;FocusWithinWindow=$true;ItemsViewFocused=$true};Resources=[pscustomobject]@{Pid=42;WorkingSetBytes=1;PrivateBytes=1;Handles=1;Threads=1}}})
    [pscustomobject]@{Error=$null;Dimension=4096;RequiredCount=12;MinimumMilliseconds=30000;BudgetMilliseconds=120000;ElapsedMilliseconds=36000;Completed=$frames}
}
Assert-SustainedLargePngProof (New-Stress) 42
foreach($mutation in @(
    {param($p) $p.Completed=$p.Completed[0..10]},
    {param($p) $p.ElapsedMilliseconds=1000},
    {param($p) $p.ElapsedMilliseconds=120001},
    {param($p) $p.Dimension=2048},
    {param($p) $p.Completed[1].File=$p.Completed[0].File},
    {param($p) $p.Completed[1].Responsive=$false},
    {param($p) $p.Completed[1].Input.ItemsViewFocused=$false},
    {param($p) $p.Completed[1].Resources.Pid=999},
    {param($p) $p.Completed[1].Sha256='invalid'},
    {param($p) $p.Completed[1].Index=1}
)){$proof=New-Stress;& $mutation $proof;$rejected=$false;try{Assert-SustainedLargePngProof $proof 42}catch{$rejected=$true};if(-not $rejected){throw 'A corrupted sustained-PNG proof was accepted.'}}
Write-Output 'Sustained large-PNG report acceptance and 10 evidence-corruption rejections passed without image generation or input.'
