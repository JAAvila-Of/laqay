# These functions define an opt-in disposable-guest protocol. Dot-sourcing is inert.
function Get-ShutdownArguments([string]$CycleId) {
    if($CycleId -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid shutdown identity.'}
    return @('/s','/t','0','/d','p:0:0','/c',('Laqay shutdown '+$CycleId))
}
function Assert-ShutdownGuest([string]$LabId, [string]$CycleId) {
    if ($LabId -cnotmatch '^[a-f0-9]{32}$' -or $CycleId -cnotmatch '^[a-f0-9]{32}$' -or
        [Security.Principal.WindowsIdentity]::GetCurrent().Name -notmatch '\\LaqayLab$') {
        throw 'Shutdown validation requires the lab account and exact identities.'
    }
    $ready = Get-Content -LiteralPath 'C:\LaqayLab\ready.json' -Raw | ConvertFrom-Json
    $machine = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    if ($ready.LabId -cne $LabId -or $ready.Role -cne 'Primary' -or -not $ready.Ready -or
        $machine.Manufacturer -cne 'Microsoft Corporation' -or $machine.Model -cne 'Virtual Machine' -or
        $os.Caption -cne 'Microsoft Windows 11 Enterprise Evaluation' -or $os.BuildNumber -cne '26300') {
        throw 'Shutdown validation requires the explicitly identified Primary guest.'
    }
    $root = 'C:\LaqayLab\Shutdown\' + $CycleId
    foreach ($path in @('C:\LaqayLab', 'C:\LaqayLab\Shutdown', $root)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Shutdown evidence paths must not contain reparse points.'
        }
    }
    return $root
}

function Write-ShutdownSnapshot([string]$Path, $Value) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 12))
    $file = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
    $deadline=[DateTime]::UtcNow.AddSeconds(2)
    try{
        while($true){
            try{
                if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
                else { [IO.File]::Move($temporary, $Path) }
                break
            }catch [IO.IOException]{
                if(($_.Exception.GetBaseException().HResult -band 0xFFFF) -notin @(32,33) -or [DateTime]::UtcNow -ge $deadline){throw}
                Start-Sleep -Milliseconds 10
            }
        }
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function Test-OwnedShutdownTraceActive([string]$Name) {
    $rows=@(& "$env:SystemRoot\System32\logman.exe" query -ets 2>&1)
    if($LASTEXITCODE -ne 0){throw 'Guest trace enumeration failed.'}
    $matching=@($rows|Where-Object {[string]$_ -match ('^\s*'+[regex]::Escape($Name)+'\s')})
    if($matching.Count -gt 1){throw 'Ambiguous trace name.'}
    return $matching.Count -eq 1
}

function Start-ShutdownTrace([string]$LabId, [string]$CycleId) {
    $root = Assert-ShutdownGuest $LabId $CycleId
    if (-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Guest administrative access is required for the temporary trace.'
    }
    $path = Join-Path $root 'process.etl'
    $receipt = Join-Path $root 'trace.json'
    if ((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath $receipt)) { throw 'Refusing a reused shutdown trace.' }
    $provider = Get-WinEvent -ListProvider Microsoft-Windows-Kernel-Process
    foreach ($id in @(1, 2)) {
        $templates = @($provider.Events | Where-Object Id -eq $id | ForEach-Object Template)
        foreach ($name in @('ProcessID', 'CreateTime') + $(if ($id -eq 2) { @('ExitTime', 'ExitCode') } else { @('ParentProcessID', 'SessionID', 'ImageName') })) {
            if (-not @($templates | Where-Object { $_ -like ('*name="' + $name + '"*') }).Count) { throw 'The guest trace provider lacks required process fields.' }
        }
    }
    $name = 'LaqayShutdown-' + $CycleId
    if(Test-OwnedShutdownTraceActive $name){throw 'The named trace already exists.'}
    $started = [DateTime]::UtcNow.ToString('o')
    $state=[ordered]@{LabId=$LabId; CycleId=$CycleId; Name=$name; Path=$path; StartedUtc=$started; Provider='Microsoft-Windows-Kernel-Process'; Keyword='0x10'; MaximumMiB=32; PersistedCollector=$false; Started=$false}
    Write-ShutdownSnapshot $receipt $state
    & "$env:SystemRoot\System32\logman.exe" create trace $name -p Microsoft-Windows-Kernel-Process 0x10 4 -o $path -f bin -max 32 -ft 1 -bs 64 -nb 2 8 -ct system -ets | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The bounded guest trace did not start.' }
    $state.Started=$true
    try{Write-ShutdownSnapshot $receipt $state}catch{& "$env:SystemRoot\System32\logman.exe" stop $name -ets|Out-Null;throw}
}

function Stop-ShutdownTrace([string]$LabId, [string]$CycleId) {
    $root = Assert-ShutdownGuest $LabId $CycleId
    $path = Join-Path $root 'trace.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($receipt.LabId -cne $LabId -or $receipt.CycleId -cne $CycleId -or $receipt.Name -cne ('LaqayShutdown-' + $CycleId)) { throw 'Unexpected trace ownership.' }
    if (Test-OwnedShutdownTraceActive $receipt.Name) {
        if(-not $receipt.Started){throw 'An active trace lacks a completed ownership receipt.'}
        & "$env:SystemRoot\System32\logman.exe" stop $receipt.Name -ets | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'The owned temporary trace did not stop.' }
    }
    if(Test-OwnedShutdownTraceActive $receipt.Name){throw 'The owned trace remains active.'}
}

