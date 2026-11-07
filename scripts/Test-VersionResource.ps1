param(
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath,
    [Parameter(Mandatory = $true)]
    [string]$MetadataPath
)

$ErrorActionPreference = 'Stop'
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$metadata = Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
$packages = @($metadata.packages | Where-Object {
    $_.name -ceq 'laqay' -and $_.id -cin $metadata.workspace_members
})
if ($packages.Count -ne 1) { throw 'Expected exactly one Laqay workspace package.' }
$package = $packages[0]
$version = [regex]::Match($package.version, '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?<pre>-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
if (-not $version.Success) { throw 'Invalid package version.' }
$parts = @(1..3 | ForEach-Object { [uint16]$version.Groups[$_].Value }) + @(0)
$numeric = $parts -join '.'
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($binary)
$expected = [ordered]@{
    ProductName = 'Laqay'; InternalName = $package.name; OriginalFilename = 'laqay.exe'
    FileDescription = $package.description; FileVersion = $numeric; ProductVersion = $package.version
}
foreach ($key in $expected.Keys) {
    if ($info.$key -cne $expected[$key]) { throw "Executable version resource mismatch: $key" }
}
$fileParts = @($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart) -join '.'
$productParts = @($info.ProductMajorPart, $info.ProductMinorPart, $info.ProductBuildPart, $info.ProductPrivatePart) -join '.'
if ($fileParts -cne $numeric -or $productParts -cne $numeric -or
    $info.IsPreRelease -ne $version.Groups['pre'].Success) {
    throw 'Executable fixed version or prerelease flag differs from Cargo.'
}
$stream = [IO.File]::OpenRead($binary)
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
finally { $sha.Dispose(); $stream.Dispose() }
[pscustomobject]@{
    Passed = $true; Executed = $false; BinarySha256 = $hash
    ProductName = $info.ProductName; FileVersion = $info.FileVersion
    ProductVersion = $info.ProductVersion; IsPreRelease = $info.IsPreRelease
}
