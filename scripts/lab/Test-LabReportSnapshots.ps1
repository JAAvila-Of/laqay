# Exercise the actual guest publisher against local files, without a guest or input.
$ErrorActionPreference='Stop'
function Test-Publisher([string]$source,[string]$publisherName){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $source),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The guest report source has parser errors.'}
    $publisher=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $publisherName},$true))
    if($publisher.Count -ne 1){throw 'The guest report publisher is ambiguous.'}
    . ([scriptblock]::Create($publisher[0].Extent.Text))
    $id=[guid]::NewGuid().ToString('N')
    $directory=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('LaqayReportTest-'+$id)))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $reportPath=Join-Path $directory 'report.json'
    $reader=$null
    try{
        $report=[ordered]@{Stage=1;Text=('Unicode '+[char]0x00F1+[char]0x6D4B);Passed=$false}
        & $publisherName
        $first=[IO.File]::ReadAllText($reportPath)
        if(($first | ConvertFrom-Json).Text -cne $report.Text){throw 'The first complete Unicode snapshot changed.'}
        $reader=[IO.File]::Open($reportPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $report.Stage=2;& $publisherName
        if(([IO.File]::ReadAllText($reportPath) | ConvertFrom-Json).Stage -ne 2){throw 'The replacement snapshot was not published.'}
        $buffer=New-Object byte[] ([int]$reader.Length)
        if($reader.Read($buffer,0,$buffer.Length) -ne $buffer.Length){throw 'The held old snapshot was truncated.'}
        if(([Text.Encoding]::UTF8.GetString($buffer).TrimStart([char]0xFEFF) | ConvertFrom-Json).Stage -ne 1){throw 'The held reader observed an overwritten snapshot.'}
        $reader.Dispose();$reader=$null
        $before=[IO.File]::ReadAllText($reportPath)
        $reader=[IO.File]::Open($reportPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $report.Stage=3;$rejected=$false;$watch=[Diagnostics.Stopwatch]::StartNew()
        try{& $publisherName}catch [IO.IOException]{$rejected=$true}
        $watch.Stop()
        if(-not $rejected -or $watch.Elapsed.TotalSeconds -gt 5 -or [IO.File]::Exists($reportPath+'.tmp')){throw 'A retained incompatible reader did not fail within the publication bound.'}
        $reader.Dispose();$reader=$null
        if([IO.File]::ReadAllText($reportPath) -cne $before){throw 'A failed publication changed the last complete snapshot.'}
        & $publisherName
        if(([IO.File]::ReadAllText($reportPath) | ConvertFrom-Json).Stage -ne 3){throw 'Publication did not recover after reader release.'}
        [IO.File]::WriteAllText($reportPath+'.tmp','Owned sentinel')
        $rejected=$false;try{& $publisherName}catch{$rejected=$true}
        if(-not $rejected -or [IO.File]::ReadAllText($reportPath+'.tmp') -cne 'Owned sentinel'){throw 'An existing publication file was overwritten.'}
        Write-Output ('Actual '+$publisherName+' publication preserved complete snapshots, bounded reader conflicts and recovery.')
    }finally{
        if($reader){$reader.Dispose()}
        if([IO.Path]::GetFullPath($directory) -ne $directory -or [IO.Path]::GetFileName($directory) -cne ('LaqayReportTest-'+$id)){throw 'Unexpected report-test cleanup path.'}
        [IO.Directory]::Delete($directory,$true)
    }

}
Test-Publisher 'Invoke-GuestDesktopSmoke.ps1' 'Save-Report'
Test-Publisher 'GuestTerminalReceiver.ps1' 'Save-Receiver'
