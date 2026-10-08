@echo off
setlocal
set "KEEPALIVE_SOURCE=%~f0"
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop'; try { $source=[IO.File]::ReadAllText($env:KEEPALIVE_SOURCE); $offset=$source.LastIndexOf('# KEEPALIVE POWERSHELL'); if ($offset -lt 0) { throw 'Embedded script is missing.' }; & ([scriptblock]::Create($source.Substring($offset))) } catch { Write-Host 'KeepAlive failed:' $_.Exception.Message -ForegroundColor Red; exit 1 }"
set "KEEPALIVE_EXIT=%ERRORLEVEL%"
if not "%KEEPALIVE_EXIT%"=="0" pause
exit /b %KEEPALIVE_EXIT%

# KEEPALIVE POWERSHELL
#requires -Version 5.1
<#
.SYNOPSIS
    Keeps Windows awake and monitors a Wi-Fi connection.
.DESCRIPTION
    Pings the local gateway and reconnects when needed. Optional Internet probes
    use an HTTP HEAD request. Power and network changes can be restored.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest

# Configuration

$Script:LauncherPath = $env:KEEPALIVE_SOURCE
$Script:Root = Split-Path -Parent $Script:LauncherPath
$Script:StatePath = Join-Path $Script:Root 'keepalive.state.json'

$Script:InternetProbeUrl = 'http://www.msftconnecttest.com/connecttest.txt'
$Script:TextPath = Join-Path $Script:Root 'keepalive.txt'

# powercfg: Wireless Adapter Settings > Power Saving Mode (0 = Maximum Performance)
$Script:WifiPowerSub     = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$Script:WifiPowerSetting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'

# SetThreadExecutionState
$Script:ES_CONTINUOUS       = [uint32]2147483648
$Script:ES_SYSTEM_REQUIRED  = [uint32]1
$Script:ES_DISPLAY_REQUIRED = [uint32]2

$Script:DefaultConfig = [ordered]@{
    Profile          = ''      # Wi-Fi profile (empty = currently connected network)
    PingIntervalSec  = 20      # gateway ping interval in seconds
    InternetCheckMin = 0       # Internet probe interval in minutes (0 = disabled)
    KeepDisplayOn    = $false  # allow the display to turn off while keeping Windows awake
    DurationHours    = 0       # 0 = unlimited
}

if (-not ('KeepAlive.NativeMethods' -as [type])) {
    Add-Type -Namespace KeepAlive -Name NativeMethods -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
[DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);
'@
}

# Utilities

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-WinRT {
    try {
        $null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
        return $true
    } catch {
        return $false
    }
}

function Read-State([string]$Section = '') {
    $state = @{}
    if (Test-Path -LiteralPath $Script:StatePath) {
        try {
            $json = Get-Content -LiteralPath $Script:StatePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $json -or $json -isnot [pscustomobject]) { throw 'Expected a JSON object.' }
            foreach ($property in $json.PSObject.Properties) { $state[$property.Name] = $property.Value }
        } catch {
            throw 'Cannot read keepalive.state.json. Restore a valid copy before continuing.'
        }
    }
    if (-not $Section) { return $state }
    $result = @{}
    if ($state.ContainsKey($Section)) {
        if ($state[$Section] -isnot [pscustomobject]) { throw "Invalid state section '$Section'." }
        foreach ($property in $state[$Section].PSObject.Properties) { $result[$property.Name] = $property.Value }
    }
    $result
}

function Write-State([string]$Section, $Data) {
    $state = Read-State
    $state[$Section] = $Data
    $temporaryPath = "$Script:StatePath.tmp"
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporaryPath -Destination $Script:StatePath -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -ErrorAction SilentlyContinue }
    }
}

