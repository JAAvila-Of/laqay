# Loaded only by the armed adverse runner in its exact owned run directory.
if(-not $IncludeAdverse -or -not $IncludeRealApplications -or $PSScriptRoot -ne $root -or $report.Cases.Count -ne 13){throw 'Real application cases require the owned basic context and explicit opt-in.'}
[LaqayGuestDesktop]::RequireRole('Primary')
foreach($kind in @('Notepad','Edge')){
    $entry=[pscustomobject]@{Kind=$kind;Inventory=$null;Info=$null;Text=@();Image=$null;Cleanup=$null;Error=$null}
    $report.RealApplications+=@($entry)
    try{
        Run-Case ($kind+'RealText') {
            $notepadExecutable='';$packageName=''
            if($kind -eq 'Notepad'){
                $packages=@(Get-AppxPackage -Name Microsoft.WindowsNotepad | Where-Object {-not $_.IsResourcePackage -and -not $_.IsFramework})
                Assert-True ($packages.Count -eq 1 -and [string]$packages[0].Status -eq 'Ok' -and $packages[0].Publisher.Contains('O=Microsoft Corporation')) 'The registered Microsoft Notepad package is unavailable.'
                $package=$packages[0];$manifest=Get-AppxPackageManifest -Package $package.PackageFullName
                $applications=@($manifest.Package.Applications.Application | Where-Object {$_.Executable -match '(^|\\)Notepad\.exe$'})
                Assert-True ($applications.Count -eq 1) 'The Notepad package entry point is ambiguous.'
                $notepadExecutable=Join-Path $package.InstallLocation $applications[0].Executable;$packageName=$package.PackageFullName
                $entry.Inventory=[pscustomobject]@{Name=$package.Name;Version=[string]$package.Version;Package=$packageName;Executable=$notepadExecutable}
            }
            $entry.Info=[LaqayGuestDesktop]::BeginRealApplication($kind,$root,$notepadExecutable,$packageName)
            foreach($enabled in @($false,$true)){
                [LaqayGuestDesktop]::ToggleEnabled()
                Wait-For {(Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Laqay' -Name Enabled) -eq [int]$enabled} 'The real application reference could not change input state.'
                $text=[pscustomobject]@{LaqayEnabled=$enabled;Source=$null;Before=$null;After=$null;TextMatched=$false;Saved=$false;Error=$null}
                try{
                    [LaqayGuestDesktop]::FocusRealApplication()
                    [LaqayGuestDesktop]::RealApplicationChord([UInt16[]]@(17,65))
                    [LaqayGuestDesktop]::RealApplicationChord([UInt16[]]@(8))
                    Wait-For {[LaqayGuestDesktop]::RealApplicationText() -eq ''} 'The real application fixture did not clear its own editor.'
                    $text.Source=[LaqayGuestDesktop]::RealApplicationTextClipboard('Laqay real application fixture.')
                    $text.Before=[LaqayGuestDesktop]::RealApplicationState()
                    [LaqayGuestDesktop]::RealApplicationChord([UInt16[]]@(17,86))
                    Wait-For {[LaqayGuestDesktop]::RealApplicationText() -ceq 'Laqay real application fixture.'} 'The real application did not receive exact clipboard text.'
                    $text.TextMatched=$true
                    if($kind -eq 'Notepad'){
                        [LaqayGuestDesktop]::RealApplicationChord([UInt16[]]@(17,83))
                        Wait-For {[LaqayGuestDesktop]::RealNotepadSaved('Laqay real application fixture.')} 'Notepad did not save its exact owned document.'
                        $text.Saved=$true
                    }
                }catch{$text.Error=$_.Exception.Message;throw}finally{
                    try{$text.After=[LaqayGuestDesktop]::RealApplicationState()}catch{}
                    $entry.Text+=@($text);Save-Report
                }
            }
        }
        Run-Case ($kind+'RealImageDoesNotWrite') {
            $data=Join-Path $root 'data';$before=@{}
            foreach($file in @(Get-ChildItem -LiteralPath $data -Recurse -File -Force)){$before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
            $image=[pscustomobject]@{Before=$null;After=$null;FixtureMatched=$false;FilesBefore=$before.Count;FilesAfter=0;PreviousFilesPreserved=$false;FenceVerified=$false;Error=$null}
            $entry.Image=$image
            try{
                [LaqayGuestDesktop]::FocusRealApplication();[LaqayGuestDesktop]::ImageClipboard()
                $image.FixtureMatched=[LaqayGuestDesktop]::ClipboardImageIsFixture()
                Assert-True $image.FixtureMatched 'The real application image source is not the expected fixture.'
                $image.Before=[LaqayGuestDesktop]::RealApplicationState()
                [LaqayGuestDesktop]::RealApplicationChord([UInt16[]]@(17,86))
                $image.After=[LaqayGuestDesktop]::RealApplicationState()
                # A later output fences the prior request in the pinned FIFO worker.
                $path=New-CaseFolder ($kind.ToLowerInvariant()+'-real-recovery');$window=Open-Folder $path
                [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86))
                Wait-For {@(Get-ChildItem -LiteralPath $path -Filter '*.png' -File).Count -eq 1} 'Explorer did not complete the later same-clipboard paste.'
                $output=(Get-ChildItem -LiteralPath $path -Filter '*.png' -File)[0].FullName;Check-Png $output
                $after=@(Get-ChildItem -LiteralPath $data -Recurse -File -Force);$image.FilesAfter=$after.Count
                Assert-True ($after.Count -eq ($before.Count+1)) 'A real application paste wrote unexpected output or staging files.'
                foreach($file in $after){
                    if($file.FullName -eq $output){continue}
                    Assert-True ($before.ContainsKey($file.FullName) -and (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -eq $before[$file.FullName]) 'A previous fixture file changed or unexpected output appeared.'
                }
                $image.PreviousFilesPreserved=$true;$image.FenceVerified=$true
            }catch{$image.Error=$_.Exception.Message;throw}finally{Save-Report}
        }
    }catch{$entry.Error=$_.Exception.Message;throw}finally{
        try{if(-not $entry.Info){$entry.Info=[LaqayGuestDesktop]::RealApplicationDiagnostics()}}catch{}
        $entry.Cleanup=[LaqayGuestDesktop]::EndRealApplication();Save-Report
        if($entry.Cleanup -and -not $entry.Cleanup.Passed){throw 'The real application required forced or incomplete cleanup.'}
    }
}
