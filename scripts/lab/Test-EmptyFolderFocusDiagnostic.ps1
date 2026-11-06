# Exercise the real diagnostic scope guards without arming guest controls.
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Guest diagnostics have parser errors.'}
$functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Compare-EmptyFolderFocus'},$true))
if($functions.Count -ne 1){throw 'The focus comparison function is ambiguous.'}
. ([scriptblock]::Create($functions[0].Extent.Text))
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('Laqay.Focus.Scope.'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $fixture 'run';$RunId='fixture';$report=@{CleanupErrors=@()}
$occupied=Join-Path $root 'data/occupied';$sibling=Join-Path $root 'data-sibling'
try{
    [IO.Directory]::CreateDirectory($occupied) | Out-Null
    [IO.Directory]::CreateDirectory($sibling) | Out-Null
    $sentinel=Join-Path $occupied 'existing.txt'
    [IO.File]::WriteAllText($sentinel,'Existing fixture must remain unchanged.')
    foreach($path in @($sibling,(Join-Path $root 'data/../../outside'))){
        $result=Compare-EmptyFolderFocus $null $path
        if($result.Error -cne 'Focus reference is outside the owned case directory.' -or -not $result.ReferenceRemoved){throw 'An out-of-scope reference reached guest controls or filesystem mutation.'}
    }
    $result=Compare-EmptyFolderFocus $null $occupied
    if($result.Status -cne 'SkippedNonEmpty' -or $result.InitiallyEmpty -or -not $result.ReferenceRemoved -or $result.Error){throw 'A nonempty folder reached guest controls or reference creation.'}
    if([IO.File]::ReadAllText($sentinel) -cne 'Existing fixture must remain unchanged.' -or @(Get-ChildItem -LiteralPath $occupied -Force).Count -ne 1 -or @(Get-ChildItem -LiteralPath $sibling -Force).Count -ne 0 -or $report.CleanupErrors.Count){throw 'Diagnostic guards changed an existing fixture.'}
    Write-Output 'Actual focus diagnostic rejected sibling/path traversal scopes and preserved a nonempty folder without guest controls.'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    if((Split-Path $resolved -Parent) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or (Split-Path $resolved -Leaf) -notlike 'Laqay.Focus.Scope.*'){throw 'Refusing cleanup outside the owned temporary fixture.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