function Read-Config {
    $config = [ordered]@{}
    foreach ($key in $Script:DefaultConfig.Keys) { $config[$key] = $Script:DefaultConfig[$key] }
    $saved = Read-State 'Config'
    foreach ($key in @($config.Keys)) {
        if ($saved.ContainsKey($key) -and $null -ne $saved[$key]) {
            $value = $saved[$key]
            $valid = switch ($key) {
                'Profile' { $value -is [string] -and $value -notmatch '[\r\n]' }
                'KeepDisplayOn' { $value -is [bool] }
                default {
                    $maximum = @{ PingIntervalSec = 300; InternetCheckMin = 120; DurationHours = 72 }[$key]
                    $minimum = if ($key -eq 'PingIntervalSec') { 5 } else { 0 }
                    ($value -is [int] -or $value -is [long]) -and $value -ge $minimum -and $value -le $maximum
                }
            }
            if ($valid) { $config[$key] = $value }
            else { Write-Warning "Invalid setting '$key'; using the default value." }
        }
    }
    $config
}

function Write-Event([string]$Message, [ValidateSet('Info', 'Ok', 'Warn', 'Err')][string]$Level = 'Info') {
    $color = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Err = 'Red' }[$Level]
    $stamp = Get-Date -Format 'HH:mm:ss'
    Clear-StatusLine
    Write-Host "  [$stamp] $Message" -ForegroundColor $color
}

function Get-ConsoleWidth { [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1) }

function Clear-StatusLine { Write-Host ("`r" + (' ' * (Get-ConsoleWidth)) + "`r") -NoNewline }

function Write-StatusLine([string]$Text) {
    $width = Get-ConsoleWidth
    if ($Text.Length -gt $width) { $Text = $Text.Substring(0, $width) }
    Write-Host ("`r" + $Text.PadRight($width)) -NoNewline -ForegroundColor Cyan
}

function Format-Duration([TimeSpan]$Span) {
    '{0:00}:{1:00}:{2:00}' -f [Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds
}

function Read-Int([string]$Prompt, [int]$Min, [int]$Max) {
    while ($true) {
        $raw = Read-Host "  $Prompt [$Min-$Max]"
        $value = 0
        if ([int]::TryParse($raw, [ref]$value) -and $value -ge $Min -and $value -le $Max) { return $value }
        Write-Host '  Invalid value.' -ForegroundColor Yellow
    }
}

function Wait-Enter { $null = Read-Host "`n  Press ENTER to return to the menu" }

function Write-Banner([string]$Subtitle = 'Keep Windows awake and connected') {
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor DarkCyan
    Write-Host '    KEEPALIVE' -ForegroundColor Cyan
    Write-Host "    $Subtitle" -ForegroundColor DarkGray
    Write-Host '  ==============================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

# Network

function Get-WifiAdapter {
    # NdisPhysicalMedium 9 = Native 802.11
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.NdisPhysicalMedium -eq 9 } |
        Sort-Object @{ Expression = { $_.Status -eq 'Up' }; Descending = $true } |
        Select-Object -First 1
}

function Get-NetworkState {
    $state = [pscustomobject]@{ Adapter = $null; Profile = $null; Metered = $null; Gateway = $null }
    $adapter = Get-WifiAdapter
    if (-not $adapter) { return $state }
    $state.Adapter = $adapter

    if ($Script:HasWinRT) {
        try {
            $wlan = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles() |
                Where-Object {
                    $_.IsWlanConnectionProfile -and $_.GetNetworkConnectivityLevel().ToString() -ne 'None' -and
                    $_.NetworkAdapter.NetworkAdapterId -eq [guid]$adapter.InterfaceGuid
                } |
                Select-Object -First 1
            if ($wlan) {
                $state.Profile = $wlan.ProfileName
                $cost = $wlan.GetConnectionCost().NetworkCostType.ToString()
                if ($cost -ne 'Unknown') { $state.Metered = $cost -ne 'Unrestricted' }
            }
        } catch {
            Write-Verbose 'Windows network profile information is unavailable.'
        }
    }

    $state.Gateway = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric |
        Select-Object -First 1 -ExpandProperty NextHop
    $state
}

# Gateway latency in milliseconds; returns $null when unreachable.
function Get-GatewayLatency([string]$Address) {
    if (-not $Address) { return $null }
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        foreach ($attempt in 1..2) {
            $reply = $ping.Send($Address, 1500)
            if ($reply.Status -eq 'Success') { return [int]$reply.RoundtripTime }
        }
    } catch {
        # Unavailable network: treat as a timeout
    } finally {
        $ping.Dispose()
    }
    $null
}

