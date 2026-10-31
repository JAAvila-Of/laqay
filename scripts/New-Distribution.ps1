param(
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath,
    [Parameter(Mandatory = $true)]
    [string]$LicenseTextPath,
    [string]$OutputDirectory = 'target'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$licenses = (Resolve-Path -LiteralPath $LicenseTextPath).Path
if ((Split-Path -Leaf $binary) -ne 'laqay.exe' -or
    (Split-Path -Leaf $licenses) -ne 'THIRD_PARTY_LICENSES.txt') {
    throw 'Expected laqay.exe and THIRD_PARTY_LICENSES.txt.'
}
$files = @($binary, $licenses) + @('LICENSE', 'THIRD_PARTY_NOTICES.md', 'TRADEMARKS.md') |
    ForEach-Object {
        $path = if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $projectRoot $_ }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing distribution file: $path" }
        $path
    }
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($output) | Out-Null
$archive = Join-Path $output 'laqay-windows-x86_64.zip'
Compress-Archive -LiteralPath $files -DestinationPath $archive -Force
Write-Output $archive
