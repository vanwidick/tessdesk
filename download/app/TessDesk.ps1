#Requires -Version 5.1
# TessDesk v4.3.11 (Restore / Remember buttons styled like Paycheck Live; TOTALS pop-up: week / month / year running totals; CAMERAS panel from saved Sentry / Dashcam clips; checks for updates on open / wake; compact-when-OFF via cb_compact_addon.ps1) - live Tesla charging cost desktop widget + Tesla controls (Tessie API).  DESIGN BY VAN.
param(
    [string]$ConfigPath,
    [string]$Snapshot,    # optional: folder to write PNG snapshots of both themes
    [switch]$Quick433,    # with -SelfTest: run only the v4.3.3 steps (trunk, sentry, drives, paused-session energy)
    [switch]$Quick432,    # with -SelfTest: run only the v4.3.2 steps (glow states, seats, flash lights, last charge)
    [switch]$SelfTest     # test run: controls forced to DRY RUN (nothing is sent to the car), snapshots, selftest.json, then exit
)
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$ErrorActionPreference = 'Stop'
$AppName    = 'TessDesk'
$AppVersion = '4.3.11'
$AppDate    = 'Oct 4, 2026'

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'config.json' }
$statePath  = Join-Path $scriptDir 'state.json'
$statusPath = Join-Path $scriptDir 'widget-status.json'
$logPath    = Join-Path $scriptDir 'widget.log'
$snapReqPath = Join-Path $scriptDir 'snapshot.request'
$iconPath   = Join-Path $scriptDir 'tessdesk.ico'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------- Single instance (per install folder) ----------------
$mutexName = 'Local\TessDesk_' + (($scriptDir.ToLowerInvariant()) -replace '[^a-z0-9]', '_')
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    # Already running: hand a snapshot request to the running instance, then quit.
    if ($Snapshot) { try { Set-Content -LiteralPath $snapReqPath -Value $Snapshot -Encoding UTF8 } catch {} }
    exit 0
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

function Write-WidgetLog {
    param([string]$Msg)
    try {
        if ((Test-Path -LiteralPath $logPath) -and ((Get-Item -LiteralPath $logPath).Length -gt 200KB)) {
            Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $logPath -Value ((Get-Date).ToString('s') + ' ' + $Msg) -Encoding UTF8
    } catch {}
}

# ---------------- Config (config.json next to the script) ----------------
function Get-DefaultConfig {
    return [ordered]@{
        displayName = 'Driver'
        tokenFile   = 'tessie.token'
        vin         = ''
        timeZoneId  = 'Central Standard Time'
        efficiency  = 0.90
        rates = [ordered]@{
            fuelAdderPerKwh = 0.0
            overnight = [ordered]@{ rate = 0.10; startHour = 23; endHour = 6 }
            daytime   = [ordered]@{ rate = 0.12; seasonalRate = $null; seasonalMonths = @() }
            peak      = [ordered]@{ enabled = $false; rate = 0.0; startHour = 14; endHour = 19; months = @(6, 7, 8, 9, 10); weekdaysOnly = $true }
        }
        overnightWindow = [ordered]@{ startHour = 23; endHour = 11 }
        placement = [ordered]@{ rightOffset = 381; top = 42 }
        fallbackJson = 'tesla-overnight-cost.json'
        defaultTheme = 'tessie'
        controls = [ordered]@{ enabled = $true; dryRun = $false }
        tires = [ordered]@{ yellowPct = 5; redPct = 10; maxPsiNoRec = 48; minPsiNoRec = 38 }
        climate = [ordered]@{ heatTempF = 82 }
        announce = [ordered]@{ actions = $false; device = ''; dryRun = $false; schedules = [ordered]@{} }
    }
}

function Get-Val { param($v, $d) if ($null -eq $v -or ($v -is [string] -and $v -eq '')) { return $d } return $v }

function Read-Config {
    $c = $null
    try {
        if (Test-Path -LiteralPath $ConfigPath) { $c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    } catch { Write-WidgetLog ('config read failed: ' + $_.Exception.Message) }
    return $c
}

function Save-ConfigVin {
    param([string]$Vin)
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $raw.vin = $Vin
        $raw | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    } catch { Write-WidgetLog ('config VIN save failed: ' + $_.Exception.Message) }
}

$script:Cfg = Read-Config
$d = Get-DefaultConfig
$c = $script:Cfg
if ($null -eq $c) { $c = [pscustomobject]@{} }
$DisplayName = [string](Get-Val $c.displayName $d.displayName)
$CredFile    = [string](Get-Val $c.tokenFile $d.tokenFile)
$CredFile    = [Environment]::ExpandEnvironmentVariables($CredFile)
if (-not [System.IO.Path]::IsPathRooted($CredFile)) { $CredFile = Join-Path $scriptDir $CredFile }
$script:VIN  = [string](Get-Val $c.vin '')
$TZID        = [string](Get-Val $c.timeZoneId $d.timeZoneId)
$EFFICIENCY  = [double](Get-Val $c.efficiency $d.efficiency)
if ($EFFICIENCY -gt 1.5) { $EFFICIENCY = $EFFICIENCY / 100.0 }
$r = $c.rates
$FCA         = [double](Get-Val $r.fuelAdderPerKwh $d.rates.fuelAdderPerKwh)
$R_ON        = [double](Get-Val $r.overnight.rate $d.rates.overnight.rate)
$ON_START    = [int](Get-Val $r.overnight.startHour 23)
$ON_END      = [int](Get-Val $r.overnight.endHour 6)
$R_DAY       = [double](Get-Val $r.daytime.rate $d.rates.daytime.rate)
$R_SEAS      = $null; if ($null -ne $r.daytime.seasonalRate) { $R_SEAS = [double]$r.daytime.seasonalRate }
$SEAS_MONTHS = @(); if ($null -ne $r.daytime.seasonalMonths) { $SEAS_MONTHS = @($r.daytime.seasonalMonths | ForEach-Object { [int]$_ }) }
$PEAK_EN     = $false; if ($null -ne $r.peak -and $null -ne $r.peak.enabled) { $PEAK_EN = [bool]$r.peak.enabled }
$R_PEAK      = [double](Get-Val $r.peak.rate 0)
$PK_S        = [int](Get-Val $r.peak.startHour 14)
$PK_E        = [int](Get-Val $r.peak.endHour 19)
$PK_MONTHS   = @(6, 7, 8, 9, 10); if ($null -ne $r.peak.months) { $PK_MONTHS = @($r.peak.months | ForEach-Object { [int]$_ }) }
$PK_WD       = $true; if ($null -ne $r.peak.weekdaysOnly) { $PK_WD = [bool]$r.peak.weekdaysOnly }
$NW_START    = [int](Get-Val $c.overnightWindow.startHour 23)
$NW_END      = [int](Get-Val $c.overnightWindow.endHour 11)
$PL_RIGHT    = [double](Get-Val $c.placement.rightOffset 381)
$PL_TOP      = [double](Get-Val $c.placement.top 42)
$DEFAULT_TESSIE = ([string](Get-Val $c.defaultTheme 'tessie')) -ne 'tessdesk'
$CTL_ENABLED = $true; if ($null -ne $c.controls -and $null -ne $c.controls.enabled) { $CTL_ENABLED = [bool]$c.controls.enabled }
$CTL_DRYRUN  = $false; if ($null -ne $c.controls -and $null -ne $c.controls.dryRun) { $CTL_DRYRUN = [bool]$c.controls.dryRun }
if ($SelfTest) { $CTL_DRYRUN = $true }
# v4.3.5: pause between flashes (config.json flashPauseSec, 1-30 s in 0.5 s steps, default 1) and count (flashCount 1-20, default 5)
$FLASH_COUNT = 5; try { if ($null -ne $c.flashCount) { $FLASH_COUNT = [int]$c.flashCount } } catch {}
$FLASH_COUNT = [math]::Min(20, [math]::Max(1, $FLASH_COUNT))
$FLASH_PAUSE = 1.0; try { if ($null -ne $c.flashPauseSec) { $FLASH_PAUSE = [double]$c.flashPauseSec } } catch {}
$FLASH_PAUSE = [math]::Min(30.0, [math]::Max(1.0, [math]::Round($FLASH_PAUSE * 2) / 2))
# Tire thresholds (config.json "tires"): % away from the car's recommended cold pressure.
$TIRE_YELLOW = 5.0; $TIRE_RED = 10.0; $TIRE_MAX_NOREC = 48.0; $TIRE_MIN_NOREC = 38.0
if ($null -ne $c.tires) {
    if ($null -ne $c.tires.yellowPct) { $TIRE_YELLOW = [double]$c.tires.yellowPct }
    if ($null -ne $c.tires.redPct) { $TIRE_RED = [double]$c.tires.redPct }
    if ($null -ne $c.tires.maxPsiNoRec) { $TIRE_MAX_NOREC = [double]$c.tires.maxPsiNoRec }
    if ($null -ne $c.tires.minPsiNoRec) { $TIRE_MIN_NOREC = [double]$c.tires.minPsiNoRec }
}
# Heat button (v4.2): Tesla has no separate heater command, so HEAT = climate on + this set temperature (config climate.heatTempF).
$HEAT_F = 82.0; if ($null -ne $c.climate -and $null -ne $c.climate.heatTempF) { $HEAT_F = [double]$c.climate.heatTempF }
# Consent / permissions (config.json "consent", saved by TessDesk Setup or the first-run notice).
$script:Consent = $c.consent
# Reminders (config.json "reminders", set up by TessDesk Setup). Sent later by TessDesk-Remind.ps1 via Task Scheduler.
$script:RemCfg = $c.reminders
$REM_DRYRUN = $false; if ($null -ne $c.reminders -and $null -ne $c.reminders.dryRun) { $REM_DRYRUN = [bool]$c.reminders.dryRun }
if ($SelfTest) { $REM_DRYRUN = $true }
$jsonPath    = [string](Get-Val $c.fallbackJson $d.fallbackJson)
if (-not [System.IO.Path]::IsPathRooted($jsonPath)) { $jsonPath = Join-Path $scriptDir $jsonPath }
Remove-Variable d, c, r

$ApiBase           = 'https://api.tessie.com'
$HttpTimeoutSec    = 15
$ResumeWindowMin   = 30
$ChargesRefreshMin = 15
$HistoryDays       = 31

# Window size: 364 wide. v4.2: the window grows to fit (never past the bottom of the work area). The top (hero + money
# rows) and the footer stay fixed; the sections below scroll (slim scrollbar) when they don't fit the screen.
$winW = 364
$winH = 900
$CmdTimeoutSec = 90

# ---------------- Time helpers ----------------
function Get-EpochNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
$script:TZ = $null
try { $script:TZ = [TimeZoneInfo]::FindSystemTimeZoneById($TZID) } catch { $script:TZ = [TimeZoneInfo]::Local }

function ConvertFrom-Epoch {
    param($Seconds)
    $utc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Seconds).UtcDateTime
    return [TimeZoneInfo]::ConvertTimeFromUtc($utc, $script:TZ)
}
function ConvertTo-EpochLocal {
    param([DateTime]$Local)
    $utc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($Local, [DateTimeKind]::Unspecified), $script:TZ)
    return [DateTimeOffset]::new([DateTime]::SpecifyKind($utc, [DateTimeKind]::Utc)).ToUnixTimeSeconds()
}
function Get-LocalNow { return (ConvertFrom-Epoch (Get-EpochNow)) }
function Format-Clock { param([DateTime]$dt) return $dt.ToString('h:mm tt', $Inv) }

function Format-Range {
    param($StartEpoch, $EndEpoch)
    try {
        $a = ConvertFrom-Epoch $StartEpoch; $b = ConvertFrom-Epoch $EndEpoch
        $left = $a.ToString('ddd MMM d h:mm tt', $Inv)
        if ($a.Date -eq $b.Date) { $right = $b.ToString('h:mm tt', $Inv) } else { $right = $b.ToString('ddd h:mm tt', $Inv) }
        return ($left + ' → ' + $right)
    } catch { return 'Last session' }
}

function Format-Duration {
    param($Minutes)
    if ($null -eq $Minutes) { return '—' }
    $n = [int][math]::Round([double]$Minutes)
    if ($n -lt 0) { return '—' }
    if ($n -ge 60) { return ('{0}h {1:00}m' -f [math]::Floor($n / 60), ($n % 60)) }
    return ('{0}m' -f $n)
}

function Format-Money {
    param($v)
    if ($null -eq $v) { return '$—' }
    try { return ('${0:N2}' -f [double]$v) } catch { return '$—' }
}

function Format-Kwh {
    param($v)
    if ($null -eq $v) { return '— kWh' }
    try {
        $n = [double]$v
        if ($n -ge 100) { return ('{0:N0} kWh' -f $n) }
        return ('{0:N1} kWh' -f $n)
    } catch { return '— kWh' }
}

# ---------------- Pricing (all-in = energy + fuel/FCA adder) ----------------
function Test-HourIn {
    param([int]$h, [int]$s, [int]$e)
    if ($s -eq $e) { return $false }
    if ($s -lt $e) { return ($h -ge $s -and $h -lt $e) }
    return ($h -ge $s -or $h -lt $e)
}

function Get-EnergyRate {
    param([DateTime]$dt)
    $h = $dt.Hour
    if (Test-HourIn $h $ON_START $ON_END) { return $R_ON }
    $dow = [int]$dt.DayOfWeek
    if ($PEAK_EN -and ($PK_MONTHS -contains $dt.Month) -and ((-not $PK_WD) -or ($dow -ge 1 -and $dow -le 5)) -and (Test-HourIn $h $PK_S $PK_E)) { return $R_PEAK }
    if ($null -ne $R_SEAS -and ($SEAS_MONTHS -contains $dt.Month)) { return $R_SEAS }
    return $R_DAY
}
function Get-AllInRate { param([DateTime]$dt) return ((Get-EnergyRate $dt) + $FCA) }

# Wall kWh spread evenly over the session minutes, each minute at its all-in rate (same as poller.py),
# priced in hour-sized chunks because rates only change on the hour. Optional window clips minutes.
# Returns @(cost, fractionOfMinutesCounted).
function Get-SpreadCost {
    param([int64]$Start, [int64]$End, [double]$Wall, $WinStart = $null, $WinEnd = $null)
    $mins = [int64][math]::Max(1, [math]::Floor(($End - $Start) / 60))
    $per = $Wall / $mins
    $t0 = ConvertFrom-Epoch $Start
    $cost = 0.0; $used = 0
    $i = 0
    while ($i -lt $mins) {
        $t = $t0.AddMinutes($i)
        $n = [int64][math]::Min((60 - $t.Minute), ($mins - $i))
        if ($n -lt 1) { $n = 1 }
        $take = $n
        if ($null -ne $WinStart) {
            $segS = $Start + $i * 60; $segE = $segS + $n * 60
            $a = [math]::Max($segS, [int64]$WinStart); $b = [math]::Min($segE, [int64]$WinEnd)
            $take = [math]::Max(0, [math]::Floor(($b - $a) / 60))
        }
        if ($take -gt 0) { $cost += $per * $take * (Get-AllInRate $t); $used += $take }
        $i += $n
    }
    return @($cost, ($used / [double]$mins))
}

# Overnight window (default 11 PM -> 11 AM). Inside it the row reads "Tonight", outside "Last night".
function Get-NightWindow {
    param([int64]$NowEpoch)
    $now = ConvertFrom-Epoch $NowEpoch
    $h = $now.Hour
    $inWin = Test-HourIn $h $NW_START $NW_END
    $startDay = $now.Date
    if ($h -lt $NW_START) { $startDay = $now.Date.AddDays(-1) }
    $startLocal = $startDay.AddHours($NW_START)
    $lenH = $NW_END - $NW_START; if ($lenH -le 0) { $lenH += 24 }
    $endLocal = $startLocal.AddHours($lenH)
    return [pscustomobject]@{
        start = (ConvertTo-EpochLocal $startLocal); end = (ConvertTo-EpochLocal $endLocal)
        inWindow = $inWin; startLocal = $startLocal; endLocal = $endLocal
    }
}

# ---------------- Tessie API ----------------
# The credential is read only from the local file named in config.json (tokenFile).
function Get-TessieToken {
    # Preferred: tessie.token.dpapi (written by TessDesk Setup, encrypted with Windows DPAPI for this user).
    $dp = $CredFile + '.dpapi'
    if (Test-Path -LiteralPath $dp) {
        $ss = (Get-Content -LiteralPath $dp -Raw).Trim() | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { $t = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($t) { return $t.Trim() }
    }
    foreach ($p in @($CredFile, ($CredFile + '.txt'))) {
        if (Test-Path -LiteralPath $p) {
            $raw = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
            if ($null -eq $raw) { continue }
            $line = @($raw -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1
            if (-not $line) { continue }
            $t = $line.Trim().Trim([char]0xFEFF).Trim()
            $t = $t -replace '^(?i)bearer\s+', ''
            if ($t) { return $t }
        }
    }
    return $null
}

function Invoke-Tessie {
    param([string]$Path, [string]$Token)
    $headers = @{ Authorization = ('Bearer ' + $Token); Accept = 'application/json' }
    return (Invoke-RestMethod -Uri ($ApiBase + $Path) -Headers $headers -Method Get -TimeoutSec $HttpTimeoutSec -UseBasicParsing)
}

function Get-HttpErrorNote {
    param($Err)
    try {
        $resp = $Err.Exception.Response
        if ($null -ne $resp) {
            $code = [int]$resp.StatusCode
            if ($code -eq 401 -or $code -eq 403) { return "Live error: token rejected ($code)" }
            return "Live error ($code), retrying"
        }
    } catch {}
    return 'Live error, retrying'
}

# Vehicle commands (TESLA CONTROLS). POST /{vin}/command/<name>?wait_for_completion=true (developer.tessie.com).
# Commands may wake the car; that's expected because the user pressed the button. Polling never wakes it.
function Get-CommandUrl {
    param([string]$Cmd, [hashtable]$Query = @{})
    $q = 'wait_for_completion=' + $(if ($Query.ContainsKey('wait_for_completion')) { [string]$Query['wait_for_completion'] } else { 'true' })
    foreach ($k in @($Query.Keys)) { if ($k -eq 'wait_for_completion') { continue }; $q += '&' + $k + '=' + [uri]::EscapeDataString([string]$Query[$k]) }
    return ($ApiBase + '/' + $script:VIN + '/command/' + $Cmd + '?' + $q)
}

$script:CmdSendBlock = {
    param($u, $t, $to)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    try {
        $r = Invoke-RestMethod -Uri $u -Method Post -Headers @{ Authorization = ('Bearer ' + $t); Accept = 'application/json' } -TimeoutSec $to -UseBasicParsing
        $ok = $false; if ($null -ne $r -and $null -ne $r.result) { $ok = [bool]$r.result }
        $why = ''; if ($null -ne $r -and $r.reason) { $why = [string]$r.reason } elseif ($null -ne $r -and $r.error) { $why = [string]$r.error }
        return [pscustomobject]@{ ok = $ok; code = 200; error = $why }
    } catch {
        $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        $msg = $_.Exception.Message
        try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $j = $_.ErrorDetails.Message | ConvertFrom-Json; if ($j.error) { $msg = [string]$j.error } elseif ($j.reason) { $msg = [string]$j.reason } } } catch {}
        return [pscustomobject]@{ ok = $false; code = $code; error = $msg }
    }
}
$script:CmdDryRunBlock = {
    param($u)
    Start-Sleep -Milliseconds 1600
    return [pscustomobject]@{ ok = $true; code = 0; error = ''; dryRun = $true }
}

# VIN from config.json; if blank, take the first active vehicle from GET /vehicles and save it.
function Resolve-Vin {
    param([string]$Token)
    if ($script:VIN) { return $script:VIN }
    $vl = Invoke-Tessie '/vehicles?only_active=true' $Token
    $first = @($vl.results | Where-Object { $_.vin }) | Select-Object -First 1
    if ($null -eq $first) { throw 'No vehicles found on this Tessie account' }
    $script:VIN = [string]$first.vin
    Save-ConfigVin $script:VIN
    Write-WidgetLog 'VIN auto-detected from /vehicles and saved to config.json'
    return $script:VIN
}

# ---------------- State (state.json next to the script) ----------------
$StateFields = @('wasCharging', 'session', 'lastLive', 'lastCharges', 'lastChargesFetchEpoch', 'recentSessions',
                 'lastCharge', 'tessieLook', 'lastTires', 'lastCar', 'drives', 'drivesFetchEpoch')

function New-State {
    param($Base, [hashtable]$Set = @{})
    $h = [ordered]@{}
    foreach ($f in $StateFields) {
        $v = $null
        if ($null -ne $Base) { $v = $Base.$f }
        if ($Set.ContainsKey($f)) { $v = $Set[$f] }
        $h[$f] = $v
    }
    $h['wasCharging'] = [bool]$h['wasCharging']
    if ($null -eq $h['tessieLook']) { $h['tessieLook'] = [bool]$DEFAULT_TESSIE } else { $h['tessieLook'] = [bool]$h['tessieLook'] }
    if ($null -eq $h['lastChargesFetchEpoch']) { $h['lastChargesFetchEpoch'] = [int64]0 } else { $h['lastChargesFetchEpoch'] = [int64]$h['lastChargesFetchEpoch'] }
    $h['recentSessions'] = @($h['recentSessions'] | Where-Object { $null -ne $_ })
    return [pscustomobject]$h
}

# v4.3.6: real overlap (more than 90 s), so a part that ended just before the next one began is not counted as the same charge (phone: dupOfLive)
function Test-RealOverlap {
    param($a, $b)
    $ae = $(if ($null -ne $a.endEpoch) { [int64]$a.endEpoch } else { [int64]$a.lastEpoch }); $be = $(if ($null -ne $b.endEpoch) { [int64]$b.endEpoch } else { [int64]$b.lastEpoch })
    return (([int64]$a.startEpoch -lt ($be - 90)) -and ([int64]$b.startEpoch -lt ($ae - 90)))
}
function Test-Overlap {
    param($a, $b)
    return (([int64]$a.startEpoch -lt ([int64]$b.endEpoch + 300)) -and ([int64]$b.startEpoch -lt ([int64]$a.endEpoch + 300)))
}

# Add/replace a completed session. v4.3.6: both sources are stored (a Tessie record and the widget's own record of the
# same charge); which one counts is decided when reading (Select-CountedSessions: Tessie wins), same rule as the phone.
function Merge-Sessions {
    param($List, $Item)
    $out = @()
    $keepItem = $true
    foreach ($x in @($List)) {
        if ($null -eq $x) { continue }
        if ([string]$x.source -eq [string]$Item.source -and [int64]$x.startEpoch -eq [int64]$Item.startEpoch) { continue }
        if (Test-Overlap $x $Item) {
            if ([string]$Item.source -eq 'live' -and [string]$x.source -ne 'live') { if (-not $Item.home -and $x.home) { $Item | Add-Member -NotePropertyName home -NotePropertyValue $x.home -Force } }
            elseif ([string]$x.source -eq 'live' -and [string]$Item.source -ne 'live') { if (-not $x.home -and $Item.home) { $x | Add-Member -NotePropertyName home -NotePropertyValue $Item.home -Force } }
            elseif ([string]$x.source -eq 'live' -and [string]$Item.source -eq 'live') { continue }
        }
        $out += $x
    }
    if ($keepItem) { $out += $Item }
    $cut = (Get-EpochNow) - $HistoryDays * 86400
    return @($out | Where-Object { [int64]$_.endEpoch -gt $cut } | Sort-Object { [int64]$_.endEpoch })
}

function Get-LatestCompleted {
    param($List)
    $l = @($List | Where-Object { $null -ne $_ } | Sort-Object { [int64]$_.endEpoch })
    if ($l.Count -eq 0) { return $null }
    return $l[$l.Count - 1]
}

function Load-WidgetState {
    try {
        if (Test-Path -LiteralPath $statePath) {
            $s = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $s) {
                $recent = @()
                if ($null -ne $s.recentSessions) { $recent = @($s.recentSessions | Where-Object { $null -ne $_ }) }
                if ($recent.Count -eq 0 -and $null -ne $s.lastCharges) { $recent = @($s.lastCharges) }
                if ($null -ne $s.lastLive) { $recent = Merge-Sessions $recent $s.lastLive }
                return (New-State $s @{ recentSessions = $recent })
            }
        }
    } catch { Write-WidgetLog ('state load failed: ' + $_.Exception.Message) }
    return (New-State $null @{})
}

function Save-WidgetState {
    try {
        $tmp = $statePath + '.tmp'
        $script:State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $statePath -Force
    } catch { Write-WidgetLog ('state save failed: ' + $_.Exception.Message) }
}

# Price all completed Tessie charges from the last $HistoryDays days.
function Get-ChargeSessions {
    param([string]$Token)
    $now = Get-EpochNow
    $from = $now - $HistoryDays * 86400
    $r = Invoke-Tessie ("/$($script:VIN)/charges?from=$from&to=$now&distance_format=mi&format=json") $Token
    $out = @()
    foreach ($c in @($r.results)) {
        if ($null -eq $c -or $null -eq $c.started_at -or $null -eq $c.ended_at) { continue }
        $start = [int64]$c.started_at; $end = [int64]$c.ended_at
        $wall = 0.0; if ($null -ne $c.energy_used) { $wall = [double]$c.energy_used }
        $cost = (Get-SpreadCost $start $end $wall)[0]
        $loc = $null; if ($c.saved_location) { $loc = [string]$c.saved_location } elseif ($c.location) { $loc = [string]$c.location }
        $out += [pscustomobject]@{
            source = 'tessie'; startEpoch = $start; endEpoch = $end
            kwhWall = [math]::Round($wall, 2); kwhAdded = $c.energy_added
            socStartPct = $c.starting_battery; socEndPct = $c.ending_battery
            costUsdAllIn = [math]::Round($cost, 4); home = $loc
            fast = ([bool]$c.is_supercharger -or [bool]$c.is_fast_charger -or ($null -ne $c.max_charger_power -and [double]$c.max_charger_power -gt 25))
            paidUsd = $(if (([bool]$c.is_supercharger -or [bool]$c.is_fast_charger -or ($null -ne $c.max_charger_power -and [double]$c.max_charger_power -gt 25)) -and $null -ne $c.cost -and [double]$c.cost -gt 0) { [double]$c.cost } else { $null })
        }
    }
    return @($out | Sort-Object { - [int64]$_.endEpoch })
}

# ---------------- Totals: Tonight / Last night, 7 and 30 days ----------------
function Get-CurrentLive {
    param($St)
    if ([bool]$St.wasCharging -and $null -ne $St.session) { return $St.session }
    return $null
}

# v4.3.6 SESSIONS RULE (same as the phone): completed sessions come from Tessie's /charges list. The widget's own record
# of a finished charge counts only while Tessie has no record overlapping it (Tessie lists a charge a few minutes after it
# ends). The live session in progress always counts, and any Tessie record overlapping it is dropped. Nothing counts twice.
function Select-CountedSessions {
    param($List)
    $all = @(@($List) | Where-Object { $null -ne $_ })
    $tes = @($all | Where-Object { [string]$_.source -ne 'live' })
    $out = @()
    foreach ($s in $all) {
        if ([string]$s.source -eq 'live') {
            $dup = $false; foreach ($t in $tes) { if (Test-RealOverlap $s $t) { $dup = $true; break } }
            if ($dup) { continue }
        }
        $out += $s
    }
    return $out
}
# Completed sessions (Tessie first, see above) minus anything that duplicates the live session in progress.
function Get-CompletedForTotals {
    param($St)
    $cur = Get-CurrentLive $St
    $out = @()
    foreach ($s in @(Select-CountedSessions $St.recentSessions)) {
        if ($null -eq $s) { continue }
        if ($null -ne $cur) {
            if ([string]$s.source -eq 'live' -and [int64]$s.startEpoch -eq [int64]$cur.startEpoch) { continue }
            $span = [pscustomobject]@{ startEpoch = $cur.startEpoch; endEpoch = $cur.lastEpoch }
            if ([string]$s.source -ne 'live' -and (Test-RealOverlap $s $span)) { continue }   # v4.3.6: an earlier back-to-back part stays (carry rule handles a running counter)
        }
        $out += $s
    }
    return $out
}

function Get-WindowPortion {
    param($s, [int64]$Ws, [int64]$We)
    $start = [int64]$s.startEpoch; $end = [int64]$s.endEpoch
    $added = 0.0; if ($null -ne $s.kwhAdded) { $added = [double]$s.kwhAdded }
    $cost = 0.0; if ($null -ne $s.costUsdAllIn) { $cost = [double]$s.costUsdAllIn }
    if ($end -le $Ws -or $start -ge $We) { return @(0.0, 0.0) }
    if ($start -ge $Ws -and $end -le $We) {
        if ([string]$s.source -eq 'live' -and $null -ne $s.winStart -and [int64]$s.winStart -eq $Ws -and $null -ne $s.costWin) {
            return @([double]$s.costWin, [double]$s.kwhWin)
        }
        return @($cost, $added)
    }
    if ([string]$s.source -eq 'live') {
        if ($null -ne $s.winStart -and [int64]$s.winStart -eq $Ws -and $null -ne $s.costWin) { return @([double]$s.costWin, [double]$s.kwhWin) }
        $a = [math]::Max($start, $Ws); $b = [math]::Min($end, $We)
        $frac = ($b - $a) / [double][math]::Max(1, $end - $start)
        return @(($cost * $frac), ($added * $frac))
    }
    $wall = 0.0; if ($null -ne $s.kwhWall) { $wall = [double]$s.kwhWall }
    $p = Get-SpreadCost $start $end $wall $Ws $We
    return @($p[0], ($added * $p[1]))
}

function Get-NightTotal {
    param($St, [int64]$NowEpoch)
    $nw = Get-NightWindow $NowEpoch
    $cost = 0.0; $kwh = 0.0; $n = 0
    foreach ($s in (Get-CompletedForTotals $St)) {
        $p = Get-WindowPortion $s $nw.start $nw.end
        if ($p[0] -gt 0 -or $p[1] -gt 0) { $n++ }
        $cost += $p[0]; $kwh += $p[1]
    }
    $cur = Get-CurrentLive $St
    if ($null -ne $cur -and $null -ne $cur.winStart -and [int64]$cur.winStart -eq $nw.start) {
        $cost += [double]$cur.costWin; $kwh += [double]$cur.kwhWin; $n++
    }
    $label = 'Last night'; if ($nw.inWindow) { $label = 'Tonight' }
    $cap = $nw.startLocal.ToString('ddd h tt', $Inv) + ' → ' + $nw.endLocal.ToString('h tt', $Inv)
    if ($nw.inWindow) { $cap = 'since ' + $nw.startLocal.ToString('h tt', $Inv) + ' · live' }
    return [pscustomobject]@{ label = $label; caption = $cap; costUsdAllIn = [math]::Round($cost, 4); kwhAdded = [math]::Round($kwh, 2)
                              sessions = $n; inWindow = $nw.inWindow; windowStart = $nw.startLocal.ToString('s'); windowEnd = $nw.endLocal.ToString('s') }
}

function Get-PeriodTotal {
    param($St, [int64]$NowEpoch, [int]$Days)
    $cut = $NowEpoch - $Days * 86400
    $cost = 0.0; $kwh = 0.0; $n = 0
    foreach ($s in (Get-CompletedForTotals $St)) {
        if ([int64]$s.startEpoch -lt $cut) { continue }
        # v4.3.10 shared rule (same as the phone): whole charges that started in the period; a Supercharger counts what Tessie says was paid
        if ($null -ne $s.paidUsd -and [double]$s.paidUsd -gt 0) { $cost += [double]$s.paidUsd } elseif ($null -ne $s.costUsdAllIn) { $cost += [double]$s.costUsdAllIn }
        if ($null -ne $s.kwhAdded) { $kwh += [double]$s.kwhAdded }
        $n++
    }
    $cur = Get-CurrentLive $St
    if ($null -ne $cur -and [int64]$cur.startEpoch -ge $cut) { $cost += [double]$cur.costUsdAllIn; $kwh += [double]$cur.kwhAdded; $n++ }
    return [pscustomobject]@{ costUsdAllIn = [math]::Round($cost, 2); kwhAdded = [math]::Round($kwh, 1); sessions = $n }
}

# ---------------- v4.3.2: LAST CHARGE = the whole 11 PM -> 11 AM home window ----------------
# Every home session that falls in one overnight window (default 11 PM -> 11 AM, config nightWindow) is ONE charge:
# unplugging for 30 minutes and plugging back in still adds to the same charge. Each part keeps its own pricing
# (kWh spread per minute at that minute's all-in rate, so anything after 6 AM is priced at the day rate).
function Get-ChargeWindowStart {
    param([int64]$Epoch)
    $t = ConvertFrom-Epoch $Epoch
    if (-not (Test-HourIn $t.Hour $NW_START $NW_END)) { return $null }
    $d = $t.Date; if ($NW_START -gt $NW_END -and $t.Hour -lt $NW_START) { $d = $d.AddDays(-1) }
    return (ConvertTo-EpochLocal $d.AddHours($NW_START))
}
function Get-SessionWindow {
    param($s)
    $se = [int64]$s.startEpoch; $ee = $(if ($null -ne $s.endEpoch) { [int64]$s.endEpoch } elseif ($null -ne $s.lastEpoch) { [int64]$s.lastEpoch } else { $se })
    $w = Get-ChargeWindowStart $se
    if ($null -eq $w) { $w = Get-ChargeWindowStart $ee }
    return $w
}
function Get-HomeLabel {
    param($List)
    $g = @(@($List) | Where-Object { $null -ne $_ -and -not [bool]$_.fast -and $_.home } | Group-Object { [string]$_.home } | Sort-Object Count -Descending)
    $cfgHome = $null; try { if ($null -ne $script:Cfg -and $script:Cfg.homeLocation) { $cfgHome = [string]$script:Cfg.homeLocation } } catch {}
    if ($cfgHome) { return $cfgHome }
    if ($g.Count -gt 0) { return [string]$g[0].Name }
    return $null
}
function Test-HomeSession {
    param($s, [string]$HomeLabel)
    if ($null -eq $s -or [bool]$s.fast) { return $false }
    $h = [string]$s.home
    if (-not $h -or -not $HomeLabel) { return $true }      # unlabeled (live-tracked) sessions count as home
    return ($h -eq $HomeLabel)
}
function Get-After6 {
    # kWh added / cost of one part that fell after the off-peak end (6 AM) inside its window
    param($s, [int64]$Ws)
    $offEnd = (ConvertFrom-Epoch $Ws).Date.AddDays(1).AddHours($ON_END)
    $a = ConvertTo-EpochLocal $offEnd; $b = $Ws + (($NW_END - $NW_START + 24) % 24) * 3600
    $se = [int64]$s.startEpoch; $ee = $(if ($null -ne $s.endEpoch) { [int64]$s.endEpoch } else { [int64]$s.lastEpoch })
    if ($ee -le $a) { return @(0.0, 0.0) }
    $added = [double](Get-Val $s.kwhAdded 0.0); $wall = [double](Get-Val $s.kwhWall ($added / $EFFICIENCY))
    $p = Get-SpreadCost $se $ee $wall $a $b
    return @([math]::Round($added * $p[1], 2), [math]::Round($p[0], 4))
}
function Get-HomeWindowCharge {
    # Returns the most recent overnight home window as one charge (completed parts + the live part in progress), or $null.
    param($St)
    if ($null -eq $St) { return $null }
    $list = @(Get-CompletedForTotals $St)
    $cur = Get-CurrentLive $St
    $homeLbl = Get-HomeLabel $list
    $items = @()
    foreach ($s in $list) { if (-not (Test-HomeSession $s $homeLbl)) { continue }; $w = Get-SessionWindow $s; if ($null -ne $w) { $items += [pscustomobject]@{ w = $w; s = $s; live = $false } } }
    if ($null -ne $cur) {
        $fastNow = ($null -ne $St.lastCar -and [bool]$St.lastCar.fastCharger)
        $w = Get-SessionWindow $cur
        if ($null -ne $w -and -not $fastNow) { $items += [pscustomobject]@{ w = $w; s = $cur; live = $true } }
    }
    if ($items.Count -eq 0) { return $null }
    $wl = [int64](@($items | ForEach-Object { [int64]$_.w } | Sort-Object)[-1])
    $parts = @($items | Where-Object { [int64]$_.w -eq $wl } | Sort-Object { [int64]$_.s.startEpoch })
    $cost = 0.0; $kwh = 0.0; $wall = 0.0; $a6k = 0.0; $a6c = 0.0; $plist = @(); $prevS = $null; $script:CarryFix = @()
    foreach ($p in $parts) {
        $s = $p.s
        $c = [double](Get-Val $s.costUsdAllIn 0.0); $k = [double](Get-Val $s.kwhAdded 0.0)
        $carry = Get-PartCarryKwh $prevS $s; $prevS = $s
        if ($carry -gt 0 -and $k -gt 0) { $cf = [math]::Min(1.0, $carry / $k); $script:CarryFix += [ordered]@{ start = [int64]$s.startEpoch; kwh = [math]::Round($carry, 2); cost = [math]::Round($c * $cf, 4) }; $c = $c * (1 - $cf); $k = $k - $carry }
        $wk = $(if ($null -ne $s.kwhWall -and [double]$s.kwhWall -gt 0) { [double]$s.kwhWall } else { $k / $EFFICIENCY })
        $cost += $c; $kwh += $k; $wall += $wk
        $af = Get-After6 $s $wl; $a6k += $af[0]; $a6c += $af[1]
        $ee = $(if ($null -ne $s.endEpoch) { [int64]$s.endEpoch } else { [int64]$s.lastEpoch })
        $plist += [ordered]@{ startEpoch = [int64]$s.startEpoch; endEpoch = $ee; live = [bool]$p.live; source = $(if ($p.live) { 'live (in progress)' } else { [string]$s.source }); start = (ConvertFrom-Epoch ([int64]$s.startEpoch)).ToString('ddd h:mm tt', $Inv); end = (ConvertFrom-Epoch $ee).ToString('ddd h:mm tt', $Inv)
            kwhAdded = [math]::Round($k, 2); kwhWall = [math]::Round($wk, 2); costUsdAllIn = [math]::Round($c, 4); kwhAfter6 = $af[0]; costAfter6 = $af[1]; home = $s.home }
    }
    $first = $parts[0].s; $last = $parts[-1].s
    $endE = $(if ($null -ne $last.endEpoch) { [int64]$last.endEpoch } else { [int64]$last.lastEpoch })
    $wsL = ConvertFrom-Epoch $wl
    return [pscustomobject]@{
        source = 'window'; startEpoch = [int64]$first.startEpoch; endEpoch = $endE; windowStart = $wl
        windowLabel = ($wsL.ToString('ddd h tt', $Inv) + ' → ' + $wsL.AddHours((($NW_END - $NW_START + 24) % 24)).ToString('ddd h tt', $Inv))
        kwhAdded = [math]::Round($kwh, 2); kwhWall = [math]::Round($wall, 2); costUsdAllIn = [math]::Round($cost, 4)
        socStartPct = $first.socStartPct; socEndPct = $(if ($null -ne $last.socEndPct) { $last.socEndPct } else { $last.socPct })
        sessions = $parts.Count; live = [bool]$parts[-1].live; homeLabel = $homeLbl
        kwhAfter6 = [math]::Round($a6k, 2); costAfter6 = [math]::Round($a6c, 4); parts = $plist
    }
}
# v4.3.5: one line per session of the current / last overnight window: '1) 11:00–11:30 PM · 3.1 kWh · $0.21'
function Format-TimeRange {
    param([int64]$FromEpoch, [int64]$ToEpoch)
    $tA = ConvertFrom-Epoch $FromEpoch; $tB = ConvertFrom-Epoch $ToEpoch
    if ($tA.ToString('tt', $Inv) -eq $tB.ToString('tt', $Inv)) { return ($tA.ToString('h:mm', $Inv) + [char]0x2013 + $tB.ToString('h:mm tt', $Inv)) }
    return ($tA.ToString('h:mm tt', $Inv) + [char]0x2013 + $tB.ToString('h:mm tt', $Inv))
}
function Get-WindowSessions {
    param($St)
    $w = $null; try { $w = Get-HomeWindowCharge $St } catch { Write-WidgetLog ('sessions: ' + $_.Exception.Message) }
    if ($null -eq $w -or @($w.parts).Count -eq 0) { return $null }
    $lines = @(); $i = 0; $sum = 0.0; $sumK = 0.0
    foreach ($p in @($w.parts)) {
        $i++; $sum += [double]$p.costUsdAllIn; $sumK += [double]$p.kwhAdded
        $lines += ('{0}) {1} · {2} kWh · {3}{4}' -f $i, (Format-TimeRange ([int64]$p.startEpoch) ([int64]$p.endEpoch)), ([double]$p.kwhAdded).ToString('0.0', $Inv), (Format-Money $p.costUsdAllIn), $(if ($p.live) { ' · live' } else { '' }))
    }
    $wsL = ConvertFrom-Epoch ([int64]$w.windowStart)
    return [pscustomobject]@{ header = ('Sessions · ' + $wsL.ToString('ddd h tt', $Inv) + ' ' + [char]0x2192 + ' ' + $wsL.AddHours((($NW_END - $NW_START + 24) % 24)).ToString('ddd h tt', $Inv))
        lines = $lines; count = $i; sumCostUsd = [math]::Round($sum, 4); sumKwh = [math]::Round($sumK, 2); windowCostUsd = [double]$w.costUsdAllIn }
}

function Render-Sessions {
    param($S)
    $has = ($null -ne $S -and @($S.lines).Count -gt 0)
    Set-Visible $ui.SessBox $has
    if (-not $has) { return }
    $ui.SessHdr.Text = [string]$S.header; $ui.SessHdr.Foreground = T 'Caption'
    $ui.SessList.Children.Clear()
    foreach ($l in @($S.lines)) {
        $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = [string]$l; $tb.FontSize = 10; $tb.Foreground = T 'TextSoft'; $tb.TextTrimming = 'CharacterEllipsis'
        [void]$ui.SessList.Children.Add($tb)
    }
}

function Get-LastChargeShown {
    # Most recent of: the overnight home window (as one charge) or a later single session (e.g. daytime / Supercharger).
    param($St)
    $win = Get-HomeWindowCharge $St
    $one = Get-LatestCompleted (Get-CompletedForTotals $St)
    if ($null -eq $win) { return $one }
    if ($null -ne $one -and [int64]$one.startEpoch -gt [int64]$win.endEpoch) { return $one }
    return $win
}

# ---------------- Live poll (one Tessie state call per minute) ----------------
$script:ChargesFetchedOnce = $false   # full 31-day /charges fetch on every start
function Update-ChargesCache {
    param($Token, [int64]$NowEpoch, [bool]$Force, [ref]$Recent, [ref]$Lc, [ref]$Lcf)
    $due = $Force -or (-not $script:ChargesFetchedOnce) -or ($null -eq $Lc.Value) -or (@($Recent.Value).Count -eq 0) -or (($NowEpoch - [int64]$Lcf.Value) -ge ($ChargesRefreshMin * 60))
    if (-not $due) { return }
    try {
        $list = @(Get-ChargeSessions $Token)
        if ($list.Count -gt 0) {
            $Lc.Value = $list[0]
            $r = @($Recent.Value)
            foreach ($x in $list) { $r = Merge-Sessions $r $x }
            $Recent.Value = $r
        }
        $Lcf.Value = $NowEpoch
        $script:ChargesFetchedOnce = $true
    } catch {
        Write-WidgetLog ('charges fetch failed: ' + $_.Exception.Message)
        $Lcf.Value = $NowEpoch - (($ChargesRefreshMin - 5) * 60)   # retry in ~5 min
    }
}

function ConvertTo-Psi { param($bar) if ($null -eq $bar -or [string]$bar -eq '') { return $null } return [math]::Round([double]$bar * 14.5038, 1) }

# Tire status (v4.1): GREEN = good. YELLOW = a little out: the car's soft TPMS warning, or yellowPct..redPct (5-10%)
# away from the car's recommended cold pressure (tpms_rcp_front_value / tpms_rcp_rear_value). RED = really out: the car's
# hard TPMS warning, or more than redPct (10%) away. Red tires flash. Without a recommendation: over maxPsiNoRec (48) or
# under minPsiNoRec (38) is red, within 2 PSI of those is yellow. Returns level = green|yellow|red|none and dir = low|high|''.
function Get-TireStatus {
    param($Psi, $Soft, $Hard, $RecPsi)
    if ($null -eq $Psi) { return [pscustomobject]@{ level = 'none'; dir = ''; devPct = $null } }
    $p = [double]$Psi; $level = 'green'; $dir = ''; $dev = $null
    if ($null -ne $RecPsi -and [double]$RecPsi -gt 0) {
        $dev = ($p - [double]$RecPsi) / [double]$RecPsi * 100.0
        if ([math]::Abs($dev) -gt $TIRE_RED) { $level = 'red' } elseif ([math]::Abs($dev) -gt $TIRE_YELLOW) { $level = 'yellow' }
        if ($level -ne 'green') { $dir = $(if ($dev -lt 0) { 'low' } else { 'high' }) }
    } else {
        if ($p -gt $TIRE_MAX_NOREC) { $level = 'red'; $dir = 'high' } elseif ($p -lt $TIRE_MIN_NOREC) { $level = 'red'; $dir = 'low' }
        elseif ($p -gt $TIRE_MAX_NOREC - 2) { $level = 'yellow'; $dir = 'high' } elseif ($p -lt $TIRE_MIN_NOREC + 2) { $level = 'yellow'; $dir = 'low' }
    }
    if ($null -ne $Hard -and [bool]$Hard) { $level = 'red'; if (-not $dir) { $dir = 'low' } }
    elseif ($null -ne $Soft -and [bool]$Soft) { if ($level -eq 'green') { $level = 'yellow' }; if (-not $dir) { $dir = 'low' } }
    return [pscustomobject]@{ level = $level; dir = $dir; devPct = $(if ($null -ne $dev) { [math]::Round($dev, 1) } else { $null }) }
}

function Get-TireData {
    param($vs, [int64]$NowEpoch)
    if ($null -eq $vs) { return $null }
    $o = [ordered]@{}
    $seen = @()
    $o['recFront'] = ConvertTo-Psi $vs.tpms_rcp_front_value
    $o['recRear']  = ConvertTo-Psi $vs.tpms_rcp_rear_value
    foreach ($k in 'fl', 'fr', 'rl', 'rr') {
        $o[$k] = ConvertTo-Psi $vs.('tpms_pressure_' + $k)
        $o['soft_' + $k] = $vs.('tpms_soft_warning_' + $k)
        $o['hard_' + $k] = $vs.('tpms_hard_warning_' + $k)
        $t = $vs.('tpms_last_seen_pressure_time_' + $k)
        if ($null -ne $t -and [int64]$t -gt 0) { $seen += [int64]$t }
    }
    $o['asOfEpoch'] = $null
    if ($seen.Count -gt 0) { $o['asOfEpoch'] = ($seen | Measure-Object -Maximum).Maximum }
    $o['fetchedEpoch'] = $NowEpoch
    return [pscustomobject]$o
}

# Range that matches the car's own display: gui_settings.gui_range_display 'Rated' -> battery_range,
# 'Ideal' -> ideal_battery_range. (est_battery_range is Tesla's driving-based estimate, shown only if nothing else exists.)
function Get-CarInfo {
    param($v, [int64]$NowEpoch)
    $cs = $v.charge_state; $vs = $v.vehicle_state; $cl = $v.climate_state; $gs = $v.gui_settings
    $kind = 'rated'; $range = $cs.battery_range
    if ($null -ne $gs -and [string]$gs.gui_range_display -eq 'Ideal' -and $null -ne $cs.ideal_battery_range -and [double]$cs.ideal_battery_range -gt 0) { $kind = 'ideal'; $range = $cs.ideal_battery_range }
    if ($null -eq $range -or [double]$range -le 0) { if ($null -ne $cs.est_battery_range) { $kind = 'estimated'; $range = $cs.est_battery_range } }
    $winOpen = $null
    if ($null -ne $vs) {
        $wins = @($vs.fd_window, $vs.fp_window, $vs.rd_window, $vs.rp_window) | Where-Object { $null -ne $_ }
        if (@($wins).Count -gt 0) { $winOpen = (@($wins | Where-Object { [int]$_ -ne 0 }).Count -gt 0) }
    }
    $units = 'F'; if ($null -ne $gs -and [string]$gs.gui_temperature_units -eq 'C') { $units = 'C' }
    return [pscustomobject]@{
        socPct = $cs.battery_level; limitPct = $cs.charge_limit_soc; chargingState = [string]$cs.charging_state
        rangeMi = $range; rangeKind = $kind; estRangeMi = $cs.est_battery_range
        chargerKw = $cs.charger_power; volts = $cs.charger_voltage; amps = $cs.charger_actual_current; phases = $cs.charger_phases
        fastCharger = [bool]$cs.fast_charger_present; minutesToFull = $cs.minutes_to_full_charge
        limitMin = $(if ($null -ne $cs.charge_limit_soc_min) { [int]$cs.charge_limit_soc_min } else { 50 }); limitMax = $(if ($null -ne $cs.charge_limit_soc_max) { [int]$cs.charge_limit_soc_max } else { 100 })
        name = [string]$v.display_name; carState = [string]$v.state; atEpoch = $NowEpoch
        locked = $(if ($null -ne $vs) { $vs.locked } else { $null }); windowsOpen = $winOpen
        climateOn = $(if ($null -ne $cl) { $cl.is_climate_on } else { $null })
        tempC = $(if ($null -ne $cl) { $cl.driver_temp_setting } else { $null })
        insideC = $(if ($null -ne $cl) { $cl.inside_temp } else { $null })
        outsideC = $(if ($null -ne $cl) { $cl.outside_temp } else { $null })
        lat = $(if ($null -ne $v.drive_state) { $v.drive_state.latitude } else { $null }); lon = $(if ($null -ne $v.drive_state) { $v.drive_state.longitude } else { $null })
        fastType = [string]$cs.fast_charger_type
        minC = $(if ($null -ne $cl -and $null -ne $cl.min_avail_temp) { [double]$cl.min_avail_temp } else { 15.0 })
        maxC = $(if ($null -ne $cl -and $null -ne $cl.max_avail_temp) { [double]$cl.max_avail_temp } else { 28.0 })
        tempUnits = $units
        ampsReq = $cs.charge_current_request; ampsMax = $cs.charge_current_request_max
        seatFL = $cl.seat_heater_left; seatFR = $cl.seat_heater_right; seatRL = $cl.seat_heater_rear_left; seatRC = $cl.seat_heater_rear_center; seatRR = $cl.seat_heater_rear_right
        rearSeatHeaters = $(if ($null -ne $v.vehicle_config) { $v.vehicle_config.rear_seat_heaters } else { $null })
        wheelOn = $(if ($null -ne $cl -and $null -ne $cl.steering_wheel_heater) { [bool]$cl.steering_wheel_heater -or ($null -ne $cl.steering_wheel_heat_level -and [int]$cl.steering_wheel_heat_level -gt 0) } else { $null })
        defrostOn = $(if ($null -ne $cl -and ($null -ne $cl.defrost_mode -or $null -ne $cl.is_front_defroster_on)) { ([int]$cl.defrost_mode -gt 0) -or [bool]$cl.is_front_defroster_on } else { $null })
        cop = $(if ($null -ne $cl) { [string]$cl.cabin_overheat_protection } else { $null }); copFanOnly = $(if ($null -ne $cl) { [bool]$cl.supports_fan_only_cabin_overheat_protection } else { $false })
        copAllowed = $(if ($null -ne $cl) { $cl.allow_cabin_overheat_protection } else { $null })
        windows = $(if ($null -ne $vs) { [ordered]@{ fd = $vs.fd_window; fp = $vs.fp_window; rd = $vs.rd_window; rp = $vs.rp_window } } else { $null })
        trunkOpen = $(if ($null -ne $vs -and $null -ne $vs.rt) { [int]$vs.rt -ne 0 } else { $null })
        sentry = $(if ($null -ne $vs -and $null -ne $vs.sentry_mode) { [bool]$vs.sentry_mode } else { $null })
        sentryAvailable = $(if ($null -ne $vs -and $null -ne $vs.sentry_mode_available) { [bool]$vs.sentry_mode_available } else { $null })
    }
}

# ---------------- v4.3.3: paused sessions never count the same kWh twice ----------------
# The car's charge_energy_added counter keeps running across a pause/resume on the same plug-in and resets on a
# new plug-in. So: resuming with a counter that did NOT drop is the SAME session (only the new kWh are added);
# a counter that dropped is a new session. (v4.3.2 split it into a new session after a 30-min pause even when the
# counter kept running, and that new session was priced from the whole counter = the paused part counted twice.)
function Test-NewLiveSession {
    param($Sess, [double]$Added, [double]$GapMin)
    if ($null -eq $Sess) { return $true }
    if ($Added -lt ([double]$Sess.kwhAdded - 0.05)) { return $true }   # counter reset -> new plug-in
    if ($GapMin -gt 720) { return $true }
    return $false
}
# kWh of an earlier part that a later part's counter already includes (0 when the counter reset).
# Only for a later part that was first seen mid-charge (kwhAtStart > 0.3) within 12 h of the earlier part's end.
# Within 60 min: the counter it showed is compared with "earlier part + what it charged since" vs "only what it charged since".
# Longer: the counter must be older than the gap (at the charging power it began before the earlier part ended).
function Get-PartCarryKwh {
    param($Prev, $Cur)
    if ($null -eq $Prev -or $null -eq $Cur -or $null -eq $Cur.kwhAtStart) { return 0.0 }
    $k0 = [double]$Cur.kwhAtStart; $pk = [double](Get-Val $Prev.kwhAdded 0.0)
    if ($k0 -le 0.3 -or $pk -lt 0.1) { return 0.0 }
    $pe = $(if ($null -ne $Prev.endEpoch) { [int64]$Prev.endEpoch } else { [int64]$Prev.lastEpoch })
    $gapS = [int64]$Cur.startEpoch - $pe
    if ($gapS -lt -300 -or $gapS -gt 43200) { return 0.0 }
    if ($k0 -lt ($pk - 0.15)) { return 0.0 }
    $kw = [double](Get-Val $Cur.kwAtStart 0.0)
    if ($gapS -gt 3600) {
        # longer gap: the counter is older than the gap (it began before the earlier part ended) -> it carries that part
        if ($kw -le 0.3 -or $pk -lt 0.3) { return 0.0 }
        $began = [int64]$Cur.startEpoch - [int64](($k0 / $EFFICIENCY) / $kw * 3600)
        if ($began -lt ($pe - 600)) { return [math]::Min($pk, $k0) }
        return 0.0
    }
    $since = [math]::Max(0.0, $gapS) / 3600.0 * $kw
    if ([math]::Abs($k0 - ($pk + $since)) -lt [math]::Abs($k0 - $since)) { return [math]::Min($pk, $k0) }
    return 0.0
}

function Invoke-LivePoll {
    param([string]$Token)
    $st = $script:State
    [void](Resolve-Vin $Token)
    $v = $null
    if ($null -ne $script:Prefetch -and ((Get-EpochNow) - [int64]$script:Prefetch.at) -lt 20) { $v = $script:Prefetch.v }
    $script:Prefetch = $null
    if ($null -eq $v) { $v = Invoke-Tessie ("/$($script:VIN)/state?use_cache=true") $Token; Set-LiveFromState $v }
    $cs = $v.charge_state
    if ($null -eq $cs) { throw 'Tessie response had no charge_state' }

    $nowE = Get-EpochNow
    $now  = ConvertFrom-Epoch $nowE
    $rate = Get-AllInRate $now
    $nw   = Get-NightWindow $nowE
    $charging = ([string]$cs.charging_state -eq 'Charging')
    $added = 0.0
    if ($null -ne $cs.charge_energy_added) { $added = [double]$cs.charge_energy_added }

    $tires = Get-TireData $v.vehicle_state $nowE
    if ($null -eq $tires) { $tires = $st.lastTires }
    $car = Get-CarInfo $v $nowE

    $sess = $st.session
    $lastLive = $st.lastLive
    $lc = $st.lastCharges
    $lcf = [int64]$st.lastChargesFetchEpoch
    $recent = @($st.recentSessions)

    if ($charging) {
        $new = $false
        $gapMin = 0.0; if ($null -ne $sess) { $gapMin = ($nowE - [int64]$sess.lastEpoch) / 60.0 }
        $new = Test-NewLiveSession $sess $added $gapMin
        if (-not $new -and -not [bool]$st.wasCharging -and $gapMin -gt $ResumeWindowMin) { $script:ResumeJoined = [ordered]@{ at = $nowE; gapMin = [math]::Round($gapMin, 1); counterKwh = $added; sessionKwh = [double]$sess.kwhAdded } }
        if ($new) {
            # Joined mid-session (or fresh start): price what's already added at the current rate.
            $startE = $nowE
            $cost = $added / $EFFICIENCY * $rate
            $joined = ($added -gt 0.3)
            $socStart = $cs.battery_level
            if ($nw.inWindow) { $winS = $nw.start; $costWin = $cost; $kwhWin = $added } else { $winS = $null; $costWin = 0.0; $kwhWin = 0.0 }
            $kAt = $added; $kwAt = $cs.charger_power
        } else {
            $kAt = Get-Val $sess.kwhAtStart $null; $kwAt = Get-Val $sess.kwAtStart $null
            $startE = [int64]$sess.startEpoch
            $delta = [math]::Max(0.0, $added - [double]$sess.kwhAdded)
            $dCost = $delta / $EFFICIENCY * $rate
            $cost = [double]$sess.costUsdAllIn + $dCost
            $joined = [bool]$sess.joinedMid
            $socStart = $sess.socStartPct
            $winS = $sess.winStart; $costWin = [double](Get-Val $sess.costWin 0.0); $kwhWin = [double](Get-Val $sess.kwhWin 0.0)
            if ($nw.inWindow) {
                if ($null -ne $winS -and [int64]$winS -eq $nw.start) { $costWin += $dCost; $kwhWin += $delta }
                else { $winS = $nw.start; $costWin = $dCost; $kwhWin = $delta }
            }
        }
        $sess = [pscustomobject]@{
            startEpoch = $startE; lastEpoch = $nowE; kwhAdded = $added; costUsdAllIn = $cost
            socStartPct = $socStart; socPct = $cs.battery_level; limitPct = $cs.charge_limit_soc
            chargerKw = $cs.charger_power; minutesToFull = $cs.minutes_to_full_charge
            rateNow = $rate; joinedMid = $joined
            winStart = $winS; costWin = $costWin; kwhWin = $kwhWin; kwhAtStart = $kAt; kwAtStart = $kwAt
        }
        Update-ChargesCache $Token $nowE $false ([ref]$recent) ([ref]$lc) ([ref]$lcf)
        $lastCharge = Get-LatestCompleted $recent
        if ($null -eq $lastCharge) { $lastCharge = $st.lastCharge }
        $script:State = New-State $st @{ wasCharging = $true; session = $sess; lastCharges = $lc; lastChargesFetchEpoch = $lcf
                                         recentSessions = $recent; lastCharge = $lastCharge; lastTires = $tires; lastCar = $car }
        Update-DrivesCache $Token $nowE
        Save-WidgetState
        $winNow = $null; try { $winNow = Get-HomeWindowCharge $script:State } catch { Write-WidgetLog ('window charge: ' + $_.Exception.Message) }
        $script:LastWindow = $winNow
        return [pscustomobject]@{ mode = 'live'; session = $sess; car = $car; tires = $tires; last = $lastCharge; win = $winNow }
    }

    # Not charging
    $force = $false
    if ([bool]$st.wasCharging -and $null -ne $sess) {
        $lastLive = [pscustomobject]@{
            source = 'live'; startEpoch = [int64]$sess.startEpoch; endEpoch = [int64]$sess.lastEpoch
            kwhAdded = [math]::Round([double]$sess.kwhAdded, 2)
            kwhWall = [math]::Round([double]$sess.kwhAdded / $EFFICIENCY, 2)
            socStartPct = $sess.socStartPct; socEndPct = $sess.socPct
            costUsdAllIn = [math]::Round([double]$sess.costUsdAllIn, 4)
            joinedMid = [bool]$sess.joinedMid; home = $null; fast = ($null -ne $st.lastCar -and [bool]$st.lastCar.fastCharger)
            winStart = $sess.winStart; costWin = $sess.costWin; kwhWin = $sess.kwhWin
            kwhAtStart = $sess.kwhAtStart; kwAtStart = $sess.kwAtStart
        }
        $recent = Merge-Sessions $recent $lastLive
        $force = $true
    }
    Update-ChargesCache $Token $nowE $force ([ref]$recent) ([ref]$lc) ([ref]$lcf)
    $last = Get-LatestCompleted $recent
    if ($null -eq $last) { $last = $st.lastCharge }
    $script:State = New-State $st @{ wasCharging = $false; session = $sess; lastLive = $lastLive; lastCharges = $lc; lastChargesFetchEpoch = $lcf
                                     recentSessions = $recent; lastCharge = $last; lastTires = $tires; lastCar = $car }
    try { $w = Get-LastChargeShown $script:State; if ($null -ne $w) { $last = $w; $script:State.lastCharge = $w } } catch { Write-WidgetLog ('window charge: ' + $_.Exception.Message) }
    $script:LastWindow = $(if ($null -ne $last -and [string]$last.source -eq 'window') { $last } else { $null })
    Update-DrivesCache $Token $nowE
    Save-WidgetState
    return [pscustomobject]@{ mode = 'idle'; last = $last; car = $car; tires = $tires }
}

# ---------------- v4.3.3: UPDATES (daily check of version.json on the TessDesk site; nothing about you is sent) ----------------
$UpdateUrl = 'https://vanwidick.github.io/tessdesk/version.json'
$UpdAllowed = @('TessDesk.ps1', 'TessDesk-Announce.ps1', 'TessDesk-Remind.ps1', 'TessDesk-Speakers.ps1', 'PRIVACY.md')
$updCheckPath = Join-Path $scriptDir 'update-check.json'
$script:Upd = [ordered]@{ state = 'idle'; latest = $null; checkedEpoch = 0; note = $null; backup = $null; installed = $null; restart = $null }
$script:UpdJob = $null; $script:UpdInfo = $null; $script:UpdUrlOverride = $null
function Get-UpdUrl { if ($script:UpdUrlOverride) { return [string]$script:UpdUrlOverride }; return $UpdateUrl }
$script:UpdFetchBlock = {
    param($Items, $Ua)
    # Items: url (+ optional name). Returns text for the feed, bytes + sha256 for files. Works for https:// and file://.
    $out = @()
    foreach ($it in $Items) {
        $wc = New-Object System.Net.WebClient
        try {
            if ([string]$it.url -like 'http*') { $wc.Headers['User-Agent'] = $Ua; $wc.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore) }
            $b = $wc.DownloadData([string]$it.url)
            $sha = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($b)).Replace('-', '').ToLowerInvariant()
            $out += [pscustomobject]@{ name = $it.name; ok = $true; bytes = $b; sha256 = $sha; err = $null }
        } catch { $out += [pscustomobject]@{ name = $it.name; ok = $false; bytes = $null; sha256 = $null; err = $_.Exception.Message } }
        finally { $wc.Dispose() }
    }
    return , $out
}
function Test-VersionNewer { param([string]$A, [string]$B) try { return ([version]($A.TrimStart('v')) -gt [version]($B.TrimStart('v'))) } catch { return $false } }
function Start-UpdJob {
    param([string]$Kind, $Items)
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:UpdFetchBlock).AddArgument($Items).AddArgument('TessDesk/' + $AppVersion + ' (update check)')
    $script:UpdJob = [pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke(); kind = $Kind; started = Get-Date }
    $script:UpdTimer.Start()
}
function Start-UpdateCheck {
    param([switch]$Force)
    if ($null -ne $script:UpdJob -or $script:Upd.state -eq 'updating') { return }
    if (-not $Force -and ((Get-EpochNow) - [int64]$script:Upd.checkedEpoch) -lt 3 * 3600) { return }   # v4.3.7: every ~3 h (was ~20 h)
    $u = Get-UpdUrl; if ($u -like 'http*') { $u += '?t=' + (Get-EpochNow) }
    Start-UpdJob 'check' @([pscustomobject]@{ name = 'version.json'; url = $u })
}
function Complete-UpdJob {
    $j = $script:UpdJob; $res = $null; $err = $null
    try { $res = @($j.ps.EndInvoke($j.async))[0] } catch { $err = $_.Exception.Message }
    try { $j.ps.Dispose() } catch {}
    $script:UpdJob = $null
    if ($j.kind -eq 'check') {
        $script:Upd.checkedEpoch = Get-EpochNow
        try {
            if ($err) { throw $err }
            $r = @($res)[0]; if (-not $r.ok) { throw $r.err }
            $info = ([System.Text.Encoding]::UTF8.GetString($r.bytes).TrimStart([char]0xFEFF)) | ConvertFrom-Json
            $script:UpdInfo = $info
            $script:Upd.latest = $(if (Test-VersionNewer ([string]$info.version) $AppVersion) { [string]$info.version } else { $null })
            $script:Upd.note = 'checked ' + (Get-Date).ToString('h:mm tt', $Inv) + ': latest v' + [string]$info.version
            if ($script:Upd.state -ne 'failed') { $script:Upd.state = $(if ($script:Upd.latest) { 'available' } else { 'current' }) }
            try { [ordered]@{ checkedEpoch = $script:Upd.checkedEpoch; latest = [string]$info.version; info = $info } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $updCheckPath -Encoding UTF8 } catch {}
            Write-WidgetLog ('update check: latest v' + [string]$info.version + ', this copy v' + $AppVersion)
            try { Register-UpdCheckSuccess } catch {}
            if ($script:Upd.state -eq 'available') { $window.Dispatcher.BeginInvoke([Action]{ try { Show-UpdatePrompt } catch { Write-WidgetLog ('update prompt: ' + $_.Exception.Message) } }) | Out-Null }
        } catch { $script:Upd.note = 'update check failed: ' + "$_"; Write-WidgetLog $script:Upd.note; try { Register-UpdCheckFailure } catch {} }
    } else {
        try {
            if ($err) { throw $err }
            Install-UpdateFiles @($res)
        } catch { $script:Upd.state = 'failed'; $script:Upd.note = "$_"; Write-WidgetLog ('update failed: ' + "$_") }
    }
    Render-Update
}
function Invoke-UpdateApply {
    if ($null -ne $script:UpdJob -or $script:Upd.state -eq 'updating') { return }
    $info = $script:UpdInfo
    if ($null -eq $info -or -not $script:Upd.latest) { return }
    $files = @($info.desktop.files | Where-Object { $null -ne $_ -and $UpdAllowed -contains [string]$_.name -and [string]$_.url -and [string]$_.sha256 })
    if (@($files | Where-Object { $_.name -eq 'TessDesk.ps1' }).Count -ne 1) { $script:Upd.state = 'failed'; $script:Upd.note = 'the update feed has no TessDesk.ps1'; Render-Update; return }
    $script:Upd.state = 'updating'; $script:Upd.note = 'downloading ' + $files.Count + ' file(s)'
    Render-Update
    Start-UpdJob 'apply' @($files | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; url = [string]$_.url; sha256 = ([string]$_.sha256).ToLowerInvariant() } })
    $script:UpdWant = @{}; foreach ($f in $files) { $script:UpdWant[[string]$f.name] = ([string]$f.sha256).ToLowerInvariant() }
}
function Install-UpdateFiles {
    param($Res)
    $ver = $script:Upd.latest
    # 1) every file must download and match its SHA-256; the new widget must parse and carry the new version
    foreach ($r in $Res) {
        if (-not $r.ok) { throw ('download failed (' + $r.name + '): ' + $r.err) }
        if ($r.sha256 -ne $script:UpdWant[[string]$r.name]) { throw ('checksum mismatch for ' + $r.name + ' - nothing was changed') }
    }
    $main = @($Res | Where-Object { $_.name -eq 'TessDesk.ps1' })[0]
    $text = [System.Text.Encoding]::UTF8.GetString($main.bytes)
    $tk = $null; $pe = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($text.TrimStart([char]0xFEFF), [ref]$tk, [ref]$pe)
    if (@($pe).Count -gt 0) { throw ('the downloaded TessDesk.ps1 does not parse - nothing was changed') }
    if ($text -notmatch ("\`$AppVersion = '" + [regex]::Escape($ver) + "'")) { throw ('the downloaded TessDesk.ps1 is not v' + $ver + ' - nothing was changed') }
    # 2) back up the current copy (same files as a manual update)
    $bk = Join-Path $scriptDir ('backup-v' + $AppVersion + '-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $bk -Force | Out-Null
    foreach ($f in @('TessDesk.ps1', 'config.json', 'state.json', 'widget-status.json', 'TessDesk-Announce.ps1', 'TessDesk-Remind.ps1', 'TessDesk-Speakers.ps1', 'PRIVACY.md')) {
        $p = Join-Path $scriptDir $f; if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $bk $f) -Force }
    }
    try { Save-WidgetState } catch {}
    # 3) install: write each file next to itself, then swap it in
    $done = @()
    foreach ($r in $Res) {
        $dst = Join-Path $scriptDir ([string]$r.name); $tmp = $dst + '.new'
        [System.IO.File]::WriteAllBytes($tmp, $r.bytes)
        Move-Item -LiteralPath $tmp -Destination $dst -Force
        $done += [string]$r.name
    }
    $script:Upd.backup = $bk; $script:Upd.installed = [ordered]@{ version = $ver; files = $done }
    $script:Upd.state = 'installed'; $script:Upd.note = 'v' + $ver + ' installed; backup in ' + (Split-Path -Leaf $bk)
    Write-WidgetLog ('update: installed v' + $ver + ' (' + ($done -join ', ') + '), backup ' + $bk)
    Restart-TessDesk
}
function Restart-TessDesk {
    if ($SelfTest) { $script:Upd.restart = 'skipped (self-test)'; return }
    $ps1 = Join-Path $scriptDir 'TessDesk.ps1'
    # a hidden helper waits for this window to close (it holds the single-instance lock), then starts the new version
    $args2 = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $ps1 + '" -ConfigPath "' + $ConfigPath + '"'
    $cmd = "Wait-Process -Id $PID -Timeout 60 -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '" + ($args2 -replace "'", "''") + "'"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $enc)
    $script:Upd.restart = 'restarting'
    $window.Dispatcher.BeginInvoke([Action]{ $window.Close() }) | Out-Null
}
function Render-Update {
    $s = $script:Upd.state
    $show = ($s -in @('available', 'updating', 'failed', 'installed')) -and ($script:Upd.latest -or $s -eq 'installed')
    Set-Visible $ui.UpdateBtn $show
    if (-not $show) { return }
    $v = 'v' + $(if ($script:Upd.latest) { $script:Upd.latest } else { $script:Upd.installed.version })
    switch ($s) {
        'available' { $ui.UpdateTxt.Text = 'UPDATE AVAILABLE · ' + $v; $ui.UpdateSub.Text = 'one click: download, back up, install, restart (you have v' + $AppVersion + ')'; $ui.UpdateBtn.Background = T 'Green'; $ui.UpdateBtn.Cursor = [System.Windows.Input.Cursors]::Hand }
        'updating' { $ui.UpdateTxt.Text = 'UPDATING TO ' + $v + '…'; $ui.UpdateSub.Text = [string]$script:Upd.note; $ui.UpdateBtn.Cursor = [System.Windows.Input.Cursors]::Wait }
        'installed' { $ui.UpdateTxt.Text = $v + ' INSTALLED · RESTARTING'; $ui.UpdateSub.Text = [string]$script:Upd.note; $ui.UpdateBtn.Cursor = [System.Windows.Input.Cursors]::Arrow }
        'failed' { $ui.UpdateTxt.Text = 'UPDATE FAILED · CLICK TO RETRY ' + $v; $ui.UpdateSub.Text = [string]$script:Upd.note; $ui.UpdateBtn.Background = T 'Amber'; $ui.UpdateBtn.BorderBrush = T 'Amber'; $ui.UpdateBtn.Cursor = [System.Windows.Input.Cursors]::Hand }
    }
}
# remember the last check across restarts so the site is asked at most about once a day
try {
    if (Test-Path -LiteralPath $updCheckPath) {
        $uc = Get-Content -LiteralPath $updCheckPath -Raw | ConvertFrom-Json
        $script:Upd.checkedEpoch = [int64]$uc.checkedEpoch; $script:UpdInfo = $uc.info
        if (Test-VersionNewer ([string]$uc.latest) $AppVersion) { $script:Upd.latest = [string]$uc.latest; $script:Upd.state = 'available' }
    }
} catch {}

# ---------------- v4.3.3: DRIVES (Tessie /drives, read-only, every ~15 min) ----------------
function Update-DrivesCache {
    param([string]$Token, [int64]$NowE)
    $st = $script:State; if ($null -eq $st -or -not $script:VIN) { return }
    $last = [int64](Get-Val $st.drivesFetchEpoch 0)
    if (($NowE - $last) -lt ($ChargesRefreshMin * 60) -and $null -ne $st.drives) { return }
    $st.drivesFetchEpoch = $NowE
    try {
        $from = $NowE - 30 * 86400
        $r = Invoke-Tessie ("/$($script:VIN)/drives?from=$from&to=$NowE&distance_format=mi&format=json&limit=10") $Token
        $rows = @($r.results | Where-Object { $null -ne $_ -and $null -ne $_.started_at } | Sort-Object { [int64]$_.started_at } -Descending | Select-Object -First 10)
        $st.drives = @($rows | ForEach-Object { Convert-Drive $_ })
        $script:DrivesNote = $null
    } catch { $script:DrivesNote = 'drives: ' + $_.Exception.Message; Write-WidgetLog ('drives fetch failed: ' + $_.Exception.Message); $st.drivesFetchEpoch = $NowE - ($ChargesRefreshMin * 60) + 300 }
}
function Get-PlaceName {
    param($Saved, $Addr)
    if ($Saved) { return [string]$Saved }
    if (-not $Addr) { return 'Unknown place' }
    $p = @(([string]$Addr) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($p.Count -ge 2 -and $p[0] -match '^\d+\s') { return ($p[0] + ', ' + $p[1]) }
    return $p[0]
}
function Convert-Drive {
    param($d)
    $kwh = [double](Get-Val $d.energy_used 0.0)
    $offPeak = Get-AllInRate ((Get-Date).Date.AddHours(1))
    $se = [int64]$d.started_at; $ee = [int64](Get-Val $d.ended_at $d.started_at)
    return [pscustomobject]@{
        id = $d.id; startEpoch = $se; endEpoch = $ee; minutes = [math]::Round(($ee - $se) / 60.0)
        from = (Get-PlaceName $d.starting_saved_location $d.starting_location); to = (Get-PlaceName $d.ending_saved_location $d.ending_location)
        fromLat = $d.starting_latitude; fromLon = $d.starting_longitude; toLat = $d.ending_latitude; toLon = $d.ending_longitude
        miles = [math]::Round([double](Get-Val $d.odometer_distance 0.0), 1); kwh = [math]::Round($kwh, 2)
        costEst = [math]::Round($kwh / $EFFICIENCY * $offPeak, 2); rate = $offPeak
        socStart = $d.starting_battery; socEnd = $d.ending_battery
    }
}
function Get-LatLon { param($a, $b) return (([double]$a).ToString('0.000000', $Inv) + ',' + ([double]$b).ToString('0.000000', $Inv)) }
function Get-DriveMapUrl {
    param($dr)
    if ($null -eq $dr.fromLat -or $null -eq $dr.toLat) { return $null }
    return ('https://www.google.com/maps/dir/?api=1&origin=' + (Get-LatLon $dr.fromLat $dr.fromLon) + '&destination=' + (Get-LatLon $dr.toLat $dr.toLon) + '&travelmode=driving')
}
function Get-PlaceMapUrl { param($lat, $lon) if ($null -eq $lat) { return $null }; return ('https://www.google.com/maps/search/?api=1&query=' + (Get-LatLon $lat $lon)) }
function Get-LocationHistory {
    # where the car has been: each drive's end point, newest first, consecutive repeats folded
    $out = @(); $prev = $null
    foreach ($dr in @(Get-Val $script:State.drives @())) {
        if ($null -eq $dr) { continue }
        if ($dr.to -eq $prev) { continue }
        $out += [pscustomobject]@{ place = $dr.to; atEpoch = $dr.endEpoch; lat = $dr.toLat; lon = $dr.toLon; url = (Get-PlaceMapUrl $dr.toLat $dr.toLon) }
        $prev = $dr.to
    }
    return $out
}
function Get-HistoryMapUrl {
    # one Google Maps route through the recent stops (oldest -> newest, up to 10 points)
    $pts = @()
    $ds = @(@(Get-Val $script:State.drives @()) | Where-Object { $null -ne $_ -and $null -ne $_.toLat })
    if ($ds.Count -eq 0) { return $null }
    [array]::Reverse($ds)
    $pts += (Get-LatLon $ds[0].fromLat $ds[0].fromLon)
    foreach ($dr in $ds) { $p = Get-LatLon $dr.toLat $dr.toLon; if ($pts[-1] -ne $p) { $pts += $p } }
    if ($pts.Count -gt 10) { $pts = $pts[($pts.Count - 10)..($pts.Count - 1)] }
    return ('https://www.google.com/maps/dir/' + ($pts -join '/'))
}
function Open-Url433 {
    param([string]$Url)
    if (-not $Url) { return }
    $script:LastOpenUrl = $Url
    if (-not $SelfTest) { try { Start-Process $Url } catch { Write-WidgetLog ('open map failed: ' + $_.Exception.Message) } }
}

# ---------------- Window (XAML) ----------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TessDesk"
        Width="$winW" Height="$winH" MinHeight="400"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="True" WindowStartupLocation="Manual"
        FontFamily="Segoe UI" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="SwitchStyle" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Grid Width="38" Height="20">
              <Border x:Name="Track" CornerRadius="10" Background="#FF2E2E2E" BorderBrush="#FF444444" BorderThickness="1"/>
              <Ellipse x:Name="Thumb" Width="14" Height="14" Fill="#FFBBBBBB" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="Thumb" Property="Fill" Value="#FFFFFFFF"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Thumb" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CtlBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Foreground" Value="#FFFFFFFF"/>
      <Setter Property="Background" Value="#FF1E1E1E"/>
      <Setter Property="BorderBrush" Value="#FF2E2E2E"/>
      <Setter Property="Padding" Value="8,4,8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1.5"
                    CornerRadius="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.6"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SlimThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb"><Border CornerRadius="3" Background="#77FFFFFF"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/><Setter Property="MinWidth" Value="6"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Border CornerRadius="3" Background="#22FFFFFF">
            <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="True">
              <Track.Thumb><Thumb Style="{StaticResource SlimThumb}"/></Track.Thumb>
            </Track>
          </Border>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <!-- v4.3.9: camera panel button + frame slider -->
    <Style x:Key="CamBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Foreground" Value="#FFE6E6E6"/>
      <Setter Property="Background" Value="#FF1A1A1A"/>
      <Setter Property="BorderBrush" Value="#FF333333"/>
      <Setter Property="Padding" Value="6,2,6,2"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1.5" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.6"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CamSlider" TargetType="Slider">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="22" Background="Transparent">
              <Border Height="6" CornerRadius="3" Background="#FF2E2E2E" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="6" CornerRadius="3" Background="#FF49DF93" VerticalAlignment="Center"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Width="12" Height="18" CornerRadius="4" Background="#FFFFFFFF"/></ControlTemplate></Thumb.Template></Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- v4.3.10: full-width row button (TOTALS button, month rows) -->
    <Style x:Key="TotRowBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Foreground" Value="#FFE6E6E6"/>
      <Setter Property="Background" Value="#FF1A1A1A"/>
      <Setter Property="BorderBrush" Value="#FF333333"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1.2" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.6"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="RootBorder" Background="#FF0B0B0B" BorderBrush="#FF333333" BorderThickness="1" CornerRadius="10">
   <Grid x:Name="RootGrid">
    <DockPanel LastChildFill="True">
      <Border x:Name="TitleBar" DockPanel.Dock="Top" Background="#FF141414" Height="28" Cursor="SizeAll" CornerRadius="10,10,0,0">
        <Grid Margin="12,0,6,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="TitleText" Grid.Column="0" Text="TESSDESK" Foreground="#FFE82127" FontFamily="Segoe UI"
                     FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/>
          <TextBlock x:Name="LoggedIn" Grid.Column="1" Text="" Foreground="#FF7A7A7A" FontSize="10" VerticalAlignment="Center" Margin="8,0,6,0" TextAlignment="Right" TextTrimming="CharacterEllipsis"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <!-- v4.3.9: camera panel On / Off -->
            <Border x:Name="CamBox" CornerRadius="9" Background="#22FFFFFF" Padding="6,1,3,1" Margin="0,0,4,0" VerticalAlignment="Center" ToolTip="Camera panel On / Off (frames from your saved Sentry / Dashcam clips, not live)">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="CamLbl" Text="&#xE722;" FontFamily="Segoe MDL2 Assets" FontSize="10.5" Foreground="#FFCCCCCC" VerticalAlignment="Center" Margin="0,0,4,0"/>
                <ToggleButton x:Name="CamToggle" Style="{StaticResource SwitchStyle}" Tag="#FF49DF93" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Border x:Name="AlexaBox" CornerRadius="9" Background="#22FFFFFF" Padding="7,1,3,1" Margin="0,0,4,0" VerticalAlignment="Center" ToolTip="Alexa: announce the result of every control you press (Voice Monkey)">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="AlexaLbl" Text="ALEXA" FontSize="9.5" FontWeight="Bold" Foreground="#FFCCCCCC" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <ToggleButton x:Name="AlexaToggle" Style="{StaticResource SwitchStyle}" Tag="#FF3578FF" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Button x:Name="LayoutBtn" Content="FULL" Height="18" Padding="6,0,6,0" Margin="0,0,4,0" Background="#22FFFFFF" Foreground="#FFCCCCCC" BorderThickness="0"
                    FontSize="9" FontWeight="Bold" Cursor="Hand" VerticalAlignment="Center" ToolTip="Switch between Full (scrolls if needed) and Compact (everything fits the screen, no scrolling)"/>
            <Button x:Name="AnnBtn" Content="&#xE823;" FontFamily="Segoe MDL2 Assets" Width="22" Height="22" Background="Transparent" Foreground="#FFCCCCCC"
                    BorderThickness="0" FontSize="12" Cursor="Hand" ToolTip="Scheduled Alexa announcements and Connected apps"/>
            <Button x:Name="CloseBtn" Content="✕" Width="22" Height="22" Background="Transparent" Foreground="#FF888888"
                    BorderThickness="0" FontSize="11" Cursor="Hand" ToolTip="Close"/>
          </StackPanel>
        </Grid>
      </Border>

      <Grid x:Name="MainGrid" Margin="16,8,16,10">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0">
          <!-- v4.3.9: CAMERAS panel (top of the widget, above the charging amount). Frames from saved Sentry / Dashcam clips; Tesla has no live camera feed for apps. -->
          <Border x:Name="CamCard" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="8,6,8,7" Margin="0,0,0,7" Visibility="Collapsed">
            <StackPanel>
              <DockPanel LastChildFill="False">
                <TextBlock x:Name="CamHdr" DockPanel.Dock="Left" Text="CAMERAS" FontSize="12.5" FontWeight="Bold" Foreground="#FF9A9A9A" VerticalAlignment="Center"/>
                <Button x:Name="CamGear" DockPanel.Dock="Right" Style="{StaticResource CamBtn}" Width="26" Height="22" Padding="0" ToolTip="Camera options: clip folder, speed, which clips, full-screen layout">
                  <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="11"/>
                </Button>
                <Border x:Name="CamPill" DockPanel.Dock="Right" CornerRadius="9" BorderBrush="#FFFFB547" BorderThickness="1.5" Background="#22FFB547" Padding="7,1,7,2" Margin="0,0,5,0" VerticalAlignment="Center"
                        ToolTip="Tesla gives apps no live camera feed. This panel loops frames from your latest saved Sentry / Dashcam clip.">
                  <TextBlock x:Name="CamPillTxt" Text="NOT LIVE · FROM SAVED CLIPS" FontSize="8.5" FontWeight="Bold" Foreground="#FFFFB547"/>
                </Border>
              </DockPanel>
              <UniformGrid x:Name="CamTabs" Rows="1" Columns="5" Margin="0,6,0,0"/>
              <DockPanel Margin="1,5,1,3" LastChildFill="True">
                <TextBlock x:Name="CamSrc" DockPanel.Dock="Right" Text="" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF8A8A8A" Margin="6,0,0,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="CamEvent" Text="" FontSize="10" FontWeight="Bold" Foreground="#FFE82127" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
              </DockPanel>
              <Border CornerRadius="6" Background="#FF0A0A0A" ClipToBounds="True">
                <Grid x:Name="CamView" Height="238"/>
              </Border>
              <Grid x:Name="CamBusy" Margin="0,6,0,0" Visibility="Collapsed">
                <TextBlock x:Name="CamBusyTxt" Text="" FontSize="10.5" FontWeight="SemiBold" Foreground="#FFCCCCCC" VerticalAlignment="Center" Margin="2,0,70,0" TextTrimming="CharacterEllipsis"/>
                <Button x:Name="CamStop" Style="{StaticResource CamBtn}" HorizontalAlignment="Right" Height="24" Padding="10,0,10,0" BorderBrush="#FFE82127" ToolTip="Stop">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE71A;" FontFamily="Segoe MDL2 Assets" FontSize="9" VerticalAlignment="Center" Margin="0,0,5,0"/><TextBlock Text="Stop" VerticalAlignment="Center"/></StackPanel>
                </Button>
              </Grid>
              <DockPanel x:Name="CamCtl" Margin="0,6,0,0" LastChildFill="True">
                <Button x:Name="CamPlay" DockPanel.Dock="Left" Style="{StaticResource CamBtn}" Width="32" Height="26" Padding="0" BorderBrush="#FF49DF93" ToolTip="Play / pause the loop">
                  <TextBlock x:Name="CamPlayTxt" Text="&#xE769;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#FF49DF93"/>
                </Button>
                <Button x:Name="CamFs" DockPanel.Dock="Right" Style="{StaticResource CamBtn}" Height="26" Padding="7,0,8,0" Margin="4,0,0,0" ToolTip="Full screen: every camera (Esc or X to exit)">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE740;" FontFamily="Segoe MDL2 Assets" FontSize="10" VerticalAlignment="Center" Margin="0,0,4,0"/><TextBlock Text="Full screen" VerticalAlignment="Center"/></StackPanel>
                </Button>
                <Button x:Name="CamSave" DockPanel.Dock="Right" Style="{StaticResource CamBtn}" Width="28" Height="26" Padding="0" Margin="4,0,0,0" ToolTip="Save this clip (copies the selected Sentry / Dashcam clip to Videos\TessDesk Clips)">
                  <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="11"/>
                </Button>
                <TextBlock x:Name="CamCount" DockPanel.Dock="Right" Text="" FontSize="9.5" Foreground="#FF8A8A8A" VerticalAlignment="Center" Margin="6,0,0,0"/>
                <Slider x:Name="CamSlider" Style="{StaticResource CamSlider}" Minimum="0" Maximum="15" Value="0" SmallChange="1" LargeChange="1" IsSnapToTickEnabled="True" TickFrequency="1" Margin="6,0,0,0" VerticalAlignment="Center"/>
              </DockPanel>
            </StackPanel>
          </Border>
        <DockPanel LastChildFill="True" Margin="0,0,0,2">
          <TextBlock x:Name="UpdBadge" DockPanel.Dock="Right" Text="" Foreground="#FF888888" FontSize="10" FontWeight="SemiBold" Margin="6,1,0,0" VerticalAlignment="Top"
                     ToolTip="How old the car data is (Tessie's cached data; TessDesk never wakes the car)"/>
          <TextBlock x:Name="LiveBadge" DockPanel.Dock="Right" Text="" Foreground="#FF2ECC40" FontSize="10"
                     FontWeight="SemiBold" Margin="6,1,0,0" VerticalAlignment="Top" Visibility="Collapsed"/>
          <TextBlock x:Name="DateLabel" Text="—" Foreground="#FF888888" FontSize="11" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        </StackPanel>

        <StackPanel Grid.Row="1" Margin="0,0,0,2">
          <!-- v4.3.3: UPDATE AVAILABLE (one click: download, back up, install, restart) -->
          <Border x:Name="UpdateBtn" CornerRadius="10" Background="#FF49DF93" BorderBrush="#FF49DF93" BorderThickness="1.5" Padding="8,4,8,5" Margin="0,2,0,6"
                  Cursor="Hand" Visibility="Collapsed" ToolTip="One click: downloads the new version, backs up your current files, installs it and restarts TessDesk">
            <StackPanel HorizontalAlignment="Center">
              <TextBlock x:Name="UpdateTxt" Text="UPDATE AVAILABLE" FontSize="13" FontWeight="Bold" Foreground="#FF06210F" HorizontalAlignment="Center"/>
              <TextBlock x:Name="UpdateSub" Text="click to update and restart" FontSize="9" FontWeight="SemiBold" Foreground="#FF0B3A1C" HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="HeroCost" Text="" Foreground="#FFFFFFFF" FontSize="48" FontWeight="Bold" HorizontalAlignment="Center"/>
          <Viewbox StretchDirection="DownOnly" Stretch="Uniform" HorizontalAlignment="Center" Margin="0,-2,0,0">
            <TextBlock x:Name="HeroSub" Text="" Foreground="#FFE82127" FontSize="14" TextWrapping="NoWrap"/>
          </Viewbox>
        </StackPanel>

        <TextBlock x:Name="KwhLabel" Grid.Row="2" Text="" Foreground="#FFE82127" FontSize="16" FontWeight="SemiBold"
                   HorizontalAlignment="Center" Margin="0,0,0,4"/>

        <!-- v4.2: money rows right under the hero, compact -->
        <Border x:Name="RowsCard" Grid.Row="3" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="10,3,10,3" Margin="0,0,0,6">
          <StackPanel>
            <Grid x:Name="NightRow" Height="19">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="62"/></Grid.ColumnDefinitions>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock x:Name="NightLbl" Text="Tonight" FontSize="11.5" FontWeight="SemiBold" Foreground="#FFCCCCCC" VerticalAlignment="Center"/>
                <TextBlock x:Name="NightCap" Text="" FontSize="9" Foreground="#FF666666" Margin="6,1,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="150"/>
              </StackPanel>
              <TextBlock x:Name="NightKwh" Grid.Column="1" Text="— kWh" FontSize="9.5" Foreground="#FF666666" VerticalAlignment="Center" Margin="4,1,0,0"/>
              <TextBlock x:Name="NightCost" Grid.Column="2" Text="$—" FontSize="13" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <!-- v4.3.5: SESSIONS of the current / last 11 PM -> 11 AM window (one line each) -->
            <StackPanel x:Name="SessBox" Visibility="Collapsed" Margin="8,0,0,2">
              <TextBlock x:Name="SessHdr" Text="Sessions" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/>
              <StackPanel x:Name="SessList"/>
            </StackPanel>
            <Border x:Name="RowSep1" Height="1" Background="#FF222222" Margin="0,1,0,1"/>
            <Grid x:Name="D7Row" Height="19">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="62"/></Grid.ColumnDefinitions>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock x:Name="D7Lbl" Text="Last 7 days" FontSize="11.5" FontWeight="SemiBold" Foreground="#FFCCCCCC" VerticalAlignment="Center"/>
                <TextBlock x:Name="D7Cap" Text="" FontSize="9" Foreground="#FF666666" Margin="6,1,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="150"/>
              </StackPanel>
              <TextBlock x:Name="D7Kwh" Grid.Column="1" Text="— kWh" FontSize="9.5" Foreground="#FF666666" VerticalAlignment="Center" Margin="4,1,0,0"/>
              <TextBlock x:Name="D7Cost" Grid.Column="2" Text="$—" FontSize="13" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <Border x:Name="RowSep2" Height="1" Background="#FF222222" Margin="0,1,0,1"/>
            <Grid x:Name="D30Row" Height="19">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="62"/></Grid.ColumnDefinitions>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock x:Name="D30Lbl" Text="Last 30 days" FontSize="11.5" FontWeight="SemiBold" Foreground="#FFCCCCCC" VerticalAlignment="Center"/>
                <TextBlock x:Name="D30Cap" Text="" FontSize="9" Foreground="#FF666666" Margin="6,1,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="150"/>
              </StackPanel>
              <TextBlock x:Name="D30Kwh" Grid.Column="1" Text="— kWh" FontSize="9.5" Foreground="#FF666666" VerticalAlignment="Center" Margin="4,1,0,0"/>
              <TextBlock x:Name="D30Cost" Grid.Column="2" Text="$—" FontSize="13" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <!-- v4.3.10: TOTALS pop-up (running totals for this week / month / year, month by month) -->
            <Border x:Name="RowSep3" Height="1" Background="#FF222222" Margin="0,1,0,2"/>
            <Button x:Name="TotBtn" Style="{StaticResource TotRowBtn}" Height="22" Margin="0,0,0,2" Padding="8,0,8,0" HorizontalAlignment="Stretch" HorizontalContentAlignment="Stretch" Cursor="Hand" ToolTip="Charging totals: this week, this month, this year, month by month">
              <DockPanel>
                <TextBlock DockPanel.Dock="Right" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" FontSize="9" VerticalAlignment="Center" Foreground="#FF888888"/>
                <TextBlock x:Name="TotBtnSum" DockPanel.Dock="Right" Text="" FontSize="9.5" Foreground="#FF888888" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Border Width="15" Height="15" CornerRadius="8" Background="#FF49DF93" Margin="0,0,6,0"><TextBlock Text="&#x24;" FontSize="10" FontWeight="Bold" Foreground="#FF06140C" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                  <TextBlock Text="TOTALS" FontSize="10.5" FontWeight="Bold" Foreground="#FFFFFFFF" VerticalAlignment="Center"/>
                  <TextBlock Text="week · month · year" FontSize="9.5" Foreground="#FF888888" VerticalAlignment="Center" Margin="6,0,0,0"/>
                </StackPanel>
              </DockPanel>
            </Button>
          </StackPanel>
        </Border>

        <!-- v4.2: lower sections scroll (slim scrollbar) when they don't fit the screen -->
        <ScrollViewer x:Name="BodyScroll" Grid.Row="4" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                      PanningMode="None" Focusable="False" Margin="0,0,-11,0">
          <StackPanel x:Name="BodyStack" Margin="0,0,5,0">
        <!-- v4.3: RATE STATUS (peak/day pill + Stop, off-peak pill, or a neutral line) -->
        <Border x:Name="PeakBanner" CornerRadius="10" Background="#30FFB547" BorderBrush="#FFFFB547" BorderThickness="1.5" Padding="10,7,10,8" Margin="0,0,0,6" Visibility="Collapsed">
          <StackPanel>
            <DockPanel LastChildFill="True">
              <TextBlock x:Name="PeakClose" DockPanel.Dock="Right" Text="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#FFCCCCCC" Cursor="Hand" Margin="6,2,0,0" VerticalAlignment="Top" ToolTip="Fold to a single line for this charge session"/>
              <TextBlock x:Name="PeakIcon" DockPanel.Dock="Left" Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="17" Foreground="#FFFFB547" Margin="0,1,8,0" VerticalAlignment="Top"/>
              <StackPanel>
                <TextBlock x:Name="PeakTitle" Text="" FontSize="12.5" FontWeight="Bold" TextWrapping="Wrap" Foreground="#FFFFFFFF"/>
                <TextBlock x:Name="PeakSub" Text="" FontSize="10" TextWrapping="Wrap" Margin="0,2,0,0" Foreground="#FFCCCCCC"/>
              </StackPanel>
            </DockPanel>
            <Grid x:Name="PeakActions" Margin="0,6,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Button x:Name="PeakStopBtn" Style="{StaticResource CtlBtn}" Height="32" Padding="10,0,10,0" ToolTip="Stop charging now (asks to confirm)">
                <TextBlock x:Name="PeakStopTxt" Text="&#x25A0; STOP CHARGING" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/>
              </Button>
              <TextBlock x:Name="PeakTip" Grid.Column="1" Text="" FontSize="9.5" TextWrapping="Wrap" Margin="8,0,0,0" VerticalAlignment="Center" Foreground="#FF888888"/>
            </Grid>
          </StackPanel>
        </Border>
        <Border x:Name="BattCard" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="12,7,12,8" Margin="0,0,0,6">
          <StackPanel>
            <DockPanel LastChildFill="True">
              <TextBlock x:Name="BattState" DockPanel.Dock="Right" Text="" FontSize="10" FontWeight="SemiBold" Foreground="#FF888888" VerticalAlignment="Center"/>
              <TextBlock x:Name="BattHdr" Text="BATTERY" FontSize="12.5" FontWeight="Bold" Foreground="#FF9A9A9A"/>
            </DockPanel>
            <Grid x:Name="BattMain">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="96"/></Grid.ColumnDefinitions>
              <StackPanel x:Name="BattLeft">
            <Grid Height="46">
              <StackPanel x:Name="BattTop" Orientation="Horizontal">
                <TextBlock x:Name="BattPct" Text="--" FontSize="38" FontWeight="Bold" Foreground="#FFFFFFFF" VerticalAlignment="Bottom"/>
                <StackPanel VerticalAlignment="Bottom" Margin="10,0,0,8">
                  <TextBlock x:Name="BattRange" Text="" FontSize="19" FontWeight="SemiBold" Foreground="#FFFFFFFF"/>
                  <TextBlock x:Name="BattRangeCap" Text="" FontSize="8" FontWeight="SemiBold" Foreground="#FF888888" Margin="0,-1,0,0"/>
                </StackPanel>
              </StackPanel>
              <StackPanel x:Name="DragBox" Orientation="Vertical" HorizontalAlignment="Left" VerticalAlignment="Bottom" Visibility="Collapsed">
                <TextBlock x:Name="DragCap" Text="SET LIMIT" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF888888"/>
                <TextBlock x:Name="DragVal" Text="" FontSize="25" FontWeight="Bold" Foreground="#FFFFFFFF" Margin="0,-3,0,0"/>
              </StackPanel>
            </Grid>
            <Canvas x:Name="BarDark" Width="206" Height="40" HorizontalAlignment="Left" Margin="0,4,0,0" Background="Transparent">
              <Rectangle x:Name="BarTrack" Canvas.Left="13" Canvas.Top="16" Width="180" Height="8" RadiusX="4" RadiusY="4" Fill="#FF2A2A2A"/>
              <Rectangle x:Name="BarFrom" Canvas.Left="13" Canvas.Top="16" Width="0" Height="8" RadiusX="4" RadiusY="4" Fill="#FFE82127" Opacity="0.35"/>
              <Rectangle x:Name="BarFill" Canvas.Left="13" Canvas.Top="16" Width="0" Height="8" RadiusX="4" RadiusY="4" Fill="#FFE82127"/>
              <Rectangle x:Name="FromTick" Canvas.Left="13" Canvas.Top="10" Width="2" Height="20" Fill="#FFCCCCCC" Opacity="0.8"/>
              <Border x:Name="LimitThumb" Canvas.Left="0" Canvas.Top="9" Width="4" Height="22" CornerRadius="2" Background="#FFFFFFFF" BorderThickness="0" ToolTip="Charge limit (set it with the slider on the right)"/>
              <Grid x:Name="BarBall" Canvas.Left="0" Canvas.Top="7" Width="26" Height="26">
                <Ellipse x:Name="BarBallDot" Fill="#FFE82127" Stroke="#FF0B0B0B" StrokeThickness="2.5"/>
                <TextBlock x:Name="BarBallText" Text="" FontSize="8" FontWeight="Bold" Foreground="#FF0B0B0B" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
            </Canvas>
            <Grid Margin="0,5,0,0" Width="206" HorizontalAlignment="Left">
              <StackPanel HorizontalAlignment="Left">
                <TextBlock x:Name="FromCap" Text="FROM" FontSize="9" FontWeight="SemiBold" Foreground="#FF8A8A8A"/>
                <TextBlock x:Name="FromMi" Text="" FontSize="11" FontWeight="SemiBold" Foreground="#FFCCCCCC"/>
                <TextBlock x:Name="BarStartLbl" Text="--" FontSize="18" FontWeight="Bold" Foreground="#FFFFFFFF" Margin="0,-2,0,0"/>
              </StackPanel>
              <StackPanel HorizontalAlignment="Right">
                <TextBlock x:Name="LimitCap" Text="LIMIT" FontSize="9" FontWeight="SemiBold" Foreground="#FF8A8A8A" HorizontalAlignment="Right"/>
                <TextBlock x:Name="LimitMi" Text="" FontSize="11" FontWeight="SemiBold" Foreground="#FFCCCCCC" HorizontalAlignment="Right"/>
                <TextBlock x:Name="BarLimitLbl" Text="--" FontSize="18" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Right" Margin="0,-2,0,0"/>
              </StackPanel>
            </Grid>
              </StackPanel>
              <!-- v4.3: vertical CHARGE LIMIT slider, % + miles on the thumb -->
              <Canvas x:Name="VLim" Grid.Column="1" Width="96" Height="150" VerticalAlignment="Top" Background="Transparent" Cursor="SizeNS"
                      ToolTip="Drag (or use the mouse wheel) to set the charge limit">
                <TextBlock x:Name="VLblTop" Canvas.Left="0" Canvas.Top="15" Width="34" TextAlignment="Right" Text="100" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/>
                <TextBlock x:Name="VLbl90" Canvas.Left="0" Canvas.Top="36" Width="34" TextAlignment="Right" Text="90" FontSize="9.5" FontWeight="Bold" Foreground="#FFFFB547"/>
                <StackPanel x:Name="VLbl80" Canvas.Left="0" Canvas.Top="57" Width="34">
                  <TextBlock x:Name="VLbl80a" Text="80" FontSize="10.5" FontWeight="Bold" Foreground="#FF49DF93" TextAlignment="Right" Margin="0,-1,0,-2"/>
                  <TextBlock x:Name="VLbl80b" Text="DAILY" FontSize="7" FontWeight="Bold" Foreground="#FF49DF93" TextAlignment="Right"/>
                </StackPanel>
                <TextBlock x:Name="VLblBot" Canvas.Left="0" Canvas.Top="121" Width="34" TextAlignment="Right" Text="50" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/>
                <Rectangle x:Name="VTrack" Canvas.Left="60" Canvas.Top="22" Width="12" Height="106" RadiusX="6" RadiusY="6" Fill="#FF2A2A2A"/>
                <Rectangle x:Name="VFill" Canvas.Left="60" Canvas.Top="128" Width="12" Height="0" RadiusX="6" RadiusY="6" Fill="#FFE82127"/>
                <Rectangle x:Name="VTick90" Canvas.Left="52" Canvas.Top="42" Width="28" Height="2" Fill="#FFFFB547"/>
                <Rectangle x:Name="VTick80" Canvas.Left="50" Canvas.Top="63" Width="32" Height="3" Fill="#FF49DF93"/>
                <Border x:Name="VThumb" Canvas.Left="37" Canvas.Top="40" Width="58" Height="42" CornerRadius="12" Background="#FFFFFFFF" BorderBrush="#FF0B0B0B" BorderThickness="2">
                  <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                    <TextBlock x:Name="VPct" Text="--" FontSize="19" FontWeight="Bold" Foreground="#FF0B0B0B" HorizontalAlignment="Center" Margin="0,-3,0,-3"/>
                    <TextBlock x:Name="VMi" Text="" FontSize="9" FontWeight="Bold" Foreground="#FF3A3A3A" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Border>
              </Canvas>
            </Grid>
            <!-- v4.2: CHARGING AMPS slider (same build as the limit slider) -->
            <Border x:Name="AmpsSep" Height="1" Background="#FF222222" Margin="0,8,0,6"/>
            <DockPanel LastChildFill="True">
              <TextBlock x:Name="AmpsNow" DockPanel.Dock="Right" Text="" FontSize="10" FontWeight="SemiBold" Foreground="#FFCCCCCC" VerticalAlignment="Center"/>
              <TextBlock x:Name="AmpsHdr" Text="CHARGING AMPS" FontSize="11" FontWeight="Bold" Foreground="#FF9A9A9A"/>
            </DockPanel>
            <Canvas x:Name="AmpsDark" Width="306" Height="40" HorizontalAlignment="Center" Margin="0,4,0,0" Background="Transparent">
              <Rectangle x:Name="AmpsTrack" Canvas.Left="13" Canvas.Top="16" Width="280" Height="8" RadiusX="4" RadiusY="4" Fill="#FF2A2A2A"/>
              <Rectangle x:Name="AmpsFill" Canvas.Left="13" Canvas.Top="16" Width="0" Height="8" RadiusX="4" RadiusY="4" Fill="#FFE82127"/>
              <Border x:Name="AmpsThumb" Canvas.Left="0" Canvas.Top="0" Width="20" Height="40" CornerRadius="6" Background="#FFFFFFFF"
                      BorderBrush="#FF0B0B0B" BorderThickness="2" Cursor="SizeWE" ToolTip="Drag to set the charging current (amps)">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                  <Rectangle x:Name="AGrip1" Width="2" Height="16" Fill="#FF555555" Margin="0,0,3,0"/>
                  <Rectangle x:Name="AGrip2" Width="2" Height="16" Fill="#FF555555"/>
                </StackPanel>
              </Border>
            </Canvas>
            <Grid Margin="0,3,0,0">
              <TextBlock x:Name="AmpsMinLbl" Text="5 A" FontSize="10" FontWeight="SemiBold" Foreground="#FF8A8A8A" HorizontalAlignment="Left" VerticalAlignment="Center"/>
              <TextBlock x:Name="AmpsVal" Text="-- A" FontSize="18" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Center"/>
              <TextBlock x:Name="AmpsMaxLbl" Text="-- A max" FontSize="10" FontWeight="SemiBold" Foreground="#FF8A8A8A" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <UniformGrid Columns="2" Rows="1" Margin="0,8,0,0">
              <Button x:Name="ChgStartBtn" Style="{StaticResource CtlBtn}" Height="44" Margin="0,0,3,0" Padding="3,2,3,2" ToolTip="Start charging (car must be plugged in)">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock x:Name="ChgStartTxt" Text="START CHARGING" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="ChgStartSub" Text="" FontSize="8.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="ChgStopBtn" Style="{StaticResource CtlBtn}" Height="44" Margin="3,0,0,0" Padding="3,2,3,2" ToolTip="Stop charging">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock x:Name="ChgStopTxt" Text="STOP CHARGING" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="ChgStopSub" Text="" FontSize="8.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
            </UniformGrid>
          </StackPanel>
        </Border>

        <UniformGrid Columns="3" Rows="1" Margin="0,0,0,6">
          <Border x:Name="Tile0" CornerRadius="8" Background="#FF151515" Margin="0,0,4,0" Padding="5,5,5,5">
            <StackPanel>
              <TextBlock x:Name="TileLbl0" Text="POWER" FontSize="9" FontWeight="SemiBold" Foreground="#FF7A7A7A" HorizontalAlignment="Center"/>
              <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="24"><TextBlock x:Name="TileVal0" Text="—" FontSize="17" FontWeight="Bold" Foreground="#FFE82127"/></Viewbox>
              <Viewbox StretchDirection="DownOnly" Stretch="Uniform"><TextBlock x:Name="TileSub0" Text=" " FontSize="9" Foreground="#FF888888"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="Tile1" CornerRadius="8" Background="#FF151515" Margin="2,0,2,0" Padding="5,5,5,5">
            <StackPanel>
              <TextBlock x:Name="TileLbl1" Text="TO FULL" FontSize="9" FontWeight="SemiBold" Foreground="#FF7A7A7A" HorizontalAlignment="Center"/>
              <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="24"><TextBlock x:Name="TileVal1" Text="—" FontSize="17" FontWeight="Bold" Foreground="#FFE82127"/></Viewbox>
              <Viewbox StretchDirection="DownOnly" Stretch="Uniform"><TextBlock x:Name="TileSub1" Text=" " FontSize="9" Foreground="#FF888888"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="Tile2" CornerRadius="8" Background="#FF151515" Margin="4,0,0,0" Padding="5,5,5,5">
            <StackPanel>
              <TextBlock x:Name="TileLbl2" Text="STARTED" FontSize="9" FontWeight="SemiBold" Foreground="#FF7A7A7A" HorizontalAlignment="Center"/>
              <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="24"><TextBlock x:Name="TileVal2" Text="—" FontSize="17" FontWeight="Bold" Foreground="#FFE82127"/></Viewbox>
              <Viewbox StretchDirection="DownOnly" Stretch="Uniform"><TextBlock x:Name="TileSub2" Text=" " FontSize="9" Foreground="#FF888888"/></Viewbox>
            </StackPanel>
          </Border>
                </UniformGrid>

        <Border x:Name="CtlCard" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="12,6,12,8" Margin="0,0,0,6">
          <StackPanel>
            <DockPanel LastChildFill="True" Margin="0,0,0,6">
              <TextBlock x:Name="CtlMode" DockPanel.Dock="Right" Text="" FontSize="10" FontWeight="Bold" Foreground="#FFFFB020" VerticalAlignment="Center"/>
              <TextBlock x:Name="CtlHdr" Text="TESLA CONTROLS" FontSize="12.5" FontWeight="Bold" Foreground="#FF9A9A9A"/>
            </DockPanel>
            <UniformGrid Columns="3" Rows="1">
              <Button x:Name="LockBtn" Style="{StaticResource CtlBtn}" Height="56" Margin="0,0,3,0" Padding="4,4,4,4" ToolTip="Lock / unlock your Tesla">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="LockIcon" Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="18" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="3,0,0,0">
                    <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="LockTxt" Text="LOCK" FontSize="16" FontWeight="Bold"/></Viewbox>
                    <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="LockSub" Text="" FontSize="10" Foreground="#FF888888"/></Viewbox>
                  </StackPanel>
                </Grid>
              </Button>
              <Border x:Name="FlashBox" Height="56" Margin="3,0,3,0" CornerRadius="10" BorderThickness="1.5" BorderBrush="#FF49DF93" Background="#2649DF93" Padding="5,3,5,3" ToolTip="Flash the headlights (Tessie flash), 1-20 times with the pause you set (1-30 s). Asks first; Stop ends early.">
                <StackPanel VerticalAlignment="Center">
                  <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Center"><TextBlock x:Name="FlashTxt" Text="FLASH LIGHTS" FontSize="11" FontWeight="Bold"/></Viewbox>
                  <Grid Margin="0,2,0,1">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="FlashCount" Text="5" Height="19" FontSize="11" FontWeight="Bold" TextAlignment="Center" VerticalContentAlignment="Center" Padding="0" MaxLength="2"
                             Background="#33000000" Foreground="#FFFFFFFF" BorderBrush="#FF49DF93" BorderThickness="1" CaretBrush="#FFFFFFFF" ToolTip="How many flashes (1-20)"/>
                    <TextBox x:Name="FlashPause" Grid.Column="1" Text="1.0" Height="19" Margin="3,0,0,0" FontSize="10" FontWeight="Bold" TextAlignment="Center" VerticalContentAlignment="Center" Padding="0" MaxLength="4"
                             Background="#33000000" Foreground="#FFFFFFFF" BorderBrush="#FF49DF93" BorderThickness="1" CaretBrush="#FFFFFFFF" ToolTip="Pause between flashes, seconds (1-30, 0.5 s steps; mouse wheel or Up/Down changes it). Under 3 s each flash is sent without waiting for the car (fire and go)."/>
                    <Button x:Name="FlashBtn" Grid.Column="2" Style="{StaticResource CtlBtn}" Height="19" Margin="3,0,0,0" Padding="1,0,1,0" ToolTip="Flash (asks first) / Stop">
                      <Viewbox StretchDirection="DownOnly"><TextBlock x:Name="FlashBtnTxt" Text="FLASH" FontSize="9.5" FontWeight="Bold" HorizontalAlignment="Center"/></Viewbox>
                    </Button>
                  </Grid>
                  <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Center"><TextBlock x:Name="FlashSub" Text="flashes · pause s" FontSize="8.5" FontWeight="SemiBold" Foreground="#FF888888"/></Viewbox>
                </StackPanel>
              </Border>
              <Button x:Name="ClimBtn" Style="{StaticResource CtlBtn}" Height="56" Margin="3,0,0,0" Padding="4,4,4,4" ToolTip="Turn climate (A/C) on or off">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="ClimIcon" Text="❄" FontFamily="Segoe UI Symbol" FontSize="17" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="3,0,0,0">
                    <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="ClimTxt" Text="A/C" FontSize="16" FontWeight="Bold"/></Viewbox>
                    <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="ClimSub" Text="" FontSize="10" Foreground="#FF888888"/></Viewbox>
                  </StackPanel>
                </Grid>
              </Button>
            </UniformGrid>
            <TextBlock x:Name="FlashStats" Text="" Visibility="Collapsed" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center" Margin="0,3,0,0"
                       ToolTip="Flash lights: response time of each flash request (sent until Tessie answered), average, and the measured gap between successful flashes"/>
            <UniformGrid Columns="3" Rows="1" Margin="0,6,0,0">
              <Button x:Name="HeatBtn" Style="{StaticResource CtlBtn}" Height="50" Margin="0,0,3,0" Padding="3,2,3,2" ToolTip="Heat = climate on with a warm set temperature (Tesla has no separate heater command)">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="HeatIcon" Text="♨" FontFamily="Segoe UI Symbol" FontSize="13" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="HeatTxt" Text="HEAT" FontSize="12.5" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Center" MaxWidth="96"><TextBlock x:Name="HeatSub" Text="" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/></Viewbox>
                </StackPanel>
              </Button>
              <Button x:Name="DefrostBtn" Style="{StaticResource CtlBtn}" Height="50" Margin="3,0,3,0" Padding="3,2,3,2" ToolTip="Max defrost on / off">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="DefrostIcon" Text="❄" FontFamily="Segoe UI Symbol" FontSize="13" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DefrostTxt" Text="DEFROST" FontSize="12.5" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Center" MaxWidth="96"><TextBlock x:Name="DefrostSub" Text="" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/></Viewbox>
                </StackPanel>
              </Button>
              <Button x:Name="CopBtn" Style="{StaticResource CtlBtn}" Height="50" Margin="3,0,0,0" Padding="3,2,3,2" ToolTip="Cabin Overheat Protection: off, on, fan only">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="CopIcon" Text="☀" FontFamily="Segoe UI Symbol" FontSize="13" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="CopTxt" Text="OVERHEAT" FontSize="12.5" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Center" MaxWidth="96"><TextBlock x:Name="CopSub" Text="" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/></Viewbox>
                </StackPanel>
              </Button>
            </UniformGrid>
            <Grid Margin="0,6,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/>
                <ColumnDefinition Width="40"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="VentBtn" Grid.Column="0" Style="{StaticResource CtlBtn}" Height="44" Margin="0,0,3,0" Padding="2" ToolTip="Vent all windows">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock x:Name="VentTxt" Text="VENT" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="VentSub" Text="WINDOWS" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="CloseWinBtn" Grid.Column="1" Style="{StaticResource CtlBtn}" Height="44" Margin="3,0,0,0" Padding="2" ToolTip="Close all windows">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock x:Name="CloseWinTxt" Text="CLOSE" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="CloseWinSub" Text="WINDOWS" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="TempDownBtn" Grid.Column="3" Style="{StaticResource CtlBtn}" Height="44" Padding="0" ToolTip="Cooler">
                <TextBlock Text="−" FontSize="22" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,-4,0,0"/>
              </Button>
              <StackPanel Grid.Column="4" VerticalAlignment="Center">
                <TextBlock x:Name="TempVal" Text="--" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center"/>
                <TextBlock x:Name="TempCap" Text="SET TEMP" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF7A7A7A" HorizontalAlignment="Center"/>
              </StackPanel>
              <Button x:Name="TempUpBtn" Grid.Column="5" Style="{StaticResource CtlBtn}" Height="44" Padding="0" ToolTip="Warmer">
                <TextBlock Text="+" FontSize="20" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,-3,0,0"/>
              </Button>
            </Grid>
            <!-- v4.3.3: OPEN TRUNK (rear only, asks first) + SENTRY MODE on/off (shows the car's state, asks first) -->
            <Grid Margin="0,6,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Button x:Name="TrunkBtn" Grid.Column="0" Style="{StaticResource CtlBtn}" Height="44" Margin="0,0,3,0" Padding="2" ToolTip="Open the rear trunk (asks Are you sure? first)">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="TrunkIcon" Text="&#xE7EF;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <TextBlock x:Name="TrunkTxt" Text="OPEN TRUNK" FontSize="13" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock x:Name="TrunkSub" Text="REAR" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="SentryBtn" Grid.Column="1" Style="{StaticResource CtlBtn}" Height="44" Margin="3,0,0,0" Padding="2" ToolTip="Sentry Mode on / off (shows the car's current state, asks first)">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="SentryIcon" Text="&#xE7B3;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <TextBlock x:Name="SentryTxt" Text="SENTRY MODE" FontSize="13" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock x:Name="SentrySub" Text="STATE UNKNOWN" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
            </Grid>
            <!-- v4.3: Announce on Alexa = one push, full status rundown; gear = Announce Setup -->
            <Grid Margin="0,6,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions>
              <Button x:Name="AnnNowBtn" Style="{StaticResource CtlBtn}" Height="42" Margin="0,0,3,0" Padding="4,2,4,2" ToolTip="Announce on Alexa: one push speaks a full status rundown (asks to confirm)">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock Text="&#xE767;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <TextBlock x:Name="AnnNowTxt" Text="ANNOUNCE ON ALEXA" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock x:Name="AnnNowSub" Text="FULL STATUS" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
              </Button>
              <Button x:Name="AnnSetupBtn" Grid.Column="1" Style="{StaticResource CtlBtn}" Height="42" Margin="3,0,0,0" Padding="0" ToolTip="Announce Setup: rundown items, speakers (pick Echos, Test, Add speaker), charging-started announcement">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="15" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="AnnSetupTxt" Text="SETUP" FontSize="8" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,2,0,0"/>
                </StackPanel>
              </Button>
            </Grid>
            <Border x:Name="CtlResultBox" CornerRadius="6" Background="#FF0F0F0F" Margin="0,6,0,0" Padding="8,4,8,4" MinHeight="26">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Ellipse x:Name="CtlSpin" Width="13" Height="13" StrokeThickness="2.2" Stroke="#FF49DF93" StrokeDashArray="5 3"
                         Margin="0,0,7,0" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5" Visibility="Collapsed">
                  <Ellipse.RenderTransform><RotateTransform x:Name="CtlSpinRot" Angle="0"/></Ellipse.RenderTransform>
                </Ellipse>
                <TextBlock x:Name="CtlResult" Grid.Column="1" Text="Ready" FontSize="10" TextWrapping="Wrap" VerticalAlignment="Center" Foreground="#FF888888"/>
              </Grid>
            </Border>
          </StackPanel>
        </Border>

        <!-- v4.2: HEATED SEATS, top-down like the tires (v4.3.2: above the tires) -->
        <Border x:Name="SeatsCard" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="12,6,12,6" Margin="0,0,0,6">
          <StackPanel>
            <DockPanel LastChildFill="True">
              <TextBlock x:Name="SeatsNote" DockPanel.Dock="Right" Text="tap a seat: off → 1 → 2 → 3" FontSize="10" Foreground="#FF888888" VerticalAlignment="Center"/>
              <TextBlock x:Name="SeatsHdr" Text="HEATED SEATS" FontSize="12.5" FontWeight="Bold" Foreground="#FF9A9A9A"/>
            </DockPanel>
            <Canvas x:Name="SeatCanvas" Width="304" Height="150" Margin="0,4,0,0">
              <Rectangle x:Name="SeatBody" Canvas.Left="92" Canvas.Top="0" Width="120" Height="150" RadiusX="34" RadiusY="40" Stroke="#FF6A6A6A" StrokeThickness="1.5" Fill="#FF161616"/>
              <Rectangle x:Name="SeatGlass" Canvas.Left="104" Canvas.Top="8" Width="96" Height="12" RadiusX="6" RadiusY="6" Fill="#FF2A2A2A"/>
              <Button x:Name="WheelBtn" Style="{StaticResource CtlBtn}" Canvas.Left="106" Canvas.Top="22" Width="38" Height="22" Padding="0" ToolTip="Steering wheel heater: tap to turn on / off">
                <TextBlock x:Name="WheelN" Text="◯" FontFamily="Segoe UI Symbol" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center"/>
              </Button>
              <Button x:Name="SeatFL" Style="{StaticResource CtlBtn}" Canvas.Left="100" Canvas.Top="46" Width="50" Height="46" Padding="0" ToolTip="Driver seat: tap to change the seat heat (off, 1, 2, 3)">
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                  <TextBlock x:Name="SeatFLN" Text="--" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Height="15"><Rectangle x:Name="SeatFLB1" Width="7" Height="7" RadiusX="1.5" RadiusY="1.5" Margin="0,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatFLB2" Width="7" Height="11" RadiusX="1.5" RadiusY="1.5" Margin="3,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatFLB3" Width="7" Height="15" RadiusX="1.5" RadiusY="1.5" Margin="3,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/></StackPanel>
                </StackPanel>
              </Button>
              <Button x:Name="SeatFR" Style="{StaticResource CtlBtn}" Canvas.Left="154" Canvas.Top="46" Width="50" Height="46" Padding="0" ToolTip="Passenger seat: tap to change the seat heat (off, 1, 2, 3)">
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                  <TextBlock x:Name="SeatFRN" Text="--" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Height="15"><Rectangle x:Name="SeatFRB1" Width="7" Height="7" RadiusX="1.5" RadiusY="1.5" Margin="0,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatFRB2" Width="7" Height="11" RadiusX="1.5" RadiusY="1.5" Margin="3,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatFRB3" Width="7" Height="15" RadiusX="1.5" RadiusY="1.5" Margin="3,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/></StackPanel>
                </StackPanel>
              </Button>
              <Button x:Name="SeatRL" Style="{StaticResource CtlBtn}" Canvas.Left="100" Canvas.Top="104" Width="32" Height="40" Padding="0" ToolTip="Rear left seat: tap to change the seat heat (off, 1, 2, 3)">
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                  <TextBlock x:Name="SeatRLN" Text="--" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Height="11"><Rectangle x:Name="SeatRLB1" Width="5" Height="5" RadiusX="1.5" RadiusY="1.5" Margin="0,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatRLB2" Width="5" Height="8" RadiusX="1.5" RadiusY="1.5" Margin="2,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatRLB3" Width="5" Height="11" RadiusX="1.5" RadiusY="1.5" Margin="2,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/></StackPanel>
                </StackPanel>
              </Button>
              <Button x:Name="SeatRC" Style="{StaticResource CtlBtn}" Canvas.Left="136" Canvas.Top="104" Width="32" Height="40" Padding="0" ToolTip="Rear center seat: tap to change the seat heat (off, 1, 2, 3)">
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                  <TextBlock x:Name="SeatRCN" Text="--" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Height="11"><Rectangle x:Name="SeatRCB1" Width="5" Height="5" RadiusX="1.5" RadiusY="1.5" Margin="0,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatRCB2" Width="5" Height="8" RadiusX="1.5" RadiusY="1.5" Margin="2,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatRCB3" Width="5" Height="11" RadiusX="1.5" RadiusY="1.5" Margin="2,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/></StackPanel>
                </StackPanel>
              </Button>
              <Button x:Name="SeatRR" Style="{StaticResource CtlBtn}" Canvas.Left="172" Canvas.Top="104" Width="32" Height="40" Padding="0" ToolTip="Rear right seat: tap to change the seat heat (off, 1, 2, 3)">
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                  <TextBlock x:Name="SeatRRN" Text="--" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Height="11"><Rectangle x:Name="SeatRRB1" Width="5" Height="5" RadiusX="1.5" RadiusY="1.5" Margin="0,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatRRB2" Width="5" Height="8" RadiusX="1.5" RadiusY="1.5" Margin="2,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/><Rectangle x:Name="SeatRRB3" Width="5" Height="11" RadiusX="1.5" RadiusY="1.5" Margin="2,0,0,0" VerticalAlignment="Bottom" Fill="#FF2E2E2E"/></StackPanel>
                </StackPanel>
              </Button>
              <TextBlock x:Name="WheelCap" Canvas.Left="0" Canvas.Top="20" Width="86" TextAlignment="Right" Text="WHEEL" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/>
              <TextBlock x:Name="WheelLvl" Canvas.Left="0" Canvas.Top="30" Width="86" TextAlignment="Right" Text="--" FontSize="11" FontWeight="Bold" Foreground="#FFE6E6E6"/>
              <TextBlock x:Name="SeatLvlFL" Canvas.Left="0" Canvas.Top="54" Width="86" TextAlignment="Right" Text="--" FontSize="15" FontWeight="Bold" Foreground="#FFE6E6E6"/>
              <TextBlock x:Name="SeatCapFL" Canvas.Left="0" Canvas.Top="74" Width="86" TextAlignment="Right" Text="DRIVER" FontSize="8.5" Foreground="#FF6A6A6A"/>
              <TextBlock x:Name="SeatLvlFR" Canvas.Left="216" Canvas.Top="54" Width="88" Text="--" FontSize="15" FontWeight="Bold" Foreground="#FFE6E6E6"/>
              <TextBlock x:Name="SeatCapFR" Canvas.Left="216" Canvas.Top="74" Width="88" Text="PASSENGER" FontSize="8.5" Foreground="#FF6A6A6A"/>
              <TextBlock x:Name="SeatLvlRL" Canvas.Left="0" Canvas.Top="108" Width="86" TextAlignment="Right" Text="--" FontSize="13" FontWeight="Bold" Foreground="#FFE6E6E6"/>
              <TextBlock x:Name="SeatCapRL" Canvas.Left="0" Canvas.Top="126" Width="86" TextAlignment="Right" Text="REAR LEFT" FontSize="8.5" Foreground="#FF6A6A6A"/>
              <TextBlock x:Name="SeatLvlRR" Canvas.Left="216" Canvas.Top="108" Width="88" Text="--" FontSize="13" FontWeight="Bold" Foreground="#FFE6E6E6"/>
              <TextBlock x:Name="SeatCapRR" Canvas.Left="216" Canvas.Top="126" Width="88" Text="REAR RIGHT" FontSize="8.5" Foreground="#FF6A6A6A"/>
            </Canvas>
          </StackPanel>
        </Border>

        <Border x:Name="TiresCard" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="12,6,12,4" Margin="0,0,0,6">
          <StackPanel>
            <DockPanel LastChildFill="True">
              <Border x:Name="TiresAsOfPill" DockPanel.Dock="Right" CornerRadius="9" Background="#1FFFFFFF" Padding="8,1,8,2" VerticalAlignment="Center">
                <TextBlock x:Name="TiresAsOf" Text="" FontSize="12" FontWeight="SemiBold" Foreground="#FFCCCCCC"/>
              </Border>
              <TextBlock x:Name="TiresHdr" Text="TIRES" FontSize="12.5" FontWeight="Bold" Foreground="#FF9A9A9A" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBlock x:Name="TiresRec" Text="" FontSize="10.5" Foreground="#FF9A9A9A" Margin="0,1,0,0"/>
            <Canvas x:Name="TireCanvas" Width="304" Height="96" Margin="0,2,0,0">
              <Rectangle x:Name="CarBody" Canvas.Left="123" Canvas.Top="2" Width="58" Height="92" RadiusX="20" RadiusY="24"
                         Stroke="#FF6A6A6A" StrokeThickness="1.5" Fill="#FF161616"/>
              <Rectangle x:Name="CarGlassF" Canvas.Left="130" Canvas.Top="22" Width="44" Height="15" RadiusX="6" RadiusY="6" Fill="#FF2A2A2A"/>
              <Rectangle x:Name="CarRoof" Canvas.Left="133" Canvas.Top="39" Width="38" Height="26" RadiusX="4" RadiusY="4" Fill="#FF1E1E1E"/>
              <Rectangle x:Name="CarGlassR" Canvas.Left="132" Canvas.Top="67" Width="40" Height="11" RadiusX="5" RadiusY="5" Fill="#FF2A2A2A"/>
              <Rectangle x:Name="TireFL" Canvas.Left="117" Canvas.Top="11" Width="10" Height="22" RadiusX="3" RadiusY="3" Fill="#FF9A9A9A"/>
              <Rectangle x:Name="TireFR" Canvas.Left="177" Canvas.Top="11" Width="10" Height="22" RadiusX="3" RadiusY="3" Fill="#FF9A9A9A"/>
              <Rectangle x:Name="TireRL" Canvas.Left="117" Canvas.Top="62" Width="10" Height="22" RadiusX="3" RadiusY="3" Fill="#FF9A9A9A"/>
              <Rectangle x:Name="TireRR" Canvas.Left="177" Canvas.Top="62" Width="10" Height="22" RadiusX="3" RadiusY="3" Fill="#FF9A9A9A"/>
              <TextBlock x:Name="PsiFL" Canvas.Left="0" Canvas.Top="7" Width="108" TextAlignment="Right" Text="--" FontSize="17" FontWeight="Bold" Foreground="#FFE6E6E6"/>
              <TextBlock x:Name="CapFL" Canvas.Left="0" Canvas.Top="29" Width="108" TextAlignment="Right" Text="FRONT LEFT · PSI" FontSize="8" Foreground="#FF6A6A6A"/>
              <TextBlock x:Name="PsiFR" Canvas.Left="196" Canvas.Top="7" Width="108" Text="--" FontSize="17" FontWeight="Bold" Foreground="#FFE6E6E6"/>
              <TextBlock x:Name="CapFR" Canvas.Left="196" Canvas.Top="29" Width="108" Text="FRONT RIGHT · PSI" FontSize="8" Foreground="#FF6A6A6A"/>
              <TextBlock x:Name="PsiRL" Canvas.Left="0" Canvas.Top="58" Width="108" TextAlignment="Right" Text="--" FontSize="17" FontWeight="Bold" Foreground="#FFE6E6E6"/>
              <TextBlock x:Name="CapRL" Canvas.Left="0" Canvas.Top="80" Width="108" TextAlignment="Right" Text="REAR LEFT · PSI" FontSize="8" Foreground="#FF6A6A6A"/>
              <TextBlock x:Name="PsiRR" Canvas.Left="196" Canvas.Top="58" Width="108" Text="--" FontSize="17" FontWeight="Bold" Foreground="#FFE6E6E6"/>
              <TextBlock x:Name="CapRR" Canvas.Left="196" Canvas.Top="80" Width="108" Text="REAR RIGHT · PSI" FontSize="8" Foreground="#FF6A6A6A"/>
            </Canvas>
            <Button x:Name="RemindBtn" Style="{StaticResource CtlBtn}" Height="30" Margin="0,2,0,2" Padding="8,2,8,2" ToolTip="Schedule a reminder (email / text) to put air in the tires">
              <TextBlock x:Name="RemindTxt" Text="REMIND ME TO GET AIR" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/>
            </Button>
            <TextBlock x:Name="RemindSetup" Text="Setup: how reminders reach you" FontSize="10.5" FontWeight="SemiBold" Foreground="#FF9A9A9A" HorizontalAlignment="Center"
                       TextDecorations="Underline" Cursor="Hand" Margin="0,1,0,2" ToolTip="Choose how reminders reach you: email, text, Alexa, Windows notification, phone calendar"/>
          </StackPanel>
        </Border>

        <!-- v4.3.3: DRIVES - recent drives + location history (Tessie, read-only) -->
        <Border x:Name="DrivesCard" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="12,6,12,6" Margin="0,0,0,6">
          <StackPanel>
            <DockPanel LastChildFill="True">
              <Border x:Name="DrivesAsOfPill" DockPanel.Dock="Right" CornerRadius="9" Background="#1FFFFFFF" Padding="8,1,8,2" VerticalAlignment="Center">
                <TextBlock x:Name="DrivesAsOf" Text="" FontSize="12" FontWeight="SemiBold" Foreground="#FFCCCCCC"/>
              </Border>
              <TextBlock x:Name="DrivesHdr" Text="DRIVES" FontSize="12.5" FontWeight="Bold" Foreground="#FF9A9A9A" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBlock x:Name="DrivesNote" Text="" FontSize="9.5" Foreground="#FF7A7A7A" Margin="0,1,0,3" TextWrapping="Wrap"/>
            <StackPanel x:Name="DrivesList"/>
            <DockPanel LastChildFill="True" Margin="0,6,0,2">
              <Button x:Name="HistMapBtn" DockPanel.Dock="Right" Style="{StaticResource CtlBtn}" Height="24" Padding="8,0,8,0" ToolTip="Open the recent stops as one route in Google Maps">
                <TextBlock Text="OPEN MAP ›" FontSize="10" FontWeight="Bold"/>
              </Button>
              <TextBlock x:Name="HistHdr" Text="LOCATION HISTORY" FontSize="11" FontWeight="Bold" Foreground="#FF9A9A9A" VerticalAlignment="Center"/>
            </DockPanel>
            <StackPanel x:Name="HistList" Margin="0,2,0,0"/>
          </StackPanel>
        </Border>



        <StackPanel Margin="0,2,0,2">
          <TextBlock x:Name="RateNote" Text="" Foreground="#FF555555" FontSize="9" TextWrapping="Wrap" HorizontalAlignment="Center" TextAlignment="Center"/>
          <TextBlock x:Name="StatusNote" Text="" Foreground="#FF6A6A6A" FontSize="9" Margin="0,2,0,0" TextWrapping="Wrap" HorizontalAlignment="Center" TextAlignment="Center"/>
        </StackPanel>
          </StackPanel>
        </ScrollViewer>

        <StackPanel Grid.Row="5" Margin="0,7,0,0" HorizontalAlignment="Center">
          <Border x:Name="FooterRule" Height="1" Width="120" Background="#FFE82127" HorizontalAlignment="Center" Margin="0,0,0,5"/>
          <TextBlock x:Name="FooterText" FontFamily="Bahnschrift, Impact" FontWeight="Bold" FontStretch="Condensed"
                     FontSize="16" Foreground="#FFE6E6E6" HorizontalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
            <TextBlock x:Name="FooterVersion" Text="" FontSize="9" Foreground="#FF6A6A6A"/>
            <TextBlock x:Name="FooterSep" Text="  ·  " FontSize="9" Foreground="#FF6A6A6A"/>
            <TextBlock x:Name="FooterAbout" Text="About / Privacy" FontSize="9" Foreground="#FF6A6A6A"/>
          </StackPanel>
          <!-- v4.3.11: Restore / Remember look like Paycheck Live's (Segoe UI 9 SemiBold, #FF444444 pill, 4 px corners, 16 px high, hover #FF666666 + white text, Restore first) -->
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,5,0,0">
            <Border x:Name="RestoreBtn" CornerRadius="4" Background="#FF444444" Padding="6,0,6,0" Height="16" Opacity="0.95" Cursor="Hand" VerticalAlignment="Center"
                    ToolTip="Restore TessDesk to its saved size and place">
              <TextBlock x:Name="RestoreTxt" Text="&#x27F2; Restore" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" Foreground="#FFDDDDDD" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <Border x:Name="KeepBtn" CornerRadius="4" Background="#FF444444" Padding="6,0,6,0" Height="16" Opacity="0.95" Margin="3,0,0,0" Cursor="Hand" VerticalAlignment="Center"
                    ToolTip="Remember TessDesk's current size and place (used by Restore and startup)">
              <TextBlock x:Name="KeepTxt" Text="Remember" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" Foreground="#FFDDDDDD" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <!-- v4.3.7: SHARE the TessDesk links (Messenger, text, email, copy, send to phone); never a token, never sent automatically -->
            <Border x:Name="ShareBtn" CornerRadius="8" BorderBrush="#FF49DF93" BorderThickness="1.5" Background="#1A49DF93" Padding="9,1,9,2" Margin="5,0,0,0" Cursor="Hand" VerticalAlignment="Center"
                    ToolTip="SHARE: send the TessDesk phone / download link to someone (only the link, never your token)">
              <TextBlock x:Name="ShareTxt" Text="SHARE" FontSize="9.5" FontWeight="Bold" Foreground="#FFFFFFFF"/>
            </Border>
          </StackPanel>
        </StackPanel>
        <!-- v4.3: toast + confirm box (Confirm / Cancel) -->
        <Border x:Name="WToast" Grid.Row="4" Grid.RowSpan="2" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,46" CornerRadius="10"
                Background="#FF1A1A1A" BorderBrush="#FF49DF93" BorderThickness="1.5" Padding="12,8,12,8" Visibility="Collapsed" MaxWidth="310">
          <TextBlock x:Name="WToastTxt" Text="" FontSize="11.5" FontWeight="SemiBold" Foreground="#FFFFFFFF" TextWrapping="Wrap" TextAlignment="Center"/>
        </Border>
        <Grid x:Name="ConfirmOverlay" Grid.Row="0" Grid.RowSpan="6" Visibility="Collapsed" Background="#B0000000" Margin="-16,-8,-16,-10">
          <Border x:Name="ConfirmBox" Width="292" CornerRadius="14" Background="#FF1A1A1A" BorderBrush="#FF3A3A3A" BorderThickness="1" Padding="16,16,16,14" HorizontalAlignment="Center" VerticalAlignment="Center">
            <StackPanel>
              <TextBlock x:Name="ConfirmMsg" Text="" FontSize="22" FontWeight="Bold" Foreground="#FFFFFFFF" TextWrapping="Wrap" HorizontalAlignment="Center" TextAlignment="Center"/>
              <TextBlock x:Name="ConfirmSub" Text="" FontSize="12" Foreground="#FFCCCCCC" TextWrapping="Wrap" HorizontalAlignment="Center" TextAlignment="Center" Margin="0,5,0,0"/>
              <UniformGrid Columns="2" Rows="1" Margin="0,14,0,0">
                <Button x:Name="ConfirmNo" Style="{StaticResource CtlBtn}" Height="40" Margin="0,0,5,0" IsCancel="False"><TextBlock x:Name="ConfirmNoTxt" Text="Cancel" FontSize="13.5" FontWeight="Bold" HorizontalAlignment="Center"/></Button>
                <Button x:Name="ConfirmYes" Style="{StaticResource CtlBtn}" Height="40" Margin="5,0,0,0"><TextBlock x:Name="ConfirmYesTxt" Text="Confirm" FontSize="13.5" FontWeight="Bold" HorizontalAlignment="Center"/></Button>
              </UniformGrid>
            </StackPanel>
          </Border>
        </Grid>
        <!-- v4.3.7: SHARE panel (links only; nothing is ever sent automatically) -->
        <Grid x:Name="ShareOverlay" Grid.Row="0" Grid.RowSpan="6" Visibility="Collapsed" Background="#B0000000" Margin="-16,-8,-16,-10">
          <Border x:Name="ShareBox" Width="300" CornerRadius="14" Background="#FF1A1A1A" BorderBrush="#FF49DF93" BorderThickness="1.5" Padding="14,14,14,12" HorizontalAlignment="Center" VerticalAlignment="Center">
            <StackPanel>
              <TextBlock x:Name="ShareTitle" Text="SHARE TESSDESK" FontSize="16" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Center"/>
              <TextBlock x:Name="ShareSub" Text="Only the TessDesk links are shared, never your token. Nothing is sent until you press send in the app that opens." FontSize="10.5" Foreground="#FFCCCCCC" TextWrapping="Wrap" TextAlignment="Center" Margin="0,4,0,8"/>
              <UniformGrid Columns="2" Rows="3">
                <Button x:Name="ShMessenger" Style="{StaticResource CtlBtn}" Height="34" Margin="0,0,4,6"><TextBlock Text="MESSENGER" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/></Button>
                <Button x:Name="ShText" Style="{StaticResource CtlBtn}" Height="34" Margin="4,0,0,6"><TextBlock Text="TEXT" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/></Button>
                <Button x:Name="ShEmail" Style="{StaticResource CtlBtn}" Height="34" Margin="0,0,4,6"><TextBlock Text="EMAIL" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/></Button>
                <Button x:Name="ShCopy" Style="{StaticResource CtlBtn}" Height="34" Margin="4,0,0,6"><TextBlock Text="COPY LINK" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/></Button>
                <Button x:Name="ShPhone" Style="{StaticResource CtlBtn}" Height="34" Margin="0,0,4,0"><TextBlock Text="SEND TO PHONE" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/></Button>
                <Button x:Name="ShClose" Style="{StaticResource CtlBtn}" Height="34" Margin="4,0,0,0"><TextBlock Text="CLOSE" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/></Button>
              </UniformGrid>
              <StackPanel x:Name="ShQrBox" Visibility="Collapsed" Margin="0,10,0,0" HorizontalAlignment="Center">
                <Border Background="#FFFFFFFF" CornerRadius="8" Padding="6" HorizontalAlignment="Center"><Image x:Name="ShQr" Width="150" Height="150" RenderOptions.BitmapScalingMode="NearestNeighbor"/></Border>
                <TextBlock x:Name="ShQrTxt" Text="Point your phone's camera here to open TessDesk on your phone: vanwidick.github.io/tessdesk" FontSize="10.5" Foreground="#FFCCCCCC" TextWrapping="Wrap" TextAlignment="Center" Margin="0,6,0,0" MaxWidth="260"/>
              </StackPanel>
            </StackPanel>
          </Border>
        </Grid>
        <!-- v4.3.10: TOTALS pop-up -->
        <Grid x:Name="TotOverlay" Grid.Row="0" Grid.RowSpan="6" Visibility="Collapsed" Background="#B0000000" Margin="-16,-8,-16,-10">
          <Border x:Name="TotBox" Width="330" CornerRadius="14" Background="#FF161616" BorderBrush="#FF49DF93" BorderThickness="1.5" Padding="12,10,8,10" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,10,0,10">
            <DockPanel>
              <DockPanel DockPanel.Dock="Top" Margin="0,0,4,4">
                <Button x:Name="TotClose" DockPanel.Dock="Right" Style="{StaticResource CamBtn}" Width="24" Height="22" Padding="0" Background="Transparent" BorderBrush="Transparent" ToolTip="Close (Esc)">
                  <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="10"/>
                </Button>
                <Button x:Name="TotRefresh" DockPanel.Dock="Right" Style="{StaticResource CamBtn}" Height="22" Padding="7,0,7,0" Margin="0,0,6,0" ToolTip="Load the charge history again from Tessie">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="9.5" VerticalAlignment="Center" Margin="0,0,5,0"/><TextBlock Text="Refresh" FontSize="10.5" VerticalAlignment="Center"/></StackPanel>
                </Button>
                <TextBlock Text="Charging totals" FontSize="14" FontWeight="Bold" Foreground="#FFFFFFFF" VerticalAlignment="Center"/>
              </DockPanel>
              <DockPanel DockPanel.Dock="Top" Margin="0,0,4,6">
                <Button x:Name="TotStop" DockPanel.Dock="Right" Style="{StaticResource CamBtn}" Height="20" Padding="8,0,8,0" Visibility="Collapsed" BorderBrush="#FFE82127" Foreground="#FFFF5A5F" ToolTip="Stop loading">
                  <TextBlock Text="Stop" FontSize="10" FontWeight="Bold"/>
                </Button>
                <TextBlock x:Name="TotStatus" Text="" FontSize="10" Foreground="#FF888888" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </DockPanel>
              <ScrollViewer x:Name="TotScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="TotBody" Margin="0,0,6,0"/>
              </ScrollViewer>
            </DockPanel>
          </Border>
        </Grid>
        <!-- v4.3.9: Camera options (clip source, speed, which clips, default camera, full-screen layout, captures) -->
        <Grid x:Name="CamOptOverlay" Grid.Row="0" Grid.RowSpan="6" Visibility="Collapsed" Background="#B0000000" Margin="-16,-8,-16,-10">
          <Border x:Name="CamOptBox" Width="318" CornerRadius="14" Background="#FF161616" BorderBrush="#FF49DF93" BorderThickness="1.5" Padding="12,10,8,10" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,10,0,10">
            <DockPanel>
              <DockPanel DockPanel.Dock="Top" Margin="0,0,4,6">
                <Button x:Name="CamOptClose" DockPanel.Dock="Right" Style="{StaticResource CamBtn}" Width="24" Height="22" Padding="0" Background="Transparent" BorderBrush="Transparent" ToolTip="Close">
                  <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="10"/>
                </Button>
                <TextBlock Text="Camera options" FontSize="14" FontWeight="Bold" Foreground="#FFFFFFFF" VerticalAlignment="Center"/>
              </DockPanel>
              <ScrollViewer x:Name="CamOptScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="CamOptBody" Margin="0,0,6,0"/>
              </ScrollViewer>
            </DockPanel>
          </Border>
        </Grid>
      </Grid>
    </DockPanel>
    <!-- v4.3.2: whole-window glow. red = not plugged in, green = plugged in, slow green pulse = charging -->
    <Border x:Name="GlowFrame" IsHitTestVisible="False" BorderThickness="2.5" CornerRadius="18" BorderBrush="#FF49DF93">
      <Border.Effect><DropShadowEffect ShadowDepth="0" BlurRadius="26" Color="#FF49DF93" Opacity="1"/></Border.Effect>
      <Border x:Name="GlowInner" BorderThickness="7" CornerRadius="16" BorderBrush="#2E49DF93"/>
    </Border>
   </Grid>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$ui = @{}
foreach ($n in @($xaml.SelectNodes('//*[@*[local-name()="Name"]]'))) {
    $name = $n.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $el = $window.FindName($name); if ($null -ne $el) { $ui[$name] = $el } }
}
try { if (Test-Path -LiteralPath $iconPath) { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath)) } } catch {}

$ui.LoggedIn.Text = 'Logged in as ' + $DisplayName
$ui.FooterVersion.Text = ('v{0} · {1}' -f $AppVersion, $AppDate)
function Get-Spaced { param([string]$s) return (($s.ToCharArray() | ForEach-Object { [string]$_ }) -join [string][char]0x2009) }
try {
    $ui.FooterText.Inlines.Clear()
    $ui.FooterText.Inlines.Add([System.Windows.Documents.Run]::new((Get-Spaced 'DESIGN') + '   ' + (Get-Spaced 'BY') + '   '))
    $script:VanRun = [System.Windows.Documents.Run]::new((Get-Spaced 'VAN'))
    $script:VanRun.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFE82127')
    $ui.FooterText.Inlines.Add($script:VanRun)
} catch { try { $ui.FooterText.Text = 'DESIGN BY VAN' } catch {} }

# ---------------- Themes ----------------
$script:Themes = @{
    tessdesk = @{
        Name = 'TessDesk'; Font = 'Segoe UI'; CardRadius = 10; TileRadius = 8; RootRadius = 10
        RootBg = '#FF0B0B0B'; RootBorder = '#FF333333'; TitleBg = '#FF141414'; Title = '#FFE82127'; LoggedIn = '#FF7A7A7A'
        Text = '#FFFFFFFF'; TextSoft = '#FFCCCCCC'; Caption = '#FF888888'; Caption2 = '#FF666666'; Note = '#FF555555'
        Green = '#FF2ECC40'; Red = '#FFE82127'; Amber = '#FFFFB020'; Grey = '#FF888888'
        CardBg = '#FF111111'; CardBorder = '#FF222222'; TileBg = '#FF151515'; Sep = '#FF222222'
        BarTrack = '#FF2A2A2A'; BallStroke = '#FF0B0B0B'; BallText = '#FF0B0B0B'; ToggleLabel = '#FF8A8A8A'
        CarStroke = '#FF6A6A6A'; CarFill = '#FF161616'; CarGlass = '#FF2A2A2A'; CarRoof = '#FF1E1E1E'; TireOk = '#FF9A9A9A'; Psi = '#FFE6E6E6'
        FooterText = '#FFE6E6E6'; Switch = '#FF3578FF'
        BtnBg = '#FF1C1C1C'; BtnBorder = '#FF2E2E2E'; BtnOn = '#FF3578FF'; ResultBg = '#FF0E0E0E'; Thumb = '#FFFFFFFF'; BtnActive = '#FF243A2C'; SeatOn = '#FFE5383B'
    }
    # TESSIE LOOK while charging: Tessie navy with a slight green lean, #49DF93 accents
    tessie = @{
        Name = 'Tessie'; Font = 'Segoe UI Variable Display, Segoe UI'; CardRadius = 16; TileRadius = 14; RootRadius = 18
        RootBg = '#FF071721'; RootBorder = '#FF1A3540'; TitleBg = '#FF0A1D28'; Title = '#FFE82127'; LoggedIn = '#FFA1B1AD'
        Text = '#FFFFFFFF'; TextSoft = '#FFFAFAFA'; Caption = '#FFA1B1AD'; Caption2 = '#FF7F9A96'; Note = '#FF6F8A88'
        Green = '#FF49DF93'; Red = '#FFEA384C'; Amber = '#FFFFB547'; Grey = '#FFA1B1AD'
        CardBg = '#FF0D2330'; CardBorder = '#FF1A3540'; TileBg = '#FF0D2330'; Sep = '#FF1A3540'
        BarTrack = '#FF1A3540'; BallStroke = '#FF071721'; BallText = '#FF071721'; ToggleLabel = '#FFB4F0D4'
        CarStroke = '#FFB4E6D6'; CarFill = '#FF0D2330'; CarGlass = '#FF1A3540'; CarRoof = '#FF12303A'; TireOk = '#FFC6D3CF'; Psi = '#FFFFFFFF'
        FooterText = '#FFFAFAFA'; Switch = '#FF49DF93'
        BtnBg = '#2649DF93'; BtnBorder = '#FF49DF93'; BtnOn = '#FF3578FF'; ResultBg = '#FF0A1C26'; Thumb = '#FFFFFFFF'; BtnActive = '#5549DF93'; SeatOn = '#FFE5383B'
    }
    # TESSIE LOOK while not charging: same look, red accents and a subtle red-tinted dark background
    tessieIdle = @{
        Name = 'Tessie (idle)'; Font = 'Segoe UI Variable Display, Segoe UI'; CardRadius = 16; TileRadius = 14; RootRadius = 18
        RootBg = '#FF180A0E'; RootBorder = '#FF3D1C23'; TitleBg = '#FF1F0D12'; Title = '#FFE82127'; LoggedIn = '#FFB5A1A5'
        Text = '#FFFFFFFF'; TextSoft = '#FFFAFAFA'; Caption = '#FFB5A1A5'; Caption2 = '#FF9E8086'; Note = '#FF8E6F75'
        Green = '#FF49DF93'; Red = '#FFFF5A5F'; Amber = '#FFFFB547'; Grey = '#FFB5A1A5'
        CardBg = '#FF261117'; CardBorder = '#FF3D1C23'; TileBg = '#FF261117'; Sep = '#FF3D1C23'
        BarTrack = '#FF3D1C23'; BallStroke = '#FF180A0E'; BallText = '#FF180A0E'; ToggleLabel = '#FFF0B4BA'
        CarStroke = '#FFF0B4BA'; CarFill = '#FF261117'; CarGlass = '#FF3D1C23'; CarRoof = '#FF311519'; TireOk = '#FFD3C6C8'; Psi = '#FFFFFFFF'
        FooterText = '#FFFAFAFA'; Switch = '#FFE82127'
        BtnBg = '#2649DF93'; BtnBorder = '#FF49DF93'; BtnOn = '#FF3578FF'; ResultBg = '#FF1F0C11'; Thumb = '#FFFFFFFF'; BtnActive = '#5549DF93'; SeatOn = '#FFE5383B'
    }
}
$script:Brush = [System.Windows.Media.BrushConverter]::new()
function Get-Brush { param([string]$c) return $script:Brush.ConvertFromString($c) }
function T { param([string]$k) return (Get-Brush $script:Theme[$k]) }

function Set-Visible { param($el, [bool]$on) if ($on) { $el.Visibility = 'Visible' } else { $el.Visibility = 'Collapsed' } }

function Apply-Theme {
    param([bool]$Tessie = $true)
    # v4.1: the Tessie look is always on (the toggle is gone): green palette while charging, red-tinted when not.
    if ([bool]$script:ThemeCharging) { $script:Theme = $script:Themes.tessie } else { $script:Theme = $script:Themes.tessieIdle }
    $script:TessieOn = $true
    $th = $script:Theme
    $window.FontFamily = [System.Windows.Media.FontFamily]::new($th.Font)
    $ui.RootBorder.Background = T 'RootBg'; $ui.RootBorder.BorderBrush = T 'RootBorder'
    $ui.RootBorder.CornerRadius = [System.Windows.CornerRadius]::new($th.RootRadius)
    $ui.TitleBar.Background = T 'TitleBg'
    $ui.TitleBar.CornerRadius = [System.Windows.CornerRadius]::new($th.RootRadius, $th.RootRadius, 0, 0)
    $ui.TitleText.Foreground = T 'Title'; $ui.LoggedIn.Foreground = T 'LoggedIn'
    $ui.DateLabel.Foreground = T 'Caption'
    foreach ($n in 'TiresCard', 'RowsCard', 'BattCard', 'CtlCard', 'SeatsCard', 'DrivesCard', 'CamCard') {
        $ui[$n].Background = T 'CardBg'; $ui[$n].BorderBrush = T 'CardBorder'
        $ui[$n].CornerRadius = [System.Windows.CornerRadius]::new($th.CardRadius)
    }
    foreach ($i in 0, 1, 2) {
        $ui['Tile' + $i].Background = T 'TileBg'
        $ui['Tile' + $i].CornerRadius = [System.Windows.CornerRadius]::new($th.TileRadius)
        $ui['TileLbl' + $i].Foreground = T 'Caption'
    }
    foreach ($n in 'RowSep1', 'RowSep2', 'RowSep3') { $ui[$n].Background = T 'Sep' }
    foreach ($n in 'NightLbl', 'D7Lbl', 'D30Lbl') { $ui[$n].Foreground = T 'TextSoft' }
    foreach ($n in 'NightCap', 'D7Cap', 'D30Cap', 'NightKwh', 'D7Kwh', 'D30Kwh') { $ui[$n].Foreground = T 'Caption2' }
    $ui.TiresAsOf.Foreground = T 'TextSoft'; $ui.TiresRec.Foreground = T 'Caption'; $ui.RemindSetup.Foreground = T 'Caption'
    foreach ($n in 'TiresHdr', 'BattHdr', 'CtlHdr', 'SeatsHdr', 'AmpsHdr') { $ui[$n].Foreground = T 'TextSoft' }
    foreach ($n in 'SeatsNote', 'AmpsMinLbl', 'AmpsMaxLbl', 'WheelCap') { $ui[$n].Foreground = T 'Caption' }
    foreach ($n in 'SeatCapFL', 'SeatCapFR', 'SeatCapRL', 'SeatCapRR') { $ui[$n].Foreground = T 'Caption2' }
    $ui.AmpsNow.Foreground = T 'TextSoft'; $ui.AmpsVal.Foreground = T 'Text'; $ui.AmpsTrack.Fill = T 'BarTrack'; $ui.AmpsSep.Background = T 'Sep'
    $ui.AmpsThumb.Background = T 'Thumb'; $ui.AmpsThumb.BorderBrush = T 'RootBg'
    $ui.SeatBody.Stroke = T 'CarStroke'; $ui.SeatBody.Fill = T 'CarFill'; $ui.SeatGlass.Fill = T 'CarGlass'
    $ui.AlexaBox.Background = T 'BtnBg'; $ui.AnnBtn.Foreground = T 'TextSoft'
    foreach ($n in 'D7Cost', 'D30Cost') { $ui[$n].Foreground = T 'Text' }
    foreach ($n in 'CapFL', 'CapFR', 'CapRL', 'CapRR') { $ui[$n].Foreground = T 'Caption2' }
    $ui.CarBody.Stroke = T 'CarStroke'; $ui.CarBody.Fill = T 'CarFill'
    $ui.CarGlassF.Fill = T 'CarGlass'; $ui.CarGlassR.Fill = T 'CarGlass'; $ui.CarRoof.Fill = T 'CarRoof'
    $ui.BarTrack.Fill = T 'BarTrack'; $ui.BarBallDot.Stroke = T 'BallStroke'; $ui.BarBallText.Foreground = T 'BallText'
    $ui.BarStartLbl.Foreground = T 'Text'; $ui.BarLimitLbl.Foreground = T 'Text'
    foreach ($n in 'FromCap', 'LimitCap', 'TempCap', 'BattRangeCap', 'DragCap') { $ui[$n].Foreground = T 'Caption' }
    foreach ($n in 'FromMi', 'LimitMi') { $ui[$n].Foreground = T 'TextSoft' }
    foreach ($n in 'BattPct', 'BattRange', 'DragVal', 'TempVal') { $ui[$n].Foreground = T 'Text' }
    $ui.FromTick.Fill = T 'TextSoft'
    $ui.LimitThumb.Background = T 'Thumb'; $ui.LimitThumb.BorderBrush = T 'RootBg'
    $ui.CtlResultBox.Background = T 'ResultBg'
    $btnR = [System.Windows.CornerRadius]::new([math]::Max(8, $th.TileRadius - 2))
    foreach ($n in 'LockBtn', 'ClimBtn', 'VentBtn', 'CloseWinBtn', 'TempDownBtn', 'TempUpBtn', 'ChgStartBtn', 'ChgStopBtn', 'HeatBtn', 'DefrostBtn', 'CopBtn', 'SeatFL', 'SeatFR', 'SeatRL', 'SeatRC', 'SeatRR', 'WheelBtn', 'FlashBtn', 'TrunkBtn', 'SentryBtn', 'HistMapBtn') {
        $ui[$n].Tag = $btnR; $ui[$n].Background = T 'BtnBg'; $ui[$n].BorderBrush = T 'BtnBorder'; $ui[$n].Foreground = T 'Text'
    }
    $script:BtnR433 = $btnR
    $ui.DrivesAsOf.Foreground = T 'TextSoft'; $ui.DrivesHdr.Foreground = T 'Caption'; $ui.HistHdr.Foreground = T 'Caption'; $ui.DrivesNote.Foreground = T 'Caption'
    foreach ($n in 'LockSub', 'ClimSub', 'VentSub', 'CloseWinSub', 'ChgStartSub', 'ChgStopSub', 'HeatSub', 'DefrostSub', 'CopSub') { $ui[$n].Foreground = T 'Caption' }
    foreach ($i in 0, 1, 2) { $ui['TileSub' + $i].Foreground = T 'Caption' }
    $ui.RateNote.Foreground = T 'Note'; $ui.StatusNote.Foreground = T 'Caption2'
    $ui.FooterText.Foreground = T 'FooterText'; $ui.FooterVersion.Foreground = T 'Caption2'
    $ui.FooterSep.Foreground = T 'Caption2'; $ui.FooterAbout.Foreground = T 'Caption2'
    $ui.RemindBtn.Tag = $btnR; $ui.RemindBtn.Background = T 'BtnBg'; $ui.RemindBtn.BorderBrush = T 'BtnBorder'; $ui.RemindBtn.Foreground = T 'Text'
    foreach ($n in 'AnnNowBtn', 'AnnSetupBtn') { $ui[$n].Tag = $btnR; $ui[$n].Background = T 'BtnBg'; $ui[$n].BorderBrush = T 'BtnBorder'; $ui[$n].Foreground = T 'Text' }
    $ui.AnnNowSub.Foreground = T 'Caption'; $ui.AnnSetupTxt.Foreground = T 'Caption'
    # v4.3.2: green outline on the Alexa pill and the Flash Lights box too; glow follows the window corners
    $ui.AlexaBox.BorderBrush = T 'BtnBorder'; $ui.AlexaBox.BorderThickness = [System.Windows.Thickness]::new(1.5)
    $ui.FlashBox.Background = T 'BtnBg'; $ui.FlashBox.BorderBrush = T 'BtnBorder'; $ui.FlashBox.CornerRadius = $btnR
    $ui.FlashTxt.Foreground = T 'Text'; $ui.FlashCount.BorderBrush = T 'BtnBorder'; $ui.FlashPause.BorderBrush = T 'BtnBorder'
    $ui.GlowFrame.CornerRadius = [System.Windows.CornerRadius]::new($th.RootRadius); $ui.GlowInner.CornerRadius = [System.Windows.CornerRadius]::new([math]::Max(0, $th.RootRadius - 2))
    $script:GlowMode = $null
}

# ---------------- v4.3.2: whole-window glow ----------------
# red = not plugged in · solid green = plugged in, not charging (complete / limit reached / stopped) · slow green pulse = charging
$script:GlowMode = $null; $script:GlowForce = $null
function Get-GlowState {
    $v = $script:View
    if ($null -ne $script:GlowForce) { return [string]$script:GlowForce }
    $cs = ''; try { $cs = [string](Get-ChgState) } catch {}
    if ($cs -eq 'Charging' -or $cs -eq 'Starting') { return 'pulse' }
    if (-not $cs -and $null -ne $v -and $v.accent -eq 'green') { return 'pulse' }
    if ($cs -and $cs -ne 'Disconnected') { return 'green' }
    return 'red'
}
function Set-Glow {
    param([string]$Mode)
    if ($Mode -eq $script:GlowMode) { return }
    $script:GlowMode = $Mode
    $col = $(if ($Mode -eq 'red') { '#FFFF3B47' } else { '#FF49DF93' })
    $b = Get-Brush $col; $c = $b.Color
    $ui.GlowFrame.BorderBrush = $b
    $ui.GlowInner.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(0x2E, $c.R, $c.G, $c.B))
    try { $ui.GlowFrame.Effect.Color = $c } catch {}
    $ui.GlowFrame.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $ui.GlowFrame.Opacity = 1.0
    if ($Mode -eq 'pulse') {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.From = 1.0; $a.To = 0.18; $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(1.75))   # 3.5 s down-and-up cycle
        $a.AutoReverse = $true; $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $e = New-Object System.Windows.Media.Animation.SineEase; $e.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut; $a.EasingFunction = $e
        $ui.GlowFrame.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    }
}

# ---------------- View model ----------------
function Read-LocalJson {
    try {
        if (-not (Test-Path -LiteralPath $jsonPath)) { return $null }
        return (Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { return $null }
}

function Format-Cents { param([double]$UsdPerKwh) return ('{0:N1}¢/kWh' -f ($UsdPerKwh * 100)) }

function New-Bar { param($Start, $Limit, $Current) if ($null -eq $Current) { return $null } return [pscustomobject]@{ start = $Start; limit = $Limit; current = $Current } }

function Get-FriendlyChargeState {
    param([string]$s)
    switch ($s) {
        'Complete'     { return 'Charge complete' }
        'Stopped'      { return 'Charging stopped' }
        'Disconnected' { return 'Unplugged' }
        'NoPower'      { return 'No power' }
        'Starting'     { return 'Starting…' }
        ''             { return ' ' }
        default        { return $s }
    }
}

function Add-CommonRows {
    param($View, $Local)
    $st = $script:State
    $nowE = Get-EpochNow
    $hasHist = ($null -ne $st) -and (@($st.recentSessions).Count -gt 0)
    if ($hasHist -or ($null -ne (Get-CurrentLive $st))) {
        $View.night = Get-NightTotal $st $nowE
        $View | Add-Member -NotePropertyName sessions -NotePropertyValue (Get-WindowSessions $st) -Force
    } else {
        $nw = Get-NightWindow $nowE
        $View.night = [pscustomobject]@{ label = $(if ($nw.inWindow) { 'Tonight' } else { 'Last night' }); caption = 'no data yet'; costUsdAllIn = $null; kwhAdded = $null }
    }
    if ($hasHist) {
        $View.d7 = Get-PeriodTotal $st $nowE 7
        $View.d30 = Get-PeriodTotal $st $nowE 30
        $View.periodSource = 'tessie /charges'
    } elseif ($null -ne $Local -and $null -ne $Local.last7Days) {
        $View.d7 = [pscustomobject]@{ costUsdAllIn = $Local.last7Days.costUsd; kwhAdded = $Local.last7Days.kwh; sessions = $null }
        $View.d30 = [pscustomobject]@{ costUsdAllIn = $Local.last30Days.costUsd; kwhAdded = $Local.last30Days.kwh; sessions = $null }
        $View.periodSource = 'daily json (fallback)'
    }
    $View.rateNote = ('All-in = energy + fuel adder · overnight {0} · {1:N0}% efficiency' -f (Format-Cents ($R_ON + $FCA)), ($EFFICIENCY * 100))
    if ($null -eq $View.tires -and $null -ne $st) { $View.tires = $st.lastTires }
    if ($null -eq $View.car -and $null -ne $st) { $View.car = $st.lastCar }
}

function New-View {
    return [pscustomobject]@{
        mode = 'unknown'; accent = 'grey'; dateLabel = '—'; badge = ''; badgeKind = ''
        hero = '—'; heroSub = ''; kwh = ''; bar = $null; tiles = @(); tires = $null
        night = $null; d7 = $null; d30 = $null; periodSource = ''; rateNote = ''; statusNote = ''; car = $null
    }
}

function Build-LiveView {
    param($s, $car, $tires, $Local, [string]$Note, $Win = $null)
    $v = New-View
    $v.mode = 'live-charging'; $v.accent = 'green'
    $v.dateLabel = 'LIVE · updated ' + (Format-Clock (ConvertFrom-Epoch $s.lastEpoch))
    $v.badge = '● Charging'; $v.badgeKind = 'green'
    $v.hero = Format-Money $s.costUsdAllIn
    $v.heroSub = 'This charge · ' + (Format-Cents ([double]$s.rateNow))
    $v.kwh = (Format-Kwh $s.kwhAdded) + ' added'
    $v.bar = New-Bar $s.socStartPct $s.limitPct $s.socPct
    $kw = '—'; if ($null -ne $s.chargerKw) { $kw = ('{0:0.#} kW' -f [double]$s.chargerKw) }
    $kwSub = ' '
    if ($null -ne $car) {
        if ([bool]$car.fastCharger) { $kwSub = 'DC fast charging' }
        elseif ($null -ne $car.volts -and [double]$car.volts -gt 50 -and $null -ne $car.amps -and [double]$car.amps -gt 0) {
            $kwSub = ('{0:N0} V · {1:N0} A' -f [double]$car.volts, [double]$car.amps)
            if ($null -ne $car.phases -and [int]$car.phases -gt 1) { $kwSub += (' · {0}-phase' -f [int]$car.phases) }
        }
    }
    $tf = Format-Duration $s.minutesToFull; $tfSub = ' '
    if ($null -ne $s.minutesToFull -and [double]$s.minutesToFull -le 0) { $tf = 'Done' }
    elseif ($null -ne $s.minutesToFull) { $tfSub = 'done ~' + (Format-Clock ((ConvertFrom-Epoch $s.lastEpoch).AddMinutes([double]$s.minutesToFull))) }
    $stLocal = ConvertFrom-Epoch $s.startEpoch
    # v4.3.2: tonight's earlier home sessions (unplugged and plugged back in) are part of this one charge
    if ($null -ne $Win -and [bool]$Win.live -and [int]$Win.sessions -gt 1) {
        $v.hero = Format-Money $Win.costUsdAllIn
        $v.heroSub = ('This charge · {0} sessions since {1} · {2}' -f $Win.sessions, (Format-Clock (ConvertFrom-Epoch $Win.startEpoch)), (Format-Cents ([double]$s.rateNow)))
        $v.kwh = (Format-Kwh $Win.kwhAdded) + ' added'
        $v.bar = New-Bar $Win.socStartPct $s.limitPct $s.socPct
        $stLocal = ConvertFrom-Epoch $Win.startEpoch
    }
    $v.tiles = @(@('CHARGING AT', $kw, $kwSub), @('TO FULL', $tf, $tfSub), @('STARTED', (Format-Clock $stLocal), $stLocal.ToString('ddd MMM d', $Inv)))
    $v.tires = $tires; $v.car = $car
    if (-not $Note -and $s.joinedMid) { $Note = 'Joined mid-session: earlier kWh priced at the current rate' }
    $v.statusNote = $Note
    Add-CommonRows $v $Local
    return $v
}

function Build-IdleView {
    param($last, $car, $tires, $Local, [string]$Note)
    $v = New-View
    $v.mode = 'live-idle-last-session'; $v.accent = 'red'
    $v.dateLabel = Format-Range $last.startEpoch $last.endEpoch
    if ($null -ne $car -and $car.chargingState) { $v.badge = [string]$car.chargingState; $v.badgeKind = 'grey' }
    $v.hero = Format-Money $last.costUsdAllIn
    $wall = $null
    if ($null -ne $last.kwhWall -and [double]$last.kwhWall -gt 0) { $wall = [double]$last.kwhWall }
    elseif ($null -ne $last.kwhAdded -and [double]$last.kwhAdded -gt 0) { $wall = [double]$last.kwhAdded / $EFFICIENCY }
    if ($null -ne $wall -and $wall -gt 0 -and $null -ne $last.costUsdAllIn) { $v.heroSub = 'Last charge · ' + (Format-Cents ([double]$last.costUsdAllIn / $wall)) + ' avg' }
    else { $v.heroSub = 'Last charge' }
    if ([string]$last.source -eq 'window' -and [int]$last.sessions -gt 1) { $v.heroSub += (' · {0} sessions' -f $last.sessions) }
    $v.kwh = (Format-Kwh $last.kwhAdded) + ' added'
    $lim = $last.socEndPct; $cur = $last.socEndPct
    if ($null -ne $car) { if ($null -ne $car.limitPct) { $lim = $car.limitPct }; if ($null -ne $car.socPct) { $cur = $car.socPct } }
    $v.bar = New-Bar $last.socStartPct $lim $cur
    $dur = Format-Duration (([int64]$last.endEpoch - [int64]$last.startEpoch) / 60.0)
    $endLocal = ConvertFrom-Epoch $last.endEpoch
    $pSub = ' '; if ($null -ne $car) { $pSub = Get-FriendlyChargeState ([string]$car.chargingState) }
    $durSub = 'last charge'; if ([string]$last.source -eq 'window') { $durSub = $(if ([int]$last.sessions -gt 1) { ('{0} sessions, 11 PM-11 AM' -f $last.sessions) } else { 'overnight charge' }) }
    $v.tiles = @(@('POWER', 'Not charging', $pSub), @('DURATION', $dur, $durSub), @('ENDED', (Format-Clock $endLocal), $endLocal.ToString('ddd MMM d', $Inv)))
    $v.tires = $tires; $v.car = $car
    $v.statusNote = $Note
    Add-CommonRows $v $Local
    return $v
}

function Build-FallbackView {
    param($Local, [string]$Note, [string]$Mode)
    $v = New-View
    $v.mode = $Mode; $v.accent = 'red'; $v.statusNote = $Note
    $o = $null; if ($null -ne $Local) { $o = $Local.overnight }
    $st = $script:State
    $last = $null; if ($null -ne $st) { $last = $st.lastCharge; if ($null -eq $last) { $last = Get-LatestCompleted $st.recentSessions } }
    if ($null -ne $last) {
        $iv = Build-IdleView $last $st.lastCar $st.lastTires $Local $Note
        $iv.mode = $Mode; $iv.badge = ''
        return $iv
    }
    if ($null -ne $o -and ($null -eq $o.charged -or [bool]$o.charged)) {
        $v.dateLabel = [string]$o.label
        $v.hero = Format-Money $o.costUsd
        $v.heroSub = 'Overnight · ' + (Format-Cents ($R_ON + $FCA))
        $v.kwh = Format-Kwh $o.kwh
        $v.bar = New-Bar $o.socStartPct $o.socEndPct $o.socEndPct
        $t1 = '—'; $t2 = '—'
        try { $t1 = Format-Clock ([DateTime]::Parse([string]$o.start, $Inv)) } catch {}
        try { $t2 = Format-Clock ([DateTime]::Parse([string]$o.end, $Inv)) } catch {}
        $v.tiles = @(@('ADDED', (Format-Kwh $o.kwh), ' '), @('STARTED', $t1, ' '), @('ENDED', $t2, ' '))
    } elseif ($null -ne $o) {
        $v.dateLabel = [string]$o.label; $v.hero = '—'; $v.accent = 'grey'; $v.heroSub = 'No charge last night'
        $v.tiles = @(@('POWER', '—', ' '), @('TO FULL', '—', ' '), @('STARTED', '—', ' '))
    } else {
        $v.dateLabel = 'Data unavailable'; $v.hero = '—'; $v.accent = 'grey'; $v.heroSub = 'Waiting for data'
        $v.tiles = @(@('POWER', '—', ' '), @('TO FULL', '—', ' '), @('STARTED', '—', ' '))
    }
    Add-CommonRows $v $Local
    return $v
}

# ---------------- Render ----------------
function Get-AccentKey { param([string]$a) switch ($a) { 'green' { return 'Green' } 'red' { return 'Red' } default { return 'Grey' } } }

$BarX = 13.0; $BarW = 280.0
$BBarX = 13.0; $BBarW = 180.0   # v4.3: battery bar is narrower (vertical limit slider on the right)
function Get-MilesAt {
    param($Pct)
    $car = $null; if ($null -ne $script:View) { $car = $script:View.car }
    if ($null -eq $car -or $null -eq $car.rangeMi -or $null -eq $car.socPct -or [double]$car.socPct -le 0 -or $null -eq $Pct) { return $null }
    return [math]::Round([double]$car.rangeMi / [double]$car.socPct * [double]$Pct)
}
function Format-Miles { param($m) if ($null -eq $m) { return ' ' } return ('{0:N0} mi' -f [double]$m) }
function Get-LimitBounds {
    $car = $null; if ($null -ne $script:View) { $car = $script:View.car }
    $lo = 50; $hi = 100
    if ($null -ne $car) { if ($null -ne $car.limitMin) { $lo = [int]$car.limitMin }; if ($null -ne $car.limitMax) { $hi = [int]$car.limitMax } }
    return @($lo, $hi)
}
function Set-ThumbAt { param([double]$Pct) [System.Windows.Controls.Canvas]::SetLeft($ui.LimitThumb, $BBarX + [math]::Max(0, [math]::Min(100, $Pct)) / 100.0 * $BBarW - 2) }

function Render-Bar {
    param($bar, [string]$AccentKey)
    $acc = T $AccentKey
    $car = $null; if ($null -ne $script:View) { $car = $script:View.car }
    if ($null -eq $bar -or $null -eq $bar.current) {
        $ui.BarFill.Width = 0; $ui.BarFrom.Width = 0; $ui.BarBall.Visibility = 'Collapsed'; $ui.FromTick.Visibility = 'Collapsed'
        $ui.LimitThumb.Visibility = 'Collapsed'; Render-VSlider $null $null
        $ui.BarStartLbl.Text = '--'; $ui.BarLimitLbl.Text = '--'; $ui.FromMi.Text = ' '; $ui.LimitMi.Text = ' '
        $ui.BattPct.Text = '--'; $ui.BattRange.Text = ''; $ui.BattRangeCap.Text = ''; $ui.BattState.Text = ''
        return
    }
    $cur = [double]$bar.current
    $start = $cur; if ($null -ne $bar.start) { $start = [double]$bar.start }
    if ($start -gt $cur) { $start = $cur }
    $limit = $cur; if ($null -ne $bar.limit) { $limit = [double]$bar.limit }
    $ov = Get-CtlValue 'limit' $bar.limit; if ($null -ne $ov) { $limit = [double]$ov }
    $script:BarLimitShown = $limit
    # big % + range (rated/ideal, as the car shows it)
    $ui.BattPct.Text = ('{0:N0}%' -f $cur)
    if ($null -ne $car -and $null -ne $car.rangeMi) {
        $ui.BattRange.Text = ('{0:N0} mi' -f [double]$car.rangeMi)
        $ui.BattRangeCap.Text = $(switch ([string]$car.rangeKind) { 'ideal' { 'IDEAL RANGE' } 'estimated' { 'EST. RANGE' } default { 'RATED RANGE' } })
    } else { $ui.BattRange.Text = ''; $ui.BattRangeCap.Text = '' }
    if ($script:View.accent -eq 'green') { $ui.BattState.Text = ('CHARGING → {0:N0}%' -f $limit); $ui.BattState.Foreground = T 'Green' }
    else { $ui.BattState.Text = ''; if ($null -ne $car) { $ui.BattState.Text = (Get-FriendlyChargeState ([string]$car.chargingState)).ToUpperInvariant() }; $ui.BattState.Foreground = T 'Caption' }
    # 0-100% bar: dim fill up to FROM, bright fill for what this charge added, ball at the current %
    $ui.BarFill.Width = [math]::Max(0.0, $start / 100.0 * $BBarW)
    $ui.BarFill.Fill = $acc; $ui.BarFill.Opacity = 0.45
    [System.Windows.Controls.Canvas]::SetLeft($ui.BarFrom, $BBarX + $start / 100.0 * $BBarW)
    $ui.BarFrom.Width = [math]::Max(0.0, ($cur - $start) / 100.0 * $BBarW)
    $ui.BarFrom.Fill = $acc; $ui.BarFrom.Opacity = 1.0
    $ui.FromTick.Visibility = 'Visible'
    [System.Windows.Controls.Canvas]::SetLeft($ui.FromTick, $BBarX + $start / 100.0 * $BBarW - 1)
    $ui.BarBall.Visibility = 'Visible'
    [System.Windows.Controls.Canvas]::SetLeft($ui.BarBall, $BBarX + $cur / 100.0 * $BBarW - 13)
    $ui.BarBallDot.Fill = $acc
    $ui.BarBallText.Text = ('{0:N0}' -f $cur)
    $ui.LimitThumb.Visibility = 'Visible'
    if (-not $script:Dragging) { Set-ThumbAt $limit }
    $ui.LimitThumb.IsEnabled = ((Test-CmdOn) -and -not $script:CtlBusy)
    # FROM / LIMIT: miles above the percentage
    $ui.BarStartLbl.Text = ('{0:N0}%' -f $start); $ui.FromMi.Text = Format-Miles (Get-MilesAt $start)
    $ui.BarLimitLbl.Text = ('{0:N0}%' -f $limit); $ui.LimitMi.Text = Format-Miles (Get-MilesAt $limit)
    Render-VSlider $limit $acc
}

# Red tires pulse (Opacity animation); paused while a PNG snapshot is taken.
$script:PulseEls = @()
function Set-TirePulse {
    param([bool]$On)
    foreach ($el in @($script:PulseEls)) {
        if ($On) {
            $an = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.25, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(650)))
            $an.AutoReverse = $true; $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $an)
        } else { $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $el.Opacity = 1.0 }
    }
}
function Render-Tires {
    param($t)
    $psiBrush = T 'Psi'
    Set-TirePulse $false; $script:PulseEls = @()
    $script:TireFlags = [ordered]@{}; $script:TireIssues = @()
    foreach ($k in 'fl', 'fr', 'rl', 'rr') {
        $tb = $ui['Psi' + $k.ToUpper()]; $rect = $ui['Tire' + $k.ToUpper()]
        $p = $null; if ($null -ne $t -and $null -ne $t.$k) { $p = [double]$t.$k }
        $rec = $null; if ($null -ne $t) { if ($k -like 'f*') { $rec = $t.recFront } else { $rec = $t.recRear } }
        $soft = $null; $hard = $null; if ($null -ne $t) { $soft = $t.('soft_' + $k); $hard = $t.('hard_' + $k) }
        $st = Get-TireStatus $p $soft $hard $rec
        $script:TireFlags[$k] = $(if ($st.dir) { $st.level + '-' + $st.dir } else { $st.level })
        $tb.Inlines.Clear()
        if ($st.level -eq 'none') { $tb.Inlines.Add([System.Windows.Documents.Run]::new('--')); $tb.Foreground = T 'Caption2'; $rect.Fill = T 'TireOk'; continue }
        $num = [System.Windows.Documents.Run]::new(('{0:N1}' -f $p))
        if ($st.level -eq 'green') { $tb.Inlines.Add($num); $tb.Foreground = $psiBrush; $rect.Fill = T 'Green'; continue }
        $col = $(if ($st.level -eq 'red') { T 'Red' } else { T 'Amber' })
        $w = [System.Windows.Documents.Run]::new($(if ($st.dir -eq 'high') { 'HIGH' } else { 'LOW' }))
        $w.FontSize = 11; $w.FontWeight = 'Bold'
        $sp = [System.Windows.Documents.Run]::new(' ')
        if ($k -like '*l') { $tb.Inlines.Add($w); $tb.Inlines.Add($sp); $tb.Inlines.Add($num) } else { $tb.Inlines.Add($num); $tb.Inlines.Add($sp); $tb.Inlines.Add($w) }
        $tb.Foreground = $col; $rect.Fill = $col
        if ($st.level -eq 'red') { $script:PulseEls += $rect; $script:PulseEls += $tb }
        $script:TireIssues += [pscustomobject]@{ pos = $k.ToUpper(); psi = $p; rec = $rec; level = $st.level; dir = $st.dir }
    }
    Set-TirePulse $true
    $recTxt = ''
    if ($null -ne $t -and $null -ne $t.recFront) {
        if ($null -ne $t.recRear -and [math]::Abs([double]$t.recRear - [double]$t.recFront) -ge 0.5) { $recTxt = ('Recommended {0:N0} PSI front · {1:N0} PSI rear' -f [double]$t.recFront, [double]$t.recRear) }
        else { $recTxt = ('Recommended {0:N0} PSI (all four)' -f [double]$t.recFront) }
    }
    $ui.TiresHdr.Text = 'TIRES'
    $ui.TiresRec.Text = $recTxt; Set-Visible $ui.TiresRec ([bool]$recTxt)
    if ($null -ne $t -and $null -ne $t.asOfEpoch) {
        $a = ConvertFrom-Epoch $t.asOfEpoch
        $ui.TiresAsOf.Text = 'Updated ' + (Format-Clock $a) + ' · ' + $a.ToString('MMM d', $Inv)
    } elseif ($null -eq $t) { $ui.TiresAsOf.Text = 'no data' } else { $ui.TiresAsOf.Text = '' }
    Set-Visible $ui.TiresAsOfPill ([bool]$ui.TiresAsOf.Text)
}

function Get-TextOf { param($tb) return ((@($tb.Inlines | ForEach-Object { $_.Text }) -join '')) }

function Render-View {
    $v = $script:View
    if ($null -eq $v) { return }
    try { Render-Peak } catch { Write-WidgetLog ('peak banner: ' + $_.Exception.Message) }
    try { Render-Drives } catch { Write-WidgetLog ('drives render: ' + $_.Exception.Message) }
    try { Render-Controls43 } catch {}
    $glow = Get-GlowState
    $chg = ($glow -ne 'red')          # v4.3.2: green look whenever plugged in, red look when unplugged
    if ($chg -ne [bool]$script:ThemeCharging) { $script:ThemeCharging = $chg; Apply-Theme $true }
    Set-Glow $glow
    $ak = Get-AccentKey $v.accent
    if ($glow -ne 'red' -and $ak -eq 'Red') { $ak = 'Green' }
    $acc = T $ak
    $ui.DateLabel.Text = [string]$v.dateLabel
    if ($v.badge) {
        $ui.LiveBadge.Text = [string]$v.badge
        if ($v.badgeKind -eq 'green') { $ui.LiveBadge.Foreground = T 'Green' } else { $ui.LiveBadge.Foreground = T 'Caption' }
        Set-Visible $ui.LiveBadge $true
    } else { Set-Visible $ui.LiveBadge $false }
    $ui.HeroCost.Text = [string]$v.hero
    $ui.HeroCost.Foreground = $acc
    $ui.HeroSub.Text = [string]$v.heroSub
    $ui.HeroSub.Foreground = $acc
    $ui.KwhLabel.Text = [string]$v.kwh
    $ui.KwhLabel.Foreground = $acc
    Render-Bar $v.bar $ak
    $tiles = @($v.tiles)
    for ($i = 0; $i -lt 3; $i++) {
        $lbl = '—'; $val = '—'; $sub = ' '
        if ($i -lt $tiles.Count -and $null -ne $tiles[$i]) { $lbl = [string]$tiles[$i][0]; $val = [string]$tiles[$i][1]; if ($tiles[$i].Count -gt 2 -and $tiles[$i][2]) { $sub = [string]$tiles[$i][2] } }
        $ui['TileLbl' + $i].Text = $lbl
        $ui['TileVal' + $i].Text = $val
        $ui['TileSub' + $i].Text = $sub
        $ui['TileVal' + $i].Foreground = $acc
    }
    if ($tiles.Count -gt 0 -and [string]$tiles[0][1] -eq 'Not charging') { $ui.TileVal0.Foreground = T 'TextSoft' }
    Render-Tires $v.tires
    Render-Controls
    if ($null -ne $v.night) {
        $ui.NightLbl.Text = [string]$v.night.label
        $ui.NightCap.Text = [string]$v.night.caption
        $ui.NightCost.Text = Format-Money $v.night.costUsdAllIn
        $ui.NightKwh.Text = Format-Kwh $v.night.kwhAdded
        if ($v.night.inWindow -and $v.accent -eq 'green') { $ui.NightCost.Foreground = T 'Green' } else { $ui.NightCost.Foreground = T 'Text' }
    }
    Render-Sessions $(if ($null -ne $v.PSObject.Properties['sessions']) { $v.sessions } else { $null })
    $cap = 'live from Tessie'; if ($v.periodSource -like 'daily*') { $cap = 'from daily file' }
    if ($null -ne $v.d7) {
        $ui.D7Cost.Text = Format-Money $v.d7.costUsdAllIn; $ui.D7Kwh.Text = Format-Kwh $v.d7.kwhAdded
        $ui.D7Cap.Text = $(if ($null -ne $v.d7.sessions) { ('{0} charges · {1}' -f $v.d7.sessions, $cap) } else { $cap })
    } else { $ui.D7Cost.Text = '$—'; $ui.D7Kwh.Text = '— kWh'; $ui.D7Cap.Text = '' }
    if ($null -ne $v.d30) {
        $ui.D30Cost.Text = Format-Money $v.d30.costUsdAllIn; $ui.D30Kwh.Text = Format-Kwh $v.d30.kwhAdded
        $ui.D30Cap.Text = $(if ($null -ne $v.d30.sessions) { ('{0} charges · {1}' -f $v.d30.sessions, $cap) } else { $cap })
    } else { $ui.D30Cost.Text = '$—'; $ui.D30Kwh.Text = '— kWh'; $ui.D30Cap.Text = '' }
    $ui.RateNote.Text = [string]$v.rateNote
    $ui.StatusNote.Text = [string]$v.statusNote
    Confirm-Fit
}

# ---------------- TESLA CONTROLS ----------------
# Lock/unlock, vent/close windows, climate on/off, cabin temperature, charge limit (slider on the battery bar).
# Unlock, vent and charge-limit changes ask for confirmation first. Every command runs in a background runspace
# (the widget never freezes) with wait_for_completion=true, and the result is shown under the buttons.
# controls.dryRun = true in config.json (and every -SelfTest run) simulates the commands: NOTHING is sent to the car.
$script:CtlBusy = $false
$script:CtlOverride = @{}          # optimistic values after a successful command: key -> @{ v; until }
$script:CtlLog = @()               # recent commands for widget-status.json (no secrets)
$script:CtlResultKind = 'idle'; $script:CtlResultText = 'Ready'
$script:CtlPendingTempC = $null
$script:ConfirmHook = $null        # -SelfTest answers the confirmation prompts itself
$script:ConfirmPrompts = @()
$script:NetCommandsSent = 0
$script:Dragging = $false; $script:DragPct = $null
$ChangelogUrl = 'https://vanwidick.github.io/tessdesk/changelog.html'
$PrivacyUrl = 'https://vanwidick.github.io/tessdesk/privacy.html'
$ConsentVersion = '4.1'
$HelpLinks = @(
    @('Sign up for Tessie', 'https://www.tessie.com', 'No Tessie account? Tessie is a paid service that connects to your Tesla.'),
    @('Get your Tessie API token', 'https://dash.tessie.com/settings/api', 'After signing up: Tessie app → Settings → API (or this page on the web).'),
    @('Create a Gmail account', 'https://accounts.google.com/signup', 'No Gmail? Free; used only to send your own reminders.'),
    @('Turn on 2-Step Verification', 'https://myaccount.google.com/signinoptions/two-step-verification', 'Google requires it before you can make an App Password.'),
    @('Make a Gmail App Password', 'https://myaccount.google.com/apppasswords', 'A 16-letter password just for TessDesk reminders.'),
    @('How App Passwords work', 'https://support.google.com/accounts/answer/185833', 'Google help article.')
)
$NoticeText = @"
TessDesk is an unofficial app. It is not made by, affiliated with, or endorsed by Tesla or Tessie.

• It uses your Tessie API token to READ vehicle data (location, battery, charging, tires, lock and climate state) and, only when you press a control, to SEND commands (lock/unlock, windows, climate, charge limit).
• Your token and settings are stored only on this PC (the token is protected with Windows DPAPI) and are sent only to api.tessie.com.
• Reminders are sent through your own email account or your carrier's email-to-text gateway. Nothing goes to the TessDesk author.
• Costs shown are estimates based on the rates you enter, not your utility bill.
• Commands can wake the car and use a little battery. Use the controls only when it is safe and legal.
• No warranty. You use TessDesk at your own risk. Tessie's Terms of Service apply to your Tessie account and token.
• To revoke access: delete the API token in the Tessie app (Settings → API). To uninstall: double-click "Uninstall TessDesk.cmd" in the TessDesk folder (it also removes TessDesk reminder tasks).
"@

function Set-ConsentVars {
    $cs = $script:Consent
    $ok = ($null -ne $cs -and $cs.agreedAt -and [bool]$cs.agreed)
    $script:ReadAllowed = ($ok -and [bool]$cs.readVehicleData)
    $script:CmdAllowed = ($ok -and [bool]$cs.sendCommands)
    $script:RemAllowed = ($ok -and [bool]$cs.reminders)
}
$script:ConsentAssumed = $false
Set-ConsentVars
if ($SelfTest -and -not $script:ReadAllowed) {
    # Self-test only: in-memory consent so the test can run; nothing is written to config.json.
    $script:Consent = [pscustomobject]@{ version = $ConsentVersion; agreed = $true; agreedAt = 'selftest'; readVehicleData = $true; sendCommands = $true; reminders = $true; announcements = $true }
    $script:ConsentAssumed = $true; Set-ConsentVars
}
function Test-CmdOn { return ($CTL_ENABLED -and [bool]$script:CmdAllowed) }

function Save-ConfigProp {
    param([string]$Name, $Value)
    $raw = $null
    if (Test-Path -LiteralPath $ConfigPath) { $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    if ($null -eq $raw) { $raw = [pscustomobject]@{} }
    $raw | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    $raw | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function New-HelpPanel {
    # "Getting started / Don't have these yet?" small link buttons, one line each.
    $sp = New-Object System.Windows.Controls.StackPanel
    $h = New-Object System.Windows.Controls.TextBlock; $h.Text = "GETTING STARTED · DON'T HAVE THESE YET?"; $h.FontSize = 10.5; $h.FontWeight = 'Bold'; $h.Foreground = T 'Caption'; $h.Margin = '0,0,0,4'
    [void]$sp.Children.Add($h)
    foreach ($l in $HelpLinks) {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,2,0,2'
        $b = New-Object System.Windows.Controls.Button; $b.Content = $l[0]; $b.FontSize = 11; $b.Padding = '8,2,8,2'; $b.Width = 168; $b.HorizontalContentAlignment = 'Left'
        $b.Tag = $l[1]; $b.ToolTip = $l[1]; $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.Add_Click({ param($s2, $e2) if (-not $SelfTest) { try { Start-Process ([string]$s2.Tag) } catch {} } })
        [System.Windows.Controls.DockPanel]::SetDock($b, 'Left'); [void]$row.Children.Add($b)
        $d = New-Object System.Windows.Controls.TextBlock; $d.Text = $l[2]; $d.FontSize = 10.5; $d.TextWrapping = 'Wrap'; $d.Margin = '8,0,0,0'; $d.VerticalAlignment = 'Center'; $d.Foreground = T 'TextSoft'
        [void]$row.Children.Add($d); [void]$sp.Children.Add($row)
    }
    return $sp
}

# Notice + permissions window. First run (no consent in config.json): no Tessie calls until "I agree" + read permission.
# Also opened from the footer's "About / Privacy" (right-click) to review or change permissions.
function Show-ConsentWindow {
    param([bool]$FirstRun = $true)
    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'TessDesk · Notice, privacy and permissions'; $dlg.Width = 560; $dlg.SizeToContent = 'Height'; $dlg.MaxHeight = 1000
    $dlg.WindowStartupLocation = 'CenterScreen'; $dlg.ResizeMode = 'NoResize'; $dlg.Background = T 'RootBg'; $dlg.Foreground = T 'Text'
    $dlg.FontFamily = $window.FontFamily
    try { if (Test-Path -LiteralPath $iconPath) { $dlg.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) } } catch {}
    $root = New-Object System.Windows.Controls.StackPanel; $root.Margin = '18,14,18,14'
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = 'Before TessDesk connects to your car'; $t.FontSize = 17; $t.FontWeight = 'Bold'; $t.Margin = '0,0,0,8'; [void]$root.Children.Add($t)
    $sv = New-Object System.Windows.Controls.ScrollViewer; $sv.MaxHeight = 330; $sv.VerticalScrollBarVisibility = 'Auto'
    $nt = New-Object System.Windows.Controls.TextBlock; $nt.Text = $NoticeText; $nt.TextWrapping = 'Wrap'; $nt.FontSize = 12; $nt.Foreground = T 'TextSoft'
    $sv.Content = $nt; [void]$root.Children.Add($sv)
    $cur = $script:Consent
    $mk = { param($txt, $chk) $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = $txt; $cb.Foreground = T 'Text'; $cb.FontSize = 12.5; $cb.Margin = '0,6,0,0'; $cb.IsChecked = $chk; return $cb }
    $cbAgree = & $mk 'I have read this notice and I agree' ($null -ne $cur -and [bool]$cur.agreed -and -not $FirstRun)
    $cbAgree.FontWeight = 'Bold'; $cbAgree.Margin = '0,12,0,4'
    $cbRead = & $mk 'Allow TessDesk to read vehicle data from Tessie (required)' $true
    $cbCmd = & $mk 'Allow TessDesk to send vehicle commands (optional; off = controls disabled)' $(if ($null -ne $cur) { [bool]$cur.sendCommands } else { $true })
    $cbRem = & $mk 'Allow reminders by email/text (optional)' $(if ($null -ne $cur) { [bool]$cur.reminders } else { $true })
    foreach ($x in $cbAgree, $cbRead, $cbCmd, $cbRem) { [void]$root.Children.Add($x) }
    $hp = New-HelpPanel; $hp.Margin = '0,14,0,0'; [void]$root.Children.Add($hp)
    $links = New-Object System.Windows.Controls.TextBlock; $links.Margin = '0,10,0,0'; $links.FontSize = 11
    $hl = New-Object System.Windows.Documents.Hyperlink; [void]$hl.Inlines.Add('Full privacy page'); $hl.NavigateUri = [Uri]$PrivacyUrl; $hl.Foreground = T 'Green'
    $hl.Add_RequestNavigate({ param($s3, $e3) if (-not $SelfTest) { try { Start-Process $e3.Uri.AbsoluteUri } catch {} } })
    [void]$links.Inlines.Add($hl); [void]$links.Inlines.Add('   ·   Local copy: PRIVACY.md in the TessDesk folder'); $links.Foreground = T 'Caption'
    [void]$root.Children.Add($links)
    $bp = New-Object System.Windows.Controls.StackPanel; $bp.Orientation = 'Horizontal'; $bp.HorizontalAlignment = 'Right'; $bp.Margin = '0,14,0,0'
    $bCancel = New-Object System.Windows.Controls.Button; $bCancel.Content = $(if ($FirstRun) { 'Not now' } else { 'Cancel' }); $bCancel.Padding = '14,4,14,4'; $bCancel.Margin = '0,0,8,0'
    $bOk = New-Object System.Windows.Controls.Button; $bOk.Content = 'Continue'; $bOk.Padding = '18,4,18,4'; $bOk.FontWeight = 'Bold'
    [void]$bp.Children.Add($bCancel); [void]$bp.Children.Add($bOk); [void]$root.Children.Add($bp)
    $script:Dlg = @{ dlg = $dlg; ok = $bOk; agree = $cbAgree; read = $cbRead; cmd = $cbCmd; rem = $cbRem }
    $upd = { $script:Dlg.ok.IsEnabled = ([bool]$script:Dlg.agree.IsChecked -and [bool]$script:Dlg.read.IsChecked) }
    $cbAgree.Add_Click($upd); $cbRead.Add_Click($upd); & $upd
    $script:ConsentResult = $null
    $bCancel.Add_Click({ $script:Dlg.dlg.Close() })
    $bOk.Add_Click({
        $script:ConsentResult = [ordered]@{ version = $ConsentVersion; agreed = $true; agreedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); via = 'widget'
            readVehicleData = [bool]$script:Dlg.read.IsChecked; sendCommands = [bool]$script:Dlg.cmd.IsChecked; reminders = [bool]$script:Dlg.rem.IsChecked
            announcements = ($null -ne $script:Consent -and [bool]$script:Consent.announcements) }
        $script:Dlg.dlg.Close()
    })
    $dlg.Content = $root
    try { $dlg.Owner = $window } catch {}
    [void]$dlg.ShowDialog()
    if ($null -ne $script:ConsentResult) {
        try { Save-ConfigProp 'consent' $script:ConsentResult } catch { Write-WidgetLog ('consent save failed: ' + $_.Exception.Message) }
        $script:Consent = [pscustomobject]$script:ConsentResult; Set-ConsentVars
        Write-WidgetLog ('consent saved: read={0} commands={1} reminders={2}' -f $script:ReadAllowed, $script:CmdAllowed, $script:RemAllowed)
        Update-Ui
    }
}

# ---------------- Tire reminder ("Remind me to get air") ----------------
$RemindScript = Join-Path $scriptDir 'TessDesk-Remind.ps1'
$RemDir = Join-Path $scriptDir 'reminders'
$script:RemScheduled = @()
# v4.2: reminder delivery channels (config.json reminders.channels): email, text, alexa, toast, calendar.
# Older configs only have reminders.channel = email | text | both; that still works.
$RemChannelNames = [ordered]@{ email = 'Email'; text = 'Text message'; alexa = 'Alexa announcement'; toast = 'Windows notification'; calendar = 'Phone calendar alert' }
function Get-RemChannels {
    $r = $script:RemCfg; if ($null -eq $r) { return @() }
    if ($null -ne $r.channels) { return @($r.channels | ForEach-Object { [string]$_ } | Where-Object { $RemChannelNames.Contains($_) }) }
    if (-not [bool]$r.enabled) { return @() }
    switch ([string]$r.channel) { 'email' { return @('email') } 'text' { return @('text') } 'both' { return @('email', 'text') } default { return @() } }
}
function Test-RemSmtp { $r = $script:RemCfg; return ($null -ne $r -and $null -ne $r.smtp -and [bool]$r.smtp.user -and (Test-Path -LiteralPath (Join-Path $scriptDir $(if ($r.smtpSecretFile) { [string]$r.smtpSecretFile } else { 'smtp.secret' })))) }
function Test-RemChanReady {
    param([string]$Ch)
    $r = $script:RemCfg
    switch ($Ch) {
        'email' { return ([bool]$script:RemAllowed -and $null -ne $r -and [bool]$r.email -and (Test-RemSmtp)) }
        'text' { return ([bool]$script:RemAllowed -and $null -ne $r -and [bool]$r.phone -and [bool]$r.carrierGateway -and (Test-RemSmtp)) }
        'alexa' { return (Test-AnnReady) }
        'toast' { return $true }
        'calendar' { return $true }
    }
    return $false
}
function Test-RemChan { param([string]$Ch) return ((@(Get-RemChannels) -contains $Ch) -and (Test-RemChanReady $Ch)) }
function Test-RemindersReady { foreach ($c in @(Get-RemChannels)) { if (Test-RemChanReady $c) { return $true } }; return $false }
function Get-ChannelText {
    $r = $script:RemCfg; $p = @()
    foreach ($c in @(Get-RemChannels)) {
        if (-not (Test-RemChanReady $c)) { continue }
        switch ($c) {
            'email' { $p += ('an email to ' + $r.email) }
            'text' { $p += ('a text to {0} (via {1})' -f $r.phone, $r.carrierGateway) }
            'alexa' { $p += ('an Alexa announcement on ' + (Get-VmDevice)) }
            'toast' { $p += 'a Windows notification on this PC' }
            'calendar' { $p += 'a phone calendar alert (Google Calendar / .ics)' }
        }
    }
    if ($p.Count -eq 0) { return 'nothing (no delivery set up)' }
    if ($p.Count -eq 1) { return $p[0] }
    return ((($p | Select-Object -First ($p.Count - 1)) -join ', ') + ' and ' + $p[-1])
}
function Get-ReminderSpeech {
    $issues = @($script:TireIssues)
    if ($issues.Count -gt 0) { return ('Reminder: get air in your tires. ' + (($issues | ForEach-Object { ('{0} is {1:N0} PSI' -f ($_.pos -replace 'FL', 'front left' -replace 'FR', 'front right' -replace 'RL', 'rear left' -replace 'RR', 'rear right'), $_.psi) }) -join ', ') + '.') }
    return 'Reminder: check your tire pressure.'
}
function New-ReminderIcs {
    # calendar alert at $Due: saves reminders\<id>.ics and returns a Google Calendar link (opens in the browser; syncs to the phone)
    param($Id, [datetime]$Due, $Msg)
    $u = $Due.ToUniversalTime(); $e = $u.AddMinutes(15); $f = 'yyyyMMdd\THHmmss\Z'
    $desc = ([string]$Msg.body) -replace '\\', '\\' -replace ';', '\;' -replace ',', '\,' -replace "`r?`n", '\n'
    $ics = "BEGIN:VCALENDAR`r`nVERSION:2.0`r`nPRODID:-//TessDesk//Tire reminder//EN`r`nBEGIN:VEVENT`r`nUID:tessdesk-$Id@tessdesk`r`nDTSTAMP:" + (Get-Date).ToUniversalTime().ToString($f) +
        "`r`nDTSTART:" + $u.ToString($f) + "`r`nDTEND:" + $e.ToString($f) + "`r`nSUMMARY:" + $Msg.subject + "`r`nDESCRIPTION:" + $desc +
        "`r`nBEGIN:VALARM`r`nACTION:DISPLAY`r`nDESCRIPTION:" + $Msg.subject + "`r`nTRIGGER:PT0M`r`nEND:VALARM`r`nEND:VEVENT`r`nEND:VCALENDAR`r`n"
    if (-not (Test-Path -LiteralPath $RemDir)) { New-Item -ItemType Directory -Path $RemDir -Force | Out-Null }
    $p = Join-Path $RemDir ($Id + '.ics'); [IO.File]::WriteAllText($p, $ics, [Text.UTF8Encoding]::new($false))
    $g = 'https://calendar.google.com/calendar/render?action=TEMPLATE&text=' + [uri]::EscapeDataString($Msg.subject) + '&dates=' + $u.ToString($f) + '/' + $e.ToString($f) + '&details=' + [uri]::EscapeDataString([string]$Msg.body)
    return [pscustomobject]@{ ics = $p; gcal = $g }
}
$script:RemSetupHook = $null   # self-test: hashtable of channel -> bool instead of showing the window
function Save-RemChannels {
    param([string[]]$Channels)
    $raw = $null; if (Test-Path -LiteralPath $ConfigPath) { $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    $o = [ordered]@{}; if ($null -ne $raw -and $null -ne $raw.reminders) { foreach ($p in $raw.reminders.PSObject.Properties) { $o[$p.Name] = $p.Value } }
    $o['channels'] = @($Channels); $o['enabled'] = ($Channels.Count -gt 0)
    Save-ConfigProp 'reminders' $o
    $script:RemCfg = (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json).reminders
    Write-WidgetLog ('reminder channels saved: ' + ($Channels -join ','))
}
function Show-ReminderSetup {
    if ($null -ne $script:RemSetupHook) { $pick = @($script:RemSetupHook.Keys | Where-Object { $script:RemSetupHook[$_] -and (Test-RemChanReady $_) }); Save-RemChannels $pick; return $pick }
    $r = $script:RemCfg; $cur = @(Get-RemChannels)
    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'TessDesk · How reminders reach you'; $dlg.Width = 520; $dlg.SizeToContent = 'Height'; $dlg.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height - 40; $dlg.ResizeMode = 'NoResize'
    $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.Background = T 'RootBg'; $dlg.Foreground = T 'Text'; $dlg.FontFamily = $window.FontFamily
    $sv = New-Object System.Windows.Controls.ScrollViewer; $sv.VerticalScrollBarVisibility = 'Auto'
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '18,14,18,14'; $sv.Content = $sp
    $h = New-Object System.Windows.Controls.TextBlock; $h.Text = 'How should "Remind me to get air" reach you?'; $h.FontSize = 16; $h.FontWeight = 'Bold'; $h.TextWrapping = 'Wrap'; [void]$sp.Children.Add($h)
    $sub = New-Object System.Windows.Controls.TextBlock; $sub.Text = 'Pick one or more. Reminders are sent by Windows Task Scheduler at the time you choose, even if TessDesk is closed (you must be signed in to Windows).'; $sub.TextWrapping = 'Wrap'; $sub.FontSize = 11.5; $sub.Foreground = T 'Caption'; $sub.Margin = '0,4,0,8'; [void]$sp.Children.Add($sub)
    $smtpOk = Test-RemSmtp
    $vmDev = Get-VmDevice
    $rows = @(
        @('email', 'Email', $(if (Test-RemChanReady 'email') { 'To ' + $r.email + ', sent from your own email account (' + $r.smtp.user + '). The most reliable choice.' } elseif (-not [bool]$script:RemAllowed) { 'Not allowed: you turned off reminders by email/text in the TessDesk notice. Run TessDesk-Setup.cmd to change it.' } else { 'Not set up: run TessDesk-Setup.cmd → 5. TIRE REMINDERS (your email address, plus your own Gmail with an App Password to send from).' })),
        @('text', 'Text message', ($(if (Test-RemChanReady 'text') { 'To ' + $r.phone + ' via ' + $r.carrierGateway + '. ' } elseif ($smtpOk) { 'Not set up: add your phone number + carrier in TessDesk-Setup.cmd → 5. TIRE REMINDERS. ' } else { 'Not set up: needs your phone + carrier and your own email account in TessDesk-Setup.cmd → 5. TIRE REMINDERS. ' }) + 'Honest note: this uses your carrier''s email-to-text gateway. AT&T shut its gateway down in June 2025, T-Mobile''s is unreliable, and Verizon''s works until March 2027. Email, Alexa or a Windows notification is more reliable.')),
        @('alexa', 'Alexa announcement', $(if (Test-RemChanReady 'alexa') { 'Your Echo (' + $vmDev + ') speaks the reminder through Voice Monkey.' } else { 'Not set up: add your Voice Monkey token and speaker (clock button in the title bar → Connected apps) and accept the announcement disclosure.' })),
        @('toast', 'Windows notification', 'A notification pops up on this PC at that time (Action Center keeps it if you miss it). Works right away, nothing to set up.'),
        @('calendar', 'Phone calendar alert', 'When you set a reminder, TessDesk opens Google Calendar with the event and alert filled in (tap Save; it syncs to your phone) and saves an .ics file in the TessDesk\reminders folder you can open on any calendar.')
    )
    $boxes = @{}
    foreach ($row in $rows) {
        $b = New-Object System.Windows.Controls.Border; $b.CornerRadius = 10; $b.Background = T 'CardBg'; $b.BorderBrush = T 'CardBorder'; $b.BorderThickness = 1; $b.Padding = '10,7,10,8'; $b.Margin = '0,4,0,4'
        $st = New-Object System.Windows.Controls.StackPanel
        $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = $row[1]; $cb.FontSize = 13.5; $cb.FontWeight = 'Bold'; $cb.Foreground = T 'Text'
        $ok = Test-RemChanReady $row[0]; $cb.IsEnabled = $ok; $cb.IsChecked = ($ok -and ($cur -contains $row[0]))
        $boxes[$row[0]] = $cb; [void]$st.Children.Add($cb)
        $d = New-Object System.Windows.Controls.TextBlock; $d.Text = $row[2]; $d.TextWrapping = 'Wrap'; $d.FontSize = 11.5; $d.Margin = '22,2,0,0'; $d.Foreground = $(if ($ok) { T 'Caption' } else { T 'Amber' }); [void]$st.Children.Add($d)
        $b.Child = $st; [void]$sp.Children.Add($b)
    }
    $tn = New-Object System.Windows.Controls.TextBlock; $tn.TextWrapping = 'Wrap'; $tn.FontSize = 11.5; $tn.Margin = '0,8,0,0'; $tn.Foreground = T 'Caption'
    $tn.Text = "Tessie app / car screen: not possible from TessDesk. Tessie's API has no way to send a notification to the Tessie app or a text message to the car's screen (its ""share"" command only sends an address or a video link to the car's navigation). For Tessie's own alerts: Tessie app → Notifications (the bell, top right) → turn on Low tire pressure."
    [void]$sp.Children.Add($tn)
    $msg = New-Object System.Windows.Controls.TextBlock; $msg.TextWrapping = 'Wrap'; $msg.FontSize = 11.5; $msg.Margin = '0,8,0,0'; [void]$sp.Children.Add($msg)
    $btns = New-Object System.Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'; $btns.HorizontalAlignment = 'Right'; $btns.Margin = '0,10,0,0'
    $script:RemSetupUi = @{ dlg = $dlg; boxes = $boxes; msg = $msg }
    $bt = New-Object System.Windows.Controls.Button; $bt.Content = 'Send test'; $bt.Padding = '12,4,12,4'; $bt.Margin = '0,0,8,0'
    $bt.Add_Click({
        try {
            $u = $script:RemSetupUi; $pick = @($u.boxes.Keys | Where-Object { [bool]$u.boxes[$_].IsChecked -and $_ -ne 'calendar' })
            if ($pick.Count -eq 0) { $u.msg.Text = 'Tick email, text, Alexa or Windows notification to test.'; return }
            Save-RemChannels @($u.boxes.Keys | Where-Object { [bool]$u.boxes[$_].IsChecked })
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $RemindScript, '-Test', '-ConfigPath', $ConfigPath); if ($REM_DRYRUN) { $a += '-DryRun' }
            Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden
            $u.msg.Foreground = T 'Green'; $u.msg.Text = ('Test sent to: ' + (($pick | ForEach-Object { $RemChannelNames[$_] }) -join ', ') + $(if ($REM_DRYRUN) { ' (DRY RUN: written to reminders.log only)' } else { '. Results go to reminders.log.' }))
        } catch { $script:RemSetupUi.msg.Foreground = T 'Amber'; $script:RemSetupUi.msg.Text = 'Test failed: ' + $_.Exception.Message }
    })
    $bs = New-Object System.Windows.Controls.Button; $bs.Content = 'Save'; $bs.Padding = '16,4,16,4'; $bs.Margin = '0,0,8,0'; $bs.FontWeight = 'Bold'
    $bs.Add_Click({ $u = $script:RemSetupUi; Save-RemChannels @($u.boxes.Keys | Where-Object { [bool]$u.boxes[$_].IsChecked }); $u.dlg.Close() })
    $bc = New-Object System.Windows.Controls.Button; $bc.Content = 'Close'; $bc.Padding = '12,4,12,4'; $bc.Add_Click({ $script:RemSetupUi.dlg.Close() })
    [void]$btns.Children.Add($bt); [void]$btns.Children.Add($bs); [void]$btns.Children.Add($bc); [void]$sp.Children.Add($btns)
    $dlg.Content = $sv; try { $dlg.Owner = $window } catch {}
    [void]$dlg.ShowDialog()
}

function Get-ReminderMessage {
    $issues = @($script:TireIssues)
    $t = $null; if ($null -ne $script:View) { $t = $script:View.tires }
    $lines = @(); $short = @()
    if ($issues.Count -gt 0) {
        foreach ($i in $issues) {
            $lv = $(if ($i.level -eq 'red') { 'really ' + $i.dir.ToUpper() } else { 'a little ' + $i.dir.ToUpper() })
            $lines += ('{0}: {1:N1} PSI ({2}{3})' -f $i.pos, $i.psi, $lv, $(if ($null -ne $i.rec) { (', recommended {0:N0}' -f $i.rec) } else { '' }))
            $short += ('{0} {1:N1}' -f $i.pos, $i.psi)
        }
        $subj = 'TessDesk: get air in your tires (' + (($issues | ForEach-Object { $_.pos }) -join ', ') + ')'
    } else {
        foreach ($k in 'fl', 'fr', 'rl', 'rr') { if ($null -ne $t -and $null -ne $t.$k) { $lines += ('{0}: {1:N1} PSI' -f $k.ToUpper(), [double]$t.$k); $short += ('{0} {1:N1}' -f $k.ToUpper(), [double]$t.$k) } }
        $subj = 'TessDesk: check your tire pressure'
    }
    $rec = ''; if ($null -ne $t -and $null -ne $t.recFront) { $rec = ('Recommended: {0:N0} PSI front / {1:N0} PSI rear (cold).' -f $t.recFront, $(if ($null -ne $t.recRear) { $t.recRear } else { $t.recFront })) }
    $asOf = ''; try { $asOf = $ui.TiresAsOf.Text } catch {}
    $body = "Reminder from TessDesk: get air in your tires.`r`n`r`n" + ($lines -join "`r`n") + "`r`n" + $rec + "`r`n(Tire readings: " + $asOf + ".)`r`n`r`nSent by your TessDesk widget."
    $sms = 'TessDesk: get air - ' + ($short -join ', ') + ' PSI' + $(if ($null -ne $t -and $null -ne $t.recFront) { (' (rec {0:N0})' -f $t.recFront) } else { '' })
    return [pscustomobject]@{ subject = $subj; body = $body; sms = $sms; lines = $lines }
}
function New-TireReminder {
    param([double]$Hours, [bool]$DryRunTask = $false)
    if (-not (Test-Path -LiteralPath $RemindScript)) { throw 'TessDesk-Remind.ps1 is missing from the TessDesk folder' }
    if (-not (Test-Path -LiteralPath $RemDir)) { New-Item -ItemType Directory -Path $RemDir -Force | Out-Null }
    $due = (Get-Date).AddMinutes([math]::Round($Hours * 60))
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $m = Get-ReminderMessage
    $job = [ordered]@{ id = $id; createdAt = (Get-Date).ToString('s'); dueAt = $due.ToString('s'); hours = $Hours; subject = $m.subject; body = $m.body; sms = $m.sms; speech = (Get-ReminderSpeech); channels = @(Get-RemChannels); dryRun = ($DryRunTask -or $REM_DRYRUN) }
    $jp = Join-Path $RemDir ($id + '.json')
    $job | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jp -Encoding UTF8
    $name = 'TessDesk Reminder ' + $id
    $arg = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Id {1}' -f $RemindScript, $id)
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $scriptDir
    $trg = New-ScheduledTaskTrigger -Once -At $due
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $pr = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Settings $set -Principal $pr -Description ('TessDesk tire reminder (one-time). Install: ' + $scriptDir) -Force | Out-Null
    $script:RemScheduled += [ordered]@{ id = $id; task = $name; dueAt = $due.ToString('s'); dryRun = $job.dryRun }
    Write-WidgetLog ('reminder scheduled {0} for {1} dryRun={2}' -f $id, $due.ToString('s'), $job.dryRun)
    return [pscustomobject]@{ id = $id; task = $name; due = $due; json = $jp; message = $m }
}
$script:RemindHook = $null   # self-test: returns hours (or $null) instead of showing the dialog
function Request-TireReminder {
    if (-not (Test-RemindersReady)) {
        $msg = 'No reminder delivery is turned on yet. Open "Setup: how reminders reach you" under the button and pick at least one: email, text, Alexa, Windows notification (works right away) or a phone calendar alert.'
        if ($null -ne $script:RemindHook) { $script:RemindLastNote = $msg; return $null }
        [void][System.Windows.MessageBox]::Show($window, $msg, 'TessDesk · Remind me to get air', 'OK', 'Information'); Show-ReminderSetup; return $null
    }
    $m = Get-ReminderMessage
    $hours = $null
    if ($null -ne $script:RemindHook) { $hours = & $script:RemindHook $m } else { $hours = Show-RemindDialog $m }
    if ($null -eq $hours) { return $null }
    $r = New-TireReminder $hours
    if (Test-RemChan 'calendar') {
        try { $cal = New-ReminderIcs $r.id $r.due $r.message; $script:LastRemCal = $cal; if ($null -eq $script:RemindHook) { Start-Process $cal.gcal } } catch { Write-WidgetLog ('calendar reminder failed: ' + $_.Exception.Message) }
    }
    $ui.RemindTxt.Text = ('REMINDER SET FOR {0}' -f $r.due.ToString('h:mm tt', $Inv)).ToUpper()
    if ($null -eq $script:RemindHook) {
        [void][System.Windows.MessageBox]::Show($window, ("Reminder set for {0}.`r`n`r`nWindows Task Scheduler will send {1}. It still fires if TessDesk is closed, as long as you're signed in to Windows (if the PC is asleep, it sends when it wakes)." -f $r.due.ToString('ddd h:mm tt', $Inv), (Get-ChannelText)), 'TessDesk · Reminder set', 'OK', 'Information')
    }
    return $r
}
function Show-RemindDialog {
    param($m)
    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'Remind me to get air'; $dlg.Width = 380; $dlg.SizeToContent = 'Height'; $dlg.ResizeMode = 'NoResize'
    $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.Background = T 'RootBg'; $dlg.Foreground = T 'Text'; $dlg.FontFamily = $window.FontFamily
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '16,12,16,14'
    $h = New-Object System.Windows.Controls.TextBlock; $h.Text = 'Remind me to get air in…'; $h.FontSize = 16; $h.FontWeight = 'Bold'; [void]$sp.Children.Add($h)
    $l = New-Object System.Windows.Controls.TextBlock; $l.Text = (@($m.lines) -join "`n"); $l.Margin = '0,6,0,8'; $l.Foreground = T 'TextSoft'; [void]$sp.Children.Add($l)
    $row = New-Object System.Windows.Controls.WrapPanel
    $script:RemPick = $null
    $script:Dlg = @{ dlg = $dlg }
    foreach ($hv in 1, 2, 4, 8) {
        $b = New-Object System.Windows.Controls.Button; $b.Content = ('{0} hour{1}' -f $hv, $(if ($hv -gt 1) { 's' } else { '' })); $b.Tag = $hv; $b.Padding = '10,5,10,5'; $b.Margin = '0,0,6,6'; $b.FontWeight = 'Bold'
        $b.Add_Click({ param($s4, $e4) $script:RemPick = [double]$s4.Tag; $script:Dlg.dlg.Close() }); [void]$row.Children.Add($b)
    }
    [void]$sp.Children.Add($row)
    $cr = New-Object System.Windows.Controls.StackPanel; $cr.Orientation = 'Horizontal'; $cr.Margin = '0,2,0,0'
    $ct = New-Object System.Windows.Controls.TextBlock; $ct.Text = 'Custom: '; $ct.VerticalAlignment = 'Center'; [void]$cr.Children.Add($ct)
    $tb = New-Object System.Windows.Controls.TextBox; $tb.Width = 60; $tb.Text = '3'; $script:Dlg.tb = $tb; [void]$cr.Children.Add($tb)
    $ct2 = New-Object System.Windows.Controls.TextBlock; $ct2.Text = ' hours  '; $ct2.VerticalAlignment = 'Center'; [void]$cr.Children.Add($ct2)
    $bc = New-Object System.Windows.Controls.Button; $bc.Content = 'Set'; $bc.Padding = '12,3,12,3'
    $bc.Add_Click({ $v = 0.0; if ([double]::TryParse($script:Dlg.tb.Text, [ref]$v) -and $v -gt 0 -and $v -le 168) { $script:RemPick = $v; $script:Dlg.dlg.Close() } else { $script:Dlg.tb.BorderBrush = T 'Red' } })
    [void]$cr.Children.Add($bc); [void]$sp.Children.Add($cr)
    $n = New-Object System.Windows.Controls.TextBlock; $n.TextWrapping = 'Wrap'; $n.FontSize = 11; $n.Margin = '0,10,0,0'; $n.Foreground = T 'Caption'
    $n.Text = ('Sends {0} at that time. Uses Windows Task Scheduler, so it works even if TessDesk is closed, but only while you are signed in to Windows.{1}' -f (Get-ChannelText), $(if ($REM_DRYRUN) { ' DRY RUN is on: nothing will actually be sent.' } else { '' }))
    [void]$sp.Children.Add($n)
    if (Test-RemChan 'calendar') {
        $cal = New-Object System.Windows.Controls.TextBlock; $cal.Text = 'Phone calendar alert: after you pick a time, TessDesk also opens Google Calendar (and saves an .ics file) with that alert.'; $cal.TextWrapping = 'Wrap'; $cal.FontSize = 11; $cal.Margin = '0,8,0,0'; $cal.Foreground = T 'Caption'; [void]$sp.Children.Add($cal)
    }
    $bx = New-Object System.Windows.Controls.Button; $bx.Content = 'Cancel'; $bx.HorizontalAlignment = 'Right'; $bx.Padding = '12,3,12,3'; $bx.Margin = '0,10,0,0'
    $bx.Add_Click({ $script:Dlg.dlg.Close() }); [void]$sp.Children.Add($bx)
    $dlg.Content = $sp; try { $dlg.Owner = $window } catch {}
    [void]$dlg.ShowDialog()
    return $script:RemPick
}


function Get-CtlValue {
    param([string]$Key, $Live)
    if ($script:CtlOverride.ContainsKey($Key)) {
        $o = $script:CtlOverride[$Key]
        if ((Get-Date) -lt $o.until -and -not ($null -ne $Live -and "$Live" -eq "$($o.v)")) { return $o.v }
        $script:CtlOverride.Remove($Key)
    }
    return $Live
}
function Set-CtlOverride { param([string]$Key, $Value) $script:CtlOverride[$Key] = @{ v = $Value; until = (Get-Date).AddMinutes(3) } }

function Get-CtlCar { $c = $null; if ($null -ne $script:View) { $c = $script:View.car }; if ($null -eq $c -and $null -ne $script:State) { $c = $script:State.lastCar }; return $c }
function Test-UnitsF { $c = Get-CtlCar; return ($null -eq $c -or [string]$c.tempUnits -ne 'C') }
function Format-Temp {
    param($C)
    if ($null -eq $C) { return '--' }
    if (Test-UnitsF) { return ('{0:N0}°F' -f ([double]$C * 9 / 5 + 32)) }
    return ('{0:0.0}°C' -f [double]$C)
}

function Set-CtlResult {
    param([string]$Kind, [string]$Text)
    $script:CtlResultKind = $Kind; $script:CtlResultText = $Text
    $ui.CtlResult.Text = $Text
    switch ($Kind) { 'ok' { $ui.CtlResult.Foreground = T 'Green' } 'err' { $ui.CtlResult.Foreground = T 'Red' } 'busy' { $ui.CtlResult.Foreground = T 'TextSoft' } default { $ui.CtlResult.Foreground = T 'Caption' } }
    Set-Visible $ui.CtlSpin ($Kind -eq 'busy')
    $ui.CtlSpin.Stroke = T 'Green'
}

function Confirm-Ctl {
    param([string]$Msg, [string]$Sub = '', [string]$Yes = '', [string]$No = 'Cancel')
    $script:ConfirmPrompts += $(if ($Sub) { $Msg + ' [' + $Sub + ']' } else { $Msg })
    if ($null -ne $script:ConfirmHook) { return [bool](& $script:ConfirmHook $Msg) }
    if ($Yes) { return [bool](Show-ConfirmOverlay $Msg $Sub $Yes $No) }
    $r = [System.Windows.MessageBox]::Show($window, $Msg, 'TessDesk · Tesla controls', 'YesNo', 'Question', 'No')
    return ($r -eq 'Yes')
}

function Start-TessieCommand {
    param([string]$Cmd, [hashtable]$Query = @{}, [string]$Busy, [string]$OkText, [scriptblock]$OnOk, [string]$Ann)
    if ($script:CtlBusy) { return $false }
    if (-not $CTL_ENABLED) { Set-CtlResult 'err' 'Controls are turned off in config.json'; return $false }
    if (-not [bool]$script:CmdAllowed) { Set-CtlResult 'err' 'Commands are off: you did not allow TessDesk to send vehicle commands (About / Privacy to change)'; return $false }
    $token = $null; try { $token = Get-TessieToken } catch {}
    if (-not $token -or -not $script:VIN) { Set-CtlResult 'err' 'Can''t send: no Tessie token / VIN'; return $false }
    $url = Get-CommandUrl $Cmd $Query
    $ps = [powershell]::Create()
    if ($CTL_DRYRUN) { [void]$ps.AddScript($script:CmdDryRunBlock).AddArgument($url) }
    else { [void]$ps.AddScript($script:CmdSendBlock).AddArgument($url).AddArgument($token).AddArgument($CmdTimeoutSec); $script:NetCommandsSent++ }
    $script:CtlJob = [pscustomobject]@{ ps = $ps; async = $null; cmd = $Cmd; query = $Query; okText = $OkText; onOk = $OnOk; ann = $Ann; started = Get-Date; url = $url }
    $script:CtlJob.async = $ps.BeginInvoke()
    $script:CtlBusy = $true
    Set-CtlResult 'busy' ($Busy + $(if ($CTL_DRYRUN) { ' (dry run)' } else { '' }))
    Render-Controls
    $script:CtlTimer.Start()
    Write-WidgetLog ('command ' + $Cmd + $(if ($CTL_DRYRUN) { ' [DRY RUN]' } else { '' }))
    return $true
}

function Complete-TessieCommand {
    try { Request-LiveSoon 4 } catch {}
    $j = $script:CtlJob; $script:CtlJob = $null
    $res = $null
    try { $out = $j.ps.EndInvoke($j.async); if ($null -ne $out -and $out.Count -gt 0) { $res = $out[$out.Count - 1] } } catch { $res = [pscustomobject]@{ ok = $false; error = $_.Exception.Message } }
    try { $j.ps.Dispose() } catch {}
    $script:CtlBusy = $false
    $secs = [math]::Round(((Get-Date) - $j.started).TotalSeconds, 1)
    $ok = ($null -ne $res -and [bool]$res.ok)
    $when = Format-Clock (Get-LocalNow)
    if ($ok) {
        try { if ($null -ne $j.onOk) { & $j.onOk } } catch {}
        if ($j.cmd -eq 'set_temperatures') { $script:CtlPendingTempC = $null }
        Set-CtlResult 'ok' ('✓ ' + $j.okText + ' · ' + $when + $(if ($CTL_DRYRUN) { ' (dry run, not sent)' } else { '' }))
        if (-not $CTL_DRYRUN) { $script:RefreshAt = (Get-Date).AddSeconds(6) }
    } else {
        $why = 'no response'; if ($null -ne $res) { $why = [string]$res.error; if (-not $why -and $null -ne $res.code) { $why = 'HTTP ' + $res.code } ; if (-not $why) { $why = 'car did not confirm' } }
        if ($null -ne $res -and ($res.code -eq 401 -or $res.code -eq 403)) { $why = 'token rejected (' + $res.code + ')' }
        if ($why.Length -gt 90) { $why = $why.Substring(0, 90) + '…' }
        if ($j.cmd -eq 'set_temperatures') { $script:CtlPendingTempC = $null }
        Set-CtlResult 'err' ('✕ ' + $j.cmd + ' failed: ' + $why)
    }
    # v4.2: follow-up step (Heat) or Alexa announcement of the final result
    $next = $null
    if ($ok -and $script:CtlQueue.Count -gt 0) { $next = $script:CtlQueue.Dequeue() } else {
        $script:CtlQueue.Clear()
        if ([bool]$script:AlexaOn -and $j.cmd -ne 'flash') { try { $ar = Send-Announcement (Get-ActionSpeech $j $ok $(if ($ok) { '' } else { $why })) 'action'; Write-WidgetLog ('announce text: ' + $ar.text + ' -> ' + $ar.result) } catch { Write-WidgetLog ('announce failed: ' + $_.Exception.Message) } }
    }
    $script:CtlLog = @(@($script:CtlLog) + [ordered]@{ at = (Get-LocalNow).ToString('s'); cmd = $j.cmd; query = $j.query; url = $j.url
        dryRun = [bool]$CTL_DRYRUN; ok = $ok; seconds = $secs; result = $script:CtlResultText }) | Select-Object -Last 12
    if ($j.cmd -eq 'flash' -and $script:Flash.running -and $script:Flash.done -lt $script:Flash.total) { Render-Controls } else { Render-View; Write-WidgetStatus }
    if ($null -ne $next) { if (-not (Start-TessieCommand $next.cmd $next.query $next.busy $next.okText $next.onOk $next.ann)) { $script:CtlQueue.Clear() } }
}

function Invoke-LockToggle {
    $car = Get-CtlCar
    $locked = Get-CtlValue 'locked' $(if ($null -ne $car) { $car.locked } else { $null })
    if ($null -ne $locked -and [bool]$locked) {
        if (-not (Confirm-Ctl 'Unlock your Tesla?')) { Set-CtlResult 'idle' 'Unlock cancelled'; return }
        [void](Start-TessieCommand 'unlock' @{} 'Unlocking…' 'Unlocked' { Set-CtlOverride 'locked' $false } 'Your Tesla is now unlocked.')
    } else {
        [void](Start-TessieCommand 'lock' @{} 'Locking…' 'Locked' { Set-CtlOverride 'locked' $true } 'Your Tesla is now locked.')
    }
}
function Invoke-Vent {
    if (-not (Confirm-Ctl 'Vent the windows on your Tesla?')) { Set-CtlResult 'idle' 'Vent cancelled'; return }
    [void](Start-TessieCommand 'vent_windows' @{} 'Venting windows…' 'Windows vented' { Set-CtlOverride 'windowsOpen' $true })
}
function Invoke-CloseWindows { [void](Start-TessieCommand 'close_windows' @{} 'Closing windows…' 'Windows closed' { Set-CtlOverride 'windowsOpen' $false }) }
function Invoke-ClimateToggle {
    $car = Get-CtlCar
    $on = Get-CtlValue 'climateOn' $(if ($null -ne $car) { $car.climateOn } else { $null })
    if ($null -ne $on -and [bool]$on) { [void](Start-TessieCommand 'stop_climate' @{} 'Turning climate off…' 'Climate off' { Set-CtlOverride 'climateOn' $false }) }
    else { [void](Start-TessieCommand 'start_climate' @{} 'Turning climate on…' 'Climate on' { Set-CtlOverride 'climateOn' $true }) }
}
function Get-ShownTempC {
    if ($null -ne $script:CtlPendingTempC) { return $script:CtlPendingTempC }
    $car = Get-CtlCar
    return (Get-CtlValue 'tempC' $(if ($null -ne $car) { $car.tempC } else { $null }))
}
function Step-Temp {
    param([int]$Dir)
    $car = Get-CtlCar
    $c = Get-ShownTempC; if ($null -eq $c) { $c = 20.0 }
    $lo = 15.0; $hi = 28.0; if ($null -ne $car) { if ($null -ne $car.minC) { $lo = [double]$car.minC }; if ($null -ne $car.maxC) { $hi = [double]$car.maxC } }
    if (Test-UnitsF) { $f = [math]::Round([double]$c * 9 / 5 + 32) + $Dir; $n = [math]::Round(($f - 32) * 5 / 9, 1) }
    else { $n = [math]::Round(([double]$c + 0.5 * $Dir) * 2) / 2 }
    $n = [math]::Max($lo, [math]::Min($hi, $n))
    $script:CtlPendingTempC = $n
    Set-CtlResult 'idle' ('Set to ' + (Format-Temp $n) + ' · sending in a moment…')
    Render-Controls
    $script:TempTimer.Stop(); $script:TempTimer.Start()      # debounce: send 1.5 s after the last tap
}
function Send-PendingTemp {
    if ($null -eq $script:CtlPendingTempC) { $script:TempTimer.Stop(); return }
    if ($script:CtlBusy) { return }                           # try again on the next tick
    $script:TempTimer.Stop()
    $n = [double]$script:CtlPendingTempC
    $txt = Format-Temp $n
    $okb = [scriptblock]::Create('Set-CtlOverride ''tempC'' ' + $n.ToString('0.0', $Inv))
    $started = Start-TessieCommand 'set_temperatures' @{ temperature = $n.ToString('0.0', $Inv) } ('Setting ' + $txt + '…') ('Temperature ' + $txt) $okb
    if (-not $started) { $script:CtlPendingTempC = $null; Render-Controls }
}
function Request-ChargeLimit {
    param([int]$Pct)
    $b = Get-LimitBounds
    $p = [int][math]::Max($b[0], [math]::Min($b[1], $Pct))
    $mi = Get-MilesAt $p
    $label = ('{0}%' -f $p) + $(if ($null -ne $mi) { ' / ' + (Format-Miles $mi) } else { '' })
    if ($null -ne $script:BarLimitShown -and $p -eq [int]$script:BarLimitShown) { $script:VPend = $null; Set-CtlResult 'idle' ('Charge limit stays ' + $label); Render-View; return $p }
    if ($null -ne $script:BarLimitShown -and $p -eq [int]$script:BarLimitShown) { $script:VPend = $null }
    $okc = Confirm-Ctl ('Set to {0}%?' -f $p) ('Charge limit ' + $label) 'Confirm' 'Cancel'
    $script:VPend = $null
    if (-not $okc) { Set-CtlResult 'idle' 'Charge limit unchanged'; Render-View; return $p }
    $okb = [scriptblock]::Create('Set-CtlOverride ''limit'' ' + $p)
    [void](Start-TessieCommand 'set_charge_limit' @{ percent = [string]$p } ('Setting charge limit ' + $label + '…') ('Charge limit ' + $label) $okb)
    Render-View
    return $p
}

function Render-Controls {
    $car = Get-CtlCar
    $have = ($null -ne $car)
    $locked = Get-CtlValue 'locked' $(if ($have) { $car.locked } else { $null })
    $win = Get-CtlValue 'windowsOpen' $(if ($have) { $car.windowsOpen } else { $null })
    $clim = Get-CtlValue 'climateOn' $(if ($have) { $car.climateOn } else { $null })
    $en = ((Test-CmdOn) -and -not $script:CtlBusy -and $have)
    foreach ($n in 'LockBtn', 'ClimBtn', 'VentBtn', 'CloseWinBtn', 'TempDownBtn', 'TempUpBtn', 'TrunkBtn', 'SentryBtn') { $ui[$n].IsEnabled = $en }
    Render-Controls42 $en
    try { Render-Controls433 } catch { Write-WidgetLog ('trunk/sentry render: ' + $_.Exception.Message) }
    $ui.CtlMode.Text = $(if (-not (Test-CmdOn)) { 'OFF' } elseif ($CTL_DRYRUN) { 'DRY RUN' } else { '' })
    if (-not [bool]$script:CmdAllowed -and -not $script:CtlBusy) { $script:CtlResultText = 'Commands off: permission not given. Change it in About / Privacy.' }
    # lock
    if ($null -eq $locked) { $ui.LockIcon.Text = [string][char]0xE72E; $ui.LockTxt.Text = 'LOCK'; $ui.LockSub.Text = 'state unknown'; $ui.LockTxt.Foreground = T 'Text'; $ui.LockBtn.BorderBrush = T 'BtnBorder' }
    elseif ([bool]$locked) { $ui.LockIcon.Text = [string][char]0xE72E; $ui.LockTxt.Text = 'LOCKED'; $ui.LockSub.Text = 'tap to unlock'; $ui.LockTxt.Foreground = T 'Text'; $ui.LockIcon.Foreground = T 'Green'; $ui.LockBtn.BorderBrush = T 'BtnBorder' }
    else { $ui.LockIcon.Text = [string][char]0xE785; $ui.LockTxt.Text = 'UNLOCKED'; $ui.LockSub.Text = 'tap to lock'; $ui.LockTxt.Foreground = T 'Amber'; $ui.LockIcon.Foreground = T 'Amber'; $ui.LockBtn.BorderBrush = T 'Amber' }
    if ($null -eq $locked) { $ui.LockIcon.Foreground = T 'Text' }
    # climate
    $inside = $null; if ($have) { $inside = $car.insideC }
    $insTxt = $(if ($null -ne $inside) { 'inside ' + (Format-Temp $inside) } else { '' })
    if ($null -ne $clim -and [bool]$clim -and (Test-HeatOn)) { $ui.ClimTxt.Text = 'CLIMATE ON'; $ui.ClimSub.Text = 'heating · tap off'; $ui.ClimBtn.Background = T 'BtnOn'; $ui.ClimBtn.BorderBrush = T 'BtnOn'; $ui.ClimSub.Foreground = T 'Text' }
    elseif ($null -ne $clim -and [bool]$clim) { $ui.ClimTxt.Text = 'A/C ON'; $ui.ClimSub.Text = $(if ($insTxt) { $insTxt + ' · tap off' } else { 'tap to turn off' }); $ui.ClimBtn.Background = T 'BtnOn'; $ui.ClimBtn.BorderBrush = T 'BtnOn'; $ui.ClimSub.Foreground = T 'Text' }
    else { $ui.ClimTxt.Text = 'A/C OFF'; $ui.ClimSub.Text = $(if ($insTxt) { $insTxt + ' · tap on' } else { 'tap to turn on' }); $ui.ClimBtn.Background = T 'BtnBg'; $ui.ClimBtn.BorderBrush = T 'BtnBorder'; $ui.ClimSub.Foreground = T 'Caption' }
    # windows
    # v4.2: the button that matches the windows' current state is green
    Set-StateBtn $ui.VentBtn $ui.VentTxt $ui.VentSub ($null -ne $win -and [bool]$win) $(if ($null -ne $win -and [bool]$win) { 'VENTED / OPEN' } else { 'WINDOWS' })
    Set-StateBtn $ui.CloseWinBtn $ui.CloseWinTxt $ui.CloseWinSub ($null -ne $win -and -not [bool]$win) $(if ($null -ne $win -and -not [bool]$win) { 'ALL CLOSED' } else { 'WINDOWS' })
    # temperature
    $ui.TempVal.Text = Format-Temp (Get-ShownTempC)
    $ui.TempCap.Text = $(if ($null -ne $script:CtlPendingTempC) { 'NEW SET TEMP' } else { 'SET TEMP' })
    if ($ui.CtlResult.Text -ne $script:CtlResultText) { $ui.CtlResult.Text = $script:CtlResultText }
    try { Render-Flash } catch {}
}

# ---------------- v4.3.2: FLASH LIGHTS (1-20 flashes, asks first, Stop ends early) ----------------
# v4.3.5: pause 1-30 s (config flashPauseSec). The next flash goes at (previous send + pause), but never while the previous
# request is still in flight. Under 3 s: wait_for_completion=false (fire and go). Stats: response time last/avg + measured gap.
$script:Flash = [ordered]@{ total = 0; done = 0; running = $false; stoppedEarly = $false; pause = $FLASH_PAUSE; noWait = $false
    pendingAt = $null; nextAt = $null; sends = @(); rtts = @() }
$script:FlashWaitFor = $null
$script:FlashTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:FlashTimer.Interval = [TimeSpan]::FromMilliseconds(50)
function Get-FlashPause {
    $t = ([string]$ui.FlashPause.Text).Trim().Replace(',', '.'); $v = 0.0
    if (-not [double]::TryParse($t, [System.Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { $v = $FLASH_PAUSE }
    return [math]::Min(30.0, [math]::Max(1.0, [math]::Round($v * 2) / 2))
}
function Set-FlashPause {
    param([double]$V)
    $V = [math]::Min(30.0, [math]::Max(1.0, [math]::Round($V * 2) / 2))
    $ui.FlashPause.Text = $V.ToString('0.0', $Inv)
    if ($V -ne $script:FlashPauseSaved) { $script:FlashPauseSaved = $V; if (-not $SelfTest) { try { Save-ConfigProp 'flashPauseSec' $V } catch { Write-WidgetLog ('flash pause save failed: ' + $_.Exception.Message) } } }
}
$script:FlashPauseSaved = $FLASH_PAUSE; $script:FlashCountSaved = $FLASH_COUNT
function Get-FlashStatsText {
    $F = $script:Flash; $r = @($F.rtts); $s = @($F.sends)
    if ($r.Count -eq 0) { return '' }
    $txt = 'Last {0}s · avg {1}s' -f $r[-1].ToString('0.0', $Inv), (($r | Measure-Object -Average).Average).ToString('0.0', $Inv)
    $g = Get-FlashGap; if ($null -ne $g) { $txt += ' · gap ' + $g.ToString('0.0', $Inv) + 's' }
    return $txt
}
function Get-FlashGap {
    $s = @($script:Flash.sends); if ($s.Count -lt 2) { return $null }
    return (($s[-1] - $s[0]).TotalSeconds / ($s.Count - 1))
}
function Get-FlashCount {
    $n = 0; [void][int]::TryParse(([string]$ui.FlashCount.Text).Trim(), [ref]$n)
    if ($n -lt 1) { $n = 1 }; if ($n -gt 20) { $n = 20 }
    return $n
}
function Invoke-FlashLights {
    if ($script:Flash.running) { Stop-FlashLights 'Stopped'; return }
    if (-not (Test-CmdOn) -or $script:CtlBusy) { return }
    $n = Get-FlashCount; $ui.FlashCount.Text = [string]$n
    if ($n -ne $script:FlashCountSaved) { $script:FlashCountSaved = $n; if (-not $SelfTest) { try { Save-ConfigProp 'flashCount' $n } catch { Write-WidgetLog ('flash count save failed: ' + $_.Exception.Message) } } }
    $p = Get-FlashPause; Set-FlashPause $p
    $plural = $(if ($n -eq 1) { '' } else { 'es' })
    if (-not (Confirm-Ctl ('Flash the lights {0} time{1}?' -f $n, $(if ($n -eq 1) { '' } else { 's' })) ('{0} flash{1}, about {2} seconds apart. Tap Stop to end early.' -f $n, $plural, $p.ToString('0.#', $Inv)) 'Flash' 'Cancel')) { Set-CtlResult 'idle' 'Flash lights cancelled'; Render-Flash; return }
    $F = $script:Flash
    $F.total = $n; $F.done = 0; $F.running = $true; $F.stoppedEarly = $false; $F.pause = $p; $F.noWait = ($p -lt 3.0)
    $F.pendingAt = $null; $F.nextAt = $null; $F.sends = @(); $F.rtts = @()
    $script:FlashTimer.Start()
    Step-FlashLights
}
function Step-FlashLights {
    $F = $script:Flash
    if (-not $F.running) { $script:FlashTimer.Stop(); return }
    if ($script:CtlBusy) { return }          # the last flash request is still in flight: never send another one on top of it
    if ($F.done -ge $F.total) { Stop-FlashLights 'Done'; return }
    $now = Get-Date
    if ($null -ne $F.nextAt -and $now -lt $F.nextAt) { return }
    $i = $F.done + 1
    $q = @{}; if ($F.noWait) { $q['wait_for_completion'] = 'false' }
    $F.pendingAt = $now
    $okb = { $FF = $script:Flash; if ($null -ne $FF.pendingAt) { $FF.rtts = @(@($FF.rtts) + [math]::Round(((Get-Date) - $FF.pendingAt).TotalSeconds, 2)); $FF.sends = @(@($FF.sends) + $FF.pendingAt); $FF.pendingAt = $null } }
    $ok = Start-TessieCommand 'flash' $q ('Flashing {0} of {1}' -f $i, $F.total) ('Flashed {0} of {1}' -f $i, $F.total) $okb
    if (-not $ok) { $F.pendingAt = $null; Stop-FlashLights 'Could not send'; return }
    $F.done = $i
    $F.nextAt = $now.AddSeconds($F.pause)
    Render-Flash
}
function Stop-FlashLights {
    param([string]$Why)
    $F = $script:Flash; $script:FlashTimer.Stop()
    $was = $F.running; $F.running = $false
    if ($Why -eq 'Stopped' -and $was) { $F.stoppedEarly = $true; if (-not $script:CtlBusy) { Set-CtlResult 'idle' ('Flash lights stopped after {0} of {1}' -f $F.done, $F.total) } }
    if ($Why -eq 'Done' -and $was -and -not $script:CtlBusy) { $g = Get-FlashGap; Set-CtlResult 'ok' ('✓ Flashed the lights {0} time{1}{2}{3}' -f $F.done, $(if ($F.done -eq 1) { '' } else { 's' }), $(if ($null -ne $g) { ' · ~' + $g.ToString('0.0', $Inv) + 's apart' } else { '' }), $(if ($CTL_DRYRUN) { ' (dry run, not sent)' } else { '' })) }
    Render-Flash
}
function Render-Flash {
    $F = $script:Flash
    if ($F.running) {
        $ui.FlashBtnTxt.Text = 'STOP'; $ui.FlashBtn.Background = T 'SeatOn'; $ui.FlashBtn.BorderBrush = T 'SeatOn'
        $g = Get-FlashGap
        $ui.FlashSub.Text = ('Flashing {0} of {1}' -f [math]::Max(1, $F.done), $F.total) + $(if ($null -ne $g) { ' · ~' + $g.ToString('0.0', $Inv) + 's apart' } else { '' }); $ui.FlashSub.Foreground = T 'Green'
        $ui.FlashBtn.IsEnabled = $true
    } else {
        $ui.FlashBtnTxt.Text = 'FLASH'; $ui.FlashBtn.Background = T 'BtnBg'; $ui.FlashBtn.BorderBrush = T 'BtnBorder'
        $ui.FlashSub.Text = 'flashes · pause s'; $ui.FlashSub.Foreground = T 'Caption'
        $ui.FlashBtn.IsEnabled = ((Test-CmdOn) -and -not $script:CtlBusy -and $null -ne (Get-CtlCar))
    }
    $ui.FlashBtnTxt.Foreground = T 'Text'
    $ui.FlashCount.IsEnabled = -not $F.running; $ui.FlashPause.IsEnabled = -not $F.running
    $st = Get-FlashStatsText; Set-Visible $ui.FlashStats ([bool]$st); if ($ui.FlashStats.Text -ne $st) { $ui.FlashStats.Text = $st }; $ui.FlashStats.Foreground = T 'Caption'
}
$script:FlashTimer.Add_Tick({ try { Step-FlashLights } catch { Write-WidgetLog ('flash: ' + $_.Exception.Message) } })
$ui.FlashBtn.Add_Click({ try { Invoke-FlashLights } catch { Write-WidgetLog ('flash: ' + $_.Exception.Message) } })
$ui.FlashCount.Add_PreviewTextInput({ param($s, $e) if ($e.Text -notmatch '^[0-9]+$') { $e.Handled = $true } })
$ui.FlashCount.Add_LostFocus({ try { $ui.FlashCount.Text = [string](Get-FlashCount) } catch {} })
$ui.FlashPause.Text = $FLASH_PAUSE.ToString('0.0', $Inv); $ui.FlashCount.Text = [string]$FLASH_COUNT
$ui.FlashPause.Add_PreviewTextInput({ param($s, $e) if ($e.Text -notmatch '^[0-9.,]+$') { $e.Handled = $true } })
$ui.FlashPause.Add_LostFocus({ try { Set-FlashPause (Get-FlashPause) } catch {} })
$ui.FlashPause.Add_PreviewMouseWheel({ param($s, $e) try { if ($ui.FlashPause.IsEnabled) { Set-FlashPause ((Get-FlashPause) + $(if ($e.Delta -gt 0) { 0.5 } else { -0.5 })); $e.Handled = $true } } catch {} })
$ui.FlashPause.Add_PreviewKeyDown({ param($s, $e) try { if ($e.Key -eq 'Up') { Set-FlashPause ((Get-FlashPause) + 0.5); $e.Handled = $true } elseif ($e.Key -eq 'Down') { Set-FlashPause ((Get-FlashPause) - 0.5); $e.Handled = $true } elseif ($e.Key -eq 'Enter') { Set-FlashPause (Get-FlashPause); $e.Handled = $true } } catch {} })

# ---------------- v4.2 controls: charging start/stop, amps, heat, defrost, cabin overheat, seats, wheel ----------------
$script:CtlQueue = New-Object System.Collections.Queue     # follow-up commands (Heat = set_temperatures then start_climate)
function Start-TessieSequence {
    param([object[]]$Steps)
    $script:CtlQueue.Clear()
    for ($i = 1; $i -lt $Steps.Count; $i++) { $script:CtlQueue.Enqueue($Steps[$i]) }
    $s = $Steps[0]
    $ok = Start-TessieCommand $s.cmd $s.query $s.busy $s.okText $s.onOk $s.ann
    if (-not $ok) { $script:CtlQueue.Clear() }
    return $ok
}
function Get-HeatC {
    $car = Get-CtlCar
    $c = [math]::Round(($HEAT_F - 32) * 5 / 9, 1)
    $hi = 28.0; if ($null -ne $car -and $null -ne $car.maxC) { $hi = [double]$car.maxC }
    return [math]::Min($hi, $c)
}
function Get-ChgState { $car = Get-CtlCar; return [string](Get-CtlValue 'chargingState' $(if ($null -ne $car) { [string]$car.chargingState } else { $null })) }
function Invoke-ChargeStart {
    if ((Get-ChgState) -eq 'Charging') { Set-CtlResult 'idle' 'Already charging'; Render-Controls; return }
    [void](Start-TessieCommand 'start_charging' @{} 'Starting charging…' 'Charging started' { Set-CtlOverride 'chargingState' 'Charging' } 'Your Tesla is now charging.')
}
function Invoke-ChargeStop {
    if ((Get-ChgState) -ne 'Charging') { Set-CtlResult 'idle' 'Not charging right now'; Render-Controls; return }
    if (-not (Confirm-Ctl 'Stop charging now?')) { Set-CtlResult 'idle' 'Still charging'; return }
    [void](Start-TessieCommand 'stop_charging' @{} 'Stopping charging…' 'Charging stopped' { Set-CtlOverride 'chargingState' 'Stopped' } 'Charging stopped.')
}
function Get-AmpsBounds {
    $car = Get-CtlCar; $hi = 48; $lo = 5
    if ($null -ne $car -and $null -ne $car.ampsMax -and [int]$car.ampsMax -gt 0) { $hi = [int]$car.ampsMax }
    if ($hi -lt $lo) { $lo = 1 }
    return @($lo, $hi)
}
function Get-ShownAmps { $car = Get-CtlCar; return (Get-CtlValue 'amps' $(if ($null -ne $car) { $car.ampsReq } else { $null })) }
function Set-AmpsThumbAt { param([double]$A) $b = Get-AmpsBounds; $f = 0.0; if ($b[1] -gt $b[0]) { $f = ([double]$A - $b[0]) / ($b[1] - $b[0]) }; $f = [math]::Max(0, [math]::Min(1, $f)); [System.Windows.Controls.Canvas]::SetLeft($ui.AmpsThumb, $BarX + $f * $BarW - 10); $ui.AmpsFill.Width = $f * $BarW }
function Get-AmpsFromX { param([double]$X) $b = Get-AmpsBounds; $f = ($X - $BarX) / $BarW; $a = [math]::Round($b[0] + $f * ($b[1] - $b[0])); return [int][math]::Max($b[0], [math]::Min($b[1], $a)) }
function Request-ChargeAmps {
    param([int]$Amps)
    $b = Get-AmpsBounds
    $a = [int][math]::Max($b[0], [math]::Min($b[1], $Amps))
    $cur = Get-ShownAmps
    if ($null -ne $cur -and $a -eq [int]$cur) { Set-CtlResult 'idle' ('Charging amps stay ' + $a + ' A'); Render-View; return $a }
    if (-not (Confirm-Ctl ('Set charging current to {0} A?' -f $a))) { Set-CtlResult 'idle' 'Charging amps unchanged'; Render-View; return $a }
    $okb = [scriptblock]::Create('Set-CtlOverride ''amps'' ' + $a)
    [void](Start-TessieCommand 'set_charging_amps' @{ amps = [string]$a } ('Setting charging current ' + $a + ' A…') ('Charging current ' + $a + ' A') $okb ('Charging current set to ' + $a + ' amps.'))
    Render-View
    return $a
}
function Show-DragAmps {
    param([int]$A)
    $script:DragAmps = $A
    Set-AmpsThumbAt $A
    $ui.DragCap.Text = 'SET AMPS '; $ui.DragVal.Text = ('{0} A' -f $A); $ui.AmpsVal.Text = ('{0} A' -f $A)
    Set-Visible $ui.DragBox $true; Set-Visible $ui.BattTop $false
}
function End-AmpsDrag {
    param([bool]$Commit)
    $script:DraggingAmps = $false; $script:Dragging = $false
    try { $ui.AmpsDark.ReleaseMouseCapture() } catch {}
    Set-Visible $ui.DragBox $false; Set-Visible $ui.BattTop $true; $ui.DragCap.Text = 'SET LIMIT '
    if ($Commit -and $null -ne $script:DragAmps) { [void](Request-ChargeAmps $script:DragAmps) } else { Render-View }
    $script:DragAmps = $null
}
function Test-HeatOn {
    $car = Get-CtlCar; if ($null -eq $car) { return $false }
    $on = Get-CtlValue 'climateOn' $car.climateOn; $t = Get-ShownTempC
    return ($null -ne $on -and [bool]$on -and $null -ne $t -and [double]$t -ge ((Get-HeatC) - 0.3))
}
function Invoke-Heat {
    if (Test-HeatOn) { [void](Start-TessieCommand 'stop_climate' @{} 'Turning heat (climate) off…' 'Heat off (climate off)' { Set-CtlOverride 'climateOn' $false } 'Heat is off. Climate is now off.'); return }
    $hc = Get-HeatC; $txt = Format-Temp $hc
    $okT = [scriptblock]::Create('Set-CtlOverride ''tempC'' ' + $hc.ToString('0.0', $Inv))
    [void](Start-TessieSequence @(
        [pscustomobject]@{ cmd = 'set_temperatures'; query = @{ temperature = $hc.ToString('0.0', $Inv) }; busy = ('Heat: setting ' + $txt + '…'); okText = ('Set ' + $txt); onOk = $okT; ann = $null },
        [pscustomobject]@{ cmd = 'start_climate'; query = @{}; busy = 'Heat: turning climate on…'; okText = ('Heat on: climate on at ' + $txt); onOk = { Set-CtlOverride 'climateOn' $true }; ann = ('Heat is on. Climate set to ' + (Get-SpokenTemp $hc) + '.') }))
}
function Get-DefrostOn { $car = Get-CtlCar; return (Get-CtlValue 'defrost' $(if ($null -ne $car) { $car.defrostOn } else { $null })) }
function Invoke-Defrost {
    $d = Get-DefrostOn
    if ($null -ne $d -and [bool]$d) { [void](Start-TessieCommand 'stop_max_defrost' @{} 'Turning defrost off…' 'Defrost off' { Set-CtlOverride 'defrost' $false } 'Defrost is now off.') }
    else { [void](Start-TessieCommand 'start_max_defrost' @{} 'Turning max defrost on…' 'Max defrost on' { Set-CtlOverride 'defrost' $true; Set-CtlOverride 'climateOn' $true } 'Max defrost is now on.') }
}
function Get-CopMode { $car = Get-CtlCar; return [string](Get-CtlValue 'cop' $(if ($null -ne $car) { $car.cop } else { $null })) }
function Invoke-CopCycle {
    $car = Get-CtlCar
    $fan = ($null -ne $car -and [bool]$car.copFanOnly)
    $m = Get-CopMode
    $next = $(switch ($m) { 'On' { if ($fan) { 'FanOnly' } else { 'Off' } } 'FanOnly' { 'Off' } default { 'On' } })
    $q = @{ on = $(if ($next -eq 'Off') { 'false' } else { 'true' }); fan_only = $(if ($next -eq 'FanOnly') { 'true' } else { 'false' }) }
    $lbl = $(switch ($next) { 'On' { 'on' } 'FanOnly' { 'fan only' } default { 'off' } })
    $okb = [scriptblock]::Create('Set-CtlOverride ''cop'' ''' + $next + '''')
    [void](Start-TessieCommand 'set_cabin_overheat_protection' $q ('Cabin overheat protection → ' + $lbl + '…') ('Cabin overheat protection ' + $lbl) $okb ('Cabin overheat protection is now ' + $(if ($next -eq 'FanOnly') { 'set to fan only' } else { $lbl }) + '.'))
}
# Heated seats: tap cycles off → 1 → 2 → 3 → off; sent 1.2 s after the last tap (one command per seat).
$SeatApi = [ordered]@{ FL = 'front_left'; FR = 'front_right'; RL = 'rear_left'; RC = 'rear_center'; RR = 'rear_right' }
$SeatName = @{ FL = 'Driver seat'; FR = 'Passenger seat'; RL = 'Rear left seat'; RC = 'Rear center seat'; RR = 'Rear right seat' }
$script:SeatPending = [ordered]@{}
function Get-SeatLevel {
    param([string]$K)
    if ($script:SeatPending.Contains($K)) { return [int]$script:SeatPending[$K] }
    $car = Get-CtlCar; if ($null -eq $car) { return $null }
    return (Get-CtlValue ('seat' + $K) $car.('seat' + $K))
}
function Step-Seat {
    param([string]$K)
    $l = Get-SeatLevel $K; if ($null -eq $l) { return }
    $n = ([int]$l + 1) % 4
    $script:SeatPending[$K] = $n
    Set-CtlResult 'idle' ($SeatName[$K] + ' → ' + $(if ($n -eq 0) { 'off' } else { 'level ' + $n }) + ' · sending in a moment…')
    Render-Controls
    $script:SeatTimer.Stop(); $script:SeatTimer.Start()
}
function Send-PendingSeat {
    if ($script:SeatPending.Count -eq 0) { $script:SeatTimer.Stop(); return }
    if ($script:CtlBusy) { return }
    $K = @($script:SeatPending.Keys)[0]; $n = [int]$script:SeatPending[$K]; $script:SeatPending.Remove($K)
    if ($script:SeatPending.Count -eq 0) { $script:SeatTimer.Stop() }
    $car = Get-CtlCar; $live = $null; if ($null -ne $car) { $live = Get-CtlValue ('seat' + $K) $car.('seat' + $K) }
    if ($null -ne $live -and [int]$live -eq $n) { Set-CtlResult 'idle' ($SeatName[$K] + ' heat unchanged'); Render-Controls; return }
    $okb = [scriptblock]::Create('Set-CtlOverride ''seat' + $K + ''' ' + $n)
    $lv = $(if ($n -eq 0) { 'off' } else { 'level ' + $n })
    $started = Start-TessieCommand 'set_seat_heat' @{ seat = $SeatApi[$K]; level = [string]$n } ($SeatName[$K] + ' heat ' + $lv + '…') ($SeatName[$K] + ' heat ' + $lv) $okb ($(if ($n -eq 0) { $SeatName[$K] + ' heat is now off.' } else { $SeatName[$K] + ' heat set to level ' + $n + '.' }))
    if (-not $started) { Render-Controls }
}
function Get-WheelOn { $car = Get-CtlCar; return (Get-CtlValue 'wheel' $(if ($null -ne $car) { $car.wheelOn } else { $null })) }
function Invoke-WheelToggle {
    $w = Get-WheelOn
    if ($null -ne $w -and [bool]$w) { [void](Start-TessieCommand 'stop_steering_wheel_heater' @{} 'Turning wheel heat off…' 'Steering wheel heat off' { Set-CtlOverride 'wheel' $false } 'Steering wheel heat is now off.') }
    else { [void](Start-TessieCommand 'start_steering_wheel_heater' @{} 'Turning wheel heat on…' 'Steering wheel heat on' { Set-CtlOverride 'wheel' $true } 'Steering wheel heat is now on.') }
}
function Get-HeatBrush { param([int]$L) switch ($L) { 1 { return (Get-Brush '#FFFFB547') } 2 { return (Get-Brush '#FFFF8A3D') } 3 { return (Get-Brush '#FFFF4D3D') } default { return (T 'BarTrack') } } }
function Render-Seats {
    param([bool]$En)
    $car = Get-CtlCar
    $rear = ($null -ne $car -and ($null -ne $car.seatRL -or $null -ne $car.seatRR) -and -not ($null -ne $car.rearSeatHeaters -and [int]$car.rearSeatHeaters -eq 0))
    foreach ($K in @($SeatApi.Keys)) {
        $btn = $ui['Seat' + $K]
        $l = Get-SeatLevel $K
        $show = ($null -ne $l); if ($K -like 'R*' -and -not $rear) { $show = $false }
        Set-Visible $btn $show
        if ($ui.ContainsKey('SeatLvl' + $K)) { Set-Visible $ui['SeatLvl' + $K] $show; Set-Visible $ui['SeatCap' + $K] $show }
        if (-not $show) { continue }
        $lv = [int]$l; $hb = Get-HeatBrush $lv
        $ui['Seat' + $K + 'N'].Text = $(if ($lv -eq 0) { 'OFF' } else { [string]$lv }); $ui['Seat' + $K + 'N'].FontSize = $(if ($lv -eq 0) { $(if ($K -like 'F*') { 11 } else { 9 }) } else { $(if ($K -like 'F*') { 15 } else { 12 }) })
        # v4.3.2: a heated seat turns solid RED; off = green outline
        $red = T 'SeatOn'
        for ($i = 1; $i -le 3; $i++) { $ui['Seat' + $K + 'B' + $i].Fill = $(if ($lv -gt 0) { $(if ($i -le $lv) { Get-Brush '#FFFFFFFF' } else { Get-Brush '#55FFFFFF' }) } else { T 'BarTrack' }) }
        $btn.BorderBrush = $(if ($lv -gt 0) { Get-Brush '#FFFF6B6E' } elseif ($script:SeatPending.Contains($K)) { T 'TextSoft' } else { T 'BtnBorder' })
        $btn.Background = $(if ($lv -gt 0) { $red } else { T 'BtnBg' })
        $ui['Seat' + $K + 'N'].Foreground = $(if ($lv -gt 0) { Get-Brush '#FFFFFFFF' } else { T 'Caption' })
        $hb = $(if ($lv -gt 0) { Get-Brush '#FFFF5A5F' } else { $hb })
        $btn.IsEnabled = $En
        if ($ui.ContainsKey('SeatLvl' + $K)) {
            $ui['SeatLvl' + $K].Text = $(if ($lv -eq 0) { 'OFF' } else { 'HEAT ' + $lv }) + $(if ($script:SeatPending.Contains($K)) { ' …' } else { '' })
            $ui['SeatLvl' + $K].Foreground = $(if ($lv -gt 0) { $hb } else { T 'Psi' })
        }
    }
    $w = Get-WheelOn
    $haveW = ($null -ne $w)
    Set-Visible $ui.WheelBtn $haveW; Set-Visible $ui.WheelCap $haveW; Set-Visible $ui.WheelLvl $haveW
    if ($haveW) {
        $on = [bool]$w
        $ui.WheelBtn.IsEnabled = $En
        $ui.WheelN.Text = $(if ($on) { '♨' } else { '◯' })
        $ui.WheelN.Foreground = $(if ($on) { Get-HeatBrush 3 } else { T 'Caption' })
        $ui.WheelBtn.BorderBrush = $(if ($on) { Get-HeatBrush 3 } else { T 'BtnBorder' })
        $ui.WheelCap.Text = 'WHEEL'
        $ui.WheelLvl.Text = $(if ($on) { 'HEAT ON' } else { 'OFF' }); $ui.WheelLvl.Foreground = $(if ($on) { Get-HeatBrush 3 } else { T 'Psi' })
    }
    $ui.SeatsNote.Text = $(if ($null -eq $car) { 'no data' } else { 'tap a seat: off → 1 → 2 → 3' })
}
# ---------------- v4.3.3: OPEN TRUNK + SENTRY MODE ----------------
function Render-Controls433 {
    $car = Get-CtlCar; $have = ($null -ne $car)
    $tr = Get-CtlValue 'trunkOpen' $(if ($have) { $car.trunkOpen } else { $null })
    $se = Get-CtlValue 'sentry' $(if ($have) { $car.sentry } else { $null })
    if ($null -ne $tr -and [bool]$tr) {
        $ui.TrunkTxt.Text = 'TRUNK OPEN'; $ui.TrunkSub.Text = 'TAP TO CLOSE'
        $ui.TrunkBtn.BorderBrush = T 'Amber'; $ui.TrunkBtn.Background = T 'BtnBg'; $ui.TrunkTxt.Foreground = T 'Amber'; $ui.TrunkIcon.Foreground = T 'Amber'; $ui.TrunkSub.Foreground = T 'Amber'
    } else {
        $ui.TrunkTxt.Text = 'OPEN TRUNK'; $ui.TrunkSub.Text = $(if ($null -eq $tr) { 'STATE UNKNOWN' } else { 'REAR · CLOSED' })
        $ui.TrunkBtn.BorderBrush = T 'BtnBorder'; $ui.TrunkBtn.Background = T 'BtnBg'; $ui.TrunkTxt.Foreground = T 'Text'; $ui.TrunkIcon.Foreground = T 'Text'; $ui.TrunkSub.Foreground = T 'Caption'
    }
    $on = ($null -ne $se -and [bool]$se)
    Set-StateBtn $ui.SentryBtn $ui.SentryTxt $ui.SentrySub $on $(if ($null -eq $se) { 'STATE UNKNOWN' } elseif ($on) { 'ON · TAP TO TURN OFF' } else { 'OFF · TAP TO TURN ON' })
    $ui.SentryIcon.Foreground = $(if ($on) { T 'Green' } else { T 'Text' })
}
function Invoke-Trunk {
    $car = Get-CtlCar
    $open = [bool](Get-CtlValue 'trunkOpen' $(if ($null -ne $car) { $car.trunkOpen } else { $null }))
    if ($open) {
        if (-not (Confirm-Ctl 'Are you sure?' 'Close the rear trunk? Make sure nothing and no one is in the way.' 'Close trunk' 'Cancel')) { Set-CtlResult 'idle' 'Trunk left open'; return }
        [void](Start-TessieCommand 'activate_rear_trunk' @{} 'Closing the trunk…' 'Trunk closing' { Set-CtlOverride 'trunkOpen' $false } 'Your Tesla trunk is closing.')
    } else {
        if (-not (Confirm-Ctl 'Are you sure?' 'Open the rear trunk?' 'Open trunk' 'Cancel')) { Set-CtlResult 'idle' 'Trunk not opened'; return }
        [void](Start-TessieCommand 'activate_rear_trunk' @{} 'Opening the trunk…' 'Trunk open' { Set-CtlOverride 'trunkOpen' $true } 'Your Tesla trunk is open.')
    }
}
function Invoke-SentryToggle {
    $car = Get-CtlCar
    $on = [bool](Get-CtlValue 'sentry' $(if ($null -ne $car) { $car.sentry } else { $null }))
    if ($on) {
        if (-not (Confirm-Ctl 'Turn Sentry Mode OFF?' 'The car stops watching and recording its surroundings.' 'Turn off' 'Cancel')) { Set-CtlResult 'idle' 'Sentry Mode stays on'; return }
        [void](Start-TessieCommand 'disable_sentry' @{} 'Turning Sentry Mode off…' 'Sentry Mode off' { Set-CtlOverride 'sentry' $false } 'Sentry Mode is now off.')
    } else {
        if (-not (Confirm-Ctl 'Turn Sentry Mode ON?' 'The car watches and records its surroundings (uses some battery).' 'Turn on' 'Cancel')) { Set-CtlResult 'idle' 'Sentry Mode stays off'; return }
        [void](Start-TessieCommand 'enable_sentry' @{} 'Turning Sentry Mode on…' 'Sentry Mode on' { Set-CtlOverride 'sentry' $true } 'Sentry Mode is now on.')
    }
}

# ---------------- v4.3.3: DRIVES card ----------------
function New-Tb433 { param([string]$Text, [double]$Size, [string]$Brush, [bool]$Bold = $false) $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = T $Brush; if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::Bold }; $t.TextTrimming = 'CharacterEllipsis'; return $t }
function Format-Dur433 { param([int]$m) if ($m -ge 60) { return ('{0} h {1} min' -f [math]::Floor($m / 60), ($m % 60)) }; return ('{0} min' -f $m) }
function Render-Drives {
    $ds = @(@(Get-Val $script:State.drives @()) | Where-Object { $null -ne $_ })
    $ui.DrivesList.Children.Clear(); $ui.HistList.Children.Clear()
    $fe = [int64](Get-Val $script:State.drivesFetchEpoch 0)
    $ui.DrivesAsOf.Text = $(if ($fe -gt 0 -and $ds.Count -gt 0) { 'as of ' + (ConvertFrom-Epoch $fe).ToString('h:mm tt', $Inv) } else { '' })
    Set-Visible $ui.DrivesAsOfPill ([bool]$ui.DrivesAsOf.Text)
    $show = @($ds | Where-Object { [double]$_.miles -ge 0.1 } | Select-Object -First 5)
    $ui.DrivesNote.Text = $(if ($ds.Count -eq 0) { $(if ($script:DrivesNote) { 'Drives unavailable right now' } else { 'No drives in the last 30 days yet' }) } else { ('Last {0} drives · cost = energy used at the home off-peak rate (estimate) · tap a drive for its map' -f $show.Count) })
    $btnR = $script:BtnR433; if ($null -eq $btnR) { $btnR = [System.Windows.CornerRadius]::new(8) }
    foreach ($dr in $show) {
        $b = New-Object System.Windows.Controls.Border
        $b.BorderThickness = [System.Windows.Thickness]::new(1); $b.BorderBrush = T 'BtnBorder'; $b.Background = T 'BtnBg'; $b.CornerRadius = $btnR
        $b.Padding = [System.Windows.Thickness]::new(8, 3, 8, 4); $b.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
        $sp = New-Object System.Windows.Controls.StackPanel
        $top = New-Object System.Windows.Controls.DockPanel
        $c = New-Tb433 ('$' + ([double]$dr.costEst).ToString('0.00', $Inv) + ' est') 11.5 'Green' $true; [System.Windows.Controls.DockPanel]::SetDock($c, 'Right'); [void]$top.Children.Add($c)
        [void]$top.Children.Add((New-Tb433 ((ConvertFrom-Epoch ([int64]$dr.startEpoch)).ToString('ddd M/d · h:mm tt', $Inv)) 10.5 'TextSoft' $true))
        [void]$sp.Children.Add($top)
        [void]$sp.Children.Add((New-Tb433 ($dr.from + '  →  ' + $dr.to) 11.5 'Text' $true))
        $parts = @(('{0} mi' -f ([double]$dr.miles).ToString('0.0', $Inv)), ('{0} kWh' -f ([double]$dr.kwh).ToString('0.0', $Inv)), (Format-Dur433 ([int]$dr.minutes)))
        $mapU = Get-DriveMapUrl $dr
        [void]$sp.Children.Add((New-Tb433 (($parts -join ' · ') + $(if ($mapU) { ' · MAP ›' } else { '' })) 10 'Caption'))
        $b.Child = $sp
        if ($mapU) { $b.Cursor = [System.Windows.Input.Cursors]::Hand; $b.ToolTip = 'Open this drive in Google Maps'; $b.Tag = $mapU; $b.Add_MouseLeftButtonUp({ param($s1, $e1) Open-Url433 ([string]$s1.Tag) }) }
        [void]$ui.DrivesList.Children.Add($b)
    }
    $hist = @(Get-LocationHistory | Select-Object -First 6)
    foreach ($h in $hist) {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
        $tm = New-Tb433 ((ConvertFrom-Epoch ([int64]$h.atEpoch)).ToString('ddd h:mm tt', $Inv)) 10 'Caption'; [System.Windows.Controls.DockPanel]::SetDock($tm, 'Right'); [void]$row.Children.Add($tm)
        $pl = New-Tb433 ('•  ' + $h.place) 10.5 'TextSoft'; [void]$row.Children.Add($pl)
        if ($h.url) { $row.Cursor = [System.Windows.Input.Cursors]::Hand; $row.Background = [System.Windows.Media.Brushes]::Transparent; $row.ToolTip = 'Open in Google Maps'; $row.Tag = $h.url; $row.Add_MouseLeftButtonUp({ param($s2, $e2) Open-Url433 ([string]$s2.Tag) }) }
        [void]$ui.HistList.Children.Add($row)
    }
    $ui.HistMapBtn.IsEnabled = ($null -ne (Get-HistoryMapUrl))
    Set-Visible $ui.HistHdr.Parent ($hist.Count -gt 0)
}

function Set-StateBtn {
    # green border + green title when this button shows the car's current state
    param($Btn, $Txt, $Sub, [bool]$Active, [string]$SubText)
    $Btn.BorderBrush = $(if ($Active) { T 'Green' } else { T 'BtnBorder' })
    $Btn.Background = $(if ($Active) { T 'BtnActive' } else { T 'BtnBg' })
    $Txt.Foreground = $(if ($Active) { T 'Green' } else { T 'Text' })
    $Sub.Text = $SubText
    $Sub.Foreground = $(if ($Active) { T 'Green' } else { T 'Caption' })
}
function Render-Controls42 {
    param([bool]$En)
    $car = Get-CtlCar; $have = ($null -ne $car)
    # charging
    $cs = Get-ChgState
    $plugged = ($have -and $cs -and $cs -ne 'Disconnected')
    $chg = ($cs -eq 'Charging')
    Set-StateBtn $ui.ChgStartBtn $ui.ChgStartTxt $ui.ChgStartSub $chg $(if ($chg) { 'CHARGING NOW' } elseif (-not $plugged) { 'NOT PLUGGED IN' } else { 'TAP TO START' })
    $stopTxt = $(switch ($cs) { 'Charging' { 'TAP TO STOP' } 'Complete' { 'COMPLETE' } 'Stopped' { 'STOPPED' } 'NoPower' { 'NO POWER' } 'Starting' { 'STARTING…' } 'Disconnected' { 'NOT PLUGGED IN' } default { if ($cs) { $cs.ToUpperInvariant() } else { 'STATE UNKNOWN' } } })
    Set-StateBtn $ui.ChgStopBtn $ui.ChgStopTxt $ui.ChgStopSub ($plugged -and -not $chg) $stopTxt
    if ($plugged -and -not $chg) { $ui.ChgStopBtn.BorderBrush = T 'TextSoft'; $ui.ChgStopTxt.Foreground = T 'Text'; $ui.ChgStopSub.Foreground = T 'TextSoft' }
    $ui.ChgStartBtn.IsEnabled = ($En -and $plugged -and -not $chg); $ui.ChgStopBtn.IsEnabled = ($En -and $chg)
    # amps slider
    $b = Get-AmpsBounds; $a = Get-ShownAmps
    $ui.AmpsMinLbl.Text = ('{0} A' -f $b[0]); $ui.AmpsMaxLbl.Text = ('{0} A max' -f $b[1])
    if (-not $script:DraggingAmps) {
        if ($null -ne $a) { $ui.AmpsVal.Text = ('{0} A' -f [int]$a); Set-AmpsThumbAt ([double]$a); Set-Visible $ui.AmpsThumb $true } else { $ui.AmpsVal.Text = '-- A'; $ui.AmpsFill.Width = 0; Set-Visible $ui.AmpsThumb $false }
    }
    $ui.AmpsNow.Text = $(if ($chg -and $have -and $null -ne $car.amps) { ('drawing {0} A now' -f [int]$car.amps) } elseif ($have -and $null -ne $car.ampsMax) { ('charger allows up to {0} A' -f [int]$car.ampsMax) } else { '' })
    $ui.AmpsFill.Fill = $(if ($null -ne $script:View) { T (Get-AccentKey $script:View.accent) } else { T 'Grey' })
    $ui.AmpsThumb.IsEnabled = ($En -and $null -ne $a)
    # heat / defrost / cabin overheat protection
    $heat = Test-HeatOn
    $ui.HeatTxt.Text = $(if ($heat) { 'HEAT ON' } else { 'HEAT' })
    $ui.HeatSub.Text = $(if ($heat) { 'climate on · ' + (Format-Temp (Get-ShownTempC)) } else { 'climate on at ' + (Format-Temp (Get-HeatC)) })
    $hb = Get-HeatBrush 2
    $ui.HeatBtn.BorderBrush = $(if ($heat) { $hb } else { T 'BtnBorder' }); $ui.HeatTxt.Foreground = $(if ($heat) { $hb } else { T 'Text' }); $ui.HeatIcon.Foreground = $ui.HeatTxt.Foreground
    $ui.HeatSub.Foreground = $(if ($heat) { $hb } else { T 'Caption' })
    $d = Get-DefrostOn
    $don = ($null -ne $d -and [bool]$d)
    Set-StateBtn $ui.DefrostBtn $ui.DefrostTxt $ui.DefrostSub $don $(if ($null -eq $d) { 'state unknown' } elseif ($don) { 'MAX · ON' } else { 'MAX · OFF' })
    $ui.DefrostIcon.Foreground = $ui.DefrostTxt.Foreground
    $m = Get-CopMode
    $copOn = ($m -eq 'On' -or $m -eq 'FanOnly')
    Set-StateBtn $ui.CopBtn $ui.CopTxt $ui.CopSub $copOn $(switch ($m) { 'On' { 'PROTECT: ON' } 'FanOnly' { 'PROTECT: FAN ONLY' } 'Off' { 'PROTECT: OFF' } default { 'state unknown' } })
    $ui.CopIcon.Foreground = $ui.CopTxt.Foreground
    foreach ($n in 'HeatBtn', 'DefrostBtn', 'CopBtn') { $ui[$n].IsEnabled = $En }
    if ($have -and $null -ne $car.copAllowed -and -not [bool]$car.copAllowed) { $ui.CopBtn.IsEnabled = $false; $ui.CopSub.Text = 'not available' }
    Render-Seats $En
}

# ---------------- v4.2 Alexa announcements (Voice Monkey API v3) ----------------
# POST https://api-v3.voicemonkey.io/announce  { token, device, speech }   (docs: voicemonkey.io/docs/api/announcement.html)
# The Voice Monkey token is stored encrypted for this Windows user (DPAPI) in voicemonkey.token.dpapi; never in config.json.
# Nothing is announced unless: the Alexa toggle is on, Voice Monkey is set up (token + device) and the announcement
# disclosure was accepted (config.json consent.announcements). Dry runs (self-test, controls.dryRun, announce.dryRun) only log the text.
$VmApi = 'https://api-v3.voicemonkey.io'
$VmTokenPath = Join-Path $scriptDir 'voicemonkey.token.dpapi'
$AnnounceScript = Join-Path $scriptDir 'TessDesk-Announce.ps1'
$AnnTaskPrefix = 'TessDesk Announce'
$script:AnnLog = @()
$script:AnnMock = [bool]$SelfTest   # self-test: pretend Voice Monkey is set up; every announcement is DRY RUN (printed, never sent)
$script:AnnSent = 0
function Get-AnnCfg { $a = $null; if ($null -ne $script:Cfg) { $a = $script:Cfg.announce }; return $a }
function Get-VmToken {
    if (-not (Test-Path -LiteralPath $VmTokenPath)) { return $null }
    try {
        $ss = (Get-Content -LiteralPath $VmTokenPath -Raw).Trim() | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { Write-WidgetLog ('voice monkey token read failed: ' + $_.Exception.Message); return $null }
}
function Save-VmToken { param([string]$Tok) ($Tok.Trim() | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content -LiteralPath $VmTokenPath -Encoding ASCII }
function Get-VmDevice { if ($script:AnnMock) { return 'selftest-mock-speaker' }; $a = Get-AnnCfg; if ($null -ne $a -and $a.device) { return [string]$a.device }; return '' }
function Test-AnnConsent { return ($null -ne $script:Consent -and [bool]$script:Consent.announcements) }
function Test-AnnReady { if ($script:AnnMock) { return $true }; return ((Test-AnnConsent) -and (Test-Path -LiteralPath $VmTokenPath) -and ([bool](Get-VmDevice) -or @(Get-SpeakerList).Count -gt 0)) }
function Test-AnnDryRun { $a = Get-AnnCfg; return ([bool]$SelfTest -or [bool]$CTL_DRYRUN -or ($null -ne $a -and [bool]$a.dryRun)) }
function Get-SpokenTemp { param($C) if ($null -eq $C) { return 'unknown' }; if (Test-UnitsF) { return ('{0:N0} degrees' -f ([double]$C * 9 / 5 + 32)) }; return ('{0:0.#} degrees' -f [double]$C) }
$script:VmSendBlock = {
    param($Api, $Tok, $Dev, $Text)
    try {
        $body = @{ token = $Tok; device = $Dev; speech = $Text } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod -Uri ($Api + '/announce') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 20 -UseBasicParsing
        return [pscustomobject]@{ ok = $true; info = ($r | ConvertTo-Json -Compress -Depth 3) }
    } catch {
        $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        return [pscustomobject]@{ ok = $false; code = $code; error = $_.Exception.Message }
    }
}
$script:AnnJobs = New-Object System.Collections.ArrayList
function Send-Announcement {
    # Background, never blocks the widget. Returns the log record. -Force: send even if the toggle is off (rundown, charging started, test).
    # v4.3: goes to every chosen speaker (default All Echos) in turn; -Parts = sequential announcements; -Lock = cross-PC lock (charging started).
    param([string]$Text, [string]$Why = 'action', [switch]$Force, [string[]]$Parts, [scriptblock]$OnDone, [switch]$Lock)
    if (-not $Parts -or @($Parts).Count -eq 0) { $Parts = @($Text) }
    if (-not $Text) { $Text = (@($Parts) -join ' ') }
    $devs = @(Get-AnnTargets $Why)
    $rec = [ordered]@{ at = (Get-LocalNow).ToString('s'); why = $Why; text = $Text; parts = @($Parts); devices = $devs; device = ($devs -join ', '); dryRun = (Test-AnnDryRun); sent = $false; result = '' }
    if (-not $Force -and -not [bool]$script:AlexaOn) { $rec.result = 'skipped: Alexa toggle off' }
    elseif (-not (Test-AnnConsent) -and -not $script:AnnMock) { $rec.result = 'skipped: announcement disclosure not accepted' }
    elseif (-not (Test-AnnReady)) { $rec.result = 'skipped: Voice Monkey not set up (token + device)' }
    elseif ($devs.Count -eq 0) { $rec.result = 'skipped: no speaker selected (Announce Setup)' }
    elseif ($rec.dryRun) {
        $rec.result = ('DRY RUN: not sent to Voice Monkey (would go to {0} speaker{1}: {2}{3})' -f $devs.Count, $(if ($devs.Count -eq 1) { '' } else { 's' }), ($devs -join ', '), $(if ($Lock) { '; cross-PC lock not used' } else { '' }))
        $n = @($Parts).Count; for ($i = 0; $i -lt $n; $i++) { Write-WidgetLog ('announce [DRY RUN] ' + $Why + ' part ' + ($i + 1) + '/' + $n + ' -> ' + ($devs -join ', ') + ': ' + $Parts[$i]) }
        if ($null -ne $OnDone) { try { & $OnDone ([pscustomobject]@{ ok = $true; dryRun = $true; okCount = 0; total = $devs.Count * $n }) } catch {} }
    }
    else {
        $tok = Get-VmToken
        if (-not $tok) { $rec.result = 'skipped: Voice Monkey token unreadable' } else {
            $gaps = @(); for ($i = 0; $i -lt @($Parts).Count - 1; $i++) { $gaps += [int]((Get-WordCount $Parts[$i]) / $AnnWps * 1000 + 2500) }
            $ps = [powershell]::Create()
            [void]$ps.AddScript($script:VmSeqBlock).AddArgument($VmApi).AddArgument($tok).AddArgument([string[]]$devs).AddArgument([string[]]@($Parts)).AddArgument([int[]]$gaps).AddArgument($(if ($Lock) { [string]$env:COMPUTERNAME } else { '' })).AddArgument($ChgLockVar).AddArgument($ChgLockWindowSec)
            [void]$script:AnnJobs.Add([pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke(); rec = $rec; onDone = $OnDone })
            $script:AnnSent++; $rec.sent = $true; $rec.result = 'sending'
            $script:AnnTimer.Start()
        }
    }
    $script:AnnLog = @(@($script:AnnLog) + $rec) | Select-Object -Last 40
    return $rec
}
function Complete-AnnJobs {
    foreach ($j in @($script:AnnJobs)) {
        if (-not $j.async.IsCompleted) { continue }
        $res = $null; try { $o = $j.ps.EndInvoke($j.async); if ($o.Count -gt 0) { $res = $o[$o.Count - 1] } } catch {}
        try { $j.ps.Dispose() } catch {}
        $j.rec.result = $(if ($null -ne $res -and $res.skipped) { 'skipped: ' + $res.skipped } elseif ($null -ne $res -and $res.ok) { 'announced (' + $res.okCount + ' send' + $(if ($res.okCount -eq 1) { '' } else { 's' }) + ')' } elseif ($null -ne $res -and $res.partial) { 'partly announced: ' + $res.okCount + '/' + $res.total + ' (' + $(if ($res.code) { 'HTTP ' + $res.code } else { $res.error }) + ')' } else { 'failed: ' + $(if ($null -ne $res) { if ($res.code) { 'HTTP ' + $res.code } else { $res.error } } else { 'no response' }) })
        if ($null -ne $res -and @($res.notes).Count -gt 0) { $j.rec.lock = @($res.notes) }
        Write-WidgetLog ('announce ' + $j.rec.why + ': ' + $j.rec.result)
        if ($null -ne $j.onDone) { try { & $j.onDone $res } catch { Write-WidgetLog ('announce done handler: ' + $_.Exception.Message) } }
        [void]$script:AnnJobs.Remove($j)
    }
    if ($script:AnnJobs.Count -eq 0) { $script:AnnTimer.Stop() }
}
# What Alexa says after a control command comes back (only after the result is known).
$CmdSpoken = @{
    lock = 'lock your Tesla'; unlock = 'unlock your Tesla'; vent_windows = 'vent the windows'; close_windows = 'close the windows'
    start_climate = 'turn on climate'; stop_climate = 'turn off climate'; set_temperatures = 'set the cabin temperature'
    start_max_defrost = 'turn on defrost'; stop_max_defrost = 'turn off defrost'; set_cabin_overheat_protection = 'change cabin overheat protection'
    set_seat_heat = 'change the seat heat'; start_steering_wheel_heater = 'turn on the steering wheel heat'; stop_steering_wheel_heater = 'turn off the steering wheel heat'
    start_charging = 'start charging'; stop_charging = 'stop charging'; set_charge_limit = 'set the charge limit'; set_charging_amps = 'set the charging current'
}
function Get-ActionSpeech {
    param($Job, [bool]$Ok, [string]$Why)
    if ($Ok) {
        if ($Job.ann) { return [string]$Job.ann }
        switch ($Job.cmd) {
            'lock' { return 'Your Tesla is now locked.' } 'unlock' { return 'Your Tesla is now unlocked.' }
            'activate_rear_trunk' { return 'Your Tesla trunk is moving.' } 'enable_sentry' { return 'Sentry Mode is now on.' } 'disable_sentry' { return 'Sentry Mode is now off.' }
            'vent_windows' { return 'Your Tesla windows are now vented.' } 'close_windows' { return 'Your Tesla windows are now closed.' }
            'start_climate' { return 'Climate is now on.' } 'stop_climate' { return 'Climate is now off.' }
            'set_temperatures' { return ('Climate set to ' + (Get-SpokenTemp ([double]::Parse([string]$Job.query.temperature, $Inv))) + '.') }
            'set_charge_limit' { return ('Charge limit set to ' + $Job.query.percent + ' percent.') }
            default { return ('Done: ' + $Job.okText + '.') }
        }
    }
    $what = $CmdSpoken[$Job.cmd]; if (-not $what) { $what = $Job.cmd -replace '_', ' ' }
    return ('TessDesk could not ' + $what + '. The command failed' + $(if ($Why -match 'token') { ' because the Tessie token was rejected' } elseif ($Why -match 'timed out|no response') { ' because the car did not respond' } else { '' }) + '.')
}

# Scheduled announcements = per-user Windows scheduled tasks running TessDesk-Announce.ps1 -Type cost|tires|status.
# They read cached Tessie data only (use_cache=true, never wakes the car) and the widget's last totals.
$AnnTypes = [ordered]@{ cost = 'Charging cost'; tires = 'Tire pressure'; status = 'Vehicle status' }
$DayNames = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
$DayFull = @{ Mon = 'Monday'; Tue = 'Tuesday'; Wed = 'Wednesday'; Thu = 'Thursday'; Fri = 'Friday'; Sat = 'Saturday'; Sun = 'Sunday' }
function Get-AnnSchedules {
    $a = Get-AnnCfg; $out = [ordered]@{}
    foreach ($k in $AnnTypes.Keys) {
        $s = $null; if ($null -ne $a -and $null -ne $a.schedules) { $s = $a.schedules.$k }
        $times = @(); if ($null -ne $s -and $null -ne $s.times) { foreach ($t in @($s.times)) { $times += [ordered]@{ time = [string]$t.time; days = @($t.days | ForEach-Object { [string]$_ }) } } }
        $out[$k] = [ordered]@{ enabled = ($null -ne $s -and [bool]$s.enabled); times = $times }
    }
    return $out
}
function Sync-AnnounceTasks {
    # Remove this install's announce tasks, then register one weekly task per (type, time). Returns what is registered.
    param($Schedules, [string]$Prefix = $AnnTaskPrefix, [switch]$DryRunTasks)
    $reg = @()
    $mine = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like ($Prefix + ' *') -and [string]$_.Description -like ('*' + $scriptDir + '*') })
    foreach ($t in $mine) { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction SilentlyContinue }
    if (-not (Test-AnnReady) -and -not $DryRunTasks) { return @() }
    foreach ($k in $Schedules.Keys) {
        $s = $Schedules[$k]; if (-not [bool]$s.enabled) { continue }
        $i = 0
        foreach ($t in @($s.times)) {
            $i++
            $days = @($t.days | Where-Object { $DayFull.ContainsKey($_) } | ForEach-Object { $DayFull[$_] }); if ($days.Count -eq 0) { continue }
            $at = [datetime]::ParseExact([string]$t.time, 'HH:mm', $Inv)
            $name = ('{0} {1} {2}' -f $Prefix, $k, $i)
            $arg = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Type {1}{2}' -f $AnnounceScript, $k, $(if ($DryRunTasks) { ' -DryRun' } else { '' }))
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $scriptDir
            $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $at
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
            $pr = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Settings $set -Principal $pr -Description ('TessDesk scheduled Alexa announcement (' + $AnnTypes[$k] + '). Install: ' + $scriptDir) -Force | Out-Null
            $reg += [ordered]@{ task = $name; type = $k; time = $t.time; days = @($t.days); dryRun = [bool]$DryRunTasks }
        }
    }
    Write-WidgetLog ('announce tasks synced: ' + $reg.Count)
    return $reg
}
function Get-AnnTaskList {
    return @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like ($AnnTaskPrefix + ' *') -and [string]$_.Description -like ('*' + $scriptDir + '*') } | ForEach-Object {
        [ordered]@{ task = $_.TaskName; start = [string]$_.Triggers[0].StartBoundary; days = [string]$_.Triggers[0].DaysOfWeek; state = [string]$_.State } })
}
function Set-AlexaToggle {
    param([bool]$On, [bool]$Save = $true)
    $script:AlexaOn = $On
    $ui.AlexaToggle.IsChecked = $On
    $ui.AlexaLbl.Foreground = $(if ($On) { T 'Text' } else { T 'Caption' })
    $ui.AlexaBox.ToolTip = $(if ($On -and -not (Test-AnnReady)) { 'Alexa is ON but Voice Monkey is not set up yet: open the clock button > Connected apps' } elseif ($On) { 'Alexa ON: control results are announced on ' + (Get-VmDevice) } else { 'Alexa OFF: tap to announce control results (Voice Monkey)' })
    if ($Save) {
        $a = Get-AnnCfg; $o = [ordered]@{}
        if ($null -ne $a) { foreach ($p in $a.PSObject.Properties) { $o[$p.Name] = $p.Value } }
        $o['actions'] = $On
        try { Save-ConfigProp 'announce' $o; $script:Cfg = Read-Config } catch { Write-WidgetLog ('alexa toggle save failed: ' + $_.Exception.Message) }
    }
}

# Settings: Connected apps (Tessie, Voice Monkey, Alexa) + scheduled announcements.
function New-Txt { param([string]$T, [double]$Size = 12, [string]$W = 'Normal', [string]$Col = 'TextSoft') $b = New-Object System.Windows.Controls.TextBlock; $b.Text = $T; $b.FontSize = $Size; $b.FontWeight = $W; $b.Foreground = (T $Col); $b.TextWrapping = 'Wrap'; return $b }
function New-Link {
    param([string]$T, [string]$Url)
    $tb = New-Object System.Windows.Controls.TextBlock; $tb.Margin = '0,2,0,0'; $tb.FontSize = 11.5
    $hl = New-Object System.Windows.Documents.Hyperlink; [void]$hl.Inlines.Add($T); $hl.NavigateUri = [Uri]$Url; $hl.Foreground = T 'Green'
    $hl.Add_RequestNavigate({ param($s5, $e5) if (-not $SelfTest) { try { Start-Process $e5.Uri.AbsoluteUri } catch {} } })
    [void]$tb.Inlines.Add($hl); return $tb
}
function New-Sec { param([string]$T) $b = New-Txt $T 13.5 'Bold' 'Text'; $b.Margin = '0,14,0,4'; return $b }
function New-TimeRow {
    param($HostObj, [string]$Time = '07:30', [string[]]$Days = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'))
    $row = New-Object System.Windows.Controls.WrapPanel; $row.Margin = '18,3,0,0'
    $h = New-Object System.Windows.Controls.ComboBox; $h.Width = 46; foreach ($x in 1..12) { [void]$h.Items.Add([string]$x) }
    $m = New-Object System.Windows.Controls.ComboBox; $m.Width = 50; $m.Margin = '3,0,0,0'; foreach ($x in 0..11) { [void]$m.Items.Add(('{0:00}' -f ($x * 5))) }
    $ap = New-Object System.Windows.Controls.ComboBox; $ap.Width = 50; $ap.Margin = '3,0,8,0'; [void]$ap.Items.Add('AM'); [void]$ap.Items.Add('PM')
    $dt = [datetime]::ParseExact($Time, 'HH:mm', $Inv)
    $h.SelectedItem = [string]$(if ($dt.Hour % 12 -eq 0) { 12 } else { $dt.Hour % 12 }); $mm = [int]([math]::Round($dt.Minute / 5) * 5) % 60; $m.SelectedItem = ('{0:00}' -f $mm); $ap.SelectedItem = $(if ($dt.Hour -ge 12) { 'PM' } else { 'AM' })
    foreach ($c in $h, $m, $ap) { [void]$row.Children.Add($c) }
    $cbs = @{}
    foreach ($d in $DayNames) { $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = $d.Substring(0, 2); $cb.Foreground = T 'TextSoft'; $cb.Margin = '0,3,6,0'; $cb.IsChecked = ($Days -contains $d); $cbs[$d] = $cb; [void]$row.Children.Add($cb) }
    $rm = New-Object System.Windows.Controls.Button; $rm.Content = 'Remove'; $rm.Padding = '6,0,6,0'; $rm.Margin = '4,0,0,0'
    $entry = [pscustomobject]@{ row = $row; h = $h; m = $m; ap = $ap; days = $cbs; host = $HostObj }
    $rm.Tag = $entry
    $rm.Add_Click({ param($s6, $e6) $en = $s6.Tag; [void]$en.host.panel.Children.Remove($en.row); [void]$en.host.rows.Remove($en) })
    [void]$row.Children.Add($rm)
    [void]$HostObj.rows.Add($entry); [void]$HostObj.panel.Children.Add($row)
    return $entry
}
function Get-TimeRowValue {
    param($E)
    $hh = [int]$E.h.SelectedItem % 12; if ([string]$E.ap.SelectedItem -eq 'PM') { $hh += 12 }
    return [ordered]@{ time = ('{0:00}:{1}' -f $hh, $E.m.SelectedItem); days = @($DayNames | Where-Object { [bool]$E.days[$_].IsChecked }) }
}
function Test-TessieNow {
    $tok = $null; try { $tok = Get-TessieToken } catch {}
    if (-not $tok) { return 'No Tessie token found (tessie.token / tessie.token.dpapi)' }
    if (-not $script:VIN) { return 'Token found; no VIN yet' }
    if ($SelfTest) { return 'Token found (check skipped in self-test)' }
    try { $s = Invoke-Tessie ('/' + $script:VIN + '/state?use_cache=true') $tok; return ('OK: ' + [string]$s.display_name + ' · ' + [string]$s.charge_state.battery_level + '% (cached data, car not woken)') } catch { return ('Check failed: ' + (Get-HttpErrorNote $_)) }
}
function Test-VoiceMonkeyNow {
    param([string]$Tok, [string]$Dev)
    if (-not $Tok) { return 'Enter your Voice Monkey API token first (app.voicemonkey.io/tokens)' }
    if ($SelfTest) { return 'Check skipped in self-test (mocked)' }
    try {
        $r = Invoke-RestMethod -Uri ($VmApi + '/devices') -Headers @{ Authorization = ('Bearer ' + $Tok) } -Method Get -TimeoutSec 15 -UseBasicParsing
        $sp = @($r.data | Where-Object { $_.capability -eq 'speakers' })
        $hit = @($sp | Where-Object { $_.id -eq $Dev -or $_.name -eq $Dev })
        if ($Dev -and $hit.Count -gt 0) { return ('OK: token valid, speaker "' + $hit[0].name + '" (' + $hit[0].id + ') found') }
        return ('Token valid. Speakers on your account: ' + ((@($sp | ForEach-Object { $_.id }) -join ', ')) + $(if ($Dev) { '. "' + $Dev + '" was not found.' } else { '' }))
    } catch { $c = $null; try { $c = [int]$_.Exception.Response.StatusCode } catch {}; return ('Check failed' + $(if ($c) { ': HTTP ' + $c + $(if ($c -eq 401) { ' (token not valid)' } else { '' }) } else { ': ' + $_.Exception.Message })) }
}
function Show-AnnounceWindow {
    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'TessDesk · Connected apps and Alexa announcements'; $dlg.Width = 600; $dlg.Height = [math]::Min(900, [System.Windows.SystemParameters]::WorkArea.Height - 40)
    $dlg.WindowStartupLocation = 'CenterScreen'; $dlg.Background = T 'RootBg'; $dlg.Foreground = T 'Text'; $dlg.FontFamily = $window.FontFamily
    try { if (Test-Path -LiteralPath $iconPath) { $dlg.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) } } catch {}
    $outer = New-Object System.Windows.Controls.DockPanel
    $sv = New-Object System.Windows.Controls.ScrollViewer; $sv.VerticalScrollBarVisibility = 'Auto'
    $root = New-Object System.Windows.Controls.StackPanel; $root.Margin = '18,10,18,10'; $sv.Content = $root
    [void]$root.Children.Add((New-Txt 'Connected apps' 17 'Bold' 'Text'))
    # Tessie
    [void]$root.Children.Add((New-Sec 'Tessie (vehicle data + commands)'))
    $tsrc = $(if (Test-Path -LiteralPath ($CredFile + '.dpapi')) { 'token saved (encrypted, DPAPI)' } elseif (Test-Path -LiteralPath $CredFile) { 'token file: ' + (Split-Path -Leaf $CredFile) + ' (plain text; TessDesk Setup can encrypt it)' } else { 'no token yet' })
    [void]$root.Children.Add((New-Txt ('Status: ' + $tsrc + $(if ($script:VIN) { ' · VIN …' + $script:VIN.Substring([math]::Max(0, $script:VIN.Length - 6)) } else { '' }))))
    $tRes = New-Txt '' 11.5 'Normal' 'Caption'
    $bT = New-Object System.Windows.Controls.Button; $bT.Content = 'Check'; $bT.Padding = '12,2,12,2'; $bT.HorizontalAlignment = 'Left'; $bT.Margin = '0,4,0,0'; $bT.Tag = $tRes
    $bT.Add_Click({ param($s7, $e7) $s7.Tag.Text = Test-TessieNow })
    [void]$root.Children.Add($bT); [void]$root.Children.Add($tRes)
    [void]$root.Children.Add((New-Link 'Get a Tessie API token (tessie.com > Settings > API)' 'https://dash.tessie.com/settings/api'))
    # Voice Monkey
    [void]$root.Children.Add((New-Sec 'Voice Monkey (Alexa announcements)'))
    $haveTok = Test-Path -LiteralPath $VmTokenPath
    [void]$root.Children.Add((New-Txt $(if ($haveTok) { 'API token: saved (encrypted for your Windows user with DPAPI). Leave the box empty to keep it.' } else { 'API token: not set. Paste it from app.voicemonkey.io/tokens. It is stored encrypted (DPAPI), never in config.json.' }) 11.5))
    $pb = New-Object System.Windows.Controls.PasswordBox; $pb.Margin = '0,4,0,0'; $pb.Height = 26
    [void]$root.Children.Add($pb)
    [void]$root.Children.Add((New-Txt 'Speaker device ID or name (from the Voice Monkey dashboard > Devices, e.g. echo-living-room-xxxxx)' 11.5))
    $tbDev = New-Object System.Windows.Controls.TextBox; $tbDev.Margin = '0,4,0,0'; $tbDev.Height = 26; $tbDev.Text = (Get-VmDevice)
    [void]$root.Children.Add($tbDev)
    $vRes = New-Txt '' 11.5 'Normal' 'Caption'
    $bp1 = New-Object System.Windows.Controls.StackPanel; $bp1.Orientation = 'Horizontal'; $bp1.Margin = '0,6,0,0'
    $bV = New-Object System.Windows.Controls.Button; $bV.Content = 'Check'; $bV.Padding = '12,2,12,2'
    $bS = New-Object System.Windows.Controls.Button; $bS.Content = 'Send test announcement'; $bS.Padding = '12,2,12,2'; $bS.Margin = '8,0,0,0'
    [void]$bp1.Children.Add($bV); [void]$bp1.Children.Add($bS); [void]$root.Children.Add($bp1); [void]$root.Children.Add($vRes)
    $cbDis = New-Object System.Windows.Controls.CheckBox; $cbDis.Margin = '0,8,0,0'; $cbDis.Foreground = T 'Text'; $cbDis.IsChecked = (Test-AnnConsent)
    $cbDis.Content = (New-Txt 'I understand: the text of each announcement (for example charging cost, tire pressures, battery, lock and window state) is sent to Voice Monkey and Amazon (Alexa) so it can be spoken on my Echo. TessDesk sends nothing else there.' 11.5 'SemiBold' 'Text')
    [void]$root.Children.Add($cbDis)
    $script:AnnDlg = @{ pb = $pb; dev = $tbDev; vres = $vRes; dis = $cbDis }
    $bV.Add_Click({ $tok = $script:AnnDlg.pb.Password; if (-not $tok) { $tok = Get-VmToken }; $script:AnnDlg.vres.Text = Test-VoiceMonkeyNow $tok $script:AnnDlg.dev.Text.Trim()
        if (-not $SelfTest -and $tok) { try { $l = @(Get-VmSpeakers $tok); if ($l.Count -gt 0) { Save-AnnProps @{ speakerList = $l }; $script:AnnDlg.vres.Text += (' · ' + $l.Count + ' speaker(s) saved for All Echos') } } catch {} } })
    $bS.Add_Click({
        if (-not [bool]$script:AnnDlg.dis.IsChecked) { $script:AnnDlg.vres.Text = 'Tick the disclosure box first.'; return }
        $tok = $script:AnnDlg.pb.Password; if (-not $tok) { $tok = Get-VmToken }
        $dev = $script:AnnDlg.dev.Text.Trim()
        if (-not $tok -or -not $dev) { $script:AnnDlg.vres.Text = 'Enter the API token and the speaker device first.'; return }
        $txt = 'This is a TessDesk test announcement. Alexa announcements are working.'
        if (Test-AnnDryRun) { $script:AnnDlg.vres.Text = 'DRY RUN: would announce "' + $txt + '" on ' + $dev; return }
        $r = & $script:VmSendBlock $VmApi $tok $dev $txt
        $script:AnnDlg.vres.Text = $(if ($r.ok) { 'Sent. You should hear it on ' + $dev + ' now.' } else { 'Failed: ' + $(if ($r.code) { 'HTTP ' + $r.code } else { $r.error }) })
    })
    # Alexa
    [void]$root.Children.Add((New-Sec 'Alexa'))
    [void]$root.Children.Add((New-Txt 'Voice Monkey speaks through your Echo. In the Alexa app enable the Voice Monkey skill and link your Amazon account, then sign in to the Voice Monkey dashboard and create a Speaker device for the Echo you want (that is the device ID above). Create an API token there too.' 11.5))
    [void]$root.Children.Add((New-Txt 'Getting started' 12 'Bold' 'Text'))
    [void]$root.Children.Add((New-Link '1. Sign up / sign in to Voice Monkey (voicemonkey.io)' 'https://voicemonkey.io'))
    [void]$root.Children.Add((New-Link '2. Enable the Voice Monkey skill in the Alexa app (Amazon skill page)' 'https://www.amazon.com/dp/B08C6Z4C3R'))
    [void]$root.Children.Add((New-Link '3. Voice Monkey dashboard: create a Speaker device' 'https://app.voicemonkey.io'))
    [void]$root.Children.Add((New-Link '4. Voice Monkey dashboard: create an API token' 'https://app.voicemonkey.io/tokens'))
    # schedules
    [void]$root.Children.Add((New-Sec 'Scheduled announcements'))
    [void]$root.Children.Add((New-Txt 'Each one runs as a Windows scheduled task for your user. It uses Tessie''s cached data (it never wakes the car) and the widget''s latest totals. Times are this PC''s local time.' 11.5 'Normal' 'Caption'))
    $sch = Get-AnnSchedules; $hosts = [ordered]@{}
    $desc = @{ cost = 'last night''s or tonight''s charging cost and kWh, plus the last 7 days'; tires = 'all four tire pressures; flags any low or high'; status = 'battery %, range, charging state, locks, windows and climate' }
    foreach ($k in $AnnTypes.Keys) {
        $cb = New-Object System.Windows.Controls.CheckBox; $cb.Margin = '0,10,0,0'; $cb.Foreground = T 'Text'; $cb.IsChecked = [bool]$sch[$k].enabled
        $cb.Content = (New-Txt ($AnnTypes[$k] + ': ' + $desc[$k]) 12 'SemiBold' 'Text')
        [void]$root.Children.Add($cb)
        $pn = New-Object System.Windows.Controls.StackPanel; [void]$root.Children.Add($pn)
        $hs = [pscustomobject]@{ panel = $pn; rows = (New-Object System.Collections.ArrayList); cb = $cb }
        $hosts[$k] = $hs
        $ts = @($sch[$k].times); if ($ts.Count -eq 0) { $ts = @([ordered]@{ time = $(switch ($k) { 'cost' { '07:00' } 'tires' { '07:30' } default { '18:00' } }); days = $DayNames }) }
        foreach ($t in $ts) { [void](New-TimeRow $hs $t.time @($t.days)) }
        $add = New-Object System.Windows.Controls.Button; $add.Content = '+ Add time'; $add.Padding = '8,0,8,0'; $add.Margin = '18,4,0,0'; $add.HorizontalAlignment = 'Left'; $add.Tag = $hs
        $add.Add_Click({ param($s8, $e8) [void](New-TimeRow $s8.Tag) })
        [void]$root.Children.Add($add)
    }
    $tl = @(Get-AnnTaskList)
    [void]$root.Children.Add((New-Txt ('Scheduled tasks now: ' + $(if ($tl.Count -eq 0) { 'none' } else { (@($tl | ForEach-Object { $_.task + ' (' + $_.days + ' ' + $_.start.Substring(11, 5) + ')' }) -join '; ') })) 10.5 'Normal' 'Caption'))
    # buttons
    $bar = New-Object System.Windows.Controls.StackPanel; $bar.Orientation = 'Horizontal'; $bar.HorizontalAlignment = 'Right'; $bar.Margin = '18,8,18,12'
    $bC = New-Object System.Windows.Controls.Button; $bC.Content = 'Cancel'; $bC.Padding = '14,4,14,4'; $bC.Margin = '0,0,8,0'
    $bOk = New-Object System.Windows.Controls.Button; $bOk.Content = 'Save'; $bOk.Padding = '18,4,18,4'; $bOk.FontWeight = 'Bold'
    [void]$bar.Children.Add($bC); [void]$bar.Children.Add($bOk)
    [System.Windows.Controls.DockPanel]::SetDock($bar, 'Bottom'); [void]$outer.Children.Add($bar); [void]$outer.Children.Add($sv)
    $script:AnnDlg.hosts = $hosts; $script:AnnDlg.dlg = $dlg; $script:AnnSaved = $null
    $bC.Add_Click({ $script:AnnDlg.dlg.Close() })
    $bOk.Add_Click({
        $d = $script:AnnDlg
        $schOut = [ordered]@{}
        foreach ($k in $d.hosts.Keys) { $h = $d.hosts[$k]; $schOut[$k] = [ordered]@{ enabled = [bool]$h.cb.IsChecked; times = @($h.rows | ForEach-Object { Get-TimeRowValue $_ }) } }
        $script:AnnSaved = [ordered]@{ token = $d.pb.Password; device = $d.dev.Text.Trim(); disclosure = [bool]$d.dis.IsChecked; schedules = $schOut }
        $d.dlg.Close()
    })
    $dlg.Content = $outer
    try { $dlg.Owner = $window } catch {}
    [void]$dlg.ShowDialog()
    if ($null -ne $script:AnnSaved) { Save-AnnounceSettings $script:AnnSaved }
}
function Save-AnnounceSettings {
    param($S)
    if ($S.token) { Save-VmToken $S.token }
    $a = Get-AnnCfg; $o = [ordered]@{ actions = [bool]$script:AlexaOn; device = $S.device; dryRun = $false; schedules = $S.schedules }
    if ($null -ne $a -and $null -ne $a.dryRun) { $o.dryRun = [bool]$a.dryRun }
    if ($null -ne $a) { foreach ($p in $a.PSObject.Properties) { if (-not $o.Contains($p.Name)) { $o[$p.Name] = $p.Value } } }   # v4.3 keys (rundownItems, speakers, speakerList, chargingStarted)
    Save-ConfigProp 'announce' $o
    $cn = [ordered]@{}; if ($null -ne $script:Consent) { foreach ($p in $script:Consent.PSObject.Properties) { $cn[$p.Name] = $p.Value } }
    if ($cn.Count -gt 0 -or $S.disclosure) {
        $cn['announcements'] = [bool]$S.disclosure; if ($S.disclosure) { $cn['announcementsAt'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }
        Save-ConfigProp 'consent' $cn; $script:Consent = [pscustomobject]$cn
    }
    $script:Cfg = Read-Config
    $reg = @(); try { $reg = @(Sync-AnnounceTasks (Get-AnnSchedules)) } catch { Write-WidgetLog ('announce task sync failed: ' + $_.Exception.Message) }
    Set-AlexaToggle ([bool]$script:AlexaOn) $false
    $msg = $(if (-not (Test-AnnReady)) { 'Saved. Announcements stay off until the Voice Monkey token, the speaker device and the disclosure are all set.' } else { 'Saved. ' + $reg.Count + ' scheduled announcement task(s) registered.' })
    Set-CtlResult 'idle' $msg
    Write-WidgetStatus
}

# ---------------- v4.3: Announce on Alexa (full rundown), speakers (All Echos), charging-started, peak banner, vertical limit slider ----------------
# Rundown items + speakers + charging-started switch are saved in config.json "announce" (rundownItems, speakers {all, ids}, speakerList, chargingStarted).
# Voice Monkey has no device groups: GET /devices lists {id, name, capability}; /announce takes one device, so TessDesk sends to each speaker in turn.
# The nightly reminder (TessDesk-Remind.ps1) keeps using announce.device (living room) only.
$RundownItems = [ordered]@{ battery = 'Battery and range'; limit = 'Charge limit'; rate = 'Charge rate (kW and amps)'; tofull = 'Time to full'
    cost = 'Tonight''s cost (and last charge)'; climate = 'Climate and seats'; lock = 'Door lock'; windows = 'Windows'; tires = 'Tires (all four)'; warnings = 'Warnings' }
$AnnWps = 2.6; $AnnPartMaxSec = 22.0; $AnnMaxSec = 45.0
$script:AnnMem = @{}          # self-test: settings live here, config.json is never written
$script:LastRundown = $null; $script:ChgStartLog = @(); $script:PeakLog = @()
$ChgMarkPath = $(if ($SelfTest) { Join-Path $env:TEMP 'tessdesk-selftest-charging-started.json' } else { Join-Path $scriptDir 'charging-started.json' })
$PeakMarkPath = $(if ($SelfTest) { Join-Path $env:TEMP 'tessdesk-selftest-peak-toast.json' } else { Join-Path $scriptDir 'peak-toast.json' })
$ChgLockVar = 'TESSDESK_CHARGE_START'; $ChgLockWindowSec = 1800

function Get-AnnProp {
    param([string]$Name, $Default)
    if ($script:AnnMem.ContainsKey($Name)) { return $script:AnnMem[$Name] }
    $a = Get-AnnCfg
    if ($null -ne $a -and $null -ne $a.PSObject.Properties[$Name] -and $null -ne $a.$Name) { return $a.$Name }
    return $Default
}
function Save-AnnProps {
    param([hashtable]$Props)
    if ($SelfTest) { foreach ($k in $Props.Keys) { $script:AnnMem[$k] = $Props[$k] }; return }
    $o = [ordered]@{}; $a = Get-AnnCfg; if ($null -ne $a) { foreach ($p in $a.PSObject.Properties) { $o[$p.Name] = $p.Value } }
    foreach ($k in $Props.Keys) { $o[$k] = $Props[$k] }
    Save-ConfigProp 'announce' $o
    $script:Cfg = Read-Config
}
function Get-RundownSel {
    $sel = [ordered]@{}; $it = Get-AnnProp 'rundownItems' $null
    foreach ($k in $RundownItems.Keys) { $v = $true; if ($null -ne $it -and $null -ne $it.PSObject.Properties[$k]) { $v = [bool]$it.$k }; $sel[$k] = $v }
    return [pscustomobject]$sel
}
function Get-SpeakerList {
    $out = @()
    foreach ($s in @(Get-AnnProp 'speakerList' @())) { if ($null -ne $s -and [string]$s.id) { $out += [pscustomobject]@{ id = [string]$s.id; name = $(if ([string]$s.name) { [string]$s.name } else { [string]$s.id }) } } }
    return $out
}
function Get-SpeakerSel {
    $s = Get-AnnProp 'speakers' $null; $all = $true; $ids = @()
    if ($null -ne $s) { if ($null -ne $s.all) { $all = [bool]$s.all }; $ids = @(@($s.ids) | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
    return [pscustomobject]@{ all = $all; ids = $ids }
}
function Get-AnnTargets {
    # Every TessDesk announcement goes to the chosen speakers (default: All Echos). 'reminder' = the single living-room device.
    param([string]$Why = 'action')
    $dev = Get-VmDevice
    if ($Why -eq 'reminder') { return @(@($dev) | Where-Object { $_ }) }
    $sel = Get-SpeakerSel; $list = @(Get-SpeakerList)
    if ($sel.all) { $t = @($list | ForEach-Object { $_.id }) } else { $t = @($sel.ids) }
    $t = @($t | Where-Object { $_ } | Select-Object -Unique)
    if ($t.Count -eq 0 -and $dev) { $t = @($dev) }
    return $t
}
function Get-TargetLabel {
    $t = @(Get-AnnTargets 'action'); $list = @(Get-SpeakerList); $sel = Get-SpeakerSel
    if ($t.Count -eq 0) { return 'no speaker' }
    $names = @($t | ForEach-Object { $id = $_; $h = @($list | Where-Object { $_.id -eq $id }); if ($h.Count -gt 0) { $h[0].name } else { $id } })
    if ($sel.all -and $list.Count -gt 0) { return ('All Echos ({0})' -f $list.Count) }
    return ($names -join ', ')
}
function Get-VmSpeakers {
    # Read-only: GET /devices (never announces). Returns speakers {id, name}.
    param([string]$Tok)
    if (-not $Tok) { $Tok = Get-VmToken }
    if (-not $Tok) { throw 'Voice Monkey token not saved yet (Connected apps)' }
    $r = Invoke-RestMethod -Uri ($VmApi + '/devices') -Headers @{ Authorization = ('Bearer ' + $Tok) } -Method Get -TimeoutSec 15 -UseBasicParsing
    return @(@($r.data) | Where-Object { $null -ne $_ -and ([string]$_.capability -eq 'speakers' -or -not $_.capability) } | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = $(if ([string]$_.name) { [string]$_.name } else { [string]$_.id }) } })
}

# --- spoken helpers ---
function Get-SpokenMoney {
    param($v)
    if ($null -eq $v) { return 'unknown' }
    $c = [int][math]::Round([double]$v * 100); $d = [int][math]::Floor($c / 100); $cc = $c % 100
    if ($d -eq 0) { return ('{0} cent{1}' -f $cc, $(if ($cc -eq 1) { '' } else { 's' })) }
    $s = ('{0} dollar{1}' -f $d, $(if ($d -eq 1) { '' } else { 's' }))
    if ($cc -gt 0) { $s += (' and {0} cent{1}' -f $cc, $(if ($cc -eq 1) { '' } else { 's' })) }
    return $s
}
function Get-SpokenDuration {
    param($Min)
    $n = [int][math]::Round([double]$Min)
    if ($n -lt 60) { return ('{0} minute{1}' -f $n, $(if ($n -eq 1) { '' } else { 's' })) }
    $h = [int][math]::Floor($n / 60); $m = $n % 60
    $s = ('{0} hour{1}' -f $h, $(if ($h -eq 1) { '' } else { 's' }))
    if ($m -gt 0) { $s += (' {0} minute{1}' -f $m, $(if ($m -eq 1) { '' } else { 's' })) }
    return $s
}
function Get-SpokenNum { param($x) return ([double]$x).ToString('0.#', $Inv) }
function Format-HourLabel { param([int]$h) return ([datetime]::Today.AddHours($h % 24)).ToString('h tt', $Inv) }
function Get-WordCount { param([string]$t) return @(([string]$t).Trim() -split '\s+' | Where-Object { $_ }).Count }
function Split-Rundown {
    param([string[]]$S)
    $S = @($S | Where-Object { $_ })
    $all = ($S -join ' ').Trim(); $words = Get-WordCount $all; $sec = [math]::Round($words / $AnnWps, 1)
    $parts = @($all)
    if ($sec -gt $AnnPartMaxSec -and $S.Count -gt 1) {
        $half = $words / 2.0; $acc = 0; $cut = 1
        for ($i = 0; $i -lt $S.Count; $i++) { $acc += (Get-WordCount $S[$i]); if ($acc -ge $half) { $cut = $i + 1; break } }
        if ($cut -ge $S.Count) { $cut = $S.Count - 1 }; if ($cut -lt 1) { $cut = 1 }
        $parts = @((($S[0..($cut - 1)]) -join ' ').Trim(), (($S[$cut..($S.Count - 1)]) -join ' ').Trim())
    }
    return [pscustomobject]@{ parts = $parts; text = $all; words = $words; seconds = $sec; underLimit = ($sec -le $AnnMaxSec) }
}

# --- peak-price state (AC charging at home outside the overnight window) ---
function Get-DistM { param([double]$La1, [double]$Lo1, [double]$La2, [double]$Lo2) $r = 6371000.0; $p1 = $La1 * [math]::PI / 180; $p2 = $La2 * [math]::PI / 180; $dp = $p2 - $p1; $dl = ($Lo2 - $Lo1) * [math]::PI / 180; $a = [math]::Sin($dp / 2) * [math]::Sin($dp / 2) + [math]::Cos($p1) * [math]::Cos($p2) * [math]::Sin($dl / 2) * [math]::Sin($dl / 2); return (2 * $r * [math]::Atan2([math]::Sqrt($a), [math]::Sqrt(1 - $a))) }
$script:PeakNow = $null   # self-test: pretend time
# Rate periods from config.json "rates" (Van: PSO RSEV Oklahoma): off-peak ON_START-ON_END, summer weekday peak PK_S-PK_E, day rate otherwise.
function Get-RateKind { param([datetime]$At) $e = Get-EnergyRate $At; if (Test-HourIn $At.Hour $ON_START $ON_END) { return 'offpeak' }; if ($PEAK_EN -and $R_PEAK -gt 0 -and $e -eq $R_PEAK) { return 'peak' }; return 'day' }
function Get-RateLabel { param([string]$K) switch ($K) { 'offpeak' { 'Off-peak' } 'peak' { 'Peak' } default { 'Day rate' } } }
function Get-NextRateTime {
    # first top-of-hour after $At where the period differs ($Want: a specific kind)
    param([datetime]$At, [string]$Want)
    $k0 = Get-RateKind $At; $t = $At.Date.AddHours($At.Hour + 1)
    for ($i = 0; $i -lt 96; $i++) { $k = Get-RateKind $t; if (($Want -and $k -eq $Want) -or (-not $Want -and $k -ne $k0)) { return [pscustomobject]@{ at = $t; kind = $k } }; $t = $t.AddHours(1) }
    return $null
}
function Format-Left { param([double]$Min) $n = [int][math]::Max(0, [math]::Round($Min)); if ($n -ge 60) { return ('{0}h {1:00}m' -f [math]::Floor($n / 60), ($n % 60)) }; return ('{0}m' -f $n) }
function Format-C1 { param([double]$UsdPerKwh) return ('{0:N1}¢/kWh' -f ($UsdPerKwh * 100)) }
function Get-RateStatus {
    $now = $(if ($null -ne $script:PeakNow) { $script:PeakNow } else { Get-LocalNow })
    $k = Get-RateKind $now; $e = Get-EnergyRate $now
    $o = [pscustomobject]@{ mode = 'idle'; kind = $k; label = (Get-RateLabel $k); show = $false; red = ($k -eq 'peak'); rateNow = $e; allInNow = ($e + $FCA); rateOff = $R_ON; allInOff = ($R_ON + $FCA)
        offPeakLabel = (Format-HourLabel $ON_START); offEndLabel = (Format-HourLabel $ON_END); untilOffMin = $null; next = $null; extraUsd = $null; reason = ''; key = ''; now = $now }
    $o.next = Get-NextRateTime $now ''
    if ($k -ne 'offpeak') { $no = Get-NextRateTime $now 'offpeak'; if ($null -ne $no) { $o.untilOffMin = ($no.at - $now).TotalMinutes } }
    $car = Get-CtlCar; $chg = Get-ChgState
    if ($null -eq $car -or ($chg -ne 'Charging' -and $chg -ne 'Starting')) { $o.reason = 'not charging'; return $o }
    if ([bool]$car.fastCharger -or ($null -ne $car.chargerKw -and [double]$car.chargerKw -gt 25)) { $o.reason = 'DC fast charging / Supercharger (home rates do not apply)'; return $o }
    $hm = $null; if ($null -ne $script:Cfg -and $null -ne $script:Cfg.PSObject.Properties['home']) { $hm = $script:Cfg.home }
    if ($null -ne $hm -and $null -ne $hm.lat -and $null -ne $hm.lon -and $null -ne $car.lat -and $null -ne $car.lon) {
        $rad = 300.0; if ($null -ne $hm.radiusM) { $rad = [double]$hm.radiusM }
        if ((Get-DistM ([double]$hm.lat) ([double]$hm.lon) ([double]$car.lat) ([double]$car.lon)) -gt $rad) { $o.reason = 'charging away from home'; return $o }
    }
    $sk = $null; if ($null -ne $script:State -and $null -ne $script:State.session) { $sk = [string]$script:State.session.startEpoch }
    $o.key = $(if ($sk) { $sk } else { 'now-' + $now.ToString('yyyyMMdd') })
    if ($k -eq 'offpeak') { $o.mode = 'charging-offpeak'; $o.reason = 'charging off-peak'; return $o }
    $o.mode = 'charging-high'; $o.show = $true; $o.reason = $(if ($k -eq 'peak') { 'summer weekday peak' } else { 'day rate' })
    # estimated extra vs off-peak for this session: (added + still to add) at the wall x (rate now - off-peak rate)
    $added = 0.0; if ($null -ne $script:State -and $null -ne $script:State.session -and $null -ne $script:State.session.kwhAdded) { $added = [double]$script:State.session.kwhAdded }
    $rem = 0.0; if ($null -ne $car.chargerKw -and $null -ne $car.minutesToFull -and [double]$car.minutesToFull -gt 0) { $rem = [double]$car.chargerKw * [double]$car.minutesToFull / 60.0 }
    if (($added + $rem) -gt 0) { $o.extraUsd = ($added + $rem) / $EFFICIENCY * ($o.allInNow - $o.allInOff) }
    return $o
}
function Get-PeakState { return (Get-RateStatus) }
function Show-WinToast {
    param([string]$Title, [string]$Body)
    if ($SelfTest) { $script:PeakLog += ('[self-test, not shown] toast: ' + $Title + ' | ' + $Body); return }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $x = New-Object Windows.Data.Xml.Dom.XmlDocument
        $esc = { param($t) [Security.SecurityElement]::Escape([string]$t) }
        $x.LoadXml('<toast><visual><binding template="ToastGeneric"><text>' + (& $esc $Title) + '</text><text>' + (& $esc $Body) + '</text></binding></visual></toast>')
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($x))
        Write-WidgetLog ('toast: ' + $Title)
    } catch { Write-WidgetLog ('toast failed: ' + $_.Exception.Message) }
}
function Get-MarkKey { param([string]$Path) try { if (Test-Path -LiteralPath $Path) { return [string](Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).key } } catch {}; return '' }
function Set-MarkKey { param([string]$Path, [string]$Key) try { [ordered]@{ key = $Key; at = (Get-LocalNow).ToString('s'); pc = $env:COMPUTERNAME } | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding UTF8 } catch {} }
$script:PeakHiddenKey = ''
function Render-Peak {
    # v4.3 RATE STATUS: always visible. Charging day/peak = red/amber pill + Stop + tip; charging off-peak = green pill; not charging = small neutral line.
    $rs = Get-RateStatus; $script:PeakShown = $rs
    $ui.PeakTitle.Foreground = T 'Text'; $ui.PeakSub.Foreground = T 'TextSoft'; $ui.PeakTip.Foreground = T 'Caption'
    if ($rs.mode -eq 'charging-high') {
        $col = $(if ($rs.red) { T 'Red' } else { T 'Amber' })
        $c = $col.Color
        $ui.PeakBanner.BorderBrush = $col; $ui.PeakBanner.BorderThickness = [System.Windows.Thickness]::new(1.5)
        $ui.PeakBanner.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(0x30, $c.R, $c.G, $c.B))
        $ui.PeakBanner.Padding = [System.Windows.Thickness]::new(10, 7, 10, 8); $ui.PeakBanner.CornerRadius = [System.Windows.CornerRadius]::new(12)
        $ui.PeakIcon.Text = [string][char]0xE7BA; $ui.PeakIcon.Foreground = $col; $ui.PeakIcon.FontSize = 17
        $ui.PeakTitle.FontSize = 12.5; $ui.PeakTitle.FontWeight = 'Bold'
        $ui.PeakTitle.Text = ('{0} · charging costs more · off-peak starts {1}{2}' -f $(if ($rs.red) { 'PEAK RATE' } else { 'DAY RATE' }), $rs.offPeakLabel, $(if ($null -ne $rs.untilOffMin) { ' (in ' + (Format-Left $rs.untilOffMin) + ')' } else { '' }))
        $ui.PeakSub.Text = ('Now {0} ({1:N1}¢ all-in) vs {2} off-peak' -f (Format-C1 $rs.rateNow), ($rs.allInNow * 100), (Format-C1 $rs.rateOff)) + $(if ($null -ne $rs.extraUsd) { "`n" + '≈ +' + (Format-Money $rs.extraUsd) + ' extra this session vs charging off-peak' } else { '' })
        Set-Visible $ui.PeakSub $true
        $ui.PeakTip.Text = ('Tip: in the car, Charging > Scheduled Charging > start at {0}.' -f $rs.offPeakLabel)
        $ui.PeakStopBtn.Tag = [System.Windows.CornerRadius]::new(8); $ui.PeakStopBtn.Background = $col; $ui.PeakStopBtn.BorderBrush = $col
        $ui.PeakStopTxt.Foreground = $(if ($rs.red) { T 'Text' } else { [System.Windows.Media.Brushes]::Black })
        $ui.PeakStopBtn.IsEnabled = ((Test-CmdOn) -and -not $script:CtlBusy)
        $hidden = ($script:PeakHiddenKey -eq $rs.key)
        Set-Visible $ui.PeakActions (-not $hidden); Set-Visible $ui.PeakSub (-not $hidden); Set-Visible $ui.PeakClose (-not $hidden)
        Set-Visible $ui.PeakBanner $true
        if ((Get-MarkKey $PeakMarkPath) -ne $rs.key) {
            Set-MarkKey $PeakMarkPath $rs.key
            Show-WinToast ('TessDesk: ' + $(if ($rs.red) { 'peak rate' } else { 'day rate' }) + ' charging') ('Now {0} ({1} all-in), off-peak {2} starts {3}{4}. Stop charging in TessDesk, or set Scheduled Charging to {3} in the car.' -f (Format-C1 $rs.rateNow), (Format-C1 $rs.allInNow), (Format-C1 $rs.rateOff), $rs.offPeakLabel, $(if ($null -ne $rs.untilOffMin) { ' (in ' + (Format-Left $rs.untilOffMin) + ')' } else { '' }))
        }
        return
    }
    Set-Visible $ui.PeakActions $false; Set-Visible $ui.PeakClose $false
    if ($rs.mode -eq 'charging-offpeak') {
        $col = T 'Green'; $c = $col.Color
        $ui.PeakBanner.BorderBrush = $col; $ui.PeakBanner.BorderThickness = [System.Windows.Thickness]::new(1.5)
        $ui.PeakBanner.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(0x26, $c.R, $c.G, $c.B))
        $ui.PeakBanner.Padding = [System.Windows.Thickness]::new(10, 5, 10, 5); $ui.PeakBanner.CornerRadius = [System.Windows.CornerRadius]::new(14)
        $ui.PeakIcon.Text = [string][char]0xE73E; $ui.PeakIcon.Foreground = $col; $ui.PeakIcon.FontSize = 13
        $ui.PeakTitle.FontSize = 12; $ui.PeakTitle.FontWeight = 'Bold'
        $ui.PeakTitle.Text = ('OFF-PEAK · {0} · cheapest rate until {1}' -f (Format-C1 $rs.rateOff), $rs.offEndLabel)
        $ui.PeakSub.Text = ('{0} all-in with the fuel adder' -f (Format-C1 $rs.allInOff)); Set-Visible $ui.PeakSub $true
        Set-Visible $ui.PeakBanner $true
        return
    }
    # not charging (or DC fast / away): small neutral line
    $ui.PeakBanner.BorderThickness = [System.Windows.Thickness]::new(0); $ui.PeakBanner.Background = [System.Windows.Media.Brushes]::Transparent
    $ui.PeakBanner.Padding = [System.Windows.Thickness]::new(4, 0, 4, 0); $ui.PeakBanner.CornerRadius = [System.Windows.CornerRadius]::new(0)
    $ui.PeakIcon.Text = [string][char]0xE823; $ui.PeakIcon.Foreground = T 'Caption'; $ui.PeakIcon.FontSize = 11
    $ui.PeakTitle.FontSize = 10.5; $ui.PeakTitle.FontWeight = 'SemiBold'; $ui.PeakTitle.Foreground = T 'Caption'
    if ($rs.kind -eq 'offpeak') { $t = ('Off-peak now · {0} · ends {1}' -f (Format-C1 $rs.rateNow), $rs.offEndLabel) + $(if ($null -ne $rs.next) { ' (in ' + (Format-Left ($rs.next.at - $rs.now).TotalMinutes) + ')' } else { '' }) }
    else { $t = ('{0} now · {1} · off-peak in {2}' -f $rs.label, (Format-C1 $rs.rateNow), $(if ($null -ne $rs.untilOffMin) { Format-Left $rs.untilOffMin } else { '?' })) }
    $ui.PeakBanner.ToolTip = $(if ($null -ne $rs.next) { (Get-RateLabel $rs.kind) + ' until ' + $rs.next.at.ToString('h tt', $Inv) + ', then ' + (Get-RateLabel $rs.next.kind).ToLowerInvariant() + '. Rates: config.json "rates" (' + $(if ($null -ne $script:Cfg -and $null -ne $script:Cfg.rates -and $script:Cfg.rates.plan) { [string]$script:Cfg.rates.plan } else { 'PSO RSEV' }) + ')' } else { $null })
    if ($rs.reason -like 'DC*' -or $rs.reason -like '*away*') { $t += (' · ' + $rs.reason) }
    $ui.PeakTitle.Text = $t
    Set-Visible $ui.PeakSub $false
    Set-Visible $ui.PeakBanner $true
}
# --- full status rundown ---
function Get-SpokenCents { param([double]$UsdPerKwh) $c = [math]::Round($UsdPerKwh * 100, 1); return ($c.ToString('0.#', $Inv) + ' cents a kilowatt hour') }
function Get-SpokenRate {
    param($Rs)
    if ($Rs.kind -eq 'offpeak') { return ('Rate: off-peak, ' + (Get-SpokenCents $Rs.rateNow) + ', the cheapest, until ' + $Rs.offEndLabel + '.') }
    $x = 'Rate: ' + $(if ($Rs.kind -eq 'peak') { 'peak' } else { 'day' }) + ', ' + (Get-SpokenCents $Rs.rateNow) + ', off-peak at ' + $Rs.offPeakLabel
    if ($null -ne $Rs.untilOffMin) { $x += ', in ' + (Get-SpokenDuration $Rs.untilOffMin) }
    if ($Rs.mode -eq 'charging-high' -and $null -ne $Rs.extraUsd) { $x += '. About ' + (Get-SpokenMoney $Rs.extraUsd) + ' extra versus off-peak' }
    return ($x + '.')
}
$TireSpoken = [ordered]@{ fl = 'front left'; fr = 'front right'; rl = 'rear left'; rr = 'rear right' }
function Get-Rundown {
    param($Sel)
    if ($null -eq $Sel) { $Sel = Get-RundownSel }
    $car = Get-CtlCar; $v = $script:View; $t = $null; if ($null -ne $v) { $t = $v.tires }; if ($null -eq $t -and $null -ne $script:State) { $t = $script:State.lastTires }
    $s = New-Object System.Collections.ArrayList
    [void]$s.Add('TessDesk status.')
    if ($null -eq $car) { [void]$s.Add('No vehicle data yet.'); return (Split-Rundown $s) }
    $chg = Get-ChgState; $isChg = ($chg -eq 'Charging' -or $chg -eq 'Starting')
    if ($Sel.battery -and $null -ne $car.socPct) { $x = ('Your Tesla is at {0:N0} percent' -f [double]$car.socPct); if ($null -ne $car.rangeMi) { $x += (', {0:N0} miles of range' -f [double]$car.rangeMi) }; [void]$s.Add($x + '.') }
    $lim = Get-CtlValue 'limit' $car.limitPct
    if ($Sel.limit -and $null -ne $lim) { $mi = Get-MilesAt $lim; [void]$s.Add((('Charge limit {0:N0} percent' -f [double]$lim) + $(if ($null -ne $mi) { (', about {0:N0} miles' -f [double]$mi) } else { '' }) + '.')) }
    if ($isChg) {
        if ($Sel.rate) {
            $x = 'Charging'
            if ($null -ne $car.chargerKw -and [double]$car.chargerKw -gt 0) { $x += (' at ' + (Get-SpokenNum $car.chargerKw) + ' kilowatts') }
            if ($null -ne $car.amps -and [double]$car.amps -gt 0) { $x += (', {0:N0} amps' -f [double]$car.amps) }
            [void]$s.Add($x + '.')
        }
        if ($Sel.tofull -and $null -ne $car.minutesToFull -and [double]$car.minutesToFull -gt 0) {
            $eta = (Get-LocalNow).AddMinutes([double]$car.minutesToFull)
            [void]$s.Add('Full in ' + (Get-SpokenDuration $car.minutesToFull) + ', around ' + $eta.ToString('h:mm tt', $Inv) + '.')
        }
    } elseif ($Sel.rate -or $Sel.tofull) {
        [void]$s.Add($(switch ($chg) { 'Complete' { 'Charging complete.' } 'Stopped' { 'Plugged in, not charging.' } 'NoPower' { 'Plugged in, but no power.' } 'Disconnected' { 'Not plugged in.' } default { 'Not charging.' } }))
    }
    if ($Sel.cost) {
        $n = $null; if ($null -ne $v) { $n = $v.night }
        if ($null -ne $n -and $null -ne $n.costUsdAllIn) { [void]$s.Add([string]$n.label + ', ' + (Get-SpokenMoney $n.costUsdAllIn) + '.') }
        $st = $script:State
        if ($isChg -and $null -ne $st -and $null -ne $st.session -and $null -ne $st.session.costUsdAllIn) { [void]$s.Add('This charge so far, ' + (Get-SpokenMoney $st.session.costUsdAllIn) + '.') }
        $lc = $null; if ($null -ne $st) { $lc = $st.lastCharge }
        if (-not $isChg -and $null -ne $lc -and $null -ne $lc.costUsdAllIn) { [void]$s.Add('Last charge, ' + (Get-SpokenMoney $lc.costUsdAllIn) + '.') }
        [void]$s.Add((Get-SpokenRate (Get-RateStatus)))
    }
    if ($Sel.climate) {
        $clim = Get-CtlValue 'climateOn' $car.climateOn
        $x = $(if ($null -eq $clim) { 'Climate unknown' } elseif ([bool]$clim) { 'Climate on' } else { 'Climate off' })
        if ([bool]$clim -and $null -ne $car.tempC) { $x += (', set to ' + (Get-SpokenTemp (Get-CtlValue 'tempC' $car.tempC))) }
        if ($null -ne $car.insideC) { $x += (', inside ' + (Get-SpokenTemp $car.insideC)) }
        if ($null -ne $car.outsideC) { $x += (', outside ' + (Get-SpokenTemp $car.outsideC)) }
        [void]$s.Add($x + '.')
        $y = @()
        if ([bool](Get-DefrostOn)) { $y += 'defrost on' }
        $cop = Get-CopMode; if ($cop) { $y += ('overheat protection ' + $(switch ($cop) { 'On' { 'on' } 'FanOnly' { 'fan only' } default { 'off' } })) }
        $on = @(); foreach ($k in 'FL', 'FR', 'RL', 'RC', 'RR') { $lv = $null; try { $lv = Get-SeatLevel $k } catch {}; if ($null -ne $lv -and [int]$lv -gt 0) { $on += ($(switch ($k) { 'FL' { 'driver' } 'FR' { 'passenger' } 'RL' { 'rear left' } 'RC' { 'rear middle' } default { 'rear right' } }) + ' ' + [int]$lv) } }
        $y += $(if ($on.Count -eq 0) { 'seat heat off' } else { 'seat heat ' + ($on -join ', ') })
        if ([bool](Get-WheelOn)) { $y += 'steering wheel heat on' }
        $z = ($y -join ', '); if ($z) { [void]$s.Add($z.Substring(0, 1).ToUpperInvariant() + $z.Substring(1) + '.') }
    }
    if ($Sel.lock) { $lk = Get-CtlValue 'locked' $car.locked; [void]$s.Add($(if ($null -eq $lk) { 'Lock state unknown.' } elseif ([bool]$lk) { 'Doors locked.' } else { 'Doors unlocked.' })) }
    if ($Sel.windows) {
        $w = $car.windows; $wo = Get-CtlValue 'windowsOpen' $car.windowsOpen
        $names = [ordered]@{ fd = 'driver front'; fp = 'passenger front'; rd = 'rear left'; rp = 'rear right' }
        $open = @(); if ($null -ne $w) { foreach ($k in $names.Keys) { if ($null -ne $w.$k -and [int]$w.$k -ne 0) { $open += $names[$k] } } }
        if ($wo -eq $false) { $open = @() } elseif ([bool]$wo -and $open.Count -eq 0) { $open = @($names.Values) }
        if ($null -eq $w -and $null -eq $wo) { [void]$s.Add('Windows unknown.') }
        elseif ($open.Count -eq 0) { [void]$s.Add('All windows up.') }
        elseif ($open.Count -eq 4) { [void]$s.Add('All four windows open.') }
        else { $closed = @($names.Values | Where-Object { $open -notcontains $_ }); [void]$s.Add('Window open: ' + ($open -join ', ') + '. ' + ($closed -join ', ') + ' up.') }
    }
    if ($Sel.tires -and $null -ne $t) {
        $p = @(); foreach ($k in $TireSpoken.Keys) { $p += $(if ($null -ne $t.$k) { ('{0:N0}' -f [double]$t.$k) } else { 'unknown' }) }
        $x = ('Tires: front left {0}, front right {1}, rear left {2}, rear right {3} PSI' -f $p[0], $p[1], $p[2], $p[3])
        if ($null -ne $t.recFront) { $x += (', recommended {0:N0}' -f [double]$t.recFront); if ($null -ne $t.recRear -and [math]::Round([double]$t.recRear) -ne [math]::Round([double]$t.recFront)) { $x += (' front, {0:N0} rear' -f [double]$t.recRear) } }
        [void]$s.Add($x + '.')
    }
    if ($Sel.warnings) {
        $wr = @()
        $pk = Get-RateStatus; if ($pk.show -and -not $Sel.cost) { $wr += ('charging at the ' + $(if ($pk.red) { 'peak' } else { 'day' }) + ' rate, off-peak starts at ' + $pk.offPeakLabel) }
        foreach ($k in $TireSpoken.Keys) { $f = [string]$script:TireFlags[$k]; if ($f -like '*-low') { $wr += ($TireSpoken[$k] + ' tire low') } elseif ($f -like '*-high') { $wr += ($TireSpoken[$k] + ' tire high') } }
        [void]$s.Add($(if ($wr.Count -eq 0) { 'No warnings.' } else { 'Warning: ' + ($wr -join '; ') + '.' }))
    }
    $age = $null; if ($null -ne $script:Live.dataEpoch) { $age = (Get-EpochNow) - [int64]$script:Live.dataEpoch }
    [void]$s.Add($(if ($null -eq $age) { 'Data age unknown.' } elseif ($age -lt 60) { 'Updated just now.' } elseif ($age -lt 3600) { 'Updated ' + [math]::Round($age / 60) + ' minutes ago.' } else { 'Updated ' + [math]::Round($age / 3600) + ' hours ago.' }))
    return (Split-Rundown ([string[]]$s.ToArray()))
}

# --- toast inside the widget ---
$script:WToastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WToastTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:WToastTimer.Add_Tick({ $script:WToastTimer.Stop(); try { Set-Visible $ui.WToast $false } catch {} })
function Show-TdToast {
    param([string]$Text, [bool]$Ok = $true)
    $ui.WToastTxt.Text = $Text
    $ui.WToast.BorderBrush = $(if ($Ok) { T 'Green' } else { T 'Red' })
    $ui.WToast.Background = T 'CardBg'; $ui.WToastTxt.Foreground = T 'Text'
    Set-Visible $ui.WToast $true
    $script:WToastTimer.Stop(); $script:WToastTimer.Start()
    $script:LastToast = [ordered]@{ text = $Text; ok = $Ok; at = (Get-LocalNow).ToString('s') }
}

# --- confirm box inside the widget (Confirm / Cancel), modal via a nested dispatcher frame ---
$script:ConfirmFrame = $null; $script:ConfirmAnswer = $false
function Show-ConfirmOverlay {
    param([string]$Msg, [string]$Sub, [string]$Yes = 'Confirm', [string]$No = 'Cancel', [switch]$NoWait)
    $ui.ConfirmMsg.Text = $Msg; $ui.ConfirmSub.Text = [string]$Sub; Set-Visible $ui.ConfirmSub ([bool]$Sub)
    $ui.ConfirmYesTxt.Text = $Yes; $ui.ConfirmNoTxt.Text = $No
    $r = [System.Windows.CornerRadius]::new(9)
    $ui.ConfirmYes.Tag = $r; $ui.ConfirmNo.Tag = $r
    $ui.ConfirmYes.Background = T 'Green'; $ui.ConfirmYes.BorderBrush = T 'Green'; $ui.ConfirmYesTxt.Foreground = [System.Windows.Media.Brushes]::Black
    $ui.ConfirmNo.Background = T 'BtnBg'; $ui.ConfirmNo.BorderBrush = T 'BtnBorder'; $ui.ConfirmNoTxt.Foreground = T 'Text'
    $ui.ConfirmBox.Background = T 'CardBg'; $ui.ConfirmBox.BorderBrush = T 'BtnBorder'; $ui.ConfirmMsg.Foreground = T 'Text'; $ui.ConfirmSub.Foreground = T 'TextSoft'
    Set-Visible $ui.ConfirmOverlay $true
    $window.UpdateLayout()
    if ($NoWait) { return $null }
    $script:ConfirmAnswer = $false
    $script:ConfirmFrame = New-Object System.Windows.Threading.DispatcherFrame
    try { [System.Windows.Threading.Dispatcher]::PushFrame($script:ConfirmFrame) } finally { $script:ConfirmFrame = $null; Set-Visible $ui.ConfirmOverlay $false }
    return [bool]$script:ConfirmAnswer
}
function Close-ConfirmOverlay { param([bool]$Answer) $script:ConfirmAnswer = $Answer; if ($null -ne $script:ConfirmFrame) { $script:ConfirmFrame.Continue = $false } else { Set-Visible $ui.ConfirmOverlay $false } }

# --- send to several speakers in sequence (background); optional cross-PC lock for charging-started ---
$script:VmSeqBlock = {
    param($Api, $Tok, [string[]]$Devs, [string[]]$Parts, [int[]]$Gaps, [string]$LockPc, [string]$LockVar, [int]$LockWin)
    $res = @()
    if ($LockPc) {
        # Home PC + laptop: a short shared lock in Voice Monkey variables, so only one of them announces this charge session.
        $enc = [uri]::EscapeDataString($Tok)
        $read = { try { $r = Invoke-RestMethod -Uri ($Api + '/variables?token=' + $enc + '&variable=' + $LockVar) -Method Get -TimeoutSec 10 -UseBasicParsing; return [string]$r.value } catch { $c = $null; try { $c = [int]$_.Exception.Response.StatusCode } catch {}; if ($c -eq 404) { return '' }; throw } }
        $fresh = { param($val) if ([string]$val -match '^(\d+)\|(.*)$') { $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$Matches[1]; if ($age -lt $LockWin) { return $Matches[2] } }; return $null }
        try {
            $v = & $read; $who = & $fresh $v
            if ($null -ne $who) { return [pscustomobject]@{ ok = $false; skipped = ('already announced by ' + $(if ($who) { $who } else { 'another PC' }) + ' for this charge session') } }
            Start-Sleep -Milliseconds (Get-Random -Minimum 300 -Maximum 3000)
            $v = & $read; $who = & $fresh $v
            if ($null -ne $who) { return [pscustomobject]@{ ok = $false; skipped = ('already announced by ' + $who + ' for this charge session') } }
            $mine = ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) + '|' + $LockPc
            $body = @{ token = $Tok; variable = $LockVar; value = $mine } | ConvertTo-Json -Compress
            [void](Invoke-RestMethod -Uri ($Api + '/variables') -Method Put -ContentType 'application/json' -Body $body -TimeoutSec 10 -UseBasicParsing)
            Start-Sleep -Milliseconds 2500
            $v = & $read
            if ([string]$v -ne $mine) { return [pscustomobject]@{ ok = $false; skipped = ('another PC claimed this charge session first (' + [string]$v.Split('|')[-1] + ')') } }
            $res += [pscustomobject]@{ dev = 'lock'; part = 0; ok = $true; note = 'lock won' }
        } catch { $res += [pscustomobject]@{ dev = 'lock'; part = 0; ok = $true; note = ('lock unavailable, announcing from this PC: ' + $_.Exception.Message) } }
    }
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds $Gaps[$i - 1] }
        foreach ($d in $Devs) {
            try {
                $body = @{ token = $Tok; device = $d; speech = $Parts[$i] } | ConvertTo-Json -Compress
                [void](Invoke-RestMethod -Uri ($Api + '/announce') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 20 -UseBasicParsing)
                $res += [pscustomobject]@{ dev = $d; part = $i + 1; ok = $true }
            } catch { $c = $null; try { $c = [int]$_.Exception.Response.StatusCode } catch {}; $res += [pscustomobject]@{ dev = $d; part = $i + 1; ok = $false; code = $c; error = $_.Exception.Message } }
        }
    }
    $sends = @($res | Where-Object { $_.part -gt 0 }); $okN = @($sends | Where-Object { $_.ok }).Count; $bad = @($sends | Where-Object { -not $_.ok })
    return [pscustomobject]@{ ok = ($sends.Count -gt 0 -and $okN -eq $sends.Count); partial = ($okN -gt 0 -and $okN -lt $sends.Count); okCount = $okN; total = $sends.Count
        code = $(if ($bad.Count -gt 0) { $bad[0].code } else { $null }); error = $(if ($bad.Count -gt 0) { $bad[0].error } else { $null }); notes = @($res | Where-Object { $_.note } | ForEach-Object { $_.note }); results = $res }
}

# --- Announce on Alexa (one push, full rundown) ---
function Invoke-AnnounceNow {
    if (-not (Test-AnnConsent) -and -not $script:AnnMock) {
        Set-CtlResult 'idle' 'Announce on Alexa: accept the announcement disclosure in Connected apps first.'
        Show-TdToast 'Accept the Alexa disclosure first (opening Connected apps)' $false
        if (-not $SelfTest) { Show-AnnounceWindow }
        return $null
    }
    if (-not (Test-AnnReady)) {
        Set-CtlResult 'idle' 'Announce on Alexa: set up Voice Monkey (token + speaker) in Connected apps first.'
        Show-TdToast 'Set up Voice Monkey first (opening Connected apps)' $false
        if (-not $SelfTest) { Show-AnnounceWindow }
        return $null
    }
    if (-not (Confirm-Ctl 'Announce full status?' ('Alexa speaks the rundown on ' + (Get-TargetLabel)) 'Announce' 'Cancel')) { Set-CtlResult 'idle' 'Announcement cancelled'; return $null }
    $rd = Get-Rundown; $script:LastRundown = $rd
    Write-WidgetLog ('rundown ({0} words, ~{1} s, {2} part(s)): {3}' -f $rd.words, $rd.seconds, @($rd.parts).Count, (@($rd.parts) -join ' || '))
    Set-CtlResult 'busy' ('Announcing on ' + (Get-TargetLabel) + '…')
    $done = {
        param($res)
        if ($null -ne $res -and $res.dryRun) { Set-CtlResult 'ok' ('DRY RUN: rundown composed ({0} part(s), ~{1} s), not sent' -f @($script:LastRundown.parts).Count, $script:LastRundown.seconds); Show-TdToast ('DRY RUN: full status composed, not sent (' + (Get-TargetLabel) + ')') $true }
        elseif ($null -ne $res -and $res.ok) { Set-CtlResult 'ok' ('✓ Announced on ' + (Get-TargetLabel)); Show-TdToast ('✓ Announced full status on ' + (Get-TargetLabel)) $true }
        elseif ($null -ne $res -and $res.partial) { Set-CtlResult 'err' ('Announced on {0} of {1} speaker sends' -f $res.okCount, $res.total); Show-TdToast ('Partly announced ({0}/{1}): {2}' -f $res.okCount, $res.total, $res.error) $false }
        else { $why = $(if ($null -ne $res) { if ($res.code) { 'HTTP ' + $res.code } else { [string]$res.error } } else { 'no response' }); Set-CtlResult 'err' ('✕ Announcement failed: ' + $why); Show-TdToast ('✕ Announcement failed: ' + $why) $false }
    }
    $r = Send-Announcement -Text $rd.text -Parts @($rd.parts) -Why 'rundown' -Force -OnDone $done
    if ($r.result -like 'skipped*') { Set-CtlResult 'err' $r.result; Show-TdToast $r.result $false }
    return $r
}

# --- charging started (desktop): Not charging -> Charging, wait one refresh for real kW / amps, once per session ---
$script:PrevCharging = $null; $script:ChgStartPending = $null
function Test-ChgStartOn { return [bool](Get-AnnProp 'chargingStarted' $true) }
function Get-ChargingStartedText {
    param($Car, $Peak)
    $nm = [string](Get-AnnProp 'name' 'Van'); if (-not $nm) { $nm = 'Van' }
    $x = $nm + ', charging has started.'
    $b = @()
    if ($null -ne $Car.socPct) { $b += ('Battery at {0:N0} percent' -f [double]$Car.socPct) }
    if ($null -ne $Car.limitPct) { $b += ('charging to {0:N0} percent' -f [double]$Car.limitPct) }
    $r = ''
    if ($null -ne $Car.chargerKw -and [double]$Car.chargerKw -gt 0) { $r = 'at ' + (Get-SpokenNum ([math]::Round([double]$Car.chargerKw, 1))) + ' kilowatts' }
    if ($null -ne $Car.amps -and [double]$Car.amps -gt 0) { $r += $(if ($r) { ', ' } else { 'at ' }) + ('{0:N0} amps' -f [double]$Car.amps) }
    $rp = ''
    if ($null -ne $Peak -and $Peak.mode -eq 'charging-offpeak') { $rp = ', at the off-peak rate' }
    elseif ($null -ne $Peak -and $Peak.mode -eq 'charging-high') { $rp = $(if ($Peak.red) { ', at the peak rate, which costs more' } else { ', at the day rate, which costs more' }) }
    if ($b.Count -gt 0) { $x += ' ' + ($b -join ', ') + $(if ($r) { ' ' + $r } else { '' }) + $rp + '.' }
    if ($null -ne $Car.minutesToFull -and [double]$Car.minutesToFull -gt 0) { $x += ' About ' + (Get-SpokenDuration $Car.minutesToFull) + ' to full.' }
    if ($null -ne $Peak -and $Peak.mode -eq 'charging-high') { $x += ' Off-peak starts at ' + $Peak.offPeakLabel + $(if ($null -ne $Peak.untilOffMin) { ', in ' + (Get-SpokenDuration $Peak.untilOffMin) } else { '' }) + '.' }
    return $x
}
function Watch-ChargingStarted {
    param($Res)
    if ($null -eq $Res) { return }
    $chg = ($Res.mode -eq 'live'); $now = Get-EpochNow
    $prev = $script:PrevCharging; $script:PrevCharging = $chg
    if (-not $chg) { $script:ChgStartPending = $null; return }
    if ($prev -eq $false) {
        $script:ChgStartPending = [pscustomobject]@{ at = $now; key = [string]$Res.session.startEpoch; polls = 0 }
        Write-WidgetLog 'charging started (Not charging -> Charging): waiting one refresh for real kW / amps'
        return
    }
    $p = $script:ChgStartPending; if ($null -eq $p) { return }
    $p.polls++
    $car = $Res.car
    $ready = ($null -ne $car -and $null -ne $car.chargerKw -and [double]$car.chargerKw -gt 0.3 -and $null -ne $car.amps -and [double]$car.amps -gt 0)
    if ((($now - [int64]$p.at) -ge 10 -and $ready) -or ($now - [int64]$p.at) -ge 180) { $script:ChgStartPending = $null; [void](Invoke-ChargingStartedAnnounce $car $p.key) }
}
function Invoke-ChargingStartedAnnounce {
    param($Car, [string]$Key)
    $rec = [ordered]@{ at = (Get-LocalNow).ToString('s'); key = $Key; text = (Get-ChargingStartedText $Car (Get-RateStatus)); result = '' }
    if (-not (Test-ChgStartOn)) { $rec.result = 'skipped: charging-started switch is off (Announce Setup)' }
    elseif (-not (Test-AnnConsent) -and -not $script:AnnMock) { $rec.result = 'skipped: announcement disclosure not accepted' }
    elseif ((Get-MarkKey $ChgMarkPath) -eq $Key) { $rec.result = 'skipped: already announced for this charge session on this PC' }
    else {
        Set-MarkKey $ChgMarkPath $Key
        $r = Send-Announcement -Text $rec.text -Why 'charging-started' -Force -Lock
        $rec.result = $r.result; $rec.devices = $r.devices
    }
    Write-WidgetLog ('charging-started announcement: ' + $rec.result + ' | ' + $rec.text)
    $script:ChgStartLog = @(@($script:ChgStartLog) + [pscustomobject]$rec) | Select-Object -Last 10
    return [pscustomobject]$rec
}

# --- vertical charge-limit slider (right of the battery): % + miles on the thumb ---
$VY0 = 22.0; $VY1 = 128.0
function Get-VY { param([double]$Pct) $b = Get-LimitBounds; $f = 0.0; if ($b[1] -gt $b[0]) { $f = ($Pct - $b[0]) / ($b[1] - $b[0]) }; $f = [math]::Max(0.0, [math]::Min(1.0, [double]$f)); return ($VY1 - $f * ($VY1 - $VY0)) }
function Get-PctFromY { param([double]$Y) $b = Get-LimitBounds; $f = ($VY1 - $Y) / ($VY1 - $VY0); $p = [math]::Round($b[0] + $f * ($b[1] - $b[0])); return [int][math]::Max($b[0], [math]::Min($b[1], $p)) }
function Set-VThumb {
    param([double]$Pct)
    $y = Get-VY $Pct
    [System.Windows.Controls.Canvas]::SetTop($ui.VThumb, $y - 21)
    [System.Windows.Controls.Canvas]::SetTop($ui.VFill, $y); $ui.VFill.Height = [math]::Max(0.0, $VY1 - $y)
    $ui.VPct.Text = ('{0:N0}%' -f $Pct)
    $mi = Get-MilesAt $Pct; $ui.VMi.Text = $(if ($null -ne $mi) { Format-Miles $mi } else { ' ' })
}
function Render-VSlider {
    param($Limit, $Brush)
    $have = ($null -ne $Limit)
    Set-Visible $ui.VThumb $have
    foreach ($pair in @(@(80, 'VTick80', 'VLbl80', 3.0), @(90, 'VTick90', 'VLbl90', 2.0))) {
        $y = Get-VY $pair[0]
        [System.Windows.Controls.Canvas]::SetTop($ui[$pair[1]], $y - $pair[3] / 2); [System.Windows.Controls.Canvas]::SetTop($ui[$pair[2]], $y - 7)
    }
    $b = Get-LimitBounds; $ui.VLblTop.Text = [string]$b[1]; $ui.VLblBot.Text = [string]$b[0]
    [System.Windows.Controls.Canvas]::SetTop($ui.VLblTop, $VY0 - 7); [System.Windows.Controls.Canvas]::SetTop($ui.VLblBot, $VY1 - 7)
    $ui.VTrack.Fill = T 'BarTrack'; $ui.VThumb.Background = T 'Thumb'; $ui.VThumb.BorderBrush = T 'RootBg'
    $ui.VTick80.Fill = T 'Green'; $ui.VLbl80a.Foreground = T 'Green'; $ui.VLbl80b.Foreground = T 'Green'; $ui.VTick90.Fill = T 'Amber'; $ui.VLbl90.Foreground = T 'Amber'
    $ui.VLblTop.Foreground = T 'Caption'; $ui.VLblBot.Foreground = T 'Caption'
    if ($null -ne $Brush) { $ui.VFill.Fill = $Brush; $ui.VFill.Opacity = 0.75 }
    $ui.VLim.IsEnabled = ((Test-CmdOn) -and -not $script:CtlBusy -and $have)
    $ui.VThumb.Opacity = $(if ($ui.VLim.IsEnabled) { 1.0 } else { 0.7 })
    if (-not $have) { $ui.VFill.Height = 0; return }
    if ($script:Dragging -and $null -ne $script:DragPct) { Set-VThumb $script:DragPct }
    elseif ($null -ne $script:VPend) { Set-VThumb $script:VPend }
    else { Set-VThumb ([double]$Limit) }
}
$script:VPend = $null; $script:WheelPct = $null
$script:WheelTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WheelTimer.Interval = [TimeSpan]::FromMilliseconds(900)
$script:WheelTimer.Add_Tick({ $script:WheelTimer.Stop(); try { if ($null -ne $script:WheelPct) { $p = $script:WheelPct; $script:WheelPct = $null; $script:DragPct = $p; End-Drag $true } } catch { Write-WidgetLog ('wheel commit: ' + $_.Exception.Message) } })
function Step-VLimit {
    param([int]$Delta)
    if (-not (Test-CmdOn) -or $script:CtlBusy -or $ui.VThumb.Visibility -ne 'Visible') { return }
    $b = Get-LimitBounds
    $base = $script:WheelPct; if ($null -eq $base) { $base = [int][math]::Round([double]$script:BarLimitShown) }
    $p = [int][math]::Max($b[0], [math]::Min($b[1], $base + $Delta))
    $script:WheelPct = $p; $script:Dragging = $true
    Show-DragPct $p
    $script:WheelTimer.Stop(); $script:WheelTimer.Start()
}

# --- v4.3.1 Announce Setup window: rundown items, SPEAKERS dropdown (tick to include, Test this speaker), Add speaker (Voice Monkey page + Alexa steps + Refresh list), charging-started ---
# Voice Monkey API v3 can LIST speakers (GET /devices) but has no endpoint to create one (voicemonkey.io/docs/api: announce, trigger, flow, devices (list), variables).
# So "Add speaker" opens app.voicemonkey.io/speakers (Add New Speaker), shows the one Alexa-app Routine step, and "Refresh list" picks the new speaker up.
$VmSpeakersUrl = 'https://app.voicemonkey.io/speakers'
$VmAddDocUrl = 'https://voicemonkey.io/docs/getting-started/add-device.html'
$script:SpkTestLog = @()
function Get-SpkTestText { param([string]$Name) return ('This is a TessDesk test on ' + $(if ($Name) { $Name } else { 'this speaker' }) + '. Tesla announcements will play here.') }
function New-SetupBtn {
    param([string]$Text, [string]$Tip = '', [string]$Pad = '12,3,12,3', [string]$Margin = '0,0,8,0', [switch]$Bold)
    $b = New-Object System.Windows.Controls.Button; $b.Content = $Text; $b.Padding = $Pad; $b.Margin = $Margin
    if ($Tip) { $b.ToolTip = $Tip }; if ($Bold) { $b.FontWeight = 'Bold' }
    return $b
}
function Get-SpkSummary {
    $d = $script:SetupDlg; $list = @($d.list)
    if ($list.Count -eq 0) { return 'No speakers listed yet' }
    $on = @($list | Where-Object { [bool]$d.allE.IsChecked -or [bool]$d.sel[$_.id] })
    if ($on.Count -eq 0) { return ('No speaker ticked (0 of {0})' -f $list.Count) }
    $names = (@($on | ForEach-Object { $_.name }) -join ', ')
    if ($names.Length -gt 34) { $names = $names.Substring(0, 32) + '…' }
    return ('{0}   ({1} of {2})' -f $names, $on.Count, $list.Count)
}
function Update-SpkHeader {
    $d = $script:SetupDlg
    $d.allLbl.Text = ('All Echos ({0})' -f @($d.list).Count)
    $d.ddTxt.Text = (Get-SpkSummary)
    $d.ddChev.Text = $(if ($d.ddOpen) { [string][char]0x25B4 } else { [string][char]0x25BE })
    $d.ddBox.Visibility = $(if ($d.ddOpen) { 'Visible' } else { 'Collapsed' })
    $d.addBox.Visibility = $(if ($d.addOpen) { 'Visible' } else { 'Collapsed' })
}
function Fill-SpkRows {
    $d = $script:SetupDlg; $d.ddRows.Children.Clear(); $d.spCbs = @()
    if (@($d.list).Count -eq 0) {
        [void]$d.ddRows.Children.Add((New-Txt ('No speakers listed yet: press Refresh list. Until then announcements go to ' + $(if (Get-VmDevice) { Get-VmDevice } else { 'no speaker' }) + '.') 11 'Normal' 'Caption'))
    }
    foreach ($s in @($d.list)) {
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,2,0,2'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, 'Star')
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
        [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
        $c = New-Object System.Windows.Controls.CheckBox; $c.VerticalAlignment = 'Center'; $c.Foreground = T 'Text'; $c.Tag = $s.id
        $c.IsChecked = $(if ([bool]$d.allE.IsChecked) { $true } else { [bool]$d.sel[$s.id] })
        $c.IsEnabled = -not [bool]$d.allE.IsChecked
        $c.ToolTip = 'Include this Echo in TessDesk announcements'
        $sp = New-Object System.Windows.Controls.StackPanel
        $nm = New-Txt $s.name 12 'SemiBold' 'Text'
        if ($d.newIds -contains $s.id) { $nm.Text = $s.name + '   NEW'; $nm.Foreground = T 'Green' }
        [void]$sp.Children.Add($nm); [void]$sp.Children.Add((New-Txt $s.id 9.5 'Normal' 'Caption'))
        $c.Content = $sp
        $c.Add_Click({ param($src, $e) $dd = $script:SetupDlg; $dd.sel[[string]$src.Tag] = [bool]$src.IsChecked; Update-SpkHeader })
        $bt = New-SetupBtn ([string][char]0x25B6 + ' Test') ('Test this speaker: plays one short line on ' + $s.name + ' only (only when you click)') '10,2,10,2' '6,0,0,0'
        $bt.Tag = $s.id; $bt.VerticalAlignment = 'Center'
        $bt.Add_Click({ param($src, $e) Invoke-SpeakerTest ([string]$src.Tag) })
        [System.Windows.Controls.Grid]::SetColumn($bt, 1)
        [void]$g.Children.Add($c); [void]$g.Children.Add($bt)
        [void]$d.ddRows.Children.Add($g); $d.spCbs += $c
    }
    Update-SpkHeader
}
function Invoke-SpeakerTest {
    # Test this speaker: ONE short announcement on ONE speaker, only when the button is clicked. Dry run (self-test / announce.dryRun / controls.dryRun) = log only.
    param([string]$Id)
    $d = $script:SetupDlg; $s = @(@($d.list) | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    $name = $(if ($null -ne $s) { $s.name } else { $Id }); $txt = Get-SpkTestText $name
    $rec = [ordered]@{ at = (Get-LocalNow).ToString('s'); why = 'speaker-test'; device = $Id; text = $txt; dryRun = (Test-AnnDryRun); sent = $false; result = '' }
    if (-not (Test-AnnConsent) -and -not $script:AnnMock) { $rec.result = 'skipped: accept the announcement disclosure in Connected apps first' }
    elseif ($rec.dryRun) { $rec.result = 'DRY RUN: test not sent'; Write-WidgetLog ('announce [DRY RUN] speaker-test -> ' + $Id + ': ' + $txt) }
    else {
        $tok = Get-VmToken
        if (-not $tok) { $rec.result = 'skipped: Voice Monkey token not saved (Connected apps)' } else {
            $ps = [powershell]::Create(); [void]$ps.AddScript($script:VmSendBlock).AddArgument($VmApi).AddArgument($tok).AddArgument($Id).AddArgument($txt)
            $d.testJob = [pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke(); rec = $rec; name = $name }
            $script:AnnSent++; $rec.sent = $true; $rec.result = 'sending'
            $d.testTimer.Start()
        }
    }
    $script:SpkTestLog = @(@($script:SpkTestLog) + $rec) | Select-Object -Last 20
    $script:AnnLog = @(@($script:AnnLog) + $rec) | Select-Object -Last 40
    $d.spRes.Text = $(if ($rec.result -eq 'sending') { 'Testing ' + $name + '… (one short line, this speaker only)' } elseif ($rec.dryRun) { 'DRY RUN: would say "' + $txt + '" on ' + $name + ' only. Nothing was sent.' } else { $rec.result })
    return $rec
}
function Complete-SpeakerTest {
    $d = $script:SetupDlg; $j = $d.testJob
    if ($null -eq $j -or -not $j.async.IsCompleted) { return }
    $d.testTimer.Stop(); $res = $null
    try { $res = @($j.ps.EndInvoke($j.async)) | Select-Object -Last 1 } catch {}
    try { $j.ps.Dispose() } catch {}
    $j.rec.result = $(if ($null -ne $res -and $res.ok) { 'test sent' } else { 'test failed: ' + $(if ($null -ne $res -and $res.code) { 'HTTP ' + $res.code } elseif ($null -ne $res) { $res.error } else { 'no response' }) })
    Write-WidgetLog ('speaker test ' + $j.rec.device + ': ' + $j.rec.result)
    $d.spRes.Text = $(if ($null -ne $res -and $res.ok) { [string][char]0x2713 + ' Test sent to ' + $j.name + '. If it stayed quiet, check its Alexa Routine (step 2 under Add speaker).' } else { [string][char]0x2715 + ' ' + $j.rec.result })
    $d.testJob = $null
}
function Invoke-SpkRefresh {
    # Read-only GET /devices. New speakers are marked NEW and ticked.
    param([switch]$FromAdd)
    $d = $script:SetupDlg
    try {
        if ($SelfTest) { $l = @(@($d.list) + @($script:SetupMockNew | Where-Object { $null -ne $_ })) | Group-Object id | ForEach-Object { $_.Group[0] }; $l = @($l) }
        else { $d.spRes.Text = 'Reading your Voice Monkey speakers (read-only)…'; $l = @(Get-VmSpeakers) }
        $old = @(@($d.list) | ForEach-Object { $_.id })
        $new = @($l | Where-Object { $old -notcontains $_.id })
        $d.list = $l
        foreach ($n in $new) { $d.sel[$n.id] = $true; if ($d.newIds -notcontains $n.id) { $d.newIds += $n.id } }
        Fill-SpkRows
        if ($new.Count -gt 0) { $d.ddOpen = $true; Update-SpkHeader }
        $msg = ('Found {0} speaker{1}' -f $l.Count, $(if ($l.Count -eq 1) { '' } else { 's' }))
        if ($new.Count -gt 0) { $msg += (' · NEW: ' + (@($new | ForEach-Object { $_.name }) -join ', ') + ' (ticked). Press Test, then Save.') }
        elseif ($FromAdd) { $msg += (' · nothing new yet. Finish step 1 (Create Speaker) in Voice Monkey, then Refresh list again.') }
        if ($SelfTest) { $msg += '  [self-test sample, nothing was read]' }
        $d.spRes.Text = $msg; if ($null -ne $d.addRes) { $d.addRes.Text = $msg }
        return $new
    } catch {
        $c = $null; try { $c = [int]$_.Exception.Response.StatusCode } catch {}
        $d.spRes.Text = 'Refresh failed' + $(if ($c) { ': HTTP ' + $c + $(if ($c -eq 401) { ' (Voice Monkey token not valid)' } else { '' }) } else { ': ' + $_.Exception.Message })
        return @()
    }
}
function Open-VmAddSpeaker {
    $d = $script:SetupDlg; $nm = ($d.addName.Text -replace '[^A-Za-z0-9 ]', '').Trim()
    if ($nm -ne $d.addName.Text.Trim()) { $d.addName.Text = $nm }
    $copied = $false
    if ($nm -and -not $SelfTest) { try { [System.Windows.Clipboard]::SetText($nm); $copied = $true } catch {} }
    $d.lastOpen = [ordered]@{ url = $VmSpeakersUrl; name = $nm; copied = $copied; opened = $false }
    if (-not $SelfTest) { try { Start-Process $VmSpeakersUrl; $d.lastOpen.opened = $true } catch { Write-WidgetLog ('open voice monkey failed: ' + $_.Exception.Message) } }
    Update-AddSteps
    $d.addRes.Text = $(if ($SelfTest) { 'Self-test: would open ' + $VmSpeakersUrl + $(if ($nm) { ' and copy "' + $nm + '"' } else { '' }) } else { 'Opened ' + $VmSpeakersUrl + ' in your browser' + $(if ($copied) { ' · "' + $nm + '" copied (Ctrl+V into the name box)' } else { '' }) })
}
function Update-AddSteps {
    $d = $script:SetupDlg; $nm = $d.addName.Text.Trim(); if (-not $nm) { $nm = 'your new speaker' } else { $nm = '"' + $nm + '"' }
    $d.step1.Text = ('1. In Voice Monkey: Add New Speaker, paste ' + $nm + ', then Create Speaker. (Sign in to Voice Monkey if asked. The page opens in your browser.)')
    $d.step2.Text = ('2. In the Alexa app on your phone (the one step only you can do): More > Routines > + > When this happens > Smart Home > Alexa Voice Monkey v3 > VM Speakers > ' + $nm + '. Add action > Skills > Voice Monkey (or Custom: "open Voice Monkey"). From: pick that Echo. Save.')
    $d.step3.Text = '3. Back here: Refresh list. The new speaker appears ticked. Press its Test button to hear it, then Save.'
}
function Show-AnnSetupWindow {
    param([string]$SnapshotPath, [string]$Scene = 'default')
    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'TessDesk · Announce Setup'; $dlg.Width = 460; $dlg.Height = [math]::Min(880, [System.Windows.SystemParameters]::WorkArea.Height - 40)
    $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.Background = T 'RootBg'; $dlg.Foreground = T 'Text'; $dlg.FontFamily = $window.FontFamily
    try { if (Test-Path -LiteralPath $iconPath) { $dlg.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) } } catch {}
    $outer = New-Object System.Windows.Controls.DockPanel; $outer.Background = T 'RootBg'
    $sv = New-Object System.Windows.Controls.ScrollViewer; $sv.VerticalScrollBarVisibility = 'Auto'
    $root = New-Object System.Windows.Controls.StackPanel; $root.Margin = '18,10,18,10'; $sv.Content = $root
    [void]$root.Children.Add((New-Txt 'Announce Setup' 17 'Bold' 'Text'))
    [void]$root.Children.Add((New-Txt 'What "Announce on Alexa" says, and where. Saved in config.json on this PC.' 11.5 'Normal' 'Caption'))
    [void]$root.Children.Add((New-Sec 'Full status rundown'))
    $bp = New-Object System.Windows.Controls.StackPanel; $bp.Orientation = 'Horizontal'; $bp.Margin = '0,2,0,4'
    $bAll = New-SetupBtn 'All on' '' '12,2,12,2' '0,0,0,0'
    $bNone = New-SetupBtn 'All off' '' '12,2,12,2' '8,0,0,0'
    $bPrev = New-SetupBtn 'Preview' '' '12,2,12,2' '8,0,0,0' -Bold
    [void]$bp.Children.Add($bAll); [void]$bp.Children.Add($bNone); [void]$bp.Children.Add($bPrev); [void]$root.Children.Add($bp)
    $sel = Get-RundownSel; $cbs = [ordered]@{}
    $ug = New-Object System.Windows.Controls.Primitives.UniformGrid; $ug.Columns = 2
    foreach ($k in $RundownItems.Keys) {
        $cb = New-Object System.Windows.Controls.CheckBox; $cb.Margin = '0,3,6,3'; $cb.Foreground = T 'Text'; $cb.IsChecked = [bool]$sel.$k
        $cb.Content = (New-Txt $RundownItems[$k] 12 'SemiBold' 'Text'); $cbs[$k] = $cb; [void]$ug.Children.Add($cb)
    }
    [void]$root.Children.Add($ug)
    [void]$root.Children.Add((New-Txt 'Data age ("Updated just now") is always said last. Long rundowns are split into 2 announcements (each under ~22 s).' 10.5 'Normal' 'Caption'))
    $pv = New-Object System.Windows.Controls.TextBox; $pv.IsReadOnly = $true; $pv.TextWrapping = 'Wrap'; $pv.Height = 110; $pv.Margin = '0,6,0,0'; $pv.VerticalScrollBarVisibility = 'Auto'
    $pv.Background = T 'CardBg'; $pv.Foreground = T 'TextSoft'; $pv.BorderBrush = T 'CardBorder'; $pv.FontSize = 11.5; $pv.Text = 'Preview shows the exact words here. Nothing is announced.'
    $pvInfo = New-Txt '' 10.5 'SemiBold' 'Caption'
    [void]$root.Children.Add($pv); [void]$root.Children.Add($pvInfo)

    # ---- speakers: All Echos (N) + dropdown with a tick + Test per speaker ----
    [void]$root.Children.Add((New-Sec 'Speakers (Echos)'))
    $ss = Get-SpeakerSel; $list = @(Get-SpeakerList)
    $selH = @{}; foreach ($s in $list) { $selH[$s.id] = ($ss.ids -contains $s.id) }
    $cbAllE = New-Object System.Windows.Controls.CheckBox; $cbAllE.Margin = '0,2,0,4'; $cbAllE.Foreground = T 'Text'; $cbAllE.IsChecked = [bool]$ss.all
    $allSp = New-Object System.Windows.Controls.StackPanel; $allSp.Orientation = 'Horizontal'
    $allLbl = New-Txt 'All Echos' 12 'Bold' 'Text'; [void]$allSp.Children.Add($allLbl)
    [void]$allSp.Children.Add((New-Txt '   every speaker on your Voice Monkey account' 11 'Normal' 'Caption'))
    $cbAllE.Content = $allSp
    [void]$root.Children.Add($cbAllE)
    # dropdown head (click to open / close)
    $ddHead = New-Object System.Windows.Controls.Button; $ddHead.HorizontalContentAlignment = 'Stretch'; $ddHead.Padding = '10,6,10,6'; $ddHead.ToolTip = 'Pick which Echos announce'
    $ddHead.Background = T 'CardBg'; $ddHead.BorderBrush = T 'CardBorder'; $ddHead.Foreground = T 'Text'
    $ddDock = New-Object System.Windows.Controls.DockPanel
    $ddChev = New-Txt ([string][char]0x25BE) 13 'Bold' 'Text'; [System.Windows.Controls.DockPanel]::SetDock($ddChev, 'Right'); $ddChev.Margin = '8,0,0,0'
    $ddIco = New-Txt ([string][char]0xE7F5) 13 'Normal' 'Text'; $ddIco.FontFamily = 'Segoe MDL2 Assets'; $ddIco.Margin = '0,1,8,0'; [System.Windows.Controls.DockPanel]::SetDock($ddIco, 'Left')
    $ddTxt = New-Txt '' 12 'SemiBold' 'Text'; $ddTxt.TextWrapping = 'NoWrap'; $ddTxt.TextTrimming = 'CharacterEllipsis'
    [void]$ddDock.Children.Add($ddChev); [void]$ddDock.Children.Add($ddIco); [void]$ddDock.Children.Add($ddTxt); $ddHead.Content = $ddDock
    [void]$root.Children.Add($ddHead)
    # dropdown list
    $ddBox = New-Object System.Windows.Controls.Border; $ddBox.BorderThickness = '1,0,1,1'; $ddBox.BorderBrush = T 'CardBorder'; $ddBox.Background = T 'CardBg'; $ddBox.Padding = '10,6,8,8'; $ddBox.Visibility = 'Collapsed'
    $ddIn = New-Object System.Windows.Controls.StackPanel; $ddRows = New-Object System.Windows.Controls.StackPanel; [void]$ddIn.Children.Add($ddRows)
    [void]$ddIn.Children.Add((New-Txt 'Tick = this Echo announces. Test plays one short line on that Echo only, and only when you click it.' 10 'Normal' 'Caption'))
    $ddBox.Child = $ddIn; [void]$root.Children.Add($ddBox)
    # Add speaker + Refresh list
    $sb = New-Object System.Windows.Controls.StackPanel; $sb.Orientation = 'Horizontal'; $sb.Margin = '0,8,0,0'
    $bAdd = New-SetupBtn ('+  Add speaker') 'Add another Echo to Voice Monkey (opens the Voice Monkey Speakers page and shows the one Alexa step)' '12,3,12,3' '0,0,8,0' -Bold
    $bRef = New-SetupBtn ([string][char]0x27F3 + '  Refresh list') 'Read your Voice Monkey speakers again (read-only, nothing is announced)' '12,3,12,3' '0,0,0,0'
    [void]$sb.Children.Add($bAdd); [void]$sb.Children.Add($bRef); [void]$root.Children.Add($sb)
    $spRes = New-Txt '' 10.5 'SemiBold' 'Caption'; $spRes.Margin = '0,4,0,0'; [void]$root.Children.Add($spRes)
    # Add speaker panel
    $addBox = New-Object System.Windows.Controls.Border; $addBox.BorderThickness = '1.5'; $addBox.BorderBrush = T 'Green'; $addBox.Background = T 'CardBg'; $addBox.CornerRadius = '8'; $addBox.Padding = '12,8,12,10'; $addBox.Margin = '0,6,0,0'; $addBox.Visibility = 'Collapsed'
    $ab = New-Object System.Windows.Controls.StackPanel; $addBox.Child = $ab
    [void]$ab.Children.Add((New-Txt 'Add a speaker (another Echo)' 13 'Bold' 'Text'))
    [void]$ab.Children.Add((New-Txt 'Voice Monkey lets apps list speakers but not create them, so the new speaker is made on the Voice Monkey page and linked to the Echo with one Alexa Routine.' 10.5 'Normal' 'Caption'))
    $nr = New-Object System.Windows.Controls.DockPanel; $nr.Margin = '0,8,0,0'
    $nl = New-Txt 'Name' 11.5 'SemiBold' 'Text'; $nl.Margin = '0,4,8,0'; $nl.TextWrapping = 'NoWrap'; [System.Windows.Controls.DockPanel]::SetDock($nl, 'Left')
    $addName = New-Object System.Windows.Controls.TextBox; $addName.FontSize = 12.5; $addName.Padding = '4,2,4,2'; $addName.ToolTip = 'Name it after the Echo, e.g. Kitchen Echo (letters, numbers and spaces)'; $addName.MaxLength = 40
    $addName.Background = T 'RootBg'; $addName.Foreground = T 'Text'; $addName.BorderBrush = T 'CardBorder'
    [void]$nr.Children.Add($nl); [void]$nr.Children.Add($addName); [void]$ab.Children.Add($nr)
    [void]$ab.Children.Add((New-Txt 'e.g. Kitchen Echo, Bedroom Echo, Office Show' 9.5 'Normal' 'Caption'))
    $bOpen = New-SetupBtn 'Open Voice Monkey' 'Opens app.voicemonkey.io/speakers in your browser and copies the name' '12,5,12,5' '0,8,0,0' -Bold
    $bOpenSp = New-Object System.Windows.Controls.StackPanel; $bOpenSp.Orientation = 'Horizontal'
    $oi = New-Txt ([string][char]0xE8A7) 12 'Normal' 'Text'; $oi.FontFamily = 'Segoe MDL2 Assets'; $oi.Margin = '0,1,8,0'
    [void]$bOpenSp.Children.Add($oi); [void]$bOpenSp.Children.Add((New-Txt 'Open Voice Monkey · Add New Speaker' 12 'Bold' 'Text')); $bOpen.Content = $bOpenSp
    $bOpen.Background = T 'BtnBg'; $bOpen.BorderBrush = T 'Green'; $bOpen.HorizontalAlignment = 'Left'
    [void]$ab.Children.Add($bOpen)
    $step1 = New-Txt '' 11 'Normal' 'TextSoft'; $step1.Margin = '0,8,0,0'
    $step2 = New-Txt '' 11 'Normal' 'TextSoft'; $step2.Margin = '0,5,0,0'
    $step3 = New-Txt '' 11 'Normal' 'TextSoft'; $step3.Margin = '0,5,0,0'
    [void]$ab.Children.Add($step1); [void]$ab.Children.Add($step2); [void]$ab.Children.Add($step3)
    $ar = New-Object System.Windows.Controls.StackPanel; $ar.Orientation = 'Horizontal'; $ar.Margin = '0,8,0,0'
    $bRef2 = New-SetupBtn ([string][char]0x27F3 + '  Refresh list') 'Pick up the new speaker (read-only)' '12,3,12,3' '0,0,8,0' -Bold
    $bHelp = New-SetupBtn 'Voice Monkey guide' 'Voice Monkey: Create a device and link it to Alexa' '12,3,12,3' '0,0,8,0'
    $bDone = New-SetupBtn 'Close' '' '12,3,12,3' '0,0,0,0'
    [void]$ar.Children.Add($bRef2); [void]$ar.Children.Add($bHelp); [void]$ar.Children.Add($bDone); [void]$ab.Children.Add($ar)
    $addRes = New-Txt '' 10.5 'SemiBold' 'Caption'; $addRes.Margin = '0,5,0,0'; [void]$ab.Children.Add($addRes)
    [void]$root.Children.Add($addBox)
    [void]$root.Children.Add((New-Txt ('Every TessDesk announcement (this rundown, charging started, control results, scheduled ones) uses the ticked speakers. The nightly tire reminder keeps using ' + $(if (Get-VmDevice) { Get-VmDevice } else { 'the Connected apps speaker' }) + '.') 10.5 'Normal' 'Caption'))
    # charging started
    [void]$root.Children.Add((New-Sec 'Charging started'))
    $cbChg = New-Object System.Windows.Controls.CheckBox; $cbChg.Margin = '0,2,0,2'; $cbChg.Foreground = T 'Text'; $cbChg.IsChecked = (Test-ChgStartOn)
    $cbChg.Content = (New-Txt 'Announce when charging starts (once per charge session)' 12 'SemiBold' 'Text')
    [void]$root.Children.Add($cbChg)
    [void]$root.Children.Add((New-Txt ('Waits one refresh so kW and amps are real, e.g. "' + (Get-ChargingStartedText ([pscustomobject]@{ socPct = 62; limitPct = 80; chargerKw = 11; amps = 48; minutesToFull = 130 }) $null) + '" Home PC + laptop: only one announces (a 30-minute shared lock in Voice Monkey variables).') 10.5 'Normal' 'Caption'))
    # buttons
    $bar = New-Object System.Windows.Controls.StackPanel; $bar.Orientation = 'Horizontal'; $bar.HorizontalAlignment = 'Right'; $bar.Margin = '18,8,18,12'
    $bC = New-SetupBtn 'Cancel' '' '14,4,14,4' '0,0,8,0'
    $bOk = New-SetupBtn 'Save' '' '18,4,18,4' '0,0,0,0' -Bold
    [void]$bar.Children.Add($bC); [void]$bar.Children.Add($bOk)
    [System.Windows.Controls.DockPanel]::SetDock($bar, 'Bottom'); [void]$outer.Children.Add($bar); [void]$outer.Children.Add($sv)
    $tt = New-Object System.Windows.Threading.DispatcherTimer; $tt.Interval = [TimeSpan]::FromMilliseconds(300); $tt.Add_Tick({ try { Complete-SpeakerTest } catch {} })
    $script:SetupDlg = @{ dlg = $dlg; cbs = $cbs; pv = $pv; pvInfo = $pvInfo; allE = $cbAllE; allLbl = $allLbl; ddHead = $ddHead; ddTxt = $ddTxt; ddChev = $ddChev; ddBox = $ddBox; ddRows = $ddRows; ddOpen = $false
        addBox = $addBox; addOpen = $false; addName = $addName; addRes = $addRes; step1 = $step1; step2 = $step2; step3 = $step3; spRes = $spRes; chg = $cbChg
        list = $list; sel = $selH; newIds = @(); spCbs = @(); saved = $null; testTimer = $tt; testJob = $null; lastOpen = $null }
    Fill-SpkRows; Update-AddSteps
    $cbAllE.Add_Click({ Fill-SpkRows })
    $ddHead.Add_Click({ $d = $script:SetupDlg; $d.ddOpen = -not $d.ddOpen; Update-SpkHeader })
    $bAdd.Add_Click({ $d = $script:SetupDlg; $d.addOpen = -not $d.addOpen; Update-SpkHeader; if ($d.addOpen) { try { [void]$d.addName.Focus() } catch {} } })
    $bDone.Add_Click({ $d = $script:SetupDlg; $d.addOpen = $false; Update-SpkHeader })
    $addName.Add_TextChanged({ Update-AddSteps })
    $bOpen.Add_Click({ try { Open-VmAddSpeaker } catch { $script:SetupDlg.addRes.Text = 'Could not open the browser: ' + $_.Exception.Message } })
    $bHelp.Add_Click({ if (-not $SelfTest) { try { Start-Process $VmAddDocUrl } catch {} } })
    $bRef.Add_Click({ [void](Invoke-SpkRefresh) })
    $bRef2.Add_Click({ [void](Invoke-SpkRefresh -FromAdd) })
    $bAll.Add_Click({ foreach ($c in $script:SetupDlg.cbs.Values) { $c.IsChecked = $true } })
    $bNone.Add_Click({ foreach ($c in $script:SetupDlg.cbs.Values) { $c.IsChecked = $false } })
    $prev = {
        $d = $script:SetupDlg; $o = [ordered]@{}; foreach ($k in $d.cbs.Keys) { $o[$k] = [bool]$d.cbs[$k].IsChecked }
        $rd = Get-Rundown ([pscustomobject]$o); $script:SetupPreview = $rd
        $ps = @($rd.parts)
        $d.pv.Text = $(if ($ps.Count -gt 1) { 'Part 1: ' + $ps[0] + "`r`n`r`nPart 2: " + $ps[1] } else { $ps[0] })
        $d.pvInfo.Text = ('{0} words · about {1} s · {2} announcement{3} · nothing was announced' -f $rd.words, $rd.seconds, $ps.Count, $(if ($ps.Count -eq 1) { '' } else { 's' }))
    }
    $script:SetupDlg.prev = $prev
    $bPrev.Add_Click({ try { & $script:SetupDlg.prev } catch { $script:SetupDlg.pvInfo.Text = 'Preview failed: ' + $_.Exception.Message } })
    $bC.Add_Click({ $script:SetupDlg.dlg.Close() })
    $bOk.Add_Click({
        $d = $script:SetupDlg; $o = [ordered]@{}; foreach ($k in $d.cbs.Keys) { $o[$k] = [bool]$d.cbs[$k].IsChecked }
        $ids = @(@($d.list) | Where-Object { [bool]$d.sel[$_.id] } | ForEach-Object { [string]$_.id })
        $d.saved = @{ rundownItems = [pscustomobject]$o; speakers = [pscustomobject]@{ all = [bool]$d.allE.IsChecked; ids = $ids }
                      speakerList = @($d.list | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name } }); chargingStarted = [bool]$d.chg.IsChecked }
        $d.dlg.Close()
    })
    $dlg.Add_Closed({ try { $script:SetupDlg.testTimer.Stop() } catch {} })
    $dlg.Content = $outer
    if ($SnapshotPath) {
        # self-test: lay the panel out off-screen at full height and save a PNG (nothing is shown, sent or saved)
        & $prev
        $sc = [ordered]@{ scene = $Scene }
        $d = $script:SetupDlg
        if ($Scene -eq 'dropdown') { $d.ddOpen = $true; Update-SpkHeader; $sc.test = (Invoke-SpeakerTest ([string](@($d.list | ForEach-Object { $_.id }) + @('selftest-mock-speaker'))[0])).result }
        if ($Scene -eq 'add' -or $Scene -eq 'added') { $d.addOpen = $true; $d.addName.Text = 'Kitchen Echo'; Update-SpkHeader; Open-VmAddSpeaker; $sc.open = $d.lastOpen }
        if ($Scene -eq 'added') { $sc.newFound = @(Invoke-SpkRefresh -FromAdd | ForEach-Object { $_.name + ' (' + $_.id + ')' }); $sc.testNew = (Invoke-SpeakerTest 'kitchen-echo-sample').result }
        $sv.VerticalScrollBarVisibility = 'Disabled'
        $outer.Measure([System.Windows.Size]::new(460, [double]::PositiveInfinity)); $h = [math]::Ceiling($outer.DesiredSize.Height)
        $outer.Arrange([System.Windows.Rect]::new(0, 0, 460, $h)); $outer.UpdateLayout()
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int](460 * 2)), ([int]($h * 2)), 192, 192, ([System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($outer)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [System.IO.File]::Create($SnapshotPath); try { $enc.Save($fs) } finally { $fs.Dispose() }
        $sc.preview = $pv.Text; $sc.info = $pvInfo.Text; $sc.speakers = @($d.list | ForEach-Object { $_.name + ' (' + $_.id + ')' }); $sc.allEchosLabel = $allLbl.Text; $sc.dropdown = $ddTxt.Text
        $sc.allEchos = [bool]$cbAllE.IsChecked; $sc.status = $spRes.Text; $sc.addStatus = $addRes.Text; $sc.steps = @($step1.Text, $step2.Text, $step3.Text); $sc.chargingStarted = [bool]$cbChg.IsChecked
        return $sc
    }
    try { $dlg.Owner = $window } catch {}
    [void]$dlg.ShowDialog()
    if ($null -ne $script:SetupDlg.saved) {
        Save-AnnProps $script:SetupDlg.saved
        Set-CtlResult 'idle' ('Announce Setup saved · speakers: ' + (Get-TargetLabel) + ' · charging started ' + $(if (Test-ChgStartOn) { 'on' } else { 'off' }))
        Render-Controls43; Write-WidgetStatus
    }
}
function Render-Controls43 {
    $ui.AnnNowBtn.Tag = [System.Windows.CornerRadius]::new(8); $ui.AnnSetupBtn.Tag = [System.Windows.CornerRadius]::new(8)
    foreach ($n in 'AnnNowBtn', 'AnnSetupBtn') { $ui[$n].Background = T 'BtnBg'; $ui[$n].BorderBrush = T 'BtnBorder'; $ui[$n].Foreground = T 'Text' }
    $ui.AnnNowSub.Foreground = T 'Caption'; $ui.AnnSetupTxt.Foreground = T 'Caption'
    $ready = ((Test-AnnConsent) -or $script:AnnMock) -and (Test-AnnReady)
    $ui.AnnNowSub.Text = $(if ($ready) { 'FULL STATUS · ' + (Get-TargetLabel).ToUpperInvariant() } else { 'SET UP IN CONNECTED APPS' })
}
function Get-V43Status {
    $pk = $script:PeakShown
    return [ordered]@{
        rateStatus = [ordered]@{ visible = ($ui.PeakBanner.Visibility -eq 'Visible'); mode = $(if ($null -ne $pk) { $pk.mode } else { '' }); kind = $(if ($null -ne $pk) { $pk.kind } else { '' }); title = $ui.PeakTitle.Text; sub = $(if ($ui.PeakSub.Visibility -eq 'Visible') { $ui.PeakSub.Text } else { '' }); stopButton = ($ui.PeakActions.Visibility -eq 'Visible'); reason = $(if ($null -ne $pk) { $pk.reason } else { '' }); red = $(if ($null -ne $pk) { $pk.red } else { $false }); extraUsd = $(if ($null -ne $pk) { $pk.extraUsd } else { $null }); toastLog = $script:PeakLog }
        vSlider = [ordered]@{ visible = ($ui.VThumb.Visibility -eq 'Visible'); thumb = ($ui.VPct.Text + ' / ' + $ui.VMi.Text); top = [System.Windows.Controls.Canvas]::GetTop($ui.VThumb); enabled = $ui.VLim.IsEnabled }
        announce = [ordered]@{ button = ($ui.AnnNowTxt.Text + ' · ' + $ui.AnnNowSub.Text); targets = @(Get-AnnTargets 'action'); targetLabel = (Get-TargetLabel); reminderDevice = (Get-VmDevice); speakers = (Get-SpeakerSel); speakerList = @(Get-SpeakerList)
            rundownItems = (Get-RundownSel); chargingStarted = (Test-ChgStartOn); speakerTests = @($script:SpkTestLog); lastRundown = $script:LastRundown; chargingStartedLog = $script:ChgStartLog; lastToast = $script:LastToast }
    }
}

# ---------------- v4.2: adaptive live refresh (never wakes the car) ----------------
# Tessie keeps its cached state fresh from its own connection to the car (Direct Telemetry / Fleet API): measured
# 0-13 s old while charging. TessDesk reads only that cache (GET /state?use_cache=true), in the background, at:
#   10 s  car active (charging, driving, climate on, or a control was used in the last 3 min)
#   15 s  window focused (car awake)
#   60 s  car awake but idle
#  120 s -> 300 s  car asleep / offline (backs off; 60 s while the window is focused)
#  errors back off 30 s -> 300 s (10 min after "token rejected")
$script:Live = @{ dataEpoch = $null; fetchEpoch = $null; carState = ''; reason = 'starting'; interval = 10; nextDue = 0; errors = 0; asleepRuns = 0; polls = 0; job = $null; lastCmdEpoch = 0; active = $false; charging = $false }
$script:Prefetch = $null
$script:StateFetchBlock = {
    param($u, $t, $to)
    try { return [pscustomobject]@{ ok = $true; v = (Invoke-RestMethod -Uri $u -Headers @{ Authorization = ('Bearer ' + $t); Accept = 'application/json' } -Method Get -TimeoutSec $to -UseBasicParsing) } }
    catch { $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}; return [pscustomobject]@{ ok = $false; code = $code; error = $_.Exception.Message } }
}
function Set-LiveFromState {
    param($v)
    $L = $script:Live; $now = Get-EpochNow
    $ts = @(); foreach ($k in 'charge_state', 'vehicle_state', 'climate_state', 'drive_state') { try { if ($null -ne $v.$k -and $v.$k.timestamp) { $ts += [int64]([double]$v.$k.timestamp / 1000) } } catch {} }
    if ($ts.Count -gt 0) { $L.dataEpoch = ($ts | Measure-Object -Maximum).Maximum }
    $L.fetchEpoch = $now; $L.errors = 0; $L.polls++
    $L.carState = [string]$v.state
    $cs = [string]$v.charge_state.charging_state; $sh = [string]$v.drive_state.shift_state
    $L.charging = ($cs -eq 'Charging' -or $cs -eq 'Starting')
    $L.active = ($L.charging -or $sh -in @('D', 'R', 'N') -or [bool]$v.climate_state.is_climate_on -or ($now - [int64]$L.lastCmdEpoch) -lt 180)
    Set-LiveInterval
}
function Set-LiveInterval {
    $L = $script:Live; $foc = $false; try { $foc = [bool]$window.IsActive } catch {}
    $asleep = ($L.carState -in @('asleep', 'offline', 'waiting_for_sleep') -and -not $L.active)
    if ($asleep) { $L.asleepRuns++ } else { $L.asleepRuns = 0 }
    if ($L.errors -gt 0) { $L.interval = [math]::Min(300, 30 * [math]::Pow(2, $L.errors - 1)); $L.reason = 'error backoff' }
    elseif ($asleep) { if ($foc) { $L.interval = 60 } else { $L.interval = $(if ($L.asleepRuns -gt 3) { 300 } else { 120 }) }; $L.reason = 'car ' + $L.carState }
    elseif ($L.active) { $L.interval = 10; $L.reason = $(if ($L.charging) { 'charging' } else { 'car active' }) }
    elseif ($foc) { $L.interval = 15; $L.reason = 'window focused' }
    else { $L.interval = 60; $L.reason = 'car idle' }
    $L.nextDue = (Get-EpochNow) + $L.interval
}
function Format-Age { param([int64]$s) if ($s -lt 0) { $s = 0 }; if ($s -lt 60) { return ('{0}s ago' -f $s) }; if ($s -lt 3600) { return ('{0}m ago' -f [math]::Floor($s / 60)) }; return ('{0}h ago' -f [math]::Floor($s / 3600)) }
function Update-LiveBadge {
    $L = $script:Live
    if ($null -eq $L.dataEpoch) { $ui.UpdBadge.Text = ''; return }
    $age = (Get-EpochNow) - [int64]$L.dataEpoch
    $pre = $(if ($L.carState -in @('asleep', 'offline')) { 'Car ' + $L.carState + ' · ' } else { '● ' })
    $ui.UpdBadge.Text = $pre + 'Updated ' + (Format-Age $age)
    $ui.UpdBadge.Foreground = $(if ($L.errors -gt 0) { T 'Amber' } elseif ($age -le 30 -and $L.carState -eq 'online') { T 'Green' } else { T 'Caption' })
}
function Invoke-LiveTick {
    $L = $script:Live; $now = Get-EpochNow
    Update-LiveBadge
    if ($null -ne $L.job) {
        if (-not $L.job.async.IsCompleted) { if ($now - $L.job.started -gt 40) { try { $L.job.ps.Stop(); $L.job.ps.Dispose() } catch {}; $L.job = $null; $L.errors++; Set-LiveInterval }; return }
        $res = $null; try { $o = $L.job.ps.EndInvoke($L.job.async); if ($o.Count -gt 0) { $res = $o[$o.Count - 1] } } catch {}
        try { $L.job.ps.Dispose() } catch {}; $L.job = $null
        if ($null -ne $res -and $res.ok) { $script:Prefetch = @{ v = $res.v; at = $now }; Set-LiveFromState $res.v }
        else { $L.errors++; Set-LiveInterval; if ($null -ne $res -and ($res.code -eq 401 -or $res.code -eq 403)) { $L.interval = 600; $L.nextDue = $now + 600; $L.reason = 'token rejected' }; Write-WidgetLog ('live refresh failed: ' + $(if ($null -ne $res) { $res.error } else { 'no result' })) }
        if ($null -ne $script:Prefetch -and -not $script:Dragging -and -not $script:CtlBusy) { try { Update-Ui } catch {} }
        return
    }
    if (-not [bool]$script:ReadAllowed -or -not $script:VIN -or $now -lt $L.nextDue) { return }
    if ($script:Dragging -or $script:CtlBusy) { return }
    $tok = $null; try { $tok = Get-TessieToken } catch {}
    if (-not $tok) { $L.nextDue = $now + 60; return }
    $ps = [powershell]::Create(); [void]$ps.AddScript($script:StateFetchBlock).AddArgument(($ApiBase + '/' + $script:VIN + '/state?use_cache=true')).AddArgument($tok).AddArgument($HttpTimeoutSec)
    $L.job = @{ ps = $ps; async = $ps.BeginInvoke(); started = $now }
}
function Request-LiveSoon { param([int]$Sec = 4) $script:Live.lastCmdEpoch = Get-EpochNow; $script:Live.nextDue = (Get-EpochNow) + $Sec }
function Get-LiveStatus { $L = $script:Live; return [ordered]@{ intervalSec = $L.interval; reason = $L.reason; carState = $L.carState; dataAgeSec = $(if ($null -ne $L.dataEpoch) { (Get-EpochNow) - [int64]$L.dataEpoch } else { $null }); polls = $L.polls; errors = $L.errors; badge = $ui.UpdBadge.Text; endpoint = '/state?use_cache=true (cached, never wakes the car)' } }

# ---------------- v4.2: FULL / COMPACT layout ----------------
# Full: the current layout; the lower sections scroll when they don't fit. Compact: same sections and controls,
# tighter padding, and the whole widget is scaled down just enough to fit the window (no scrolling).
$script:Layout = 'full'; try { if ($null -ne $script:Cfg.ui -and [string]$script:Cfg.ui.layout -eq 'compact') { $script:Layout = 'compact' } } catch {}
$script:OrigBox = @{}
$script:CompactScale = 1.0
function Set-LayoutMode {
    param([string]$Mode, [bool]$Save = $true)
    $script:Layout = $Mode; $c = ($Mode -eq 'compact')
    $ui.LayoutBtn.Content = $(if ($c) { 'COMPACT' } else { 'FULL' })
    $ui.LayoutBtn.ToolTip = $(if ($c) { 'Compact: everything fits the screen, no scrolling. Click for Full.' } else { 'Full: normal size, the lower sections scroll if needed. Click for Compact.' })
    $cards = @('RowsCard', 'BattCard', 'CtlCard', 'TiresCard', 'SeatsCard')
    foreach ($n in $cards) {
        $e = $ui[$n]; if (-not $script:OrigBox.ContainsKey($n)) { $script:OrigBox[$n] = @($e.Padding, $e.Margin) }
        if ($c) { $p = $script:OrigBox[$n][0]; $e.Padding = [System.Windows.Thickness]::new([math]::Max(8, $p.Left - 3), [math]::Max(3, $p.Top - 3), [math]::Max(8, $p.Right - 3), [math]::Max(3, $p.Bottom - 3)); $m = $script:OrigBox[$n][1]; $e.Margin = [System.Windows.Thickness]::new($m.Left, $m.Top, $m.Right, [math]::Min(3, $m.Bottom)) }
        else { $e.Padding = $script:OrigBox[$n][0]; $e.Margin = $script:OrigBox[$n][1] }
    }
    if ($c) { $ui.BodyScroll.VerticalScrollBarVisibility = 'Disabled'; $ui.BodyScroll.ScrollToTop() }
    else { $ui.BodyScroll.VerticalScrollBarVisibility = 'Auto'; $ui.MainGrid.LayoutTransform = [System.Windows.Media.Transform]::Identity; $script:CompactScale = 1.0 }
    if ($Save) {
        $o = [ordered]@{}; try { if ($null -ne $script:Cfg.ui) { foreach ($p in $script:Cfg.ui.PSObject.Properties) { $o[$p.Name] = $p.Value } } } catch {}
        $o['layout'] = $Mode; try { Save-ConfigProp 'ui' $o; $script:Cfg = Read-Config } catch { Write-WidgetLog ('layout save failed: ' + $_.Exception.Message) }
    }
    Update-CompactScale
}
function Update-CompactScale {
    if ($script:Layout -ne 'compact' -or -not $window.IsLoaded) { return }
    try {
        $g = $ui.MainGrid
        $wa = [System.Windows.SystemParameters]::WorkArea
        $maxH = $wa.Bottom - $window.Top
        if ($window.Height -lt $maxH) { $window.Height = [math]::Floor($maxH) }   # compact uses the full work-area height
        $window.UpdateLayout()
        $avail = $window.ActualHeight - 2 - $ui.TitleBar.ActualHeight
        $w = $window.ActualWidth - 2
        $s = 1.0
        $g.LayoutTransform = [System.Windows.Media.Transform]::Identity
        for ($i = 0; $i -lt 4; $i++) {
            if ($s -lt 0.999) { $g.LayoutTransform = [System.Windows.Media.ScaleTransform]::new($s, $s) } else { $g.LayoutTransform = [System.Windows.Media.Transform]::Identity }
            $g.Measure([System.Windows.Size]::new($w, [double]::PositiveInfinity))
            $need = $g.DesiredSize.Height
            if ($need -le $avail + 0.5) { if ($i -gt 0 -and ($avail - $need) -lt 6) { break }; if ($s -ge 0.999) { break } }
            $s = [math]::Max(0.6, [math]::Min(1.0, $s * ($avail - 1) / $need))
        }
        $g.Measure([System.Windows.Size]::new($w, [double]::PositiveInfinity))
        if ($g.DesiredSize.Height -gt $avail + 0.5 -and $s -gt 0.6) { $s = [math]::Max(0.6, $s * ($avail - 1) / $g.DesiredSize.Height); $g.LayoutTransform = [System.Windows.Media.ScaleTransform]::new($s, $s) }
        $script:CompactScale = [math]::Round($s, 3)
        $g.InvalidateMeasure(); $window.UpdateLayout()
    } catch { Write-WidgetLog ('compact scale failed: ' + $_.Exception.Message) }
}

# ---------------- Update loop ----------------
function Update-Ui {
    $script:UiMode = 'unknown'
    try {
        $local = Read-LocalJson
        if (-not [bool]$script:ReadAllowed) {
            # No Tessie calls at all until the notice is accepted and reading vehicle data is allowed.
            $script:View = Build-FallbackView $local 'Live off: review and accept the TessDesk notice first' 'fallback-no-consent'
            $script:UiMode = $script:View.mode; Render-View; return
        }
        $token = $null
        $noTokenNote = 'Live off: add your Tessie token file'
        try { $token = Get-TessieToken } catch { $noTokenNote = 'Live off: cannot read the token file' }
        if (-not $token) {
            $script:View = Build-FallbackView $local $noTokenNote 'fallback-no-token'
        } else {
            $res = $null
            try { $res = Invoke-LivePoll $token } catch {
                $note = Get-HttpErrorNote $_
                Write-WidgetLog ('live poll failed: ' + $_.Exception.Message)
                $s = $script:State.session
                if ([bool]$script:State.wasCharging -and $null -ne $s -and ((Get-EpochNow) - [int64]$s.lastEpoch) -lt 600) {
                    $script:View = Build-LiveView $s $script:State.lastCar $script:State.lastTires $local $note
                    $script:View.mode = 'live-stale-error'
                } else {
                    $script:View = Build-FallbackView $local $note 'fallback-error'
                }
            }
            if ($null -ne $res) {
                try { Watch-ChargingStarted $res } catch { Write-WidgetLog ('charging-started watch: ' + $_.Exception.Message) }
                $checked = Format-Clock (Get-LocalNow)
                if ($res.mode -eq 'live') { $script:View = Build-LiveView $res.session $res.car $res.tires $local '' $res.win }
                elseif ($null -ne $res.last) { $script:View = Build-IdleView $res.last $res.car $res.tires $local ('Live on · not charging · checked ' + $checked) }
                else { $script:View = Build-FallbackView $local ('Live on · no recent session · checked ' + $checked) 'live-idle-fallback' }
            }
        }
        $script:UiMode = $script:View.mode
        Render-View
    } catch {
        Write-WidgetLog ('Update-Ui failed: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber)
        try { $ui.StatusNote.Text = 'Widget error, retrying' } catch {}
    } finally {
        Write-WidgetStatus
    }
}

# ---------------- Fit + layout check + status file (no secrets) ----------------
# If the content ever needs more height than the window has, grow the window (never past the work area).
$script:FitGrew = $null
function Get-ContentNeed {
    $window.UpdateLayout()
    $g = $ui.MainGrid
    $w = $g.ActualWidth; $h = $g.ActualHeight
    $g.Measure([System.Windows.Size]::new($w, [double]::PositiveInfinity))
    $need = $g.DesiredSize.Height - $g.Margin.Top - $g.Margin.Bottom
    $g.InvalidateMeasure(); $window.UpdateLayout()
    return @($need, $h, $w)
}
function Confirm-Fit {
    try {
        if (-not $window.IsLoaded) { return }
        if ($script:Layout -eq 'compact') { Update-CompactScale; return }
        $m = Get-ContentNeed
        if ($m[0] -gt $m[1] + 0.5) {
            $wa = [System.Windows.SystemParameters]::WorkArea
            $newH = [math]::Min($window.Height + ($m[0] - $m[1]) + 4, $wa.Bottom - $window.Top)
            if ($newH -gt $window.Height) { $window.Height = [math]::Ceiling($newH); $script:FitGrew = $window.Height; $window.UpdateLayout() }
        }
    } catch {}
}

function Get-LayoutCheck {
    try {
        $m = Get-ContentNeed; $need = $m[0]; $h = $m[1]; $w = $m[2]
        $wide = @()
        foreach ($n in 'HeroCost', 'KwhLabel', 'DateLabel', 'NightCost', 'D7Cost', 'D30Cost', 'FooterText', 'FooterVersion', 'LoggedIn',
                       'PsiFL', 'PsiFR', 'PsiRL', 'PsiRR', 'BattState', 'TiresHdr', 'TiresRec', 'UpdBadge', 'NightCap', 'D7Cap', 'D30Cap', 'CtlHdr', 'SeatsHdr', 'AmpsHdr', 'TiresAsOf', 'SeatLvlFL', 'SeatLvlFR', 'SeatCapRR', 'AmpsNow') {
            $tb = $ui[$n]
            $tb.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
            $limitW = $w
            if ($n -like 'Psi*') { $limitW = 108 }
            if ($n -like 'SeatLvl*' -or $n -like 'SeatCap*') { $limitW = 88 }
            if ($n -like '*Cap' -and $n -notlike 'SeatCap*') { $limitW = 150 }
            if ($tb.DesiredSize.Width -gt $limitW + 0.5) { $wide += $n }
            $tb.InvalidateMeasure()
        }
        # battery top row and FROM/LIMIT labels must fit inside the battery card
        $card = $ui.BattCard.ActualWidth - 26
        $ui.BattTop.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        if ($ui.BattTop.DesiredSize.Width -gt $card + 0.5) { $wide += 'BattTop' }
        $shrunk = @()
        foreach ($n in 'HeroSub', 'TileVal0', 'TileVal1', 'TileVal2', 'TileSub0', 'TileSub1', 'TileSub2', 'LockTxt', 'LockSub', 'ClimTxt', 'ClimSub', 'HeatSub', 'DefrostSub', 'CopSub') {
            $tb = $ui[$n]; $vb = $tb.Parent
            if ($null -ne $vb -and $vb.ActualWidth -gt 0 -and $tb.ActualWidth -gt $vb.ActualWidth + 0.5) { $shrunk += $n }
        }
        $window.UpdateLayout()
        $wa = [System.Windows.SystemParameters]::WorkArea
        $sc = $ui.BodyScroll
        $scrollH = [math]::Max(0.0, $sc.ExtentHeight - $sc.ViewportHeight)
        $fixedOver = $need - $scrollH - $h       # > 0 only if something outside the scroll area doesn't fit
        $bodyW = $ui.BodyStack.ActualWidth
        if ($bodyW -lt 329.5) { $wide += ('BodyStack ' + [math]::Round($bodyW, 1)) }
        return [ordered]@{ window = ('{0}x{1}' -f $window.Width, $window.Height); contentNeededHeight = [math]::Round($need, 1)
            contentAvailableHeight = [math]::Round($h, 1); contentWidth = [math]::Round($w, 1)
            scroll = [ordered]@{ used = ($scrollH -gt 0.5); viewport = [math]::Round($sc.ViewportHeight, 1); content = [math]::Round($sc.ExtentHeight, 1); hiddenBelow = [math]::Round($scrollH, 1); offset = [math]::Round($sc.VerticalOffset, 1); bodyWidth = [math]::Round($bodyW, 1) }
            fullHeightNeeded = [math]::Round($need + 28 + 18 + 2, 0)
            clipped = (($fixedOver -gt 0.5) -or ($wide.Count -gt 0)); tooWide = $wide; scaledToFit = $shrunk
            workArea = ('{0},{1} {2}x{3}' -f $wa.Left, $wa.Top, $wa.Width, $wa.Height); bottom = ($window.Top + $window.Height)
            fitsWorkArea = (($window.Top + $window.Height) -le ($wa.Bottom + 0.5)); grewTo = $script:FitGrew }
    } catch { return [ordered]@{ error = $_.Exception.Message } }
}

function Write-WidgetStatus {
    try {
        $v = $script:View
        $tiles = @(); if ($null -ne $v) { foreach ($t in @($v.tiles)) { if ($null -ne $t) { $tiles += ('{0}: {1}{2}' -f $t[0], $t[1], $(if ($t.Count -gt 2 -and [string]$t[2] -ne ' ') { ' (' + $t[2] + ')' } else { '' })) } } }
        $tires = $null
        if ($null -ne $v -and $null -ne $v.tires) {
            $tires = [ordered]@{ fl = $v.tires.fl; fr = $v.tires.fr; rl = $v.tires.rl; rr = $v.tires.rr; recFront = $v.tires.recFront; recRear = $v.tires.recRear
                shown = [ordered]@{ fl = (Get-TextOf $ui.PsiFL); fr = (Get-TextOf $ui.PsiFR); rl = (Get-TextOf $ui.PsiRL); rr = (Get-TextOf $ui.PsiRR) }
                flags = $script:TireFlags; header = $ui.TiresHdr.Text; asOf = $ui.TiresAsOf.Text }
        }
        $car = Get-CtlCar
        $o = [ordered]@{
            app = ('{0} v{1}' -f $AppName, $AppVersion); mode = $script:UiMode; at = (Get-LocalNow).ToString('s')
            theme = $script:Theme.Name; tessieLook = 'always on'; palette = $(if ([bool]$script:ThemeCharging) { 'charging' } else { 'not-charging' }); title = $ui.TitleText.Text; loggedIn = $ui.LoggedIn.Text; vin = $script:VIN
            dateLabel = $ui.DateLabel.Text; badge = $(if ($ui.LiveBadge.Visibility -eq 'Visible') { $ui.LiveBadge.Text } else { '' })
            hero = $ui.HeroCost.Text; heroColor = $ui.HeroCost.Foreground.ToString(); heroSub = $ui.HeroSub.Text
            kwh = $ui.KwhLabel.Text
            battery = [ordered]@{ pct = $ui.BattPct.Text; range = $ui.BattRange.Text; rangeKind = $ui.BattRangeCap.Text; state = $ui.BattState.Text
                from = ($ui.FromMi.Text + ' / ' + $ui.BarStartLbl.Text); limit = ($ui.LimitMi.Text + ' / ' + $ui.BarLimitLbl.Text); ball = $ui.BarBallText.Text
                limitSlider = [ordered]@{ visible = ($ui.LimitThumb.Visibility -eq 'Visible'); left = [System.Windows.Controls.Canvas]::GetLeft($ui.LimitThumb); bounds = (Get-LimitBounds) } }
            tiles = $tiles; tileColor = $ui.TileVal0.Foreground.ToString()
            tires = $tires
            consent = [ordered]@{ agreedAt = $(if ($null -ne $script:Consent) { $script:Consent.agreedAt } else { $null }); readVehicleData = [bool]$script:ReadAllowed; sendCommands = [bool]$script:CmdAllowed; reminders = [bool]$script:RemAllowed; selfTestAssumed = [bool]$script:ConsentAssumed }
            live = (Get-LiveStatus); layoutMode = [ordered]@{ mode = $script:Layout; compactScale = $script:CompactScale }; reminderChannels = @(Get-RemChannels); reminders = [ordered]@{ configured = (Test-RemindersReady); channel = $(if ($null -ne $script:RemCfg) { $script:RemCfg.channel } else { $null }); dryRun = $REM_DRYRUN; scheduled = @($script:RemScheduled) }
            alexa = [ordered]@{ toggle = [bool]$script:AlexaOn; ready = (Test-AnnReady); disclosureAccepted = (Test-AnnConsent); tokenSaved = (Test-Path -LiteralPath $VmTokenPath); device = (Get-VmDevice); dryRun = (Test-AnnDryRun)
                realAnnouncementsSentThisRun = $script:AnnSent; recent = $script:AnnLog; schedules = (Get-AnnSchedules); tasks = @(Get-AnnTaskList) }
            tireThresholds = [ordered]@{ yellowPct = $TIRE_YELLOW; redPct = $TIRE_RED; maxPsiNoRec = $TIRE_MAX_NOREC; minPsiNoRec = $TIRE_MIN_NOREC }
            controls = [ordered]@{ enabled = $CTL_ENABLED; commandsAllowed = [bool]$script:CmdAllowed; dryRun = $CTL_DRYRUN; busy = $script:CtlBusy
                lock = ($ui.LockTxt.Text + ' · ' + $ui.LockSub.Text); climate = ($ui.ClimTxt.Text + ' · ' + $ui.ClimSub.Text)
                windows = ($ui.VentSub.Text + ' / ' + $ui.CloseWinSub.Text); setTemp = $ui.TempVal.Text; units = $(if (Test-UnitsF) { 'F' } else { 'C' })
                windowsGreen = $(if ($ui.VentBtn.BorderBrush.ToString() -eq (T 'Green').ToString()) { 'vent' } elseif ($ui.CloseWinBtn.BorderBrush.ToString() -eq (T 'Green').ToString()) { 'closed' } else { 'none' })
                windowPositions = $(if ($null -ne $car) { $car.windows } else { $null })
                charging = [ordered]@{ start = ($ui.ChgStartTxt.Text + ' · ' + $ui.ChgStartSub.Text); stop = ($ui.ChgStopTxt.Text + ' · ' + $ui.ChgStopSub.Text); startEnabled = $ui.ChgStartBtn.IsEnabled; stopEnabled = $ui.ChgStopBtn.IsEnabled }
                amps = [ordered]@{ shown = $ui.AmpsVal.Text; min = $ui.AmpsMinLbl.Text; max = $ui.AmpsMaxLbl.Text; note = $ui.AmpsNow.Text; thumbLeft = [System.Windows.Controls.Canvas]::GetLeft($ui.AmpsThumb); bounds = (Get-AmpsBounds) }
                heat = ($ui.HeatTxt.Text + ' · ' + $ui.HeatSub.Text); heatTempF = $HEAT_F; defrost = ($ui.DefrostTxt.Text + ' · ' + $ui.DefrostSub.Text); cabinOverheat = ($ui.CopTxt.Text + ' · ' + $ui.CopSub.Text)
                seats = [ordered]@{ fl = $ui.SeatFLN.Text; fr = $ui.SeatFRN.Text; rl = $(if ($ui.SeatRL.Visibility -eq 'Visible') { $ui.SeatRLN.Text } else { 'hidden' }); rc = $(if ($ui.SeatRC.Visibility -eq 'Visible') { $ui.SeatRCN.Text } else { 'hidden' }); rr = $(if ($ui.SeatRR.Visibility -eq 'Visible') { $ui.SeatRRN.Text } else { 'hidden' }); wheel = $(if ($ui.WheelBtn.Visibility -eq 'Visible') { $ui.WheelLvl.Text } else { 'hidden' }) }
                result = $script:CtlResultText; resultKind = $script:CtlResultKind; recent = $script:CtlLog; realCommandsSentThisRun = $script:NetCommandsSent }
            rows = [ordered]@{
                sessions = [ordered]@{ visible = ($ui.SessBox.Visibility -eq 'Visible'); header = $ui.SessHdr.Text; lines = @($ui.SessList.Children | ForEach-Object { $_.Text }) }
                night = [ordered]@{ label = $ui.NightLbl.Text; caption = $ui.NightCap.Text; cost = $ui.NightCost.Text; kwh = $ui.NightKwh.Text }
                d7 = [ordered]@{ cost = $ui.D7Cost.Text; kwh = $ui.D7Kwh.Text; caption = $ui.D7Cap.Text }
                d30 = [ordered]@{ cost = $ui.D30Cost.Text; kwh = $ui.D30Kwh.Text; caption = $ui.D30Cap.Text } }
            rateNote = $ui.RateNote.Text; statusNote = $ui.StatusNote.Text
            footer = [ordered]@{ text = (((@($ui.FooterText.Inlines | ForEach-Object { $_.Text }) -join '') -replace [string][char]0x2009, '') -replace '\s+', ' ').Trim(); version = $ui.FooterVersion.Text; link = $ChangelogUrl; about = $ui.FooterAbout.Text; aboutLink = $PrivacyUrl }
            layout = Get-LayoutCheck
            position = [ordered]@{ left = $window.Left; top = $window.Top; width = $window.Width; height = $window.Height }
            keptSpot = $script:KeptSpot; startedAtKeptSpot = [bool]$script:StartedAtKept
            lastSnapshot = $script:LastSnapshot
            v43 = (Get-V43Status)
            v432 = [ordered]@{ glow = $script:GlowMode; glowForced = $script:GlowForce; glowOpacityNow = [math]::Round($ui.GlowFrame.Opacity, 2); seatsCardAboveTires = $true
                flash = [ordered]@{ pauseSec = $ui.FlashPause.Text; noWait = [bool]$script:Flash.noWait; stats = $ui.FlashStats.Text; rtts = @($script:Flash.rtts); gapSec = (Get-FlashGap); count = $ui.FlashCount.Text; button = $ui.FlashBtnTxt.Text; progress = $ui.FlashSub.Text; running = [bool]$script:Flash.running; done = $script:Flash.done; total = $script:Flash.total }
                lastChargeWindow = $script:LastWindow }
            v433 = [ordered]@{ trunk = [ordered]@{ button = $ui.TrunkTxt.Text; sub = $ui.TrunkSub.Text }; sentry = [ordered]@{ button = $ui.SentryTxt.Text; sub = $ui.SentrySub.Text }
                drives = @(@(Get-Val $script:State.drives @()) | Where-Object { $null -ne $_ }).Count; drivesFetched = $script:State.drivesFetchEpoch; drivesNote = $script:DrivesNote
                update = $script:Upd; updateButton = $(if ($ui.UpdateBtn.Visibility -eq 'Visible') { $ui.UpdateTxt.Text } else { $null }); updateFeed = (Get-UpdUrl)
                locationHistory = @(Get-LocationHistory).Count; resumeJoined = $script:ResumeJoined; carryFix = $script:CarryFix; frunkButton = $false }
        }
        $o | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $statusPath -Encoding UTF8
    } catch { Write-WidgetLog ('status write failed: ' + $_.Exception.Message) }
}

# ---------------- Snapshots (RenderTargetBitmap of the window itself) ----------------
function Save-RootPng {
    # -Full: lay the window out at its full content height (no scrolling) just for the picture, then restore.
    param([string]$Path, [switch]$Full)
    Set-TirePulse $false
    $window.UpdateLayout()
    $root = $ui.RootBorder
    if ($Full) {
        $root.Measure([System.Windows.Size]::new($root.ActualWidth, [double]::PositiveInfinity))
        $root.Arrange([System.Windows.Rect]::new(0, 0, $root.ActualWidth, $root.DesiredSize.Height))
    }
    $scale = 2.0
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]($root.ActualWidth * $scale)), ([int]($root.ActualHeight * $scale)), (96 * $scale), (96 * $scale), ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [System.IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose(); Set-TirePulse $true; if ($Full) { $root.InvalidateMeasure(); $root.InvalidateArrange(); $window.UpdateLayout() } }
}

# Writes the (always-on) Tessie look in the current state; while charging also a not-charging preview
# built from the last completed charge. The live view is restored afterwards.
function Save-Snapshots {
    param([string]$Dir)
    if (-not $Dir) { $Dir = Join-Path $scriptDir 'shots' }
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $liveView = $script:View
    $files = @()
    $isChg = ($null -ne $liveView -and $liveView.accent -eq 'green')
    $cur = $(if ($isChg) { 'charging' } else { 'idle' })
    try {
        Render-View
        $p = Join-Path $Dir ('tessdesk-v43-{0}.png' -f $cur); Save-RootPng $p; $files += $p
        $p = Join-Path $Dir ('tessdesk-v43-{0}-full.png' -f $cur); Save-RootPng $p -Full; $files += $p
        $st = $script:State
        if ($isChg -and $null -ne $st) {
            $last = $st.lastCharge; if ($null -eq $last) { $last = Get-LatestCompleted $st.recentSessions }
            if ($null -ne $last) {
                $pc = $st.lastCar
                if ($null -ne $pc) { $pc = $pc.PSObject.Copy(); $pc.chargingState = 'Complete'; $pc.chargerKw = 0; $pc.volts = 0; $pc.amps = 0 }
                $script:View = Build-IdleView $last $pc $st.lastTires (Read-LocalJson) 'Preview: not-charging look (last completed charge)'
                Render-View
                $p = Join-Path $Dir 'tessdesk-v43-idle-preview.png'; Save-RootPng $p; $files += $p
                $p = Join-Path $Dir 'tessdesk-v43-idle-preview-full.png'; Save-RootPng $p -Full; $files += $p
            }
        }
    } finally {
        $script:View = $liveView
        Render-View
    }
    $script:LastSnapshot = [ordered]@{ at = (Get-LocalNow).ToString('s'); files = $files }
    Write-WidgetStatus
}

# ---------------- Window behavior ----------------
$ui.TitleBar.Add_MouseLeftButtonDown({ param($sender, $e) try { $window.DragMove() } catch {} })
$ui.CloseBtn.Add_Click({ $window.Close() })

# Footer version = link to the "What's new" changelog (opens in the default browser).
$ui.FooterVersion.Cursor = [System.Windows.Input.Cursors]::Hand
$ui.FooterVersion.ToolTip = "What's new in TessDesk"
$ui.FooterVersion.Add_MouseEnter({ $ui.FooterVersion.TextDecorations = [System.Windows.TextDecorations]::Underline })
$ui.FooterVersion.Add_MouseLeave({ $ui.FooterVersion.TextDecorations = $null })
$ui.FooterVersion.Add_MouseLeftButtonUp({ if (-not $SelfTest) { try { Start-Process $ChangelogUrl } catch { Write-WidgetLog ('changelog open failed: ' + $_.Exception.Message) } } })
# About / Privacy: opens the in-app notice + permissions + getting-started links (with a link to the full privacy page).
$ui.FooterAbout.Cursor = [System.Windows.Input.Cursors]::Hand
$ui.FooterAbout.ToolTip = 'About TessDesk: notice, privacy, permissions and getting-started links'
$ui.FooterAbout.Add_MouseEnter({ $ui.FooterAbout.TextDecorations = [System.Windows.TextDecorations]::Underline })
$ui.FooterAbout.Add_MouseLeave({ $ui.FooterAbout.TextDecorations = $null })
$ui.FooterAbout.Add_MouseLeftButtonUp({ if (-not $SelfTest) { try { Show-ConsentWindow $false } catch { Write-WidgetLog ('about window failed: ' + $_.Exception.Message) } } })
$ui.KeepBtn.Add_MouseLeftButtonUp({ try { Invoke-KeepSpot } catch { Write-WidgetLog ('keep failed: ' + $_.Exception.Message); Show-TdToast ('Could not save the spot: ' + $_.Exception.Message) $false } })
$ui.RestoreBtn.Add_MouseLeftButtonUp({ try { Invoke-RestoreSpot } catch { Write-WidgetLog ('restore failed: ' + $_.Exception.Message) } })
$ui.LayoutBtn.Add_Click({ try { Set-LayoutMode $(if ($script:Layout -eq 'compact') { 'full' } else { 'compact' }) (-not $SelfTest) } catch { Write-WidgetLog ('layout toggle failed: ' + $_.Exception.Message) } })
$ui.RemindSetup.Add_MouseLeftButtonUp({ try { [void](Show-ReminderSetup) } catch { Write-WidgetLog ('reminder setup failed: ' + $_.Exception.Message) } })
$ui.RemindBtn.Add_Click({ try { Request-TireReminder } catch { Write-WidgetLog ('reminder failed: ' + $_.Exception.Message); [void][System.Windows.MessageBox]::Show($window, ('Could not set the reminder: ' + $_.Exception.Message), 'TessDesk · Reminder', 'OK', 'Warning') } })

# Placement: Van's left-screen row (config.json placement: Left = WorkArea.Right - rightOffset, Top = WorkArea.Top + top).
try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $left = $wa.Right - $PL_RIGHT
    $top  = $wa.Top + $PL_TOP
    $window.Left = [math]::Max($wa.Left, [math]::Min($left, $wa.Right - $winW))
    $window.Top  = [math]::Max($wa.Top, [math]::Min($top, $wa.Bottom - $winH))
} catch { $window.Left = 40; $window.Top = 40 }

# ---------------- v4.3.11: Restore / Remember look and feel like Paycheck Live's ----------------
# Same pill as Paycheck Live (#FF444444, hover #FF666666 with white text), label reads restored / saved / failed for 1.4 s
# (button disabled meanwhile) and its tooltip then shows what happened. The save / restore logic is unchanged (desk_window_layout.json TESSDESK entry).
$DwLbl = @{ restore = ([string][char]0x27F2 + ' Restore'); remember = 'Remember' }
$script:DwBrush = @{}
function Get-DwBrush { param([string]$Hex) if (-not $script:DwBrush.ContainsKey($Hex)) { $b = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex); $b.Freeze(); $script:DwBrush[$Hex] = $b }; return $script:DwBrush[$Hex] }
function Set-DwHover { param($Btn, [bool]$On) $Btn.Background = Get-DwBrush $(if ($On) { '#FF666666' } else { '#FF444444' }); $Btn.Child.Foreground = Get-DwBrush $(if ($On) { '#FFFFFFFF' } else { '#FFDDDDDD' }) }
foreach ($dwb in @($ui.RestoreBtn, $ui.KeepBtn)) {
    $dwb.Add_MouseEnter({ param($s, $e) try { Set-DwHover $s $true } catch {} })
    $dwb.Add_MouseLeave({ param($s, $e) try { Set-DwHover $s $false } catch {} })
}
function Set-DwTip { param($Btn, [string]$Act, $R, [string]$Err) try { $Btn.ToolTip = $(if ($null -ne $R) { $Act + ': ' + [int]$R.x + ',' + [int]$R.y + ' ' + [int]$R.w + 'x' + [int]$R.h + $(if ($Err) { ' (' + $Err + ')' } else { '' }) } elseif ($Err) { $Err } else { 'failed' }) } catch {} }
# ---------------- v4.3.5: KEEP / RESTORE (window spot) ----------------
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch {}
if (-not ('TdWinRect' -as [type])) {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class TdWinRect { [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; } [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); }'
}
# v4.3.7: REMEMBER / RESTORE use the same file and behavior as TIMECLOCK LIVE and Paycheck Live:
#   %USERPROFILE%\desk_window_layout.json, one entry per window (WPF units); only the TESSDESK entry is ever rewritten.
#   REMEMBER = save the current size and place (not when minimized, maximized, off-screen or an implausible size).
#   RESTORE  = back to the remembered size and place; nothing remembered yet -> the place TessDesk picked at startup.
#   Startup  = opens at the remembered place. (cb_window_layout.json belongs to the stream windows and is not touched.)
#   config.json keptSpot keeps a copy (with the screen name) in case the layout file is missing.
$DeskLayoutPath = Join-Path $env:USERPROFILE 'desk_window_layout.json'
$DWL_Name = 'TESSDESK'
$DWL_Note = 'Written by the Remember button of Paycheck Live / TessDesk / TimeClock Live; read by their Restore button and at startup'
$script:KeptSpot = $null; try { if ($null -ne $c.keptSpot -and $null -ne $c.keptSpot.left) { $script:KeptSpot = $c.keptSpot } } catch {}
function Get-TdHwnd { return (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle }
function Get-TdMonitor { try { return [string][System.Windows.Forms.Screen]::FromHandle((Get-TdHwnd)).DeviceName } catch { return $null } }
function Test-SpotUsable {
    param($S)
    if ($null -eq $S) { return $false }
    try {
        $scr = @([System.Windows.Forms.Screen]::AllScreens)
        if ($S.monitor -and -not ($scr | Where-Object { $_.DeviceName -eq [string]$S.monitor })) { return $false }
        $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
        $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
        $l = [double]$S.left; $t = [double]$S.top; $w = [double]$S.width
        return (($l + $w) -gt ($vl + 40) -and $l -lt ($vl + $vw - 40) -and $t -ge ($vt - 10) -and $t -lt ($vt + $vh - 40))
    } catch { return $false }
}
function Set-TdSpot {
    param($S)
    $window.Left = [double]$S.left; $window.Top = [double]$S.top
    if ($null -ne $S.width -and [double]$S.width -ge 200) { $window.Width = [double]$S.width }
    if ($null -ne $S.height -and [double]$S.height -ge 400) { $window.Height = [double]$S.height }
}
function Get-DeskLayoutPath {
    if ($SelfTest) { if ($script:SelfDeskPath) { return $script:SelfDeskPath }; return $null }   # a self-test never writes the real file
    return $DeskLayoutPath
}
function Read-DeskLayout {
    param([switch]$Strict)
    $p = Get-DeskLayoutPath; if (-not $p) { $p = $DeskLayoutPath }
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { if ($Strict) { throw ('desk_window_layout.json could not be read - not changed (' + $_.Exception.Message + ')') }; Write-WidgetLog ('desk layout read: ' + $_.Exception.Message); return $null }
}
function Get-DeskSaved {
    $doc = Read-DeskLayout
    if ($doc -and $doc.windows) {
        $e = @($doc.windows | Where-Object { $null -ne $_ -and [string]$_.name -eq $DWL_Name }) | Select-Object -First 1
        if ($e -and $null -ne $e.x -and $null -ne $e.y -and [int]$e.w -ge 100 -and [int]$e.h -ge 60) { return [pscustomobject]@{ left = [double]$e.x; top = [double]$e.y; width = [double]$e.w; height = [double]$e.h; monitor = $null; from = 'desk_window_layout.json' } }
    }
    if ($null -ne $script:KeptSpot) { return [pscustomobject]@{ left = [double]$script:KeptSpot.left; top = [double]$script:KeptSpot.top; width = $script:KeptSpot.width; height = $script:KeptSpot.height; monitor = $script:KeptSpot.monitor; from = 'config.json keptSpot' } }
    return $null
}
function Write-DeskTessDeskEntry {
    param($R)
    $p = Get-DeskLayoutPath; if (-not $p) { throw 'self-test without a test copy of the layout file' }
    $doc = Read-DeskLayout -Strict
    $list = New-Object System.Collections.Generic.List[object]; $found = $false
    if ($doc -and $doc.windows) {
        foreach ($e in @($doc.windows)) {
            if ($null -eq $e) { continue }
            if ([string]$e.name -eq $DWL_Name) {
                foreach ($k in 'x', 'y', 'w', 'h') { $e | Add-Member -NotePropertyName $k -NotePropertyValue ([int]$R[$k]) -Force }
                $e | Add-Member -NotePropertyName source -NotePropertyValue 'remembered' -Force
                $found = $true
            }
            $list.Add($e)
        }
    }
    if (-not $found) { $list.Add([pscustomobject][ordered]@{ name = $DWL_Name; script = (Join-Path $scriptDir 'TessDesk.ps1'); x = [int]$R.x; y = [int]$R.y; w = [int]$R.w; h = [int]$R.h; source = 'remembered' }) }
    $out = [ordered]@{ saved = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); note = $DWL_Note; windows = $list.ToArray() }
    $tmp = $p + '.tmp'
    $out | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $p -Force
    return $(if ($found) { 'TESSDESK entry updated' } else { 'TESSDESK entry added' })
}
function Set-SpotBtnFeedback {
    # like TIMECLOCK LIVE: the button reads 'saved' / 'restored' / 'failed' for 1.4 s
    # v4.3.11: like Paycheck Live, the button is disabled while it shows the result
    param($Tb, [string]$Text, [string]$Orig)
    $Tb.Text = $Text
    try { $Tb.Parent.IsEnabled = $false } catch {}
    $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(1400); $t.Tag = @($Tb, $Orig)
    $t.Add_Tick({ param($sx, $ex) try { $sx.Stop(); $sx.Tag[0].Text = $sx.Tag[1]; $sx.Tag[0].Parent.IsEnabled = $true; Set-DwHover $sx.Tag[0].Parent ([bool]$sx.Tag[0].Parent.IsMouseOver) } catch {} })
    $t.Start()
}
function Invoke-KeepSpot {
    $fail = { param($why) Set-SpotBtnFeedback $ui.KeepTxt 'failed' $DwLbl.remember; Set-DwTip $ui.KeepBtn 'remember' $null ($why + ' - not saved'); Show-TdToast ('Not saved: ' + $why) $false; Write-WidgetLog ('REMEMBER: not saved (' + $why + ')'); $script:KeepLast = [ordered]@{ action = 'remember'; ok = $false; error = $why } }
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) { & $fail 'minimized'; return }
    if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) { & $fail 'maximized'; return }
    $R = [ordered]@{ x = [int][math]::Round($window.Left); y = [int][math]::Round($window.Top); w = [int][math]::Round($window.ActualWidth); h = [int][math]::Round($window.ActualHeight) }
    $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
    $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
    if (-not (($R.x + $R.w -gt $vl + 40) -and ($R.x -lt $vl + $vw - 40) -and ($R.y + 30 -gt $vt) -and ($R.y -lt $vt + $vh - 40))) { & $fail 'off-screen'; return }
    if ($R.w -lt 100 -or $R.h -lt 60 -or $R.w -gt $vw -or $R.h -gt $vh) { & $fail 'implausible size'; return }
    $S = [ordered]@{ left = $R.x; top = $R.y; width = $R.w; height = $R.h; monitor = (Get-TdMonitor); savedAt = (Get-LocalNow).ToString('s') }
    Save-ConfigProp 'keptSpot' $S
    $script:KeptSpot = [pscustomobject]$S
    $lf = $null; try { $lf = Write-DeskTessDeskEntry $R } catch { $lf = 'desk_window_layout.json not updated: ' + $_.Exception.Message; Write-WidgetLog $lf }
    $script:KeepLast = [ordered]@{ action = 'remember'; ok = $true; spot = $S; layoutFile = $lf; path = (Get-DeskLayoutPath) }
    Write-WidgetLog ('REMEMBER: spot saved ' + $R.x + ',' + $R.y + ' ' + $R.w + 'x' + $R.h + ' on ' + $S.monitor + ' (' + $lf + ')')
    Set-SpotBtnFeedback $ui.KeepTxt 'saved' $DwLbl.remember
    Set-DwTip $ui.KeepBtn 'remember' $R
}
function Invoke-RestoreSpot {
    $S = Get-DeskSaved
    if ($null -ne $S -and -not (Test-SpotUsable $S)) { Set-SpotBtnFeedback $ui.RestoreTxt 'failed' $DwLbl.restore; Set-DwTip $ui.RestoreBtn 'restore' $null 'the remembered spot is not on any screen right now'; Show-TdToast 'The remembered spot is not on any screen right now' $false; return }
    if ($window.WindowState -ne [System.Windows.WindowState]::Normal) { $window.WindowState = [System.Windows.WindowState]::Normal }
    if ($null -eq $S) {
        if ($null -eq $script:DWL_Default) { Set-SpotBtnFeedback $ui.RestoreTxt 'failed' $DwLbl.restore; Set-DwTip $ui.RestoreBtn 'restore' $null 'no saved place'; Show-TdToast 'No spot remembered yet: press Remember first' $false; return }
        $window.Left = [double]$script:DWL_Default.left; $window.Top = [double]$script:DWL_Default.top   # nothing remembered: the startup place, size unchanged
        $from = 'startup place'
    } else { Set-TdSpot $S; $from = [string]$S.from }
    try { $window.UpdateLayout(); [void]$window.Activate() } catch {}
    $script:KeepLast = [ordered]@{ action = 'restore'; spot = $S; from = $from; at = [ordered]@{ left = $window.Left; top = $window.Top; width = $window.Width; height = $window.Height } }
    Write-WidgetLog ('RESTORE: moved to ' + [math]::Round($window.Left) + ',' + [math]::Round($window.Top) + ' (' + $from + ')')
    Set-SpotBtnFeedback $ui.RestoreTxt 'restored' $DwLbl.restore
    Set-DwTip $ui.RestoreBtn 'restore' ([ordered]@{ x = $window.Left; y = $window.Top; w = $window.ActualWidth; h = $window.ActualHeight })
}
# startup: remember the place TessDesk picked itself (RESTORE falls back to it), then open at the remembered spot
$script:DWL_Default = [pscustomobject]@{ left = $window.Left; top = $window.Top }
try { $sp0 = Get-DeskSaved; if ($null -ne $sp0 -and (Test-SpotUsable $sp0)) { Set-TdSpot $sp0; $script:StartedAtKept = $true; $script:StartedFrom = [string]$sp0.from } } catch {}

# ---------------- v4.3.7: SHARE (links only; the app that opens does the sending, never TessDesk) ----------------
$ShareLinks = [ordered]@{ phone = 'https://vanwidick.github.io/tessdesk/'; download = 'https://vanwidick.github.io/tessdesk/download.html' }
$ShareSubject = 'TessDesk: live Tesla charging cost'
$ShareQrB64 = 'iVBORw0KGgoAAAANSUhEUgAAAIQAAACEAQAAAAB5P74KAAABGUlEQVR4nM2WQW5EMQhDH1+zNzf49z9WbmBO4C6mXUy7KiNVZZUghRiwSSq82lx8t7/1VFUPUz1UVS/jECVS8rX0GmE1Z9pKU/1mpn3k9m9P/fC0KebXt796YoJoQ7yNUynQ52ZAZ9uvpym2kmTZrwcNeIDb9NGePyjCUZDX/HmAKaw+ZFR7PA5JACfxtj4XXaqaCKqGrb4uJCwaCaE9D4dp+pg2zDYOgdiSEWFdH+JIskKQ/UbfSwfNUxz3Pi+BIHJkrfFcHPnIAw0Hv4HHKJIBrXV6PZXVcFthPecfFOjQGejxvedzggg0Rtv6PN+LuhsypdnrCyAHumV6y58HAA0dmMkbeGJ8mJpCs6/PVNE6AdjPn/pn/5YPNzan6JGUdtgAAAAASUVORK5CYII='
$script:ShareLog = @()
function Get-ShareText { return ("TessDesk shows what your Tesla's charging costs, live (it works with your Tessie account).`r`nPhone: " + $ShareLinks.phone + "`r`nWindows: " + $ShareLinks.download) }
function Get-ShareQr {
    $b = [Convert]::FromBase64String($ShareQrB64); $ms = New-Object System.IO.MemoryStream(, $b)
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage; $bi.BeginInit(); $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bi.StreamSource = $ms; $bi.EndInit(); $bi.Freeze()
    return $bi
}
function Open-ShareTarget {
    param([string]$Kind, [string]$Uri)
    $script:ShareLog += [pscustomobject]@{ kind = $Kind; uri = $Uri; at = (Get-LocalNow).ToString('s'); launched = (-not $SelfTest) }
    if ($SelfTest) { return }      # the self-test records what would open; it never opens an app
    Start-Process $Uri
}
function Set-ShareClipboard { param([string]$T) try { [System.Windows.Clipboard]::SetText($T); return $true } catch { return $false } }
function Open-ShareOverlay {
    $ui.ShareBox.Background = T 'CardBg'; $ui.ShareTitle.Foreground = T 'Text'; $ui.ShareSub.Foreground = T 'TextSoft'; $ui.ShQrTxt.Foreground = T 'TextSoft'
    foreach ($n in 'ShMessenger', 'ShText', 'ShEmail', 'ShCopy', 'ShPhone', 'ShClose') { $ui[$n].Background = T 'BtnBg'; $ui[$n].BorderBrush = T 'BtnBorder'; $ui[$n].Foreground = T 'Text' }
    $ui.ShPhone.BorderBrush = T 'Green'
    Set-Visible $ui.ShQrBox $false
    Set-Visible $ui.ShareOverlay $true
}
function Close-ShareOverlay { Set-Visible $ui.ShareOverlay $false }
function Invoke-Share {
    param([string]$Kind)
    $txt = Get-ShareText
    switch ($Kind) {
        'messenger' { [void](Set-ShareClipboard $txt); Open-ShareTarget 'messenger' 'https://www.messenger.com/'; Close-ShareOverlay; Show-TdToast 'Message copied. Messenger is opening: pick who gets it, paste (Ctrl+V) and press send.' $true }
        'text' { [void](Set-ShareClipboard $txt); Open-ShareTarget 'text' ('sms:?body=' + [uri]::EscapeDataString($txt)); Close-ShareOverlay; Show-TdToast 'Your texting app is opening with the message filled in (also copied). Pick who gets it and press send.' $true }
        'email' { Open-ShareTarget 'email' ('mailto:?subject=' + [uri]::EscapeDataString($ShareSubject) + '&body=' + [uri]::EscapeDataString($txt)); Close-ShareOverlay; Show-TdToast 'Your email app is opening with a new message. Add who gets it and press send.' $true }
        'copy' { $ok = Set-ShareClipboard $ShareLinks.phone; $script:ShareLog += [pscustomobject]@{ kind = 'copy'; uri = $ShareLinks.phone; at = (Get-LocalNow).ToString('s'); launched = $false }; Close-ShareOverlay; Show-TdToast $(if ($ok) { 'Link copied: ' + $ShareLinks.phone } else { 'Could not copy the link' }) $ok }
        'phone' { try { if ($null -eq $ui.ShQr.Source) { $ui.ShQr.Source = Get-ShareQr } } catch { Write-WidgetLog ('share QR: ' + $_.Exception.Message) }; Set-Visible $ui.ShQrBox $true; $script:ShareLog += [pscustomobject]@{ kind = 'phone'; uri = $ShareLinks.phone; at = (Get-LocalNow).ToString('s'); launched = $false } }
    }
}

# ---------------- v4.3.7: UPDATE POP-UP (Update now / Later) ----------------
# When version.json lists a newer version, TessDesk asks once: Update now (download, check SHA-256, back up, install, restart)
# or Later. Publishing a new version from Van's master copy to the site is what every other copy picks up here.
# v4.3.8: Later = not asked again for that version until TessDesk is opened again (kept in memory only, never saved;
# a still newer version asks again). The green UPDATE AVAILABLE button stays either way.
$script:UpdLaterFor = $null
$script:UpdPrompt = [ordered]@{ shown = $null; answer = $null; pending = $false }

# ---------------- v4.3.8: CHECK FOR UPDATES WHEN TESSDESK OPENS / THE PC WAKES / THE WINDOW COMES BACK ----------------
# launch  : right away every time TessDesk opens (including the auto-start at boot), no matter when it last checked
# resume  : when the PC wakes from sleep (SystemEvents.PowerModeChanged Resume, plus a clock-gap check as a backup)
# focus / restore : when the window regains focus or is restored from the taskbar
# resume / focus / restore are throttled: at most one check every 5 minutes. The ~3 h periodic check stays.
# launch / resume: if the network isn't up yet (just booted / just woke), retry silently 5 times over about 2 minutes.
$UpdMinGapSec = 300
$UpdRetryDelays = @(10, 20, 30, 30, 30)
$script:UpdLastTry = 0; $script:UpdLaunched = $false; $script:UpdTriggers = @()
$script:UpdRetry = [ordered]@{ active = $false; reason = $null; i = 0 }
$script:UpdRetryTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UpdRetryTimer.Add_Tick({
    try {
        $script:UpdRetryTimer.Stop()
        if ($SelfTest -or -not $script:UpdRetry.active) { return }
        if ($null -ne $script:UpdJob -or $script:Upd.state -eq 'updating') { $script:UpdRetryTimer.Interval = [TimeSpan]::FromSeconds(5); $script:UpdRetryTimer.Start(); return }
        $script:UpdLastTry = Get-EpochNow
        if (-not (Test-UpdNetwork)) { Register-UpdCheckFailure; return }
        Start-UpdateCheck -Force
    } catch { Write-WidgetLog ('update retry: ' + $_.Exception.Message) }
})
function Test-UpdNetwork { try { return [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable() } catch { return $true } }
function Add-UpdTrigger { param($Rec) $script:UpdTriggers = @(@($script:UpdTriggers) + @([pscustomobject]$Rec) | Select-Object -Last 30) }
function Request-UpdateCheck {
    param([string]$Reason)
    $now = Get-EpochNow
    $rec = [ordered]@{ reason = $Reason; at = (Get-LocalNow).ToString('s'); action = $null }
    if ($Reason -ne 'launch' -and -not $script:UpdLaunched) { $rec.action = 'ignored (the launch check has not run yet)'; Add-UpdTrigger $rec; return $rec.action }
    if ($Reason -ne 'launch' -and ($now - [int64]$script:UpdLastTry) -lt $UpdMinGapSec) { $rec.action = 'skipped (last check ' + ($now - [int64]$script:UpdLastTry) + ' s ago, 5 min minimum)'; Add-UpdTrigger $rec; return $rec.action }
    if ($null -ne $script:UpdJob -or $script:Upd.state -in @('updating', 'installed')) { $rec.action = 'skipped (busy)'; Add-UpdTrigger $rec; return $rec.action }
    if ($Reason -eq 'launch') { $script:UpdLaunched = $true }
    $script:UpdLastTry = $now
    if ($Reason -in @('launch', 'resume')) { $script:UpdRetry.active = $true; $script:UpdRetry.reason = $Reason; $script:UpdRetry.i = 0; $script:UpdRetryTimer.Stop() }
    else { $script:UpdRetry.active = $false; $script:UpdRetryTimer.Stop() }
    if ($SelfTest) { $rec.action = 'would check now (self-test: no network)'; Add-UpdTrigger $rec; return $rec.action }
    if (-not (Test-UpdNetwork)) { $rec.action = 'no network yet'; Add-UpdTrigger $rec; Write-WidgetLog ('update check (' + $Reason + '): no network yet'); Register-UpdCheckFailure; return $rec.action }
    Start-UpdateCheck -Force
    $rec.action = 'checking'; Add-UpdTrigger $rec
    Write-WidgetLog ('update check (' + $Reason + ')')
    return $rec.action
}
function Register-UpdCheckSuccess { $script:UpdRetry.active = $false; $script:UpdRetry.i = 0; try { $script:UpdRetryTimer.Stop() } catch {} }
function Register-UpdCheckFailure {
    $r = $script:UpdRetry
    if (-not $r.active) { return }
    if ($r.i -ge $UpdRetryDelays.Count) {
        $r.active = $false
        Write-WidgetLog ('update check (' + $r.reason + '): still no answer after ' + $UpdRetryDelays.Count + ' silent retries; next try on focus / restore / wake or the 3 h check')
        if ($script:Upd.state -eq 'available' -and -not $SelfTest) { $window.Dispatcher.BeginInvoke([Action]{ try { Show-UpdatePrompt } catch {} }) | Out-Null }   # last known newer version (update-check.json)
        return
    }
    $d = [int]$UpdRetryDelays[$r.i]; $r.i++
    $script:UpdRetryTimer.Interval = [TimeSpan]::FromSeconds($d); $script:UpdRetryTimer.Start()
    Write-WidgetLog ('update check (' + $r.reason + '): no answer, silent retry ' + $r.i + '/' + $UpdRetryDelays.Count + ' in ' + $d + ' s')
}
function Test-UpdPromptAllowed { return -not ($script:UpdLaterFor -and [string]$script:UpdLaterFor -eq [string]$script:Upd.latest) }
function Set-UpdLater {
    $script:UpdLaterFor = [string]$script:Upd.latest
    Write-WidgetLog ('update v' + $script:Upd.latest + ': Later (not asked again for this version until TessDesk opens again; the UPDATE button stays)')
}
# wake from sleep: a tiny C# listener only counts Resume events (no PowerShell runs on the SystemEvents thread);
# a 15 s timer picks the count up on the window's thread. The clock-gap check catches a wake even if the listener can't start.
$script:PwWatch = [ordered]@{ listener = $false; seen = 0; lastTick = (Get-EpochNow); wakes = 0; error = $null }
function Start-UpdResumeWatch {
    try {
        if (-not ('TdPowerWatch' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Threading; using Microsoft.Win32;
public static class TdPowerWatch {
    static long _n; static int _on;
    public static long Resumes { get { return Interlocked.Read(ref _n); } }
    public static void Start() { if (Interlocked.Exchange(ref _on, 1) == 1) return; SystemEvents.PowerModeChanged += OnPm; }
    public static void Stop() { if (Interlocked.Exchange(ref _on, 0) == 0) return; try { SystemEvents.PowerModeChanged -= OnPm; } catch { } }
    static void OnPm(object s, PowerModeChangedEventArgs e) { if (e.Mode == PowerModes.Resume) Interlocked.Increment(ref _n); }
}
'@
        }
        [TdPowerWatch]::Start(); $script:PwWatch.listener = $true; $script:PwWatch.seen = [TdPowerWatch]::Resumes
    } catch { $script:PwWatch.error = $_.Exception.Message; Write-WidgetLog ('wake listener: ' + $_.Exception.Message + ' (clock-gap check still on)') }
    $script:PwTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PwTimer.Interval = [TimeSpan]::FromSeconds(15)
    $script:PwTimer.Add_Tick({ try { Test-UpdResume } catch {} })
    $script:PwTimer.Start()
}
function Test-UpdResume {
    $now = Get-EpochNow; $gap = $now - [int64]$script:PwWatch.lastTick; $script:PwWatch.lastTick = $now
    $n = $script:PwWatch.seen; if ($script:PwWatch.listener) { try { $n = [TdPowerWatch]::Resumes } catch {} }
    $woke = ($n -ne $script:PwWatch.seen) -or ($gap -gt 120)
    $script:PwWatch.seen = $n
    if (-not $woke) { return $false }
    $script:PwWatch.wakes++
    Write-WidgetLog ('PC woke up (' + $(if ($gap -gt 120) { 'clock gap ' + $gap + ' s' } else { 'power resume' }) + '): checking for updates')
    [void](Request-UpdateCheck 'resume')
    return $true
}
function Show-UpdatePrompt {
    param([switch]$NoWait)
    if (-not $script:Upd.latest -or $script:Upd.state -ne 'available' -or $null -ne $script:UpdJob) { return }
    if ($SelfTest -and -not $NoWait) { return }
    if (-not $NoWait -and -not (Test-UpdPromptAllowed)) { return }   # v4.3.8: Later = quiet for this version until the next launch
    if ($ui.ConfirmOverlay.Visibility -eq 'Visible' -or $ui.ShareOverlay.Visibility -eq 'Visible') { $script:UpdPrompt.pending = $true; return }
    $script:UpdPrompt.pending = $false; $script:UpdPrompt.shown = [string]$script:Upd.latest
    $msg = 'Update to v' + $script:Upd.latest + '?'
    $sub = 'TessDesk v' + $script:Upd.latest + ' is out (you have v' + $AppVersion + '). Update now downloads it, checks every file, backs up this copy and restarts TessDesk right here. Later asks again the next time TessDesk opens.'
    if ($NoWait) { [void](Show-ConfirmOverlay $msg $sub 'Update now' 'Later' -NoWait); return }
    $a = Show-ConfirmOverlay $msg $sub 'Update now' 'Later'
    $script:UpdPrompt.answer = $(if ($a) { 'update now' } else { 'later' })
    if ($a) { Write-WidgetLog ('update v' + $script:Upd.latest + ': Update now'); Invoke-UpdateApply }
    else { Set-UpdLater }
}

$script:State = Load-WidgetState
$script:LastSnapshot = $null
$script:TireFlags = @{}
Apply-Theme $true

# TESLA CONTROLS buttons
$ui.LockBtn.Add_Click({ try { Invoke-LockToggle } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.VentBtn.Add_Click({ try { Invoke-Vent } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.UpdateBtn.Add_MouseLeftButtonUp({ try { if ($script:Upd.state -in @('available', 'failed')) { if ($script:Upd.state -eq 'failed') { $script:Upd.state = 'available' }; Invoke-UpdateApply } } catch { $script:Upd.state = 'failed'; $script:Upd.note = $_.Exception.Message; Render-Update } })
$script:UpdTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UpdTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:UpdTimer.Add_Tick({
    try {
        $j = $script:UpdJob
        if ($null -eq $j) { $script:UpdTimer.Stop(); return }
        if ($j.async.IsCompleted) { Complete-UpdJob; if ($null -eq $script:UpdJob) { $script:UpdTimer.Stop() } }
        elseif (((Get-Date) - $j.started).TotalSeconds -gt 90) { try { $j.ps.Stop() } catch {}; $script:UpdJob = $null; $script:UpdTimer.Stop(); if ($j.kind -eq 'apply') { $script:Upd.state = 'failed' }; $script:Upd.note = 'update ' + $j.kind + ' timed out'; Render-Update; if ($j.kind -eq 'check') { try { Register-UpdCheckFailure } catch {} } }
    } catch { Write-WidgetLog ('update timer: ' + $_.Exception.Message) }
})
# daily check: 90 s after start, then every hour asks "has it been ~a day?" (not during -SelfTest)
$script:UpdDaily = New-Object System.Windows.Threading.DispatcherTimer
$script:UpdDaily.Interval = [TimeSpan]::FromSeconds(90)
$script:UpdDaily.Add_Tick({ try { $script:UpdDaily.Interval = [TimeSpan]::FromHours(1); if (-not $SelfTest) { Start-UpdateCheck; if ($null -eq $script:UpdJob) { Show-UpdatePrompt } } } catch {} })
$script:UpdDaily.Start()
try { Render-Update } catch {}
$ui.TrunkBtn.Add_Click({ try { Invoke-Trunk } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.SentryBtn.Add_Click({ try { Invoke-SentryToggle } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.HistMapBtn.Add_Click({ try { Open-Url433 (Get-HistoryMapUrl) } catch {} })
$ui.CloseWinBtn.Add_Click({ try { Invoke-CloseWindows } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.ClimBtn.Add_Click({ try { Invoke-ClimateToggle } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.TempDownBtn.Add_Click({ try { Step-Temp -1 } catch {} })
$ui.TempUpBtn.Add_Click({ try { Step-Temp 1 } catch {} })
$ui.ChgStartBtn.Add_Click({ try { Invoke-ChargeStart } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.ChgStopBtn.Add_Click({ try { Invoke-ChargeStop } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.HeatBtn.Add_Click({ try { Invoke-Heat } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.DefrostBtn.Add_Click({ try { Invoke-Defrost } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.CopBtn.Add_Click({ try { Invoke-CopCycle } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.WheelBtn.Add_Click({ try { Invoke-WheelToggle } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
foreach ($k in 'FL', 'FR', 'RL', 'RC', 'RR') { $b = $ui['Seat' + $k]; $b.CommandParameter = $k; $b.Add_Click({ param($s9, $e9) try { Step-Seat ([string]$s9.CommandParameter) } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } }) }
# Alexa toggle (saved in config.json announce.actions) + schedule / Connected apps window
$script:AlexaOn = $false; try { $a0 = Get-AnnCfg; if ($null -ne $a0 -and [bool]$a0.actions) { $script:AlexaOn = $true } } catch {}
Set-AlexaToggle $script:AlexaOn $false
$ui.AlexaToggle.Add_Click({ try { Set-AlexaToggle ([bool]$ui.AlexaToggle.IsChecked) (-not $SelfTest); if ([bool]$script:AlexaOn -and -not (Test-AnnReady)) { Set-CtlResult 'idle' 'Alexa is on, but Voice Monkey is not set up yet: tap the clock button next to it > Connected apps.' }; Write-WidgetStatus } catch {} })
$ui.AnnBtn.Add_Click({ if (-not $SelfTest) { try { Show-AnnounceWindow } catch { Write-WidgetLog ('announce window failed: ' + $_.Exception.Message); [void][System.Windows.MessageBox]::Show($window, ('Could not open settings: ' + $_.Exception.Message), 'TessDesk', 'OK', 'Warning') } } })

# v4.3 charge-limit slider: vertical, right of the battery. Drag the white thumb (it shows % + miles while dragging and at rest),
# or use the mouse wheel over it (1% per notch, sends 0.9 s after the last notch). Release -> "Set to X%?" Confirm / Cancel.
function Get-PctFromX { param([double]$X) $b = Get-LimitBounds; $p = [math]::Round(($X - $BBarX) / $BBarW * 100); return [int][math]::Max($b[0], [math]::Min($b[1], $p)) }
function Show-DragPct {
    param([int]$Pct)
    $script:DragPct = $Pct
    Set-ThumbAt $Pct
    Set-VThumb $Pct
    $mi = Get-MilesAt $Pct
    $ui.DragVal.Text = ('{0}%' -f $Pct) + $(if ($null -ne $mi) { ' / ' + (Format-Miles $mi) } else { '' })
    $ui.BarLimitLbl.Text = ('{0}%' -f $Pct); $ui.LimitMi.Text = Format-Miles $mi
    Set-Visible $ui.DragBox $true; Set-Visible $ui.BattTop $false
}
function End-Drag {
    param([bool]$Commit)
    $script:Dragging = $false
    try { $ui.VLim.ReleaseMouseCapture() } catch {}
    Set-Visible $ui.DragBox $false; Set-Visible $ui.BattTop $true
    $p = $script:DragPct; $script:DragPct = $null
    if ($Commit -and $null -ne $p) { $script:VPend = $p; Set-VThumb $p; [void](Request-ChargeLimit $p) } else { Render-View }
}
$ui.VLim.Add_MouseLeftButtonDown({ param($s, $e)
    try {
        $ui.DragCap.Text = 'SET LIMIT'
        if (-not (Test-CmdOn) -or $script:CtlBusy -or $ui.VThumb.Visibility -ne 'Visible') { return }
        $script:WheelTimer.Stop(); $script:WheelPct = $null
        $script:Dragging = $true
        [void]$ui.VLim.CaptureMouse()
        Show-DragPct (Get-PctFromY ($e.GetPosition($ui.VLim).Y))
        $e.Handled = $true
    } catch {}
})
$ui.VLim.Add_MouseMove({ param($s, $e) if ($script:Dragging -and $null -eq $script:WheelPct) { try { Show-DragPct (Get-PctFromY ($e.GetPosition($ui.VLim).Y)) } catch {} } })
$ui.VLim.Add_MouseLeftButtonUp({ param($s, $e) if ($script:Dragging -and $null -eq $script:WheelPct) { End-Drag $true } })
$ui.VLim.Add_LostMouseCapture({ if ($script:Dragging -and $null -eq $script:WheelPct) { End-Drag $false } })
$ui.VLim.Add_MouseWheel({ param($s, $e) try { Step-VLimit $(if ($e.Delta -gt 0) { 1 } else { -1 }); $e.Handled = $true } catch {} })

# v4.3 buttons: Announce on Alexa (full rundown), Setup, peak banner, confirm box
$ui.AnnNowBtn.Add_Click({ try { [void](Invoke-AnnounceNow) } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message); Show-TdToast ('✕ Announcement failed: ' + $_.Exception.Message) $false } })
$ui.AnnSetupBtn.Add_Click({ if (-not $SelfTest) { try { Show-AnnSetupWindow } catch { Write-WidgetLog ('announce setup failed: ' + $_.Exception.Message); [void][System.Windows.MessageBox]::Show($window, ('Could not open Announce Setup: ' + $_.Exception.Message), 'TessDesk', 'OK', 'Warning') } } })
$ui.PeakStopBtn.Add_Click({ try { Invoke-ChargeStop } catch { Set-CtlResult 'err' ('✕ ' + $_.Exception.Message) } })
$ui.PeakClose.Add_MouseLeftButtonUp({ try { $pk = Get-RateStatus; $script:PeakHiddenKey = $pk.key; Render-Peak; Confirm-Fit } catch {} })   # x = fold to the pill for this session
$ui.ConfirmYes.Add_Click({ Close-ConfirmOverlay $true })
$ui.ShareBtn.Add_MouseLeftButtonUp({ try { Open-ShareOverlay } catch { Write-WidgetLog ('share: ' + $_.Exception.Message) } })
$ui.ShMessenger.Add_Click({ try { Invoke-Share 'messenger' } catch { Show-TdToast ('Could not open Messenger: ' + $_.Exception.Message) $false } })
$ui.ShText.Add_Click({ try { Invoke-Share 'text' } catch { Show-TdToast ('Could not open a texting app: ' + $_.Exception.Message + ' (the message is copied)') $false } })
$ui.ShEmail.Add_Click({ try { Invoke-Share 'email' } catch { Show-TdToast ('Could not open your email app: ' + $_.Exception.Message) $false } })
$ui.ShCopy.Add_Click({ try { Invoke-Share 'copy' } catch {} })
$ui.ShPhone.Add_Click({ try { Invoke-Share 'phone' } catch {} })
$ui.ShClose.Add_Click({ Close-ShareOverlay })
$ui.ConfirmNo.Add_Click({ Close-ConfirmOverlay $false })
$window.Add_PreviewKeyDown({ param($s, $e) if ($ui.ConfirmOverlay.Visibility -eq 'Visible') { if ($e.Key -eq 'Escape') { Close-ConfirmOverlay $false; $e.Handled = $true } elseif ($e.Key -eq 'Return') { Close-ConfirmOverlay $true; $e.Handled = $true } } })

$ui.AmpsDark.Add_MouseLeftButtonDown({ param($s, $e)
    try {
        if (-not (Test-CmdOn) -or $script:CtlBusy -or $ui.AmpsThumb.Visibility -ne 'Visible') { return }
        $script:DraggingAmps = $true; $script:Dragging = $true
        [void]$ui.AmpsDark.CaptureMouse()
        Show-DragAmps (Get-AmpsFromX ($e.GetPosition($ui.AmpsDark).X))
        $e.Handled = $true
    } catch {}
})
$ui.AmpsDark.Add_MouseMove({ param($s, $e) if ($script:DraggingAmps) { try { Show-DragAmps (Get-AmpsFromX ($e.GetPosition($ui.AmpsDark).X)) } catch {} } })
$ui.AmpsDark.Add_MouseLeftButtonUp({ param($s, $e) if ($script:DraggingAmps) { End-AmpsDrag $true } })
$ui.AmpsDark.Add_LostMouseCapture({ if ($script:DraggingAmps) { End-AmpsDrag $false } })
$window.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { if ($script:DraggingAmps) { End-AmpsDrag $false } elseif ($script:Dragging) { End-Drag $false } } })

# Spinner + command completion + follow-up refresh (60 ms ticks only while a command is running)
$script:RefreshAt = $null
$script:CtlTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:CtlTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$script:CtlTimer.Add_Tick({
    try {
        $ui.CtlSpinRot.Angle = ($ui.CtlSpinRot.Angle + 20) % 360
        if ($null -ne $script:CtlJob -and $script:CtlJob.async.IsCompleted) { Complete-TessieCommand }
        if (-not $script:CtlBusy) {
            if ($null -ne $script:RefreshAt -and (Get-Date) -ge $script:RefreshAt) { $script:RefreshAt = $null; Update-Ui }
            if ($null -eq $script:RefreshAt) { $script:CtlTimer.Stop() }
        }
    } catch { Write-WidgetLog ('control timer: ' + $_.Exception.Message) }
})
$script:TempTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TempTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$script:TempTimer.Add_Tick({ try { Send-PendingTemp } catch { Write-WidgetLog ('temp send: ' + $_.Exception.Message) } })
$script:SeatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SeatTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$script:SeatTimer.Add_Tick({ try { Send-PendingSeat } catch { Write-WidgetLog ('seat send: ' + $_.Exception.Message) } })
$script:AnnTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:AnnTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:AnnTimer.Add_Tick({ try { Complete-AnnJobs } catch {} })

# ---------------- v4.3.9: CAMERAS panel ----------------
# Tesla / Tessie give apps NO live camera feed. This panel loops still frames pulled from saved Sentry / Dashcam clips
# (the TeslaCam folder from the car's USB drive: a Wi-Fi USB drive such as TeslaUSB, or the folder copied to this PC).
# Frames are read on this PC with Windows' own video player (MediaPlayer), kept in memory as small JPEGs, never uploaded.
# Capture saves the frame as a PNG and emails it (your own email account from Setup > Reminders if it is set up,
# otherwise your email app opens to the address with the picture copied). TessDesk never stores or embeds a password.
$CamKeys  = @('front', 'back', 'left_repeater', 'right_repeater', 'left_pillar', 'right_pillar')
$CamNames = @{ front = 'Front'; back = 'Rear'; left_repeater = 'Left repeater'; right_repeater = 'Right repeater'; left_pillar = 'Left pillar'; right_pillar = 'Right pillar' }
$CamShort = @{ front = 'Front'; back = 'Rear'; left_repeater = 'Left rep.'; right_repeater = 'Right rep.'; left_pillar = 'L pillar'; right_pillar = 'R pillar' }
$CamFramesN = 16
$CamMaxW = 1280
$CamMailDefault = 'vanwidick@gmail.com'
function Get-CamCfg {
    $d = [ordered]@{ enabled = $false; source = 'usb'; usbPath = ''; folderPath = ''; fps = 4; which = 'latest'; defaultCam = 'grid'; fsLayout = 'two'; fsFront = 'left'; mailTo = $CamMailDefault; captureDir = ''; clipDir = '' }
    try { $c0 = $script:Cfg.camera; if ($null -ne $c0) { foreach ($p in $c0.PSObject.Properties) { if ($d.Contains($p.Name)) { $d[$p.Name] = $p.Value } } } } catch {}
    $d.enabled = [bool]$d.enabled
    if (@('usb', 'folder') -notcontains [string]$d.source) { $d.source = 'usb' }
    if (@(2, 4, 8) -notcontains [int]$d.fps) { $d.fps = 4 }; $d.fps = [int]$d.fps
    if (@('latest', 'all') -notcontains [string]$d.which) { $d.which = 'latest' }
    if (@('grid') + $CamKeys -notcontains [string]$d.defaultCam) { $d.defaultCam = 'grid' }
    if (@('two', 'one') -notcontains [string]$d.fsLayout) { $d.fsLayout = 'two' }
    if (@('left', 'right') -notcontains [string]$d.fsFront) { $d.fsFront = 'left' }
    if (-not [string]$d.mailTo) { $d.mailTo = $CamMailDefault }
    return $d
}
$script:CamCfg = Get-CamCfg
function Save-CamCfg { try { Save-ConfigProp 'camera' ([pscustomobject]$script:CamCfg) } catch { Write-WidgetLog ('camera settings save failed: ' + $_.Exception.Message) } }
$script:Cam = [ordered]@{ status = 'off'; msg = ''; events = @(); ev = $null; evKey = $null; frames = @{}; times = @{}; errs = @{}; cams = @(); n = 0; idx = 0; playing = $true; view = [string]$script:CamCfg.defaultCam; scanNote = ''; lastScan = $null; lastLoad = $null }
$script:CamViews = New-Object System.Collections.ArrayList    # every Image that shows a camera (widget + full screen)
$script:CamBars = New-Object System.Collections.ArrayList     # sliders / counts / play buttons (widget + full screen)
$script:CamJob = $null; $script:CamScan = $null; $script:CamSave = $null; $script:CamMail = $null
$script:CamLog = @(); $script:CamStopAt = 0; $script:CamBusySeen = $null; $script:CamFs = $null; $script:CamSync = $false; $script:CamCaptures = @(); $script:CamMsgText = $null; $script:CamOptList = $null
function Get-CamBrush { param([string]$c) return (Get-Brush $c) }
function Get-CamRoot { if ([string]$script:CamCfg.source -eq 'folder') { return [string]$script:CamCfg.folderPath } else { return [string]$script:CamCfg.usbPath } }
function Get-CamSrcLabel { if ([string]$script:CamCfg.source -eq 'folder') { return 'PC folder' } else { return 'USB drive' } }
function Test-CamBusy { return ($null -ne $script:CamJob -or $null -ne $script:CamScan -or $null -ne $script:CamSave) }
function Add-CamLog { param([string]$M) $script:CamLog = @(@($script:CamLog) + @(((Get-LocalNow).ToString('HH:mm:ss') + ' ' + $M)) | Select-Object -Last 60); Write-WidgetLog ('camera: ' + $M) }

# ---- folder scan (background, so a sleeping Wi-Fi drive never freezes the widget) ----
$script:CamScanBlock = {
    param([string]$Root, [int]$Max)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $res = [ordered]@{ ok = $false; err = $null; camRoot = $null; events = @() }
    try {
        if (-not $Root) { throw 'nofolder' }
        if (-not (Test-Path -LiteralPath $Root)) { throw ('Folder not found: ' + $Root) }
        $tc = $Root; $sub = Join-Path $Root 'TeslaCam'; if (Test-Path -LiteralPath $sub) { $tc = $sub }
        $res.camRoot = $tc
        $rx = '^(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})-(front|back|left_repeater|right_repeater|left_pillar|right_pillar)\.mp4$'
        $mk = {
            param($Kind, $Dir, $Files, $Name)
            $clips = [ordered]@{}; $all = @(); $bytes = [int64]0
            foreach ($f in $Files) {
                $all += $f.FullName; $bytes += $f.Length
                $m = [regex]::Match($f.Name, $rx); if (-not $m.Success) { continue }
                $st = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd_HH-mm-ss', $inv)
                $k = $m.Groups[2].Value; if (-not $clips.Contains($k)) { $clips[$k] = @() }
                $clips[$k] += [pscustomobject]@{ start = $st.ToString('s'); path = $f.FullName; bytes = $f.Length }
            }
            if ($clips.Count -eq 0) { return $null }
            $t = $null; $trig = $false; $reason = $null; $city = $null
            $ej = Join-Path $Dir 'event.json'
            if ($Kind -ne 'RecentClips' -and (Test-Path -LiteralPath $ej)) { try { $j = Get-Content -LiteralPath $ej -Raw | ConvertFrom-Json; if ($j.timestamp) { $t = ([datetime]::Parse([string]$j.timestamp, $inv)).ToString('s'); $trig = $true }; $reason = [string]$j.reason; $city = [string]$j.city } catch {} }
            if (-not $t -and $Name -match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$') { $t = ([datetime]::ParseExact($Name, 'yyyy-MM-dd_HH-mm-ss', $inv)).ToString('s') }
            if (-not $t) { $t = (@($clips.Values | ForEach-Object { $_ } | Sort-Object start) | Select-Object -Last 1).start }
            return [pscustomobject]@{ kind = $Kind; name = $Name; dir = $Dir; time = $t; trigger = $trig; reason = $reason; city = $city; clips = [pscustomobject]$clips; files = $all; bytes = $bytes }
        }
        $evs = @()
        foreach ($kind in @('SentryClips', 'SavedClips')) {
            $kd = Join-Path $tc $kind; if (-not (Test-Path -LiteralPath $kd)) { continue }
            foreach ($d in @(Get-ChildItem -LiteralPath $kd -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First $Max)) {
                $e = & $mk $kind $d.FullName @(Get-ChildItem -LiteralPath $d.FullName -File -ErrorAction SilentlyContinue) $d.Name; if ($null -ne $e) { $evs += $e }
            }
        }
        $rd = Join-Path $tc 'RecentClips'
        if (Test-Path -LiteralPath $rd) {
            $groups = @(Get-ChildItem -LiteralPath $rd -File -Filter '*.mp4' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $rx } | Group-Object { $_.Name.Substring(0, 19) } | Sort-Object Name -Descending | Select-Object -First ([math]::Max(1, [int]($Max / 2))))
            foreach ($g in $groups) { $e = & $mk 'RecentClips' $rd @($g.Group) $g.Name; if ($null -ne $e) { $evs += $e } }
        }
        if ($evs.Count -eq 0) {   # a single event folder picked directly
            $here = @(Get-ChildItem -LiteralPath $tc -File -ErrorAction SilentlyContinue)
            if (@($here | Where-Object { $_.Name -match $rx }).Count -gt 0) { $e = & $mk 'Folder' $tc $here (Split-Path -Leaf $tc); if ($null -ne $e) { $evs += $e } }
        }
        $res.events = @($evs | Sort-Object time -Descending)
        $res.ok = $true
    } catch { $res.err = $_.Exception.Message }
    return [pscustomobject]$res
}
function Start-CamScan {
    param([switch]$Load)
    if ($null -ne $script:CamScan) { return }
    $root = Get-CamRoot
    if (-not $root) { Set-CamStatus 'nofolder' ''; return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:CamScanBlock).AddArgument($root).AddArgument(25)
    $script:CamScan = [pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke(); started = (Get-Date); load = [bool]$Load; root = $root }
    if ($script:Cam.n -eq 0) { Set-CamStatus 'scanning' ('Looking for clips in ' + $root) } else { Update-CamBusy }
    $script:CamTick.Start()
}
function Complete-CamScan {
    $s = $script:CamScan; $r = $null; $err = $null
    try { $r = @($s.ps.EndInvoke($s.async))[0] } catch { $err = $_.Exception.Message }
    try { $s.ps.Dispose() } catch {}
    $script:CamScan = $null; $script:Cam.lastScan = Get-LocalNow
    if ($err -or $null -eq $r -or -not $r.ok) {
        $m = $(if ($err) { $err } elseif ($r) { [string]$r.err } else { 'scan failed' })
        if ($m -eq 'nofolder') { Set-CamStatus 'nofolder' ''; return }
        Add-CamLog ('scan: ' + $m)
        if ($script:Cam.n -eq 0) { Set-CamStatus 'error' ($m + ' (if it is a Wi-Fi drive, it may be asleep or away from home)') } else { $script:Cam.scanNote = $m; Update-CamBusy }
        return
    }
    $script:Cam.events = @($r.events)
    Add-CamLog ('scan: ' + @($r.events).Count + ' event(s) in ' + $r.camRoot)
    if (@($r.events).Count -eq 0) { if ($script:Cam.n -eq 0) { Set-CamStatus 'noclips' ('No Sentry / Dashcam clips found in ' + $s.root) }; return }
    $newest = @($r.events)[0]
    $key = [string]$newest.dir + '|' + [string]$newest.name
    if ($s.load -or ([string]$script:CamCfg.which -eq 'latest' -and $key -ne $script:Cam.evKey -and $null -eq $script:CamJob)) { Start-CamLoad $newest }
    else { Update-CamBusy; Update-CamOptEvents }
}

# ---- frame extraction: Windows MediaPlayer, seek + render each frame (UI thread, small steps, Stop any time) ----
function Get-CamClipFor {
    param($Ev, [string]$Cam)
    $list = @($Ev.clips.$Cam); if ($list.Count -eq 0 -or $null -eq $list[0]) { return $null }
    $t = [datetime]::Parse([string]$Ev.time, $Inv)
    $pick = $null
    if ($Ev.trigger) { $pick = @($list | Where-Object { [datetime]::Parse([string]$_.start, $Inv) -le $t } | Sort-Object start | Select-Object -Last 1)[0] }
    if ($null -eq $pick) { $pick = @($list | Sort-Object start | Select-Object -Last 1)[0] }
    $st = [datetime]::Parse([string]$pick.start, $Inv)
    $off = $(if ($Ev.trigger) { ($t - $st).TotalSeconds } else { $null })
    return [pscustomobject]@{ path = [string]$pick.path; start = $st; offset = $off }
}
function Get-CamPositions {
    param([double]$Dur, $Offset, [int]$N)
    # around a Sentry trigger: about 6 s before to 2 s after; otherwise spread over the whole clip
    $lo = 0.3; $hi = [math]::Max(0.4, $Dur - 0.3)
    if ($null -ne $Offset) { $a = [double]$Offset - 6; $b = [double]$Offset + 2; if ($b -gt $hi) { $a -= ($b - $hi); $b = $hi }; if ($a -lt $lo) { $b = [math]::Min($hi, $b + ($lo - $a)); $a = $lo } }
    else { $a = $lo; $b = $hi }
    $out = @(); for ($i = 0; $i -lt $N; $i++) { $out += [math]::Round($a + ($b - $a) * $i / [math]::Max(1, $N - 1), 2) }
    return $out
}
function Start-CamLoad {
    param($Ev)
    Stop-CamJob 'replaced'
    $items = @()
    foreach ($k in $CamKeys) {
        $cl = Get-CamClipFor $Ev $k; if ($null -eq $cl) { continue }
        $p = New-Object System.Windows.Media.MediaPlayer
        $p.ScrubbingEnabled = $true; $p.IsMuted = $true; $p.Volume = 0
        $it = [ordered]@{ cam = $k; path = $cl.path; start = $cl.start; offset = $cl.offset; p = $p; state = 'open'; k = 0; wait = 0; tries = 0; t0 = (Get-Date); w = 0; h = 0; pos = @(); frames = (New-Object System.Collections.ArrayList); err = $null }
        $p.Add_MediaFailed({ param($s9, $e9) try { foreach ($x in @($script:CamJob.items)) { if ([object]::ReferenceEquals($x.p, $s9)) { $x.err = $(if ($e9.ErrorException) { $e9.ErrorException.Message } else { 'could not open' }) } } } catch {} })
        try { $p.Open([Uri]::new($cl.path)) } catch { $it.err = $_.Exception.Message }
        $items += $it
    }
    if ($items.Count -eq 0) { Set-CamStatus 'noclips' 'This event has no camera clips'; return }
    $script:CamJob = [ordered]@{ ev = $Ev; items = $items; total = $items.Count * $CamFramesN; done = 0; cancelled = $false; started = (Get-Date) }
    Add-CamLog ('loading ' + $Ev.kind + ' ' + $Ev.name + ' (' + $items.Count + ' cameras x ' + $CamFramesN + ' frames)')
    if ($script:Cam.n -eq 0) { Set-CamStatus 'loading' '' } else { Update-CamBusy }
    $script:CamTick.Start()
}
function Close-CamPlayer { param($It) try { $It.p.Stop() } catch {}; try { $It.p.Close() } catch {}; $It.p = $null }
function Get-CamGrab {
    param($It, [bool]$Accept)
    $w = [int]$It.w; $h = [int]$It.h
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen(); $dc.DrawVideo($It.p, [System.Windows.Rect]::new(0, 0, $w, $h)); $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    if (-not $Accept) {
        $stride = $w * 4; $px = New-Object byte[] $stride
        $rtb.CopyPixels([System.Windows.Int32Rect]::new(0, [int]($h / 2), $w, 1), $px, $stride, 0)
        $sum = 0; for ($i = 0; $i -lt $px.Length; $i += 32) { $sum += [int]$px[$i] + [int]$px[$i + 1] + [int]$px[$i + 2] }
        if ($sum -eq 0) { return $null }   # not decoded yet: wait a little longer
    }
    $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder; $enc.QualityLevel = 85
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = New-Object System.IO.MemoryStream; $enc.Save($ms); $b = $ms.ToArray(); $ms.Dispose()
    return , $b
}
function Step-CamJob {
    $j = $script:CamJob; if ($null -eq $j) { return }
    foreach ($it in $j.items) {
        if ($it.state -eq 'done' -or $it.state -eq 'failed') { continue }
        if ($it.state -eq 'open') {
            if ($it.err) { $it.state = 'failed'; $j.done += $CamFramesN; Close-CamPlayer $it; Add-CamLog ($it.cam + ': ' + $it.err); continue }
            $p = $it.p
            if ($p.NaturalDuration.HasTimeSpan -and $p.NaturalVideoWidth -gt 0) {
                $dur = $p.NaturalDuration.TimeSpan.TotalSeconds
                $w = [double]$p.NaturalVideoWidth; $h = [double]$p.NaturalVideoHeight
                if ($w -gt $CamMaxW) { $h = [math]::Round($h * $CamMaxW / $w); $w = $CamMaxW }
                $it.w = [int]$w; $it.h = [int]$h
                $it.pos = @(Get-CamPositions $dur $it.offset $CamFramesN)
                try { $p.Play(); $p.Pause() } catch {}
                $it.state = 'seek'
            } elseif (((Get-Date) - $it.t0).TotalSeconds -gt 15) { $it.err = 'timed out opening the clip (Windows may need the HEVC Video Extension for newer cars)'; $it.state = 'failed'; $j.done += $CamFramesN; Close-CamPlayer $it; Add-CamLog ($it.cam + ': ' + $it.err) }
            continue
        }
        if ($it.state -eq 'seek') { $it.p.Position = [TimeSpan]::FromSeconds([double]$it.pos[$it.k]); $it.wait = 0; $it.state = 'wait'; continue }
        if ($it.state -eq 'wait') {
            $it.wait++
            if ($it.wait -lt 4) { continue }
            $b = $null; try { $b = Get-CamGrab $it ($it.tries -ge 3) } catch { $it.err = $_.Exception.Message }
            if ($null -eq $b -and -not $it.err) { $it.tries++; $it.wait = 0; continue }
            if ($null -ne $b) { [void]$it.frames.Add($b) }
            $it.k++; $it.tries = 0; $j.done++
            if ($it.err -or $it.k -ge $it.pos.Count) { $it.state = 'done'; Close-CamPlayer $it } else { $it.state = 'seek' }
        }
    }
    Update-CamBusy
    if ($SelfTest -and $script:CamStopAt -gt 0 -and $j.done -ge $script:CamStopAt) {   # self-test: picture mid-load, then press Stop
        $script:CamStopAt = 0; try { $window.UpdateLayout(); & $script:Shot439 'camera-loading' } catch {}
        Stop-CamJob; return
    }
    if (@($j.items | Where-Object { $_.state -ne 'done' -and $_.state -ne 'failed' }).Count -eq 0) { Complete-CamJob $false }
}
function Complete-CamJob {
    param([bool]$Stopped)
    $j = $script:CamJob; if ($null -eq $j) { return }
    $script:CamJob = $null
    foreach ($it in $j.items) { if ($null -ne $it.p) { Close-CamPlayer $it } }
    $ok = @($j.items | Where-Object { $_.frames.Count -gt 0 })
    if ($ok.Count -eq 0) {
        $e = @($j.items | Where-Object { $_.err } | ForEach-Object { $_.err } | Select-Object -First 1)[0]
        if ($Stopped) { if ($script:Cam.n -eq 0) { Set-CamStatus 'stopped' 'Stopped before any frame was loaded' } else { Update-CamBusy } }
        else { Set-CamStatus 'error' $(if ($e) { 'Could not read the clip: ' + $e } else { 'Could not read the clip' }) }
        return
    }
    $n = $(if ($Stopped) { [int](@($ok | ForEach-Object { $_.frames.Count } | Measure-Object -Minimum).Minimum) } else { [int](@($ok | ForEach-Object { $_.frames.Count } | Measure-Object -Maximum).Maximum) })
    $fr = @{}; $tm = @{}; $er = @{}
    foreach ($it in $j.items) {
        if ($it.frames.Count -gt 0) { $fr[$it.cam] = @($it.frames | Select-Object -First $n); $st0 = $it.start; $tm[$it.cam] = @(@($it.pos | Select-Object -First $n) | ForEach-Object { $st0.AddSeconds([double]$_) }) }
        else { $er[$it.cam] = $(if ($it.err) { [string]$it.err } else { 'no frames' }) }
    }
    $C = $script:Cam
    $C.frames = $fr; $C.times = $tm; $C.errs = $er
    $C.cams = @($CamKeys | Where-Object { $fr.ContainsKey($_) -or $er.ContainsKey($_) })
    $C.ev = $j.ev; $C.evKey = [string]$j.ev.dir + '|' + [string]$j.ev.name; $C.n = $n; $C.idx = 0
    if ($C.view -ne 'grid' -and -not $fr.ContainsKey($C.view)) { $C.view = 'grid' }
    $C.status = 'ready'; $C.msg = $(if ($Stopped) { 'Stopped: ' + $n + ' of ' + $CamFramesN + ' frames per camera' } else { '' })
    $secs = [math]::Round(((Get-Date) - $j.started).TotalSeconds, 1)
    Add-CamLog ('loaded ' + $j.ev.kind + ' ' + $j.ev.name + ': ' + $fr.Count + ' camera(s) x ' + $n + ' frames in ' + $secs + ' s' + $(if ($Stopped) { ' (stopped)' } else { '' }) + $(if ($er.Count) { '; failed: ' + (($er.Keys | ForEach-Object { $_ + ' (' + $er[$_] + ')' }) -join ', ') } else { '' }))
    $C.lastLoad = [ordered]@{ event = [string]$j.ev.kind + '/' + [string]$j.ev.name; cameras = $fr.Count; frames = $n; seconds = $secs; stopped = $Stopped; failed = $er; doneAtStop = $j.done; total = $j.total }
    Render-Cam
    Start-CamPlay
    Update-CamOptEvents
}
function Stop-CamJob {
    param([string]$Why = 'stop')
    if ($null -eq $script:CamJob) { return }
    $script:CamJob.cancelled = $true
    if ($Why -eq 'replaced') { foreach ($it in $script:CamJob.items) { if ($null -ne $it.p) { Close-CamPlayer $it } }; $script:CamJob = $null; return }
    Add-CamLog ('stopped loading at ' + $script:CamJob.done + ' / ' + $script:CamJob.total + ' frames')
    Complete-CamJob $true
}

# ---- playback ----
$script:CamPlayTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:CamPlayTimer.Add_Tick({ try { Step-CamPlay } catch { Write-WidgetLog ('camera play: ' + $_.Exception.Message) } })
function Start-CamPlay {
    $script:CamPlayTimer.Stop()
    $script:CamPlayTimer.Interval = [TimeSpan]::FromMilliseconds([int](1000 / [math]::Max(1, [int]$script:CamCfg.fps)))
    Show-CamFrame
    if ($script:Cam.playing -and $script:Cam.n -gt 1) { $script:CamPlayTimer.Start() }
}
function Step-CamPlay {
    $C = $script:Cam
    if (-not $C.playing -or $C.n -lt 2) { $script:CamPlayTimer.Stop(); return }
    $fsOn = ($null -ne $script:CamFs)
    if (-not $fsOn -and (-not $ui.CamCard.IsVisible -or $window.WindowState -eq [System.Windows.WindowState]::Minimized)) { return }   # nothing on screen: no work
    $C.idx = ($C.idx + 1) % $C.n
    Show-CamFrame
}
function Set-CamPlaying { param([bool]$On) $script:Cam.playing = $On; Start-CamPlay; Update-CamBars }
function ConvertTo-CamImage {
    param([byte[]]$Bytes, [int]$W)
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.StreamSource = New-Object System.IO.MemoryStream (, $Bytes)
    if ($W -gt 0) { $bi.DecodePixelWidth = $W }
    $bi.EndInit(); $bi.Freeze()
    return $bi
}
function Show-CamFrame {
    $C = $script:Cam
    foreach ($v in @($script:CamViews)) {
        $f = $C.frames[$v.cam]
        if ($null -eq $f -or @($f).Count -eq 0) { continue }
        $i = [math]::Min([int]$C.idx, @($f).Count - 1)
        try { $v.img.Source = ConvertTo-CamImage $f[$i] $v.w } catch {}
        if ($null -ne $v.ts) { try { $v.ts.Text = ([datetime]$C.times[$v.cam][$i]).ToString('yyyy-MM-dd HH:mm:ss', $Inv) } catch {} }
    }
    Update-CamBars
}
function Update-CamBars {
    $C = $script:Cam
    $script:CamSync = $true
    try {
        foreach ($b in @($script:CamBars)) {
            if ($b.kind -eq 'slider') { $b.el.Maximum = [math]::Max(0, $C.n - 1); $b.el.Value = $C.idx; $b.el.IsEnabled = ($C.n -gt 1) }
            elseif ($b.kind -eq 'count') { $b.el.Text = $(if ($C.n -gt 0) { [string]($C.idx + 1) + ' / ' + $C.n + ' · ' + $script:CamCfg.fps + ' fps' } else { '' }) }
            elseif ($b.kind -eq 'play') { $b.el.Text = $(if ($C.playing) { [string][char]0xE769 } else { [string][char]0xE768 }) }
            elseif ($b.kind -eq 'fps') { $on = ([int]$b.el.Tag -eq [int]$script:CamCfg.fps); $b.el.BorderBrush = Get-CamBrush $(if ($on) { '#FF49DF93' } else { '#FF333333' }); $b.el.Foreground = Get-CamBrush $(if ($on) { '#FF49DF93' } else { '#FFE6E6E6' }) }
        }
    } finally { $script:CamSync = $false }
}
function Register-CamBar { param([string]$Kind, $El, [string]$Owner) [void]$script:CamBars.Add([pscustomobject]@{ kind = $Kind; el = $El; owner = $Owner }) }
function Clear-CamOwner {
    param([string]$Owner)
    foreach ($v in @($script:CamViews | Where-Object { $_.owner -eq $Owner })) { $script:CamViews.Remove($v) }
    foreach ($b in @($script:CamBars | Where-Object { $_.owner -eq $Owner })) { $script:CamBars.Remove($b) }
}
function On-CamSlider { param($S) if ($script:CamSync) { return }; $script:Cam.idx = [int][math]::Round($S.Value); if ($script:Cam.playing) { $script:Cam.playing = $false; $script:CamPlayTimer.Stop() }; Show-CamFrame }

# ---- tiles ----
function New-CamText {
    param([string]$T, [double]$Size, [string]$Color = '#FFFFFFFF', [string]$Weight = 'Bold', [string]$Font = $null)
    $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = $T; $tb.FontSize = $Size; $tb.Foreground = Get-CamBrush $Color; $tb.FontWeight = $Weight
    if ($Font) { $tb.FontFamily = [System.Windows.Media.FontFamily]::new($Font) }
    return $tb
}
function New-CamButton {
    param($Content, [double]$Size = 10.5, [string]$Tip = $null, [string]$Border = '#FF333333')
    $b = New-Object System.Windows.Controls.Button; $b.Style = $window.FindResource('CamBtn'); $b.FontSize = $Size; $b.BorderBrush = Get-CamBrush $Border
    $b.Content = $Content
    if ($Tip) { $b.ToolTip = $Tip }
    return $b
}
function New-CamIconLabel {
    param([string]$Glyph, [string]$Text, [double]$Size)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $g = New-CamText $Glyph ($Size - 0.5) '#FFE6E6E6' 'Normal' 'Segoe MDL2 Assets'; $g.VerticalAlignment = 'Center'; [void]$sp.Children.Add($g)
    if ($Text) { $g.Margin = '0,0,4,0'; $t = New-CamText $Text $Size '#FFE6E6E6' 'SemiBold'; $t.VerticalAlignment = 'Center'; [void]$sp.Children.Add($t) }
    return $sp
}
function New-CamTile {
    param([string]$Cam, [int]$DecodeW, [double]$Scale = 1.0, [string]$Owner = 'widget', [bool]$CapText = $true, [bool]$ClickToOpen = $false)
    $C = $script:Cam
    $bd = New-Object System.Windows.Controls.Border; $bd.Background = Get-CamBrush '#FF0E0E0E'; $bd.CornerRadius = [System.Windows.CornerRadius]::new(5); $bd.Margin = '1.5'; $bd.ClipToBounds = $true
    $g = New-Object System.Windows.Controls.Grid; $bd.Child = $g
    if ($C.frames.ContainsKey($Cam)) {
        $img = New-Object System.Windows.Controls.Image; $img.Stretch = 'Uniform'; [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality'); [void]$g.Children.Add($img)
        if ($ClickToOpen) { $img.Cursor = [System.Windows.Input.Cursors]::Hand; $img.Tag = $Cam; $img.ToolTip = 'Show only ' + $CamNames[$Cam]; $img.Add_MouseLeftButtonUp({ param($s9, $e9) try { Set-CamView ([string]$s9.Tag) } catch {} }) }
        $tsb = New-Object System.Windows.Controls.Border; $tsb.Background = Get-CamBrush '#B0000000'; $tsb.CornerRadius = [System.Windows.CornerRadius]::new(3); $tsb.Padding = '4,1,4,1'
        $tsb.HorizontalAlignment = 'Left'; $tsb.VerticalAlignment = 'Bottom'; $tsb.Margin = [System.Windows.Thickness]::new(4 * $Scale)
        $ts = New-CamText '' (8 * $Scale) '#FFFFFFFF' 'Bold' 'Consolas'; $tsb.Child = $ts; [void]$g.Children.Add($tsb)
        $cap = New-CamButton (New-CamIconLabel ([string][char]0xE722) $(if ($CapText) { 'Capture' } else { $null }) (8.5 * $Scale)) (8.5 * $Scale) ('Capture this ' + $CamNames[$Cam] + ' frame and email it to ' + $script:CamCfg.mailTo) '#FF555555'
        $cap.Background = Get-CamBrush '#D0111111'; $cap.Padding = [System.Windows.Thickness]::new(5 * $Scale, 1, 5 * $Scale, 1); $cap.HorizontalAlignment = 'Right'; $cap.VerticalAlignment = 'Bottom'; $cap.Margin = [System.Windows.Thickness]::new(3 * $Scale)
        $cap.Tag = $Cam; $cap.Add_Click({ param($s9, $e9) try { [void](Invoke-CamCapture ([string]$s9.Tag)) } catch { Show-CamToast ('Capture failed: ' + $_.Exception.Message) $false } })
        [void]$g.Children.Add($cap)
        [void]$script:CamViews.Add([pscustomobject]@{ cam = $Cam; img = $img; ts = $ts; w = $DecodeW; owner = $Owner; cap = $cap })
    } else {
        $t = New-CamText ($CamNames[$Cam] + ': could not read this clip' + $(if ($C.errs[$Cam]) { ' (' + $C.errs[$Cam] + ')' } else { '' })) (9 * $Scale) '#FF8A8A8A' 'SemiBold'
        $t.TextWrapping = 'Wrap'; $t.TextAlignment = 'Center'; $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'; $t.Margin = '8'; [void]$g.Children.Add($t)
    }
    $lb = New-Object System.Windows.Controls.Border; $lb.Background = Get-CamBrush '#B0000000'; $lb.CornerRadius = [System.Windows.CornerRadius]::new(3); $lb.Padding = '4,1,4,1'
    $lb.HorizontalAlignment = 'Left'; $lb.VerticalAlignment = 'Top'; $lb.Margin = [System.Windows.Thickness]::new(4 * $Scale)
    $lb.Child = (New-CamText ($CamNames[$Cam].ToUpper()) (8 * $Scale)); [void]$g.Children.Add($lb)
    return $bd
}

# ---- widget panel ----
function Set-CamStatus { param([string]$S, [string]$M) $script:Cam.status = $S; $script:Cam.msg = $M; Render-Cam }
function Set-CamView { param([string]$V) $script:Cam.view = $V; Render-Cam; Show-CamFrame }
function Get-CamEventLine {
    param($Ev)
    if ($null -eq $Ev) { return '' }
    $t = [datetime]::Parse([string]$Ev.time, $Inv)
    $when = $(if ($t.Date -eq (Get-LocalNow).Date) { $t.ToString('h:mm tt', $Inv) } else { $t.ToString('ddd MMM d, h:mm tt', $Inv) })
    $dot = [string][char]0x25CF
    switch ([string]$Ev.kind) {
        'SentryClips' { return $dot + ' SENTRY EVENT · saved ' + $when }
        'SavedClips' { return $dot + ' SAVED DASHCAM CLIP · ' + $when }
        'RecentClips' { return $dot + ' RECENT DASHCAM · ' + $when }
        default { return $dot + ' CLIP · ' + $when }
    }
}
function Update-CamBusy {
    $txt = $null
    if ($null -ne $script:CamSave) { $s = $script:CamSave.sync; $txt = 'Saving clip: ' + $s.done + ' / ' + $s.total + ' files' + $(if ($s.mb -gt 0) { ' (' + [math]::Round($s.mb, 1) + ' MB)' } else { '' }) }
    elseif ($null -ne $script:CamJob) { $txt = 'Loading frames ' + $script:CamJob.done + ' / ' + $script:CamJob.total }
    elseif ($null -ne $script:CamScan) { $txt = 'Looking for new clips...' }
    Set-Visible $ui.CamBusy ([bool]$txt)
    if ($txt) { $ui.CamBusyTxt.Text = $txt }
    if ($SelfTest -and $txt -and $null -ne $script:CamBusySeen -and ($script:CamBusySeen.Count -eq 0 -or [string]$script:CamBusySeen[$script:CamBusySeen.Count - 1] -ne $txt)) { [void]$script:CamBusySeen.Add($txt) }
    $ui.CamSave.IsEnabled = ($null -ne $script:Cam.ev -and $null -eq $script:CamSave)
    if ($script:Cam.status -eq 'loading' -and $null -ne $script:CamJob -and $null -ne $script:CamMsgText) { $script:CamMsgText.Text = 'Loading frames ' + $script:CamJob.done + ' / ' + $script:CamJob.total }
}
function Render-Cam {
    $C = $script:Cam; $on = [bool]$script:CamCfg.enabled
    $ui.CamToggle.IsChecked = $on
    Set-Visible $ui.CamCard $on
    if (-not $on) { return }
    $ui.CamCard.Background = T 'CardBg'; $ui.CamCard.BorderBrush = T 'CardBorder'
    # tabs
    $ui.CamTabs.Children.Clear()
    $have = @($C.cams); if ($have.Count -eq 0) { $have = @('front', 'back', 'left_repeater', 'right_repeater') }
    $tabs = @($have) + @('grid')
    $ui.CamTabs.Columns = $tabs.Count
    foreach ($k in $tabs) {
        $lbl = $(if ($k -eq 'grid') { $(if ($have.Count -gt 4) { [string]$have.Count + '-up' } else { '4-up' }) } else { $CamShort[$k] })
        $b = New-CamButton $lbl $(if ($tabs.Count -gt 5) { 9 } else { 10.5 }) $(if ($k -eq 'grid') { 'All cameras in a grid' } else { $CamNames[$k] })
        $b.Height = 26; $b.Margin = '1.5,0,1.5,0'; $b.Padding = '2,0,2,0'; $b.Tag = $k
        if ($C.view -eq $k) { $b.BorderBrush = Get-CamBrush '#FF49DF93'; $b.Foreground = Get-CamBrush '#FF49DF93'; $b.Background = Get-CamBrush '#1A49DF93' }
        $b.IsEnabled = ($C.n -gt 0 -and ($k -eq 'grid' -or $C.frames.ContainsKey($k)))
        $b.Add_Click({ param($s9, $e9) try { Set-CamView ([string]$s9.Tag) } catch {} })
        [void]$ui.CamTabs.Children.Add($b)
    }
    $ui.CamEvent.Text = Get-CamEventLine $C.ev
    $ui.CamEvent.Foreground = Get-CamBrush $(if ($null -ne $C.ev -and [string]$C.ev.kind -eq 'SentryClips') { '#FFE82127' } else { '#FFCCCCCC' })
    $ui.CamSrc.Text = $(if ($null -ne $C.ev) { (Get-CamSrcLabel) + ' · ' + $(if ($C.ev.kind -eq 'Folder') { 'folder' } else { [string]$C.ev.kind }) } else { Get-CamSrcLabel })
    $ui.CamSrc.ToolTip = $(if (Get-CamRoot) { Get-CamRoot } else { 'No clip folder chosen yet' })
    # view
    Clear-CamOwner 'widget'
    Register-CamBar 'slider' $ui.CamSlider 'widget'; Register-CamBar 'count' $ui.CamCount 'widget'; Register-CamBar 'play' $ui.CamPlayTxt 'widget'
    $ui.CamView.Children.Clear(); $script:CamMsgText = $null
    if ($C.n -gt 0) {
        if ($C.view -eq 'grid') {
            $ug = New-Object System.Windows.Controls.Primitives.UniformGrid
            $cols = $(if (@($C.cams).Count -gt 4) { 3 } else { 2 }); $ug.Columns = $cols
            foreach ($k in $C.cams) { [void]$ug.Children.Add((New-CamTile $k $(if ($cols -eq 3) { 240 } else { 320 }) $(if ($cols -eq 3) { 0.85 } else { 1.0 }) 'widget' ($cols -eq 2) $true)) }
            [void]$ui.CamView.Children.Add($ug)
        } else { [void]$ui.CamView.Children.Add((New-CamTile $C.view 640 1.15 'widget' $true $false)) }
        if ($C.msg) { $nb = New-Object System.Windows.Controls.Border; $nb.Background = Get-CamBrush '#C0000000'; $nb.CornerRadius = [System.Windows.CornerRadius]::new(4); $nb.Padding = '6,2,6,2'; $nb.HorizontalAlignment = 'Center'; $nb.VerticalAlignment = 'Top'; $nb.Margin = '0,4,0,0'; $nb.Child = (New-CamText $C.msg 9 '#FFFFB547' 'SemiBold'); [void]$ui.CamView.Children.Add($nb) }
    } else {
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'; $sp.HorizontalAlignment = 'Center'; $sp.Margin = '14,0,14,0'
        $title = ''; $sub = ''; $btns = @()
        switch ($C.status) {
            'nofolder' { $title = 'Where are your TeslaCam clips?'; $sub = 'Pick the TeslaCam folder: a Wi-Fi USB drive (such as TeslaUSB) or the folder copied from the car''s USB stick. Tesla has no live camera feed, so TessDesk shows frames from saved Sentry / Dashcam clips.'; $btns = @('pick') }
            'scanning' { $title = 'Looking for clips...'; $sub = $C.msg }
            'loading' { $title = 'Loading frames...'; $sub = '' }
            'noclips' { $title = 'No clips yet'; $sub = $C.msg + '. New Sentry events show up here after the car saves them to its USB drive.'; $btns = @('pick', 'rescan') }
            'stopped' { $title = 'Stopped'; $sub = $C.msg; $btns = @('rescan') }
            default { $title = 'Could not load clips'; $sub = $C.msg; $btns = @('pick', 'rescan') }
        }
        $t1 = New-CamText $title 12.5 '#FFFFFFFF' 'Bold'; $t1.HorizontalAlignment = 'Center'; [void]$sp.Children.Add($t1)
        $t2 = New-CamText $sub 9.5 '#FFAAAAAA' 'Normal'; $t2.TextWrapping = 'Wrap'; $t2.TextAlignment = 'Center'; $t2.Margin = '0,5,0,0'; [void]$sp.Children.Add($t2)
        if ($C.status -eq 'loading') { $script:CamMsgText = $t2 }
        if ($btns.Count) {
            $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Center'; $row.Margin = '0,10,0,0'
            foreach ($bk in $btns) {
                $b = New-CamButton $(if ($bk -eq 'pick') { 'Choose folder' } else { 'Look again' }) 10.5 $null $(if ($bk -eq 'pick') { '#FF49DF93' } else { '#FF333333' })
                $b.Height = 26; $b.Padding = '10,0,10,0'; $b.Margin = '3,0,3,0'; $b.Tag = $bk
                $b.Add_Click({ param($s9, $e9) try { if ([string]$s9.Tag -eq 'pick') { [void](Select-CamFolder ([string]$script:CamCfg.source)) } else { Start-CamScan -Load } } catch {} })
                [void]$row.Children.Add($b)
            }
            [void]$sp.Children.Add($row)
        }
        [void]$ui.CamView.Children.Add($sp)
    }
    $ui.CamPlay.IsEnabled = ($C.n -gt 1); $ui.CamFs.IsEnabled = ($C.n -gt 0)
    Update-CamBusy; Update-CamBars
}
function Set-CamEnabled {
    param([bool]$On, [bool]$Save = $true)
    $script:CamCfg.enabled = $On
    if ($Save) { Save-CamCfg }
    Add-CamLog $(if ($On) { 'panel ON' } else { 'panel OFF' })
    if ($On) {
        if (-not $SelfTest) { $script:CamRescan.Start() }
        Render-Cam
        if ($script:Cam.n -eq 0 -and $null -eq $script:CamJob) { if (Get-CamRoot) { Start-CamScan -Load } else { Set-CamStatus 'nofolder' '' } }
        else { Start-CamPlay }
    } else {
        $script:CamRescan.Stop()
        Close-CamFullscreen; Stop-CamJob 'replaced'; $script:CamPlayTimer.Stop()
        $script:Cam.frames = @{}; $script:Cam.times = @{}; $script:Cam.n = 0; $script:Cam.cams = @(); $script:Cam.ev = $null; $script:Cam.evKey = $null; $script:Cam.status = 'off'
        Clear-CamOwner 'widget'; $ui.CamView.Children.Clear()
        Render-Cam
    }
    try { Update-CompactScale } catch {}
}
function Select-CamFolder {
    param([string]$Kind = 'folder', [string]$TestPath = $null)
    $p = $TestPath
    if (-not $p) {
        if ($SelfTest) { return $null }
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $(if ($Kind -eq 'usb') { 'Pick the TeslaCam folder on your Wi-Fi USB drive (for example \\teslausb\TeslaCam or its drive letter)' } else { 'Pick the TeslaCam folder you copied from the car''s USB stick' })
        $dlg.ShowNewFolderButton = $false
        $cur = $(if ($Kind -eq 'usb') { [string]$script:CamCfg.usbPath } else { [string]$script:CamCfg.folderPath }); if ($cur -and (Test-Path -LiteralPath $cur)) { $dlg.SelectedPath = $cur }
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $p = $dlg.SelectedPath
    }
    if ($Kind -eq 'usb') { $script:CamCfg.usbPath = $p } else { $script:CamCfg.folderPath = $p }
    $script:CamCfg.source = $Kind
    Save-CamCfg; Add-CamLog ('clip folder (' + $Kind + '): ' + $p)
    Stop-CamJob 'replaced'; $script:CamPlayTimer.Stop()
    $script:Cam.n = 0; $script:Cam.frames = @{}; $script:Cam.cams = @(); $script:Cam.ev = $null; $script:Cam.evKey = $null
    Start-CamScan -Load
    if ($ui.CamOptOverlay.Visibility -eq 'Visible') { Build-CamOptions }
    return $p
}

# ---- capture: save the frame (PNG) + email it ----
function Show-CamToast {
    param([string]$Text, [bool]$Ok = $true)
    $script:CamLastToast = $Text
    if ($null -ne $script:CamFs) {
        foreach ($w in $script:CamFs.windows) { try { $w.Tag.toastTxt.Text = $Text; $w.Tag.toast.BorderBrush = Get-CamBrush $(if ($Ok) { '#FF49DF93' } else { '#FFE82127' }); $w.Tag.toast.Visibility = 'Visible' } catch {} }
        $script:CamFsToastTimer.Stop(); $script:CamFsToastTimer.Start()
    } else { Show-TdToast $Text $Ok }
}
$script:CamFsToastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:CamFsToastTimer.Interval = [TimeSpan]::FromSeconds(6)
$script:CamFsToastTimer.Add_Tick({ $script:CamFsToastTimer.Stop(); try { foreach ($w in $script:CamFs.windows) { $w.Tag.toast.Visibility = 'Collapsed' } } catch {} })
function Test-CamSmtp { try { return [bool](Test-RemSmtp) } catch { return $false } }
function Get-CamCaptureDir {
    if ([string]$script:CamCfg.captureDir) { return [string]$script:CamCfg.captureDir }
    if ($SelfTest -and $script:SelfDir) { return (Join-Path $script:SelfDir 'captures') }
    return (Join-Path ([Environment]::GetFolderPath('MyPictures')) 'TessDesk Captures')
}
function Save-CamCapturePng {
    param([string]$Cam, [string]$Path)
    $C = $script:Cam; $i = [math]::Min([int]$C.idx, @($C.frames[$Cam]).Count - 1)
    $src = ConvertTo-CamImage $C.frames[$Cam][$i] 0
    $w = $src.PixelWidth; $h = $src.PixelHeight; $t = [datetime]$C.times[$Cam][$i]
    $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
    $dc.DrawImage($src, [System.Windows.Rect]::new(0, 0, $w, $h))
    $bh = [math]::Max(28, [int]($h * 0.045))
    $dc.DrawRectangle((Get-CamBrush '#C0000000'), $null, [System.Windows.Rect]::new(0, $h - $bh, $w, $bh))
    $cap = $CamNames[$Cam].ToUpper() + '   ' + $t.ToString('yyyy-MM-dd HH:mm:ss', $Inv) + '   ' + $(if ($C.ev.kind -eq 'SentryClips') { 'Sentry event' } else { 'Dashcam clip' }) + ' (saved clip, not live)   TessDesk'
    $ft = New-Object System.Windows.Media.FormattedText ($cap, $Inv, [System.Windows.FlowDirection]::LeftToRight, (New-Object System.Windows.Media.Typeface 'Segoe UI'), ($bh * 0.5), (Get-CamBrush '#FFFFFFFF'))
    $dc.DrawText($ft, [System.Windows.Point]::new(12, $h - $bh + ($bh - $ft.Height) / 2)); $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32); $rtb.Render($dv)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($Path); try { $enc.Save($fs) } finally { $fs.Dispose() }
    return [pscustomobject]@{ bmp = $rtb; time = $t; w = $w; h = $h }
}
function Invoke-CamCapture {
    param([string]$Cam)
    $C = $script:Cam
    if (-not $C.frames.ContainsKey($Cam)) { Show-CamToast ('No ' + $CamNames[$Cam] + ' frame to capture') $false; return $null }
    $dir = Get-CamCaptureDir; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $i = [math]::Min([int]$C.idx, @($C.frames[$Cam]).Count - 1); $t = [datetime]$C.times[$Cam][$i]
    $name = 'TessDesk-' + ($CamNames[$Cam] -replace ' ', '-') + '-' + $t.ToString('yyyy-MM-dd-HHmmss', $Inv) + '.png'
    $path = Join-Path $dir $name
    $r = Save-CamCapturePng $Cam $path
    $to = [string]$script:CamCfg.mailTo
    $subj = 'TessDesk ' + $CamNames[$Cam] + ' camera ' + $t.ToString('MMM d, h:mm:ss tt', $Inv)
    $body = $CamNames[$Cam] + ' camera, ' + $t.ToString('dddd MMM d yyyy, h:mm:ss tt', $Inv) + ' (' + $(if ($C.ev.kind -eq 'SentryClips') { 'Sentry event' } else { 'Dashcam clip' }) + ' ' + [string]$C.ev.name + '). From a saved clip, not live. Sent from TessDesk.'
    $rec = [ordered]@{ cam = $Cam; file = $path; bytes = (Get-Item -LiteralPath $path).Length; size = ([string]$r.w + 'x' + [string]$r.h); frame = $t.ToString('s'); to = $to; via = $null; launched = $false; uri = $null }
    if (Test-CamSmtp) {
        $rec.via = 'your email account (SMTP)'
        if ($SelfTest -or $CTL_DRYRUN) { $rec.via += ', DRY RUN (not sent)'; Show-CamToast ('Saved ' + $CamNames[$Cam] + ' · would email to ' + $to + ' (dry run)') $true }
        else { Start-CamMail $to $subj $body $path $CamNames[$Cam]; Show-CamToast ('Saved ' + $CamNames[$Cam] + ' · emailing to ' + $to + '...') $true }
    } else {
        $rec.via = 'email app (mailto) + picture on the clipboard'
        if (-not $SelfTest) { try { [System.Windows.Clipboard]::SetImage($r.bmp) } catch {} }
        $rec.uri = 'mailto:' + $to + '?subject=' + [uri]::EscapeDataString($subj) + '&body=' + [uri]::EscapeDataString($body + "`r`n`r`nPicture: " + $path + "`r`n(It is also on the clipboard: paste it with Ctrl+V.)")
        Open-ShareTarget 'camera-email' $rec.uri
        $rec.launched = (-not $SelfTest)
        Show-CamToast ('Saved ' + $CamNames[$Cam] + ' · your email app is opening to ' + $to + '. The picture is copied: paste it (Ctrl+V) or attach ' + $name + ' from Pictures\TessDesk Captures.') $true
    }
    $script:CamCaptures = @(@($script:CamCaptures) + @([pscustomobject]$rec) | Where-Object { $null -ne $_ } | Select-Object -Last 20)
    Add-CamLog ('capture ' + $Cam + ' -> ' + $name + ' via ' + $rec.via)
    return [pscustomobject]$rec
}
$script:CamMailBlock = {
    param($HostN, $Port, $Ssl, $User, $From, $To, $SecFile, $Subject, $Body, $Att)
    $ss = (Get-Content -LiteralPath $SecFile -Raw).Trim() | ConvertTo-SecureString
    $cl = New-Object System.Net.Mail.SmtpClient([string]$HostN, [int]$Port); $cl.EnableSsl = [bool]$Ssl; $cl.Timeout = 60000
    $cl.Credentials = New-Object System.Net.NetworkCredential([string]$User, $ss)
    $mm = New-Object System.Net.Mail.MailMessage([string]$From, [string]$To); $mm.Subject = $Subject; $mm.Body = $Body
    $mm.Attachments.Add((New-Object System.Net.Mail.Attachment([string]$Att)))
    try { $cl.Send($mm); return 'sent' } finally { $mm.Dispose(); $cl.Dispose() }
}
function Start-CamMail {
    param([string]$To, [string]$Subj, [string]$Body, [string]$Att, [string]$CamName)
    $r = $script:RemCfg; $smtp = $r.smtp
    $sec = Join-Path $scriptDir $(if ($r.smtpSecretFile) { [string]$r.smtpSecretFile } else { 'smtp.secret' })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:CamMailBlock).AddArgument([string]$smtp.host).AddArgument([int]$smtp.port).AddArgument($(if ($null -ne $smtp.ssl) { [bool]$smtp.ssl } else { $true })).AddArgument([string]$smtp.user).AddArgument($(if ($smtp.from) { [string]$smtp.from } else { [string]$smtp.user })).AddArgument($To).AddArgument($sec).AddArgument($Subj).AddArgument($Body).AddArgument($Att)
    $script:CamMail = [pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke(); to = $To; cam = $CamName; started = (Get-Date) }
    $script:CamTick.Start()
}
function Complete-CamMail {
    $m = $script:CamMail; $script:CamMail = $null; $ok = $false; $err = $null
    try { $o = @($m.ps.EndInvoke($m.async)); $ok = ($o -contains 'sent'); if (-not $ok -and $m.ps.Streams.Error.Count) { $err = $m.ps.Streams.Error[0].Exception.Message } } catch { $err = $_.Exception.Message }
    try { $m.ps.Dispose() } catch {}
    if ($ok) { Add-CamLog ('emailed ' + $m.cam + ' to ' + $m.to); Show-CamToast ('Saved ' + $m.cam + ' · emailed to ' + $m.to) $true }
    else { Add-CamLog ('email failed: ' + $err); Show-CamToast ('Saved ' + $m.cam + ', but the email failed: ' + $err) $false }
}

# ---- save the selected clip (copy the event's files, with progress + Stop) ----
$script:CamCopyBlock = {
    param($Files, [string]$Dest, $Sync, [int]$SlowMs)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $buf = New-Object byte[] (1MB)
    foreach ($f in $Files) {
        if ($Sync.cancel) { break }
        $dst = Join-Path $Dest (Split-Path -Leaf $f); $tmp = $dst + '.part'
        $in = $null; $out = $null
        try {
            $in = [System.IO.File]::OpenRead($f); $out = [System.IO.File]::Create($tmp)
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { if ($Sync.cancel) { break }; $out.Write($buf, 0, $n); $Sync.mb += $n / 1MB }
        } catch { $Sync.err = $_.Exception.Message } finally { if ($out) { $out.Dispose() }; if ($in) { $in.Dispose() } }
        if ($Sync.cancel -or $Sync.err) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; break }
        Move-Item -LiteralPath $tmp -Destination $dst -Force
        $Sync.done++
        if ($SlowMs -gt 0) { Start-Sleep -Milliseconds $SlowMs }   # self-test only (slow copy to test Stop)
    }
    return 'ok'
}
function Get-CamClipDir {
    if ([string]$script:CamCfg.clipDir) { return [string]$script:CamCfg.clipDir }
    if ($SelfTest -and $script:SelfDir) { return (Join-Path $script:SelfDir 'clips') }
    return (Join-Path ([Environment]::GetFolderPath('MyVideos')) 'TessDesk Clips')
}
function Start-CamSaveClip {
    param([int]$SlowMs = 0)
    $ev = $script:Cam.ev
    if ($null -eq $ev) { Show-CamToast 'Pick a clip first' $false; return $null }
    if ($null -ne $script:CamSave) { return $null }
    $files = @($ev.files | Where-Object { $_ })
    $dest = Join-Path (Get-CamClipDir) ($(if ($ev.kind -eq 'Folder') { 'Clip' } else { [string]$ev.kind }) + '-' + [string]$ev.name)
    $sync = [hashtable]::Synchronized(@{ done = 0; total = $files.Count; cancel = $false; err = $null; mb = 0.0 })
    $ps = [powershell]::Create(); [void]$ps.AddScript($script:CamCopyBlock).AddArgument($files).AddArgument($dest).AddArgument($sync).AddArgument($(if ($SelfTest) { $SlowMs } else { 0 }))
    $script:CamSave = [pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke(); sync = $sync; dest = $dest; started = (Get-Date); ev = $ev }
    Add-CamLog ('saving clip ' + $ev.kind + '/' + $ev.name + ' (' + $files.Count + ' files) to ' + $dest)
    Update-CamBusy; $script:CamTick.Start()
    return $dest
}
function Stop-CamSave { if ($null -ne $script:CamSave) { $script:CamSave.sync.cancel = $true } }
function Complete-CamSave {
    $s = $script:CamSave; $script:CamSave = $null
    try { [void]$s.ps.EndInvoke($s.async) } catch { if (-not $s.sync.err) { $s.sync.err = $_.Exception.Message } }
    try { $s.ps.Dispose() } catch {}
    $y = $s.sync
    $script:CamLastSave = [ordered]@{ dest = $s.dest; done = $y.done; total = $y.total; cancelled = [bool]$y.cancel; err = $y.err; mb = [math]::Round($y.mb, 2) }
    if ($y.cancel) { Add-CamLog ('clip save stopped at ' + $y.done + ' / ' + $y.total); Show-CamToast ('Stopped: saved ' + $y.done + ' of ' + $y.total + ' files to ' + $s.dest) $false }
    elseif ($y.err) { Add-CamLog ('clip save failed: ' + $y.err); Show-CamToast ('Saving the clip failed: ' + $y.err) $false }
    else { Add-CamLog ('clip saved: ' + $y.done + ' files, ' + [math]::Round($y.mb, 1) + ' MB'); Show-CamToast ('Saved the clip (' + $y.done + ' files) to ' + $s.dest) $true }
    Update-CamBusy
}

# ---- one 50 ms timer runs only while something is loading / scanning / saving / emailing ----
$script:CamTick = New-Object System.Windows.Threading.DispatcherTimer
$script:CamTick.Interval = [TimeSpan]::FromMilliseconds(50)
$script:CamTick.Add_Tick({
    try {
        if ($null -ne $script:CamScan) { if ($script:CamScan.async.IsCompleted) { Complete-CamScan } elseif (((Get-Date) - $script:CamScan.started).TotalSeconds -gt 45) { try { $script:CamScan.ps.Stop() } catch {}; $script:CamScan = $null; Add-CamLog 'scan timed out'; if ($script:Cam.n -eq 0) { Set-CamStatus 'error' ('No answer from ' + (Get-CamRoot) + ' (a Wi-Fi drive may be asleep or away from home)') } } }
        if ($null -ne $script:CamJob) { Step-CamJob }
        if ($null -ne $script:CamSave) { if ($script:CamSave.async.IsCompleted) { Complete-CamSave } else { Update-CamBusy } }
        if ($null -ne $script:CamMail -and $script:CamMail.async.IsCompleted) { Complete-CamMail }
        if (-not (Test-CamBusy) -and $null -eq $script:CamMail) { $script:CamTick.Stop(); Update-CamBusy }
    } catch { Write-WidgetLog ('camera tick: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber) }
})
# latest-event mode: look for a newer clip every 5 minutes while the panel is on (a Wi-Fi drive syncs new events home)
$script:CamRescan = New-Object System.Windows.Threading.DispatcherTimer
$script:CamRescan.Interval = [TimeSpan]::FromMinutes(5)
$script:CamRescan.Add_Tick({ try { if (-not $SelfTest -and [bool]$script:CamCfg.enabled -and [string]$script:CamCfg.which -eq 'latest' -and -not (Test-CamBusy) -and $null -eq $script:CamFs -and (Get-CamRoot)) { Start-CamScan } } catch {} })

# ---- options panel ----
function New-CamSection { param([string]$T) $h = New-CamText $T 10 '#FF9A9A9A' 'Bold'; $h.Margin = '0,9,0,4'; return $h }
function New-CamChoice {
    param([string]$Label, [bool]$On, $Tag, [double]$Size = 10.5)
    $b = New-CamButton $Label $Size $null $(if ($On) { '#FF49DF93' } else { '#FF333333' })
    $b.Height = 26; $b.Margin = '2,0,2,0'; $b.Padding = '4,0,4,0'; $b.Tag = $Tag
    if ($On) { $b.Foreground = Get-CamBrush '#FF49DF93'; $b.Background = Get-CamBrush '#1A49DF93' }
    return $b
}
function Build-CamOptions {
    $OB = $ui.CamOptBody; $OB.Children.Clear(); $cfg = $script:CamCfg
    # on / off
    $row = New-Object System.Windows.Controls.DockPanel
    $tg = New-Object System.Windows.Controls.Primitives.ToggleButton; $tg.Style = $window.FindResource('SwitchStyle'); $tg.Tag = Get-CamBrush '#FF49DF93'; $tg.IsChecked = [bool]$cfg.enabled; $tg.VerticalAlignment = 'Center'
    [System.Windows.Controls.DockPanel]::SetDock($tg, 'Right'); [void]$row.Children.Add($tg)
    $tl = New-Object System.Windows.Controls.StackPanel
    $on1 = New-CamText ('Show camera panel   ' + $(if ($cfg.enabled) { 'ON' } else { 'OFF' })) 11.5 '#FFFFFFFF' 'Bold'; [void]$tl.Children.Add($on1)
    $ts = New-CamText 'Loops still frames from your saved Sentry / Dashcam clips. Not live. Off = the panel is hidden and TessDesk looks as before.' 9.5 '#FFAAAAAA' 'Normal'; $ts.TextWrapping = 'Wrap'; $ts.Margin = '0,0,8,0'; [void]$tl.Children.Add($ts)
    [void]$row.Children.Add($tl)
    $tg.Add_Click({ param($s9, $e9) try { Set-CamEnabled ([bool]$s9.IsChecked); Build-CamOptions } catch {} })
    [void]$OB.Children.Add($row)
    # clip source
    [void]$OB.Children.Add((New-CamSection 'CLIP SOURCE'))
    foreach ($src in @(@('usb', 'USB Wi-Fi drive', ' (auto sync, e.g. TeslaUSB)', [string]$cfg.usbPath, 'New Sentry / Dashcam clips copy home over Wi-Fi when the car parks.'),
                       @('folder', 'Folder on this PC', '', [string]$cfg.folderPath, 'Copy the TeslaCam folder from the car''s USB stick, then point TessDesk at it.'))) {
        $on = ([string]$cfg.source -eq $src[0])
        $cb = New-Object System.Windows.Controls.Border; $cb.CornerRadius = [System.Windows.CornerRadius]::new(9); $cb.BorderThickness = '1.5'; $cb.Padding = '8,6,8,7'; $cb.Margin = '0,0,0,5'; $cb.Cursor = [System.Windows.Input.Cursors]::Hand
        $cb.BorderBrush = Get-CamBrush $(if ($on) { '#FF49DF93' } else { '#FF333333' }); $cb.Background = Get-CamBrush $(if ($on) { '#1249DF93' } else { '#FF1A1A1A' })
        $dp = New-Object System.Windows.Controls.DockPanel
        $pick = New-CamButton 'Choose...' 9.5 'Pick the folder'; $pick.Height = 22; $pick.Padding = '6,0,6,0'; $pick.Tag = $src[0]; $pick.VerticalAlignment = 'Top'
        $pick.Add_Click({ param($s9, $e9) try { $e9.Handled = $true; [void](Select-CamFolder ([string]$s9.Tag)) } catch {} })
        [System.Windows.Controls.DockPanel]::SetDock($pick, 'Right'); [void]$dp.Children.Add($pick)
        $sp = New-Object System.Windows.Controls.StackPanel
        $t = New-Object System.Windows.Controls.TextBlock; $t.FontSize = 11; $t.Foreground = Get-CamBrush '#FFFFFFFF'; $t.TextWrapping = 'Wrap'
        $r1 = [System.Windows.Documents.Run]::new($(if ($on) { [string][char]0x25C9 } else { [string][char]0x25CB }) + ' ' + $src[1]); $r1.FontWeight = 'Bold'; [void]$t.Inlines.Add($r1)
        if ($src[2]) { [void]$t.Inlines.Add([System.Windows.Documents.Run]::new($src[2])) }
        [void]$sp.Children.Add($t)
        $d = New-CamText $(if ($src[3]) { $src[3] } else { $src[4] }) 9 $(if ($src[3]) { '#FF49DF93' } else { '#FFAAAAAA' }) 'Normal'; $d.TextWrapping = 'Wrap'; $d.Margin = '14,1,0,0'; [void]$sp.Children.Add($d)
        [void]$dp.Children.Add($sp); $cb.Child = $dp; $cb.Tag = $src[0]
        $cb.Add_MouseLeftButtonUp({ param($s9, $e9) try { $k = [string]$s9.Tag; $p = $(if ($k -eq 'usb') { [string]$script:CamCfg.usbPath } else { [string]$script:CamCfg.folderPath }); if (-not $p) { [void](Select-CamFolder $k) } elseif ($script:CamCfg.source -ne $k) { [void](Select-CamFolder $k $p) } } catch {} })
        [void]$OB.Children.Add($cb)
    }
    $ph = New-Object System.Windows.Controls.Border; $ph.CornerRadius = [System.Windows.CornerRadius]::new(9); $ph.BorderThickness = '1.5'; $ph.Padding = '8,6,8,7'; $ph.BorderBrush = Get-CamBrush '#FF2A2A2A'; $ph.Background = Get-CamBrush '#FF151515'
    $pps = New-Object System.Windows.Controls.StackPanel; [void]$pps.Children.Add((New-CamText ([string][char]0x25CB + ' Phone: pick a saved video') 11 '#FF8A8A8A' 'Bold'))
    $pd = New-CamText 'In the TessDesk phone app: Cameras > Pick clip (Photos / Files).' 9 '#FF777777' 'Normal'; $pd.Margin = '14,1,0,0'; $pd.TextWrapping = 'Wrap'; [void]$pps.Children.Add($pd); $ph.Child = $pps
    [void]$OB.Children.Add($ph)
    $nt = New-CamText ([string][char]0x24D8 + ' The Tesla app can''t export Sentry / Dashcam clips to other apps, so clips have to come from the car''s USB drive.') 9.5 '#FFFFB547' 'Normal'; $nt.TextWrapping = 'Wrap'; $nt.Margin = '0,5,0,0'; [void]$OB.Children.Add($nt)
    # speed
    [void]$OB.Children.Add((New-CamSection 'PLAYBACK SPEED'))
    $ug = New-Object System.Windows.Controls.Primitives.UniformGrid; $ug.Columns = 3
    foreach ($f in 2, 4, 8) { $b = New-CamChoice ([string]$f + ' fps') ([int]$cfg.fps -eq $f) $f; $b.Add_Click({ param($s9, $e9) try { Set-CamFps ([int]$s9.Tag); Build-CamOptions } catch {} }); [void]$ug.Children.Add($b) }
    [void]$OB.Children.Add($ug)
    # which clips
    [void]$OB.Children.Add((New-CamSection 'WHICH CLIPS'))
    $ug = New-Object System.Windows.Controls.Primitives.UniformGrid; $ug.Columns = 2
    foreach ($w in @(@('latest', 'Latest event'), @('all', 'All events'))) {
        $b = New-CamChoice $w[1] ([string]$cfg.which -eq $w[0]) $w[0]
        $b.Add_Click({ param($s9, $e9) try { $script:CamCfg.which = [string]$s9.Tag; Save-CamCfg; if ($script:CamCfg.which -eq 'latest' -and @($script:Cam.events).Count) { $n0 = @($script:Cam.events)[0]; if (([string]$n0.dir + '|' + [string]$n0.name) -ne $script:Cam.evKey) { Start-CamLoad $n0 } }; Build-CamOptions } catch {} })
        [void]$ug.Children.Add($b)
    }
    [void]$OB.Children.Add($ug)
    $script:CamOptList = New-Object System.Windows.Controls.StackPanel; $script:CamOptList.Margin = '0,5,0,0'
    [void]$OB.Children.Add($script:CamOptList); Update-CamOptEvents
    # default camera
    [void]$OB.Children.Add((New-CamSection 'DEFAULT CAMERA'))
    $ug = New-Object System.Windows.Controls.Primitives.UniformGrid; $ug.Columns = 5
    foreach ($d in @(@('front', 'Front'), @('back', 'Rear'), @('left_repeater', 'Left'), @('right_repeater', 'Right'), @('grid', '4-up'))) { $b = New-CamChoice $d[1] ([string]$cfg.defaultCam -eq $d[0]) $d[0] 10; $b.Add_Click({ param($s9, $e9) try { $script:CamCfg.defaultCam = [string]$s9.Tag; Save-CamCfg; Set-CamView ([string]$s9.Tag); Build-CamOptions } catch {} }); [void]$ug.Children.Add($b) }
    [void]$OB.Children.Add($ug)
    # full screen
    [void]$OB.Children.Add((New-CamSection 'FULL SCREEN'))
    $scr = @(Get-CamScreens)
    [void]$OB.Children.Add((New-CamText 'Full-screen layout' 9.5 '#FFAAAAAA' 'Normal'))
    $cmb = New-Object System.Windows.Controls.ComboBox; $cmb.Margin = '0,3,0,0'; $cmb.FontSize = 10.5
    foreach ($o in @(@('two', 'Two monitors: Front full screen on one monitor, other cameras grid on the other'), @('one', 'One screen: Front on top, others below'))) {
        $ci = New-Object System.Windows.Controls.ComboBoxItem; $tb = New-CamText $o[1] 10.5 '#FF111111' 'SemiBold'; $tb.TextWrapping = 'Wrap'; $tb.MaxWidth = 250; $ci.Content = $tb; $ci.Tag = $o[0]; [void]$cmb.Items.Add($ci)
        if ([string]$cfg.fsLayout -eq $o[0]) { $cmb.SelectedItem = $ci }
    }
    $cmb.Add_SelectionChanged({ param($s9, $e9) try { if ($null -ne $s9.SelectedItem -and [string]$s9.SelectedItem.Tag -ne $script:CamCfg.fsLayout) { $script:CamCfg.fsLayout = [string]$s9.SelectedItem.Tag; Save-CamCfg; $window.Dispatcher.BeginInvoke([Action]{ try { Build-CamOptions } catch {} }) | Out-Null } } catch {} })
    [void]$OB.Children.Add($cmb); $script:CamOptLayoutCombo = $cmb; $script:CamOptMonCombo = $null
    if ([string]$cfg.fsLayout -eq 'two') {
        $l2 = New-CamText 'Which monitor gets Front (two-monitor layout)' 9.5 '#FFAAAAAA' 'Normal'; $l2.Margin = '0,6,0,0'; [void]$OB.Children.Add($l2)
        $cm2 = New-Object System.Windows.Controls.ComboBox; $cm2.Margin = '0,3,0,0'; $cm2.FontSize = 10.5
        foreach ($o in @(@('left', 'Left monitor'), @('right', 'Right monitor'))) { $ci = New-Object System.Windows.Controls.ComboBoxItem; $ci.Content = $o[1]; $ci.Tag = $o[0]; [void]$cm2.Items.Add($ci); if ([string]$cfg.fsFront -eq $o[0]) { $cm2.SelectedItem = $ci } }
        $cm2.Add_SelectionChanged({ param($s9, $e9) try { if ($null -ne $s9.SelectedItem) { $script:CamCfg.fsFront = [string]$s9.SelectedItem.Tag; Save-CamCfg } } catch {} })
        [void]$OB.Children.Add($cm2); $script:CamOptMonCombo = $cm2
    }
    $sn = New-CamText ([string]$scr.Count + ' monitor(s) found' + $(if ($scr.Count -lt 2 -and [string]$cfg.fsLayout -eq 'two') { ': the two-monitor layout uses one screen until a second monitor is connected.' } else { '.' }) + ' Esc or X closes full screen; TessDesk hides while it is open.') 9 '#FF8A8A8A' 'Normal'
    $sn.TextWrapping = 'Wrap'; $sn.Margin = '0,5,0,0'; [void]$OB.Children.Add($sn)
    # capture + save
    [void]$OB.Children.Add((New-CamSection 'CAPTURE AND SAVE'))
    $how = $(if (Test-CamSmtp) { 'Capture on any camera saves that frame and emails it to ' + $cfg.mailTo + ' from your own email account (Setup > Reminders).' } else { 'Capture on any camera saves that frame to Pictures\TessDesk Captures and opens your email app to ' + $cfg.mailTo + ' with the picture copied (paste it, or attach the file). To send it automatically, set up your email account in TessDesk Setup > Reminders.' })
    $hw = New-CamText $how 9.5 '#FFCCCCCC' 'Normal'; $hw.TextWrapping = 'Wrap'; [void]$OB.Children.Add($hw)
    $sv = New-CamText ('Save clip copies the selected Sentry / Dashcam clip to ' + (Get-CamClipDir) + '.') 9.5 '#FFCCCCCC' 'Normal'; $sv.TextWrapping = 'Wrap'; $sv.Margin = '0,4,0,2'; [void]$OB.Children.Add($sv)
}
function Update-CamOptEvents {
    $L = $script:CamOptList; if ($null -eq $L) { return }
    $L.Children.Clear()
    $evs = @($script:Cam.events); if ([string]$script:CamCfg.which -eq 'latest') { $evs = @($evs | Select-Object -First 1) } else { $evs = @($evs | Select-Object -First 12) }
    if ($evs.Count -eq 0) { [void]$L.Children.Add((New-CamText $(if (Get-CamRoot) { 'No clips found yet.' } else { 'Choose a clip folder above.' }) 9.5 '#FF8A8A8A' 'Normal')); return }
    foreach ($e in $evs) {
        $cur = (([string]$e.dir + '|' + [string]$e.name) -eq $script:Cam.evKey)
        $t = [datetime]::Parse([string]$e.time, $Inv)
        $b = New-Object System.Windows.Controls.Border; $b.Padding = '8,4,8,4'; $b.Margin = '0,0,0,1'; $b.CornerRadius = [System.Windows.CornerRadius]::new(4); $b.Cursor = [System.Windows.Input.Cursors]::Hand; $b.Tag = $e
        $b.Background = Get-CamBrush $(if ($cur) { '#2249DF93' } else { '#FF1A1A1A' }); $b.ToolTip = [string]$e.dir
        $dp = New-Object System.Windows.Controls.DockPanel
        $r = New-CamText $t.ToString('ddd MMM d', $Inv) 9.5 '#FF8A8A8A' 'Normal'; [System.Windows.Controls.DockPanel]::SetDock($r, 'Right'); [void]$dp.Children.Add($r)
        $kind = switch ([string]$e.kind) { 'SentryClips' { 'Sentry event · saved ' } 'SavedClips' { 'Dashcam clip · saved ' } 'RecentClips' { 'Recent dashcam · ' } default { 'Clip · ' } }
        [void]$dp.Children.Add((New-CamText ($kind + $t.ToString('h:mm tt', $Inv)) 10 $(if ($cur) { '#FF49DF93' } else { '#FFE6E6E6' }) 'SemiBold'))
        $b.Child = $dp
        $b.Add_MouseLeftButtonUp({ param($s9, $e9) try { Start-CamLoad $s9.Tag; Update-CamOptEvents } catch {} })
        [void]$L.Children.Add($b)
    }
}
function Show-CamOptions { Build-CamOptions; $ui.CamOptScroll.MaxHeight = [math]::Max(300, $window.ActualHeight - 110); Set-Visible $ui.CamOptOverlay $true }
function Close-CamOptions { Set-Visible $ui.CamOptOverlay $false }
function Set-CamFps { param([int]$F) if (@(2, 4, 8) -notcontains $F) { return }; $script:CamCfg.fps = $F; Save-CamCfg; Start-CamPlay; Update-CamBars }

# ---- full screen (two monitors or one screen); TessDesk hides while it is open ----
function Get-CamScreens { try { return @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y }) } catch { return @() } }
function Get-CamDipRect {
    param($Screen)
    $sx = 1.0; $sy = 1.0
    try { $m = [System.Windows.PresentationSource]::FromVisual($window).CompositionTarget.TransformFromDevice; $sx = $m.M11; $sy = $m.M22 } catch {}
    $b = $Screen.Bounds
    return [System.Windows.Rect]::new($b.X * $sx, $b.Y * $sy, $b.Width * $sx, $b.Height * $sy)
}
function New-CamFsWindow {
    param([System.Windows.Rect]$Rect, [string]$Title, [string]$Kind, [string]$Note = $null)
    $C = $script:Cam
    $w = New-Object System.Windows.Window
    $w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'; $w.Topmost = $true; $w.ShowInTaskbar = $false; $w.WindowStartupLocation = 'Manual'
    $w.Background = Get-CamBrush '#FF0B0B0B'; $w.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI'); $w.Title = 'TessDesk cameras'
    try { $w.Icon = $window.Icon } catch {}
    $off = $(if ($SelfTest) { -30000 } else { 0 })   # the self-test lays the windows out off screen (pictures only), never over the desktop
    $w.Left = $Rect.X + $off; $w.Top = $Rect.Y; $w.Width = $Rect.Width; $w.Height = $Rect.Height
    if ($SelfTest) { $w.ShowActivated = $false }
    $own = 'fs' + $script:CamFs.windows.Count
    $root = New-Object System.Windows.Controls.Grid
    $dock = New-Object System.Windows.Controls.DockPanel; [void]$root.Children.Add($dock)
    # top bar
    $top = New-Object System.Windows.Controls.Border; $top.Background = Get-CamBrush '#FF141414'; $top.Height = 38; $top.Padding = '14,0,8,0'
    [System.Windows.Controls.DockPanel]::SetDock($top, 'Top'); [void]$dock.Children.Add($top)
    $tg = New-Object System.Windows.Controls.DockPanel; $top.Child = $tg
    $x = New-CamButton (New-CamText ([string][char]0xE711) 11 '#FFE6E6E6' 'Normal' 'Segoe MDL2 Assets') 11 'Close full screen (Esc)'; $x.Width = 30; $x.Height = 26; $x.Padding = '0'
    $x.Add_Click({ try { Close-CamFullscreen } catch {} }); [System.Windows.Controls.DockPanel]::SetDock($x, 'Right'); [void]$tg.Children.Add($x)
    $esc = New-CamText 'Esc to close' 10 '#FF8A8A8A' 'SemiBold'; $esc.VerticalAlignment = 'Center'; $esc.Margin = '10,0,10,0'; [System.Windows.Controls.DockPanel]::SetDock($esc, 'Right'); [void]$tg.Children.Add($esc)
    $pill = New-Object System.Windows.Controls.Border; $pill.CornerRadius = [System.Windows.CornerRadius]::new(9); $pill.BorderBrush = Get-CamBrush '#FFFFB547'; $pill.BorderThickness = '1.5'; $pill.Background = Get-CamBrush '#22FFB547'; $pill.Padding = '8,1,8,2'; $pill.VerticalAlignment = 'Center'
    $pill.Child = (New-CamText 'NOT LIVE · FROM SAVED CLIPS' 9.5 '#FFFFB547' 'Bold'); [System.Windows.Controls.DockPanel]::SetDock($pill, 'Right'); [void]$tg.Children.Add($pill)
    $ls = New-Object System.Windows.Controls.StackPanel; $ls.Orientation = 'Horizontal'; $ls.VerticalAlignment = 'Center'
    $tt = New-CamText 'TESSDESK' 12 '#FFE82127' 'Bold'; $tt.Margin = '0,0,14,0'; [void]$ls.Children.Add($tt)
    $t2 = New-CamText $Title 12 '#FFFFFFFF' 'Bold'; $t2.Margin = '0,0,14,0'; [void]$ls.Children.Add($t2)
    [void]$ls.Children.Add((New-CamText (Get-CamEventLine $C.ev) 11 $(if ($C.ev.kind -eq 'SentryClips') { '#FFE82127' } else { '#FFCCCCCC' }) 'Bold'))
    [void]$tg.Children.Add($ls)
    # bottom bar (grid / one-screen windows)
    if ($Kind -ne 'front') {
        $bot = New-Object System.Windows.Controls.Border; $bot.Background = Get-CamBrush '#FF141414'; $bot.Height = 46; $bot.Padding = '12,0,14,0'
        [System.Windows.Controls.DockPanel]::SetDock($bot, 'Bottom'); [void]$dock.Children.Add($bot)
        $bg = New-Object System.Windows.Controls.DockPanel; $bot.Child = $bg
        $pt = New-CamText '' 13 '#FF49DF93' 'Normal' 'Segoe MDL2 Assets'
        $pb = New-CamButton $pt 12 'Play / pause (Space)' '#FF49DF93'; $pb.Width = 38; $pb.Height = 30; $pb.Padding = '0'
        $pb.Add_Click({ try { Set-CamPlaying (-not $script:Cam.playing) } catch {} }); [System.Windows.Controls.DockPanel]::SetDock($pb, 'Left'); [void]$bg.Children.Add($pb); Register-CamBar 'play' $pt $own
        foreach ($f in 2, 4, 8) { $fb = New-CamButton ([string]$f + ' fps') 10.5 ('Play at ' + $f + ' frames per second'); $fb.Height = 26; $fb.Margin = '6,0,0,0'; $fb.Padding = '8,0,8,0'; $fb.Tag = $f; $fb.Add_Click({ param($s9, $e9) try { Set-CamFps ([int]$s9.Tag) } catch {} }); [System.Windows.Controls.DockPanel]::SetDock($fb, 'Left'); [void]$bg.Children.Add($fb); Register-CamBar 'fps' $fb $own }
        $dbv = New-Object System.Windows.Controls.StackPanel; $dbv.VerticalAlignment = 'Center'; $dbv.Margin = '16,0,0,0'
        $dt = New-Object System.Windows.Controls.TextBlock; $dt.FontFamily = [System.Windows.Media.FontFamily]::new('Bahnschrift, Impact'); $dt.FontWeight = 'Bold'; $dt.FontSize = 13; $dt.Foreground = Get-CamBrush '#FFE6E6E6'
        [void]$dt.Inlines.Add([System.Windows.Documents.Run]::new('DESIGN BY ')); $vr = [System.Windows.Documents.Run]::new('VAN'); $vr.Foreground = Get-CamBrush '#FFE82127'; [void]$dt.Inlines.Add($vr); [void]$dbv.Children.Add($dt)
        [void]$dbv.Children.Add((New-CamText ('v' + $AppVersion + ' · ' + $AppDate) 9 '#FF6A6A6A' 'Normal'))
        [System.Windows.Controls.DockPanel]::SetDock($dbv, 'Right'); [void]$bg.Children.Add($dbv)
        $cnt = New-CamText '' 11 '#FF8A8A8A' 'SemiBold'; $cnt.VerticalAlignment = 'Center'; $cnt.Margin = '12,0,0,0'; [System.Windows.Controls.DockPanel]::SetDock($cnt, 'Right'); [void]$bg.Children.Add($cnt); Register-CamBar 'count' $cnt $own
        $sl = New-Object System.Windows.Controls.Slider; $sl.Style = $window.FindResource('CamSlider'); $sl.Minimum = 0; $sl.Maximum = [math]::Max(0, $C.n - 1); $sl.IsSnapToTickEnabled = $true; $sl.TickFrequency = 1; $sl.SmallChange = 1; $sl.LargeChange = 1; $sl.Margin = '14,0,0,0'; $sl.VerticalAlignment = 'Center'
        $sl.Add_ValueChanged({ param($s9, $e9) try { On-CamSlider $s9 } catch {} }); [void]$bg.Children.Add($sl); Register-CamBar 'slider' $sl $own
    }
    # cameras
    $body = New-Object System.Windows.Controls.Grid; $body.Margin = '8'; [void]$dock.Children.Add($body)
    $main = $(if ($C.cams -contains 'front') { 'front' } else { @($C.cams)[0] })
    $others = @($C.cams | Where-Object { $_ -ne $main })
    if ($Kind -eq 'front') { [void]$body.Children.Add((New-CamTile $main 0 2.0 $own $true $false)) }
    elseif ($Kind -eq 'grid') {
        $cells = $others.Count + $(if ($Note) { 1 } else { 0 })
        $ug = New-Object System.Windows.Controls.Primitives.UniformGrid; $ug.Columns = $(if ($cells -le 4) { 2 } else { 3 })
        foreach ($k in $others) { [void]$ug.Children.Add((New-CamTile $k 960 1.5 $own $true $false)) }
        if ($Note) {
            $nb = New-Object System.Windows.Controls.Border; $nb.Background = Get-CamBrush '#FF111111'; $nb.CornerRadius = [System.Windows.CornerRadius]::new(5); $nb.Margin = '1.5'
            $ns = New-Object System.Windows.Controls.StackPanel; $ns.HorizontalAlignment = 'Center'; $ns.VerticalAlignment = 'Center'
            $n1 = New-CamText $Note 16 '#FFFFFFFF' 'Bold'; $n1.HorizontalAlignment = 'Center'; [void]$ns.Children.Add($n1)
            $n2 = New-CamText ('Change it in Camera options > Full screen') 11 '#FF8A8A8A' 'Normal'; $n2.HorizontalAlignment = 'Center'; $n2.Margin = '0,6,0,0'; [void]$ns.Children.Add($n2)
            $nb.Child = $ns; [void]$ug.Children.Add($nb)
        }
        [void]$body.Children.Add($ug)
    } else {
        $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = [System.Windows.GridLength]::new(2.2, 'Star'); $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [System.Windows.GridLength]::new(1, 'Star')
        [void]$body.RowDefinitions.Add($r0); [void]$body.RowDefinitions.Add($r1)
        [void]$body.Children.Add((New-CamTile $main 0 1.7 $own $true $false))
        $ug = New-Object System.Windows.Controls.Primitives.UniformGrid; $ug.Rows = 1; $ug.Columns = [math]::Max(1, $others.Count); [System.Windows.Controls.Grid]::SetRow($ug, 1)
        foreach ($k in $others) { [void]$ug.Children.Add((New-CamTile $k 640 1.1 $own $true $false)) }
        [void]$body.Children.Add($ug)
    }
    # toast
    $toast = New-Object System.Windows.Controls.Border; $toast.CornerRadius = [System.Windows.CornerRadius]::new(10); $toast.Background = Get-CamBrush '#F01A1A1A'; $toast.BorderBrush = Get-CamBrush '#FF49DF93'; $toast.BorderThickness = '1.5'
    $toast.Padding = '16,10,16,10'; $toast.HorizontalAlignment = 'Center'; $toast.VerticalAlignment = 'Bottom'; $toast.Margin = '0,0,0,70'; $toast.MaxWidth = 720; $toast.Visibility = 'Collapsed'
    $toastTxt = New-CamText '' 13 '#FFFFFFFF' 'SemiBold'; $toastTxt.TextWrapping = 'Wrap'; $toastTxt.TextAlignment = 'Center'; $toast.Child = $toastTxt; [void]$root.Children.Add($toast)
    $w.Content = $root
    $w.Tag = [pscustomobject]@{ kind = $Kind; owner = $own; toast = $toast; toastTxt = $toastTxt; close = $x; rect = $Rect }
    $w.Add_KeyDown({ param($s9, $e9) try { if ($e9.Key -eq 'Escape') { $e9.Handled = $true; Close-CamFullscreen } elseif ($e9.Key -eq 'Space') { Set-CamPlaying (-not $script:Cam.playing) } } catch {} })
    $w.Add_Closed({ try { if ($null -ne $script:CamFs -and -not $script:CamFs.closing) { Close-CamFullscreen } } catch {} })
    return $w
}
function Open-CamFullscreen {
    if ($script:Cam.n -eq 0) { Show-TdToast 'No clip loaded yet' $false; return $null }
    if ($null -ne $script:CamFs) { return $script:CamFs }
    Close-CamOptions
    $scr = @(Get-CamScreens)
    $mode = [string]$script:CamCfg.fsLayout
    $me = $null; try { $me = [System.Windows.Forms.Screen]::FromHandle((Get-TdHwnd)) } catch {}
    if ($null -eq $me -and $scr.Count) { $me = $scr[0] }
    $script:CamFs = [pscustomobject]@{ windows = (New-Object System.Collections.ArrayList); closing = $false; mode = $mode; prev = [ordered]@{ opacity = $window.Opacity; topmost = $window.Topmost; hit = $window.IsHitTestVisible }; screens = $scr.Count; plan = @() }
    if ($mode -eq 'two' -and $scr.Count -ge 2) {
        $fi = $(if ([string]$script:CamCfg.fsFront -eq 'right') { $scr.Count - 1 } else { 0 })
        $oi = $(if ($fi -eq 0) { 1 } else { $scr.Count - 2 })
        $side = $(if ($fi -eq 0) { 'left' } else { 'right' })
        [void]$script:CamFs.windows.Add((New-CamFsWindow (Get-CamDipRect $scr[$fi]) 'FRONT' 'front'))
        [void]$script:CamFs.windows.Add((New-CamFsWindow (Get-CamDipRect $scr[$oi]) 'OTHER CAMERAS' 'grid' ('Front is on the ' + $side + ' monitor')))
        $script:CamFs.plan = @(('front on ' + $scr[$fi].DeviceName + ' ' + [string]$scr[$fi].Bounds), ('others on ' + $scr[$oi].DeviceName + ' ' + [string]$scr[$oi].Bounds))
    } else {
        if ($mode -eq 'two') { $script:CamFs.mode = 'one (only ' + $scr.Count + ' monitor)' }
        $r = $(if ($null -ne $me) { Get-CamDipRect $me } else { [System.Windows.SystemParameters]::WorkArea })
        [void]$script:CamFs.windows.Add((New-CamFsWindow $r 'ALL CAMERAS' 'one'))
        $script:CamFs.plan = @('all on ' + $(if ($me) { $me.DeviceName + ' ' + [string]$me.Bounds } else { 'work area' }))
    }
    # hide the always-on-top widget while full screen is open (Hide() would end TessDesk's window loop, so it goes fully transparent and click-through instead)
    $window.Topmost = $false; $window.Opacity = 0; $window.IsHitTestVisible = $false
    foreach ($w in $script:CamFs.windows) { $w.Show() }
    if (-not $SelfTest) { try { $script:CamFs.windows[0].Activate(); [void]$script:CamFs.windows[0].Focus() } catch {} }
    Add-CamLog ('full screen: ' + $script:CamFs.mode + ' (' + ($script:CamFs.plan -join '; ') + ')')
    Show-CamFrame; Start-CamPlay
    return $script:CamFs
}
function Close-CamFullscreen {
    $f = $script:CamFs; if ($null -eq $f -or $f.closing) { return }
    $f.closing = $true
    foreach ($w in @($f.windows)) { try { Clear-CamOwner $w.Tag.owner } catch {}; try { $w.Close() } catch {} }
    $script:CamFs = $null; $script:CamFsToastTimer.Stop()
    $window.Opacity = $f.prev.opacity; $window.IsHitTestVisible = $f.prev.hit; $window.Topmost = $f.prev.topmost
    if (-not $SelfTest) { try { $window.Activate() } catch {} }
    Add-CamLog 'full screen closed'
    Show-CamFrame
}

# ---- wiring ----
$ui.CamToggle.Add_Click({ try { Set-CamEnabled ([bool]$ui.CamToggle.IsChecked) } catch { Write-WidgetLog ('camera toggle: ' + $_.Exception.Message) } })
$ui.CamGear.Add_Click({ try { Show-CamOptions } catch { Write-WidgetLog ('camera options: ' + $_.Exception.Message) } })
$ui.CamOptClose.Add_Click({ Close-CamOptions })
$ui.CamOptOverlay.Add_MouseLeftButtonUp({ param($s9, $e9) if ($e9.OriginalSource -eq $ui.CamOptOverlay) { Close-CamOptions } })
$ui.CamPlay.Add_Click({ try { Set-CamPlaying (-not $script:Cam.playing) } catch {} })
$ui.CamFs.Add_Click({ try { [void](Open-CamFullscreen) } catch { Write-WidgetLog ('camera full screen: ' + $_.Exception.Message); Close-CamFullscreen; Show-TdToast ('Full screen failed: ' + $_.Exception.Message) $false } })
$ui.CamSave.Add_Click({ try { [void](Start-CamSaveClip) } catch { Show-TdToast ('Save clip failed: ' + $_.Exception.Message) $false } })
$ui.CamStop.Add_Click({ try { if ($null -ne $script:CamSave) { Stop-CamSave } elseif ($null -ne $script:CamJob) { Stop-CamJob } elseif ($null -ne $script:CamScan) { try { $script:CamScan.ps.Stop() } catch {}; $script:CamScan = $null; Update-CamBusy; if ($script:Cam.n -eq 0) { Set-CamStatus 'stopped' 'Stopped looking for clips' } } } catch {} })
$ui.CamSlider.Add_ValueChanged({ param($s9, $e9) try { On-CamSlider $s9 } catch {} })
try { Render-Cam } catch { Write-WidgetLog ('camera render: ' + $_.Exception.Message) }
function Start-CamOnLaunch {
    if ($SelfTest -or -not [bool]$script:CamCfg.enabled) { return }
    $script:CamRescan.Start()
    if (Get-CamRoot) { Start-CamScan -Load } else { Set-CamStatus 'nofolder' '' }
}
function Stop-CamAll {
    try { $script:CamRescan.Stop(); $script:CamPlayTimer.Stop(); $script:CamTick.Stop(); $script:CamFsToastTimer.Stop() } catch {}
    try { Close-CamFullscreen } catch {}
    try { if ($null -ne $script:CamJob) { foreach ($it in $script:CamJob.items) { if ($null -ne $it.p) { Close-CamPlayer $it } } } } catch {}
    try { if ($null -ne $script:CamSave) { $script:CamSave.sync.cancel = $true } } catch {}
}

# ---------------- v4.3.10: TOTALS pop-up (running totals for this week / month / year + month by month) ----------------
# SHARED TOTALS RULE (the phone app uses the exact same rule, so both show the same numbers):
#  * Charges come from Tessie's charge history (/charges), fetched one month at a time and cached in totals-cache.json.
#    The charge in progress (if any) is added from the live tracker until Tessie lists it.
#  * Home = saved location '3515 W 41st Pl' (config homeLocation). Home cost = wall kWh (Tessie energy_used, else
#    kWh added / efficiency) spread evenly over the charging minutes, each minute at its all-in PSO rate (energy + FCA:
#    6.2323 c/kWh overnight 11 PM to 6 AM, the day / peak rate other hours). Same per-minute math as everywhere in TessDesk.
#  * Away from home: a Supercharger / fast charge uses the amount Tessie reports (what was paid); anything else away is
#    priced like home (estimate). Away is listed separately and included in the grand total.
#  * A charge belongs to the night it started in: between 11 PM and 11 AM that is the date the night began (a 12:30 AM
#    charge on Oct 1 is the night of Sep 30); outside that window it is the day it started. Weeks run Monday to Sunday.
#  * Nights = number of different home charging nights. Avg c/kWh = home cost / home wall kWh.
#  * Last 7 / 30 days rows: every charge that STARTED in the last 7 / 30 days, counted whole, home + away (paid).
$TotHome = '3515 W 41st Pl'; try { if ($null -ne $script:Cfg -and $script:Cfg.homeLocation) { $TotHome = [string]$script:Cfg.homeLocation } } catch {}
$totCachePath = Join-Path $scriptDir 'totals-cache.json'
$script:Tot = [ordered]@{ months = @{}; job = $null; shared = $null; status = ''; open = @{}; loadedAt = 0; lastLoad = $null; view = $null; rowsKey = ''; rows = @() }
$script:TotFixtureDir = $null; $script:TotStopAt = 0; $script:TotBusySeen = $null
$script:TotPriced = @{}; $script:TotPricedDirty = $false   # priced cost per charge (saved with the cache, so the pop-up opens fast)
function Get-TotRateSig { return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}' -f $R_ON, $R_DAY, $R_SEAS, $R_PEAK, $FCA, $ON_START, $ON_END, $PK_S, $PK_E, $PEAK_EN, $EFFICIENCY) }
function Test-TotBusy { return ($null -ne $script:Tot.job) }
function Get-TotMonthKeys {
    param([datetime]$Now)
    $keys = @(); for ($m = 1; $m -le $Now.Month; $m++) { $keys += ('{0:0000}-{1:00}' -f $Now.Year, $m) }; return $keys
}
function Get-TotMonthRange {
    param([string]$Key)
    $y = [int]$Key.Substring(0, 4); $m = [int]$Key.Substring(5, 2); $a = New-Object DateTime $y, $m, 1
    return @((ConvertTo-EpochLocal $a), (ConvertTo-EpochLocal $a.AddMonths(1)))
}
function Load-TotCache {
    $script:Tot.months = @{}
    try {
        if (Test-Path -LiteralPath $totCachePath) {
            $j = Get-Content -LiteralPath $totCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in @($j.months.PSObject.Properties)) { $script:Tot.months[[string]$p.Name] = [pscustomobject]@{ at = [int64]$p.Value.at; rows = @($p.Value.rows | Where-Object { $null -ne $_ }) } }
            $script:Tot.loadedAt = [int64](Get-Val $j.savedAt 0)
            $script:TotPriced = @{}; if ([string]$j.rateSig -eq (Get-TotRateSig) -and $null -ne $j.priced) { foreach ($q in @($j.priced.PSObject.Properties)) { $script:TotPriced[[string]$q.Name] = [double]$q.Value } }
        }
    } catch { Write-WidgetLog ('totals cache: ' + $_.Exception.Message) }
}
function Save-TotCache {
    try {
        $m = [ordered]@{}; foreach ($k in ($script:Tot.months.Keys | Sort-Object)) { $m[$k] = $script:Tot.months[$k] }
        $tmp = $totCachePath + '.tmp'
        [ordered]@{ app = 'TessDesk'; version = $AppVersion; savedAt = $(if ($script:Tot.loadedAt -gt 0) { $script:Tot.loadedAt } else { Get-EpochNow }); home = $TotHome; months = $m; rateSig = (Get-TotRateSig); priced = $script:TotPriced } | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $totCachePath -Force; $script:TotPricedDirty = $false
    } catch { Write-WidgetLog ('totals cache save: ' + $_.Exception.Message) }
}
# Background fetch (one Tessie /charges call per month). Never logs or returns the token.
$script:TotFetchBlock = {
    param($Items, $Tok, $Api, $Vin, $Fixture, $Ua, $Sh)
    $out = @()
    foreach ($it in $Items) {
        if ($Sh.cancel) { break }
        $res = [pscustomobject]@{ key = $it.key; ok = $false; rows = @(); err = $null }
        try {
            if ($Fixture) {
                Start-Sleep -Milliseconds 120
                $f = Join-Path $Fixture ($it.key + '.json'); $txt = $(if (Test-Path -LiteralPath $f) { [System.IO.File]::ReadAllText($f) } else { '{"results":[]}' })
            } else {
                $wc = New-Object System.Net.WebClient
                try {
                    $wc.Headers['Authorization'] = 'Bearer ' + $Tok; $wc.Headers['Accept'] = 'application/json'; $wc.Headers['User-Agent'] = $Ua; $wc.Encoding = [System.Text.Encoding]::UTF8
                    $txt = $wc.DownloadString($Api + '/' + $Vin + '/charges?from=' + $it.from + '&to=' + $it.to + '&distance_format=mi&format=json')
                } finally { $wc.Dispose() }
            }
            $j = $txt | ConvertFrom-Json
            $rows = @()
            foreach ($c in @($j.results)) {
                if ($null -eq $c -or $null -eq $c.started_at -or $null -eq $c.ended_at) { continue }
                $loc = $(if ($c.saved_location) { [string]$c.saved_location } elseif ($c.location) { [string]$c.location } else { '' })
                $rows += [pscustomobject]@{ id = $c.id; s = [int64]$c.started_at; e = [int64]$c.ended_at; add = $c.energy_added; used = $c.energy_used; cost = $c.cost
                    sc = [bool]$c.is_supercharger; fc = [bool]$c.is_fast_charger; kw = $c.max_charger_power; loc = $loc }
            }
            $res.rows = $rows; $res.ok = $true
        } catch { $res.err = $_.Exception.Message -replace 'Bearer\s+\S+', 'Bearer ***' }
        $out += $res
        $Sh.done = [int]$Sh.done + 1
    }
    return , $out
}
function Start-TotLoad {
    param([switch]$All)
    if (Test-TotBusy) { return $false }
    if (-not $script:TotFixtureDir -and -not [bool]$script:ReadAllowed) { return $false }
    $nowE = Get-EpochNow; $now = ConvertFrom-Epoch $nowE
    $need = @()
    foreach ($k in (Get-TotMonthKeys $now)) {
        $r = Get-TotMonthRange $k; $c = $script:Tot.months[$k]
        $go = [bool]$All -or $null -eq $c
        if (-not $go -and $nowE -lt $r[1]) { $go = ($nowE - [int64]$c.at) -gt 600 }               # this month: again after 10 min
        if (-not $go -and $nowE -ge $r[1] -and [int64]$c.at -lt $r[1] + 2 * 86400) { $go = $true }   # a closed month: once more 2 days after it ended
        if ($go) { $need += [pscustomobject]@{ key = $k; from = $r[0]; to = [math]::Min($r[1], $nowE) } }
    }
    if ($need.Count -eq 0) { return $false }
    $tok = $null
    if (-not $script:TotFixtureDir) { try { $tok = [string](Get-TessieToken) } catch {}; if (-not $tok) { $script:Tot.status = 'No Tessie token: showing what is saved'; Render-TotStatus; return $false } }
    $sh = [hashtable]::Synchronized(@{ done = 0; total = $need.Count; cancel = $false })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:TotFetchBlock).AddArgument($need).AddArgument($tok).AddArgument($ApiBase).AddArgument([string]$script:VIN).AddArgument($script:TotFixtureDir).AddArgument('TessDesk/' + $AppVersion + ' (totals)').AddArgument($sh)
    $tok = $null
    $script:Tot.shared = $sh
    $script:Tot.job = [pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke(); started = Get-Date; total = $need.Count; all = [bool]$All }
    $script:TotTick.Start(); Render-TotStatus
    return $true
}
function Stop-TotLoad { if ($null -ne $script:Tot.shared) { $script:Tot.shared.cancel = $true } }
function Complete-TotLoad {
    $j = $script:Tot.job; $res = @(); $err = $null
    try { $res = @(@($j.ps.EndInvoke($j.async))[0]) } catch { $err = $_.Exception.Message }
    try { $j.ps.Dispose() } catch {}
    $sh = $script:Tot.shared; $script:Tot.job = $null; $script:Tot.shared = $null
    $nowE = Get-EpochNow; $ok = 0; $bad = @()
    foreach ($r in $res) { if ($null -eq $r) { continue }; if ($r.ok) { $script:Tot.months[[string]$r.key] = [pscustomobject]@{ at = $nowE; rows = @($r.rows) }; $ok++ } else { $bad += [string]$r.key } }
    if ($ok -gt 0) { $script:Tot.loadedAt = $nowE; Save-TotCache }
    $secs = [math]::Round(((Get-Date) - $j.started).TotalSeconds, 1)
    $script:Tot.lastLoad = [ordered]@{ months = $j.total; ok = $ok; failed = $bad; stopped = [bool]$sh.cancel; seconds = $secs; err = $err }
    if ($sh.cancel) { $script:Tot.status = ('Stopped at {0} / {1} months, showing what is saved' -f $ok, $j.total) }
    elseif ($bad.Count -gt 0 -or $err) { $script:Tot.status = ('Could not load {0} month(s), showing what is saved' -f [math]::Max(1, $bad.Count)) }
    else { $script:Tot.status = '' }
    Write-WidgetLog ('totals: loaded ' + $ok + ' / ' + $j.total + ' months in ' + $secs + ' s' + $(if ($sh.cancel) { ' (stopped)' } else { '' }))
    $script:Tot.rowsKey = ''
    try { Update-TotBtnSum } catch {}
    if ($script:TotPricedDirty) { Save-TotCache }
    if ($ui.TotOverlay.Visibility -eq 'Visible') { Render-Totals } else { Render-TotStatus }
}
$script:TotTick = New-Object System.Windows.Threading.DispatcherTimer
$script:TotTick.Interval = [TimeSpan]::FromMilliseconds(150)
$script:TotTick.Add_Tick({
    try {
        $j = $script:Tot.job
        if ($null -eq $j) { $script:TotTick.Stop(); return }
        if ($script:TotStopAt -gt 0 -and [int]$script:Tot.shared.done -ge $script:TotStopAt) { $script:TotStopAt = 0; Stop-TotLoad }
        if ($j.async.IsCompleted) { $script:TotTick.Stop(); Complete-TotLoad } else { Render-TotStatus }
    } catch { $script:TotTick.Stop(); $script:Tot.job = $null; Write-WidgetLog ('totals tick: ' + $_.Exception.Message) }
})
function Get-TotNight {
    param([int64]$Epoch)
    $t = ConvertFrom-Epoch $Epoch
    if ((Test-HourIn $t.Hour $NW_START $NW_END) -and $t.Hour -lt $NW_START) { return $t.Date.AddDays(-1) }
    return $t.Date
}
function Test-TotHomeLoc { param([string]$Loc) return ($Loc -and $Loc.Trim().StartsWith($TotHome, [System.StringComparison]::OrdinalIgnoreCase)) }
function Get-TotRows {
    # every cached charge, normalized and priced once per cache change (+ the live charge in progress)
    $nowE = Get-EpochNow
    $cur = $null; try { $cur = Get-CurrentLive $script:State } catch {}
    $key = [string]$script:Tot.loadedAt + '|' + @($script:Tot.months.Keys).Count + '|' + $(if ($null -ne $cur) { [string]$cur.startEpoch + ':' + [string]$cur.kwhAdded } else { '-' })
    if ($key -eq $script:Tot.rowsKey) { return $script:Tot.rows }
    $seen = @{}; $rows = New-Object System.Collections.ArrayList
    foreach ($k in ($script:Tot.months.Keys | Sort-Object)) {
        foreach ($c in @($script:Tot.months[$k].rows)) {
            if ($null -eq $c) { continue }
            $id = $(if ($null -ne $c.id) { [string]$c.id } else { [string]$c.s }); if ($seen.ContainsKey($id)) { continue }; $seen[$id] = $true
            $s = [int64]$c.s; $e = [int64]$c.e; if ($s -gt $nowE) { continue }
            $add = [double](Get-Val $c.add 0.0); $used = [double](Get-Val $c.used 0.0)
            $wall = $(if ($used -gt 0) { $used } else { $add / $EFFICIENCY })
            $fast = ([bool]$c.sc -or [bool]$c.fc -or ($null -ne $c.kw -and [double]$c.kw -gt 25))
            $isHome = (Test-TotHomeLoc ([string]$c.loc)) -and -not $fast
            $paid = $null; if (-not $isHome -and $fast -and $null -ne $c.cost -and [double]$c.cost -gt 0) { $paid = [double]$c.cost }
            $pk = $id + ':' + $s + ':' + $e + ':' + $wall
            if ($null -ne $paid) { $cost = $paid } elseif ($script:TotPriced.ContainsKey($pk)) { $cost = [double]$script:TotPriced[$pk] } else { $cost = (Get-SpreadCost $s $e $wall)[0]; $script:TotPriced[$pk] = $cost; $script:TotPricedDirty = $true }
            [void]$rows.Add([pscustomobject]@{ s = $s; e = $e; add = $add; wall = $wall; cost = $cost; home = $isHome; fast = $fast; paid = ($null -ne $paid); day = (Get-TotNight $s); loc = [string]$c.loc; live = $false })
        }
    }
    if ($null -ne $cur) {
        $cs = [int64]$cur.startEpoch; $ce = [int64](Get-Val $cur.lastEpoch $nowE)
        $dup = $false; foreach ($r in $rows) { if ($r.s -lt $ce + 300 -and $cs -lt $r.e + 300) { $dup = $true; break } }
        $fastNow = ($null -ne $script:State.lastCar -and [bool]$script:State.lastCar.fastCharger)
        if (-not $dup) {
            $add = [double](Get-Val $cur.kwhAdded 0.0); $wall = [double](Get-Val $cur.kwhWall ($add / $EFFICIENCY))
            [void]$rows.Add([pscustomobject]@{ s = $cs; e = $ce; add = $add; wall = $wall; cost = [double](Get-Val $cur.costUsdAllIn 0.0); home = (-not $fastNow); fast = $fastNow; paid = $false; day = (Get-TotNight $cs); loc = 'live'; live = $true })
        }
    }
    $script:Tot.rows = @($rows | Sort-Object s); $script:Tot.rowsKey = $key
    return $script:Tot.rows
}
function Get-TotAgg {
    param($Rows)
    $hk = 0.0; $hc = 0.0; $hw = 0.0; $nights = @{}; $an = 0; $ak = 0.0; $ac = 0.0; $live = $false
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        if ($r.live) { $live = $true }
        if ($r.home) { $hk += $r.add; $hc += $r.cost; $hw += $r.wall; $nights[$r.day.ToString('yyyy-MM-dd')] = $true }
        else { $an++; $ak += $r.add; $ac += $r.cost }
    }
    return [pscustomobject]@{ kwh = [math]::Round($hk, 1); cost = [math]::Round($hc, 2); nights = $nights.Count; cpk = $(if ($hw -gt 0) { [math]::Round(100 * $hc / $hw, 1) } else { $null })
        awayN = $an; awayKwh = [math]::Round($ak, 1); awayCost = [math]::Round($ac, 2); grand = [math]::Round($hc + $ac, 2); live = $live }
}
function Get-TotView {
    $rows = @(Get-TotRows); $now = (ConvertFrom-Epoch (Get-EpochNow)).Date
    $wk0 = $now.AddDays(-(([int]$now.DayOfWeek + 6) % 7)); $mo0 = New-Object DateTime $now.Year, $now.Month, 1; $yr0 = New-Object DateTime $now.Year, 1, 1
    $inR = { param($a, $z) @($rows | Where-Object { $_.day -ge $a -and $_.day -le $z }) }
    $months = @()
    for ($m = 1; $m -le $now.Month; $m++) {
        $a = New-Object DateTime $now.Year, $m, 1; $z = $a.AddMonths(1).AddDays(-1)
        $mr = & $inR $a $z
        $months += [pscustomobject]@{ key = $a.ToString('yyyy-MM'); name = $a.ToString('MMMM', $Inv); short = $a.ToString('MMM', $Inv); current = ($m -eq $now.Month); agg = (Get-TotAgg $mr); rows = $mr; cached = $script:Tot.months.ContainsKey($a.ToString('yyyy-MM')) }
    }
    return [pscustomobject]@{ now = $now; weekStart = $wk0; weekEnd = $wk0.AddDays(6)
        week = (Get-TotAgg (& $inR $wk0 $now)); month = (Get-TotAgg (& $inR $mo0 $now)); year = (Get-TotAgg (& $inR $yr0 $now)); months = $months; count = $rows.Count
        first = $(if ($rows.Count) { $rows[0].day } else { $null }) }
}
function New-TotTb {
    param([string]$Text, [double]$Size = 11, [string]$Col = '#FFE6E6E6', [bool]$Bold = $false, [string]$Align = 'Left')
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.FontSize = $Size
    $t.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Col))
    if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::Bold }
    $t.HorizontalAlignment = $Align; $t.VerticalAlignment = 'Center'; $t.TextTrimming = 'CharacterEllipsis'; return $t
}
function Format-TotCents { param($v) if ($null -eq $v) { return '--' }; return ([double]$v).ToString('0.0', $Inv) + [char]0x00A2 }
function Format-TotKwh { param([double]$v) if ($v -ge 1000) { return $v.ToString('#,0', $Inv) + ' kWh' }; return $v.ToString('0.0', $Inv) + ' kWh' }
function New-TotGrid {
    param([double[]]$Cols)
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in $Cols) { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $(if ($w -le 0) { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) } else { New-Object System.Windows.GridLength $w }); [void]$g.ColumnDefinitions.Add($cd) }
    return $g
}
function Add-TotCell { param($G, $El, [int]$Col) [System.Windows.Controls.Grid]::SetColumn($El, $Col); [void]$G.Children.Add($El) }
function Render-TotStatus {
    $j = $script:Tot.job
    if ($null -ne $j) {
        $d = [int]$script:Tot.shared.done; $ui.TotStatus.Text = ('Loading charge history {0} / {1} months' -f $d, $j.total)
        $ui.TotStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFD27A'))
        Set-Visible $ui.TotStop $true; $ui.TotRefresh.IsEnabled = $false
        if ($null -ne $script:TotBusySeen) { $t = $ui.TotStatus.Text; if ($script:TotBusySeen.Count -eq 0 -or $script:TotBusySeen[-1] -ne $t) { [void]$script:TotBusySeen.Add($t) } }
    } else {
        Set-Visible $ui.TotStop $false; $ui.TotRefresh.IsEnabled = $true
        $v = $script:Tot.view; $n = $(if ($null -ne $v) { $v.count } else { 0 })
        $txt = $script:Tot.status
        if (-not $txt) { $txt = $(if ($script:Tot.loadedAt -gt 0) { 'Updated ' + (ConvertFrom-Epoch $script:Tot.loadedAt).ToString('ddd h:mm tt', $Inv) + ' · ' + $n + ' charges from Tessie' } else { 'Not loaded yet' }) }
        $ui.TotStatus.Text = $txt
        $ui.TotStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($script:Tot.status) { '#FFFFD27A' } else { '#FF888888' })))
    }
}
function New-TotPeriod {
    param([string]$Label, [string]$Sub, $A)
    $bd = New-Object System.Windows.Controls.Border; $bd.CornerRadius = 9; $bd.Padding = '7,5,6,6'; $bd.Margin = '0,0,4,0'
    $bd.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF1E1E1E'))
    $sp = New-Object System.Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-TotTb $Label 9 '#FF49DF93' $true))
    [void]$sp.Children.Add((New-TotTb $Sub 8.5 '#FF888888'))
    [void]$sp.Children.Add((New-TotTb (Format-Money $A.cost) 17 '#FFFFFFFF' $true))
    [void]$sp.Children.Add((New-TotTb (Format-TotKwh $A.kwh) 10 '#FFCCCCCC'))
    [void]$sp.Children.Add((New-TotTb ('{0} night{1}' -f $A.nights, $(if ($A.nights -eq 1) { '' } else { 's' })) 9.5 '#FFAAAAAA'))
    [void]$sp.Children.Add((New-TotTb ('avg ' + (Format-TotCents $A.cpk) + '/kWh') 9.5 '#FFAAAAAA'))
    if ($A.awayN -gt 0) { [void]$sp.Children.Add((New-TotTb ('+ ' + (Format-Money $A.awayCost) + ' away') 9 '#FFFFB547')); [void]$sp.Children.Add((New-TotTb ('Total ' + (Format-Money $A.grand)) 9.5 '#FFFFFFFF' $true)) }
    $bd.Child = $sp; return $bd
}
function New-TotNightLines {
    param($Rows)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '10,2,4,6'
    $g = @($Rows | Where-Object { $_.home } | Group-Object { $_.day.ToString('yyyy-MM-dd') } | Sort-Object Name)
    foreach ($x in $g) {
        $d = [datetime]::ParseExact($x.Name, 'yyyy-MM-dd', $Inv); $k = 0.0; $c = 0.0; foreach ($r in $x.Group) { $k += $r.add; $c += $r.cost }
        $ln = New-TotGrid @(0, 62, 52)
        Add-TotCell $ln (New-TotTb ($d.ToString('ddd MMM d', $Inv) + $(if ($x.Count -gt 1) { ' · ' + $x.Count + ' charges' } else { '' }) + $(if (@($x.Group | Where-Object { $_.live }).Count) { ' · live' } else { '' })) 9.5 '#FFBBBBBB') 0
        Add-TotCell $ln (New-TotTb (Format-TotKwh $k) 9.5 '#FF999999' $false 'Right') 1
        Add-TotCell $ln (New-TotTb (Format-Money $c) 9.5 '#FFE6E6E6' $true 'Right') 2
        [void]$sp.Children.Add($ln)
    }
    foreach ($r in @($Rows | Where-Object { -not $_.home } | Sort-Object s)) {
        $ln = New-TotGrid @(0, 62, 52)
        $place = ([string]$r.loc -split ',')[0]; if ($place.Length -gt 22) { $place = $place.Substring(0, 22) }
        Add-TotCell $ln (New-TotTb ((ConvertFrom-Epoch $r.s).ToString('ddd MMM d', $Inv) + ' · ' + $(if ($r.fast) { 'Supercharger' } else { 'Away' }) + ' · ' + $place) 9.5 '#FFFFB547') 0
        Add-TotCell $ln (New-TotTb (Format-TotKwh $r.add) 9.5 '#FF999999' $false 'Right') 1
        Add-TotCell $ln (New-TotTb ((Format-Money $r.cost) + $(if ($r.paid) { ' paid' } else { ' est.' })) 9.5 '#FFFFB547' $true 'Right') 2
        [void]$sp.Children.Add($ln)
    }
    if ($sp.Children.Count -eq 0) { [void]$sp.Children.Add((New-TotTb 'No charges this month' 9.5 '#FF777777')) }
    return $sp
}
function Render-Totals {
    $v = Get-TotView; $script:Tot.view = $v
    $B0 = $ui.TotBody; $B0.Children.Clear()
    # 1) running totals
    $pg = New-TotGrid @(0, 0, 0)
    Add-TotCell $pg (New-TotPeriod 'THIS WEEK' ($v.weekStart.ToString('MMM d', $Inv) + ' to ' + $v.weekEnd.ToString('MMM d', $Inv)) $v.week) 0
    Add-TotCell $pg (New-TotPeriod 'THIS MONTH' ($v.now.ToString('MMMM', $Inv) + ' so far') $v.month) 1
    Add-TotCell $pg (New-TotPeriod 'THIS YEAR' ([string]$v.now.Year + ' so far') $v.year) 2
    [void]$B0.Children.Add($pg)
    $note = New-TotTb ('Home at ' + $TotHome + ' · what you paid at the all-in PSO rate') 9 '#FF888888'; $note.Margin = '2,5,0,8'; $note.TextWrapping = 'Wrap'; [void]$B0.Children.Add($note)
    # 2) month by month
    $hd = New-TotGrid @(0, 70, 58, 40, 14); $hd.Margin = '8,0,8,3'
    Add-TotCell $hd (New-TotTb 'MONTH BY MONTH' 9 '#FF49DF93' $true) 0
    Add-TotCell $hd (New-TotTb 'kWh' 9 '#FF888888' $false 'Right') 1; Add-TotCell $hd (New-TotTb 'Cost' 9 '#FF888888' $false 'Right') 2; Add-TotCell $hd (New-TotTb 'Nights' 9 '#FF888888' $false 'Right') 3
    [void]$B0.Children.Add($hd)
    foreach ($mo in @($v.months | Sort-Object key -Descending)) {
        $a = $mo.agg; $isOpen = [bool]$script:Tot.open[$mo.key]
        $btn = New-Object System.Windows.Controls.Button; $btn.Style = $window.FindResource('TotRowBtn'); $btn.Padding = '8,4,6,4'; $btn.Margin = '0,0,0,3'; $btn.Tag = $mo.key
        if ($mo.current) { $btn.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF49DF93')) }
        $rg = New-TotGrid @(0, 70, 58, 40, 14)
        $nm = $mo.name + $(if ($mo.current) { ' so far' } else { '' })
        $empty = ($a.kwh -le 0 -and $a.awayN -eq 0)
        Add-TotCell $rg (New-TotTb $nm 11 $(if ($empty) { '#FF777777' } else { '#FFFFFFFF' }) $true) 0
        if ($empty) { Add-TotCell $rg (New-TotTb $(if ($mo.cached) { 'no charges' } else { 'not loaded' }) 9.5 '#FF666666' $false 'Right') 2 }
        else {
            Add-TotCell $rg (New-TotTb (Format-TotKwh $a.kwh) 10 '#FFBBBBBB' $false 'Right') 1
            Add-TotCell $rg (New-TotTb (Format-Money $a.grand) 11 '#FFFFFFFF' $true 'Right') 2
            Add-TotCell $rg (New-TotTb ([string]$a.nights) 10 '#FFBBBBBB' $false 'Right') 3
            Add-TotCell $rg (New-TotTb $(if ($isOpen) { [string][char]0xE70E } else { [string][char]0xE70D }) 8 '#FF888888' $false 'Right') 4
            $rg.Children[$rg.Children.Count - 1].FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
        }
        $btn.Content = $rg
        if (-not $empty) { $btn.Add_Click({ param($s9, $e9) $k9 = [string]$s9.Tag; $script:Tot.open[$k9] = -not [bool]$script:Tot.open[$k9]; Render-Totals }) }
        [void]$B0.Children.Add($btn)
        if ($isOpen -and -not $empty) {
            if ($a.awayN -gt 0) { $al = New-TotTb ('Home ' + (Format-Money $a.cost) + ' + away ' + (Format-Money $a.awayCost) + ' (' + $a.awayN + ')') 9 '#FFFFB547'; $al.Margin = '10,0,0,1'; [void]$B0.Children.Add($al) }
            [void]$B0.Children.Add((New-TotNightLines $mo.rows))
        }
    }
    # 3) year line + the rule
    $y = $v.year
    $yl = New-TotTb ([string]$v.now.Year + ' total: ' + (Format-TotKwh $y.kwh) + ' at home, ' + (Format-Money $y.cost) + $(if ($y.awayN -gt 0) { ' + ' + (Format-Money $y.awayCost) + ' away = ' + (Format-Money $y.grand) } else { '' })) 10 '#FFFFFFFF' $true
    $yl.Margin = '2,6,0,4'; $yl.TextWrapping = 'Wrap'; [void]$B0.Children.Add($yl)
    $rule = New-TotTb ('Home = ' + $TotHome + '. Home cost is priced by the minute at the all-in PSO rate (energy + fuel charge): 6.23' + [char]0x00A2 + '/kWh from 11 PM to 6 AM, the day rate at other hours. Supercharger and away charges use the amount Tessie reports as paid. A charge counts on the night it started (weeks run Monday to Sunday). The phone app uses the same rule.') 9 '#FF777777'
    $rule.TextWrapping = 'Wrap'; $rule.TextTrimming = 'None'; $rule.Margin = '2,2,0,4'; [void]$B0.Children.Add($rule)
    Render-TotStatus
}
function Update-TotBtnSum {
    if ($script:Tot.months.Count -eq 0) { $ui.TotBtnSum.Text = ''; return }
    $v = Get-TotView; $script:Tot.view = $v
    $ui.TotBtnSum.Text = ($v.now.ToString('MMM', $Inv) + ' ' + (Format-Money $v.month.grand) + ' · ' + [string]$v.now.Year + ' ' + (Format-Money $v.year.grand))
}
function Show-Totals {
    $t0 = Get-Date
    if ($script:Tot.months.Count -eq 0) { Load-TotCache }
    $ui.TotScroll.MaxHeight = [math]::Max(300, $window.ActualHeight - 120)
    Render-Totals; Set-Visible $ui.TotOverlay $true
    $script:Tot.openMs = [math]::Round(((Get-Date) - $t0).TotalMilliseconds)
    if ($script:TotPricedDirty) { Save-TotCache }
    [void](Start-TotLoad)
}
function Close-Totals { Set-Visible $ui.TotOverlay $false; Stop-TotLoad }
function Invoke-TotKey { param([string]$Key) if ($ui.TotOverlay.Visibility -eq 'Visible' -and $Key -eq 'Escape') { Close-Totals; return $true }; return $false }
$ui.TotBtn.Add_Click({ try { Show-Totals } catch { Write-WidgetLog ('totals: ' + $_.Exception.Message) } })
$ui.TotClose.Add_Click({ Close-Totals })
$ui.TotStop.Add_Click({ Stop-TotLoad })
$ui.TotRefresh.Add_Click({ try { $script:Tot.status = ''; [void](Start-TotLoad -All) } catch { Write-WidgetLog ('totals refresh: ' + $_.Exception.Message) } })
$ui.TotOverlay.Add_MouseLeftButtonUp({ param($s9, $e9) if ($e9.OriginalSource -eq $ui.TotOverlay) { Close-Totals } })
$window.Add_PreviewKeyDown({ param($s9, $e9) try { if (Invoke-TotKey ([string]$e9.Key)) { $e9.Handled = $true } } catch {} })
try { Load-TotCache } catch {}

# Show local/cached data immediately; the first Tessie call runs once the window is on screen.
try {
    $script:View = Build-FallbackView (Read-LocalJson) 'Live: connecting…' 'starting'
    Set-CtlResult 'idle' $(if ($CTL_DRYRUN) { 'DRY RUN: buttons are simulated, nothing is sent' } else { 'Ready' })
    Render-View
} catch { Write-WidgetLog ('initial render failed: ' + $_.Exception.Message) }

# ---------------- -SelfTest (DRY RUN only: nothing is sent to the car) ----------------
$script:SelfSteps = $null
function Start-SelfTest {
    $dir = $Snapshot; if (-not $dir) { $dir = Join-Path $scriptDir 'shots' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:SelfDir = $dir
    $script:SelfAnswers = New-Object System.Collections.Queue
    $script:ConfirmHook = { param($m) if ($script:SelfAnswers.Count -gt 0) { return [bool]$script:SelfAnswers.Dequeue() } return $false }
    $script:SelfRec = [ordered]@{ dryRun = $CTL_DRYRUN; steps = @(); tireCases = @(); shots = @() }
    $car = Get-CtlCar
    $script:SelfRec.carAtStart = [ordered]@{ chargingState = $car.chargingState; amps = $car.ampsReq; ampsMax = $car.ampsMax; seats = @($car.seatFL, $car.seatFR, $car.seatRL, $car.seatRC, $car.seatRR); wheel = $car.wheelOn; defrost = $car.defrostOn; cop = $car.cop; copFanOnly = $car.copFanOnly; locked = $car.locked; windowsOpen = $car.windowsOpen; climateOn = $car.climateOn; tempC = $car.tempC; units = $car.tempUnits; limit = $car.limitPct; limitMin = $car.limitMin; limitMax = $car.limitMax; socPct = $car.socPct; rangeMi = $car.rangeMi }
    # tire logic cases (rec 42.1 PSI = 2.9 bar; thresholds from config: yellow > 5%, red > 10%)
    foreach ($c in @(@(42.8, $false, $false, 42.1, 'green'), @(44.5, $false, $false, 42.1, 'yellow-high'), @(39.5, $false, $false, 42.1, 'yellow-low'),
                     @(37.0, $false, $false, 42.1, 'red-low'), @(46.6, $false, $false, 42.1, 'red-high'), @(42.0, $true, $false, 42.1, 'yellow-low'),
                     @(42.0, $false, $true, 42.1, 'red-low'), @(35.0, $true, $false, 42.1, 'red-low'), @(49.0, $false, $false, $null, 'red-high'),
                     @(47.0, $false, $false, $null, 'yellow-high'), @(44.0, $null, $null, $null, 'green'), @(37.0, $false, $false, $null, 'red-low'))) {
        $st = Get-TireStatus $c[0] $c[1] $c[2] $c[3]; $got = $(if ($st.dir) { $st.level + '-' + $st.dir } else { $st.level })
        $script:SelfRec.tireCases += ('{0} psi soft={1} hard={2} rec={3} -> {4} (expect {5}) {6}' -f $c[0], $c[1], $c[2], $c[3], $got, $c[4], $(if ($got -eq $c[4]) { 'PASS' } else { 'FAIL' }))
    }
    $script:SelfSteps = New-Object System.Collections.Queue
    $add = { param($name, $answers, $sb) $script:SelfSteps.Enqueue([pscustomobject]@{ name = $name; answers = $answers; run = $sb }) }
    # ---- v4.3.3 steps (DRY RUN: nothing is sent to the car, nothing announced) ----
    $script:Shot433 = { param($n, [switch]$Full) $f = 'tessdesk-v433-' + $n + '.png'; if ($Full) { Save-RootPng (Join-Path $script:SelfDir $f) -Full } else { Save-RootPng (Join-Path $script:SelfDir $f) }; $script:SelfRec.shots += $f }
    $script:SelfRec.v433 = [ordered]@{ carTrunkOpen = $car.trunkOpen; carSentry = $car.sentry; frunkButton = ($null -ne $ui['FrunkBtn']) }
    & $add 'v4.3.3 paused-session energy: unit cases' @() {
        $s = [pscustomobject]@{ kwhAdded = 3.0; startEpoch = 1000; lastEpoch = 2000 }
        $cases = @(
            @('counter kept running after a 45-min pause (v4.3.2: new session = 3.0 kWh counted twice)', (Test-NewLiveSession $s 3.4 45), $false),
            @('counter kept running after a 2-min pause', (Test-NewLiveSession $s 3.1 2), $false),
            @('counter reset (re-plugged): 0.0 after 3.0', (Test-NewLiveSession $s 0.0 1), $true),
            @('gap over 12 h', (Test-NewLiveSession $s 3.5 800), $true),
            @('no session yet', (Test-NewLiveSession $null 1.0 0), $true))
        $script:SelfRec.v433.newSessionCases = @($cases | ForEach-Object { '{0} -> new={1} (expect {2}) {3}' -f $_[0], $_[1], $_[2], $(if ($_[1] -eq $_[2]) { 'PASS' } else { 'FAIL' }) })
        $p = [pscustomobject]@{ kwhAdded = 2.0; endEpoch = 10000 }
        $cc = @(
            @('joined 10 min later at 7.2 kW, counter 3.2 = 2.0 + 1.2 carried', (Get-PartCarryKwh $p ([pscustomobject]@{ startEpoch = 10600; kwhAtStart = 3.2; kwAtStart = 7.2 })), 2.0),
            @('joined 10 min later at 7.2 kW, counter 1.2 = reset', (Get-PartCarryKwh $p ([pscustomobject]@{ startEpoch = 10600; kwhAtStart = 1.2; kwAtStart = 7.2 })), 0.0),
            @('started fresh (counter 0.0)', (Get-PartCarryKwh $p ([pscustomobject]@{ startEpoch = 10016; kwhAtStart = 0.0; kwAtStart = 7.2 })), 0.0),
            @('joined 2 h later at 4 kW, counter 12.0 (older than the gap = carried)', (Get-PartCarryKwh $p ([pscustomobject]@{ startEpoch = 17200; kwhAtStart = 12.0; kwAtStart = 4.0 })), 2.0),
            @('joined 2 h later at 4 kW, counter 6.0 (fits the gap = reset)', (Get-PartCarryKwh $p ([pscustomobject]@{ startEpoch = 17200; kwhAtStart = 6.0; kwAtStart = 4.0 })), 0.0),
            @('13 h later', (Get-PartCarryKwh $p ([pscustomobject]@{ startEpoch = 56800; kwhAtStart = 40.0; kwAtStart = 7.2 })), 0.0),
            @('old record without kwhAtStart', (Get-PartCarryKwh $p ([pscustomobject]@{ startEpoch = 10600 })), 0.0))
        $script:SelfRec.v433.carryCases = @($cc | ForEach-Object { '{0} -> carried {1} kWh (expect {2}) {3}' -f $_[0], $_[1], $_[2], $(if ([math]::Abs([double]$_[1] - [double]$_[2]) -lt 0.001) { 'PASS' } else { 'FAIL' }) })
        $script:SelfRec.v433.lastChargeNow = (Get-LastChargeShown $script:State)
        $script:SelfRec.v433.carryFixNow = $script:CarryFix }
    & $add 'v4.3.3 drives card (cached Tessie /drives read) + snapshot' @() {
        if ($null -eq $script:State.drives) { $tk = $null; try { $tk = Get-TessieToken } catch {}; if ($tk) { Update-DrivesCache $tk (Get-EpochNow) } }
        Render-View; $window.UpdateLayout()
        $script:SelfRec.v433.drives = @(@(Get-Val $script:State.drives @()) | Select-Object -First 5)
        $script:SelfRec.v433.locationHistory = @(Get-LocationHistory | Select-Object -First 6)
        $script:SelfRec.v433.historyMap = Get-HistoryMapUrl
        $script:SelfRec.v433.drivesNote = $ui.DrivesNote.Text + ' | ' + $script:DrivesNote
        if ($ui.DrivesList.Children.Count -gt 0) { $ui.DrivesList.Children[0].RaiseEvent((New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left) -Property @{ RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent })); $script:SelfRec.v433.driveClickUrl = $script:LastOpenUrl }
        $ui.HistMapBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $script:SelfRec.v433.mapButtonUrl = $script:LastOpenUrl
        & $script:Shot433 'full' -Full
        $ui.DrivesCard.BringIntoView(); $window.UpdateLayout(); & $script:Shot433 'drives' }
    & $add 'v4.3.3 controls snapshot (trunk + sentry state)' @() { Render-Controls; $ui.CtlCard.BringIntoView(); $window.UpdateLayout(); $script:SelfRec.v433.buttons = [ordered]@{ trunk = $ui.TrunkTxt.Text + ' / ' + $ui.TrunkSub.Text; sentry = $ui.SentryTxt.Text + ' / ' + $ui.SentrySub.Text; sentryBorder = $ui.SentryBtn.BorderBrush.ToString() }; & $script:Shot433 'controls' }
    & $add 'v4.3.3 OPEN TRUNK: Are you sure? snapshot' @() { [void](Show-ConfirmOverlay 'Are you sure?' 'Open the rear trunk?' 'Open trunk' 'Cancel' -NoWait); $window.UpdateLayout(); & $script:Shot433 'trunk-confirm'; Set-Visible $ui.ConfirmOverlay $false }
    & $add 'v4.3.3 OPEN TRUNK: answer NO' @($false) { $n0 = @($script:CtlLog).Count; Invoke-Trunk; $script:SelfRec.v433.trunkNo = [ordered]@{ result = $script:CtlResultText; commands = @($script:CtlLog).Count - $n0 } }
    & $add 'v4.3.3 OPEN TRUNK: answer YES (DRY RUN)' @($true) { Invoke-Trunk }
    & $add 'v4.3.3 trunk result' @() { $script:SelfRec.v433.trunkYes = [ordered]@{ result = $script:CtlResultText; button = $ui.TrunkTxt.Text + ' / ' + $ui.TrunkSub.Text; cmd = @($script:CtlLog | Where-Object { $_.cmd -eq 'activate_rear_trunk' }).Count }; & $script:Shot433 'trunk-open'; $script:CtlOverride.Remove('trunkOpen'); Render-Controls }
    & $add 'v4.3.3 SENTRY: confirm snapshot' @() { $on = [bool]$car.sentry; [void](Show-ConfirmOverlay $(if ($on) { 'Turn Sentry Mode OFF?' } else { 'Turn Sentry Mode ON?' }) $(if ($on) { 'The car stops watching and recording its surroundings.' } else { 'The car watches and records its surroundings (uses some battery).' }) $(if ($on) { 'Turn off' } else { 'Turn on' }) 'Cancel' -NoWait); $window.UpdateLayout(); & $script:Shot433 'sentry-confirm'; Set-Visible $ui.ConfirmOverlay $false }
    & $add 'v4.3.3 SENTRY: answer NO' @($false) { $n0 = @($script:CtlLog).Count; Invoke-SentryToggle; $script:SelfRec.v433.sentryNo = [ordered]@{ result = $script:CtlResultText; commands = @($script:CtlLog).Count - $n0 } }
    & $add 'v4.3.3 SENTRY: answer YES (DRY RUN)' @($true) { Invoke-SentryToggle }
    & $add 'v4.3.3 sentry result' @() { $script:SelfRec.v433.sentryYes = [ordered]@{ result = $script:CtlResultText; button = $ui.SentryTxt.Text + ' / ' + $ui.SentrySub.Text; cmds = @($script:CtlLog | Where-Object { $_.cmd -like '*_sentry' } | ForEach-Object { $_.cmd }) }; & $script:Shot433 'sentry-toggled'; $script:CtlOverride.Remove('sentry'); Render-Controls; $ui.CtlCard.BringIntoView(); $window.UpdateLayout(); & $script:Shot433 'controls-after' }
    & $add 'v4.3.3 update: check a local test feed (v9.9.8 = newer than this copy)' @() {
        $feed = Join-Path $script:SelfDir 'updfeed'; New-Item -ItemType Directory -Path $feed -Force | Out-Null
        $me = [System.IO.File]::ReadAllText((Join-Path $scriptDir 'TessDesk.ps1'))
        $t4 = $me.Replace("`$AppVersion = '" + $AppVersion + "'", "`$AppVersion = '9.9.8'")
        $enc = New-Object System.Text.UTF8Encoding($true); [System.IO.File]::WriteAllText((Join-Path $feed 'TessDesk.ps1'), $t4, $enc)
        $sha = (Get-FileHash -Algorithm SHA256 (Join-Path $feed 'TessDesk.ps1')).Hash.ToLowerInvariant()
        $uri = ([System.Uri](Join-Path $feed 'TessDesk.ps1')).AbsoluteUri
        [ordered]@{ app = 'TessDesk'; version = '9.9.8'; date = 'test'; desktop = [ordered]@{ files = @([ordered]@{ name = 'TessDesk.ps1'; url = $uri; sha256 = $sha }) } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $feed 'version.json') -Encoding UTF8
        $script:UpdUrlOverride = ([System.Uri](Join-Path $feed 'version.json')).AbsoluteUri
        $script:SelfRec.v433.updateBefore = [ordered]@{ state = $script:Upd.state; buttonVisible = ($ui.UpdateBtn.Visibility -eq 'Visible') }
        Start-UpdateCheck -Force }
    & $add 'v4.3.3 update: button shows UPDATE AVAILABLE · v4.3.4' @() { $window.UpdateLayout(); $script:SelfRec.v433.updateAvailable = [ordered]@{ state = $script:Upd.state; latest = $script:Upd.latest; button = $ui.UpdateTxt.Text; sub = $ui.UpdateSub.Text; visible = ($ui.UpdateBtn.Visibility -eq 'Visible') }; & $script:Shot433 'update-available' }
    & $add 'v4.3.3 update: bad checksum is refused (nothing changed)' @() { $script:UpdInfoGood = $script:UpdInfo; $bad = $script:UpdInfo | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $bad.desktop.files[0].sha256 = ('0' * 64); $script:UpdInfo = $bad; Invoke-UpdateApply }
    & $add 'v4.3.3 update: refused result' @() { $script:SelfRec.v433.updateBadSha = [ordered]@{ state = $script:Upd.state; note = $script:Upd.note; button = $ui.UpdateTxt.Text; fileStillCurrent = ([System.IO.File]::ReadAllText((Join-Path $scriptDir 'TessDesk.ps1')) -match ("\`$AppVersion = '" + $AppVersion + "'")) }; & $script:Shot433 'update-refused'; $script:UpdInfo = $script:UpdInfoGood; $script:Upd.state = 'available'; Render-Update }
    & $add 'v4.3.3 update: one click (download, back up, install; restart skipped in self-test)' @() { $ui.UpdateBtn.RaiseEvent((New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left) -Property @{ RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent })) }
    & $add 'v4.3.3 update: installed result' @() {
        $window.UpdateLayout()
        $now = [System.IO.File]::ReadAllText((Join-Path $scriptDir 'TessDesk.ps1'))
        $script:SelfRec.v433.updateInstalled = [ordered]@{ state = $script:Upd.state; note = $script:Upd.note; button = $ui.UpdateTxt.Text; restart = $script:Upd.restart; backup = $script:Upd.backup
            backupFiles = @(Get-ChildItem -LiteralPath $script:Upd.backup | ForEach-Object { $_.Name }); installedIs434 = ($now -match "\`$AppVersion = '9.9.8'")
            backupIs433 = ([System.IO.File]::ReadAllText((Join-Path $script:Upd.backup 'TessDesk.ps1')) -match ("\`$AppVersion = '" + $AppVersion + "'")) }
        & $script:Shot433 'update-installed' }
    & $add 'v4.3.5 flash pause: clamp 0.3 -> 1.0, 31 -> 30.0, 2.7 -> 2.5' @() { $script:SelfRec.v435 = [ordered]@{}; $ui.FlashPause.Text = '0.3'; $a = Get-FlashPause; $ui.FlashPause.Text = '31'; $b = Get-FlashPause; $ui.FlashPause.Text = '2.7'; $c2 = Get-FlashPause; $script:SelfRec.v435.clamp = @($a, $b, $c2) }
    & $add 'v4.3.5 flash x4, pause 1.0 s (fire and go, DRY RUN)' @($true) { $script:V435n0 = @($script:CtlLog).Count; $ui.FlashCount.Text = '4'; $ui.FlashPause.Text = '1.0'; Invoke-FlashLights; $script:FlashWaitFor = 99 }
    & $add 'v4.3.5 flash x4 result' @() { $window.UpdateLayout(); $L = @(@($script:CtlLog)[$script:V435n0..(@($script:CtlLog).Count - 1)] | Where-Object { $_.cmd -eq 'flash' })
        $script:SelfRec.v435.fast = [ordered]@{ urls = @($L | ForEach-Object { $_.url }); rtts = @($script:Flash.rtts); gap = (Get-FlashGap); stats = $ui.FlashStats.Text; statsVisible = ($ui.FlashStats.Visibility -eq 'Visible'); result = $script:CtlResultText
            noOverlap = $(if (@($script:Flash.sends).Count -ge 2) { $ok2 = $true; for ($k = 1; $k -lt @($script:Flash.sends).Count; $k++) { if ((($script:Flash.sends[$k] - $script:Flash.sends[$k - 1]).TotalSeconds) -lt ($script:Flash.rtts[$k - 1] - 0.1)) { $ok2 = $false } }; $ok2 } else { $null }) }
        & $script:Shot433 'v435-flash-stats' }
    & $add 'v4.3.5 flash x2, pause 3.0 s (waits for completion, DRY RUN)' @($true) { $script:V435n1 = @($script:CtlLog).Count; $ui.FlashCount.Text = '2'; $ui.FlashPause.Text = '3.0'; Invoke-FlashLights; $script:FlashWaitFor = 2 }
    & $add 'v4.3.5 flash x2 progress snapshot' @() { $window.UpdateLayout(); $script:SelfRec.v435.slowProgress = $ui.FlashSub.Text; & $script:Shot433 'v435-flash-progress'; $script:FlashWaitFor = 99 }
    & $add 'v4.3.5 flash x2 result' @() { $window.UpdateLayout(); $L = @(@($script:CtlLog)[$script:V435n1..(@($script:CtlLog).Count - 1)] | Where-Object { $_.cmd -eq 'flash' }); $script:SelfRec.v435.slow = [ordered]@{ urls = @($L | ForEach-Object { $_.url }); gap = (Get-FlashGap); stats = $ui.FlashStats.Text; result = $script:CtlResultText; defaults = @($FLASH_COUNT, $FLASH_PAUSE) }; $ui.FlashPause.Text = $FLASH_PAUSE.ToString('0.0', $Inv) }
    & $add 'v4.3.5 sessions: mock window, 3 parts (pause + replug, one after 6 AM)' @() {
        $ws = Get-ChargeWindowStart ((Get-EpochNow) - 86400); if ($null -eq $ws) { $t0 = (Get-LocalNow).Date.AddDays(-1).AddHours($NW_START); $ws = ConvertTo-EpochLocal $t0 }
        $mk = { param($a, $b, $k) $wall = $k / $EFFICIENCY; $c = (Get-SpreadCost $a $b $wall $a $b)[0]; [pscustomobject]@{ source = 'tessie'; startEpoch = [int64]$a; endEpoch = [int64]$b; kwhAdded = $k; kwhWall = $wall; costUsdAllIn = [math]::Round($c, 4); home = $null; fast = $false; kwhAtStart = 0.0 } }
        $parts = @((& $mk ($ws) ($ws + 1800) 3.1), (& $mk ($ws + 3 * 3600) ($ws + 4 * 3600 + 900) 7.4), (& $mk ($ws + 7 * 3600 + 1800) ($ws + 8 * 3600) 2.2))
        $mock = [pscustomobject]@{ recentSessions = $parts; wasCharging = $false; session = $null; lastCar = $null }
        $ms = Get-WindowSessions $mock; $mw = Get-HomeWindowCharge $mock
        $script:SelfRec.v435.sessionsMock = [ordered]@{ header = $ms.header; lines = $ms.lines; sumOfLines = $ms.sumCostUsd; windowCost = $mw.costUsdAllIn; sumMatches = ([math]::Abs($ms.sumCostUsd - $mw.costUsdAllIn) -lt 0.0001)
            perPartCost = @($parts | ForEach-Object { $_.costUsdAllIn }); after6 = [ordered]@{ kwh = $mw.kwhAfter6; cost = $mw.costAfter6 } }
        Render-Sessions $ms; $ui.RowsCard.BringIntoView(); $window.UpdateLayout(); & $script:Shot433 'v435-sessions-mock' }
    & $add 'v4.3.5 sessions: cached real read (state.json, Tessie cache)' @() {
        $rs = Get-WindowSessions $script:State; $rw = Get-HomeWindowCharge $script:State
        $script:SelfRec.v435.sessionsReal = [ordered]@{ header = $(if ($rs) { $rs.header } else { $null }); lines = $(if ($rs) { $rs.lines } else { @() }); sumOfLines = $(if ($rs) { $rs.sumCostUsd } else { $null }); windowCost = $(if ($rw) { $rw.costUsdAllIn } else { $null }); hero = $ui.HeroCost.Text }
        Render-View; $ui.RowsCard.BringIntoView(); $window.UpdateLayout(); & $script:Shot433 'v435-sessions-real' }
    & $add 'v4.3.6 sessions rule: Tessie wins for completed, live in progress wins, nothing twice' @() {
        $b0 = ConvertTo-EpochLocal ((Get-Date).Date.AddDays(-1).AddHours(23))
        $L = [pscustomobject]@{ source = 'live'; startEpoch = $b0 + 240; endEpoch = $b0 + 13620; kwhAdded = 12.8; kwhWall = 14.2; costUsdAllIn = 0.89 }
        $T1 = [pscustomobject]@{ source = 'tessie'; startEpoch = $b0 + 200; endEpoch = $b0 + 600; kwhAdded = 0.2; kwhWall = 0.25; costUsdAllIn = 0.02 }
        $T2 = [pscustomobject]@{ source = 'tessie'; startEpoch = $b0 + 900; endEpoch = $b0 + 13700; kwhAdded = 13.6; kwhWall = 15.1; costUsdAllIn = 0.90 }
        $r = @(); foreach ($x in @($L, $T1, $T2)) { $r = Merge-Sessions $r $x }
        $c = @(Select-CountedSessions $r)
        $only = @(Select-CountedSessions @($L))
        $script:SelfRec.v436 = [ordered]@{ stored = $r.Count; counted = @($c | ForEach-Object { [string]$_.source + ':' + $_.kwhAdded }); liveAloneCounts = ($only.Count -eq 1)
            ok = ($r.Count -eq 3 -and @($r | Where-Object { $_.source -eq 'tessie' }).Count -eq 2 -and $c.Count -eq 2 -and @($c | Where-Object { $_.source -eq 'live' }).Count -eq 0 -and $only.Count -eq 1) }
        if (-not $script:SelfRec.v436.ok) { throw ('sessions rule wrong: ' + ($script:SelfRec.v436 | ConvertTo-Json -Compress)) }
    }
    & $add 'v4.3.6 sessions: tonight from a fresh Tessie /charges read (GET only) + this state' @() {
        $tok = Get-TessieToken; Resolve-Vin $tok | Out-Null
        $list = @(Get-ChargeSessions $tok)
        $st = $script:State; $r = @($st.recentSessions); foreach ($x in $list) { $r = Merge-Sessions $r $x }
        $st2 = New-State $st @{ recentSessions = $r }
        $ws = Get-WindowSessions $st2; $w = Get-HomeWindowCharge $st2
        $script:SelfRec.v436.real = [ordered]@{ header = $ws.header; lines = @($ws.lines); sumCost = $ws.sumCostUsd; sumKwh = $ws.sumKwh; windowCost = $ws.windowCostUsd
            parts = @(@($w.parts) | ForEach-Object { [string]$_.source + ' ' + $_.start + '-' + $_.end + ' ' + $_.kwhAdded }) }
    }
    & $add 'v4.3.7 REMEMBER: save the spot (test copy of desk_window_layout.json)' @() {
        $script:SelfDeskPath = Join-Path $script:SelfDir 'desk_window_layout.json'
        if (Test-Path -LiteralPath $DeskLayoutPath) { Copy-Item -LiteralPath $DeskLayoutPath -Destination $script:SelfDeskPath -Force } else { [ordered]@{ saved = ''; note = 'test'; windows = @() } | ConvertTo-Json | Set-Content -LiteralPath $script:SelfDeskPath -Encoding UTF8 }
        $before = @(@((Get-Content -LiteralPath $script:SelfDeskPath -Raw | ConvertFrom-Json).windows) | Where-Object { $null -ne $_ -and $_.name -ne 'TESSDESK' } | ForEach-Object { ($_ | ConvertTo-Json -Compress -Depth 4) })
        $script:SelfRec.v437 = [ordered]@{ startedFrom = $script:StartedFrom }
        Invoke-KeepSpot; $window.UpdateLayout(); & $script:Shot433 'v437-remember-toast'
        $d = Get-Content -LiteralPath $script:SelfDeskPath -Raw | ConvertFrom-Json
        $after = @(@($d.windows) | Where-Object { $null -ne $_ -and $_.name -ne 'TESSDESK' } | ForEach-Object { ($_ | ConvertTo-Json -Compress -Depth 4) })
        $script:SelfRec.v437.remember = [ordered]@{ toast = $ui.WToastTxt.Text; button = $ui.KeepTxt.Text; kept = $script:KeptSpot; entry = @(@($d.windows) | Where-Object { $_.name -eq 'TESSDESK' })[0]
            otherEntriesUnchanged = (($before -join '|') -eq ($after -join '|')); others = @(@($d.windows) | Where-Object { $_.name -ne 'TESSDESK' } | ForEach-Object { $_.name }); note = $d.note; layoutFile = $script:KeepLast.layoutFile }
        $script:SelfRec.v435 = $(if ($script:SelfRec.v435) { $script:SelfRec.v435 } else { [ordered]@{} })
    }
    & $add 'v4.3.5 RESTORE: move away, then back' @() {
        $window.Left = $window.Left - 300; $window.Top = $window.Top + 25; $moved = [ordered]@{ left = $window.Left; top = $window.Top }
        Invoke-RestoreSpot
        $script:SelfRec.v435.restore = [ordered]@{ moved = $moved; after = [ordered]@{ left = $window.Left; top = $window.Top; width = $window.Width; height = $window.Height }; toast = $ui.WToastTxt.Text
            backAtKept = ([math]::Abs($window.Left - [double]$script:KeptSpot.left) -lt 1 -and [math]::Abs($window.Top - [double]$script:KeptSpot.top) -lt 1); button = $ui.RestoreTxt.Text; from = $script:KeepLast.from } }
    & $add 'v4.3.7 SHARE panel + each target (recorded, nothing opened or sent)' @() {
        $clip0 = $null; try { if ([System.Windows.Clipboard]::ContainsText()) { $clip0 = [System.Windows.Clipboard]::GetText() } } catch {}
        Open-ShareOverlay; $window.UpdateLayout(); & $script:Shot433 'v437-share'
        Invoke-Share 'phone'; $window.UpdateLayout(); & $script:Shot433 'v437-share-qr'
        $qrOk = ($null -ne $ui.ShQr.Source -and $ui.ShQr.Source.PixelWidth -gt 50)
        foreach ($k in 'messenger', 'text', 'email', 'copy') { Open-ShareOverlay; Invoke-Share $k }
        $clipNow = $null; try { $clipNow = [System.Windows.Clipboard]::GetText() } catch {}
        try { if ($null -ne $clip0) { [System.Windows.Clipboard]::SetText($clip0) } else { [System.Windows.Clipboard]::Clear() } } catch {}
        $tok = ''; try { $tok = [string](Get-TessieToken) } catch {}
        $all = (@($script:ShareLog | ForEach-Object { $_.uri }) -join ' ') + ' ' + $clipNow
        $script:SelfRec.v437.share = [ordered]@{ log = @($script:ShareLog); qrShown = $qrOk; copied = $clipNow; launchedAny = (@($script:ShareLog | Where-Object { $_.launched }).Count -gt 0)
            noToken = ($tok.Length -lt 8 -or -not $all.Contains($tok)); onlyOurLinks = (-not ($all -match 'token|Bearer|vin=')); toast = $ui.WToastTxt.Text }
    }
    & $add 'v4.3.7 UPDATE pop-up (pretend v9.9.9 is out; Later)' @() {
        $u0 = [ordered]@{ state = $script:Upd.state; latest = $script:Upd.latest }
        $script:Upd.state = 'available'; $script:Upd.latest = '9.9.9'
        Show-UpdatePrompt -NoWait; $window.UpdateLayout(); & $script:Shot433 'v437-update-popup'
        $script:SelfRec.v437.updatePopup = [ordered]@{ msg = $ui.ConfirmMsg.Text; sub = $ui.ConfirmSub.Text; yes = $ui.ConfirmYesTxt.Text; no = $ui.ConfirmNoTxt.Text; visible = ($ui.ConfirmOverlay.Visibility -eq 'Visible') }
        Close-ConfirmOverlay $false
        $script:Upd.state = $u0.state; $script:Upd.latest = $u0.latest; Render-Update
    }
    & $add 'v4.3.8 update triggers: launch, 5 min throttle, wake, silent retries, Later until next launch' @() {
        $r = [ordered]@{}
        $s0 = [ordered]@{ last = $script:UpdLastTry; launched = $script:UpdLaunched; later = $script:UpdLaterFor; state = $script:Upd.state; latest = $script:Upd.latest }
        $script:UpdTriggers = @(); $script:UpdLaunched = $false; $script:UpdLastTry = 0; $script:Upd.state = 'current'; $script:Upd.latest = $null
        $r.focusBeforeLaunch = Request-UpdateCheck 'focus'
        $r.launch = Request-UpdateCheck 'launch'
        $r.launchArmsRetry = [bool]$script:UpdRetry.active
        $r.launchAgain = Request-UpdateCheck 'launch'
        $r.focusRightAfter = Request-UpdateCheck 'focus'
        $script:UpdLastTry = (Get-EpochNow) - 240; $r.restoreAt4min = Request-UpdateCheck 'restore'
        $script:UpdLastTry = (Get-EpochNow) - 301; $r.restoreAt5min = Request-UpdateCheck 'restore'
        $r.focusAfterThat = Request-UpdateCheck 'focus'
        $script:UpdLastTry = (Get-EpochNow) - 301; $r.resume = Request-UpdateCheck 'resume'
        $script:UpdRetry.active = $true; $script:UpdRetry.i = 0; $script:UpdRetry.reason = 'launch'
        $r.retries = @(); for ($k = 0; $k -lt 6; $k++) { Register-UpdCheckFailure; $r.retries += ('fail ' + ($k + 1) + ': retry=' + $script:UpdRetry.active + ' next=' + $(if ($script:UpdRetryTimer.IsEnabled) { [string]$script:UpdRetryTimer.Interval.TotalSeconds + ' s' } else { 'none' })) }
        $script:UpdRetryTimer.Stop()
        $r.retryWindowSec = ($UpdRetryDelays | Measure-Object -Sum).Sum
        $script:UpdRetry.active = $true; Register-UpdCheckSuccess; $r.successStopsRetry = (-not $script:UpdRetry.active -and -not $script:UpdRetryTimer.IsEnabled)
        $script:PwWatch.lastTick = (Get-EpochNow) - 600; $script:UpdLastTry = (Get-EpochNow) - 301
        $r.wakeByClockGap = Test-UpdResume
        $r.noWakeNextTick = (-not (Test-UpdResume))
        try { Start-UpdResumeWatch; $script:PwTimer.Stop(); $r.wakeListener = [ordered]@{ started = $script:PwWatch.listener; error = $script:PwWatch.error; resumesSoFar = $(if ('TdPowerWatch' -as [type]) { [TdPowerWatch]::Resumes } else { $null }) } } catch { $r.wakeListener = 'failed: ' + $_.Exception.Message }
        $script:Upd.state = 'available'; $script:Upd.latest = '9.9.9'
        $r.promptAllowedBefore = Test-UpdPromptAllowed
        Set-UpdLater
        $r.promptAllowedAfterLater = Test-UpdPromptAllowed
        $script:Upd.latest = '9.9.10'; $r.promptAllowedForNewerVersion = Test-UpdPromptAllowed
        $r.laterSavedToConfig = ([System.IO.File]::ReadAllText($ConfigPath) -match 'updSnooze|UpdLaterFor')
        $r.triggers = @($script:UpdTriggers | ForEach-Object { $_.reason + ': ' + $_.action })
        $script:UpdLastTry = $s0.last; $script:UpdLaunched = $s0.launched; $script:UpdLaterFor = $s0.later; $script:Upd.state = $s0.state; $script:Upd.latest = $s0.latest; $script:UpdRetry.active = $false; Render-Update
        $r.footer = $ui.FooterVersion.Text; $r.appVersion = $AppVersion
        $window.UpdateLayout(); & $script:Shot433 'v438-window' -Full
        $script:SelfRec.v438 = $r
    }
    if ($Quick433) { return (Start-SelfTimer) }
    # ---- v4.3.2 steps (forced/mock state, DRY RUN: nothing is sent to the car, nothing announced) ----
    $script:Shot432 = { param($n, [switch]$Full) $f = 'tessdesk-v432-' + $n + '.png'; if ($Full) { Save-RootPng (Join-Path $script:SelfDir $f) -Full } else { Save-RootPng (Join-Path $script:SelfDir $f) }; $script:SelfRec.shots += $f }
    $script:SelfRec.v432 = [ordered]@{}
    & $add 'v4.3.2 last charge = 11 PM-11 AM home window' @() { $script:SelfRec.v432.lastChargeWindow = (Get-HomeWindowCharge $script:State); $script:SelfRec.v432.heroNow = ($ui.HeroCost.Text + ' · ' + $ui.HeroSub.Text + ' · ' + $ui.KwhLabel.Text) }
    & $add 'v4.3.2 glow RED (forced: not plugged in)' @() { $script:GlowForce = 'red'; Render-View; $window.UpdateLayout(); & $script:Shot432 'glow-red'; & $script:Shot432 'glow-red-full' -Full; $script:SelfRec.v432.red = [ordered]@{ glow = $script:GlowMode; theme = $script:Theme.Name; frame = $ui.GlowFrame.BorderBrush.ToString(); opacity = $ui.GlowFrame.Opacity; animated = $ui.GlowFrame.HasAnimatedProperties } }
    & $add 'v4.3.2 glow GREEN (forced: plugged in, not charging)' @() { $script:GlowForce = 'green'; Render-View; $window.UpdateLayout(); & $script:Shot432 'glow-green'; $script:SelfRec.v432.green = [ordered]@{ glow = $script:GlowMode; theme = $script:Theme.Name; frame = $ui.GlowFrame.BorderBrush.ToString(); opacity = $ui.GlowFrame.Opacity; animated = $ui.GlowFrame.HasAnimatedProperties } }
    & $add 'v4.3.2 glow PULSE (forced: charging) - frames over one 3.5 s cycle' @() {
        $script:GlowForce = 'pulse'; Render-View; $window.UpdateLayout()
        $script:SelfRec.v432.pulse = [ordered]@{ glow = $script:GlowMode; animated = $ui.GlowFrame.HasAnimatedProperties; frames = @() }
        $ui.GlowFrame.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        for ($i = 0; $i -lt 12; $i++) { $o = 0.18 + 0.82 * (0.5 + 0.5 * [math]::Cos(2 * [math]::PI * $i / 12)); $ui.GlowFrame.Opacity = $o; $window.UpdateLayout(); & $script:Shot432 ('pulse-{0:00}' -f $i); $script:SelfRec.v432.pulse.frames += [math]::Round($o, 2) }
        $script:GlowMode = $null; Set-Glow 'pulse'; $script:SelfRec.v432.pulse.restarted = $ui.GlowFrame.HasAnimatedProperties }
    & $add 'v4.3.2 charging stops -> solid green (no pulse)' @() { $script:GlowForce = 'green'; Render-View; $script:SelfRec.v432.afterStop = [ordered]@{ glow = $script:GlowMode; animated = $ui.GlowFrame.HasAnimatedProperties; opacity = $ui.GlowFrame.Opacity } }
    & $add 'v4.3.2 seat heated -> RED (driver 2, rear left 1; override only, not sent)' @() {
        Set-CtlOverride 'seatFL' 2; Set-CtlOverride 'seatRL' 1; Render-Controls; $window.UpdateLayout()
        $script:SelfRec.v432.seats = [ordered]@{ flBg = $ui.SeatFL.Background.ToString(); frBg = $ui.SeatFR.Background.ToString(); frBorder = $ui.SeatFR.BorderBrush.ToString(); rlBg = $ui.SeatRL.Background.ToString(); fl = $ui.SeatFLN.Text; fr = $ui.SeatFRN.Text }
        & $script:Shot432 'seat-red-full' -Full
        $script:CtlOverride.Remove('seatFL'); $script:CtlOverride.Remove('seatRL'); Render-Controls }
    & $add 'v4.3.2 flash lights: count 25 -> 20, 0 -> 1, confirm NO' @($false) { $ui.FlashCount.Text = '25'; $a = Get-FlashCount; $ui.FlashCount.Text = '0'; $b = Get-FlashCount; $script:SelfRec.v432.flashClamp = @($a, $b); $ui.FlashCount.Text = '3'; Invoke-FlashLights; $script:SelfRec.v432.flashNo = [ordered]@{ running = $script:Flash.running; result = $script:CtlResultText } }
    & $add 'v4.3.2 flash lights: confirm box snapshot' @() { $ui.FlashCount.Text = '5'; [void](Show-ConfirmOverlay 'Flash the lights 5 times?' '5 flashes, about 2.5 seconds apart. Tap Stop to end early.' 'Flash' 'Cancel' -NoWait); $window.UpdateLayout(); & $script:Shot432 'flash-confirm'; Set-Visible $ui.ConfirmOverlay $false }
    & $add 'v4.3.2 flash lights x5: answer YES (DRY RUN)' @($true) { $ui.FlashCount.Text = '5'; Invoke-FlashLights; $script:FlashWaitFor = 2 }
    & $add 'v4.3.2 flash progress snapshot (Flashing 2 of 5) + Stop' @() { $script:FlashWaitFor = $null; $window.UpdateLayout(); $script:SelfRec.v432.flashProgress = ($ui.FlashSub.Text + ' | ' + $ui.FlashBtnTxt.Text); & $script:Shot432 'flash-progress'; Invoke-FlashLights; $script:SelfRec.v432.flashStopped = [ordered]@{ done = $script:Flash.done; total = $script:Flash.total; running = $script:Flash.running } }
    & $add 'v4.3.2 flash lights x2 full run: answer YES (DRY RUN)' @($true) { $ui.FlashCount.Text = '2'; Invoke-FlashLights; $script:FlashWaitFor = 99 }
    & $add 'v4.3.2 flash result + glow back to live state' @() { $script:SelfRec.v432.flashFull = [ordered]@{ done = $script:Flash.done; result = $script:CtlResultText; flashCommands = @($script:CtlLog | Where-Object { $_.cmd -eq 'flash' }).Count }; $script:GlowForce = $null; Render-View; & $script:Shot432 'controls'; $script:SelfRec.v432.liveGlow = $script:GlowMode }
    if ($Quick432) { return (Start-SelfTimer) }
    & $add 'snapshot ready' @() { Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-controls-ready.png'); $script:SelfRec.shots += 'tessdesk-v43-controls-ready.png' }
    & $add 'ALEXA toggle on (self-test: Voice Monkey mocked, every announcement DRY RUN)' @() { Set-AlexaToggle $true $false }
    & $add 'lock button (car locked): unlock, answer NO' @($false) { Invoke-LockToggle }
    & $add 'lock button: unlock, answer YES' @($true) { Invoke-LockToggle; Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-controls-sending.png'); $script:SelfRec.shots += 'tessdesk-v43-controls-sending.png' }
    & $add 'lock button again (now unlocked): lock, no prompt' @() { Invoke-LockToggle }
    & $add 'vent windows: answer NO' @($false) { Invoke-Vent }
    & $add 'vent windows: answer YES' @($true) { Invoke-Vent }
    & $add 'close windows' @() { Invoke-CloseWindows }
    & $add 'climate toggle (on)' @() { Invoke-ClimateToggle }
    & $add 'climate toggle (off)' @() { Invoke-ClimateToggle }
    & $add 'temp up x2 (debounced)' @() { Step-Temp 1; Step-Temp 1 }
    & $add 'wait for temp send' @() { }
    & $add 'charge limit drag to 85: answer NO' @($false) { Show-DragPct 85; Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-limit-dragging.png'); $script:SelfRec.shots += 'tessdesk-v43-limit-dragging.png'; End-Drag $true }
    & $add 'charge limit drag to 85: answer YES' @($true) { Show-DragPct 85; End-Drag $true }
    & $add 'charge limit 130 -> clamped to max: answer YES' @($true) { [void](Request-ChargeLimit 130) }
    & $add 'charge limit 20 -> clamped to min: answer YES' @($true) { [void](Request-ChargeLimit 20) }
    & $add 'start charging (state-aware)' @() { Invoke-ChargeStart }
    & $add 'stop charging: answer NO' @($false) { Set-CtlOverride 'chargingState' 'Charging'; Render-Controls; Invoke-ChargeStop }
    & $add 'stop charging: answer YES' @($true) { Invoke-ChargeStop }
    & $add 'start charging again (now stopped)' @() { Render-Controls; Invoke-ChargeStart }
    & $add 'amps drag to 12: answer NO' @($false) { Show-DragAmps 12; Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-amps-dragging.png'); $script:SelfRec.shots += 'tessdesk-v43-amps-dragging.png'; End-AmpsDrag $true }
    & $add 'amps drag to 12: answer YES' @($true) { Show-DragAmps 12; End-AmpsDrag $true }
    & $add 'amps 60 -> clamped to charger max: answer YES' @($true) { [void](Request-ChargeAmps 60) }
    & $add 'amps 2 -> clamped to min: answer YES' @($true) { [void](Request-ChargeAmps 2) }
    & $add 'amps from x: far right / far left' @() { $script:SelfRec.ampsFromX = @((Get-AmpsFromX 400), (Get-AmpsFromX -50), (Get-AmpsBounds)) }
    & $add 'HEAT on (set_temperatures + start_climate sequence)' @() { Invoke-Heat }
    & $add 'wait heat sequence' @() { }
    & $add 'HEAT shown + off' @() { $script:SelfRec.heatShown = ($ui.HeatTxt.Text + ' · ' + $ui.HeatSub.Text + ' | ' + $ui.ClimTxt.Text); Invoke-Heat }
    & $add 'defrost on' @() { Invoke-Defrost }
    & $add 'defrost off' @() { Invoke-Defrost }
    & $add 'cabin overheat protection cycle 1' @() { Invoke-CopCycle }
    & $add 'cabin overheat protection cycle 2' @() { Invoke-CopCycle }
    & $add 'cabin overheat protection cycle 3' @() { Invoke-CopCycle }
    & $add 'driver seat tap x2 (-> 2), rear left tap x1, debounced' @() { Step-Seat 'FL'; Step-Seat 'FL'; Step-Seat 'RL' }
    & $add 'wait seats' @() { }
    & $add 'passenger seat tap x4 (-> off again, no change)' @() { Step-Seat 'FR'; Step-Seat 'FR'; Step-Seat 'FR'; Step-Seat 'FR' }
    & $add 'wait seats 2' @() { }
    & $add 'steering wheel heat toggle' @() { Invoke-WheelToggle }
    & $add 'snapshot seats + climate' @() { $script:SelfRec.seatsShown = [ordered]@{ fl = $ui.SeatFLN.Text; fr = $ui.SeatFRN.Text; rl = $ui.SeatRLN.Text; rc = $ui.SeatRCN.Text; rr = $ui.SeatRRN.Text; wheel = $ui.WheelLvl.Text }; Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-seats-full.png') -Full; $script:SelfRec.shots += 'tessdesk-v43-seats-full.png' }
    & $add 'windows green: open state then closed state' @() {
        Set-CtlOverride 'windowsOpen' $true; Render-Controls; $o = ($ui.VentBtn.BorderBrush.ToString() -eq (T 'Green').ToString()); $o2 = ($ui.CloseWinBtn.BorderBrush.ToString() -eq (T 'Green').ToString())
        Set-CtlOverride 'windowsOpen' $false; Render-Controls; $c = ($ui.CloseWinBtn.BorderBrush.ToString() -eq (T 'Green').ToString()); $c2 = ($ui.VentBtn.BorderBrush.ToString() -eq (T 'Green').ToString())
        $script:SelfRec.windowsGreen = ('open: vent green={0} closed green={1} | closed: closed green={2} vent green={3} -> {4}' -f $o, $o2, $c, $c2, $(if ($o -and -not $o2 -and $c -and -not $c2) { 'PASS' } else { 'FAIL' })) }
    & $add 'alexa failure wording (simulated failed command, not sent)' @() {
        $fj = [pscustomobject]@{ cmd = 'lock'; query = @{}; okText = 'Locked'; ann = 'Your Tesla is now locked.' }
        $script:SelfRec.alexaFailText = @((Get-ActionSpeech $fj $false 'car did not confirm'), (Get-ActionSpeech ([pscustomobject]@{ cmd = 'start_climate'; query = @{}; okText = ''; ann = $null }) $false 'timed out'))
        [void](Send-Announcement $script:SelfRec.alexaFailText[0] 'action-failed-sim') }
    & $add 'scheduled announcements: register (dry-run tasks), verify, run each once -DryRun, clean up' @() {
        $sch = [ordered]@{ cost = [ordered]@{ enabled = $true; times = @([ordered]@{ time = '07:15'; days = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri') }, [ordered]@{ time = '21:30'; days = @('Sun') }) }
                           tires = [ordered]@{ enabled = $true; times = @([ordered]@{ time = '08:00'; days = @('Sat') }) }
                           status = [ordered]@{ enabled = $true; times = @([ordered]@{ time = '18:45'; days = @('Mon', 'Wed', 'Fri') }) } }
        $rec = [ordered]@{}
        try {
            Write-WidgetStatus
            $reg = @(Sync-AnnounceTasks $sch 'TessDesk SelfTest Announce' -DryRunTasks)
            $rec.registered = $reg
            $rec.readBack = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'TessDesk SelfTest Announce *' } | ForEach-Object { [ordered]@{ task = $_.TaskName; start = [string]$_.Triggers[0].StartBoundary; days = [string]$_.Triggers[0].DaysOfWeek; weeks = [string]$_.Triggers[0].WeeksInterval; args = [string]$_.Actions[0].Arguments; user = [string]$_.Principal.UserId } })
            $rec.texts = [ordered]@{}
            foreach ($k in 'cost', 'tires', 'status') { $rec.texts[$k] = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AnnounceScript -Type $k -DryRun -ConfigPath $ConfigPath 2>&1 | ForEach-Object { [string]$_ }) }
        } catch { $rec.error = $_.Exception.Message }
        $null = Sync-AnnounceTasks ([ordered]@{}) 'TessDesk SelfTest Announce' -DryRunTasks
        $rec.leftAfterCleanup = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'TessDesk SelfTest Announce *' }).Count
        $script:SelfRec.schedules = $rec }
    & $add 'snapshot after commands' @() { Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-controls-after.png'); $script:SelfRec.shots += 'tessdesk-v43-controls-after.png' }
    & $add 'tire warning demo + reminder (dry run)' @() {
        $saved = $script:View.tires
        $demo = $saved.PSObject.Copy(); $demo.fl = 35.2; $demo.soft_fl = $true; $demo.fr = 39.6; $demo.rr = 44.6
        $script:View.tires = $demo; Render-View
        $script:SelfRec.tireDemo = [ordered]@{ shown = [ordered]@{ fl = (Get-TextOf $ui.PsiFL); fr = (Get-TextOf $ui.PsiFR); rl = (Get-TextOf $ui.PsiRL); rr = (Get-TextOf $ui.PsiRR) }; flags = $script:TireFlags; pulsing = @($script:PulseEls).Count }
        # reminder: schedule 8 h out (DRY RUN task), verify in Task Scheduler, run the sender once in -DryRun (prints the composed message), verify cleanup
        $rr = [ordered]@{ ready = (Test-RemindersReady); allowed = [bool]$script:RemAllowed }
        $script:RemindHook = { param($m) return 8 }
        try {
            $r = Request-TireReminder
            if ($null -eq $r) { $rr.note = $script:RemindLastNote } else {
                $rr.id = $r.id; $rr.due = $r.due.ToString('s'); $rr.subject = $r.message.subject; $rr.button = $ui.RemindTxt.Text
                $tk = Get-ScheduledTask -TaskName $r.task -ErrorAction SilentlyContinue
                $rr.taskRegistered = ($null -ne $tk); if ($null -ne $tk) { $rr.taskState = [string]$tk.State; $rr.taskTrigger = [string]$tk.Triggers[0].StartBoundary; $rr.taskUser = [string]$tk.Principal.UserId; $rr.taskArgs = [string]$tk.Actions[0].Arguments }
                Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-tires-warning-demo.png'); $script:SelfRec.shots += 'tessdesk-v43-tires-warning-demo.png'
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemindScript -Id $r.id -DryRun -ConfigPath $ConfigPath 2>&1
                $rr.senderDryRunOutput = @($out | ForEach-Object { [string]$_ })
                $rr.taskAfterSender = ($null -ne (Get-ScheduledTask -TaskName $r.task -ErrorAction SilentlyContinue))
                $rr.jsonAfterSender = (Test-Path -LiteralPath $r.json)
                if ($rr.taskAfterSender) { Unregister-ScheduledTask -TaskName $r.task -Confirm:$false -ErrorAction SilentlyContinue }
            }
        } catch { $rr.error = $_.Exception.Message }
        $script:SelfRec.reminder = $rr
        $script:RemindHook = $null; $ui.RemindTxt.Text = 'REMIND ME TO GET AIR'
        $script:View.tires = $saved; Render-View
    }
    & $add 'reminder Setup: pick channels (email, Alexa, Windows notification, calendar), remind in 1 h, sender -DryRun' @() {
        $rs = [ordered]@{}
        try {
            $script:RemSetupHook = @{ email = $true; text = $false; alexa = $true; toast = $true; calendar = $true }
            $rs.saved = @(Show-ReminderSetup); $rs.channels = @(Get-RemChannels); $rs.channelText = (Get-ChannelText)
            $rs.ready = [ordered]@{}; foreach ($c in $RemChannelNames.Keys) { $rs.ready[$c] = (Test-RemChanReady $c) }
            $script:RemindHook = { param($m) return 1 }
            $r = Request-TireReminder
            if ($null -ne $r) {
                $rs.jobChannels = @((Get-Content -LiteralPath $r.json -Raw | ConvertFrom-Json).channels); $rs.speech = (Get-Content -LiteralPath $r.json -Raw | ConvertFrom-Json).speech
                $rs.ics = $(if ($null -ne $script:LastRemCal) { [ordered]@{ file = (Split-Path -Leaf $script:LastRemCal.ics); exists = (Test-Path -LiteralPath $script:LastRemCal.ics); gcalPrefix = $script:LastRemCal.gcal.Substring(0, 60) } } else { $null })
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemindScript -Id $r.id -DryRun -ConfigPath $ConfigPath 2>&1
                $rs.senderDryRunOutput = @($out | ForEach-Object { [string]$_ })
                $rs.taskAfterSender = ($null -ne (Get-ScheduledTask -TaskName $r.task -ErrorAction SilentlyContinue))
                if ($rs.taskAfterSender) { Unregister-ScheduledTask -TaskName $r.task -Confirm:$false -ErrorAction SilentlyContinue }
            } else { $rs.note = $script:RemindLastNote }
        } catch { $rs.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber }
        $script:RemSetupHook = $null; $script:RemindHook = $null; $ui.RemindTxt.Text = 'REMIND ME TO GET AIR'
        $script:SelfRec.reminderSetup = $rs
    }
    & $add 'COMPACT layout: fits the window, no scrolling' @() {
        $cr = [ordered]@{}
        try {
            $cr.fullBefore = (Get-LayoutCheck)
            Set-LayoutMode 'compact' $false; $window.UpdateLayout()
            $cr.scale = $script:CompactScale; $cr.button = [string]$ui.LayoutBtn.Content; $cr.compact = (Get-LayoutCheck)
            $g = $ui.MainGrid; $cr.mainGridBottom = [math]::Round($g.TranslatePoint([System.Windows.Point]::new(0, $g.ActualHeight), $ui.RootBorder).Y, 1); $cr.rootHeight = [math]::Round($ui.RootBorder.ActualHeight, 1)
            Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-compact.png'); $script:SelfRec.shots += 'tessdesk-v43-compact.png'
            Set-LayoutMode 'full' $false; $window.UpdateLayout(); $cr.backToFull = [string]$ui.LayoutBtn.Content; $cr.fullAfter = (Get-LayoutCheck)
        } catch { $cr.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber }
        $script:SelfRec.compact = $cr
    }
    # ---- v4.3 steps (DRY RUN: nothing is sent to the car or to Voice Monkey) ----
    & $add 'v4.3 vertical slider: drag 68 -> 74 -> 80 -> 83 (mid-drag snapshot), confirm box, answer NO' @($false) {
        $script:Dragging = $true; $vs = @()
        foreach ($p in 68, 74, 80, 83) { Show-DragPct $p; $window.UpdateLayout(); $vs += ('{0} -> thumb "{1} {2}" top={3} | big "{4}"' -f $p, $ui.VPct.Text, $ui.VMi.Text, [System.Windows.Controls.Canvas]::GetTop($ui.VThumb), $ui.DragVal.Text) }
        Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-slider-middrag.png'); $script:SelfRec.shots += 'tessdesk-v43-slider-middrag.png'
        $script:SelfRec.vSliderDrag = $vs
        $script:Dragging = $false; Set-Visible $ui.DragBox $false; Set-Visible $ui.BattTop $true; $script:VPend = 83; Set-VThumb 83
        [void](Show-ConfirmOverlay 'Set to 83%?' ('Charge limit 83% / ' + (Format-Miles (Get-MilesAt 83))) 'Confirm' 'Cancel' -NoWait)
        Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-slider-confirm.png'); $script:SelfRec.shots += 'tessdesk-v43-slider-confirm.png'
        $script:SelfRec.vSliderConfirm = ($ui.ConfirmMsg.Text + ' | ' + $ui.ConfirmSub.Text + ' | ' + $ui.ConfirmNoTxt.Text + ' | ' + $ui.ConfirmYesTxt.Text)
        Set-Visible $ui.ConfirmOverlay $false
        $script:DragPct = 83; End-Drag $true
        $script:SelfRec.vSliderAfterCancel = ($ui.VPct.Text + ' ' + $ui.VMi.Text)
    }
    & $add 'v4.3 mouse wheel +2 over the slider (debounced 0.9 s), answer NO' @($false) { Step-VLimit 1; Step-VLimit 1; $script:SelfRec.wheelShown = ($ui.VPct.Text + ' ' + $ui.VMi.Text) }
    & $add 'wait wheel' @() { }
    & $add 'v4.3 RATE STATUS: charging peak (red) / day (amber) / off-peak (green), not charging (neutral), Full + Compact' @() {
        $pr = [ordered]@{}
        $shot = { param($n) $f = 'tessdesk-v43-rate-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
        $cases = @(@('charging-peak', 'Charging', [datetime]::new(2026, 9, 30, 15, 48, 0)), @('charging-day', 'Charging', [datetime]::new(2026, 9, 30, 21, 48, 0)),
                   @('charging-offpeak', 'Charging', [datetime]::new(2026, 9, 30, 23, 30, 0)), @('idle-peak', 'Stopped', [datetime]::new(2026, 9, 30, 15, 48, 0)),
                   @('idle-day', 'Stopped', [datetime]::new(2026, 9, 30, 21, 48, 0)), @('idle-offpeak', 'Stopped', [datetime]::new(2026, 10, 1, 1, 30, 0)))
        foreach ($c in $cases) {
            Set-CtlOverride 'chargingState' $c[1]; $script:PeakNow = $c[2]; Render-View; $window.UpdateLayout()
            $pr[$c[0]] = (Get-V43Status).rateStatus
            if ($c[0] -in 'charging-peak', 'charging-day', 'charging-offpeak', 'idle-peak') { & $shot $c[0] }
        }
        Set-LayoutMode 'compact' $false; $window.UpdateLayout()
        foreach ($c in $cases | Where-Object { $_[0] -in 'charging-peak', 'charging-offpeak', 'idle-peak' }) { Set-CtlOverride 'chargingState' $c[1]; $script:PeakNow = $c[2]; Render-View; Update-CompactScale; $window.UpdateLayout(); & $shot ($c[0] + '-compact') }
        $pr.compactScale = $script:CompactScale
        Set-LayoutMode 'full' $false; $window.UpdateLayout()
        Set-CtlOverride 'chargingState' 'Charging'; $script:PeakNow = [datetime]::new(2026, 9, 30, 15, 48, 0); Render-View
        $script:SelfRec.rundownCharging = (Get-Rundown)
        $script:SelfRec.chargingStartedPeak = (Get-ChargingStartedText ([pscustomobject]@{ socPct = 62; limitPct = 80; chargerKw = 11; amps = 48; minutesToFull = 130 }) (Get-RateStatus))
        $script:PeakNow = [datetime]::new(2026, 9, 30, 23, 30, 0)
        $script:SelfRec.chargingStartedOffPeak = (Get-ChargingStartedText ([pscustomobject]@{ socPct = 62; limitPct = 80; chargerKw = 11; amps = 48; minutesToFull = 130 }) (Get-RateStatus))
        $script:SelfRec.rundownChargingOffPeak = (Get-Rundown).text
        $script:SelfRec.rate = $pr
        $script:PeakNow = [datetime]::new(2026, 9, 30, 15, 48, 0); Render-View
    }
    & $add 'v4.3 RATE STATUS Stop charging: answer NO' @($false) { Invoke-ChargeStop }
    & $add 'v4.3 peak banner cleanup' @() { $script:PeakNow = $null; Set-CtlOverride 'chargingState' ([string]$script:SelfRec.carAtStart.chargingState); Render-View }
    & $add 'v4.3 Announce on Alexa: confirm box snapshot, answer YES (dry run)' @($true) {
        [void](Show-ConfirmOverlay 'Announce full status?' ('Alexa speaks the rundown on ' + (Get-TargetLabel)) 'Announce' 'Cancel' -NoWait)
        Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-announce-confirm.png'); $script:SelfRec.shots += 'tessdesk-v43-announce-confirm.png'
        Set-Visible $ui.ConfirmOverlay $false
        $r = Invoke-AnnounceNow
        $window.UpdateLayout()
        Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v43-announce-toast.png'); $script:SelfRec.shots += 'tessdesk-v43-announce-toast.png'
        $script:SelfRec.rundown = $script:LastRundown; $script:SelfRec.rundownResult = $(if ($null -ne $r) { $r.result } else { $null }); $script:SelfRec.rundownToast = $script:LastToast
    }
    & $add 'v4.3 Announce on Alexa: answer NO' @($false) { [void](Invoke-AnnounceNow) }
    & $add 'v4.3 Announce Setup panel snapshot + Preview' @() { $script:SelfRec.setup = (Show-AnnSetupWindow -SnapshotPath (Join-Path $script:SelfDir 'tessdesk-v43-announce-setup.png')); $script:SelfRec.shots += 'tessdesk-v43-announce-setup.png' }
    # ---- v4.3.1 steps: speakers dropdown, Test this speaker, Add speaker flow (DRY RUN: nothing is announced, no browser opened, config.json untouched) ----
    & $add 'v4.3.1 Announce Setup: speakers dropdown open + Test this speaker (DRY RUN)' @() { $script:SelfRec.setupDropdown = (Show-AnnSetupWindow -SnapshotPath (Join-Path $script:SelfDir 'tessdesk-v431-setup-dropdown.png') -Scene 'dropdown'); $script:SelfRec.shots += 'tessdesk-v431-setup-dropdown.png' }
    & $add 'v4.3.1 Add speaker: name + Open Voice Monkey (not opened in self-test) + Alexa steps' @() { $script:SelfRec.setupAdd = (Show-AnnSetupWindow -SnapshotPath (Join-Path $script:SelfDir 'tessdesk-v431-setup-add.png') -Scene 'add'); $script:SelfRec.shots += 'tessdesk-v431-setup-add.png' }
    & $add 'v4.3.1 Add speaker: Refresh list picks up a new speaker (self-test sample) + Test it (DRY RUN)' @() {
        $script:SetupMockNew = @([pscustomobject]@{ id = 'kitchen-echo-sample'; name = 'Kitchen Echo' })
        try { $script:SelfRec.setupAdded = (Show-AnnSetupWindow -SnapshotPath (Join-Path $script:SelfDir 'tessdesk-v431-setup-added.png') -Scene 'added'); $script:SelfRec.shots += 'tessdesk-v431-setup-added.png' } finally { $script:SetupMockNew = $null }
    }
    & $add 'v4.3.1 All Echos label + speaker test log' @() {
        $l = [ordered]@{ real = (Get-TargetLabel); button = $ui.AnnNowSub.Text }
        Save-AnnProps @{ speakerList = @([pscustomobject]@{ id = 'a'; name = 'A' }); speakers = [pscustomobject]@{ all = $true; ids = @() } }; $l.one = (Get-TargetLabel)
        Save-AnnProps @{ speakerList = @([pscustomobject]@{ id = 'a'; name = 'A' }, [pscustomobject]@{ id = 'b'; name = 'B' }) }; $l.two = (Get-TargetLabel)
        $script:AnnMem.Remove('speakerList'); $script:AnnMem.Remove('speakers'); Render-Controls43; $l.buttonAfter = $ui.AnnNowSub.Text
        $l.tests = $script:SpkTestLog; $l.realAnnouncementsSent = $script:AnnSent
        $script:SelfRec.v431 = $l
    }
    & $add 'v4.3 rundown subset (battery + tires only) and speaker targets (in memory)' @() {
        $sub = [ordered]@{}; foreach ($k in $RundownItems.Keys) { $sub[$k] = ($k -eq 'battery' -or $k -eq 'tires') }
        Save-AnnProps @{ rundownItems = [pscustomobject]$sub }; $script:SelfRec.rundownSubset = (Get-Rundown).text; Save-AnnProps @{ rundownItems = $null }
        $real = @(Get-SpeakerList)
        $mock = @([pscustomobject]@{ id = 'selftest-echo-a'; name = 'Mock A' }, [pscustomobject]@{ id = 'selftest-echo-b'; name = 'Mock B' }, [pscustomobject]@{ id = 'selftest-echo-c'; name = 'Mock C' })
        $t = [ordered]@{ realList = @($real | ForEach-Object { $_.name + ' (' + $_.id + ')' }); realTargetsAllEchos = @(Get-AnnTargets 'action') }
        Save-AnnProps @{ speakerList = $mock; speakers = [pscustomobject]@{ all = $true; ids = @() } }; $t.allEchos = @(Get-AnnTargets 'action'); $t.label = (Get-TargetLabel)
        Save-AnnProps @{ speakers = [pscustomobject]@{ all = $false; ids = @('selftest-echo-b') } }; $t.picked = @(Get-AnnTargets 'action'); $t.pickedLabel = (Get-TargetLabel)
        $t.reminder = @(Get-AnnTargets 'reminder')
        $t.sendDry = (Send-Announcement -Parts @('Self-test part one.', 'Self-test part two.') -Why 'selftest-multi' -Force).result
        $script:AnnMem.Remove('speakerList'); $script:AnnMem.Remove('speakers'); $t.afterReset = @(Get-AnnTargets 'action')
        $script:SelfRec.speakerTargets = $t
    }
    & $add 'v4.3 charging started: Not charging -> Charging, wait one refresh, announce once (dry run)' @() {
        $cs = [ordered]@{}
        try {
            Remove-Item -LiteralPath $ChgMarkPath -Force -ErrorAction SilentlyContinue
            $c0 = (Get-CtlCar).PSObject.Copy(); $c0.chargingState = 'Charging'; $c0.socPct = 62; $c0.limitPct = 80; $c0.chargerKw = 0; $c0.amps = 0; $c0.minutesToFull = 130
            $c1 = $c0.PSObject.Copy(); $c1.chargerKw = 11.0; $c1.amps = 48
            $k = Get-EpochNow; $se = [pscustomobject]@{ startEpoch = $k }
            $script:PrevCharging = $null
            Watch-ChargingStarted ([pscustomobject]@{ mode = 'idle'; car = $c0 })
            Watch-ChargingStarted ([pscustomobject]@{ mode = 'live'; car = $c0; session = $se }); $cs.pendingAfterTransition = ($null -ne $script:ChgStartPending)
            Watch-ChargingStarted ([pscustomobject]@{ mode = 'live'; car = $c0; session = $se }); $cs.pendingAfterImmediatePoll = ($null -ne $script:ChgStartPending)
            $script:ChgStartPending.at = $k - 15
            Watch-ChargingStarted ([pscustomobject]@{ mode = 'live'; car = $c1; session = $se }); $cs.announcedAfterRefresh = (@($script:ChgStartLog).Count -gt 0)
            Watch-ChargingStarted ([pscustomobject]@{ mode = 'live'; car = $c1; session = $se })
            Watch-ChargingStarted ([pscustomobject]@{ mode = 'idle'; car = $c0 }); Watch-ChargingStarted ([pscustomobject]@{ mode = 'live'; car = $c1; session = $se }); $script:ChgStartPending.at = $k - 15
            Watch-ChargingStarted ([pscustomobject]@{ mode = 'live'; car = $c1; session = $se })
            Save-AnnProps @{ chargingStarted = $false }; [void](Invoke-ChargingStartedAnnounce $c1 'another-session'); $script:AnnMem.Remove('chargingStarted')
            $cs.log = $script:ChgStartLog
        } catch { $cs.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber }
        $script:PrevCharging = $null; $script:ChgStartPending = $null
        Remove-Item -LiteralPath $ChgMarkPath -Force -ErrorAction SilentlyContinue
        $script:SelfRec.chargingStarted = $cs
    }
    # ---- v4.3.9 CAMERAS (self-test TeslaCam clips next to the script; nothing is emailed, nothing opens, nothing is sent to the car) ----
    $script:Shot439 = { param($n, [switch]$Full) $f = 'tessdesk-v439-' + $n + '.png'; if ($Full) { Save-RootPng (Join-Path $script:SelfDir $f) -Full } else { Save-RootPng (Join-Path $script:SelfDir $f) }; $script:SelfRec.shots += $f }
    $script:SaveFsPng = { param($W, $n) $W.UpdateLayout(); $el = $W.Content; $el.UpdateLayout(); $bw = [int][math]::Max(1, $el.ActualWidth); $bh = [int][math]::Max(1, $el.ActualHeight)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $bw, $bh, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32); $bmp.Render($el)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $f = 'tessdesk-v439-' + $n + '.png'; $fs = [System.IO.File]::Create((Join-Path $script:SelfDir $f)); try { $enc.Save($fs) } finally { $fs.Dispose() }; $script:SelfRec.shots += $f }
    $script:CamTestDir = Join-Path $scriptDir 'selftest-teslacam'
    $script:SelfRec.v439 = [ordered]@{ testClips = $script:CamTestDir; testClipsFound = (Test-Path -LiteralPath $script:CamTestDir); appVersion = $AppVersion; footer = $ui.FooterVersion.Text }
    & $add 'v4.3.9 camera: OFF by default (panel hidden, header toggle off)' @() {
        $r = $script:SelfRec.v439
        $r.offByDefault = [ordered]@{ enabled = [bool]$script:CamCfg.enabled; cardVisible = [string]$ui.CamCard.Visibility; toggle = [bool]$ui.CamToggle.IsChecked }
        $script:CamCfg.fsLayout = 'two'; $script:CamCfg.fsFront = 'left'; $script:CamCfg.fps = 4; $script:CamCfg.which = 'latest'; $script:CamCfg.defaultCam = 'grid'; $script:Cam.view = 'grid'
        $script:CamCfg.usbPath = ''; $script:CamCfg.folderPath = ''; $script:CamCfg.source = 'folder'
        & $script:Shot439 'off'
    }
    & $add 'v4.3.9 camera: ON with no folder yet (Choose folder)' @() {
        Set-CamEnabled $true
        $r = $script:SelfRec.v439; $r.onNoFolder = [ordered]@{ status = $script:Cam.status; cardVisible = [string]$ui.CamCard.Visibility; aboveChargingAmount = ([System.Windows.Controls.Grid]::GetRow($ui.CamCard.Parent) -eq 0 -and $ui.CamCard.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.MainGrid).Y -lt $ui.HeroCost.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.MainGrid).Y) }
        $window.UpdateLayout(); & $script:Shot439 'nofolder'
    }
    & $add 'v4.3.9 camera: pick the test TeslaCam folder, scan, load the latest event' @() {
        $script:CamBusySeen = New-Object System.Collections.ArrayList
        [void](Select-CamFolder 'folder' $script:CamTestDir)
    }
    & $add 'v4.3.9 camera: 4-up grid loaded (progress counts, frame times)' @() {
        $r = $script:SelfRec.v439; $C = $script:Cam
        $r.scan = [ordered]@{ events = @($C.events | ForEach-Object { $_.kind + '/' + $_.name + ' @ ' + $_.time + ' cams=' + @($_.clips.PSObject.Properties).Count }) }
        $r.load = $C.lastLoad; $r.status = $C.status; $r.cams = @($C.cams); $r.frames = [ordered]@{}; foreach ($k in $C.cams) { $r.frames[$k] = @($C.frames[$k]).Count }
        $r.frameTimesFront = @($C.times['front'] | ForEach-Object { $_.ToString('HH:mm:ss.f') })
        $r.frameBytesFront = @($C.frames['front'] | ForEach-Object { $_.Length })
        $r.progressSeen = @($script:CamBusySeen | Select-Object -First 4) + @('...') + @($script:CamBusySeen | Select-Object -Last 3)
        $r.eventLine = $ui.CamEvent.Text; $r.source = $ui.CamSrc.Text; $r.count = $ui.CamCount.Text
        $Cam0 = $C.idx; $r.idxA = $Cam0
        $window.UpdateLayout(); & $script:Shot439 'camera-grid'
    }
    & $add 'v4.3.9 camera: playback advances, then Front view (paused on frame 9)' @() {
        $r = $script:SelfRec.v439; $r.idxB = $script:Cam.idx; $r.playing = $script:Cam.playing; $r.playAdvanced = ($r.idxB -ne $r.idxA)
        Set-CamView 'front'; Set-CamPlaying $false; $script:Cam.idx = 8; Show-CamFrame
        $r.frontView = [ordered]@{ count = $ui.CamCount.Text; ts = @($script:CamViews | Where-Object { $_.owner -eq 'widget' } | ForEach-Object { $_.ts.Text }) }
        $window.UpdateLayout(); & $script:Shot439 'camera-front'
    }
    & $add 'v4.3.9 camera: capture Front (PNG saved; email path recorded, nothing opened or sent)' @() {
        $r = $script:SelfRec.v439
        $c = Invoke-CamCapture 'front'
        $r.captureFront = $c; $r.captureFileOk = (Test-Path -LiteralPath $c.file); $r.captureToast = $ui.WToastTxt.Text
        $r.shareLogLast = @($script:ShareLog | Select-Object -Last 1 | ForEach-Object { $_.kind + ' launched=' + $_.launched })
        $window.UpdateLayout(); & $script:Shot439 'camera-capture'
    }
    & $add 'v4.3.9 camera: options panel' @() {
        Set-CamView 'grid'; Show-CamOptions; $window.UpdateLayout()
        $r = $script:SelfRec.v439; $r.options = [ordered]@{ layoutItems = @($script:CamOptLayoutCombo.Items | ForEach-Object { $_.Content.Text }); layout = [string]$script:CamOptLayoutCombo.SelectedItem.Tag; monitorItems = @($script:CamOptMonCombo.Items | ForEach-Object { [string]$_.Content }); monitors = @(Get-CamScreens).Count; events = @($script:CamOptList.Children).Count }
        & $script:Shot439 'camera-options'
        $ui.CamOptScroll.ScrollToBottom(); $window.UpdateLayout(); & $script:Shot439 'camera-options-bottom'
        $ui.CamOptScroll.ScrollToTop(); Close-CamOptions
    }
    & $add 'v4.3.9 camera: full screen, two monitors (Front left, grid right), TessDesk hidden, capture, Esc' @() {
        $r = $script:SelfRec.v439; $f = [ordered]@{}
        $script:CamCfg.fsLayout = 'two'; $script:CamCfg.fsFront = 'left'; Set-CamPlaying $false; $script:Cam.idx = 8
        $fs = Open-CamFullscreen
        $f.mode = $fs.mode; $f.plan = $fs.plan; $f.windows = $fs.windows.Count; $f.rects = @($fs.windows | ForEach-Object { [string]$_.Tag.kind + ' ' + [string]$_.Tag.rect })
        $f.mainHidden = [ordered]@{ opacity = $window.Opacity; topmost = $window.Topmost; hitTest = $window.IsHitTestVisible }
        $f.views = @($script:CamViews | Where-Object { $_.owner -like 'fs*' }).Count
        Show-CamFrame
        $i = 0; foreach ($w in $fs.windows) { & $script:SaveFsPng $w $(if ($i -eq 0) { 'fs-front' } else { 'fs-others' }); $i++ }
        $c = Invoke-CamCapture 'right_repeater'; $f.capture = $c.file; $f.toastInFs = $fs.windows[1].Tag.toastTxt.Text
        & $script:SaveFsPng $fs.windows[1] 'fs-capture'
        $w0 = $fs.windows[0]
        $ka = New-Object System.Windows.Input.KeyEventArgs ([System.Windows.Input.Keyboard]::PrimaryDevice, [System.Windows.PresentationSource]::FromVisual($w0), 0, [System.Windows.Input.Key]::Escape)
        $ka.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent; $w0.RaiseEvent($ka)
        $f.closedByEsc = ($null -eq $script:CamFs); $f.mainRestored = [ordered]@{ opacity = $window.Opacity; topmost = $window.Topmost; hitTest = $window.IsHitTestVisible }
        $f.fsViewsLeft = @($script:CamViews | Where-Object { $_.owner -like 'fs*' }).Count
        $r.fsTwo = $f
    }
    & $add 'v4.3.9 camera: full screen, one screen (Front on top, others below), X closes' @() {
        $r = $script:SelfRec.v439; $f = [ordered]@{}
        $script:CamCfg.fsLayout = 'one'
        $fs = Open-CamFullscreen
        $f.mode = $fs.mode; $f.plan = $fs.plan; $f.windows = $fs.windows.Count; $f.mainOpacity = $window.Opacity
        Show-CamFrame; & $script:SaveFsPng $fs.windows[0] 'fs-one'
        $fs.windows[0].Tag.close.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $f.closedByX = ($null -eq $script:CamFs); $f.mainOpacityAfter = $window.Opacity; $f.topmostAfter = $window.Topmost
        $script:CamCfg.fsLayout = 'two'
        $r.fsOne = $f
    }
    & $add 'v4.3.9 camera: save the selected clip (copy with progress)' @() {
        $script:CamBusySeen = New-Object System.Collections.ArrayList
        $script:SelfRec.v439.saveDest = Start-CamSaveClip
    }
    & $add 'v4.3.9 camera: Stop while loading (6-camera event, stop at 40 frames)' @() {
        $r = $script:SelfRec.v439
        $r.save = $script:CamLastSave; $r.saveProgress = @($script:CamBusySeen); $r.savedFiles = @(Get-ChildItem -LiteralPath $script:CamLastSave.dest -File | ForEach-Object { $_.Name })
        $ev2 = @($script:Cam.events | Where-Object { $_.kind -eq 'SavedClips' })[0]
        $script:CamStopAt = 40; $script:CamBusySeen = New-Object System.Collections.ArrayList
        Start-CamLoad $ev2
    }
    & $add 'v4.3.9 camera: stopped load shows what it got (6-up), then Stop while saving a clip' @() {
        $r = $script:SelfRec.v439; $C = $script:Cam
        $r.stopLoad = [ordered]@{ lastLoad = $C.lastLoad; msg = $C.msg; cams = @($C.cams); n = $C.n; progressSeen = @($script:CamBusySeen | Select-Object -Last 3) }
        $C.idx = 0; Set-CamView 'grid'; $window.UpdateLayout(); & $script:Shot439 'camera-6up-stopped'
        [void](Start-CamSaveClip -SlowMs 700)
        $t0 = Get-Date; while (((Get-Date) - $t0).TotalMilliseconds -lt 1000) { Start-Sleep -Milliseconds 100 }
        Update-CamBusy; $r.saveBusyText = $ui.CamBusyTxt.Text; $window.UpdateLayout(); & $script:Shot439 'camera-saving'
        Stop-CamSave
    }
    & $add 'v4.3.9 camera: OFF again (panel hidden, frames freed)' @() {
        $r = $script:SelfRec.v439
        $r.saveStopped = $script:CamLastSave
        Set-CamEnabled $false
        $r.offAgain = [ordered]@{ cardVisible = [string]$ui.CamCard.Visibility; frames = $script:Cam.frames.Count; views = $script:CamViews.Count; playTimer = $script:CamPlayTimer.IsEnabled }
        $r.log = @($script:CamLog); $r.captures = @($script:CamCaptures | ForEach-Object { $_.cam + ' ' + $_.size + ' ' + $_.bytes + ' B via ' + $_.via })
        $r.cfgSaved = (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).camera
        $r.footer = $ui.FooterVersion.Text
    }
    # ---- v4.3.10 TOTALS (charge history fixture next to the script; no Tessie call, nothing sent to the car) ----
    $script:Shot4310 = { param($n, [switch]$Full) $f = 'tessdesk-v4310-' + $n + '.png'; if ($Full) { Save-RootPng (Join-Path $script:SelfDir $f) -Full } else { Save-RootPng (Join-Path $script:SelfDir $f) }; $script:SelfRec.shots += $f }
    $script:TotView4310 = { param($V) $o = [ordered]@{}; foreach ($p in 'week', 'month', 'year') { $a = $V.$p; $o[$p] = [ordered]@{ kwh = $a.kwh; cost = $a.cost; nights = $a.nights; cpk = $a.cpk; awayN = $a.awayN; awayKwh = $a.awayKwh; awayCost = $a.awayCost; grand = $a.grand } }
        $o.months = @($V.months | ForEach-Object { '{0}: {1} kWh, ${2}, {3} nights, away {4} ${5}{6}' -f $_.key, $_.agg.kwh, $_.agg.cost, $_.agg.nights, $_.agg.awayN, $_.agg.awayCost, $(if ($_.current) { ' (so far)' } else { '' }) })
        $o.weekRange = $V.weekStart.ToString('yyyy-MM-dd') + '..' + $V.weekEnd.ToString('yyyy-MM-dd'); $o.charges = $V.count; return $o }
    $script:SelfRec.v4310 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text; home = $TotHome }
    & $add 'v4.3.10 totals: open with no cache (loads the charge history month by month, progress count)' @() {
        $r = $script:SelfRec.v4310
        $script:TotFixtureDir = Join-Path $scriptDir 'selftest-charges'; $r.fixture = $script:TotFixtureDir; $r.fixtureFound = (Test-Path -LiteralPath $script:TotFixtureDir)
        try { Remove-Item -LiteralPath $totCachePath -Force -ErrorAction SilentlyContinue } catch {}
        $script:Tot.months = @{}; $script:Tot.loadedAt = 0; $script:Tot.rowsKey = ''; $script:Tot.open = @{}
        $script:TotBusySeen = New-Object System.Collections.ArrayList
        Show-Totals; $r.startedJob = (Test-TotBusy); $r.firstStatus = $ui.TotStatus.Text
        $window.UpdateLayout(); & $script:Shot4310 'totals-loading'
    }
    & $add 'v4.3.10 totals: loaded (this week / month / year, month by month)' @() {
        $r = $script:SelfRec.v4310
        $r.nowEpoch = Get-EpochNow; $r.lastLoad = $script:Tot.lastLoad; $r.progressSeen = @($script:TotBusySeen)
        $r.view = & $script:TotView4310 $script:Tot.view; $r.status = $ui.TotStatus.Text; $r.cacheFile = (Test-Path -LiteralPath $totCachePath)
        $r.cacheBytes = $(if ($r.cacheFile) { (Get-Item -LiteralPath $totCachePath).Length } else { 0 })
        $r.overlayVisible = [string]$ui.TotOverlay.Visibility
        $ui.TotScroll.ScrollToTop(); $window.UpdateLayout(); & $script:Shot4310 'totals'
    }
    & $add 'v4.3.10 totals: expand October (nights) and July (Supercharger, paid)' @() {
        $r = $script:SelfRec.v4310; $mk = (ConvertFrom-Epoch (Get-EpochNow)).ToString('yyyy-MM')
        $script:Tot.open[$mk] = $true; $script:Tot.open['2026-07'] = $true; Render-Totals; $window.UpdateLayout()
        $r.expanded = @($ui.TotBody.Children | Where-Object { $_ -is [System.Windows.Controls.StackPanel] } | ForEach-Object { @($_.Children | ForEach-Object { (@($_.Children | ForEach-Object { $_.Text }) -join ' | ') }) })
        $ui.TotScroll.ScrollToVerticalOffset(150); $window.UpdateLayout(); & $script:Shot4310 'totals-months'
        $ui.TotScroll.ScrollToVerticalOffset(700); $window.UpdateLayout(); & $script:Shot4310 'totals-july'
    }
    & $add 'v4.3.10 totals: X closes; reopening uses the cache (fast, nothing reloaded)' @() {
        $r = $script:SelfRec.v4310
        $ui.TotClose.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $r.xClosed = ([string]$ui.TotOverlay.Visibility -ne 'Visible')
        $script:Tot.months = @{}; $script:Tot.rowsKey = ''      # as after a restart: read the cache file
        Show-Totals; $r.reopen = [ordered]@{ ms = $script:Tot.openMs; reloadStarted = (Test-TotBusy); week = $script:Tot.view.week.cost; month = $script:Tot.view.month.cost; year = $script:Tot.view.year.grand }
    }
    & $add 'v4.3.10 totals: Refresh, then Stop part way' @() {
        $script:TotBusySeen = New-Object System.Collections.ArrayList; $script:TotStopAt = 3
        $script:SelfRec.v4310.refreshStarted = (Start-TotLoad -All)
    }
    & $add 'v4.3.10 totals: stopped shows what is saved; Esc closes' @() {
        $r = $script:SelfRec.v4310
        $r.stop = [ordered]@{ lastLoad = $script:Tot.lastLoad; status = $ui.TotStatus.Text; progressSeen = @($script:TotBusySeen); yearStill = $script:Tot.view.year.grand }
        $window.UpdateLayout(); & $script:Shot4310 'totals-stopped'
        $r.escHandled = (Invoke-TotKey 'Escape'); $r.escClosed = ([string]$ui.TotOverlay.Visibility -ne 'Visible')
    }
    & $add 'v4.3.10 totals: TOTALS button + Last 7 / 30 days (shared rule)' @() {
        $r = $script:SelfRec.v4310; $script:Tot.status = ''
        Update-TotBtnSum; Render-View; $window.UpdateLayout()
        $r.button = [ordered]@{ visible = [string]$ui.TotBtn.Visibility; sum = $ui.TotBtnSum.Text }
        $r.rows = [ordered]@{ d7 = $ui.D7Cost.Text + ' ' + $ui.D7Kwh.Text + ' ' + $ui.D7Cap.Text; d30 = $ui.D30Cost.Text + ' ' + $ui.D30Kwh.Text + ' ' + $ui.D30Cap.Text }
        $ui.RowsCard.BringIntoView(); $window.UpdateLayout(); & $script:Shot4310 'totals-button'
        $script:TotFixtureDir = $null
    }
    # ---- v4.3.11: Restore / Remember match Paycheck Live (look, order, hover, feedback) ----
    $script:Shot4311 = { param($n) $f = 'tessdesk-v4311-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
    $script:DwProps = { param($b) [ordered]@{ text = $b.Child.Text; font = [string]$b.Child.FontFamily; size = $b.Child.FontSize; weight = [string]$b.Child.FontWeight; fg = [string]$b.Child.Foreground; bg = [string]$b.Background
        corner = [string]$b.CornerRadius; padding = [string]$b.Padding; height = $b.Height; opacity = $b.Opacity; margin = [string]$b.Margin; borderThickness = [string]$b.BorderThickness; enabled = $b.IsEnabled; tip = [string]$b.ToolTip; width = [math]::Round($b.ActualWidth, 1) } }
    & $add 'v4.3.11 Restore / Remember: Paycheck Live look and order' @() {
        $script:SelfRec.v4311 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text }
        $r = $script:SelfRec.v4311; $row = $ui.RestoreBtn.Parent
        $r.order = @($row.Children | ForEach-Object { [string]$_.Name })
        $r.restore = & $script:DwProps $ui.RestoreBtn; $r.remember = & $script:DwProps $ui.KeepBtn
        $r.shareStill = ([string]$ui.ShareBtn.Visibility)
        $ui.FooterText.BringIntoView(); $window.UpdateLayout(); & $script:Shot4311 'buttons'
    }
    & $add 'v4.3.11 hover: #FF666666 with white text, back to #FF444444' @() {
        $r = $script:SelfRec.v4311; $mk = { param($ev) New-Object System.Windows.Input.MouseEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0) -Property @{ RoutedEvent = $ev } }
        $ui.RestoreBtn.RaiseEvent((& $mk ([System.Windows.UIElement]::MouseEnterEvent))); $window.UpdateLayout()
        $r.hoverOn = [ordered]@{ bg = [string]$ui.RestoreBtn.Background; fg = [string]$ui.RestoreTxt.Foreground }
        & $script:Shot4311 'hover'
        $ui.RestoreBtn.RaiseEvent((& $mk ([System.Windows.UIElement]::MouseLeaveEvent))); $window.UpdateLayout()
        $r.hoverOff = [ordered]@{ bg = [string]$ui.RestoreBtn.Background; fg = [string]$ui.RestoreTxt.Foreground }
    }
    & $add 'v4.3.11 Remember: label saved, disabled 1.4 s, tooltip shows the spot (test copy of the layout file)' @() {
        $r = $script:SelfRec.v4311
        Invoke-KeepSpot; $window.UpdateLayout()
        $r.rememberClick = [ordered]@{ label = $ui.KeepTxt.Text; enabled = $ui.KeepBtn.IsEnabled; tip = [string]$ui.KeepBtn.ToolTip; toastVisible = [string]$ui.WToast.Visibility; layoutPath = (Get-DeskLayoutPath); realFileUntouched = ((Get-DeskLayoutPath) -ne $DeskLayoutPath) }
        & $script:Shot4311 'saved'
        $window.Left = $window.Left - 120
        Invoke-RestoreSpot; $window.UpdateLayout()
        $r.restoreClick = [ordered]@{ label = $ui.RestoreTxt.Text; enabled = $ui.RestoreBtn.IsEnabled; tip = [string]$ui.RestoreBtn.ToolTip; backAtKept = ([math]::Abs($window.Left - [double]$script:KeptSpot.left) -lt 1) }
        & $script:Shot4311 'restored'
    }
    & $add 'v4.3.11 (wait for the 1.4 s label timer)' @() { }
    & $add 'v4.3.11 (wait)' @() { }
    & $add 'v4.3.11 (wait)' @() { }
    & $add 'v4.3.11 (wait)' @() { }
    & $add 'v4.3.11 labels back to Restore / Remember and enabled again' @() {
        $r = $script:SelfRec.v4311
        $r.after = [ordered]@{ restore = $ui.RestoreTxt.Text; remember = $ui.KeepTxt.Text; restoreEnabled = $ui.RestoreBtn.IsEnabled; rememberEnabled = $ui.KeepBtn.IsEnabled }
    }
    & $add 'live refresh status' @() { $script:SelfRec.live = (Get-LiveStatus); $script:SelfRec.liveBadge = $ui.UpdBadge.Text; $script:SelfRec.tiresHeader = [ordered]@{ hdr = $ui.TiresHdr.Text; rec = $ui.TiresRec.Text; asOf = $ui.TiresAsOf.Text } }
    & $add 'theme snapshots' @() { Save-Snapshots $script:SelfDir; $script:SelfRec.shots += @($script:LastSnapshot.files | ForEach-Object { Split-Path -Leaf $_ }) }
    Start-SelfTimer
}
function Start-SelfTimer {
    $script:SelfTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SelfTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:SelfTimer.Add_Tick({
        try {
            if ($null -ne $script:FlashWaitFor -and $script:FlashWaitFor -lt 99) { if ($script:Flash.running -and $script:Flash.done -lt $script:FlashWaitFor) { return } }
            elseif ($null -ne $script:UpdJob -or (Test-CamBusy) -or (Test-TotBusy) -or $script:CtlBusy -or $script:TempTimer.IsEnabled -or $script:SeatTimer.IsEnabled -or $script:WheelTimer.IsEnabled) { return }
            if ($null -ne $script:FlashWaitFor -and $script:FlashWaitFor -ge 99 -and $script:Flash.running) { return }
            if ($script:SelfSteps.Count -eq 0) {
                $script:SelfTimer.Stop()
                $script:SelfRec.commands = $script:CtlLog
                $script:SelfRec.prompts = $script:ConfirmPrompts
                $script:SelfRec.realCommandsSent = $script:NetCommandsSent
                $script:SelfRec.announcements = $script:AnnLog
                $script:SelfRec.realAnnouncementsSent = $script:AnnSent
                $script:SelfRec.layout = Get-LayoutCheck
                $script:SelfRec.v43 = (Get-V43Status)
                $script:SelfRec.status = 'done'
                Write-WidgetStatus
                $script:SelfRec | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $script:SelfDir 'selftest.json') -Encoding UTF8
                $window.Close(); return
            }
            $st = $script:SelfSteps.Dequeue()
            foreach ($a in @($st.answers)) { $script:SelfAnswers.Enqueue($a) }
            $before = @($script:CtlLog).Count; $pBefore = @($script:ConfirmPrompts).Count
            & $st.run
            $script:SelfRec.steps += ('{0}: prompts={1} startedCommand={2} result="{3}"' -f $st.name, ((@($script:ConfirmPrompts) | Select-Object -Skip $pBefore) -join ' | '), $script:CtlBusy, $script:CtlResultText)
        } catch { $script:SelfRec.steps += ('ERROR ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber) }
    })
    $script:SelfTimer.Start()
}

$window.Add_ContentRendered({
    try { Update-Ui } catch {}
    try { if ($script:Layout -eq 'compact') { Set-LayoutMode 'compact' $false } else { $ui.LayoutBtn.Content = 'FULL' } } catch {}
    if ($SelfTest) { try { Start-SelfTest } catch { Write-WidgetLog ('selftest failed: ' + $_.Exception.Message); $window.Close() } }
    elseif ($Snapshot) { try { Save-Snapshots $Snapshot } catch { Write-WidgetLog ('snapshot failed: ' + $_.Exception.Message) } }
    if (-not $SelfTest) {
        # v4.3.8: check for updates right away every time TessDesk opens (auto-start at boot too), then watch for wake-ups
        $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ try { [void](Request-UpdateCheck 'launch') } catch { Write-WidgetLog ('update launch check: ' + $_.Exception.Message) }; try { Start-UpdResumeWatch } catch {} }) | Out-Null
        # v4.3.9: camera panel (only when it is On): find the latest saved clip and load its frames
        $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action]{ try { Start-CamOnLaunch } catch { Write-WidgetLog ('camera start: ' + $_.Exception.Message) } }) | Out-Null
        # v4.3.10: TOTALS button summary from the cache, then refresh this month's charge history in the background
        $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action]{ try { Update-TotBtnSum; [void](Start-TotLoad) } catch { Write-WidgetLog ('totals start: ' + $_.Exception.Message) } }) | Out-Null
    }
    if (-not $SelfTest -and -not [bool]$script:ReadAllowed) {
        # First run after the update: show the notice; nothing is fetched from Tessie until it is accepted.
        $window.Dispatcher.BeginInvoke([Action]{ try { Show-ConsentWindow $true } catch { Write-WidgetLog ('consent window failed: ' + $_.Exception.Message) } }) | Out-Null
    }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(60)
# fallback refresh (no token / consent / errors). The live loop below does the fast refresh in the background.
$timer.Add_Tick({ try { $lf = $script:Live.fetchEpoch; if (-not $script:Dragging -and -not $script:CtlBusy -and ($null -eq $lf -or ((Get-EpochNow) - [int64]$lf) -gt 90)) { Update-Ui } } catch {} })
$timer.Start()
$script:LiveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:LiveTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:LiveTimer.Add_Tick({ try { Invoke-LiveTick } catch { Write-WidgetLog ('live tick failed: ' + $_.Exception.Message) } })
$script:LiveTimer.Start()
$window.Add_Activated({ try { $L = $script:Live; if ($L.interval -gt 15 -and $L.carState -eq 'online') { $L.nextDue = [math]::Min([int64]$L.nextDue, (Get-EpochNow) + 1) } } catch {} })
# v4.3.8: focus / restore -> update check (at most every 5 min; ignored until the launch check ran; never during -SelfTest)
$script:WasMinimized = $false
$window.Add_Activated({ try { if (-not $SelfTest) { [void](Request-UpdateCheck 'focus') } } catch {} })
$window.Add_StateChanged({
    try {
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) { $script:WasMinimized = $true; return }
        if ($script:WasMinimized) { $script:WasMinimized = $false; if (-not $SelfTest) { [void](Request-UpdateCheck 'restore') } }
    } catch {}
})

# Snapshot requests: create snapshot.request (optionally containing a folder path) next to the script.
$snapTimer = New-Object System.Windows.Threading.DispatcherTimer
$snapTimer.Interval = [TimeSpan]::FromSeconds(3)
$snapTimer.Add_Tick({
    try {
        if (Test-Path -LiteralPath $snapReqPath) {
            $dir = ''
            try { $dir = ([string](Get-Content -LiteralPath $snapReqPath -Raw)).Trim() } catch {}
            Remove-Item -LiteralPath $snapReqPath -Force -ErrorAction SilentlyContinue
            Save-Snapshots $dir
        }
    } catch { Write-WidgetLog ('snapshot failed: ' + $_.Exception.Message) }
})
$snapTimer.Start()

$window.Add_Closed({
    try { Stop-CamAll } catch {}
    try { Stop-TotLoad } catch {}
    try { $script:UpdRetryTimer.Stop(); if ($script:PwTimer) { $script:PwTimer.Stop() }; if ('TdPowerWatch' -as [type]) { [TdPowerWatch]::Stop() } } catch {}
    try { $timer.Stop(); $script:LiveTimer.Stop(); $snapTimer.Stop(); $script:CtlTimer.Stop(); $script:TempTimer.Stop(); $script:SeatTimer.Stop(); $script:AnnTimer.Stop(); $script:WheelTimer.Stop(); $script:WToastTimer.Stop(); $script:FlashTimer.Stop() } catch {}
    try { $script:Mutex.ReleaseMutex() } catch {}
})

# 2026-10-03: compact-when-OFF (OFF button top-left on hover -> small card with a snapshot + ON / Restore + DESIGN BY VAN). Keep this line in new versions.
try { . 'C:\Users\vanwi\cb_compact_addon.ps1'; Enable-CbCompactMode -Window $window -Name 'TESSDESK' -Version $AppVersion -OffMargin '8,40,0,0' } catch { }
[void]$window.ShowDialog()