# HTTP HEAD request; no response body is downloaded.
function Test-Internet {
    try {
        $request = [System.Net.HttpWebRequest]::Create($Script:InternetProbeUrl)
        $request.Method = 'HEAD'
        $request.Timeout = 5000
        $request.AllowAutoRedirect = $false
        $response = $request.GetResponse()
        $ok = [int]$response.StatusCode -eq 200
        $response.Close()
        $ok
    } catch {
        $false
    }
}

function Get-WlanProfiles {
    netsh wlan show profiles 2>$null |
        ForEach-Object { if ($_ -match '^\s{4}[^:]+?\s+:\s(.+)$') { $Matches[1].Trim() } }
}

function Resolve-TargetProfile {
    if ($Script:Config.Profile) { return $Script:Config.Profile }
    (Get-NetworkState).Profile
}

function Wait-WifiReady([string]$ProfileName, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 2
        $state = Get-NetworkState
        $rightNetwork = $null -eq $state.Profile -or $state.Profile -eq $ProfileName
        if ($rightNetwork -and $null -ne (Get-GatewayLatency $state.Gateway)) { return $true }
    } while ((Get-Date) -lt $deadline)
    $false
}

function Invoke-WifiReconnect([string]$ProfileName) {
    Write-Event 'Reconnecting to the selected Wi-Fi profile...' Warn
    $adapter = Get-WifiAdapter
    if (-not $adapter) { return $false }
    netsh wlan connect "name=$ProfileName" "interface=$($adapter.Name)" *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    if (Wait-WifiReady $ProfileName 20) { return $true }

    if ($Script:IsAdmin -and $adapter) {
        Write-Event 'Restarting the Wi-Fi adapter...' Warn
        Restart-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        netsh wlan connect "name=$ProfileName" "interface=$($adapter.Name)" *> $null
        if ($LASTEXITCODE -ne 0) { return $false }
        if (Wait-WifiReady $ProfileName 30) { return $true }
    }
    $false
}

# Power settings

