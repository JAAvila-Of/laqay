# Inert file fixtures only: no executable is launched and no registry/VM is touched.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem,System.Web.Extensions
if(-not ('LaqayPortableFiles' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'PortablePackageFiles.cs') -ReferencedAssemblies @('System.Core.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll','System.Web.Extensions.dll')}
$fixtureId=[guid]::NewGuid().ToString('N')
$fixture=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('Laqay.Portable.'+$fixtureId)))
$junction=Join-Path $fixture 'link'
$names=@('laqay.exe','LICENSE','THIRD_PARTY_NOTICES.md','THIRD_PARTY_LICENSES.txt','TRADEMARKS.md','PORTABLE.md')
function Assert-True($condition,[string]$message){if(-not $condition){throw $message}}
function Reject([scriptblock]$operation,[string]$message){$rejected=$false;try{& $operation | Out-Null}catch{$rejected=$true};Assert-True $rejected $message}
function New-Archive([string]$name,[string[]]$entries,[string]$emptyName='',[string]$symlinkName=''){
    $path=Join-Path $fixture $name
    $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew)
    $zip=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Create)
    try{foreach($entryName in $entries){
        $entry=$zip.CreateEntry($entryName)
        if($entryName -eq $symlinkName){$entry.ExternalAttributes=-1610612736}
        $stream=$entry.Open()
        try{if($entryName -ne $emptyName){$bytes=[Text.Encoding]::UTF8.GetBytes('Inert fixture '+$entryName);$stream.Write($bytes,0,$bytes.Length)}}finally{$stream.Dispose()}
    }}finally{$zip.Dispose();$file.Dispose()}
    return $path
}
try{
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $bytes=[Text.Encoding]::UTF8.GetBytes('Inert fixture laqay.exe')
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$exeHash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $zip=New-Archive 'good.zip' $names
    $hash=[LaqayPortableFiles]::Hash($zip)
    $inventory=[LaqayPortableFiles]::Archive($zip,$hash,$exeHash)
    $destination=Join-Path $fixture 'package'
    [LaqayPortableFiles]::Install($fixture,$destination,$zip,$hash,$exeHash)
    [LaqayPortableFiles]::Verify($destination,$inventory)
    Reject {[LaqayPortableFiles]::Install($fixture,$destination,$zip,$hash,$exeHash)} 'An existing installation was replaced.'
    Reject {[LaqayPortableFiles]::Archive($zip,('0'*64),$exeHash)} 'An incorrect archive hash was accepted.'
    Reject {[LaqayPortableFiles]::Archive($zip,$hash,('0'*64))} 'An incorrect executable hash was accepted.'
    Reject {[LaqayPortableFiles]::Child($fixture,(Join-Path $fixture '../escape'))} 'A path escape was accepted.'
    Reject {[LaqayPortableFiles]::Child($fixture,$fixture)} 'An owned root was accepted as its own child.'
    $license=Join-Path $destination 'LICENSE';$original=[IO.File]::ReadAllBytes($license)
    [IO.File]::AppendAllText($license,'changed')
    Reject {[LaqayPortableFiles]::Remove($fixture,$destination,$inventory)} 'A modified package was removed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'laqay.exe')) 'A failed removal deleted a package file.'
    [IO.File]::WriteAllBytes($license,$original)
    $extra=Join-Path $destination 'keep.txt';[IO.File]::WriteAllText($extra,'keep')
    Reject {[LaqayPortableFiles]::Remove($fixture,$destination,$inventory)} 'An unexpected package file was removed.'
    Assert-True (Test-Path -LiteralPath $extra) 'An unexpected file was deleted.'
    [IO.File]::Delete($extra)
    [LaqayPortableFiles]::Remove($fixture,$destination,$inventory)
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'The verified package was not removed.'
    $variants=@(
        @{Name='missing.zip';Entries=@($names | Where-Object {$_ -ne 'LICENSE'});Empty='';Link=''},
        @{Name='extra.zip';Entries=@($names)+@('unexpected');Empty='';Link=''},
        @{Name='duplicate.zip';Entries=@('laqay.exe','LICENSE','LICENSE','THIRD_PARTY_LICENSES.txt','TRADEMARKS.md','PORTABLE.md');Empty='';Link=''},
        @{Name='escape.zip';Entries=@('laqay.exe','../LICENSE','THIRD_PARTY_NOTICES.md','THIRD_PARTY_LICENSES.txt','TRADEMARKS.md','PORTABLE.md');Empty='';Link=''},
        @{Name='case.zip';Entries=@('LAQAY.EXE','LICENSE','THIRD_PARTY_NOTICES.md','THIRD_PARTY_LICENSES.txt','TRADEMARKS.md','PORTABLE.md');Empty='';Link=''},
        @{Name='empty.zip';Entries=$names;Empty='LICENSE';Link=''},
        @{Name='link.zip';Entries=$names;Empty='';Link='LICENSE'}
    )
    foreach($variant in $variants){
        $bad=New-Archive $variant.Name $variant.Entries $variant.Empty $variant.Link
        $badHash=[LaqayPortableFiles]::Hash($bad)
        Reject {[LaqayPortableFiles]::Archive($bad,$badHash,$exeHash)} ('An unsafe archive was accepted: '+$variant.Name)
    }
    $tree=Join-Path $fixture 'tree';[IO.Directory]::CreateDirectory((Join-Path $tree 'empty')) | Out-Null
    $treeInventory=[LaqayPortableFiles]::Snapshot($tree)
    [IO.Directory]::Delete((Join-Path $tree 'empty'))
    Reject {[LaqayPortableFiles]::Verify($tree,$treeInventory)} 'An empty directory missing from the baseline was ignored.'
    New-Item -ItemType Junction -Path $junction -Target $tree | Out-Null
    Reject {[LaqayPortableFiles]::Snapshot($junction)} 'A junction root was accepted.'
    Reject {[LaqayPortableFiles]::Snapshot($fixture)} 'A nested junction was accepted.'
    [IO.Directory]::Delete($junction)
    Write-Output 'Portable file policy passed valid round-trip, identity, unsafe archive, changed-tree, path and reparse tests.'
}finally{
    # Remove a possible link itself, never walk its target during fixture cleanup.
    if(Test-Path -LiteralPath $junction){[IO.Directory]::Delete($junction)}
    if($fixture -ne [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('Laqay.Portable.'+$fixtureId)))){throw 'Unexpected fixture cleanup path.'}
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
