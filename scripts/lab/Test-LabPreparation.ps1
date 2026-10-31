$ErrorActionPreference = 'Stop'
$labId = [guid]::NewGuid().ToString('N')
$entry = Join-Path $PSScriptRoot 'Invoke-DesktopTestLab.ps1'
$root = Join-Path $env:LOCALAPPDATA ('LaqayTestLab/' + $labId)
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('Laqay.Lab.Media.' + $labId)
function Assert-True($value,[string]$message) { if (-not $value) { throw $message } }
try {
    foreach ($script in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')) {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        Assert-True ($errors.Count -eq 0) ('Syntax error in ' + $script.Name)
    }
    $plan = & $entry -Action Plan -LabId $labId | ConvertFrom-Json
    Assert-True (-not (Test-Path -LiteralPath $root)) 'Planning created a runtime directory.'
    Assert-True ($plan.CpuCount -eq 2 -and $plan.MemoryBytes -eq 4GB -and $plan.Network -eq 'Private') 'Unexpected resource/isolation plan.'
    Assert-True (-not $plan.HostDesktopControl -and -not $plan.HostReboot -and -not $plan.Internet) 'Planning permits host session changes.'
    $rejected = $false
    try { & $entry -Action Remove -LabId '../outside' } catch { $rejected = $true }
    Assert-True $rejected 'A traversal lab ID was accepted.'
    New-Item -ItemType Directory -Path $root | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'Owned test sentinel'
    Set-Content -LiteralPath (Join-Path $root 'lab.json') -Value '{"Kind":"WrongOwner","Schema":1}'
    $rejected = $false
    try { & $entry -Action Remove -LabId $labId } catch {
        Assert-True ($_.Exception.Message -eq 'Invalid disposable lab manifest.') 'Removal failed for an unrelated reason.'
        $rejected = $true
    }
    Assert-True ($rejected -and (Test-Path -LiteralPath (Join-Path $root 'keep.txt'))) 'Malformed ownership allowed deletion.'
    $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Autounattend.xml.template') -Raw
    $xml = [xml]($template.Replace('@@PASSWORD@@','Synthetic-Lab-Only!').Replace('@@COMPUTER_NAME@@','LQW11-TEST').Replace('@@FIRST_LOGON_COMMAND@@','cmd.exe /c exit 0'))
    $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
    Assert-True ($xml.SelectSingleNode('//u:WillWipeDisk',$ns).InnerText -eq 'true') 'Unexpected guest disk configuration.'
    Assert-True ($xml.SelectSingleNode('//u:InstallTo/u:DiskID',$ns).InnerText -eq '0') 'Unexpected guest installation target.'
    New-Item -ItemType Directory -Path (Join-Path $temporary 'source') | Out-Null
    Set-Content -LiteralPath (Join-Path $temporary 'source/fixture.txt') -Value 'Synthetic ISO fixture'
    $iso = Join-Path $temporary 'fixture.iso'
    & (Join-Path $PSScriptRoot 'New-SeedIso.ps1') -SourceDirectory (Join-Path $temporary 'source') -Destination $iso -VolumeLabel LQTEST
    $file = [IO.File]::OpenRead($iso)
    try {
        [void]$file.Seek(32769,[IO.SeekOrigin]::Begin)
        $bytes = New-Object byte[] 5
        Assert-True ($file.Read($bytes,0,5) -eq 5 -and [Text.Encoding]::ASCII.GetString($bytes) -eq 'CD001') 'Invalid ISO 9660 primary descriptor.'
    } finally { $file.Dispose() }
    $before = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'New-SeedIso.ps1') -SourceDirectory (Join-Path $temporary 'source') -Destination $iso -VolumeLabel LQTEST } catch { $rejected = $true }
    Assert-True ($rejected -and (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash -eq $before) 'Existing ISO was overwritten.'
    Write-Output 'Lab planning, ownership rejection, unattended XML, and native seed ISO checks passed.'
} finally {
    # Delete only this test's newly allocated, exact absolute directories.
    foreach ($directory in @($root,$temporary)) {
        $resolved = [IO.Path]::GetFullPath($directory)
        if ($resolved -ne $directory -or -not $resolved.Contains($labId)) { throw 'Unexpected test cleanup path.' }
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