function Get-PowerIndex([string]$Subgroup, [string]$Setting) {
    $schemeOutput = powercfg /getactivescheme 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $scheme = [regex]::Match(($schemeOutput -join ' '), '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
    if (-not $scheme) { return $null }
    $output = powercfg /q $scheme $Subgroup $Setting 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $values = @([regex]::Matches(($output -join "`n"), '0x([0-9a-fA-F]{8})') |
        ForEach-Object { [Convert]::ToInt32($_.Groups[1].Value, 16) })
    if ($values.Count -lt 2) { return $null }
    [pscustomobject]@{ AC = $values[-2]; DC = $values[-1]; Scheme = $scheme }
}

function Set-PowerIndex([string]$Subgroup, [string]$Setting, [int]$AC, [int]$DC, [string]$Scheme = 'SCHEME_CURRENT') {
    powercfg /setacvalueindex $Scheme $Subgroup $Setting $AC 2>$null | Out-Null
    $ok = $LASTEXITCODE -eq 0
    powercfg /setdcvalueindex $Scheme $Subgroup $Setting $DC 2>$null | Out-Null
    $ok = $ok -and $LASTEXITCODE -eq 0
    powercfg /setactive SCHEME_CURRENT 2>$null | Out-Null
    $ok -and $LASTEXITCODE -eq 0
}

function Get-ProfileCost([string]$ProfileName) {
    $output = netsh wlan show profile "name=$ProfileName" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    # Skip the change if localized output does not expose a recognized cost value.
    $match = [regex]::Match(($output -join "`n"), '(?im)^\s*[^:\r\n]+:\s*(Unrestricted|Fixed|Variable|Default)\s*$')
    if ($match.Success) { $match.Groups[1].Value }
}

function Set-ProfileCost([string]$ProfileName, [string]$Cost) {
    netsh wlan set profileparameter "name=$ProfileName" "cost=$Cost" *> $null
    $LASTEXITCODE -eq 0
}

# Menu actions

function Start-TextSession {
    $writer = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $nextWrite = 1000L
    $count = 0L
    $duration = [long]$Script:Config.DurationHours * 3600000
    Clear-Host
    Write-Banner 'TXT session - Q / ESC to stop, or Ctrl+Alt+Q from any window'
    Write-Host "  Appending one character per second to: $Script:TextPath"
    Write-Host '  Sequence: 424242... | No keyboard input is simulated.'
    try {
        # Deny other writers to prevent overlapping sessions on the same file.
        $stream = [IO.File]::Open($Script:TextPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $sequenceOffset = $stream.Length % 2
        try { $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false)) }
        catch { $stream.Dispose(); throw }
        $writer.AutoFlush = $true
        Write-Event 'TXT session started.' Ok
        while ($true) {
            $stop = $false
            while ([Console]::KeyAvailable) {
                if ([Console]::ReadKey($true).Key -in 'Q', 'Escape') { $stop = $true }
            }
            $emergencyStop = ([KeepAlive.NativeMethods]::GetAsyncKeyState(0x11) -band 0x8000) -and
                ([KeepAlive.NativeMethods]::GetAsyncKeyState(0x12) -band 0x8000) -and
                ([KeepAlive.NativeMethods]::GetAsyncKeyState(0x51) -band 0x8000)
            if ($stop -or $emergencyStop -or ($duration -gt 0 -and $clock.ElapsedMilliseconds -ge $duration)) { break }
            if ($clock.ElapsedMilliseconds -ge $nextWrite) {
                $character = if (($count + $sequenceOffset) % 2 -eq 0) { '4' } else { '2' }
                $writer.Write($character)
                $count++
                $nextWrite = $clock.ElapsedMilliseconds + 1000
                Write-StatusLine "  Written $count characters | [Q / ESC / Ctrl+Alt+Q] stop"
            }
            Start-Sleep -Milliseconds 50
        }
    } catch {
        Write-Event 'TXT session failed. Check file permissions, available space, and other running sessions.' Err
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        $clock.Stop()
        Write-Event 'TXT session ended.' Info
    }
    Wait-Enter
}

