# Loaded only by the armed interactive smoke runner. Never run standalone.
if(-not $IncludeAdverse -or $PSScriptRoot -ne $root -or $report.Cases.Count -ne 13){throw 'The adverse cases require the owned smoke context.'}
[LaqayGuestDesktop]::RequireRole('Primary')
Assert-True ([LaqayGuestDesktop]::SessionProtocol() -eq 0) 'The adverse cases require the disposable console.'
function Assert-Empty([string]$path){Assert-True (@(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) 'A declined paste left files or staging output.'}
Run-Case 'EmptyClipboardNoOutput' {
    $path=New-CaseFolder 'empty-clipboard';$window=Open-Folder $path
    [LaqayGuestDesktop]::EmptyImageClipboard();[LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86))
    Start-Sleep -Milliseconds 700;Assert-Empty $path;Assert-True ([LaqayGuestDesktop]::MatrixApplicationResponsive()) 'The application stopped on an empty clipboard.'
}
Run-Case 'LockedClipboardRecovery' {
    $path=New-CaseFolder 'locked-clipboard';$window=Open-Folder $path
    # Retire the preceding case's input thread and invalidate old requests before
    # testing a newly held external lock. In-flight earlier work is a separate case.
    [LaqayGuestDesktop]::ToggleEnabled()
    Wait-For {(Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Laqay' -Name Enabled) -eq 0} 'The lock fixture could not pause old requests.'
    [LaqayGuestDesktop]::EmptyImageClipboard();Start-Sleep -Milliseconds 500;Assert-Empty $path
    [LaqayGuestDesktop]::ToggleEnabled()
    Wait-For {(Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Laqay' -Name Enabled) -eq 1} 'The lock fixture could not resume input.'
    [LaqayGuestDesktop]::ImageClipboard();$report.AdverseFixturesClosed=$false
    function Record-Lease([string]$stage){
        $proof=[LaqayGuestDesktop]::ClipboardLeaseState()
        $report.ClipboardLeaseProof+=@([pscustomobject]@{Stage=$stage;Proof=$proof});Save-Report
        Assert-True ($proof.Held -and $proof.ProbeRejected -and $proof.OwnerPid -ne $report.ApplicationPid) 'The external clipboard lock was not independently confirmed.'
    }
    try{
        [LaqayGuestDesktop]::BeginClipboardLease();Record-Lease 'BeforeKey'
        Assert-Empty $path
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86));Record-Lease 'AfterKey'
        Start-Sleep -Milliseconds 1000;Record-Lease 'AfterObservation'
        Assert-Empty $path;Assert-True ([LaqayGuestDesktop]::MatrixApplicationResponsive()) 'The clipboard lock blocked the tray window.'
    }finally{[LaqayGuestDesktop]::EndClipboardLease();$report.AdverseFixturesClosed=$true}
    # A request may finish only after the external lock is released. Allow either
    # safe rejection or one complete result; never accept incomplete output.
    Start-Sleep -Milliseconds 700
    $files=@(Get-ChildItem -LiteralPath $path -Force)
    Assert-True ($files.Count -le 1 -and @($files | Where-Object Extension -ne '.png').Count -eq 0) 'The locked paste left unexpected output.'
    foreach($file in $files){Check-Png $file.FullName}
    Paste-Image $window $path ($files.Count+1)
    foreach($file in @(Get-ChildItem -LiteralPath $path -Filter '*.png')){Check-Png $file.FullName}
}
foreach($size in @(2,2048)){
    $name=if($size -eq 2){'PngAlphaExact'}else{'LargePngResponsive'}
    Run-Case $name {
        $path=New-CaseFolder ('png-'+$size);$window=Open-Folder $path
        [LaqayGuestDesktop]::MatrixPngClipboard($size)
        $watch=[Diagnostics.Stopwatch]::StartNew()
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86))
        Wait-For {Assert-True ([LaqayGuestDesktop]::MatrixApplicationResponsive()) 'The tray stopped responding during PNG processing.';@(Get-ChildItem -LiteralPath $path -Filter '*.png').Count -eq 1} 'The PNG fixture was not published.' 30
        $image=[Drawing.Bitmap]::new((Get-ChildItem -LiteralPath $path -Filter '*.png')[0].FullName)
        try{
            Assert-True ($image.Width -eq $size -and $image.Height -eq $size) 'PNG dimensions changed.'
            $points=@(@(0,0),@(($size-1),0),@(0,($size-1)),@(($size-1),($size-1)))
            for($index=0;$index -lt 4;$index++){Assert-True ($image.GetPixel($points[$index][0],$points[$index][1]).ToArgb() -eq [LaqayGuestDesktop]::MatrixPixel($index)) 'PNG alpha or channel values changed.'}
        }finally{$image.Dispose()}
        Assert-True (@(Get-ChildItem -LiteralPath $path -Force).Count -eq 1) 'PNG encoding left staging output.'
        $report.ResourceSamples+=@([pscustomobject]@{Phase=$name;ElapsedMilliseconds=$watch.ElapsedMilliseconds;Sample=[LaqayGuestDesktop]::MatrixResources()})
    }
}
Run-Case 'HeldPasteSingleImage' {
    $path=New-CaseFolder 'held-key';$window=Open-Folder $path
    [LaqayGuestDesktop]::ImageClipboard();[LaqayGuestDesktop]::HeldPaste([IntPtr]$window.HWND)
    Wait-For {@(Get-ChildItem -LiteralPath $path -Filter '*.png').Count -eq 1} 'The held Ctrl+V did not publish one image.'
    Start-Sleep -Milliseconds 1000
    Assert-True (@(Get-ChildItem -LiteralPath $path -Force).Count -eq 1) 'Key repeat published extra images or staging files.'
    Check-Png (Get-ChildItem -LiteralPath $path -Filter '*.png')[0].FullName
}
Run-Case 'RapidPastePreservesImages' {
    $path=New-CaseFolder 'rapid-paste';$window=Open-Folder $path
    [LaqayGuestDesktop]::ImageClipboard()
    for($index=0;$index -lt 8;$index++){[LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86))}
    Wait-For {@(Get-ChildItem -LiteralPath $path -Filter '*.png').Count -gt 0} 'Rapid paste produced no image.'
    Start-Sleep -Seconds 2;$files=@(Get-ChildItem -LiteralPath $path -Force)
    Assert-True ($files.Count -ge 1 -and $files.Count -le 8 -and @($files | Where-Object Extension -ne '.png').Count -eq 0) 'Rapid input produced unexpected output.'
    $hashes=@{};foreach($file in $files){Check-Png $file.FullName;$hashes[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
    Paste-Image $window $path ($files.Count+1)
    foreach($file in $hashes.Keys){Assert-True ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $hashes[$file]) 'A rapid-paste image was overwritten.'}
}
Run-Case 'SecondInstanceExits' {$report.SecondInstance=[LaqayGuestDesktop]::SecondApplication()}
Run-Case 'VirtualFolderDeclines' {
    $before=@(Get-ChildItem -LiteralPath (Join-Path $root 'data') -Filter '*.png' -Recurse -File | ForEach-Object FullName)
    $shell.Open('shell:MyComputerFolder');$script:virtualWindow=$null
    Wait-For {foreach($candidate in @($shell.Windows())){try{if($candidate.Document.Folder.Self.Path -eq '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'){$script:virtualWindow=$candidate;return $true}}catch{}};$false} 'The real This PC namespace did not open.'
    [LaqayGuestDesktop]::Activate([IntPtr]$virtualWindow.HWND)
    Wait-For {try{[LaqayGuestDesktop]::FocusFolder([IntPtr]$virtualWindow.HWND);$true}catch{$false}} 'The virtual folder view was not ready.'
    [LaqayGuestDesktop]::ImageClipboard();$sequence=[LaqayGuestDesktop]::ClipboardSequence()
    [LaqayGuestDesktop]::Chord([IntPtr]$virtualWindow.HWND,[UInt16[]]@(17,86));Start-Sleep -Milliseconds 1000
    $after=@(Get-ChildItem -LiteralPath (Join-Path $root 'data') -Filter '*.png' -Recurse -File | ForEach-Object FullName)
    Assert-True (@(Compare-Object $before $after).Count -eq 0 -and [LaqayGuestDesktop]::ClipboardSequence() -eq $sequence) 'A virtual paste changed the clipboard or wrote into a previous fixture.'
    Assert-True ([LaqayGuestDesktop]::MatrixApplicationResponsive()) 'The application stopped on a virtual folder.'
}
$report.AdverseFixturesClosed=$false
try{
    [LaqayGuestDesktop]::BeginMatrixEditor()
    foreach($rich in @($false,$true)){
        $prefix=if($rich){'RichEdit'}else{'NativeEdit'}
        Run-Case ($prefix+'NativeText') {
            [LaqayGuestDesktop]::FocusMatrixEditor($rich);[LaqayGuestDesktop]::TextClipboard('Laqay external editor fixture.')
            [LaqayGuestDesktop]::PasteMatrixEditor()
            Wait-For {[LaqayGuestDesktop]::MatrixEditorText() -eq 'Laqay external editor fixture.'} 'Text did not reach the native editor.'
        }
        Run-Case ($prefix+'ImageDoesNotWrite') {
            $before=@(Get-ChildItem -LiteralPath (Join-Path $root 'data') -Filter '*.png' -Recurse -File | ForEach-Object FullName)
            [LaqayGuestDesktop]::FocusMatrixEditor($rich);[LaqayGuestDesktop]::ImageClipboard();[LaqayGuestDesktop]::PasteMatrixEditor()
            Start-Sleep -Milliseconds 700
            $after=@(Get-ChildItem -LiteralPath (Join-Path $root 'data') -Filter '*.png' -Recurse -File | ForEach-Object FullName)
            Assert-True (@(Compare-Object $before $after).Count -eq 0) 'A non-Explorer editor wrote into an old Explorer fixture.'
        }
    }
}finally{[LaqayGuestDesktop]::EndMatrixEditor();$report.AdverseFixturesClosed=$true}
Run-Case 'IdleResponsivenessSample' {
    $before=[LaqayGuestDesktop]::MatrixResources()
    for($index=0;$index -lt 8;$index++){Start-Sleep -Milliseconds 500;Assert-True ([LaqayGuestDesktop]::MatrixApplicationResponsive()) 'The idle application stopped responding.'}
    $report.ResourceSamples+=@([pscustomobject]@{Phase='Idle';Before=$before;After=[LaqayGuestDesktop]::MatrixResources()})
}
Run-Case 'SerialPasteResourceSample' {
    $path=New-CaseFolder 'serial-paste';$window=Open-Folder $path;$before=[LaqayGuestDesktop]::MatrixResources()
    for($index=1;$index -le 12;$index++){Paste-Image $window $path $index}
    $files=@(Get-ChildItem -LiteralPath $path -Force)
    Assert-True ($files.Count -eq 12) 'The serial sample lost images or left staging files.'
    foreach($file in $files){Check-Png $file.FullName}
    $report.ResourceSamples+=@([pscustomobject]@{Phase='Serial';Before=$before;After=[LaqayGuestDesktop]::MatrixResources()})
}
Assert-True ($report.Cases.Count -eq 27) 'The complete adverse suite did not execute.'
