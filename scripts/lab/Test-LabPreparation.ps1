$ErrorActionPreference = 'Stop'
$labId = [guid]::NewGuid().ToString('N')
$entry = Join-Path $PSScriptRoot 'Invoke-DesktopTestLab.ps1'
$root = Join-Path $env:LOCALAPPDATA ('LaqayTestLab/' + $labId)
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('Laqay.Lab.Media.' + $labId)
function Assert-True($value,[string]$message) { if (-not $value) { throw $message } }
try {
    & (Join-Path $PSScriptRoot 'Test-PortablePackageFiles.ps1')
    & (Join-Path $PSScriptRoot 'Test-GuestLaunchArguments.ps1')
    & (Join-Path $PSScriptRoot 'Test-GuestApplicationInventory.ps1')
    & (Join-Path $PSScriptRoot 'Invoke-DesktopSmoke.ps1') -PrepareOnly
    # Exercise the actual serial input expressions with a Shell-shaped object.
    # Every call must bind successfully and then fail at the unarmed guard.
    $serialAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-GuestAdverseCases.ps1'),[ref]$null,[ref]$null)
    $serialCase=@($serialAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Run-Case' -and $node.CommandElements[1].Extent.Text -eq "'SerialPasteResourceSample'"},$true))
    Assert-True ($serialCase.Count -eq 1) 'The serial fixture could not be located.'
    $inputCalls=@($serialCase[0].FindAll({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Expression.Extent.Text -eq '[LaqayGuestDesktop]' -and $node.Member.Value -in @('FolderInputState','Chord')},$true))
    Assert-True ($inputCalls.Count -eq 3) 'The serial fixture input observations changed.'
    $window=[pscustomobject]@{HWND=[long]12345}
    foreach($call in $inputCalls){
        $rejectedAtGuard=$false
        try{& ([scriptblock]::Create($call.Extent.Text))}catch{$rejectedAtGuard=$_.Exception.ToString().Contains('Guest desktop controls are not armed or have expired.')}
        Assert-True $rejectedAtGuard 'A serial Shell window failed argument binding before the unarmed guard.'
    }
    Write-Output 'Actual serial Shell-window expressions bind native handles before rejecting unarmed input.'
    $renderedBytes=[LaqayGuestDesktop]::RenderedPngFixture()
    $renderedStream=[IO.MemoryStream]::new($renderedBytes,$false);$renderedBitmap=[Drawing.Bitmap]::new($renderedStream)
    try{
        Assert-True ($renderedBitmap.Width -eq 2 -and $renderedBitmap.Height -eq 2) 'The delayed PNG fixture dimensions changed.'
        for($y=0;$y -lt 2;$y++){for($x=0;$x -lt 2;$x++){
            Assert-True ($renderedBitmap.GetPixel($x,$y).ToArgb() -eq [Drawing.Color]::Magenta.ToArgb()) 'The delayed fixture cannot distinguish a stale paste from fresh recovery.'
        }}
    }finally{$renderedBitmap.Dispose();$renderedStream.Dispose()}
    foreach($size in @(2,2048)){
        $bytes=[LaqayGuestDesktop]::MatrixPng($size)
        $stream=[IO.MemoryStream]::new($bytes,$false);$bitmap=[Drawing.Bitmap]::new($stream)
        try{
            Assert-True ($bitmap.Width -eq $size -and $bitmap.Height -eq $size) 'Adverse PNG fixture dimensions changed.'
            $colors=@('00000000','40FF0000','8000FF00','FF0000FF')
            $points=@(@(0,0),@(($size-1),0),@(0,($size-1)),@(($size-1),($size-1)))
            for($index=0;$index -lt 4;$index++){
                Assert-True ($bitmap.GetPixel($points[$index][0],$points[$index][1]).ToArgb().ToString('X8') -eq $colors[$index]) 'Adverse PNG fixture alpha/colors changed.'
            }
            if($size -gt 2){Assert-True ($bitmap.GetPixel(100,100).ToArgb() -eq [Drawing.Color]::White.ToArgb()) 'The large fixture interior changed.'}
        }finally{$bitmap.Dispose();$stream.Dispose()}
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32/mstsc.exe')) 'The native Windows RDP client is missing.'
    Add-Type -Path (Join-Path $PSScriptRoot 'GuestSessionQuery.cs')
    Assert-True ([Runtime.InteropServices.Marshal]::SizeOf([type][LaqayGuestWaitChain+Node]) -eq 280 -and [Runtime.InteropServices.Marshal]::OffsetOf([type][LaqayGuestWaitChain+Node],'ThreadId').ToInt32() -eq 12) 'Unexpected native wait-chain ABI layout.'
    $rejected=$false
    try{[LaqayGuestWaitChain]::Inspect('invalid','invalid',0,0,0,0) | Out-Null}catch{$rejected=$true}
    Assert-True $rejected 'An unowned wait-chain diagnostic was accepted.'
    Assert-True ([Runtime.InteropServices.Marshal]::SizeOf([type][LaqayGuestWaitChain+SnapshotThread]) -eq 120 -and [Runtime.InteropServices.Marshal]::OffsetOf([type][LaqayGuestWaitChain+SnapshotThread],'Context').ToInt32() -eq 112) 'Unexpected x64 process-snapshot thread ABI.'
    $stub=New-Object byte[] 32;$stub[0]=0x4c;$stub[1]=0x8b;$stub[2]=0xd1;$stub[3]=0xb8;$stub[18]=0x0f;$stub[19]=0x05;$stub[20]=0xc3
    Assert-True ([LaqayGuestWaitChain]::ClipboardStubLength($stub) -eq 21) 'The expected clipboard syscall stub was not recognized.'
    $stub[0]=0xe9
    Assert-True ([LaqayGuestWaitChain]::ClipboardStubLength($stub) -eq 0) 'An unknown or redirected syscall stub was accepted.'
    Assert-True ([LaqayGuestWaitChain]::InstructionInStub(4116,4096,21) -and -not [LaqayGuestWaitChain]::InstructionInStub(4117,4096,21) -and -not [LaqayGuestWaitChain]::InstructionInStub(4095,4096,21)) 'The clipboard instruction range accepted an out-of-range address.'
    function New-RedirectedDibFixture([int]$header,[int]$height,[int]$compression){
        $offset=$header;if($header -eq 40 -and $compression -eq 3){$offset+=12}
        $bytes=New-Object byte[] ($offset+24)
        [BitConverter]::GetBytes([uint32]$header).CopyTo($bytes,0)
        [BitConverter]::GetBytes([int]3).CopyTo($bytes,4)
        [BitConverter]::GetBytes($height).CopyTo($bytes,8)
        [BitConverter]::GetBytes([uint16]1).CopyTo($bytes,12)
        [BitConverter]::GetBytes([uint16]32).CopyTo($bytes,14)
        [BitConverter]::GetBytes([uint32]$compression).CopyTo($bytes,16)
        if($compression -eq 3){
            [BitConverter]::GetBytes([uint32]16711680).CopyTo($bytes,40)
            [BitConverter]::GetBytes([uint32]65280).CopyTo($bytes,44)
            [BitConverter]::GetBytes([uint32]255).CopyTo($bytes,48)
            if($header -ge 108){[BitConverter]::GetBytes([uint32]4278190080).CopyTo($bytes,52)}
        }
        $pixels=@('FFFF00FF','FF00FFFF','FFFFFF00','FF000000','FFFFA500','FF800080')
        for($y=0;$y -lt 2;$y++){for($x=0;$x -lt 3;$x++){
            $row=if($height -gt 0){1-$y}else{$y}
            [BitConverter]::GetBytes([Convert]::ToUInt32($pixels[$y*3+$x],16)).CopyTo($bytes,($offset+$row*12+$x*4))
        }}
        return ,$bytes
    }
    foreach($case in @(@{Header=40;Compression=0},@{Header=40;Compression=3},@{Header=108;Compression=3},@{Header=124;Compression=3})){
        foreach($height in @(2,-2)){
            $dib=New-RedirectedDibFixture $case.Header $height $case.Compression
            Assert-True ([LaqayGuestDesktop]::RedirectedDibMatches($dib)) 'The native DIB oracle lost fixture colors, masks, or row orientation.'
        }
    }
    $dib=New-RedirectedDibFixture 40 2 3
    $dib[64]=$dib[64] -bxor 1
    Assert-True (-not [LaqayGuestDesktop]::RedirectedDibMatches($dib)) 'The native DIB oracle accepted a changed pixel.'
    $dib=New-RedirectedDibFixture 124 2 3
    $dib[40]=1
    Assert-True (-not [LaqayGuestDesktop]::RedirectedDibMatches($dib)) 'The native DIB oracle accepted an unknown channel mask.'
    Assert-True (-not [LaqayGuestDesktop]::RedirectedDibMatches((New-Object byte[] 40))) 'The native DIB oracle accepted a truncated fixture.'
    $generated=[LaqayGuestDesktop]::RedirectedDibFixture()
    Assert-True ([LaqayGuestDesktop]::RedirectedDibMatches($generated)) 'The actual native client fixture failed its independent DIB oracle.'
    Assert-True ($generated.Length -eq 148 -and [BitConverter]::ToUInt32($generated,0) -eq 124 -and [BitConverter]::ToInt32($generated,8) -eq -2) 'The native client fixture header or extent changed.'
    foreach ($script in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')) {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        Assert-True ($errors.Count -eq 0) ('Syntax error in ' + $script.Name)
    }
    $plan = & $entry -Action Plan -LabId $labId | ConvertFrom-Json
    Assert-True (-not (Test-Path -LiteralPath $root)) 'Planning created a runtime directory.'
    Assert-True ($plan.CpuCount -eq 2 -and $plan.MemoryBytes -eq 4GB -and $plan.Network -eq 'Private') 'Unexpected resource/isolation plan.'
    Assert-True (-not $plan.HostDesktopControl -and -not $plan.HostReboot -and -not $plan.Internet) 'Planning permits host session changes.'
    $rejected=$false
    try{& (Join-Path $PSScriptRoot 'Set-GuestLabFirewall.ps1') -LabId $labId -Role Primary | Out-Null}catch{$rejected=$true}
    Assert-True $rejected 'Guest firewall configuration was accepted outside its fixed owned guest directory.'
    Assert-True ($plan.MaximumRunningGuests -eq 1 -and $plan.MinimumFreeMemoryForFullCapacityBytes -eq 7GB) 'Default lab concurrency changed.'
    $pair=& $entry -Action Plan -LabId $labId -MaximumRunningGuests 2 | ConvertFrom-Json
    Assert-True ($pair.MaximumRunningGuests -eq 2 -and $pair.MinimumFreeMemoryForFullCapacityBytes -eq 11GB) 'Unexpected pair capacity plan.'
    $budget=Join-Path $PSScriptRoot 'Get-LabStartBudget.ps1'
    foreach($case in @(@{Free=7GB;Running=0;Max=1},@{Free=11GB;Running=0;Max=2},@{Free=7GB;Running=1;Max=2})){
        $admission=& $budget -FreeMemoryBytes $case.Free -FreeDiskBytes 40GB -RunningGuestCount $case.Running -MaximumRunningGuests $case.Max
        Assert-True ($admission.Allowed -and $admission.HostMemoryReserveBytes -eq 3GB) 'A valid exact-boundary start was rejected.'
    }
    foreach($case in @(@{Free=7GB-1;Disk=40GB;Running=0;Max=1},@{Free=11GB-1;Disk=40GB;Running=0;Max=2},@{Free=7GB-1;Disk=40GB;Running=1;Max=2},@{Free=20GB;Disk=40GB;Running=1;Max=1},@{Free=20GB;Disk=40GB;Running=2;Max=2},@{Free=20GB;Disk=40GB-1;Running=0;Max=2})){
        $rejected=$false
        try{& $budget -FreeMemoryBytes $case.Free -FreeDiskBytes $case.Disk -RunningGuestCount $case.Running -MaximumRunningGuests $case.Max | Out-Null}catch{$rejected=$true}
        Assert-True $rejected 'A reserve or concurrency violation was accepted.'
    }
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