function Start-KeepAliveSession {
    $cfg = $Script:Config
    $target = Resolve-TargetProfile
    if (-not $target) {
        Write-Host "`n  No Wi-Fi connection or configured profile." -ForegroundColor Red
        Write-Host '  Connect to Wi-Fi or select a profile in Settings.' -ForegroundColor Red
        Wait-Enter
        return
    }

    $flags = $Script:ES_CONTINUOUS -bor $Script:ES_SYSTEM_REQUIRED
    if ($cfg.KeepDisplayOn) { $flags = $flags -bor $Script:ES_DISPLAY_REQUIRED }
    $flags = [uint32]$flags

    $start      = Get-Date
    $end        = if ($cfg.DurationHours -gt 0) { $start.AddHours($cfg.DurationHours) } else { [datetime]::MaxValue }
    $nextCheck  = $start
    $nextNet    = $start
    $pingFails  = 0
    $netFails   = 0
    $reconnects = 0
    $latency    = $null
    $netStatus  = if ($cfg.InternetCheckMin -gt 0) { '...' } else { 'off' }

    Clear-Host
    Write-Banner 'Session active - press Q or ESC to stop'
    Write-Host "  Network: $target | ping every $($cfg.PingIntervalSec)s | internet: $(if ($cfg.InternetCheckMin) { "every $($cfg.InternetCheckMin) min" } else { 'off' }) | display: $(if ($cfg.KeepDisplayOn) { 'always on' } else { 'may turn off' })" -ForegroundColor DarkGray
    Write-Event "Session started (duration: $(if ($cfg.DurationHours) { "$($cfg.DurationHours) h" } else { 'unlimited' }))" Ok

    try {
        $stop = $false
        while (-not $stop) {
            $now = Get-Date
            if ($now -ge $end) { Write-Event 'Configured duration reached.' Ok; break }

            while ([Console]::KeyAvailable) {
                if ([Console]::ReadKey($true).Key -in 'Q', 'Escape') { $stop = $true }
            }
            if ($stop) { break }

            if ($now -ge $nextCheck) {
                # Refresh the execution state on each check.
                $null = [KeepAlive.NativeMethods]::SetThreadExecutionState($flags)

                $state   = Get-NetworkState
                $latency = Get-GatewayLatency $state.Gateway
                $wrongNetwork = $state.Profile -and $state.Profile -ne $target

                if ($null -eq $latency) { $pingFails++ }
                elseif ($pingFails -ge 2) { Write-Event 'Connection is stable again.' Ok; $pingFails = 0 }
                else { $pingFails = 0 }

                if ($wrongNetwork -or $pingFails -ge 2) {
                    $reason = if ($wrongNetwork) { "connected to a different Wi-Fi profile" } else { 'gateway unreachable' }
                    Write-Event "Connection issue: $reason." Warn
                    if (Invoke-WifiReconnect $target) {
                        $reconnects++
                        $pingFails = 0
                        Write-Event 'Reconnected.' Ok
                    } else {
                        Write-Event 'Reconnect failed; retrying on the next check.' Err
                    }
                }

                if ($cfg.InternetCheckMin -gt 0 -and $now -ge $nextNet -and $pingFails -eq 0) {
                    if (Test-Internet) {
                        if ($netFails -gt 0) { Write-Event 'Internet is reachable again.' Ok }
                        $netFails  = 0
                        $netStatus = "OK $('{0:HH:mm}' -f $now)"
                        $nextNet   = $now.AddMinutes($cfg.InternetCheckMin)
                    } else {
                        $netFails++
                        $netStatus = "KO x$netFails"
                        $nextNet   = $now.AddMinutes(1)   # retry sooner
                        Write-Event "Internet unreachable ($netFails/3)." Warn
                        if ($netFails -ge 3) {
                            if (Invoke-WifiReconnect $target) { $reconnects++ }
                            $netFails = 0
                        }
                    }
                }

                $nextCheck = (Get-Date).AddSeconds($cfg.PingIntervalSec)
            }

            $elapsed = Format-Duration ((Get-Date) - $start)
            $left    = if ($end -ne [datetime]::MaxValue) { " (remaining $(Format-Duration ($end - (Get-Date))))" } else { '' }
            $ping    = if ($null -ne $latency) { "$latency ms" } else { 'KO' }
            Write-StatusLine "  Active $elapsed$left | gateway $ping | internet $netStatus | reconnects $reconnects | [Q] stop"
            Start-Sleep -Milliseconds 500
        }
    } finally {
        $null = [KeepAlive.NativeMethods]::SetThreadExecutionState($Script:ES_CONTINUOUS)
        Write-Event 'Session ended; Windows may sleep again.' Info
    }
    Wait-Enter
}

function Select-WlanProfile {
    $profiles = @(Get-WlanProfiles)
    Write-Host ''
    Write-Host '   0) Automatic (network connected at session start)'
    for ($i = 0; $i -lt $profiles.Count; $i++) { Write-Host ('  {0,2}) {1}' -f ($i + 1), $profiles[$i]) }
    $choice = Read-Int 'Profile' 0 $profiles.Count
    if ($choice -eq 0) { '' } else { $profiles[$choice - 1] }
}

