# Stage the exact guest copy loop without remoting, then prepare both entries.
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-RdpSmoke.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The RDP controller has syntax errors.'}
$loops=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.ForEachStatementAst] -and
    $node.Variable.VariablePath.UserPath -ceq 'file' -and
    $node.Condition.Extent.Text.Contains("'GuestSessionQuery.cs'")
},$true))
if($loops.Count -ne 1){throw 'Expected one RDP guest resource copy loop.'}
$commands=@($loops[0].Body.FindAll({param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cne 'Join-Path'
},$true))
if($commands.Count -ne 1 -or $commands[0].GetCommandName() -cne 'Copy-Item'){throw 'The resource fixture only permits the guest copy command.'}
$id=[guid]::NewGuid().ToString('N')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('LaqayRdpBundle-'+$id)
$guestRoot=$fixture;$sessions=@{Peer='inert-copy'};$role='Peer';$bundleSource=$PSScriptRoot
function Copy-Item {
    param([string]$LiteralPath,[string]$Destination,[string]$ToSession)
    $source=[IO.Path]::GetFullPath($LiteralPath)
    if($ToSession -cne 'inert-copy' -or $Destination -cne $fixture -or -not [string]::Equals([IO.Path]::GetDirectoryName($source),$bundleSource,[StringComparison]::OrdinalIgnoreCase)){throw 'The resource copy escaped its fixture scope.'}
    [IO.File]::Copy($source,(Join-Path $fixture ([IO.Path]::GetFileName($source))),$false)
}
try{
    [IO.Directory]::CreateDirectory($fixture)|Out-Null
    & ([scriptblock]::Create($loops[0].Extent.Text.Replace('$PSScriptRoot','$bundleSource')))
    foreach($entry in @('Invoke-GuestDesktopSmoke.ps1','Invoke-GuestRdpClient.ps1')){
        # Fresh processes prevent previously loaded helpers from hiding omissions.
        & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -File (Join-Path $fixture $entry) -PrepareOnly
        if($LASTEXITCODE -ne 0){throw ('The staged RDP entry did not prepare: '+$entry)}
    }
    Write-Output 'The actual RDP guest bundle prepared both entries without remoting, input, or guest startup.'
}finally{
    if([IO.Path]::GetFullPath($fixture) -ne $fixture -or [IO.Path]::GetFileName($fixture) -cne ('LaqayRdpBundle-'+$id)){throw 'Unexpected RDP bundle cleanup path.'}
    if([IO.Directory]::Exists($fixture)){[IO.Directory]::Delete($fixture,$true)}
}