function Convert-ShutdownProcessEvent([string]$EventXml) {
    $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($EventXml),$settings)
    $xml=[Xml.XmlDocument]::new();$xml.XmlResolver=$null
    try{$xml.Load($reader)}finally{$reader.Dispose()}
    $system = $xml.Event.System
    if ($system.Provider.Name -cne 'Microsoft-Windows-Kernel-Process' -or
        ([guid]$system.Provider.Guid) -ne [guid]'22fb2cd6-0e7b-422b-a0c7-2fad1fd0e716' -or [int]$system.EventID -notin @(1, 2)) {
        throw 'Unexpected shutdown process event provider or ID.'
    }
    $data = @{}
    foreach ($entry in $xml.Event.EventData.Data) {
        if ($data.ContainsKey([string]$entry.Name)) { throw 'Duplicate process event field.' }
        $data[[string]$entry.Name] = [string]$entry.InnerText
    }
    $id = [int]$system.EventID
    $required = @('ProcessID', 'CreateTime') + $(if ($id -eq 1) { @('ParentProcessID', 'SessionID', 'ImageName') } else { @('ExitTime', 'ExitCode') })
    foreach ($key in $required) { if (-not $data.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($data[$key])) { throw 'Incomplete shutdown process event.' } }
    $result = [ordered]@{EventId=$id; Pid=[uint32]$data.ProcessID; CreatedUtc=([DateTimeOffset]::Parse($data.CreateTime, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime.ToString('o')}
    if ($id -eq 1) { $result.ParentPid=[uint32]$data.ParentProcessID; $result.SessionId=[uint32]$data.SessionID; $result.Image=$data.ImageName }
    else { $result.ExitedUtc=([DateTimeOffset]::Parse($data.ExitTime, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime.ToString('o'); $result.ExitCode=[uint32]$data.ExitCode }
    return [pscustomobject]$result
}

function Test-ShutdownProcessEvidence($Events, $Expected) {
    $created = ([DateTimeOffset]::Parse($Expected.CreatedUtc)).UtcDateTime.ToString('o')
    $matching = @($Events | Where-Object { $_.Pid -eq $Expected.Pid -and $_.CreatedUtc -ceq $created })
    $start = @($matching | Where-Object EventId -eq 1)
    $stop = @($matching | Where-Object EventId -eq 2)
    if ($start.Count -ne 1 -or $stop.Count -ne 1 -or $Expected.Pid -le 0 -or $Expected.ParentPid -le 0 -or $Expected.SessionId -le 0) { throw 'Missing or ambiguous exact process lifetime.' }
    if ($start[0].ParentPid -ne $Expected.ParentPid -or $start[0].SessionId -ne $Expected.SessionId -or
        [IO.Path]::GetFileName($start[0].Image) -cne 'laqay.exe' -or $stop[0].ExitCode -ne 0 -or
        [DateTimeOffset]::Parse($stop[0].ExitedUtc) -lt [DateTimeOffset]::Parse($Expected.ShutdownRequestedUtc) -or
        [DateTimeOffset]::Parse($stop[0].ExitedUtc) -gt [DateTimeOffset]::Parse($Expected.ShutdownRequestedUtc).AddSeconds(60) -or
        [DateTimeOffset]::Parse($start[0].CreatedUtc) -ge [DateTimeOffset]::Parse($Expected.ShutdownRequestedUtc)) {
        throw 'Process identity, normal exit or shutdown timing was not established.'
    }
    return [pscustomobject]@{Passed=$true; Start=$start[0]; Stop=$stop[0]; ExitCode=0}
}