function Show-SettingsMenu {
    while ($true) {
        $cfg = $Script:Config
        Clear-Host
        Write-Banner 'Settings'
        Write-Host "  1) Wi-Fi profile        : $(if ($cfg.Profile) { $cfg.Profile } else { 'automatic (current network)' })"
        Write-Host "  2) Gateway ping interval : $($cfg.PingIntervalSec) s"
        Write-Host "  3) Internet check       : $(if ($cfg.InternetCheckMin) { "every $($cfg.InternetCheckMin) min" } else { 'disabled' })"
        Write-Host "  4) Keep display on      : $(if ($cfg.KeepDisplayOn) { 'Yes' } else { 'No (recommended)' })"
        Write-Host "  5) Session duration     : $(if ($cfg.DurationHours) { "$($cfg.DurationHours) h" } else { 'unlimited' })"
        Write-Host '  0) Back'
        Write-Host ''
        switch (Read-Host '  Choice') {
            '1' { $cfg.Profile = Select-WlanProfile }
            '2' { $cfg.PingIntervalSec = Read-Int 'Seconds between gateway pings' 5 300 }
            '3' { $cfg.InternetCheckMin = Read-Int 'Minutes between Internet checks (0 = disabled)' 0 120 }
            '4' { $cfg.KeepDisplayOn = -not $cfg.KeepDisplayOn }
            '5' { $cfg.DurationHours = Read-Int 'Hours (0 = unlimited)' 0 72 }
            '0' { return }
        }
        Write-State 'Config' $cfg
    }
}

function Invoke-Optimize {
    Clear-Host
    Write-Banner 'Optimize Windows for a long session'
    Write-Host '  Original settings are saved; use option 4 to restore them.' -ForegroundColor DarkGray
    Write-Host ''
    $backup = Read-State 'Backup'
    if ($backup.Count -gt 0) {
        Write-Host '  Restore saved settings with option 4 before optimizing again.' -ForegroundColor Yellow
        Wait-Enter
        return
    }

    # 1. Set Wi-Fi power saving to maximum performance
    $wifi = Get-PowerIndex $Script:WifiPowerSub $Script:WifiPowerSetting
    if (-not $wifi) {
        Write-Host '  [--] Wi-Fi power saving: not available on this PC' -ForegroundColor DarkGray
    } else {
        $backup.WifiPower = @{ AC = $wifi.AC; DC = $wifi.DC; Scheme = $wifi.Scheme }
        Write-State 'Backup' $backup
        if (Set-PowerIndex $Script:WifiPowerSub $Script:WifiPowerSetting 0 0 $wifi.Scheme) {
            Write-Host '  [OK] Wi-Fi power saving: maximum performance (AC and battery)' -ForegroundColor Green
        } else {
            Write-Host '  [KO] Wi-Fi power saving: could not change setting' -ForegroundColor Red
        }
    }

    # 2. Disable sleep on lid close
    $lid = Get-PowerIndex 'SUB_BUTTONS' 'LIDACTION'
    if (-not $lid) {
        Write-Host '  [--] Lid close action: not available on this PC (keep the lid open)' -ForegroundColor DarkGray
    } else {
        $backup.Lid = @{ AC = $lid.AC; DC = $lid.DC; Scheme = $lid.Scheme }
        Write-State 'Backup' $backup
        if (Set-PowerIndex 'SUB_BUTTONS' 'LIDACTION' 0 0 $lid.Scheme) {
            Write-Host '  [OK] Lid close action: do nothing' -ForegroundColor Green
        } else {
            Write-Host '  [KO] Lid close action: could not change setting' -ForegroundColor Red
        }
    }

    # 3. Set a metered connection to reduce background downloads
    $target = Resolve-TargetProfile
    $originalCost = if ($target) { Get-ProfileCost $target } else { $null }
    if (-not $target) {
        Write-Host '  [--] Metered connection: no Wi-Fi profile selected' -ForegroundColor DarkGray
    } elseif (-not $Script:IsAdmin) {
        Write-Host '  [--] Metered connection: requires administrator (option 6)' -ForegroundColor Yellow
    } elseif (-not $originalCost) {
        Write-Host '  [--] Metered connection: original cost could not be read safely' -ForegroundColor Yellow
    } else {
        $backup.MeteredProfile = $target
        $backup.MeteredCost = $originalCost
        Write-State 'Backup' $backup
        if (Set-ProfileCost $target 'Fixed') {
            Write-Host '  [OK] Metered connection enabled (reduces background traffic)' -ForegroundColor Green
        } else {
            Write-Host '  [KO] Metered connection: could not enable setting' -ForegroundColor Red
        }
    }

    Write-Event 'Optimization finished.' Info
    Wait-Enter
}

