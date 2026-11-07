param(
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath,
    [Parameter(Mandatory = $true)]
    [string]$MetadataPath
)

$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'Test-VersionResource.ps1'
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$proof = & $checker -BinaryPath $binary -MetadataPath $MetadataPath
$original = Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8
$root = Join-Path ([IO.Path]::GetTempPath()) ('laqay-version-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
$changed = Join-Path $root 'metadata.json'
$inert = Join-Path $root 'no-resource.exe'
$rejections = @()
try {
    $cases = [ordered]@{
        StaleVersion = { param($data) ($data.packages | Where-Object { $_.name -ceq 'laqay' -and $_.id -cin $data.workspace_members }).version = '65535.0.0' }
        WrongDescription = { param($data) ($data.packages | Where-Object { $_.name -ceq 'laqay' -and $_.id -cin $data.workspace_members }).description = 'Unrelated product.' }
        MissingWorkspace = { param($data) $data.workspace_members = @() }
        DuplicatePackage = { param($data) $data.packages = @($data.packages) + @($data.packages | Where-Object { $_.name -ceq 'laqay' -and $_.id -cin $data.workspace_members }) }
    }
    foreach ($name in $cases.Keys) {
        $data = $original | ConvertFrom-Json
        & $cases[$name] $data
        $data | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $changed -Encoding UTF8
        $rejected = $false
        try { & $checker -BinaryPath $binary -MetadataPath $changed | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw "Version gate accepted invalid metadata: $name" }
        $rejections += $name
    }
    [IO.File]::WriteAllBytes($inert, [byte[]]@(0x4d, 0x5a, 0, 0))
    $rejected = $false
    try { & $checker -BinaryPath $inert -MetadataPath $MetadataPath | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Version gate accepted a resource-free inert file.' }
    $rejections += 'MissingResource'
    $after = & $checker -BinaryPath $binary -MetadataPath $MetadataPath
    if ($after.BinarySha256 -cne $proof.BinarySha256) { throw 'Validation changed the executable.' }
    [pscustomobject]@{ Passed = $true; Cases = 7; Rejected = $rejections; Resource = $proof; Executed = $false }
}
finally {
    foreach ($path in @($changed, $inert)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction Stop }
    }
    [IO.Directory]::Delete($root, $false)
}
