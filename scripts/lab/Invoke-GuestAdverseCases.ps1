# Loaded only by the armed interactive smoke runner. Never run standalone.
$adverseStart=if($IncludeRealApplications){17}else{13}
if($IncludeWindowsTerminal){$adverseStart+=2}
if(-not $IncludeAdverse -or $PSScriptRoot -ne $root -or $report.Cases.Count -ne $adverseStart){throw 'The adverse cases require the owned smoke context.'}
[LaqayGuestDesktop]::RequireRole('Primary')
Assert-True ([LaqayGuestDesktop]::SessionProtocol() -eq 0) 'The adverse cases require the disposable console.'
$report.SessionProtocol=[LaqayGuestDesktop]::SessionProtocol()
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
function Check-RenderedPng([string]$path){
    $image=[Drawing.Bitmap]::new($path)
    try{
        Assert-True ($image.Width -eq 2 -and $image.Height -eq 2) 'The rendered PNG dimensions changed.'
        for($y=0;$y -lt 2;$y++){for($x=0;$x -lt 2;$x++){
            Assert-True ($image.GetPixel($x,$y).ToArgb() -eq [Drawing.Color]::Magenta.ToArgb()) 'The rendered PNG pixels changed.'
        }}
    }finally{$image.Dispose()}
}
function Release-RenderedPng {
    [LaqayGuestDesktop]::ReleaseRenderedDelayedPng()
    Wait-For {$state=[LaqayGuestDesktop]::DelayedPngState();Assert-True (-not $state.Error -and -not $state.TimedOut) 'The rendered provider failed.';$state.Rendered} 'The provider did not supply its PNG bytes.'
    Wait-For {[LaqayGuestDesktop]::ClipboardReadAvailable()} 'The application did not release its clipboard read.'
}
Run-Case 'RenderedPngReferencePaste' {
    $path=New-CaseFolder 'rendered-reference';$window=Open-Folder $path
    $report.TabClipboardRace=[pscustomobject]@{Reference=$null;ReferenceInput=$null;WindowHandle=0;SourceTab=$null;DestinationTab=$null;FenceTab=$null;FenceInputBefore=$null;FenceInputAfter=$null;FenceShellPath=$null;FenceCounts=$null;ResponsiveBefore=$false;ResponsiveAfter=$false;BeforeSwitch=$null;AfterSwitch=$null;AfterRender=$null;AfterFence=$null;SameWindow=$false;TabChanged=$false;FenceVerified=$false;OriginalFoldersEmpty=$false;FreshPasteVerified=$false;ProviderStopped=$false}
    try{
        [LaqayGuestDesktop]::BeginRenderedDelayedPng()
        $report.TabClipboardRace.ReferenceInput=[LaqayGuestDesktop]::FolderInputState([IntPtr]$window.HWND)
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86))
        Wait-For {([LaqayGuestDesktop]::DelayedPngState()).Requested} 'The reference provider did not receive its render request.'
        Release-RenderedPng
        Wait-For {@(Get-ChildItem -LiteralPath $path -Filter '*.png' -File).Count -eq 1} 'The held PNG reference did not publish.'
        Assert-True (@(Get-ChildItem -LiteralPath $path -Force).Count -eq 1) 'The reference left extra files.'
        Check-RenderedPng (Get-ChildItem -LiteralPath $path -Filter '*.png' -File)[0].FullName
        $report.TabClipboardRace.Reference=[LaqayGuestDesktop]::DelayedPngState()
        Assert-True ($report.TabClipboardRace.Reference.Sequence -eq $report.TabClipboardRace.Reference.PublishedSequence) 'Rendering changed the reference clipboard sequence; it cannot isolate a focus race.'
    }finally{
        try{$report.TabClipboardRace.Reference=[LaqayGuestDesktop]::DelayedPngState()}catch{}
        [LaqayGuestDesktop]::EndDelayedPng();Save-Report
    }
}
Run-Case 'TabSwitchCancelsPendingImage' {
    $pathA=New-CaseFolder 'pending-tab-a';$pathB=New-CaseFolder 'pending-tab-b';$pathC=New-CaseFolder 'pending-tab-fence'
    $window=Open-Folder $pathA;$handle=[IntPtr]$window.HWND
    foreach($path in @($pathB,$pathC)){
        [LaqayGuestDesktop]::Chord($handle,[UInt16[]]@(17,84));Start-Sleep -Milliseconds 400
        Navigate-Tab $handle $path
        Assert-True ((Find-Folder $path).HWND -eq $window.HWND) 'The pending fixtures are not tabs of one Explorer window.'
    }
    $report.TabClipboardRace.SameWindow=$true
    foreach($name in @('SourceShellPath','SourceInputBefore','SourceInputAfter','SourceProviderBefore','SourceProviderAfter','SourceCounts')){$report.TabClipboardRace | Add-Member -NotePropertyName $name -NotePropertyValue $null}
    $report.TabClipboardRace.WindowHandle=$handle.ToInt64()
    [LaqayGuestDesktop]::Chord($handle,[UInt16[]]@(17,16,9));[LaqayGuestDesktop]::Chord($handle,[UInt16[]]@(17,16,9))
    Wait-For {[LaqayGuestDesktop]::SelectedTabName($handle).Contains('pending-tab-a')} 'The source tab was not selected.'
    $report.TabClipboardRace.SourceTab=[LaqayGuestDesktop]::SelectedTabName($handle)
    [LaqayGuestDesktop]::FocusFolder($handle)
    try{
        $report.ProviderStopped=$false;[LaqayGuestDesktop]::BeginRenderedDelayedPng()
        try{
            $report.TabClipboardRace.SourceShellPath=(Find-Folder $pathA).Document.Folder.Self.Path
            $inputState=[LaqayGuestDesktop]::FolderInputState($handle);$report.TabClipboardRace.SourceInputBefore=$inputState
            $provider=[LaqayGuestDesktop]::DelayedPngState();$report.TabClipboardRace.SourceProviderBefore=$provider;Save-Report
            Assert-True ($report.TabClipboardRace.SourceShellPath -eq $pathA -and $inputState.Foreground -and $inputState.FocusWithinWindow -and $inputState.ItemsViewFocused -and $inputState.HasPng -and -not $inputState.HasFileDrop -and ($inputState.GuiFlags -band 0x1e) -eq 0 -and -not $inputState.ControlDown -and -not $inputState.AltDown -and -not $inputState.ShiftDown -and -not $inputState.WindowsDown) 'The source folder was not ready for its single race input.'
            Assert-True ($provider.OwnerMatches -and $provider.MarkerPublished -and $provider.Sequence -eq $provider.PublishedSequence -and $provider.Sequence -eq $inputState.ClipboardSequence -and -not $provider.Requested -and -not $provider.Rendered -and -not $provider.Released -and -not $provider.Error -and -not $provider.TimedOut) 'The source provider was not fresh and stable before the single race input.'
            [LaqayGuestDesktop]::Chord($handle,[UInt16[]]@(17,86))
            Wait-For {([LaqayGuestDesktop]::DelayedPngState()).Requested} 'The race provider did not receive its render request.'
        }finally{
            try{$report.TabClipboardRace.SourceInputAfter=[LaqayGuestDesktop]::FolderInputState($handle)}catch{}
            $report.TabClipboardRace.SourceProviderAfter=[LaqayGuestDesktop]::DelayedPngState()
            $report.TabClipboardRace.SourceCounts=[pscustomobject]@{A=@(Get-ChildItem -LiteralPath $pathA -Force).Count;B=@(Get-ChildItem -LiteralPath $pathB -Force).Count;C=@(Get-ChildItem -LiteralPath $pathC -Force).Count};Save-Report
        }
        $report.PendingClipboard=[LaqayGuestDesktop]::DelayedPngState();Save-Report
        $proofPath=Join-Path $root 'pending-proof.json';$abortPath=Join-Path $root 'pending-abort.json'
        Wait-For {(Test-Path -LiteralPath $proofPath) -or (Test-Path -LiteralPath $abortPath)} 'The controller did not verify the held clipboard read.' 25
        if(Test-Path -LiteralPath $abortPath){throw 'The controller aborted the held-read validation.'}
        $proof=Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json
        Assert-True ($proof.LabId -eq $LabId -and $proof.RunId -eq $RunId -and $proof.Confirmed -and $proof.ApplicationPid -eq $report.ApplicationPid -and $proof.ProviderPid -eq $report.PendingClipboard.ProviderPid -and $proof.ProviderThreadId -eq $report.PendingClipboard.ProviderThreadId -and $proof.SessionId -eq $report.SessionId) 'The wait proof does not match this application and provider.'
        $report.PendingWaitVerified=$true
        $report.TabClipboardRace.BeforeSwitch=[LaqayGuestDesktop]::DelayedPngState()
        [LaqayGuestDesktop]::Chord($handle,[UInt16[]]@(17,9))
        Wait-For {[LaqayGuestDesktop]::SelectedTabName($handle).Contains('pending-tab-b')} 'The destination tab did not become active.'
        $report.TabClipboardRace.DestinationTab=[LaqayGuestDesktop]::SelectedTabName($handle)
        $report.TabClipboardRace.TabChanged=$true
        $held=[LaqayGuestDesktop]::DelayedPngState();$report.TabClipboardRace.AfterSwitch=$held
        Assert-True ($held.Requested -and -not $held.Released -and -not $held.Rendered -and $held.OwnerMatches -and $held.Sequence -eq $held.PublishedSequence -and -not $held.Error -and -not $held.TimedOut) 'The provider was not retained across the tab switch.'
        Release-RenderedPng
        $report.TabClipboardRace.AfterRender=[LaqayGuestDesktop]::DelayedPngState()
        # The published application has one FIFO paste worker. A later output
        # from the same clipboard proves the held request has finished, without
        # changing its clipboard sequence or relying on a quiet-time delay.
        [LaqayGuestDesktop]::Chord($handle,[UInt16[]]@(17,9))
        Wait-For {[LaqayGuestDesktop]::SelectedTabName($handle).Contains('pending-tab-fence')} 'The completion-fence tab did not become active.'
        $report.TabClipboardRace.FenceTab=[LaqayGuestDesktop]::SelectedTabName($handle)
        [LaqayGuestDesktop]::FocusFolder($handle)
        try{
            $report.TabClipboardRace.FenceShellPath=(Find-Folder $pathC).Document.Folder.Self.Path
            $inputState=[LaqayGuestDesktop]::FolderInputState($handle);$report.TabClipboardRace.FenceInputBefore=$inputState
            $report.TabClipboardRace.ResponsiveBefore=[LaqayGuestDesktop]::MatrixApplicationResponsive();Save-Report
            Assert-True ($report.TabClipboardRace.FenceShellPath -eq $pathC -and $inputState.Foreground -and $inputState.FocusWithinWindow -and $inputState.ItemsViewFocused -and $inputState.HasPng -and ($inputState.GuiFlags -band 0x1e) -eq 0 -and -not $inputState.ControlDown -and -not $inputState.AltDown -and -not $inputState.ShiftDown -and -not $inputState.WindowsDown) 'The completion-fence folder was not ready for its single input.'
            [LaqayGuestDesktop]::Chord($handle,[UInt16[]]@(17,86))
            Wait-For {@(Get-ChildItem -LiteralPath $pathC -Filter '*.png' -File).Count -eq 1} 'The later same-clipboard paste did not complete.'
            Check-RenderedPng (Get-ChildItem -LiteralPath $pathC -Filter '*.png' -File)[0].FullName
            Assert-True (@(Get-ChildItem -LiteralPath $pathC -Force).Count -eq 1) 'The completion fence left extra files.'
        }finally{
            try{$report.TabClipboardRace.FenceInputAfter=[LaqayGuestDesktop]::FolderInputState($handle)}catch{}
            $report.TabClipboardRace.ResponsiveAfter=[LaqayGuestDesktop]::MatrixApplicationResponsive()
            $report.TabClipboardRace.FenceCounts=[pscustomobject]@{A=@(Get-ChildItem -LiteralPath $pathA -Force).Count;B=@(Get-ChildItem -LiteralPath $pathB -Force).Count;C=@(Get-ChildItem -LiteralPath $pathC -Force).Count}
            $report.TabClipboardRace.AfterFence=[LaqayGuestDesktop]::DelayedPngState();Save-Report
        }
        Assert-True ($report.TabClipboardRace.AfterFence.OwnerMatches -and $report.TabClipboardRace.AfterFence.Sequence -eq $held.PublishedSequence) 'The completion fence changed clipboard ownership or sequence.'
        $report.TabClipboardRace.FenceVerified=$true
        Assert-Empty $pathA;Assert-Empty $pathB;$report.TabClipboardRace.OriginalFoldersEmpty=$true
    }finally{[LaqayGuestDesktop]::EndDelayedPng();$report.ProviderStopped=$true;$report.TabClipboardRace.ProviderStopped=$true;Save-Report}
    [LaqayGuestDesktop]::Chord($handle,[UInt16[]]@(17,16,9))
    Wait-For {[LaqayGuestDesktop]::SelectedTabName($handle).Contains('pending-tab-b')} 'The recovery tab did not become active.'
    Paste-Image (Find-Folder $pathB) $pathB 1
    Check-Png (Get-ChildItem -LiteralPath $pathB -Filter '*.png' -File)[0].FullName
    Assert-True (@(Get-ChildItem -LiteralPath $pathB -Force).Count -eq 1) 'The fresh recovery paste left extra files.'
    Assert-Empty $pathA;$report.TabClipboardRace.FreshPasteVerified=$true;Save-Report
}
$report.AdverseFixturesClosed=$false
try{
    [LaqayGuestDesktop]::BeginMatrixEditor()
    foreach($rich in @($false,$true)){
        $prefix=if($rich){'RichEdit'}else{'NativeEdit'}
        Run-Case ($prefix+'NativeText') {
            foreach($enabled in @($false,$true)){
                [LaqayGuestDesktop]::ToggleEnabled()
                Wait-For {(Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Laqay' -Name Enabled) -eq [int]$enabled} 'The editor reference could not change input state.'
                $proof=[pscustomobject]@{Control=$prefix;LaqayEnabled=$enabled;Source=$null;Before=$null;After=$null;TextMatched=$false}
                $pasteFailure=$null
                try{
                    [LaqayGuestDesktop]::FocusMatrixEditor($rich)
                    $proof.Source=[LaqayGuestDesktop]::MatrixEditorTextClipboard('Laqay external editor fixture.')
                    $proof.Before=[LaqayGuestDesktop]::MatrixEditorState()
                    [LaqayGuestDesktop]::PasteMatrixEditor()
                    Wait-For {[LaqayGuestDesktop]::MatrixEditorText() -eq 'Laqay external editor fixture.'} ('Text did not reach '+$prefix+'; Laqay enabled='+$enabled)
                    $proof.TextMatched=$true
                }catch{$pasteFailure=$_}finally{
                    $proof.After=[LaqayGuestDesktop]::MatrixEditorState();$report.EditorProof+=@($proof);Save-Report
                }
                if($pasteFailure){
                    # Diagnose sender-thread coupling without replacing the failed assertion.
                    $alternate=[pscustomobject]@{Control=$prefix;LaqayEnabled=$enabled;Sender='EditorThread';Source=$null;Before=$null;After=$null;TextMatched=$false;Error=$null}
                    try{
                        [LaqayGuestDesktop]::FocusMatrixEditor($rich)
                        $alternate.Source=[LaqayGuestDesktop]::MatrixEditorTextClipboard('Laqay external editor fixture.')
                        $alternate.Before=[LaqayGuestDesktop]::MatrixEditorState()
                        [LaqayGuestDesktop]::PasteMatrixEditorFromUiThread()
                        Wait-For {[LaqayGuestDesktop]::MatrixEditorText() -eq 'Laqay external editor fixture.'} 'The editor-thread diagnostic did not receive text.'
                        $alternate.TextMatched=$true
                    }catch{$alternate.Error=$_.Exception.Message}finally{
                        $alternate.After=[LaqayGuestDesktop]::MatrixEditorState();$report.EditorSenderComparison+=@($alternate);Save-Report
                    }
                    if($enabled){
                        [LaqayGuestDesktop]::ToggleEnabled()
                        Wait-For {(Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Laqay' -Name Enabled) -eq 0} 'The passive-hook reference could not disable Laqay.'
                        foreach($mode in @('DisabledRecovery','PassiveReferenceHook')){
                            $reference=[pscustomobject]@{Mode=$mode;LaqayEnabled=$false;Source=$null;Before=$null;After=$null;TextMatched=$false;Hook=$null;Error=$null}
                            try{
                                [LaqayGuestDesktop]::FocusMatrixEditor($rich)
                                $reference.Source=[LaqayGuestDesktop]::MatrixEditorTextClipboard('Laqay external editor fixture.')
                                if($mode -eq 'PassiveReferenceHook'){[LaqayGuestDesktop]::BeginMatrixReferenceHook()}
                                $reference.Before=[LaqayGuestDesktop]::MatrixEditorState()
                                [LaqayGuestDesktop]::PasteMatrixEditor()
                                Wait-For {[LaqayGuestDesktop]::MatrixEditorText() -eq 'Laqay external editor fixture.'} ('The '+$mode+' reference did not receive text.') 3
                                $reference.TextMatched=$true
                            }catch{$reference.Error=$_.Exception.Message}finally{
                                $reference.Hook=[LaqayGuestDesktop]::EndMatrixReferenceHook()
                                $reference.After=[LaqayGuestDesktop]::MatrixEditorState();$report.ReferenceHookProof+=@($reference);Save-Report
                            }
                        }
                    }
                    throw $pasteFailure
                }
            }
        }
        Run-Case ($prefix+'ImageDoesNotWrite') {
            $before=@(Get-ChildItem -LiteralPath (Join-Path $root 'data') -Filter '*.png' -Recurse -File | ForEach-Object FullName)
            [LaqayGuestDesktop]::FocusMatrixEditor($rich);[LaqayGuestDesktop]::ImageClipboard();[LaqayGuestDesktop]::PasteMatrixEditor()
            Start-Sleep -Milliseconds 700
            $after=@(Get-ChildItem -LiteralPath (Join-Path $root 'data') -Filter '*.png' -Recurse -File | ForEach-Object FullName)
            Assert-True (@(Compare-Object $before $after).Count -eq 0) 'A non-Explorer editor wrote into an old Explorer fixture.'
        }
    }
}finally{[LaqayGuestDesktop]::EndMatrixReferenceHook() | Out-Null;[LaqayGuestDesktop]::EndMatrixEditor();$report.AdverseFixturesClosed=$true}
Run-Case 'IdleResponsivenessSample' {
    $before=[LaqayGuestDesktop]::MatrixResources()
    for($index=0;$index -lt 8;$index++){Start-Sleep -Milliseconds 500;Assert-True ([LaqayGuestDesktop]::MatrixApplicationResponsive()) 'The idle application stopped responding.'}
    $report.ResourceSamples+=@([pscustomobject]@{Phase='Idle';Before=$before;After=[LaqayGuestDesktop]::MatrixResources()})
}
Run-Case 'SerialPasteResourceSample' {
    $path=New-CaseFolder 'serial-paste';$window=Open-Folder $path;$before=[LaqayGuestDesktop]::MatrixResources()
    # Keep the initial Items View focus throughout the serial sample.
    for($index=1;$index -le 12;$index++){
        $entry=[pscustomobject]@{Index=$index;Started=[DateTime]::UtcNow.ToString('o');Finished=$null;Before=$null;After=$null;ObservedPngCount=0;Published=$false;Error=$null}
        try{
            [LaqayGuestDesktop]::ImageClipboard()
            $entry.Before=[LaqayGuestDesktop]::FolderInputState([IntPtr]$window.HWND)
            Assert-True ($entry.Before.Foreground -and $entry.Before.FocusWithinWindow -and ($entry.Before.GuiFlags -band 0x1e) -eq 0 -and $entry.Before.MenuOwner -eq 0) ('Serial paste '+$index+' lost guest folder input focus.')
            [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[System.UInt16[]]@(17,86))
            Wait-For {@(Get-ChildItem -LiteralPath $path -Filter '*.png' -File).Count -eq $index} ('Serial paste '+$index+' did not publish the expected image in the active guest folder.')
            $entry.Published=$true
        }catch{$entry.Error=$_.Exception.Message;throw}finally{
            $entry.Finished=[DateTime]::UtcNow.ToString('o')
            $entry.ObservedPngCount=@(Get-ChildItem -LiteralPath $path -Filter '*.png' -File).Count
            try{$entry.After=[LaqayGuestDesktop]::FolderInputState([IntPtr]$window.HWND)}catch{if(-not $entry.Error){$entry.Error=$_.Exception.Message}}
            $report.SerialPastes+=@($entry);Save-Report
        }
        Assert-True (-not $entry.Error) ('Serial paste '+$index+' input inspection failed: '+$entry.Error)
    }
    $files=@(Get-ChildItem -LiteralPath $path -Force)
    Assert-True ($files.Count -eq 12) 'The serial sample lost images or left staging files.'
    foreach($file in $files){Check-Png $file.FullName}
    $report.ResourceSamples+=@([pscustomobject]@{Phase='Serial';Before=$before;After=[LaqayGuestDesktop]::MatrixResources()})
}
Run-Case 'VirtualFileImageNativePaste' {
    Assert-True ((Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Laqay' -Name Enabled) -eq 1) 'The virtual-file reference requires the running application enabled initially.'
    foreach($enabled in @($false,$true)){
        [LaqayGuestDesktop]::ToggleEnabled()
        Wait-For {(Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Laqay' -Name Enabled) -eq [int]$enabled} 'The virtual-file reference could not set Enabled.'
        $path=New-CaseFolder ('virtual-file-'+$enabled);$window=Open-Folder $path
        $proof=[pscustomobject]@{LaqayEnabled=$enabled;Before=$null;After=$null;Input=$null;FileSha256=$null;OnlyExpectedFile=$false;ProviderClosed=$false;Error=$null}
        $report.AdverseFixturesClosed=$false
        try{
            [LaqayGuestDesktop]::BeginVirtualFileClipboard()
            $proof.Before=[LaqayGuestDesktop]::VirtualFileClipboardState()
            Assert-True ($proof.Before.Current -and $proof.Before.OwnerPid -eq $proof.Before.SourcePid -and $proof.Before.HasPng -and $proof.Before.HasDescriptor -and $proof.Before.HasContents -and -not $proof.Before.HasFileDrop -and -not $proof.Before.Expired -and -not $proof.Before.Error) 'The live virtual provider did not offer both virtual files and PNG.'
            $proof.Input=[LaqayGuestDesktop]::FolderInputState([IntPtr]$window.HWND)
            Assert-True ($proof.Input.Foreground -and $proof.Input.FocusWithinWindow) 'The virtual-file target lost folder focus.'
            [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86))
            $expected=Join-Path $path $proof.Before.FileName
            Wait-For {(Test-Path -LiteralPath $expected) -and (Get-Item -LiteralPath $expected).Length -eq $proof.Before.Length} 'Native Shell did not paste the virtual file.'
            Start-Sleep -Milliseconds 700
            $proof.After=[LaqayGuestDesktop]::VirtualFileClipboardState()
            $proof.FileSha256=(Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash
            $files=@(Get-ChildItem -LiteralPath $path -Force)
            $proof.OnlyExpectedFile=($files.Count -eq 1 -and -not $files[0].PSIsContainer -and $files[0].Name -ceq $proof.Before.FileName)
            Assert-True ($proof.OnlyExpectedFile -and $proof.FileSha256 -ceq $proof.Before.Sha256) 'Virtual-file paste produced an image, staging output, or changed file bytes.'
            Assert-True ($proof.After.Current -and $proof.After.OwnerPid -eq $proof.Before.OwnerPid -and $proof.After.SourceThread -eq $proof.Before.SourceThread -and $proof.After.HasPng -and $proof.After.HasDescriptor -and $proof.After.HasContents -and -not $proof.After.HasFileDrop -and $proof.After.ContentReads -gt $proof.Before.ContentReads -and -not $proof.After.Expired -and -not $proof.After.Error) 'The same live OLE provider did not supply native file contents.'
        }catch{$proof.Error=$_.Exception.Message;throw}finally{
            try{[LaqayGuestDesktop]::EndVirtualFileClipboard();$proof.ProviderClosed=$true;$report.AdverseFixturesClosed=$true}finally{$report.VirtualFileProof+=@($proof);Save-Report}
        }
    }
}
Run-Case 'SustainedLargePngResponsive' {
    $path=New-CaseFolder 'sustained-large-png';$window=Open-Folder $path
    $watch=[Diagnostics.Stopwatch]::StartNew();$before=[LaqayGuestDesktop]::MatrixResources()
    $report.SustainedLargePng=[pscustomobject]@{Dimension=4096;RequiredCount=12;Completed=@();ElapsedMilliseconds=0;MinimumMilliseconds=30000;BudgetMilliseconds=120000;Error=$null}
    try{
        for($index=1;$index -le 12;$index++){
            Assert-True ($watch.ElapsedMilliseconds -lt 120000) 'The sustained PNG workload exceeded its budget.'
            $frame=[Diagnostics.Stopwatch]::StartNew()
            [LaqayGuestDesktop]::MatrixPngClipboard(4096)
            $input=[LaqayGuestDesktop]::FolderInputState([IntPtr]$window.HWND)
            Assert-True ($input.Foreground -and $input.FocusWithinWindow -and $input.ItemsViewFocused) 'The sustained PNG workload lost the folder view.'
            [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86))
            Wait-For {Assert-True ([LaqayGuestDesktop]::MatrixApplicationResponsive()) 'The tray stopped responding during the sustained PNG workload.';@(Get-ChildItem -LiteralPath $path -Filter '*.png' -File).Count -eq $index} 'A sustained large PNG was not published.' 30
            $files=@(Get-ChildItem -LiteralPath $path -Filter '*.png' -File | Sort-Object LastWriteTimeUtc,Name)
            $image=[Drawing.Bitmap]::new($files[-1].FullName)
            try{
                Assert-True ($image.Width -eq 4096 -and $image.Height -eq 4096) 'A sustained PNG changed dimensions.'
                $points=@(@(0,0),@(4095,0),@(0,4095),@(4095,4095))
                for($corner=0;$corner -lt 4;$corner++){Assert-True ($image.GetPixel($points[$corner][0],$points[$corner][1]).ToArgb() -eq [LaqayGuestDesktop]::MatrixPixel($corner)) 'A sustained PNG changed alpha/channels.'}
            }finally{$image.Dispose()}
            Assert-True (@(Get-ChildItem -LiteralPath $path -Force).Count -eq $index) 'The sustained workload left staging output.'
            $report.SustainedLargePng.Completed+=@([pscustomobject]@{Index=$index;File=$files[-1].Name;Sha256=(Get-FileHash -LiteralPath $files[-1].FullName -Algorithm SHA256).Hash;ElapsedMilliseconds=$frame.ElapsedMilliseconds;Input=$input;Responsive=[LaqayGuestDesktop]::MatrixApplicationResponsive();Resources=[LaqayGuestDesktop]::MatrixResources()})
            Save-Report
            # Keep the bounded sample active for at least 30 seconds, rather than
            # presenting a fast burst as a sustained workload.
            $pace=3000-$frame.ElapsedMilliseconds;if($pace -gt 0){Start-Sleep -Milliseconds $pace}
        }
        Assert-True ($watch.ElapsedMilliseconds -ge 30000 -and $watch.ElapsedMilliseconds -le 120000) 'The sustained PNG sample duration is outside its declared bounds.'
        $report.ResourceSamples+=@([pscustomobject]@{Phase='SustainedLargePng';Before=$before;After=[LaqayGuestDesktop]::MatrixResources()})
    }catch{$report.SustainedLargePng.Error=$_.Exception.Message;throw}finally{$report.SustainedLargePng.ElapsedMilliseconds=$watch.ElapsedMilliseconds;Save-Report}
}
$expectedCases=if($IncludeRealApplications){35}else{31}
if($IncludeWindowsTerminal){$expectedCases+=2}
Assert-True ($report.Cases.Count -eq $expectedCases) 'The complete adverse suite did not execute.'