function Invoke-Restore([switch]$NoPause) {
    $backup = Read-State 'Backup'
    if ($backup.Count -eq 0) {
        Write-Host "`n  No settings to restore." -ForegroundColor DarkGray
        if (-not $NoPause) { Wait-Enter }
        return
    }

    if ($backup.ContainsKey('WifiPower')) {
        $scheme = if ($backup.WifiPower.PSObject.Properties['Scheme']) { $backup.WifiPower.Scheme } else { 'SCHEME_CURRENT' }
        if (Set-PowerIndex $Script:WifiPowerSub $Script:WifiPowerSetting $backup.WifiPower.AC $backup.WifiPower.DC $scheme) {
            $backup.Remove('WifiPower')
            Write-Host '  [OK] Wi-Fi power saving restored' -ForegroundColor Green
        } else { Write-Host '  [KO] Wi-Fi restore failed; backup retained' -ForegroundColor Red }
    }
    if ($backup.ContainsKey('Lid')) {
        $scheme = if ($backup.Lid.PSObject.Properties['Scheme']) { $backup.Lid.Scheme } else { 'SCHEME_CURRENT' }
        if (Set-PowerIndex 'SUB_BUTTONS' 'LIDACTION' $backup.Lid.AC $backup.Lid.DC $scheme) {
            $backup.Remove('Lid')
            Write-Host '  [OK] Lid close action restored' -ForegroundColor Green
        } else { Write-Host '  [KO] Lid restore failed; backup retained' -ForegroundColor Red }
    }
    if ($backup.ContainsKey('MeteredProfile')) {
        $cost = if ($backup.ContainsKey('MeteredCost')) { $backup.MeteredCost } else { 'Default' }
        if (-not $backup.ContainsKey('MeteredCost')) { Write-Warning 'Legacy backup has no original network cost; restoring Default.' }
        if ($Script:IsAdmin -and (Set-ProfileCost $backup.MeteredProfile $cost)) {
            Write-Host '  [OK] Metered connection restored' -ForegroundColor Green
            $backup.Remove('MeteredProfile')
            $backup.Remove('MeteredCost')
        } else {
            Write-Host '  [--] Metered connection: restore failed or requires administrator (option 6)' -ForegroundColor Yellow
        }
    }

    Write-State 'Backup' $backup
    Write-Event 'Restore finished.' Info
    if (-not $NoPause) { Wait-Enter }
}

function Show-Diagnostics {
    Clear-Host
    Write-Banner 'Quick diagnostics'
    $state = Get-NetworkState
    $wifi  = Get-PowerIndex $Script:WifiPowerSub $Script:WifiPowerSetting
    $wifiLabels = 'Maximum performance', 'Low power saving', 'Medium power saving', 'Maximum power saving'

    Write-Host "  Wi-Fi adapter        : $(if ($state.Adapter) { "$($state.Adapter.Name) ($($state.Adapter.Status))" } else { 'not found' })"
    Write-Host "  Connected network       : $(if ($state.Profile) { $state.Profile } else { 'none / unknown' })"
    Write-Host "  Gateway             : $(if ($state.Gateway) { $state.Gateway } else { '-' })"
    Write-Host "  Metered connection      : $(if ($null -eq $state.Metered) { '-' } elseif ($state.Metered) { 'Yes' } else { 'No' })"
    if ($wifi) {
        Write-Host "  Wi-Fi power saving     : AC $($wifiLabels[$wifi.AC]) | battery $($wifiLabels[$wifi.DC])"
    }
    Write-Host "  Administrator      : $(if ($Script:IsAdmin) { 'Yes' } else { 'No' })"
    Write-Host ''

    if ($state.Gateway) {
        Write-Host '  Gateway ping (local traffic):'
        foreach ($i in 1..4) {
            $ms = Get-GatewayLatency $state.Gateway
            Write-Host "    #$i $(if ($null -ne $ms) { "$ms ms" } else { 'timeout' })"
        }
    }
    Write-Host -NoNewline '  Internet (HTTP HEAD): '
    if (Test-Internet) { Write-Host 'OK' -ForegroundColor Green } else { Write-Host 'unreachable' -ForegroundColor Red }
    Wait-Enter
}

function Restart-AsAdmin {
    if ($Script:IsAdmin) {
        Write-Host "`n  Already running as administrator." -ForegroundColor DarkGray
        Wait-Enter
        return
    }
    try {
        Start-Process -FilePath $Script:LauncherPath -Verb RunAs -ErrorAction Stop
        exit
    } catch {
        Write-Host "`n  Elevation cancelled." -ForegroundColor Yellow
        Wait-Enter
    }
}

function Write-StatusSummary {
    $state   = Get-NetworkState
    $latency = Get-GatewayLatency $state.Gateway
    $network = if ($state.Profile) { $state.Profile } elseif ($state.Gateway) { 'connected' } else { 'DISCONNECTED' }
    $color   = if ($null -ne $latency) { 'Green' } else { 'Red' }

    Write-Host "  Wi-Fi     : $network$(if ($null -ne $latency) { "  (gateway $($state.Gateway), $latency ms)" })" -ForegroundColor $color
    Write-Host "  Metered   : $(if ($null -eq $state.Metered) { '-' } elseif ($state.Metered) { 'Yes' } else { 'No - enable with option 3' })" -ForegroundColor DarkGray
    Write-Host "  Admin     : $(if ($Script:IsAdmin) { 'Yes' } else { 'No - adapter restart and metered settings limited' })" -ForegroundColor DarkGray
    if ((Read-State 'Backup').Count -gt 0) {
        Write-Host '  Note      : saved settings available (option 4 to restore)' -ForegroundColor Yellow
    }
}

function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Banner
        Write-StatusSummary
        Write-Host ''
        Write-Host '  1) Start keep-alive session'
        Write-Host '  2) Settings'
        Write-Host '  3) Optimize Windows for a long session'
        Write-Host '  4) Restore original settings'
        Write-Host '  5) Quick diagnostics'
        Write-Host '  6) Restart as administrator'
        Write-Host '  7) Write 424242... to a TXT file (one character per second)'
        Write-Host '  0) Exit'
        Write-Host ''
        switch (Read-Host '  Choice') {
            '1' { Start-KeepAliveSession }
            '2' { Show-SettingsMenu }
            '3' { Invoke-Optimize }
            '4' { Clear-Host; Write-Banner 'Restore'; Invoke-Restore }
            '5' { Show-Diagnostics }
            '6' { Restart-AsAdmin }
            '7' { Start-TextSession }
            '0' {
                if ((Read-State 'Backup').Count -gt 0) {
                    if ((Read-Host '  Restore original settings before exiting? (Y/n)') -notmatch '^[nN]') {
                        Invoke-Restore -NoPause
                    }
                }
                return
            }
        }
    }
}

function Invoke-Main {
    $Host.UI.RawUI.WindowTitle = 'KeepAlive'
    $Script:IsAdmin  = Test-IsAdmin
    $Script:HasWinRT = Initialize-WinRT
    $Script:Config   = Read-Config
    Show-MainMenu
}

Invoke-Main
