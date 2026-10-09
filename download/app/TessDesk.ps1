#Requires -Version 5.1
# TessDesk v4.3.23 (CHARGING SCHEDULE in START / STOP: START AT + FINISH BY, set on the car through Tessie; v4.3.22: CHARGE column in HEALTH HISTORY: highest charge % per day + Home / AC / Supercharger; v4.3.21: HEALTH HISTORY under START / STOP with CALIBRATION INFO; health history logged by the app itself; v4.3.20: HEALTH HISTORY dropdown, one entry per day, kept indefinitely; v4.3.19: 30% wider; PLUG-IN REMINDER; TRIPS; MORNING READY CHECK; PSO BILL MATCH with on/off; BATTERY HEALTH TREND + TIPS; LEAVING SOON 'Start after' delay; v4.3.18 CHARGING STATUS bar under the big cost with START / STOP, fits 364x990 without scrolling; v4.3.17: TESLA CONTROLS under the big cost, CHARGE HISTORY & TOTALS dropdown; v4.3.16 LEAVING SOON: adjustable 'Windows after' / 'Unlock after' minutes, Stop undoes the steps already done; v4.3.15: climate on, close windows, unlock; rolling 7 / 14 days and 30 / 60 days $ beside the big amount; Restore / Remember at the top right with fade-in, like Paycheck Live; TOTALS pop-up: week / month / year running totals; CAMERAS panel from saved Sentry / Dashcam clips; checks for updates on open / wake; compact-when-OFF via cb_compact_addon.ps1) - live Tesla charging cost desktop widget + Tesla controls (Tessie API).  DESIGN BY VAN.
param(
    [string]$ConfigPath,
    [string]$Snapshot,    # optional: folder to write PNG snapshots of both themes
    [switch]$Quick433,    # with -SelfTest: run only the v4.3.3 steps (trunk, sentry, drives, paused-session energy)
    [switch]$Quick432,
    [switch]$Quick4323,   # with -SelfTest: run only the v4.3.21 - v4.3.23 steps (health history, CHARGE column, CHARGING SCHEDULE, dry run) + a short smoke check    # with -SelfTest: run only the v4.3.2 steps (glow states, seats, flash lights, last charge)
    [switch]$SelfTest     # test run: controls forced to DRY RUN (nothing is sent to the car), snapshots, selftest.json, then exit
)
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$ErrorActionPreference = 'Stop'
$AppName    = 'TessDesk'
$AppVersion = '4.3.23'
$AppDate    = 'Oct 9, 2026'

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
$HistoryDays       = 61   # v4.3.14: 60 days rolling needs 60 days of /charges

# Window size: 473 wide (v4.3.19, 30% wider than 364). v4.2: the window grows to fit (never past the bottom of the work area). The top (hero + money
# rows) and the footer stay fixed; the sections below scroll (slim scrollbar) when they don't fit the screen.
$winW = 473
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
                 'lastCharge', 'tessieLook', 'lastTires', 'lastCar', 'drives', 'drivesFetchEpoch', 'trips', 'health', 'healthFetchEpoch')

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
$script:ChargesFetchedOnce = $false   # full 61-day /charges fetch on every start
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
        schedMode = [string]$cs.scheduled_charging_mode; schedStartEpoch = $cs.scheduled_charging_start_time; schedStartMin = $(if ($null -ne $cs.scheduled_charging_start_time_minutes) { $cs.scheduled_charging_start_time_minutes } else { $cs.scheduled_charging_start_time_app }); schedPending = $cs.scheduled_charging_pending
        departEpoch = $cs.scheduled_departure_time; departMin = $cs.scheduled_departure_time_minutes; offPeak = $cs.off_peak_charging_enabled; offPeakEndMin = $cs.off_peak_hours_end_time; precond = $cs.preconditioning_enabled
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
        try { Update-HealthCache $Token $nowE } catch { Write-WidgetLog ('battery health: ' + $_.Exception.Message) }   # v4.3.21: also while charging
        try { Update-ChargeHist $Token $nowE } catch { Write-WidgetLog ('charge history: ' + $_.Exception.Message) }   # v4.3.22
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
    try { Update-HealthCache $Token $nowE } catch { Write-WidgetLog ('battery health: ' + $_.Exception.Message) }
    try { Update-ChargeHist $Token $nowE } catch { Write-WidgetLog ('charge history: ' + $_.Exception.Message) }   # v4.3.22
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
        $r = Invoke-Tessie ("/$($script:VIN)/drives?from=$from&to=$NowE&distance_format=mi&format=json") $Token
        $rows = @($r.results | Where-Object { $null -ne $_ -and $null -ne $_.started_at } | Sort-Object { [int64]$_.started_at } -Descending)
        $st.drives = @($rows | Select-Object -First 10 | ForEach-Object { Convert-Drive $_ })   # the DRIVES card (last 10)
        $st.trips = @($rows | ForEach-Object { Convert-Trip4319 $_ })   # v4.3.19: the TRIPS card (full 30 days)
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
    <!-- v4.3.17: CHARGE HISTORY & TOTALS dropdown header (flat, the whole row is clickable) -->
    <Style x:Key="SkipCfChk" TargetType="CheckBox">
      <Setter Property="FontSize" Value="9"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#FFCCCCCC"/>
      <Setter Property="Margin" Value="0,1,2,1"/>
      <Setter Property="Padding" Value="1,0,0,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
    </Style>
    <Style x:Key="SchedStepBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#FFCCCCCC"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Width" Value="15"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-3,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#22FFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#44FFFFFF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="HistHdrBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.8"/></Trigger>
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
        <!-- v4.3.12: date on the first line (kept clear of the top-right Restore / Remember buttons), status on its own line below them -->
        <StackPanel Margin="0,0,0,2">
          <TextBlock x:Name="DateLabel" Text="—" Foreground="#FF888888" FontSize="11" TextTrimming="CharacterEllipsis" Margin="0,0,116,0"/>
          <StackPanel x:Name="StatusLine" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,2,0,0">
            <TextBlock x:Name="LiveBadge" Text="" Foreground="#FF2ECC40" FontSize="10"
                       FontWeight="SemiBold" Margin="0,0,6,0" VerticalAlignment="Center" Visibility="Collapsed"/>
            <TextBlock x:Name="UpdBadge" Text="" Foreground="#FF888888" FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"
                       ToolTip="How old the car data is (Tessie's cached data; TessDesk never wakes the car)"/>
          </StackPanel>
        </StackPanel>
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
          <!-- v4.3.14: rolling 7 days over 14 days (left) and 30 days over 60 days (right) beside the big amount. Money only; same shared calculation (Get-PeriodTotal) as the Last 7 / 30 days rows. -->
          <Grid x:Name="HeroRow" HorizontalAlignment="Stretch">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Grid x:Name="HeroL" Grid.Column="0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel x:Name="RollL" HorizontalAlignment="Center" VerticalAlignment="Top">
                <StackPanel x:Name="Roll7" HorizontalAlignment="Center" Margin="0,0,0,0" Cursor="Arrow"
                            ToolTip="Rolling last 7 days: home charging + Supercharger paid (same as the Last 7 days row)">
                  <TextBlock x:Name="Roll7Cap" Text="7 DAYS" FontSize="8.5" FontWeight="Bold" Foreground="#FF49DF93" Opacity="0.85" HorizontalAlignment="Center" Margin="0,0,0,1"/>
                  <TextBlock x:Name="Roll7Cost" Text="$--" FontSize="17" FontWeight="SemiBold" Foreground="#FFF2F2F2" HorizontalAlignment="Center" TextWrapping="NoWrap"/>
                </StackPanel>
                <StackPanel x:Name="Roll14" HorizontalAlignment="Center" Margin="0,4,0,0" Cursor="Arrow"
                            ToolTip="Rolling last 14 days: home charging + Supercharger paid">
                  <TextBlock x:Name="Roll14Cap" Text="14 DAYS" FontSize="8.5" FontWeight="Bold" Foreground="#FF49DF93" Opacity="0.85" HorizontalAlignment="Center" Margin="0,0,0,1"/>
                  <TextBlock x:Name="Roll14Cost" Text="$--" FontSize="17" FontWeight="SemiBold" Foreground="#FFF2F2F2" HorizontalAlignment="Center" TextWrapping="NoWrap"/>
                </StackPanel>
              </StackPanel>
              <Border x:Name="HeroDivL" Grid.Column="1" Width="1" Height="58" Margin="4,0,12,0" VerticalAlignment="Center">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#0049DF93" Offset="0"/><GradientStop Color="#7749DF93" Offset="0.5"/><GradientStop Color="#0049DF93" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
            </Grid>
            <TextBlock x:Name="HeroCost" Grid.Column="1" Text="" Foreground="#FFFFFFFF" FontSize="48" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Top"/>
            <Grid x:Name="HeroR" Grid.Column="2">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="HeroDivR" Grid.Column="0" Width="1" Height="58" Margin="12,0,4,0" VerticalAlignment="Center">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#0049DF93" Offset="0"/><GradientStop Color="#7749DF93" Offset="0.5"/><GradientStop Color="#0049DF93" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
              <StackPanel x:Name="RollR" Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Top">
                <StackPanel x:Name="Roll30" HorizontalAlignment="Center" Margin="0,0,0,0" Cursor="Arrow"
                            ToolTip="Rolling last 30 days: home charging + Supercharger paid (same as the Last 30 days row)">
                  <TextBlock x:Name="Roll30Cap" Text="30 DAYS" FontSize="8.5" FontWeight="Bold" Foreground="#FF49DF93" Opacity="0.85" HorizontalAlignment="Center" Margin="0,0,0,1"/>
                  <TextBlock x:Name="Roll30Cost" Text="$--" FontSize="17" FontWeight="SemiBold" Foreground="#FFF2F2F2" HorizontalAlignment="Center" TextWrapping="NoWrap"/>
                </StackPanel>
                <StackPanel x:Name="Roll60" HorizontalAlignment="Center" Margin="0,4,0,0" Cursor="Arrow"
                            ToolTip="Rolling last 60 days: home charging + Supercharger paid">
                  <TextBlock x:Name="Roll60Cap" Text="60 DAYS" FontSize="8.5" FontWeight="Bold" Foreground="#FF49DF93" Opacity="0.85" HorizontalAlignment="Center" Margin="0,0,0,1"/>
                  <TextBlock x:Name="Roll60Cost" Text="$--" FontSize="17" FontWeight="SemiBold" Foreground="#FFF2F2F2" HorizontalAlignment="Center" TextWrapping="NoWrap"/>
                </StackPanel>
              </StackPanel>
            </Grid>
          </Grid>
          <Viewbox StretchDirection="DownOnly" Stretch="Uniform" HorizontalAlignment="Center" Margin="0,-2,0,0">
            <TextBlock x:Name="HeroSub" Text="" Foreground="#FFE82127" FontSize="14" TextWrapping="NoWrap"/>
          </Viewbox>
        </StackPanel>

        <TextBlock x:Name="KwhLabel" Grid.Row="2" Text="" Foreground="#FFE82127" FontSize="16" FontWeight="SemiBold"
                   HorizontalAlignment="Center" Margin="0,0,0,4"/>

        <!-- v4.3.18: CHARGING STATUS bar, fixed under the big cost (never scrolls): state word (CHARGING / NOT CHARGING / UNPLUGGED / COMPLETE), START / STOP on the right, then POWER, SESSION, FULL AT or ENDED, BATTERY -->
        <Border x:Name="ChgCard" Grid.Row="3" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="2" Padding="10,5,8,5" Margin="0,2,0,6">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Grid x:Name="ChgHead" VerticalAlignment="Center" Margin="0,0,6,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Ellipse x:Name="ChgDot" Width="13" Height="13" Fill="#FF49DF93" Stroke="#FF49DF93" StrokeThickness="2" VerticalAlignment="Center" Margin="0,1,7,0"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" Stretch="Uniform" HorizontalAlignment="Left" VerticalAlignment="Center" Height="32">
                <TextBlock x:Name="ChgState" Text="&#x2014;" FontSize="24" FontWeight="Black" Foreground="#FFFFFFFF"/>
              </Viewbox>
            </Grid>
            <StackPanel x:Name="ChgBtnCol" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="ChgStartBtn" Style="{StaticResource CtlBtn}" Width="70" Height="36" Margin="0,0,4,0" Padding="2,1,2,1" ToolTip="Start charging (car must be plugged in)">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock x:Name="ChgStartTxt" Text="&#x25B6; START" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="ChgStartSub" Text="" FontSize="7" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="ChgStopBtn" Style="{StaticResource CtlBtn}" Width="70" Height="36" Padding="2,1,2,1" ToolTip="Stop charging (asks first)">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock x:Name="ChgStopTxt" Text="&#x25A0; STOP" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="ChgStopSub" Text="" FontSize="7" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
            </StackPanel>
            <UniformGrid x:Name="ChgStats" Grid.Row="1" Grid.ColumnSpan="2" Columns="4" Rows="1" Margin="0,5,0,0">
              <StackPanel Margin="0,0,2,0"><Viewbox StretchDirection="DownOnly" Height="20"><TextBlock x:Name="ChgV0" Text="&#x2014;" FontSize="15" FontWeight="Bold" Foreground="#FFFFFFFF"/></Viewbox><TextBlock x:Name="ChgL0" Text="POWER" FontSize="8" FontWeight="Bold" Foreground="#FFCCCCCC" HorizontalAlignment="Center"/></StackPanel>
              <StackPanel Margin="2,0,2,0"><Viewbox StretchDirection="DownOnly" Height="20"><TextBlock x:Name="ChgV1" Text="&#x2014;" FontSize="15" FontWeight="Bold" Foreground="#FFFFFFFF"/></Viewbox><TextBlock x:Name="ChgL1" Text="SESSION" FontSize="8" FontWeight="Bold" Foreground="#FFCCCCCC" HorizontalAlignment="Center"/></StackPanel>
              <StackPanel Margin="2,0,2,0"><Viewbox StretchDirection="DownOnly" Height="20"><TextBlock x:Name="ChgV2" Text="&#x2014;" FontSize="15" FontWeight="Bold" Foreground="#FFFFFFFF"/></Viewbox><TextBlock x:Name="ChgL2" Text="ENDED" FontSize="8" FontWeight="Bold" Foreground="#FFCCCCCC" HorizontalAlignment="Center"/></StackPanel>
              <StackPanel Margin="2,0,0,0"><Viewbox StretchDirection="DownOnly" Height="20"><TextBlock x:Name="ChgV3" Text="&#x2014;" FontSize="15" FontWeight="Bold" Foreground="#FFFFFFFF"/></Viewbox><TextBlock x:Name="ChgL3" Text="BATTERY" FontSize="8" FontWeight="Bold" Foreground="#FFCCCCCC" HorizontalAlignment="Center"/></StackPanel>
            </UniformGrid>
            <TextBlock x:Name="ChgSub" Grid.Row="2" Grid.ColumnSpan="2" Text="" FontSize="9.5" FontWeight="SemiBold" Foreground="#FFCCCCCC" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,3,0,0"/>
            <!-- v4.3.23: CHARGING SCHEDULE: START AT (car's scheduled charging) or FINISH BY (scheduled departure + off-peak + target %), set on the car through Tessie -->
            <Border x:Name="SchedBox" Grid.Row="3" Grid.ColumnSpan="2" Margin="0,4,0,0" Padding="5,2,5,2" CornerRadius="6" Background="#14FFFFFF" BorderBrush="#FF333333" BorderThickness="1">
              <StackPanel>
                <DockPanel LastChildFill="False">
                  <CheckBox x:Name="SchedStartChk" Style="{StaticResource SkipCfChk}" VerticalAlignment="Center" Margin="0,0,3,0"><TextBlock Text="START AT" FontSize="10" FontWeight="Bold" VerticalAlignment="Center"/></CheckBox>
                  <Border x:Name="SchedStartBox" CornerRadius="4" BorderThickness="1" BorderBrush="#FF333333" Background="#FF1A1A1A" Height="20" VerticalAlignment="Center" ToolTip="START AT time, every night (15-minute steps; the mouse wheel works too)">
                    <DockPanel>
                      <Button x:Name="SchedStartDn" Style="{StaticResource SchedStepBtn}" DockPanel.Dock="Left" Content="&#x2039;"/>
                      <Button x:Name="SchedStartUp" Style="{StaticResource SchedStepBtn}" DockPanel.Dock="Right" Content="&#x203A;"/>
                      <TextBlock x:Name="SchedStartVal" Text="11:00 PM" Width="50" FontSize="10.5" FontWeight="SemiBold" TextAlignment="Center" VerticalAlignment="Center"/>
                    </DockPanel>
                  </Border>
                  <Border x:Name="SchedTgtBox" DockPanel.Dock="Right" CornerRadius="4" BorderThickness="1" BorderBrush="#FF333333" Background="#FF1A1A1A" Height="20" VerticalAlignment="Center" Margin="3,0,0,0" ToolTip="FINISH BY target charge % (sets the car's charge limit only if it is different)">
                    <DockPanel>
                      <Button x:Name="SchedTgtDn" Style="{StaticResource SchedStepBtn}" DockPanel.Dock="Left" Content="&#x2039;"/>
                      <Button x:Name="SchedTgtUp" Style="{StaticResource SchedStepBtn}" DockPanel.Dock="Right" Content="&#x203A;"/>
                      <TextBlock x:Name="SchedTgtVal" Text="80%" Width="30" FontSize="10.5" FontWeight="SemiBold" TextAlignment="Center" VerticalAlignment="Center"/>
                    </DockPanel>
                  </Border>
                  <Border x:Name="SchedFinishBox" DockPanel.Dock="Right" CornerRadius="4" BorderThickness="1" BorderBrush="#FF333333" Background="#FF1A1A1A" Height="20" VerticalAlignment="Center" ToolTip="FINISH BY time: the car charges off-peak and is done by then (15-minute steps; the mouse wheel works too)">
                    <DockPanel>
                      <Button x:Name="SchedFinishDn" Style="{StaticResource SchedStepBtn}" DockPanel.Dock="Left" Content="&#x2039;"/>
                      <Button x:Name="SchedFinishUp" Style="{StaticResource SchedStepBtn}" DockPanel.Dock="Right" Content="&#x203A;"/>
                      <TextBlock x:Name="SchedFinishVal" Text="10:00 AM" Width="50" FontSize="10.5" FontWeight="SemiBold" TextAlignment="Center" VerticalAlignment="Center"/>
                    </DockPanel>
                  </Border>
                  <CheckBox x:Name="SchedFinishChk" DockPanel.Dock="Right" Style="{StaticResource SkipCfChk}" VerticalAlignment="Center" Margin="0,0,3,0" ToolTip="FINISH BY: the car finishes charging by this time at the target % (overrides START AT while on)"><TextBlock Text="FINISH BY" FontSize="10" FontWeight="Bold" VerticalAlignment="Center"/></CheckBox>
                </DockPanel>
                <DockPanel Margin="1,1,0,0" LastChildFill="True">
                  <TextBlock x:Name="SchedSync" DockPanel.Dock="Right" Text="" FontSize="9.5" FontWeight="SemiBold" Margin="6,0,0,0" MaxWidth="190" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="SchedEst" Text="" FontSize="9.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                </DockPanel>
              </StackPanel>
            </Border>
            <!-- v4.3.19: PLUG-IN REMINDER (evening, at home, unplugged, under the daily limit); clears when plugged in -->
            <Border x:Name="PlugRemBar" Grid.Row="4" Grid.ColumnSpan="2" Visibility="Collapsed" CornerRadius="6" Background="#40E82127" BorderBrush="#FFE82127" BorderThickness="1.5" Padding="8,2,8,3" Margin="0,4,0,0"
                    ToolTip="Plug-in reminder: evening, the car is home, unplugged and under its daily limit. Turn it off in BATTERY (Plug-in reminder).">
              <DockPanel LastChildFill="True">
                <TextBlock x:Name="PlugRemSub" DockPanel.Dock="Right" Text="" FontSize="10" FontWeight="SemiBold" Foreground="#FFFFFFFF" VerticalAlignment="Center" Margin="6,0,0,0"/>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <Ellipse x:Name="PlugRemDot" Width="9" Height="9" Fill="#FFE82127" VerticalAlignment="Center" Margin="0,1,6,0"/>
                  <TextBlock x:Name="PlugRemTxt" Text="PLUG IN TONIGHT" FontSize="13" FontWeight="Black" Foreground="#FFFF4D52" VerticalAlignment="Center"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <!-- v4.3.21: HEALTH HISTORY dropdown attached under START / STOP (moved from BATTERY HEALTH); starts collapsed, open/closed saved in config.json healthHistory.open -->
            <StackPanel x:Name="HHistWrap" Grid.Row="5" Grid.ColumnSpan="2" Margin="0,5,0,0">
              <Border x:Name="HHistBtn" Padding="9,4,9,4" CornerRadius="6" Background="#14FFFFFF" BorderBrush="#FF333333" BorderThickness="1" Cursor="Hand" ToolTip="Show or hide the daily battery health history (remembered)">
                <DockPanel LastChildFill="True">
                  <TextBlock x:Name="HHistSum" DockPanel.Dock="Right" FontSize="10.5" VerticalAlignment="Center"/>
                  <TextBlock x:Name="HHistHdr" Text="HEALTH HISTORY &#x25B8;" FontSize="10.5" FontWeight="Bold" Foreground="#FFFFFFFF" VerticalAlignment="Center"/>
                </DockPanel>
              </Border>
              <StackPanel x:Name="HHistBody" Visibility="Collapsed" Margin="2,5,2,0">
                <TextBlock x:Name="HHistSummary" FontSize="10" TextWrapping="Wrap" Margin="0,0,0,3"/>
                <TextBlock x:Name="HHistCal" FontSize="10" TextWrapping="Wrap" Margin="0,0,0,2"/>
                <TextBlock x:Name="HHistCalNote" FontSize="9.5" TextWrapping="Wrap" Margin="0,0,0,2"/>
                <TextBlock x:Name="HHistTip" FontSize="9.5" TextWrapping="Wrap" Margin="0,0,0,5"/>
                <Grid Margin="0,0,8,2">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="124"/><ColumnDefinition Width="50"/><ColumnDefinition Width="54"/><ColumnDefinition Width="68"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="HHistC0" Text="DATE" FontSize="9" FontWeight="Bold" Foreground="#FF8A8A8A"/>
                  <TextBlock x:Name="HHistC1" Grid.Column="1" Text="HEALTH" FontSize="9" FontWeight="Bold" Foreground="#FF8A8A8A" HorizontalAlignment="Right"/>
                  <TextBlock x:Name="HHistC2" Grid.Column="2" Text="CHANGE" FontSize="9" FontWeight="Bold" Foreground="#FF8A8A8A" HorizontalAlignment="Right"/>
                  <TextBlock x:Name="HHistC4" Grid.Column="3" Text="CHARGE" FontSize="9" FontWeight="Bold" Foreground="#FF8A8A8A" HorizontalAlignment="Right" ToolTip="Highest charge % reached that day. H = home, AC = other AC charger, SC = Supercharger, DC = DC fast; amber = fast charging"/>
                  <TextBlock x:Name="HHistC3" Grid.Column="4" Text="CAPACITY" FontSize="9" FontWeight="Bold" Foreground="#FF8A8A8A" HorizontalAlignment="Right"/>
                </Grid>
                <ScrollViewer x:Name="HHistScroll" MaxHeight="240" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" PanningMode="None" Focusable="False">
                  <StackPanel x:Name="HHistList" Margin="0,0,8,0"/>
                </ScrollViewer>
                <Button x:Name="HHistAllBtn" Style="{StaticResource CtlBtn}" Height="24" Margin="0,5,0,2" Padding="10,0,10,0" HorizontalAlignment="Center" Visibility="Collapsed" ToolTip="Show every logged day, or only the last 30">
                  <TextBlock x:Name="HHistAllTxt" Text="Show all" FontSize="10.5" FontWeight="Bold"/>
                </Button>
              </StackPanel>
            </StackPanel>
          </Grid>
        </Border>

        <!-- v4.2: lower sections scroll (slim scrollbar) when they don't fit the screen -->
        <ScrollViewer x:Name="BodyScroll" Grid.Row="4" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                      PanningMode="None" Focusable="False" Margin="0,0,-11,0">
          <StackPanel x:Name="BodyStack" Margin="0,0,5,0">
        <!-- v4.3.17: order = TESLA CONTROLS, START / STOP CHARGING, BATTERY + CHARGING AMPS, tiles, day-rate line, CHARGE HISTORY & TOTALS -->
        <Border x:Name="CtlCard" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="10,4,10,5" Margin="0,0,0,6">
          <StackPanel>
            <Grid x:Name="CtlHdrRow" Margin="0,0,0,3">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="CtlHdr" Grid.ColumnSpan="3" Text="TESLA CONTROLS" FontSize="12.5" FontWeight="Bold" Foreground="#FF9A9A9A" HorizontalAlignment="Left" VerticalAlignment="Center"/>
              <!-- v4.3.15: LEAVING SOON, same line as the heading, over the Flash Lights column (right edge = Flash Lights box right edge) -->
              <Button x:Name="LeaveBtn" Grid.Column="1" Style="{StaticResource CtlBtn}" Height="17" Margin="3,0,3,0" Padding="5,0,5,0" HorizontalAlignment="Right" VerticalAlignment="Center"
                      ToolTip="Leaving Soon: waits the Start after minutes, then climate on, close the windows after the Windows after minutes, unlock after the Unlock after minutes. Asks first; each step is announced on Alexa; Stop cancels the rest and undoes the steps already done. Stop during Start after just cancels.">
                <TextBlock x:Name="LeaveBtnTxt" Text="LEAVING SOON" FontSize="9" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Button>
              <TextBlock x:Name="CtlMode" Grid.Column="2" Text="" FontSize="10" FontWeight="Bold" Foreground="#FFFFB020" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <!-- v4.3.16: Leaving Soon waits, minutes 0-30 (default 3, 0 = right away), saved in config.json leavingSoon. v4.3.19: Start after (0-120, default 0) first -->
            <Viewbox x:Name="LeaveWaitFit" Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Right" Margin="0,-1,0,4">
            <StackPanel x:Name="LeaveWaitRow" Orientation="Horizontal" HorizontalAlignment="Right">
              <TextBlock x:Name="LeaveStartLbl" Text="Start after" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF9A9A9A" VerticalAlignment="Center" Margin="0,0,2,0"/>
              <Button x:Name="LeaveStartDn" Style="{StaticResource CtlBtn}" Width="16" Height="17" Padding="0" ToolTip="1 minute less"><TextBlock Text="&#x2212;" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/></Button>
              <TextBox x:Name="LeaveStartMin" Text="0" Width="26" Height="17" Margin="1,0,1,0" FontSize="10" FontWeight="Bold" TextAlignment="Center" VerticalContentAlignment="Center" Padding="0" MaxLength="3"
                       Background="#33000000" Foreground="#FFFFFFFF" BorderBrush="#FF49DF93" BorderThickness="1" CaretBrush="#FFFFFFFF" ToolTip="Leaving Soon: minutes to wait after you press LEAVING SOON before it starts (before climate turns on). 0-120, 0 = start right away; type a number, or use the mouse wheel or Up/Down"/>
              <Button x:Name="LeaveStartUp" Style="{StaticResource CtlBtn}" Width="16" Height="17" Padding="0" ToolTip="1 minute more"><TextBlock Text="+" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/></Button>
              <TextBlock Text="min" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF9A9A9A" VerticalAlignment="Center" Margin="2,0,7,0"/>
              <TextBlock x:Name="LeaveWinLbl" Text="Windows after" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF9A9A9A" VerticalAlignment="Center" Margin="0,0,2,0"/>
              <Button x:Name="LeaveWinDn" Style="{StaticResource CtlBtn}" Width="16" Height="17" Padding="0" ToolTip="1 minute less"><TextBlock Text="&#x2212;" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/></Button>
              <TextBox x:Name="LeaveWinMin" Text="3" Width="22" Height="17" Margin="1,0,1,0" FontSize="10" FontWeight="Bold" TextAlignment="Center" VerticalContentAlignment="Center" Padding="0" MaxLength="2"
                       Background="#33000000" Foreground="#FFFFFFFF" BorderBrush="#FF49DF93" BorderThickness="1" CaretBrush="#FFFFFFFF" ToolTip="Leaving Soon: minutes from climate on to closing the windows (0-30, 0 = right away; mouse wheel or Up/Down changes it)"/>
              <Button x:Name="LeaveWinUp" Style="{StaticResource CtlBtn}" Width="16" Height="17" Padding="0" ToolTip="1 minute more"><TextBlock Text="+" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/></Button>
              <TextBlock Text="min" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF9A9A9A" VerticalAlignment="Center" Margin="2,0,7,0"/>
              <TextBlock x:Name="LeaveUnlockLbl" Text="Unlock after" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF9A9A9A" VerticalAlignment="Center" Margin="0,0,2,0"/>
              <Button x:Name="LeaveUnlockDn" Style="{StaticResource CtlBtn}" Width="16" Height="17" Padding="0" ToolTip="1 minute less"><TextBlock Text="&#x2212;" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/></Button>
              <TextBox x:Name="LeaveUnlockMin" Text="3" Width="22" Height="17" Margin="1,0,1,0" FontSize="10" FontWeight="Bold" TextAlignment="Center" VerticalContentAlignment="Center" Padding="0" MaxLength="2"
                       Background="#33000000" Foreground="#FFFFFFFF" BorderBrush="#FF49DF93" BorderThickness="1" CaretBrush="#FFFFFFFF" ToolTip="Leaving Soon: minutes from closing the windows to unlocking (0-30, 0 = right away; mouse wheel or Up/Down changes it)"/>
              <Button x:Name="LeaveUnlockUp" Style="{StaticResource CtlBtn}" Width="16" Height="17" Padding="0" ToolTip="1 minute more"><TextBlock Text="+" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/></Button>
              <TextBlock Text="min" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF9A9A9A" VerticalAlignment="Center" Margin="2,0,0,0"/>
            </StackPanel>
            </Viewbox>
            <Border x:Name="LeaveRow" Visibility="Collapsed" CornerRadius="6" BorderThickness="1" BorderBrush="#FF49DF93" Background="#1A49DF93" Padding="7,3,4,3" Margin="0,0,0,6">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock x:Name="LeaveStep" Text="" FontSize="10.5" FontWeight="Bold" TextWrapping="Wrap" Foreground="#FFFFFFFF"/>
                  <TextBlock x:Name="LeaveNote" Text="" FontSize="9" TextWrapping="Wrap" Foreground="#FF9A9A9A" Visibility="Collapsed"/>
                </StackPanel>
                <Button x:Name="LeaveStopBtn" Grid.Column="1" Style="{StaticResource CtlBtn}" Height="20" Margin="6,0,0,0" Padding="9,0,9,0" VerticalAlignment="Center" ToolTip="Stop Leaving Soon: the remaining steps are cancelled">
                  <TextBlock x:Name="LeaveStopTxt" Text="STOP" FontSize="9.5" FontWeight="Bold" HorizontalAlignment="Center"/>
                </Button>
              </Grid>
            </Border>
            <UniformGrid Columns="3" Rows="1">
              <Button x:Name="LockBtn" Style="{StaticResource CtlBtn}" Height="54" Margin="0,0,3,0" Padding="4,4,4,4" ToolTip="Lock / unlock your Tesla">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="LockIcon" Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="18" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="3,0,0,0">
                    <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="LockTxt" Text="LOCK" FontSize="16" FontWeight="Bold"/></Viewbox>
                    <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="LockSub" Text="" FontSize="10" Foreground="#FF888888"/></Viewbox>
                  </StackPanel>
                </Grid>
              </Button>
              <Border x:Name="FlashBox" Height="54" Margin="3,0,3,0" CornerRadius="10" BorderThickness="1.5" BorderBrush="#FF49DF93" Background="#2649DF93" Padding="5,2,5,2" ToolTip="Flash the headlights (Tessie flash), 1-20 times with the pause you set (1-30 s). Asks first; Stop ends early.">
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
              <Button x:Name="ClimBtn" Style="{StaticResource CtlBtn}" Height="54" Margin="3,0,0,0" Padding="4,4,4,4" ToolTip="Turn climate (A/C) on or off">
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
            <UniformGrid Columns="3" Rows="1" Margin="0,4,0,0">
              <Button x:Name="HeatBtn" Style="{StaticResource CtlBtn}" Height="44" Margin="0,0,3,0" Padding="3,2,3,2" ToolTip="Heat = climate on with a warm set temperature (Tesla has no separate heater command)">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="HeatIcon" Text="♨" FontFamily="Segoe UI Symbol" FontSize="13" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="HeatTxt" Text="HEAT" FontSize="12.5" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Center" MaxWidth="96"><TextBlock x:Name="HeatSub" Text="" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/></Viewbox>
                </StackPanel>
              </Button>
              <Button x:Name="DefrostBtn" Style="{StaticResource CtlBtn}" Height="44" Margin="3,0,3,0" Padding="3,2,3,2" ToolTip="Max defrost on / off">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="DefrostIcon" Text="❄" FontFamily="Segoe UI Symbol" FontSize="13" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DefrostTxt" Text="DEFROST" FontSize="12.5" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Center" MaxWidth="96"><TextBlock x:Name="DefrostSub" Text="" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/></Viewbox>
                </StackPanel>
              </Button>
              <Button x:Name="CopBtn" Style="{StaticResource CtlBtn}" Height="44" Margin="3,0,0,0" Padding="3,2,3,2" ToolTip="Cabin Overheat Protection: off, on, fan only">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="CopIcon" Text="☀" FontFamily="Segoe UI Symbol" FontSize="13" Margin="0,0,4,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="CopTxt" Text="OVERHEAT" FontSize="12.5" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Center" MaxWidth="96"><TextBlock x:Name="CopSub" Text="" FontSize="9" FontWeight="SemiBold" Foreground="#FF888888"/></Viewbox>
                </StackPanel>
              </Button>
            </UniformGrid>
            <Grid Margin="0,4,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/>
                <ColumnDefinition Width="40"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="VentBtn" Grid.Column="0" Style="{StaticResource CtlBtn}" Height="38" Margin="0,0,3,0" Padding="2" ToolTip="Vent all windows">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock x:Name="VentTxt" Text="VENT" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="VentSub" Text="WINDOWS" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="CloseWinBtn" Grid.Column="1" Style="{StaticResource CtlBtn}" Height="38" Margin="3,0,0,0" Padding="2" ToolTip="Close all windows">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock x:Name="CloseWinTxt" Text="CLOSE" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="CloseWinSub" Text="WINDOWS" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="TempDownBtn" Grid.Column="3" Style="{StaticResource CtlBtn}" Height="38" Padding="0" ToolTip="Cooler">
                <TextBlock Text="−" FontSize="22" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,-4,0,0"/>
              </Button>
              <StackPanel Grid.Column="4" VerticalAlignment="Center">
                <TextBlock x:Name="TempVal" Text="--" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center"/>
                <TextBlock x:Name="TempCap" Text="SET TEMP" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF7A7A7A" HorizontalAlignment="Center"/>
              </StackPanel>
              <Button x:Name="TempUpBtn" Grid.Column="5" Style="{StaticResource CtlBtn}" Height="38" Padding="0" ToolTip="Warmer">
                <TextBlock Text="+" FontSize="20" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,-3,0,0"/>
              </Button>
            </Grid>
            <!-- v4.3.3: OPEN TRUNK (rear only, asks first) + SENTRY MODE on/off (shows the car's state, asks first) -->
            <Grid Margin="0,4,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Button x:Name="TrunkBtn" Grid.Column="0" Style="{StaticResource CtlBtn}" Height="38" Margin="0,0,3,0" Padding="2" ToolTip="Open the rear trunk (asks Are you sure? first)">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="TrunkIcon" Text="&#xE7EF;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <TextBlock x:Name="TrunkTxt" Text="OPEN TRUNK" FontSize="13" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock x:Name="TrunkSub" Text="REAR" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="SentryBtn" Grid.Column="1" Style="{StaticResource CtlBtn}" Height="38" Margin="3,0,0,0" Padding="2" ToolTip="Sentry Mode on / off (shows the car's current state, asks first)">
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
            <Grid Margin="0,4,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions>
              <Button x:Name="AnnNowBtn" Style="{StaticResource CtlBtn}" Height="38" Margin="0,0,3,0" Padding="4,2,4,2" ToolTip="Announce on Alexa: one push speaks a full status rundown (asks to confirm)">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock Text="&#xE767;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <TextBlock x:Name="AnnNowTxt" Text="ANNOUNCE ON ALEXA" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock x:Name="AnnNowSub" Text="FULL STATUS" FontSize="7.5" FontWeight="SemiBold" Foreground="#FF888888" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
              </Button>
              <Button x:Name="AnnSetupBtn" Grid.Column="1" Style="{StaticResource CtlBtn}" Height="38" Margin="3,0,0,0" Padding="0" ToolTip="Announce Setup: rundown items, speakers (pick Echos, Test, Add speaker), charging-started announcement">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="15" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="AnnSetupTxt" Text="SETUP" FontSize="8" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,2,0,0"/>
                </StackPanel>
              </Button>
            </Grid>
            <Border x:Name="CtlResultBox" CornerRadius="6" Background="#FF0F0F0F" Margin="0,4,0,0" Padding="8,3,8,3" MinHeight="22">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Ellipse x:Name="CtlSpin" Width="13" Height="13" StrokeThickness="2.2" Stroke="#FF49DF93" StrokeDashArray="5 3"
                         Margin="0,0,7,0" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5" Visibility="Collapsed">
                  <Ellipse.RenderTransform><RotateTransform x:Name="CtlSpinRot" Angle="0"/></Ellipse.RenderTransform>
                </Ellipse>
                <TextBlock x:Name="CtlResult" Grid.Column="1" Text="Ready" FontSize="10" TextWrapping="Wrap" VerticalAlignment="Center" Foreground="#FF888888"/>
              </Grid>
            </Border>
            <Border x:Name="SkipCfRow" Margin="0,4,0,0" Padding="6,1,4,1" CornerRadius="6" BorderThickness="1" BorderBrush="#33FFFFFF" ToolTip="Skip confirm: a checked action runs right away, with no Yes/No or Are-you-sure pop-up. Each one is saved in your settings and stays checked after restarts and updates.">
              <DockPanel x:Name="SkipCfWrap" LastChildFill="True">
                <TextBlock x:Name="SkipCfHdr" DockPanel.Dock="Left" Text="SKIP&#x0a;CONFIRM" FontSize="9" FontWeight="Bold" LineHeight="10" LineStackingStrategy="BlockLineHeight" Foreground="#FF9A9A9A" VerticalAlignment="Center" TextAlignment="Center" Margin="0,0,5,0"/>
                <UniformGrid x:Name="SkipCfGrid" Columns="5" Rows="3">
                  <CheckBox x:Name="SkipCf_unlock" Tag="unlock" Style="{StaticResource SkipCfChk}" ToolTip="Skip confirm for UNLOCK (the LOCKED button): unlocks right away"><TextBlock Text="Unlock" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_leave" Tag="leave" Style="{StaticResource SkipCfChk}" ToolTip="Skip the 'Are you sure? Start Leaving Soon?' pop-up"><TextBlock Text="Leaving" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_flash" Tag="flash" Style="{StaticResource SkipCfChk}" ToolTip="Skip confirm for FLASH LIGHTS"><TextBlock Text="Flash" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_vent" Tag="vent" Style="{StaticResource SkipCfChk}" ToolTip="Skip confirm for VENT windows"><TextBlock Text="Vent" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_trunk" Tag="trunk" Style="{StaticResource SkipCfChk}" ToolTip="Skip the 'Are you sure?' pop-up when opening or closing the TRUNK"><TextBlock Text="Trunk" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_sentry" Tag="sentry" Style="{StaticResource SkipCfChk}" ToolTip="Skip confirm when turning SENTRY on or off"><TextBlock Text="Sentry" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_announce" Tag="announce" Style="{StaticResource SkipCfChk}" ToolTip="Skip confirm for ANNOUNCE full status on Alexa"><TextBlock Text="Announce" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_stopCharging" Tag="stopCharging" Style="{StaticResource SkipCfChk}" ToolTip="Skip 'Stop charging now?' (the STOP button in the charging bar)"><TextBlock Text="Stop chg" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_limit" Tag="limit" Style="{StaticResource SkipCfChk}" ToolTip="Skip confirm when you drag the charge limit on the battery bar"><TextBlock Text="Limit" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_amps" Tag="amps" Style="{StaticResource SkipCfChk}" ToolTip="Skip confirm when you set the charging amps"><TextBlock Text="Amps" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                  <CheckBox x:Name="SkipCf_schedule" Tag="schedule" Style="{StaticResource SkipCfChk}" ToolTip="Skip confirm when you change the CHARGING SCHEDULE (START AT / FINISH BY)"><TextBlock Text="Sched" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/></CheckBox>
                </UniformGrid>
              </DockPanel>
            </Border>
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
            <Canvas x:Name="BarDark" Width="286" Height="40" HorizontalAlignment="Left" Margin="0,4,0,0" Background="Transparent">
              <Rectangle x:Name="BarTrack" Canvas.Left="13" Canvas.Top="16" Width="260" Height="8" RadiusX="4" RadiusY="4" Fill="#FF2A2A2A"/>
              <Rectangle x:Name="BarFrom" Canvas.Left="13" Canvas.Top="16" Width="0" Height="8" RadiusX="4" RadiusY="4" Fill="#FFE82127" Opacity="0.35"/>
              <Rectangle x:Name="BarFill" Canvas.Left="13" Canvas.Top="16" Width="0" Height="8" RadiusX="4" RadiusY="4" Fill="#FFE82127"/>
              <Rectangle x:Name="FromTick" Canvas.Left="13" Canvas.Top="10" Width="2" Height="20" Fill="#FFCCCCCC" Opacity="0.8"/>
              <Border x:Name="LimitThumb" Canvas.Left="0" Canvas.Top="9" Width="4" Height="22" CornerRadius="2" Background="#FFFFFFFF" BorderThickness="0" ToolTip="Charge limit (set it with the slider on the right)"/>
              <Grid x:Name="BarBall" Canvas.Left="0" Canvas.Top="7" Width="26" Height="26">
                <Ellipse x:Name="BarBallDot" Fill="#FFE82127" Stroke="#FF0B0B0B" StrokeThickness="2.5"/>
                <TextBlock x:Name="BarBallText" Text="" FontSize="8" FontWeight="Bold" Foreground="#FF0B0B0B" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
            </Canvas>
            <Grid Margin="0,5,0,0" Width="286" HorizontalAlignment="Left">
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
            <!-- v4.3.19: MORNING READY CHECK (cached data only; big 5-10 AM, one line otherwise) -->
            <Border x:Name="ReadyBox" CornerRadius="6" BorderThickness="1" BorderBrush="#FF49DF93" Background="#1A49DF93" Padding="8,3,8,4" Margin="0,6,0,0">
              <StackPanel>
                <DockPanel LastChildFill="True">
                  <TextBlock x:Name="ReadyWhen" DockPanel.Dock="Right" Text="" FontSize="9.5" Foreground="#FF9A9A9A" VerticalAlignment="Center"/>
                  <TextBlock x:Name="ReadyHdr" Text="MORNING READY CHECK" FontSize="10.5" FontWeight="Bold" Foreground="#FF9A9A9A" VerticalAlignment="Center"/>
                  <Border x:Name="ReadyPill" CornerRadius="4" Padding="6,0,6,1" Margin="7,0,0,0" HorizontalAlignment="Left" VerticalAlignment="Center" Background="#FF49DF93">
                    <TextBlock x:Name="ReadyPillTxt" Text="READY" FontSize="11" FontWeight="Black" Foreground="#FF0B0B0B"/>
                  </Border>
                </DockPanel>
                <TextBlock x:Name="ReadyOff" Text="" FontSize="10.5" FontWeight="SemiBold" TextWrapping="Wrap" Foreground="#FFFFB547" Margin="0,2,0,0" Visibility="Collapsed"/>
                <UniformGrid x:Name="ReadyGrid" Columns="2" Margin="0,3,0,0"/>
                <TextBlock x:Name="ReadyLine" Text="" FontSize="10" TextWrapping="Wrap" Foreground="#FFCCCCCC" Margin="0,2,0,0"/>
              </StackPanel>
            </Border>
            <!-- v4.2: CHARGING AMPS slider (same build as the limit slider) -->
            <Border x:Name="AmpsSep" Height="1" Background="#FF222222" Margin="0,8,0,6"/>
            <DockPanel LastChildFill="True">
              <TextBlock x:Name="AmpsNow" DockPanel.Dock="Right" Text="" FontSize="10" FontWeight="SemiBold" Foreground="#FFCCCCCC" VerticalAlignment="Center"/>
              <TextBlock x:Name="AmpsHdr" Text="CHARGING AMPS" FontSize="11" FontWeight="Bold" Foreground="#FF9A9A9A"/>
            </DockPanel>
            <Canvas x:Name="AmpsDark" Width="386" Height="40" HorizontalAlignment="Center" Margin="0,4,0,0" Background="Transparent">
              <Rectangle x:Name="AmpsTrack" Canvas.Left="13" Canvas.Top="16" Width="360" Height="8" RadiusX="4" RadiusY="4" Fill="#FF2A2A2A"/>
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
            <!-- v4.3.19: PSO BILL MATCH (on/off switch; off = one small row) -->
            <Border x:Name="BillSep" Height="1" Background="#FF222222" Margin="0,8,0,5"/>
            <DockPanel x:Name="BillHead" LastChildFill="True">
              <ToggleButton x:Name="BillSwitch" DockPanel.Dock="Right" Style="{StaticResource SwitchStyle}" Tag="#FF49DF93" IsChecked="True" VerticalAlignment="Center" ToolTip="PSO BILL MATCH on / off (off hides the card and its calculations; saved)"/>
              <TextBlock x:Name="BillState" DockPanel.Dock="Right" Text="" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF888888" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock x:Name="BillHdr" Text="PSO BILL MATCH" FontSize="11" FontWeight="Bold" Foreground="#FF9A9A9A" VerticalAlignment="Center"/>
            </DockPanel>
            <StackPanel x:Name="BillBody" Margin="0,4,0,0">
              <Grid x:Name="BillInputs">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Margin="0,0,4,0"><TextBlock x:Name="BillFromLbl" Text="PERIOD FROM" FontSize="8.5" FontWeight="Bold" Foreground="#FF8A8A8A"/>
                  <TextBox x:Name="BillFrom" Height="22" FontSize="10.5" Padding="2,0,2,0" VerticalContentAlignment="Center" Background="#33000000" Foreground="#FFFFFFFF" BorderBrush="#FF444444" CaretBrush="#FFFFFFFF" ToolTip="First day of the PSO billing period (e.g. 8/26/2026)"/></StackPanel>
                <StackPanel Grid.Column="1" Margin="0,0,4,0"><TextBlock x:Name="BillToLbl" Text="TO" FontSize="8.5" FontWeight="Bold" Foreground="#FF8A8A8A"/>
                  <TextBox x:Name="BillTo" Height="22" FontSize="10.5" Padding="2,0,2,0" VerticalContentAlignment="Center" Background="#33000000" Foreground="#FFFFFFFF" BorderBrush="#FF444444" CaretBrush="#FFFFFFFF" ToolTip="Last day of the billing period"/></StackPanel>
                <StackPanel Grid.Column="2" Margin="0,0,4,0"><TextBlock x:Name="BillKwhLbl" Text="TOTAL kWh" FontSize="8.5" FontWeight="Bold" Foreground="#FF8A8A8A"/>
                  <TextBox x:Name="BillKwh" Height="22" FontSize="10.5" Padding="2,0,2,0" VerticalContentAlignment="Center" Background="#33000000" Foreground="#FFFFFFFF" BorderBrush="#FF444444" CaretBrush="#FFFFFFFF" ToolTip="Total kWh used on the bill"/></StackPanel>
                <StackPanel Grid.Column="3" Margin="0,0,4,0"><TextBlock x:Name="BillUsdLbl" Text="TOTAL &#x24;" FontSize="8.5" FontWeight="Bold" Foreground="#FF8A8A8A"/>
                  <TextBox x:Name="BillUsd" Height="22" FontSize="10.5" Padding="2,0,2,0" VerticalContentAlignment="Center" Background="#33000000" Foreground="#FFFFFFFF" BorderBrush="#FF444444" CaretBrush="#FFFFFFFF" ToolTip="Total amount of the bill in dollars"/></StackPanel>
                <Button x:Name="BillSaveBtn" Grid.Column="4" Style="{StaticResource CtlBtn}" Width="44" Height="22" VerticalAlignment="Bottom" Padding="0" ToolTip="Save the bill numbers (settings) and recalculate"><TextBlock Text="SAVE" FontSize="10" FontWeight="Bold"/></Button>
              </Grid>
              <TextBlock x:Name="BillSrc" Text="" FontSize="9" Foreground="#FF888888" TextWrapping="Wrap" Margin="0,3,0,0"/>
              <TextBlock x:Name="BillRes1" Text="" FontSize="10.5" FontWeight="SemiBold" Foreground="#FFFFFFFF" TextWrapping="Wrap" Margin="0,3,0,0"/>
              <TextBlock x:Name="BillRes2" Text="" FontSize="10" Foreground="#FFCCCCCC" TextWrapping="Wrap" Margin="0,1,0,0"/>
              <Border x:Name="BillFlag" CornerRadius="5" BorderThickness="1" BorderBrush="#FFFFB547" Background="#26FFB547" Padding="6,2,6,3" Margin="0,3,0,0" Visibility="Collapsed">
                <TextBlock x:Name="BillFlagTxt" Text="" FontSize="10" FontWeight="SemiBold" Foreground="#FFFFB547" TextWrapping="Wrap"/>
              </Border>
            </StackPanel>
            <!-- v4.3.19: BATTERY HEALTH TREND + TIPS -->
            <StackPanel x:Name="HealthBox">
            <Border x:Name="HealthSep" Height="1" Background="#FF222222" Margin="0,8,0,5"/>
            <DockPanel LastChildFill="True">
              <TextBlock x:Name="HealthAsOf" DockPanel.Dock="Right" Text="" FontSize="9.5" FontWeight="SemiBold" Foreground="#FF888888" VerticalAlignment="Center"/>
              <TextBlock x:Name="HealthHdr" Text="BATTERY HEALTH" FontSize="11" FontWeight="Bold" Foreground="#FF9A9A9A"/>
            </DockPanel>
            <Grid Margin="0,2,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="HealthPct" Text="--" FontSize="26" FontWeight="Bold" Foreground="#FFFFFFFF"/>
                <TextBlock x:Name="HealthPctCap" Text="HEALTH" FontSize="8.5" FontWeight="Bold" Foreground="#FF8A8A8A" Margin="0,-3,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="1" Margin="12,1,8,0" VerticalAlignment="Center">
                <TextBlock x:Name="HealthL1" Text="" FontSize="11" FontWeight="SemiBold" Foreground="#FFFFFFFF"/>
                <TextBlock x:Name="HealthL2" Text="" FontSize="10" Foreground="#FFCCCCCC"/>
                <TextBlock x:Name="HealthTrend" Text="" FontSize="9.5" Foreground="#FF9A9A9A" TextWrapping="Wrap"/>
              </StackPanel>
              <StackPanel Grid.Column="2" VerticalAlignment="Center">
                <Canvas x:Name="HealthSpark" Width="130" Height="36" ClipToBounds="False">
                  <Polyline x:Name="HealthLine" Stroke="#FF49DF93" StrokeThickness="1.8" StrokeLineJoin="Round"/>
                  <Ellipse x:Name="HealthDot" Width="6" Height="6" Fill="#FF49DF93"/>
                </Canvas>
                <TextBlock x:Name="HealthSparkCap" Text="" FontSize="8.5" Foreground="#FF888888" HorizontalAlignment="Center" Margin="0,2,0,0"/>
              </StackPanel>
            </Grid>
            <TextBlock x:Name="TipsHdr" Text="TIPS FROM YOUR DATA" FontSize="9.5" FontWeight="Bold" Foreground="#FF9A9A9A" Margin="0,6,0,1"/>
            <StackPanel x:Name="TipsList"/>
            </StackPanel>
            <!-- v4.3.19: plug-in reminder setting (on by default) -->
            <Border x:Name="PlugSetSep" Height="1" Background="#FF222222" Margin="0,7,0,5"/>
            <DockPanel x:Name="PlugSetRow" LastChildFill="True">
              <ToggleButton x:Name="PlugRemSwitch" DockPanel.Dock="Right" Style="{StaticResource SwitchStyle}" Tag="#FF49DF93" IsChecked="True" VerticalAlignment="Center" ToolTip="Plug-in reminder on / off (saved)"/>
              <TextBlock x:Name="PlugSetTxt" Text="Plug-in reminder" FontSize="10" FontWeight="SemiBold" Foreground="#FFCCCCCC" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,8,0"/>
            </DockPanel>
          </StackPanel>
        </Border>

        <!-- v4.3.19: TRIPS (Tessie /drives, grouped by day; cost = kWh x your home charging $/kWh) -->
        <Border x:Name="TripsCard" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="12,6,12,7" Margin="0,0,0,6">
          <StackPanel>
            <DockPanel LastChildFill="True">
              <Border x:Name="TripsSumPill" DockPanel.Dock="Right" CornerRadius="9" Background="#1FFFFFFF" Padding="8,1,8,2" VerticalAlignment="Center">
                <TextBlock x:Name="TripsSumPillTxt" Text="" FontSize="11" FontWeight="SemiBold" Foreground="#FFCCCCCC"/>
              </Border>
              <TextBlock x:Name="TripsHdr" Text="TRIPS" FontSize="12.5" FontWeight="Bold" Foreground="#FF9A9A9A" VerticalAlignment="Center"/>
            </DockPanel>
            <Border x:Name="TripsSumBox" CornerRadius="6" Background="#14FFFFFF" Padding="8,3,8,4" Margin="0,4,0,2">
              <StackPanel>
                <TextBlock x:Name="TripsSumHdr" Text="LAST 7 DAYS" FontSize="8.5" FontWeight="Bold" Foreground="#FF8A8A8A"/>
                <UniformGrid x:Name="TripsSumGrid" Columns="5" Rows="1" Margin="0,1,0,0">
                  <StackPanel><TextBlock x:Name="TripsS0" Text="--" FontSize="13" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Center"/><TextBlock x:Name="TripsSL0" Text="TRIPS" FontSize="8" FontWeight="Bold" Foreground="#FF8A8A8A" HorizontalAlignment="Center"/></StackPanel>
                  <StackPanel><TextBlock x:Name="TripsS1" Text="--" FontSize="13" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Center"/><TextBlock x:Name="TripsSL1" Text="MILES" FontSize="8" FontWeight="Bold" Foreground="#FF8A8A8A" HorizontalAlignment="Center"/></StackPanel>
                  <StackPanel><TextBlock x:Name="TripsS2" Text="--" FontSize="13" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Center"/><TextBlock x:Name="TripsSL2" Text="kWh" FontSize="8" FontWeight="Bold" Foreground="#FF8A8A8A" HorizontalAlignment="Center"/></StackPanel>
                  <StackPanel><TextBlock x:Name="TripsS3" Text="--" FontSize="13" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Center"/><TextBlock x:Name="TripsSL3" Text="COST" FontSize="8" FontWeight="Bold" Foreground="#FF8A8A8A" HorizontalAlignment="Center"/></StackPanel>
                  <StackPanel><TextBlock x:Name="TripsS4" Text="--" FontSize="13" FontWeight="Bold" Foreground="#FFFFFFFF" HorizontalAlignment="Center"/><TextBlock x:Name="TripsSL4" Text="AVG mi/kWh" FontSize="8" FontWeight="Bold" Foreground="#FF8A8A8A" HorizontalAlignment="Center"/></StackPanel>
                </UniformGrid>
              </StackPanel>
            </Border>
            <TextBlock x:Name="TripsRate" Text="" FontSize="9" Foreground="#FF888888" TextWrapping="Wrap" Margin="0,1,0,2"/>
            <StackPanel x:Name="TripsList"/>
            <Button x:Name="TripsMoreBtn" Style="{StaticResource CtlBtn}" Height="24" Margin="0,5,0,0" Padding="10,0,10,0" HorizontalAlignment="Center" ToolTip="Show more trips (30 days) or fewer (7 days); remembered">
              <TextBlock x:Name="TripsMoreTxt" Text="Show more" FontSize="10.5" FontWeight="Bold"/>
            </Button>
          </StackPanel>
        </Border>

        <!-- v4.3.18: old POWER / DURATION / ENDED tiles replaced by the CHARGING STATUS bar; kept collapsed (Render-View still fills them) -->
        <UniformGrid x:Name="TilesRow" Columns="3" Rows="1" Margin="0,0,0,6" Visibility="Collapsed">
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
        <!-- v4.3.17: CHARGE HISTORY & TOTALS dropdown (Last night + sessions, Last 7 / 30 days, TOTALS). Starts collapsed; open / closed saved in config.json ui.historyOpen -->
        <Border x:Name="RowsCard" CornerRadius="10" Background="#FF111111" BorderBrush="#FF222222" BorderThickness="1" Padding="10,3,10,3" Margin="0,0,0,6">
          <StackPanel>
            <Button x:Name="ChgHistBtn" Style="{StaticResource HistHdrBtn}" Height="24" Padding="0" ToolTip="Show Last night, Last 7 days, Last 30 days and TOTALS">
              <DockPanel LastChildFill="True">
                <TextBlock x:Name="ChgHistArrow" DockPanel.Dock="Right" Text="&#x25B8;" FontFamily="Segoe UI Symbol" FontSize="12" FontWeight="Bold" Foreground="#FF9A9A9A" VerticalAlignment="Center" Margin="7,0,0,1"/>
                <TextBlock x:Name="ChgHistSum" DockPanel.Dock="Right" Text="" FontSize="10.5" FontWeight="SemiBold" Foreground="#FFCCCCCC" VerticalAlignment="Center" Margin="6,0,0,0"/>
                <TextBlock x:Name="ChgHistHdr" Text="CHARGE HISTORY &amp; TOTALS" FontSize="11" FontWeight="Bold" Foreground="#FF9A9A9A" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </DockPanel>
            </Button>
            <StackPanel x:Name="ChgHistBody" Visibility="Collapsed">
            <Border x:Name="ChgHistSep" Height="1" Background="#FF222222" Margin="0,1,0,1"/>
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
          <!-- v4.3.12: Restore / Remember moved to the top right (fade in on mouse move, like Paycheck Live); SHARE stays here -->
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,5,0,0">
            <!-- v4.3.7: SHARE the TessDesk links (Messenger, text, email, copy, send to phone); never a token, never sent automatically -->
            <Border x:Name="ShareBtn" CornerRadius="8" BorderBrush="#FF49DF93" BorderThickness="1.5" Background="#1A49DF93" Padding="9,1,9,2" Margin="0,0,0,0" Cursor="Hand" VerticalAlignment="Center"
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
    <!-- v4.3.12: Restore / Remember at the top right under the title bar, exactly like Paycheck Live (Margin 0,34,14,0; fade in on mouse move, hide 2.2 s after the mouse stops) -->
    <StackPanel x:Name="DwRow" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,34,14,0" Opacity="0" IsHitTestVisible="False" Panel.ZIndex="50">
      <Border x:Name="RestoreBtn" CornerRadius="4" Background="#FF444444" Padding="6,0,6,0" Height="16" Cursor="Hand" VerticalAlignment="Center"
              ToolTip="Restore TessDesk to its saved size and place">
        <TextBlock x:Name="RestoreTxt" Text="&#x27F2; Restore" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" Foreground="#FFDDDDDD" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <Border x:Name="KeepBtn" CornerRadius="4" Background="#FF444444" Padding="6,0,6,0" Height="16" Margin="3,0,0,0" Cursor="Hand" VerticalAlignment="Center"
              ToolTip="Remember TessDesk's current size and place (used by Restore and startup)">
        <TextBlock x:Name="KeepTxt" Text="Remember" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" Foreground="#FFDDDDDD" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </StackPanel>
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
    foreach ($n in 'TiresCard', 'RowsCard', 'BattCard', 'CtlCard', 'SeatsCard', 'DrivesCard', 'CamCard', 'TripsCard') {
        $ui[$n].Background = T 'CardBg'; $ui[$n].BorderBrush = T 'CardBorder'
        $ui[$n].CornerRadius = [System.Windows.CornerRadius]::new($th.CardRadius)
    }
    foreach ($i in 0, 1, 2) {
        $ui['Tile' + $i].Background = T 'TileBg'
        $ui['Tile' + $i].CornerRadius = [System.Windows.CornerRadius]::new($th.TileRadius)
        $ui['TileLbl' + $i].Foreground = T 'Caption'
    }
    foreach ($n in 'RowSep1', 'RowSep2', 'RowSep3', 'ChgHistSep') { $ui[$n].Background = T 'Sep' }
    foreach ($n in 'NightLbl', 'D7Lbl', 'D30Lbl') { $ui[$n].Foreground = T 'TextSoft' }
    foreach ($n in 'NightCap', 'D7Cap', 'D30Cap', 'NightKwh', 'D7Kwh', 'D30Kwh') { $ui[$n].Foreground = T 'Caption2' }
    $ui.TiresAsOf.Foreground = T 'TextSoft'; $ui.TiresRec.Foreground = T 'Caption'; $ui.RemindSetup.Foreground = T 'Caption'
    foreach ($n in 'TiresHdr', 'BattHdr', 'CtlHdr', 'SeatsHdr', 'AmpsHdr', 'ChgHistHdr', 'ChgHistArrow') { $ui[$n].Foreground = T 'TextSoft' }
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
        $View.d14 = Get-PeriodTotal $st $nowE 14
        $View.d30 = Get-PeriodTotal $st $nowE 30
        $View.d60 = Get-PeriodTotal $st $nowE 60
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
        night = $null; d7 = $null; d14 = $null; d30 = $null; d60 = $null; periodSource = ''; rateNote = ''; statusNote = ''; car = $null
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
    $dm = [math]::Max(0.0, ((ConvertFrom-Epoch $s.lastEpoch) - $stLocal).TotalMinutes)   # v4.3.18: status bar
    $v | Add-Member -NotePropertyName chgInfo -NotePropertyValue ([ordered]@{ kw = $kw; sub = $kwSub; durMin = $dm; dur = (Format-Duration $dm); fullAt = $(if ($tf -eq 'Done') { 'Done' } elseif ($tfSub -like 'done ~*') { $tfSub.Substring(5) } else { $tf }); endedClock = '' }) -Force
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
    $v | Add-Member -NotePropertyName chgInfo -NotePropertyValue ([ordered]@{ kw = '0 kW'; sub = $durSub; durMin = $null; dur = $dur; fullAt = ''; endedClock = (Format-Clock $endLocal); endedDay = $endLocal.ToString('ddd MMM d', $Inv) }) -Force   # v4.3.18: status bar
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

$BarX = 13.0; $BarW = 360.0   # v4.3.19: amps bar widened with the window
$BBarX = 13.0; $BBarW = 260.0   # v4.3.19: battery bar widened with the window (vertical limit slider stays on the right)
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

# ---------------- v4.3.14: rolling 7 / 14 days (left) and 30 / 60 days (right) $ beside the big amount ----------------
# Money only. All four come from Get-PeriodTotal (whole charges that STARTED in the period, home + Supercharger paid), the
# same shared calculation and Format-Money as the Last 7 days / Last 30 days rows. 7 and 30 always equal the rows.
$script:RollBase = 17.0
function Get-TbWidth { param($Tb, [string]$Text, [double]$Size)
    $tf = New-Object System.Windows.Media.Typeface($Tb.FontFamily, $Tb.FontStyle, $Tb.FontWeight, $Tb.FontStretch)
    $ft = New-Object System.Windows.Media.FormattedText($Text, [Globalization.CultureInfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, $tf, $Size, [System.Windows.Media.Brushes]::White, 1.0)
    return $ft
}
function Get-TbCapH { param($Tb, [double]$Size)
    $tf = New-Object System.Windows.Media.Typeface($Tb.FontFamily, $Tb.FontStyle, $Tb.FontWeight, $Tb.FontStretch)
    return ($tf.CapsHeight * $Size)
}
function Get-RollStackInk {
    # ink top (cap top of the upper caption) and ink bottom (baseline of the lower amount) inside one side stack, from font metrics
    param($CapA, $CostA, $CapB, $CostB, [double]$Size, [double]$Gap)
    $ca = Get-TbWidth $CapA $CapA.Text $CapA.FontSize; $a = Get-TbWidth $CostA $CostA.Text $Size
    $cb = Get-TbWidth $CapB $CapB.Text $CapB.FontSize; $b = Get-TbWidth $CostB $CostB.Text $Size
    $top = $ca.Baseline - (Get-TbCapH $CapA $CapA.FontSize)
    $bottom = $ca.Height + 1 + $a.Height + $Gap + $cb.Height + 1 + $b.Baseline
    return @($top, $bottom)
}
function Set-HeroRollFit {
    # one font size for all four (symmetric); shrink together only if one would not fit; each stack is centered on the big amount's digits
    try {
        $rowW = $ui.HeroRow.ActualWidth; if ($rowW -le 0) { $rowW = 330 }
        $hf = Get-TbWidth $ui.HeroCost $ui.HeroCost.Text $ui.HeroCost.FontSize
        $side = ($rowW - $hf.WidthIncludingTrailingWhitespace) / 2 - 17 - 4
        $size = $script:RollBase
        $names = 'Roll7Cost', 'Roll14Cost', 'Roll30Cost', 'Roll60Cost'
        while ($size -gt 11) {
            $w = 0.0; foreach ($n in $names) { $w = [math]::Max($w, (Get-TbWidth $ui[$n] $ui[$n].Text $size).WidthIncludingTrailingWhitespace) }
            if ($w -le $side) { break }
            $size -= 0.5
        }
        foreach ($n in $names) { $ui[$n].FontSize = $size }
        $gap = [double]$ui.Roll14.Margin.Top
        $ink = Get-RollStackInk $ui.Roll7Cap $ui.Roll7Cost $ui.Roll14Cap $ui.Roll14Cost $size $gap
        $heroMid = $hf.Baseline - (Get-TbCapH $ui.HeroCost $ui.HeroCost.FontSize) / 2
        $stackMid = ($ink[0] + $ink[1]) / 2
        $d = $heroMid - $stackMid
        if ($d -ge 0) { $hm = 0.0; $sm = $d } else { $hm = - $d; $sm = 0.0 }
        $ui.HeroCost.Margin = New-Object System.Windows.Thickness(0, $hm, 0, 0)
        $m = New-Object System.Windows.Thickness(0, $sm, 0, 0)
        $ui.RollL.Margin = $m; $ui.RollR.Margin = $m
        $dh = [math]::Max(34, $ink[1] - $ink[0] + 8)
        $ui.HeroDivL.Height = $dh; $ui.HeroDivR.Height = $dh
        $dm = $sm + ($ink[0] + $ink[1]) / 2 - $dh / 2
        $ui.HeroDivL.VerticalAlignment = 'Top'; $ui.HeroDivR.VerticalAlignment = 'Top'
        $ui.HeroDivL.Margin = New-Object System.Windows.Thickness(4, $dm, 12, 0); $ui.HeroDivR.Margin = New-Object System.Windows.Thickness(12, $dm, 4, 0)
    } catch { Write-WidgetLog ('hero roll fit: ' + $_.Exception.Message) }
}
function Render-HeroRoll {
    param($v)
    $pick = { param($p) if ($null -ne $v -and $null -ne $v.$p -and $null -ne $v.$p.costUsdAllIn) { Format-Money $v.$p.costUsdAllIn } else { '$--' } }
    $ui.Roll7Cost.Text = & $pick 'd7'; $ui.Roll14Cost.Text = & $pick 'd14'
    $ui.Roll30Cost.Text = & $pick 'd30'; $ui.Roll60Cost.Text = & $pick 'd60'
    $ui.Roll7Cap.Text = Get-Spaced '7 DAYS'; $ui.Roll14Cap.Text = Get-Spaced '14 DAYS'; $ui.Roll30Cap.Text = Get-Spaced '30 DAYS'; $ui.Roll60Cap.Text = Get-Spaced '60 DAYS'
    $g = T 'Green'; $tx = T 'Text'
    foreach ($n in 'Roll7Cap', 'Roll14Cap', 'Roll30Cap', 'Roll60Cap') { $ui[$n].Foreground = $g }
    foreach ($n in 'Roll7Cost', 'Roll14Cost', 'Roll30Cost', 'Roll60Cost') { $ui[$n].Foreground = $tx }
    Set-HeroRollFit
}
try { $ui.HeroRow.Add_SizeChanged({ Set-HeroRollFit }) } catch {}

function Render-View {
    $v = $script:View
    if ($null -eq $v) { return }
    try { Render-Peak } catch { Write-WidgetLog ('peak banner: ' + $_.Exception.Message) }
    try { Render-Drives } catch { Write-WidgetLog ('drives render: ' + $_.Exception.Message) }
    try { Render-V4319 } catch { Write-WidgetLog ('v4.3.19 render: ' + $_.Exception.Message) }
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
    Render-HeroRoll $v
    try { Update-ChgHist } catch {}
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
        if ([bool]$script:AlexaOn -and $j.cmd -ne 'flash' -and -not $script:SchedSync) { try { $ar = Send-Announcement (Get-ActionSpeech $j $ok $(if ($ok) { '' } else { $why })) 'action'; Write-WidgetLog ('announce text: ' + $ar.text + ' -> ' + $ar.result) } catch { Write-WidgetLog ('announce failed: ' + $_.Exception.Message) } }
    }
    $script:CtlLog = @(@($script:CtlLog) + [ordered]@{ at = (Get-LocalNow).ToString('s'); cmd = $j.cmd; query = $j.query; url = $j.url
        dryRun = [bool]$CTL_DRYRUN; ok = $ok; seconds = $secs; result = $script:CtlResultText }) | Select-Object -Last 12
    if ($script:SchedSync -and $script:SchedCmds -contains $j.cmd) { try { Complete-SchedStep $j $ok $(if ($ok) { '' } else { $why }) ($null -ne $next) } catch { Write-WidgetLog ('schedule: ' + $_.Exception.Message) } }   # v4.3.23
    if ($j.cmd -eq 'flash' -and $script:Flash.running -and $script:Flash.done -lt $script:Flash.total) { Render-Controls } else { Render-View; Write-WidgetStatus }
    if ($null -ne $next) { if (-not (Start-TessieCommand $next.cmd $next.query $next.busy $next.okText $next.onOk $next.ann)) { $script:CtlQueue.Clear() } }
}

# ---------------- v4.3.18: SKIP CONFIRM (one saved checkbox per confirmed action; default unchecked) ----------------
# config.json skipConfirm = { unlock, leave, flash, vent, trunk, sentry, announce, stopCharging, limit, amps } (true = run right away, no pop-up).
# Updates only replace TessDesk.ps1, so the settings stay until unchecked.
$SkipCfKeys = @('unlock', 'leave', 'flash', 'vent', 'trunk', 'sentry', 'announce', 'stopCharging', 'limit', 'amps', 'schedule')
$script:SkipCf = [ordered]@{}; foreach ($k in $SkipCfKeys) { $script:SkipCf[$k] = $false }
$script:SkipCfLog = @()
$script:SkipCfLoading = $false
function Get-SkipCfCfg {
    $o = [ordered]@{}; foreach ($k in $SkipCfKeys) { $o[$k] = $false }
    try { $raw = Read-Config; if ($null -ne $raw -and $null -ne $raw.PSObject.Properties['skipConfirm'] -and $null -ne $raw.skipConfirm) { foreach ($k in $SkipCfKeys) { $p = $raw.skipConfirm.PSObject.Properties[$k]; if ($null -ne $p) { $o[$k] = [bool]$p.Value } } } } catch {}
    return $o
}
function Test-SkipConfirm {
    param([string]$Key)
    $on = [bool]$script:SkipCf[$Key]
    if ($on) { $script:SkipCfLog = @(@($script:SkipCfLog) + $Key | Select-Object -Last 40); Write-WidgetLog ('skip confirm: ' + $Key + ' runs right away (checked in TESLA CONTROLS)') }
    return $on
}
function Set-SkipConfirm {
    param([string]$Key, [bool]$On, [bool]$Save = $true)
    $script:SkipCf[$Key] = $On
    $cb = $ui['SkipCf_' + $Key]; if ($null -ne $cb -and [bool]$cb.IsChecked -ne $On) { $script:SkipCfLoading = $true; try { $cb.IsChecked = $On } finally { $script:SkipCfLoading = $false } }
    if ($Save) {
        $o = [ordered]@{}; foreach ($k in $SkipCfKeys) { $o[$k] = [bool]$script:SkipCf[$k] }
        try { Save-ConfigProp 'skipConfirm' $o; Write-WidgetLog ('skip confirm saved: ' + $Key + ' = ' + $On) } catch { Write-WidgetLog ('skip confirm save failed: ' + $_.Exception.Message) }
    }
}
function Render-SkipCf {
    $ui.SkipCfHdr.Foreground = T 'TextSoft'; $ui.SkipCfRow.BorderBrush = T 'BtnBorder'
    foreach ($k in $SkipCfKeys) { $cb = $ui['SkipCf_' + $k]; $cb.Foreground = $(if ([bool]$cb.IsChecked) { T 'Amber' } else { T 'TextSoft' }) }
}
$script:SkipCf = Get-SkipCfCfg
foreach ($k in $SkipCfKeys) {
    $cb = $ui['SkipCf_' + $k]
    $script:SkipCfLoading = $true; try { $cb.IsChecked = [bool]$script:SkipCf[$k] } finally { $script:SkipCfLoading = $false }
    $h = { param($s9, $e9) try { if (-not $script:SkipCfLoading) { Set-SkipConfirm ([string]$s9.Tag) ([bool]$s9.IsChecked); Render-SkipCf } } catch { Write-WidgetLog ('skip confirm: ' + $_.Exception.Message) } }
    $cb.Add_Checked($h); $cb.Add_Unchecked($h)
}

function Invoke-LockToggle {
    $car = Get-CtlCar
    $locked = Get-CtlValue 'locked' $(if ($null -ne $car) { $car.locked } else { $null })
    if ($null -ne $locked -and [bool]$locked) {
        if (-not (Test-SkipConfirm 'unlock') -and -not (Confirm-Ctl 'Unlock your Tesla?')) { Set-CtlResult 'idle' 'Unlock cancelled'; return }
        [void](Start-TessieCommand 'unlock' @{} 'Unlocking…' 'Unlocked' { Set-CtlOverride 'locked' $false } 'Your Tesla is now unlocked.')
    } else {
        [void](Start-TessieCommand 'lock' @{} 'Locking…' 'Locked' { Set-CtlOverride 'locked' $true } 'Your Tesla is now locked.')
    }
}
function Invoke-Vent {
    if (-not (Test-SkipConfirm 'vent') -and -not (Confirm-Ctl 'Vent the windows on your Tesla?')) { Set-CtlResult 'idle' 'Vent cancelled'; return }
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
    $okc = (Test-SkipConfirm 'limit') -or (Confirm-Ctl ('Set to {0}%?' -f $p) ('Charge limit ' + $label) 'Confirm' 'Cancel')
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
    try { Render-Leave } catch {}
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
    if (-not (Test-SkipConfirm 'flash') -and -not (Confirm-Ctl ('Flash the lights {0} time{1}?' -f $n, $(if ($n -eq 1) { '' } else { 's' })) ('{0} flash{1}, about {2} seconds apart. Tap Stop to end early.' -f $n, $plural, $p.ToString('0.#', $Inv)) 'Flash' 'Cancel')) { Set-CtlResult 'idle' 'Flash lights cancelled'; Render-Flash; return }
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

# ---------------- v4.3.15 / v4.3.16: LEAVING SOON (climate on, close windows after N min, unlock M min later; Stop undoes the steps already done) ----------------
# Tessie command names checked against developer.tessie.com (Oct 4, 2026): POST /{vin}/command/start_climate, /close_windows, /unlock
# (each answers { result: true|false }). Every step is checked; a failure stops the rest (the car is never unlocked after a failed step),
# is shown in red and announced. Announcements go to the Voice Monkey living-room device (config announce.device, default echo-living-room-4hqjv).
# v4.3.16: 'Windows after' / 'Unlock after' minutes (0-30, default 3, 0 = that step runs right away), saved in config.json leavingSoon.windowsAfterMin / unlockAfterMin.
# v4.3.16: when Leaving Soon starts, the start state is read from Tessie's cache (GET /{vin}/state?use_cache=true, never wakes the car; if that read fails,
# the last TessDesk refresh). Stop cancels the remaining steps, then undoes only the steps already done, newest first:
#   unlocked and it was locked -> lock; windows closed and any was open -> vent_windows (Tessie can only vent or close); climate started and it was off -> stop_climate.
# Each undo step is announced and shown as 'Undoing n of m'. A forward step that FAILS still just stops (no undo), as in v4.3.15.
# Dry run (controls.dryRun / -SelfTest): nothing is sent to the car or Voice Monkey; leavingSoon.dryRunSecPerMin shortens the waits (self-test 2 s per minute).
$LeaveDefaultDevice = 'echo-living-room-4hqjv'
$LeaveSteps = @(
    [pscustomobject]@{ cmd = 'start_climate'; doing = 'turning on climate'; next = 'climate on'; done = 'climate on'; spoken = 'Leaving Soon: climate is now on.'; what = 'turn on climate' }
    [pscustomobject]@{ cmd = 'close_windows'; doing = 'closing windows'; next = 'closing windows'; done = 'windows closed'; spoken = 'Leaving Soon: the windows are now closed.'; what = 'close the windows' }
    [pscustomobject]@{ cmd = 'unlock'; doing = 'unlocking'; next = 'unlocking'; done = 'unlocked'; spoken = 'Leaving Soon: your Tesla is now unlocked.'; what = 'unlock your Tesla' }
)
$LeaveUndo = @{
    start_climate = [pscustomobject]@{ cmd = 'stop_climate'; doing = 'turning climate back off'; done = 'climate off'; spoken = 'Leaving Soon undo: climate is off again.'; what = 'turn climate back off' }
    close_windows = [pscustomobject]@{ cmd = 'vent_windows'; doing = 'venting the windows'; done = 'windows vented'; spoken = 'Leaving Soon undo: the windows are vented again.'; what = 'vent the windows' }
    unlock        = [pscustomobject]@{ cmd = 'lock'; doing = 'locking'; done = 'locked'; spoken = 'Leaving Soon undo: your Tesla is locked again.'; what = 'lock your Tesla' }
}
$LeaveMinMax = 30; $LeaveMinDefault = 3
$LeaveStartMax = 120; $LeaveStartDefault = 0   # v4.3.19: 'Start after' (minutes before the sequence begins)
$LeaveMinSpec = @{ windowsAfterMin = @(30, 3); unlockAfterMin = @(30, 3); startAfterMin = @(120, 0) }
function Get-LeaveCfg { $l = $null; if ($null -ne $script:Cfg) { try { $l = $script:Cfg.leavingSoon } catch {} }; return $l }
function Get-LeaveMinSpec { param([string]$Key) if ($LeaveMinSpec.ContainsKey($Key)) { return $LeaveMinSpec[$Key] }; return @($LeaveMinMax, $LeaveMinDefault) }
function Get-LeaveCfgMin {
    param([string]$Key)
    $sp = Get-LeaveMinSpec $Key; $l = Get-LeaveCfg; $v = $sp[1]
    if ($null -ne $l) { try { if ($null -ne $l.$Key) { $v = [int]$l.$Key } } catch {} }
    return [int][math]::Min($sp[0], [math]::Max(0, $v))
}
function Get-LeaveSecPerMin {
    if ($CTL_DRYRUN -or $SelfTest) {
        $l = Get-LeaveCfg; $v = 0
        if ($null -ne $l -and $null -ne $l.dryRunSecPerMin) { $v = [int]$l.dryRunSecPerMin }
        elseif ($null -ne $l -and $null -ne $l.dryRunWaitSec) { $v = [int][math]::Max(1, [math]::Round([double]$l.dryRunWaitSec / 3)) }
        elseif ($SelfTest) { $v = 2 }
        if ($v -ge 1) { return [int][math]::Min(60, $v) }
    }
    return 60
}
function Get-LeaveUiMin {
    param($Box, [string]$Key)
    $sp = Get-LeaveMinSpec $Key; $n = 0; if (-not [int]::TryParse(([string]$Box.Text).Trim(), [ref]$n)) { $n = Get-LeaveCfgMin $Key }
    return [int][math]::Min($sp[0], [math]::Max(0, $n))
}
function Get-LeaveMins { return @((Get-LeaveUiMin $ui.LeaveWinMin 'windowsAfterMin'), (Get-LeaveUiMin $ui.LeaveUnlockMin 'unlockAfterMin'), (Get-LeaveUiMin $ui.LeaveStartMin 'startAfterMin')) }
function Get-LeaveWaitSec { param([int]$Step = 1) $m = Get-LeaveMins; return [int]($(if ($Step -ge 2) { $m[1] } else { $m[0] }) * (Get-LeaveSecPerMin)) }
function Save-LeaveMins {
    $m = Get-LeaveMins
    $ui.LeaveWinMin.Text = [string]$m[0]; $ui.LeaveUnlockMin.Text = [string]$m[1]; $ui.LeaveStartMin.Text = [string]$m[2]
    if ($null -ne $script:LeaveMinSaved -and $m[0] -eq $script:LeaveMinSaved[0] -and $m[1] -eq $script:LeaveMinSaved[1] -and $m[2] -eq $script:LeaveMinSaved[2]) { return }
    $script:LeaveMinSaved = @($m[0], $m[1], $m[2])
    if ($SelfTest -and (Split-Path -Leaf $ConfigPath) -eq 'config.json') { return }   # self-test writes only its own test config
    try {
        $o = [ordered]@{}; $l = Get-LeaveCfg
        if ($null -ne $l) { foreach ($p in $l.PSObject.Properties) { $o[$p.Name] = $p.Value } }
        $o['windowsAfterMin'] = $m[0]; $o['unlockAfterMin'] = $m[1]; $o['startAfterMin'] = $m[2]
        Save-ConfigProp 'leavingSoon' ([pscustomobject]$o); $script:Cfg = Read-Config
        Write-WidgetLog ('leaving soon waits saved: start ' + $m[2] + ' min, windows ' + $m[0] + ' min, unlock ' + $m[1] + ' min')
    } catch { Write-WidgetLog ('leaving soon waits save failed: ' + $_.Exception.Message) }
}
function Set-LeaveMin { param($Box, [int]$V) $sp = Get-LeaveMinSpec ([string]$Box.Tag); $Box.Text = [string][math]::Min($sp[0], [math]::Max(0, $V)); Save-LeaveMins; try { Render-Leave } catch {} }
function Add-LeaveMin { param($Box, [string]$Key, [int]$D) if (-not $Box.IsEnabled) { return }; Set-LeaveMin $Box ((Get-LeaveUiMin $Box $Key) + $D) }
function Get-LeaveDevice {
    $a = Get-AnnCfg; $d = ''
    if ($null -ne $a) { try { if ($a.leavingSoonDevice) { $d = [string]$a.leavingSoonDevice } elseif ($a.device) { $d = [string]$a.device } } catch {} }
    if (-not $d) { $d = $LeaveDefaultDevice }
    return $d
}
function Format-LeaveSpan { param([int]$Sec) if ($Sec -ge 60 -and $Sec % 60 -eq 0) { $m = $Sec / 60; return ('{0} minute{1}' -f $m, $(if ($m -eq 1) { '' } else { 's' })) }; return ('{0} second{1}' -f $Sec, $(if ($Sec -eq 1) { '' } else { 's' })) }
function Get-LeaveSummary { param($M) $f = { param($n, $z, $t) if ([int]$n -le 0) { $z } else { $t -f [int]$n } }; return ((& $f $M[2] 'start now' 'start in {0} min') + ' · ' + (& $f $M[0] 'windows right away' 'windows {0} min later') + ' · ' + (& $f $M[1] 'unlock right after' 'unlock {0} min later')) }
function Format-LeaveIn { param([int]$Min, [string]$Now, [string]$Later) if ($Min -le 0) { return $Now }; return ($Later -f (Format-LeaveSpan ($Min * 60))) }
$script:Leave = [ordered]@{ running = $false; phase = 'idle'; step = 0; total = 3; dueAt = $null; job = $null; waitSec = 180; mins = @(0, 3, 3); waits = @(0, 180, 180); startAfterMin = 0; result = ''; kind = 'idle'; notes = @(); log = @(); ann = @(); startedAt = $null; endedAt = $null; hideAt = $null
    snap = $null; snapJob = $null; snapUntil = $null; doneCmds = @(); undoing = $false; undo = @(); undoIdx = 0; undoDone = @(); undoFailed = @(); undoKept = @(); waitLog = @() }
$script:LeaveFailCmd = $null     # self-test only: this command comes back failed (dry run)
$script:LeaveFakeStart = $null   # self-test only: start state used instead of the Tessie cache read
$script:LeaveSeen = @()          # self-test only: status-line texts seen
$script:LeaveMinSaved = $null
$script:LeaveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:LeaveTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:LeaveTimer.Add_Tick({ try { Step-Leave } catch { Write-WidgetLog ('leaving soon tick: ' + $_.Exception.Message) } })

function Add-LeaveNote { param([string]$Text) $script:Leave.notes = @(@($script:Leave.notes) + $Text) | Select-Object -Last 3 }
function Send-LeaveAnnouncement {
    param([string]$Text, [string]$Tag)
    $L = $script:Leave
    $rec = $null
    try {
        $done = [scriptblock]::Create('param($r) Complete-LeaveAnn ''' + $Tag + ''' $r')
        $rec = Send-Announcement $Text 'leaving' -Force -OnDone $done
    } catch { Add-LeaveNote ('Alexa: could not announce (' + $_.Exception.Message + ')'); Render-Leave; return }
    $L.ann = @(@($L.ann) + [ordered]@{ tag = $Tag; text = $Text; devices = @($rec.devices); dryRun = [bool]$rec.dryRun; result = [string]$rec.result }) | Select-Object -Last 20
    if ([string]$rec.result -like 'skipped*') { Add-LeaveNote ('Alexa ' + $rec.result); Render-Leave }
}
function Complete-LeaveAnn {
    param([string]$Tag, $Res)
    if ($null -eq $Res -or [bool]$Res.ok -or [bool]$Res.dryRun) { return }
    $why = $(if ($Res.code) { 'HTTP ' + $Res.code } elseif ($Res.skipped) { [string]$Res.skipped } elseif ($Res.error) { [string]$Res.error } else { 'no response' })
    Add-LeaveNote ('Alexa announcement failed (' + $Tag + '): ' + $why)
    Write-WidgetLog ('leaving soon announce failed ' + $Tag + ': ' + $why)
    Render-Leave
}
function Start-LeaveSoon {
    $L = $script:Leave
    if ($L.running -or $L.undoing -or $null -ne $L.job) { return }
    if (-not (Test-CmdOn)) { Set-CtlResult 'err' 'Leaving Soon: commands are off (About / Privacy or config.json)'; return }
    Save-LeaveMins
    $m = Get-LeaveMins; $spm = Get-LeaveSecPerMin
    $sub = (Get-LeaveSummary $m) + "`n" + ($(if ($m[2] -gt 0) { 'Starts in ' + (Format-LeaveSpan ($m[2] * 60)) + ' (nothing happens until then; Stop just cancels). Then c' } else { 'C' }) + 'limate turns on now, {0}, then {1}. Each step is announced on Alexa. Stop cancels the rest and undoes the steps already done.' -f (Format-LeaveIn $m[0] 'the windows close right away' 'the windows close {0} later'), (Format-LeaveIn $m[1] 'the car unlocks right after that' 'the car unlocks {0} after that'))
    if (-not (Test-SkipConfirm 'leave') -and -not (Confirm-Ctl 'Are you sure? Start Leaving Soon?' $sub 'Start' 'Cancel')) { Set-CtlResult 'idle' 'Leaving Soon cancelled'; return }
    $L.running = $true; $L.phase = $(if ($m[2] -gt 0) { 'pre' } else { 'snap' }); $L.step = 0; $L.mins = @(0, $m[0], $m[1]); $L.waits = @(0, ($m[0] * $spm), ($m[1] * $spm)); $L.waitSec = $L.waits[1]; $L.startAfterMin = $m[2]
    $L.dueAt = Get-Date; $L.job = $null; $L.result = ''; $L.kind = 'busy'; $L.notes = @(); $L.log = @(); $L.ann = @(); $L.waitLog = @()
    $L.startedAt = Get-Date; $L.dueAt = $(if ($m[2] -gt 0) { (Get-Date).AddSeconds($m[2] * $spm) } else { Get-Date }); $L.endedAt = $null; $L.hideAt = $null
    $L.snap = $null; $L.snapJob = $null; $L.doneCmds = @(); $L.undoing = $false; $L.undo = @(); $L.undoIdx = 0; $L.undoDone = @(); $L.undoFailed = @(); $L.undoKept = @()
    $script:LeaveSeen = @()
    Add-LeaveNote (Get-LeaveSummary $m)
    Write-WidgetLog ('leaving soon start startAfter=' + $m[2] + 'min windows=' + $m[0] + 'min unlock=' + $m[1] + 'min' + $(if ($CTL_DRYRUN) { ' [DRY RUN ' + $spm + 's/min]' } else { '' }))
    Send-LeaveAnnouncement ($(if ($m[2] -gt 0) { 'Leaving Soon starts in ' + (Format-LeaveSpan ($m[2] * 60)) + '. Then c' } else { 'Leaving Soon is starting. C' }) + 'limate is turning on now. {0}, and {1}.' -f (Format-LeaveIn $m[0] 'The windows close right away' 'The windows close in {0}'), (Format-LeaveIn $m[1] 'the car unlocks right after that' 'the car unlocks {0} after that')) 'start'
    if ($m[2] -le 0) { Start-LeaveSnap }
    Set-Visible $ui.LeaveRow $true
    $script:LeaveTimer.Start()
    Step-Leave
}
# ---- start state (for Stop / undo) ----
function Get-LeaveSnapFrom {
    param($V, [string]$Src)
    $vs = $V.vehicle_state; $cl = $V.climate_state
    $w = [ordered]@{}; foreach ($k in 'fd', 'fp', 'rd', 'rp') { $w[$k] = $(if ($null -ne $vs) { $vs.($k + '_window') } else { $null }) }
    $known = @($w.Values | Where-Object { $null -ne $_ })
    return [pscustomobject]@{ src = $Src; at = (Get-LocalNow).ToString('s')
        climateOn = $(if ($null -ne $cl -and $null -ne $cl.is_climate_on) { [bool]$cl.is_climate_on } else { $null })
        windows = $w; anyOpen = $(if ($known.Count -gt 0) { @($known | Where-Object { [int]$_ -ne 0 }).Count -gt 0 } else { $null })
        locked = $(if ($null -ne $vs -and $null -ne $vs.locked) { [bool]$vs.locked } else { $null }) }
}
function Set-LeaveSnapFallback {
    param([string]$Why)
    $L = $script:Leave; $c = Get-CtlCar
    if ($null -eq $c) { $L.snap = [pscustomobject]@{ src = ('unknown: ' + $Why); at = (Get-LocalNow).ToString('s'); climateOn = $null; windows = $null; anyOpen = $null; locked = $null } }
    else { $L.snap = [pscustomobject]@{ src = ('last TessDesk refresh: ' + $Why); at = (Get-LocalNow).ToString('s'); climateOn = $(if ($null -ne $c.climateOn) { [bool]$c.climateOn } else { $null }); windows = $c.windows; anyOpen = $(if ($null -ne $c.windowsOpen) { [bool]$c.windowsOpen } else { $null }); locked = $(if ($null -ne $c.locked) { [bool]$c.locked } else { $null }) } }
    Add-LeaveNote ('Start state from the ' + $L.snap.src)
}
function Start-LeaveSnap {
    $L = $script:Leave; $L.snap = $null; $L.snapJob = $null; $L.snapUntil = (Get-Date).AddSeconds(10)
    if ($null -ne $script:LeaveFakeStart) { $L.snap = Get-LeaveSnapFrom $script:LeaveFakeStart 'self-test start state'; return }
    $tok = $null; try { $tok = Get-TessieToken } catch {}
    if (-not $tok -or -not $script:VIN) { Set-LeaveSnapFallback 'no Tessie token / VIN'; return }
    $ps = [powershell]::Create(); [void]$ps.AddScript($script:StateFetchBlock).AddArgument(($ApiBase + '/' + $script:VIN + '/state?use_cache=true')).AddArgument($tok).AddArgument(8)
    $tok = $null
    $L.snapJob = [pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke() }
}
function Step-LeaveSnap {
    $L = $script:Leave; $j = $L.snapJob
    if ($null -ne $j -and $j.async.IsCompleted) {
        $res = $null; try { $o = $j.ps.EndInvoke($j.async); if ($null -ne $o -and $o.Count -gt 0) { $res = $o[$o.Count - 1] } } catch {}
        try { $j.ps.Dispose() } catch {}; $L.snapJob = $null
        if ($null -ne $res -and [bool]$res.ok -and $null -ne $res.v) { $L.snap = Get-LeaveSnapFrom $res.v 'Tessie cached state' }
        else { Set-LeaveSnapFallback ('cached state read failed' + $(if ($null -ne $res -and $res.code) { ' (HTTP ' + $res.code + ')' } else { '' })) }
    } elseif ($null -ne $j -and (Get-Date) -gt $L.snapUntil) {
        try { [void]$j.ps.BeginStop($null, $null) } catch {}; $L.snapJob = $null; Set-LeaveSnapFallback 'cached state read timed out'
    } elseif ($null -eq $j -and $null -eq $L.snap) { Set-LeaveSnapFallback 'no read' }
    if ($null -ne $L.snap -and $L.running -and $L.phase -eq 'snap') {
        $s = $L.snap; Write-WidgetLog ('leaving soon start state (' + $s.src + '): climateOn=' + $s.climateOn + ' windowsOpen=' + $s.anyOpen + ' locked=' + $s.locked)
        $L.phase = 'send'
    }
}
# ---- commands (forward steps and undo steps share one runner) ----
function Start-LeaveJob {
    param([string]$Cmd, [string]$Kind)
    $L = $script:Leave
    if (-not (Test-CmdOn)) { return 'commands are off' }
    $token = $null; try { $token = Get-TessieToken } catch {}
    if (-not $token -or -not $script:VIN) { return 'no Tessie token / VIN' }
    $url = Get-CommandUrl $Cmd @{}
    $ps = [powershell]::Create()
    if ($CTL_DRYRUN) {
        if ($script:LeaveFailCmd -eq $Cmd) { [void]$ps.AddScript({ param($u) Start-Sleep -Milliseconds 800; [pscustomobject]@{ ok = $false; code = 200; error = 'simulated failure (self-test)'; dryRun = $true } }).AddArgument($url) }
        else { [void]$ps.AddScript($script:CmdDryRunBlock).AddArgument($url) }
    } else { [void]$ps.AddScript($script:CmdSendBlock).AddArgument($url).AddArgument($token).AddArgument($CmdTimeoutSec); $script:NetCommandsSent++ }
    $token = $null
    $L.job = [pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke(); cmd = $Cmd; kind = $Kind; url = $url; started = Get-Date }
    Write-WidgetLog ('leaving soon ' + $(if ($Kind -eq 'undo') { 'undo ' } else { '' }) + 'command ' + $Cmd + $(if ($CTL_DRYRUN) { ' [DRY RUN]' } else { '' }))
    return ''
}
function Start-LeaveCommand {
    $L = $script:Leave; $s = $LeaveSteps[$L.step]
    $err = Start-LeaveJob $s.cmd 'step'
    if ($err) { Stop-LeaveFailed $s $err; return }
    $L.phase = 'sending'
}
function Complete-LeaveCommand {
    $L = $script:Leave; $j = $L.job; $L.job = $null
    $res = $null
    try { $out = $j.ps.EndInvoke($j.async); if ($null -ne $out -and $out.Count -gt 0) { $res = $out[$out.Count - 1] } } catch { $res = [pscustomobject]@{ ok = $false; error = $_.Exception.Message } }
    try { $j.ps.Dispose() } catch {}
    $ok = ($null -ne $res -and [bool]$res.ok)
    $why = ''
    if (-not $ok) {
        $why = 'no response'; if ($null -ne $res) { $why = [string]$res.error; if (-not $why -and $null -ne $res.code) { $why = 'HTTP ' + $res.code }; if (-not $why) { $why = 'car did not confirm' } }
        if ($null -ne $res -and ($res.code -eq 401 -or $res.code -eq 403)) { $why = 'token rejected (' + $res.code + ')' }
        if ($why.Length -gt 90) { $why = $why.Substring(0, 90) + '…' }
    }
    $now = Get-Date; $secs = [math]::Round(($now - $j.started).TotalSeconds, 1)
    $L.log = @(@($L.log) + [ordered]@{ at = (Get-LocalNow).ToString('s'); cmd = $j.cmd; kind = $j.kind; ok = $ok; error = $why; seconds = $secs; dryRun = [bool]$CTL_DRYRUN; cancelled = ($j.kind -eq 'step' -and -not $L.running); started = $j.started.ToString('HH:mm:ss.fff'); ended = $now.ToString('HH:mm:ss.fff') })
    $script:CtlLog = @(@($script:CtlLog) + [ordered]@{ at = (Get-LocalNow).ToString('s'); cmd = $j.cmd; query = @{}; url = $j.url; dryRun = [bool]$CTL_DRYRUN; ok = $ok; seconds = $secs; result = ('Leaving Soon ' + $(if ($j.kind -eq 'undo') { 'undo ' } else { '' }) + $j.cmd + ': ' + $(if ($ok) { 'ok' } else { 'failed: ' + $why })) }) | Select-Object -Last 12
    try { Request-LiveSoon 4 } catch {}
    if ($j.kind -eq 'undo') { Complete-LeaveUndo $ok $why; return }
    $s = $LeaveSteps[$L.step]
    if ($ok) {
        switch ($s.cmd) { 'start_climate' { Set-CtlOverride 'climateOn' $true } 'close_windows' { Set-CtlOverride 'windowsOpen' $false } 'unlock' { Set-CtlOverride 'locked' $false } }
        $L.doneCmds = @(@($L.doneCmds) + $s.cmd)
    }
    if (-not $L.running) {
        # Stop was pressed while this command was on its way: if it went through it counts as done and is undone too.
        Add-LeaveNote ('The ' + $s.cmd + ' request was already sent: ' + $(if ($ok) { 'it went through' } else { 'it failed (' + $why + ')' }) + '.')
        if ($L.phase -eq 'cancelled') { Start-LeaveUndoPlan }
        return
    }
    if (-not $ok) { Stop-LeaveFailed $s $why; return }
    Send-LeaveAnnouncement $s.spoken $s.cmd
    $L.step++
    if ($L.step -ge $L.total) {
        $L.running = $false; $L.phase = 'done'; $L.kind = 'ok'; $L.endedAt = Get-Date; $L.hideAt = (Get-Date).AddMinutes(2)
        $L.result = ('Leaving Soon done · climate on, windows closed, unlocked · ' + (Format-Clock (Get-LocalNow)) + $(if ($CTL_DRYRUN) { ' (dry run, not sent)' } else { '' }))
        Set-CtlResult 'ok' ('✓ ' + $L.result)
        Write-WidgetLog 'leaving soon done'
    } else {
        $L.waitSec = [int]$L.waits[$L.step]; $L.phase = 'wait'; $L.dueAt = (Get-Date).AddSeconds($L.waitSec)
        $L.waitLog = @(@($L.waitLog) + [ordered]@{ beforeStep = ($L.step + 1); minutes = $L.mins[$L.step]; seconds = $L.waitSec })
        Set-CtlResult 'ok' ('✓ Leaving Soon: ' + $s.done + $(if ($CTL_DRYRUN) { ' (dry run, not sent)' } else { '' }))
    }
    try { Render-Controls } catch {}
}
function Stop-LeaveFailed {
    param($S, [string]$Why)
    $L = $script:Leave
    $skipped = @($LeaveSteps | Select-Object -Skip ($L.step + 1) | ForEach-Object { $_.done -replace '^climate on$', 'climate' -replace '^windows closed$', 'close windows' -replace '^unlocked$', 'unlock' })
    $L.running = $false; $L.phase = 'failed'; $L.kind = 'err'; $L.endedAt = Get-Date; $L.hideAt = $null
    $L.result = ('Step {0} of {1} failed: {2}: {3}{4}' -f ($L.step + 1), $L.total, $S.cmd, $Why, $(if ($skipped.Count -gt 0) { '. Skipped: ' + ($skipped -join ', ') } else { '' }))
    Set-CtlResult 'err' ('✕ Leaving Soon ' + $S.cmd + ' failed: ' + $Why)
    Write-WidgetLog ('leaving soon failed ' + $S.cmd + ': ' + $Why)
    $reason = $(if ($Why -match 'token') { ' because the Tessie token was rejected' } elseif ($Why -match 'timed out|no response|did not confirm') { ' because the car did not respond' } else { '' })
    Send-LeaveAnnouncement ('Leaving Soon stopped. TessDesk could not ' + $S.what + $reason + '.' + $(if ($skipped.Count -gt 0) { ' The remaining steps will not run.' } else { '' })) 'failed'
    try { Render-Controls } catch {}
}
function Stop-LeaveSoon {
    $L = $script:Leave
    if ($L.undoing -or ($L.phase -eq 'cancelled' -and $null -ne $L.job)) { return }   # undo / pending result already in progress
    if (-not $L.running) { Set-Visible $ui.LeaveRow $false; $L.phase = 'idle'; $script:LeaveTimer.Stop(); Render-Leave; return }
    if ($L.phase -eq 'pre') {   # v4.3.19: stopped before the sequence began: nothing was done, so there is nothing to undo
        $L.running = $false; $L.phase = 'cancelled'; $L.kind = 'idle'; $L.endedAt = Get-Date
        $L.result = 'Leaving Soon cancelled before it started · nothing to undo · ' + (Format-Clock (Get-LocalNow))
        $L.hideAt = (Get-Date).AddMinutes(1); Set-CtlResult 'idle' $L.result
        Write-WidgetLog 'leaving soon cancelled during the start-after countdown (nothing to undo)'; Render-Leave; return }
    $L.running = $false; $L.phase = 'cancelled'; $L.kind = 'idle'; $L.endedAt = Get-Date; $L.hideAt = $null
    if ($null -ne $L.snapJob) { try { [void]$L.snapJob.ps.BeginStop($null, $null) } catch {}; $L.snapJob = $null }
    Write-WidgetLog ('leaving soon cancelled at step ' + ($L.step + 1))
    if ($null -ne $L.job) {
        $L.result = ('Leaving Soon stopping · waiting for the ' + $L.job.cmd + ' result…')
        Set-CtlResult 'busy' $L.result; Render-Leave; return
    }
    Start-LeaveUndoPlan
}
function Start-LeaveUndoPlan {
    $L = $script:Leave; $sn = $L.snap; $plan = @(); $kept = @()
    $d = @($L.doneCmds); [array]::Reverse($d)
    foreach ($c in $d) {
        $need = $false; $why = ''
        switch ($c) {
            'start_climate' { if ($null -eq $sn -or $null -eq $sn.climateOn) { $why = 'climate start state unknown, left on' } elseif (-not $sn.climateOn) { $need = $true } else { $why = 'climate was already on' } }
            'close_windows' { if ($null -eq $sn -or $null -eq $sn.anyOpen) { $why = 'window start state unknown, left closed' } elseif ($sn.anyOpen) { $need = $true } else { $why = 'windows were already closed' } }
            'unlock' { if ($null -eq $sn -or $null -eq $sn.locked -or $sn.locked) { $need = $true } else { $why = 'it was already unlocked' } }   # unknown -> lock (never leave it unlocked by mistake)
        }
        if ($need) { $plan += $LeaveUndo[$c] } else { $kept += $why }
    }
    $L.undo = @($plan); $L.undoIdx = 0; $L.undoDone = @(); $L.undoFailed = @(); $L.undoKept = @($kept)
    foreach ($k in $kept) { Add-LeaveNote ('Not undone: ' + $k + '.') }
    $n = $plan.Count
    Send-LeaveAnnouncement ('Leaving Soon is cancelled. The remaining steps will not run.' + $(if ($n -gt 0) { ' Undoing ' + $n + ' step' + $(if ($n -eq 1) { '' } else { 's' }) + '.' } else { '' })) 'cancel'
    if ($n -eq 0) { Complete-LeaveStop; return }
    $L.undoing = $true; $L.phase = 'undo'
    Set-CtlResult 'busy' ('Leaving Soon stopped · undoing ' + $n + ' step' + $(if ($n -eq 1) { '' } else { 's' }) + $(if ($CTL_DRYRUN) { ' (dry run)' } else { '' }))
    Write-WidgetLog ('leaving soon undo plan: ' + (@($plan | ForEach-Object { $_.cmd }) -join ', '))
    Render-Leave
}
function Start-LeaveUndoCommand {
    $L = $script:Leave
    if ($L.undoIdx -ge @($L.undo).Count) { Complete-LeaveStop; return }
    $u = $L.undo[$L.undoIdx]
    $err = Start-LeaveJob $u.cmd 'undo'
    if ($err) { Complete-LeaveUndo $false $err }
}
function Complete-LeaveUndo {
    param([bool]$Ok, [string]$Why)
    $L = $script:Leave; $u = $L.undo[$L.undoIdx]; $L.undoIdx++
    if ($Ok) {
        switch ($u.cmd) { 'stop_climate' { Set-CtlOverride 'climateOn' $false } 'vent_windows' { Set-CtlOverride 'windowsOpen' $true } 'lock' { Set-CtlOverride 'locked' $true } }
        $L.undoDone = @(@($L.undoDone) + $u.done)
        Send-LeaveAnnouncement $u.spoken ('undo-' + $u.cmd)
    } else {
        $L.undoFailed = @(@($L.undoFailed) + ($u.cmd + ': ' + $Why))
        Add-LeaveNote ('Undo ' + $u.cmd + ' failed: ' + $Why)
        Write-WidgetLog ('leaving soon undo failed ' + $u.cmd + ': ' + $Why)
        $reason = $(if ($Why -match 'token') { ' because the Tessie token was rejected' } elseif ($Why -match 'timed out|no response|did not confirm') { ' because the car did not respond' } else { '' })
        Send-LeaveAnnouncement ('Leaving Soon undo failed. TessDesk could not ' + $u.what + $reason + '.') ('undo-failed-' + $u.cmd)
    }
    if ($L.undoIdx -ge @($L.undo).Count) { Complete-LeaveStop }
    try { Render-Controls } catch {}
}
function Complete-LeaveStop {
    $L = $script:Leave
    $L.undoing = $false; $L.phase = 'cancelled'; $L.endedAt = Get-Date
    $doneTxt = @($LeaveSteps | Where-Object { @($L.doneCmds) -contains $_.cmd } | ForEach-Object { $_.done })
    $n = @($L.undo).Count; $bad = @($L.undoFailed).Count
    $t = 'Leaving Soon stopped · ' + $(if ($doneTxt.Count -gt 0) { ($doneTxt -join ', ') + ', ' } else { '' }) + 'the rest cancelled'
    if ($n -gt 0) { $t += (' · undid {0} of {1}{2}' -f @($L.undoDone).Count, $n, $(if (@($L.undoDone).Count -gt 0) { ': ' + (@($L.undoDone) -join ', ') } else { '' })) }
    if ($bad -gt 0) { $t += (' · FAILED: ' + (@($L.undoFailed) -join '; ')) }
    $L.result = $t + ' · ' + (Format-Clock (Get-LocalNow)) + $(if ($CTL_DRYRUN -and ($n -gt 0 -or $doneTxt.Count -gt 0)) { ' (dry run, not sent)' } else { '' })
    $L.kind = $(if ($bad -gt 0) { 'err' } else { 'idle' }); $L.hideAt = $(if ($bad -gt 0) { $null } else { (Get-Date).AddMinutes(1) })
    Set-CtlResult $(if ($bad -gt 0) { 'err' } else { 'idle' }) $L.result
    Write-WidgetLog ('leaving soon stopped; undo ' + @($L.undoDone).Count + '/' + $n + $(if ($bad -gt 0) { ' failed ' + $bad } else { '' }))
    Render-Leave
}
function Step-Leave {
    $L = $script:Leave
    if ($L.running -and $L.phase -eq 'pre' -and (Get-Date) -ge $L.dueAt) { $L.phase = 'snap'; Start-LeaveSnap }
    if ($L.phase -eq 'snap') { Step-LeaveSnap }
    if ($null -ne $L.job -and $L.job.async.IsCompleted) { Complete-LeaveCommand }
    if ($L.running -and $null -eq $L.job -and ($L.phase -eq 'send' -or ($L.phase -eq 'wait' -and (Get-Date) -ge $L.dueAt))) { Start-LeaveCommand }
    if ($L.undoing -and $null -eq $L.job) { Start-LeaveUndoCommand }
    if (-not $L.running -and -not $L.undoing -and $null -eq $L.job) {
        if ($null -ne $L.hideAt -and (Get-Date) -ge $L.hideAt) { Set-Visible $ui.LeaveRow $false; $L.hideAt = $null; $L.phase = 'idle' }
        if ($ui.LeaveRow.Visibility -ne 'Visible') { $script:LeaveTimer.Stop() }
    }
    Render-Leave
}
function Get-LeaveStepText {
    $L = $script:Leave
    if ($L.undoing) { $u = $L.undo[[math]::Min($L.undoIdx, @($L.undo).Count - 1)]; return ('Undoing {0} of {1} · {2}…' -f ([math]::Min($L.undoIdx + 1, @($L.undo).Count)), @($L.undo).Count, $u.doing) }
    if (-not $L.running) { return $L.result }
    if ($L.phase -eq 'pre') { $left = [math]::Max(0, [int][math]::Ceiling(($L.dueAt - (Get-Date)).TotalSeconds)); return ('Starting in {0}:{1:00}' -f [math]::Floor($left / 60), ($left % 60)) }
    if ($L.phase -eq 'snap') { return ('Step 1 of {0} · reading the start state…' -f $L.total) }
    $s = $LeaveSteps[[math]::Min($L.step, $L.total - 1)]
    if ($L.phase -eq 'wait') {
        $left = [math]::Max(0, [int][math]::Ceiling(($L.dueAt - (Get-Date)).TotalSeconds))
        return ('Step {0} of {1} · {2} in {3}:{4:00}' -f ($L.step + 1), $L.total, $s.next, [math]::Floor($left / 60), ($left % 60))
    }
    return ('Step {0} of {1} · {2}…' -f ($L.step + 1), $L.total, $s.doing)
}
function Render-Leave {
    $L = $script:Leave
    $r = [System.Windows.CornerRadius]::new(5); $r3 = [System.Windows.CornerRadius]::new(3)
    $ui.LeaveBtn.Tag = $r; $ui.LeaveStopBtn.Tag = $r
    $busy = ($L.running -or $L.undoing -or $null -ne $L.job)
    $ui.LeaveBtn.IsEnabled = ((Test-CmdOn) -and -not $busy)
    if ($L.running) { $ui.LeaveBtn.Background = T 'BtnOn'; $ui.LeaveBtn.BorderBrush = T 'Green'; $ui.LeaveBtnTxt.Foreground = T 'Text' }
    else { $ui.LeaveBtn.Background = T 'BtnBg'; $ui.LeaveBtn.BorderBrush = T 'BtnBorder'; $ui.LeaveBtnTxt.Foreground = T 'Text' }
    foreach ($b in @($ui.LeaveStartDn, $ui.LeaveStartUp, $ui.LeaveWinDn, $ui.LeaveWinUp, $ui.LeaveUnlockDn, $ui.LeaveUnlockUp)) { $b.Tag = $r3; $b.Background = T 'BtnBg'; $b.BorderBrush = T 'BtnBorder'; $b.Foreground = T 'Text'; $b.IsEnabled = -not $busy }
    foreach ($tb in @($ui.LeaveStartMin, $ui.LeaveWinMin, $ui.LeaveUnlockMin)) { $tb.IsEnabled = -not $busy; $tb.BorderBrush = T 'Green'; $tb.Foreground = T 'Text' }
    foreach ($lb in @($ui.LeaveStartLbl, $ui.LeaveWinLbl, $ui.LeaveUnlockLbl)) { $lb.Foreground = T 'Caption' }
    if ($ui.LeaveRow.Visibility -ne 'Visible') { return }
    $ui.LeaveStep.Text = Get-LeaveStepText
    if ($SelfTest -and @($script:LeaveSeen) -notcontains $ui.LeaveStep.Text -and @($script:LeaveSeen).Count -lt 200) { $script:LeaveSeen = @(@($script:LeaveSeen) + $ui.LeaveStep.Text) }
    $notes = @($L.notes); $ui.LeaveNote.Text = ($notes -join "`n"); Set-Visible $ui.LeaveNote ($notes.Count -gt 0)
    $acc = $(if ($L.kind -eq 'err') { 'Red' } elseif ($L.undoing -or $L.kind -eq 'idle') { 'Amber' } else { 'Green' })
    $ui.LeaveRow.BorderBrush = T $acc; $ui.LeaveRow.Background = T 'ResultBg'
    $ui.LeaveStep.Foreground = $(if ($L.kind -eq 'err') { T 'Red' } else { T 'Text' })
    $ui.LeaveNote.Foreground = $(if (@($notes | Where-Object { $_ -match 'fail|could not|skipped' }).Count -gt 0) { T 'Red' } else { T 'TextSoft' })
    $pending = ($L.undoing -or ($L.phase -eq 'cancelled' -and $null -ne $L.job))
    $ui.LeaveStopTxt.Text = $(if ($L.running -or $pending) { 'STOP' } else { 'CLOSE' })
    $ui.LeaveStopBtn.IsEnabled = -not $pending
    $ui.LeaveStopBtn.ToolTip = $(if ($L.phase -eq 'pre') { 'Stop: cancels before anything starts (nothing to undo)' } elseif ($L.running) { 'Stop Leaving Soon: the remaining steps are cancelled and the steps already done are undone' } elseif ($pending) { 'Undoing the steps already done…' } else { 'Hide this line' })
    $ui.LeaveStopBtn.Background = T 'BtnBg'; $ui.LeaveStopBtn.BorderBrush = $(if ($L.running -or $pending) { T 'Red' } else { T 'BtnBorder' }); $ui.LeaveStopTxt.Foreground = T 'Text'
}
$ui.LeaveBtn.Add_Click({ try { Start-LeaveSoon } catch { Write-WidgetLog ('leaving soon: ' + $_.Exception.Message); Set-CtlResult 'err' ('Leaving Soon error: ' + $_.Exception.Message) } })
$ui.LeaveStopBtn.Add_Click({ try { Stop-LeaveSoon } catch { Write-WidgetLog ('leaving soon stop: ' + $_.Exception.Message) } })
# v4.3.16: wait boxes (digits only; - / + buttons, mouse wheel, Up / Down; saved on change)
$ui.LeaveStartMin.Text = [string](Get-LeaveCfgMin 'startAfterMin'); $ui.LeaveWinMin.Text = [string](Get-LeaveCfgMin 'windowsAfterMin'); $ui.LeaveUnlockMin.Text = [string](Get-LeaveCfgMin 'unlockAfterMin'); $script:LeaveMinSaved = @(Get-LeaveMins)
foreach ($pair in @(@($ui.LeaveStartMin, 'startAfterMin', $ui.LeaveStartDn, $ui.LeaveStartUp), @($ui.LeaveWinMin, 'windowsAfterMin', $ui.LeaveWinDn, $ui.LeaveWinUp), @($ui.LeaveUnlockMin, 'unlockAfterMin', $ui.LeaveUnlockDn, $ui.LeaveUnlockUp))) {
    $bx = $pair[0]; $ky = $pair[1]
    $bx.Add_PreviewTextInput({ param($s, $e) if ($e.Text -notmatch '^[0-9]+$') { $e.Handled = $true } })
    $bx.Add_LostFocus({ param($s, $e) try { Set-LeaveMin $s (Get-LeaveUiMin $s $s.Tag) } catch {} })
    $bx.Add_PreviewMouseWheel({ param($s, $e) try { if ($s.IsEnabled) { Add-LeaveMin $s $s.Tag $(if ($e.Delta -gt 0) { 1 } else { -1 }); $e.Handled = $true } } catch {} })
    $bx.Add_PreviewKeyDown({ param($s, $e) try { if ($e.Key -eq 'Up') { Add-LeaveMin $s $s.Tag 1; $e.Handled = $true } elseif ($e.Key -eq 'Down') { Add-LeaveMin $s $s.Tag -1; $e.Handled = $true } elseif ($e.Key -eq 'Enter') { Set-LeaveMin $s (Get-LeaveUiMin $s $s.Tag); $e.Handled = $true } } catch {} })
    $bx.Tag = $ky; $pair[2].CommandParameter = $bx; $pair[3].CommandParameter = $bx
    $pair[2].Add_Click({ param($s, $e) try { Add-LeaveMin $s.CommandParameter $s.CommandParameter.Tag -1 } catch {} })
    $pair[3].Add_Click({ param($s, $e) try { Add-LeaveMin $s.CommandParameter $s.CommandParameter.Tag 1 } catch {} })
}
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
    if (-not (Test-SkipConfirm 'stopCharging') -and -not (Confirm-Ctl 'Stop charging now?')) { Set-CtlResult 'idle' 'Still charging'; return }
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
    if (-not (Test-SkipConfirm 'amps') -and -not (Confirm-Ctl ('Set charging current to {0} A?' -f $a))) { Set-CtlResult 'idle' 'Charging amps unchanged'; Render-View; return $a }
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
        if (-not (Test-SkipConfirm 'trunk') -and -not (Confirm-Ctl 'Are you sure?' 'Close the rear trunk? Make sure nothing and no one is in the way.' 'Close trunk' 'Cancel')) { Set-CtlResult 'idle' 'Trunk left open'; return }
        [void](Start-TessieCommand 'activate_rear_trunk' @{} 'Closing the trunk…' 'Trunk closing' { Set-CtlOverride 'trunkOpen' $false } 'Your Tesla trunk is closing.')
    } else {
        if (-not (Test-SkipConfirm 'trunk') -and -not (Confirm-Ctl 'Are you sure?' 'Open the rear trunk?' 'Open trunk' 'Cancel')) { Set-CtlResult 'idle' 'Trunk not opened'; return }
        [void](Start-TessieCommand 'activate_rear_trunk' @{} 'Opening the trunk…' 'Trunk open' { Set-CtlOverride 'trunkOpen' $true } 'Your Tesla trunk is open.')
    }
}
function Invoke-SentryToggle {
    $car = Get-CtlCar
    $on = [bool](Get-CtlValue 'sentry' $(if ($null -ne $car) { $car.sentry } else { $null }))
    if ($on) {
        if (-not (Test-SkipConfirm 'sentry') -and -not (Confirm-Ctl 'Turn Sentry Mode OFF?' 'The car stops watching and recording its surroundings.' 'Turn off' 'Cancel')) { Set-CtlResult 'idle' 'Sentry Mode stays on'; return }
        [void](Start-TessieCommand 'disable_sentry' @{} 'Turning Sentry Mode off…' 'Sentry Mode off' { Set-CtlOverride 'sentry' $false } 'Sentry Mode is now off.')
    } else {
        if (-not (Test-SkipConfirm 'sentry') -and -not (Confirm-Ctl 'Turn Sentry Mode ON?' 'The car watches and records its surroundings (uses some battery).' 'Turn on' 'Cancel')) { Set-CtlResult 'idle' 'Sentry Mode stays off'; return }
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
# ---------------- v4.3.18: CHARGING STATUS bar (under the big cost) ----------------
# Same state logic as the START / STOP buttons and the glow (Get-ChgState, Get-GlowState). CHARGING = green + pulsing dot; COMPLETE = green;
# NOT CHARGING (stopped / no power / unknown) and UNPLUGGED = red. Numbers come from the view (chgInfo from Build-LiveView / Build-IdleView) + the car's SOC.
$script:ChgPulseKind = ''
$script:ChgStatus = $null
function Get-ChgStatus {
    $v = $script:View; $car = Get-CtlCar
    $cs = ''; try { $cs = [string](Get-ChgState) } catch {}
    $glow = ''; try { $glow = [string](Get-GlowState) } catch {}
    $kind = 'not'
    if ($cs -eq 'Charging' -or $cs -eq 'Starting') { $kind = 'charging' }
    elseif (-not $cs -and $glow -eq 'pulse') { $kind = 'charging' }
    elseif ($cs -eq 'Complete') { $kind = 'complete' }
    elseif ($cs -eq 'Disconnected') { $kind = 'unplugged' }
    $word = @{ charging = 'CHARGING'; complete = 'COMPLETE'; unplugged = 'UNPLUGGED'; not = 'NOT CHARGING' }[$kind]
    $ci = $null; if ($null -ne $v -and $null -ne $v.PSObject.Properties['chgInfo']) { $ci = $v.chgInfo }
    $live = ($null -ne $ci -and $null -ne $ci.durMin)
    $dur = $(if ($null -ne $ci -and $ci.dur) { [string]$ci.dur } else { '—' })
    $soc = '—'; if ($null -ne $car -and $null -ne $car.socPct) { $soc = ('{0:N0}%' -f [double]$car.socPct) } elseif ([string]$ui.BattPct.Text -match '\d') { $soc = [string]$ui.BattPct.Text }
    if ($kind -eq 'charging') {
        $labels = @('POWER', 'SESSION', 'FULL AT', 'BATTERY')
        $values = @($(if ($live -and $ci.kw) { [string]$ci.kw } else { '—' }), $(if ($live) { $dur } else { '—' }), $(if ($live -and $ci.fullAt) { [string]$ci.fullAt } else { '—' }), $soc)
    } else {
        $labels = @('POWER', $(if ($live) { 'SESSION' } else { 'LAST SESSION' }), 'ENDED', 'BATTERY')
        $values = @('0 kW', $dur, $(if ($null -ne $ci -and $ci.endedClock) { [string]$ci.endedClock } else { '—' }), $soc)
    }
    $sub = ''
    switch ($kind) {
        'charging'  { $sub = $(if ($cs -eq 'Starting') { 'Starting…' } elseif ($live -and $ci.sub -and [string]$ci.sub -ne ' ') { [string]$ci.sub + ' · this session' } else { 'this session' }) }
        'complete'  { $sub = 'Charge complete · still plugged in' }
        'unplugged' { $sub = 'Plug in to charge' }
        default     { $sub = $(if ($cs) { Get-FriendlyChargeState $cs } else { 'Charging state unknown' }) }
    }
    if ($kind -ne 'charging' -and -not $live -and $null -ne $ci -and $ci.sub -and [string]$ci.sub -ne ' ') { $sub += ' · ' + [string]$ci.sub }
    return [ordered]@{ kind = $kind; state = $cs; word = $word; labels = $labels; values = $values; sub = $sub }
}
function Render-ChgStatus {
    $st = Get-ChgStatus; $script:ChgStatus = $st
    $key = $(if ($st.kind -eq 'charging' -or $st.kind -eq 'complete') { 'Green' } else { 'Red' })
    $b = T $key; $c = $b.Color
    $ui.ChgState.Text = $st.word; $ui.ChgState.Foreground = $b
    $ui.ChgCard.BorderBrush = $b
    $ui.ChgCard.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb($(if ($st.kind -eq 'charging') { 0x30 } else { 0x22 }), $c.R, $c.G, $c.B))
    try { $ui.ChgCard.CornerRadius = [System.Windows.CornerRadius]::new($script:Theme.CardRadius) } catch {}
    $ui.ChgDot.Stroke = $b; $ui.ChgDot.Fill = $(if ($st.kind -eq 'unplugged') { [System.Windows.Media.Brushes]::Transparent } else { $b })
    for ($i = 0; $i -lt 4; $i++) { $ui['ChgL' + $i].Text = $st.labels[$i]; $ui['ChgV' + $i].Text = $st.values[$i]; $ui['ChgL' + $i].Foreground = T 'TextSoft'; $ui['ChgV' + $i].Foreground = T 'Text' }
    $ui.ChgSub.Text = $st.sub; $ui.ChgSub.Foreground = T 'TextSoft'
    $ui.ChgCard.ToolTip = ('Charging status: ' + $st.word + ' · ' + $st.sub)
    if ($st.kind -ne $script:ChgPulseKind) {
        $script:ChgPulseKind = $st.kind
        $ui.ChgDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $ui.ChgDot.Opacity = 1.0
        if ($st.kind -eq 'charging') {
            $a = New-Object System.Windows.Media.Animation.DoubleAnimation
            $a.From = 1.0; $a.To = 0.2; $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(0.9)); $a.AutoReverse = $true
            $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $ui.ChgDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
        }
    }
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
    try { Render-ChgStatus } catch { Write-WidgetLog ('charging status: ' + $_.Exception.Message) }
    try { if (Get-Command Render-Sched -ErrorAction SilentlyContinue) { Render-Sched $En } } catch { Write-WidgetLog ('charging schedule: ' + $_.Exception.Message) }   # v4.3.23
    try { Render-SkipCf } catch { Write-WidgetLog ('skip confirm: ' + $_.Exception.Message) }
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
    if ($Why -eq 'leaving') { return @(Get-LeaveDevice) }   # v4.3.15: Leaving Soon = the living-room Echo
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
    if (-not (Test-SkipConfirm 'announce') -and -not (Confirm-Ctl 'Announce full status?' ('Alexa speaks the rundown on ' + (Get-TargetLabel)) 'Announce' 'Cancel')) { Set-CtlResult 'idle' 'Announcement cancelled'; return $null }
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
    $cards = @('RowsCard', 'BattCard', 'CtlCard', 'TiresCard', 'SeatsCard', 'TripsCard')
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
        foreach ($n in 'HeroCost', 'Roll7Cost', 'Roll14Cost', 'Roll30Cost', 'Roll60Cost', 'KwhLabel', 'DateLabel', 'NightCost', 'D7Cost', 'D30Cost', 'FooterText', 'FooterVersion', 'LoggedIn',
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
                schedule = $(try { Get-SchedInfo } catch { $null })
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
# ---------------- v4.3.12: Restore / Remember row fades in like Paycheck Live ----------------
# Same as Paycheck Live's DeskWin-Fade / DeskWin-Show: 150 ms opacity animation to 0.95 (shown) or 0 (hidden), shown on any mouse move or
# click over the window, hidden 2.2 s after the mouse stops (not while the mouse is over the buttons). Kept hidden while a pop-up is open.
function Test-DwBlocked { foreach ($n in 'ConfirmOverlay', 'ShareOverlay', 'TotOverlay', 'CamOptOverlay') { try { if ($ui[$n].Visibility -eq 'Visible') { return $true } } catch {} }; return $false }
function Set-DwFade {
    param([double]$To)
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = $To; $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(150))
    $ui.DwRow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    $ui.DwRow.IsHitTestVisible = ($To -gt 0)
}
function Show-DwRow {
    try {
        if (Test-DwBlocked) { if ($ui.DwRow.IsHitTestVisible) { $script:DwHide.Stop(); Set-DwFade 0 }; return }
        if (-not $ui.DwRow.IsHitTestVisible) { Set-DwFade 0.95 }
        $script:DwHide.Stop(); $script:DwHide.Start()
    } catch {}
}
$script:DwHide = New-Object System.Windows.Threading.DispatcherTimer
$script:DwHide.Interval = [TimeSpan]::FromMilliseconds(2200)
$script:DwHide.Add_Tick({ try { if ($ui.DwRow.IsMouseOver -and -not (Test-DwBlocked)) { return }; $script:DwHide.Stop(); Set-DwFade 0 } catch {} })
$window.Add_PreviewMouseMove({ Show-DwRow })
$window.Add_PreviewMouseDown({ Show-DwRow })
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
    if ($null -ne $S.width -and [double]$S.width -ge 200) { $ww = [double]$S.width; if ($ww -lt $winW) { $window.Left = [math]::Max(0, $window.Left - ($winW - $ww)); $ww = $winW }; $window.Width = $ww }
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
    Show-DwRow
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
# ---------------- v4.3.17: CHARGE HISTORY & TOTALS dropdown ----------------
# Last night (+ sessions), Last 7 days, Last 30 days and the TOTALS row fold into one row under the info section.
# Starts collapsed (header shows last night's $); click opens / closes it; open / closed is saved in config.json ui.historyOpen.
$script:ChgHist = @{ open = $false }
function Get-ChgHistCfg { try { if ($null -ne $script:Cfg -and $null -ne $script:Cfg.ui -and $null -ne $script:Cfg.ui.PSObject.Properties['historyOpen']) { return [bool]$script:Cfg.ui.historyOpen } } catch {}; return $false }
function Update-ChgHist {
    $o = [bool]$script:ChgHist.open
    $ui.ChgHistArrow.Text = $(if ($o) { [string][char]0x25BE } else { [string][char]0x25B8 })
    $sum = ''
    if (-not $o) { $c = [string]$ui.NightCost.Text; if ($c -match '\d') { $sum = ([string]$ui.NightLbl.Text + '  ' + $c) } }
    $ui.ChgHistSum.Text = $sum
    $ui.ChgHistBtn.ToolTip = $(if ($o) { 'Hide the charge history and totals' } else { 'Show Last night, Last 7 days, Last 30 days and TOTALS' })
}
function Set-ChgHistOpen {
    param([bool]$Open, [bool]$Save = $true)
    $script:ChgHist.open = $Open
    Set-Visible $ui.ChgHistBody $Open
    Update-ChgHist
    if ($Save) {
        $o = [ordered]@{}; try { $raw = Read-Config; if ($null -ne $raw -and $null -ne $raw.ui) { foreach ($p in $raw.ui.PSObject.Properties) { $o[$p.Name] = $p.Value } } } catch {}
        $o['historyOpen'] = $Open
        try { Save-ConfigProp 'ui' $o; $script:Cfg = Read-Config } catch { Write-WidgetLog ('history dropdown save failed: ' + $_.Exception.Message) }
    }
    try { if ($window.IsLoaded) { Confirm-Fit } } catch {}
}
$ui.ChgHistBtn.Add_Click({ try { Set-ChgHistOpen (-not [bool]$script:ChgHist.open) } catch { Write-WidgetLog ('history dropdown: ' + $_.Exception.Message) } })
try { Set-ChgHistOpen (Get-ChgHistCfg) $false } catch { Write-WidgetLog ('history dropdown init: ' + $_.Exception.Message) }

$ui.TotClose.Add_Click({ Close-Totals })
$ui.TotStop.Add_Click({ Stop-TotLoad })
$ui.TotRefresh.Add_Click({ try { $script:Tot.status = ''; [void](Start-TotLoad -All) } catch { Write-WidgetLog ('totals refresh: ' + $_.Exception.Message) } })
$ui.TotOverlay.Add_MouseLeftButtonUp({ param($s9, $e9) if ($e9.OriginalSource -eq $ui.TotOverlay) { Close-Totals } })
$window.Add_PreviewKeyDown({ param($s9, $e9) try { if (Invoke-TotKey ([string]$e9.Key)) { $e9.Handled = $true } } catch {} })
try { Load-TotCache } catch {}

# ---------------- v4.3.19: PLUG-IN REMINDER, TRIPS, MORNING READY CHECK, PSO BILL MATCH (on/off), BATTERY HEALTH TREND + TIPS ----------------
# All read-only: Tessie cached state (use_cache=true, never wakes the car), /drives, /battery_health. No Alexa (Voice Monkey) for any of these.
# Windows toasts: plug-in reminder once per night, morning ready check once per morning only when something is off.
$HomeLatDef = 36.10364; $HomeLonDef = -96.03282
$HomeSavedNames = @('3515 W 41st Pl', 'Home')
$HealthHistPath = Join-Path $scriptDir 'battery-health-history.json'
$script:Now4319 = $null          # self-test only: fixed 'now'
$script:Toast4319 = @()          # toasts asked for (self-test: logged, not shown)
$script:TripsSig = ''; $script:Trips4319 = $null
function Get-Now4319 { if ($null -ne $script:Now4319) { return [DateTime]$script:Now4319 }; return (Get-LocalNow) }
function Get-Cfg4319 { param([string]$Name) try { if ($null -ne $script:Cfg -and $null -ne $script:Cfg.PSObject.Properties[$Name]) { return $script:Cfg.$Name } } catch {}; return $null }
function Save-Cfg4319 {
    param([string]$Name, $Value)
    $obj = $(if ($Value -is [System.Collections.IDictionary]) { [pscustomobject]$Value } else { $Value })
    if ($null -eq $script:Cfg) { $script:Cfg = [pscustomobject]@{} }
    try { $script:Cfg | Add-Member -NotePropertyName $Name -NotePropertyValue $obj -Force } catch {}
    if ($SelfTest -and (Split-Path -Leaf $ConfigPath) -eq 'config.json') { return }   # a self-test writes only its own test config
    try { Save-ConfigProp $Name $obj } catch { Write-WidgetLog ('config save ' + $Name + ': ' + $_.Exception.Message) }
}
function Get-Merged4319 {
    param([string]$Name, $Defaults)
    $o = [ordered]@{}; foreach ($k in @($Defaults.Keys)) { $o[$k] = $Defaults[$k] }
    $c = Get-Cfg4319 $Name
    if ($null -ne $c) { foreach ($p in $c.PSObject.Properties) { if ($null -ne $p.Value) { $o[$p.Name] = $p.Value } } }
    return $o
}
function Get-MarkPath4319 { param([string]$N) if ($SelfTest) { return (Join-Path $env:TEMP ('td4319-selftest-' + $N + '.json')) }; return (Join-Path $scriptDir ($N + '.json')) }

# ---- home ----
function Get-DistMi { param([double]$La1, [double]$Lo1, [double]$La2, [double]$Lo2) $r = [math]::PI / 180; $x = ($Lo2 - $Lo1) * $r * [math]::Cos(($La1 + $La2) / 2 * $r); $y = ($La2 - $La1) * $r; return [math]::Sqrt($x * $x + $y * $y) * 3958.8 }
function Get-HomeLL {
    $h = Get-Cfg4319 'home'; $la = $HomeLatDef; $lo = $HomeLonDef
    try { if ($null -ne $h -and $null -ne $h.lat -and $null -ne $h.lon) { $la = [double]$h.lat; $lo = [double]$h.lon } } catch {}
    return @($la, $lo)
}
function Test-HomeName { param($Saved) if (-not $Saved) { return $false }; return (@($HomeSavedNames | Where-Object { $_ -eq [string]$Saved }).Count -gt 0) }
function Test-NearHome { param($La, $Lo) if ($null -eq $La -or $null -eq $Lo) { return $false }; $h = Get-HomeLL; return ((Get-DistMi ([double]$La) ([double]$Lo) $h[0] $h[1]) -le 0.15) }
function Test-CarAtHome {
    param($Car)
    if ($null -ne $Car -and $null -ne $Car.lat -and $null -ne $Car.lon) { return (Test-NearHome $Car.lat $Car.lon) }
    $t = @(@(Get-Val $script:State.trips @()) | Where-Object { $null -ne $_ } | Sort-Object { [int64]$_.startEpoch } -Descending | Select-Object -First 1)
    if ($t.Count -gt 0) { return [bool]$t[0].toHome }
    return $null
}

# ---- 1. PLUG-IN REMINDER ----
function Get-PlugCfg {
    $o = Get-Merged4319 'plugReminder' ([ordered]@{ enabled = $true; fromHour = 21; untilHour = 5; thresholdPct = 60; mode = 'limit' })
    $o.enabled = [bool]$o.enabled; $o.fromHour = [int]$o.fromHour; $o.untilHour = [int]$o.untilHour; $o.thresholdPct = [int]$o.thresholdPct; $o.mode = [string]$o.mode
    return $o
}
function Get-PlugReminder {
    param($Car, [DateTime]$Now, $Cfg, $AtHome)
    $r = [ordered]@{ show = $false; why = ''; soc = $null; target = $null; targetKind = ''; atHome = $AtHome; state = ''; inWindow = $false; enabled = [bool]$Cfg.enabled }
    $r.inWindow = (Test-HourIn $Now.Hour ([int]$Cfg.fromHour) ([int]$Cfg.untilHour))
    if ($null -eq $Car) { $r.why = 'no car data'; return [pscustomobject]$r }
    $r.state = [string]$Car.chargingState; $r.soc = $Car.socPct
    if ([string]$Cfg.mode -eq 'threshold' -or $null -eq $Car.limitPct) { $r.target = [int]$Cfg.thresholdPct; $r.targetKind = 'reminder threshold' } else { $r.target = [int]$Car.limitPct; $r.targetKind = 'daily limit' }
    if (-not $Cfg.enabled) { $r.why = 'reminder is off'; return [pscustomobject]$r }
    if (-not $r.inWindow) { $r.why = 'not evening yet'; return [pscustomobject]$r }
    if ($AtHome -ne $true) { $r.why = 'car is not at home'; return [pscustomobject]$r }
    if ($r.state -ne 'Disconnected') { $r.why = 'plugged in'; return [pscustomobject]$r }
    if ($null -eq $r.soc -or [double]$r.soc -ge [double]$r.target) { $r.why = 'battery is at or above the target'; return [pscustomobject]$r }
    $r.show = $true; $r.why = ('{0}% is under the {1} {2}%' -f $r.soc, $r.targetKind, $r.target)
    return [pscustomobject]$r
}
function Get-Car4319 {
    $c = Get-CtlCar; if ($null -eq $c) { return $null }
    return [pscustomobject]@{ socPct = $c.socPct; limitPct = $c.limitPct; chargingState = [string](Get-CtlValue 'chargingState' $c.chargingState); lat = $c.lat; lon = $c.lon
        locked = (Get-CtlValue 'locked' $c.locked); windowsOpen = (Get-CtlValue 'windowsOpen' $c.windowsOpen); sentry = (Get-CtlValue 'sentry' $c.sentry); rangeMi = $c.rangeMi; atEpoch = $c.atEpoch }
}
function Render-PlugRem {
    $cfg = Get-PlugCfg; $car = Get-Car4319; $now = Get-Now4319
    $r = Get-PlugReminder $car $now $cfg (Test-CarAtHome $car)
    $script:PlugRem = $r
    Set-Visible $ui.PlugRemBar ([bool]$r.show)
    if ($r.show) {
        $ui.PlugRemSub.Text = ('{0}% · {1} {2}% · home, unplugged' -f $r.soc, $(if ($r.targetKind -eq 'daily limit') { 'limit' } else { 'reminder' }), $r.target)
        $ui.PlugRemBar.BorderBrush = T 'Red'; $ui.PlugRemDot.Fill = T 'Red'; $ui.PlugRemBar.Background = Get-Brush '#40E82127'
        $n = $now; if ($n.Hour -lt 12) { $n = $n.AddDays(-1) }; $key = 'night-' + $n.ToString('yyyy-MM-dd')
        $mp = Get-MarkPath4319 'plug-reminder'
        if ((Get-MarkKey $mp) -ne $key) {
            Set-MarkKey $mp $key
            $script:Toast4319 = @(@($script:Toast4319) + ('plug: ' + $key))
            Show-WinToast 'TessDesk: plug in tonight' ('Battery {0}% is under the {1} {2}%. The car is home and unplugged.' -f $r.soc, $r.targetKind, $r.target)
        }
    }
    $ui.PlugRemSwitch.IsChecked = [bool]$cfg.enabled
    $ui.PlugSetTxt.Text = ('Plug-in reminder · from {0}, when home, unplugged and under the {1}' -f (Format-HourLabel $cfg.fromHour), $(if ($cfg.mode -eq 'threshold') { 'reminder threshold ' + $cfg.thresholdPct + '%' } else { 'daily limit' + $(if ($null -ne $car -and $null -ne $car.limitPct) { ' (' + $car.limitPct + '%)' } else { '' }) }))
    $ui.PlugSetTxt.Foreground = T 'TextSoft'
}
function Set-PlugEnabled { param([bool]$On) $c = Get-PlugCfg; $c.enabled = $On; Save-Cfg4319 'plugReminder' $c; Write-WidgetLog ('plug-in reminder ' + $(if ($On) { 'on' } else { 'off' })); Render-PlugRem }

# ---- 3. TRIPS ----
function Get-ShortAddr {
    param([string]$A)
    if (-not $A) { return 'Unknown place' }
    $p = @(([string]$A) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($p.Count -eq 0) { return 'Unknown place' }
    $s = $p[0]
    if ($s -notmatch '^\d') { if ($s.Length -gt 26) { $s = $s.Substring(0, 25) + '…' }; return $s }
    foreach ($w in @(@('South', 'S'), @('North', 'N'), @('East', 'E'), @('West', 'W'), @('Avenue', 'Ave'), @('Street', 'St'), @('Place', 'Pl'), @('Road', 'Rd'), @('Boulevard', 'Blvd'), @('Drive', 'Dr'), @('Parkway', 'Pkwy'), @('Highway', 'Hwy'), @('Court', 'Ct'), @('Lane', 'Ln'), @('Expressway', 'Expy'), @('Circle', 'Cir'))) { $s = $s -replace ('\b' + $w[0] + '\b'), $w[1] }
    if ($p.Count -ge 2 -and $p[1] -ne 'Tulsa' -and $p[1] -notmatch '^\d' -and $p[1] -notmatch 'United States|Oklahoma') { $s += ', ' + $p[1] }
    if ($s.Length -gt 30) { $s = $s.Substring(0, 29) + '…' }
    return $s
}
function Get-TripPlace { param($Saved, $Addr, $La, $Lo) if ((Test-HomeName $Saved) -or (Test-NearHome $La $Lo)) { return 'Home' }; if ($Saved) { return [string]$Saved }; return (Get-ShortAddr $Addr) }
function Convert-Trip4319 {
    param($d)
    $se = [int64]$d.started_at; $ee = [int64](Get-Val $d.ended_at $d.started_at)
    $fh = ((Test-HomeName $d.starting_saved_location) -or (Test-NearHome $d.starting_latitude $d.starting_longitude))
    $th = ((Test-HomeName $d.ending_saved_location) -or (Test-NearHome $d.ending_latitude $d.ending_longitude))
    return [pscustomobject]@{
        id = $d.id; startEpoch = $se; endEpoch = $ee; minutes = [int][math]::Round(($ee - $se) / 60.0)
        from = (Get-TripPlace $d.starting_saved_location $d.starting_location $d.starting_latitude $d.starting_longitude)
        to = (Get-TripPlace $d.ending_saved_location $d.ending_location $d.ending_latitude $d.ending_longitude)
        fromHome = $fh; toHome = $th
        miles = [math]::Round([double](Get-Val $d.odometer_distance 0.0), 2); kwh = [math]::Round([double](Get-Val $d.energy_used 0.0), 2)
        tempF = $d.average_outside_temperature; avgMph = $d.average_speed; socStart = $d.starting_battery; socEnd = $d.ending_battery
    }
}
function Test-Fast4319 { param($s) return ([bool]$s.fast -or $null -ne $s.paidUsd) }
function Get-TripRate {
    param($Sessions, [int64]$NowE)
    $cut = $NowE - 30 * 86400; $cost = 0.0; $kwh = 0.0; $n = 0
    foreach ($s in @($Sessions)) {
        if ($null -eq $s -or (Test-Fast4319 $s) -or [int64]$s.startEpoch -lt $cut) { continue }
        $ka = $(if ($null -ne $s.kwhAdded -and [double]$s.kwhAdded -gt 0) { [double]$s.kwhAdded } else { 0.0 })
        if ($ka -le 0 -or $null -eq $s.costUsdAllIn) { continue }
        $cost += [double]$s.costUsdAllIn; $kwh += $ka; $n++
    }
    if ($kwh -ge 5 -and $n -ge 2) {
        $rt = $cost / $kwh
        return [pscustomobject]@{ rate = $rt; source = 'home'; sessions = $n; kwh = [math]::Round($kwh, 1); cost = [math]::Round($cost, 2)
            note = ('Cost = kWh used × {0} = your home charging average, last 30 days ({1} charges, {2:N0} kWh added, {3} incl. losses)' -f (Format-C1 $rt), $n, $kwh, (Format-Money $cost)) }
    }
    $rt = $R_ON + $FCA
    return [pscustomobject]@{ rate = $rt; source = 'pso'; sessions = $n; kwh = [math]::Round($kwh, 1); cost = [math]::Round($cost, 2)
        note = ('Cost = kWh used × {0} = PSO overnight rate (no home charging data in the last 30 days)' -f (Format-C1 $rt)) }
}
function Get-TripDayLabel { param([DateTime]$D, [DateTime]$Today) if ($D.Date -eq $Today) { return 'Today' }; if ($D.Date -eq $Today.AddDays(-1)) { return 'Yesterday' }; return $D.ToString('ddd MMM d', $Inv) }
function Get-TripView {
    param($Trips, [DateTime]$Now, [int]$Days, [double]$Rate)
    $today = $Now.Date
    $all = @(@($Trips) | Where-Object { $null -ne $_ -and [double]$_.miles -ge 0.1 } | Sort-Object { [int64]$_.startEpoch } -Descending)
    $c7 = ConvertTo-EpochLocal $today.AddDays(-6); $back = 1 - [math]::Max(1, $Days); $cut = ConvertTo-EpochLocal $today.AddDays($back)
    $w7 = @($all | Where-Object { [int64]$_.startEpoch -ge $c7 })
    $mi7 = [double](($w7 | Measure-Object -Property miles -Sum).Sum); $k7 = [double](($w7 | Measure-Object -Property kwh -Sum).Sum)
    $miA = [double](($all | Measure-Object -Property miles -Sum).Sum); $kA = [double](($all | Measure-Object -Property kwh -Sum).Sum)
    $avg7 = $(if ($k7 -gt 0) { $mi7 / $k7 } else { $null }); $avgA = $(if ($kA -gt 0) { $miA / $kA } else { $null })
    $ref = $(if ($w7.Count -ge 3 -and $null -ne $avg7) { $avg7 } else { $avgA })
    $dayList = New-Object System.Collections.ArrayList; $cur = $null
    foreach ($t in @($all | Where-Object { [int64]$_.startEpoch -ge $cut })) {
        $dt = ConvertFrom-Epoch $t.startEpoch; $key = $dt.ToString('yyyy-MM-dd')
        if ($null -eq $cur -or $cur.key -ne $key) { $cur = [pscustomobject]@{ key = $key; label = (Get-TripDayLabel $dt $today); trips = New-Object System.Collections.ArrayList; n = 0; miles = 0.0; kwh = 0.0; cost = 0.0 }; [void]$dayList.Add($cur) }
        $kw = [double]$t.kwh; $mi = [double]$t.miles
        $mpk = $(if ($kw -gt 0.05) { $mi / $kw } else { $null })
        $bad = ($mi -ge 2 -and $null -ne $mpk -and $null -ne $ref -and $mpk -lt 0.7 * $ref)
        [void]$cur.trips.Add([pscustomobject]@{ t = $t; time = (Format-Clock $dt); from = $t.from; to = $t.to; minutes = [int]$t.minutes; miles = $mi; kwh = $kw; cost = [math]::Round($kw * $Rate, 4); mpk = $mpk; inefficient = $bad })
        $cur.n++; $cur.miles += $mi; $cur.kwh += $kw; $cur.cost += $kw * $Rate
    }
    return [pscustomobject]@{ days = @($dayList); refMpk = $ref; days7 = 7; shownDays = $Days
        sum7 = [pscustomobject]@{ trips = $w7.Count; miles = [math]::Round($mi7, 1); kwh = [math]::Round($k7, 1); cost = [math]::Round($k7 * $Rate, 2); avgMpk = $(if ($null -ne $avg7) { [math]::Round($avg7, 2) } else { $null }) }
        older = @($all | Where-Object { [int64]$_.startEpoch -lt $cut }).Count; total = $all.Count }
}
function Get-TripsOpen { $c = Get-Cfg4319 'trips'; try { if ($null -ne $c -and $null -ne $c.expanded) { return [bool]$c.expanded } } catch {}; return $false }
function Set-TripsOpen { param([bool]$On) Save-Cfg4319 'trips' ([ordered]@{ expanded = $On }); $script:TripsSig = ''; Render-Trips }
function New-Tb4319 { param([string]$Text, [double]$Size, $Brush, [string]$Weight = 'Normal') $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = $Brush; $t.FontWeight = $Weight; return $t }
function Format-Mpk { param($v) if ($null -eq $v) { return '-- mi/kWh' }; return ('{0:N1} mi/kWh' -f [double]$v) }
function Format-TripMin { param([int]$m) if ($m -ge 60) { return ('{0} h {1} min' -f [math]::Floor($m / 60), ($m % 60)) }; return ('{0} min' -f [math]::Max(1, $m)) }
function Render-Trips {
    $st = $script:State; $open = Get-TripsOpen; $days = $(if ($open) { 30 } else { 7 })
    $trips = @(Get-Val $st.trips @()); $now = Get-Now4319; $nowE = ConvertTo-EpochLocal $now
    $rate = Get-TripRate @(Get-CompletedForTotals $st) $nowE
    $sig = ('{0}|{1}|{2}|{3}|{4}|{5:N4}|{6}' -f $trips.Count, $(if ($trips.Count) { $trips[0].id } else { '' }), [int64](Get-Val $st.drivesFetchEpoch 0), $open, $now.ToString('yyyy-MM-dd'), $rate.rate, [bool]$script:ThemeCharging)
    if ($sig -eq $script:TripsSig) { return }
    $script:TripsSig = $sig
    $v = Get-TripView $trips $now $days $rate.rate; $script:Trips4319 = [pscustomobject]@{ view = $v; rate = $rate; open = $open }
    $ui.TripsList.Children.Clear()
    $ui.TripsHdr.Foreground = T 'Caption'; $ui.TripsRate.Foreground = T 'Caption'; $ui.TripsSumHdr.Foreground = T 'Caption'
    foreach ($i in 0..4) { $ui['TripsS' + $i].Foreground = T 'Text'; $ui['TripsSL' + $i].Foreground = T 'Caption' }
    $s7 = $v.sum7
    $ui.TripsS0.Text = [string]$s7.trips; $ui.TripsS1.Text = ('{0:N1}' -f $s7.miles); $ui.TripsS2.Text = ('{0:N1}' -f $s7.kwh); $ui.TripsS3.Text = (Format-Money $s7.cost); $ui.TripsS4.Text = $(if ($null -ne $s7.avgMpk) { ('{0:N2}' -f $s7.avgMpk) } else { '--' })
    $fe = [int64](Get-Val $st.drivesFetchEpoch 0)
    $ui.TripsSumPillTxt.Text = $(if ($fe -gt 0) { 'as of ' + (ConvertFrom-Epoch $fe).ToString('h:mm tt', $Inv) } else { 'no data yet' })
    $ui.TripsRate.Text = $rate.note + ' · ▼ = under 70% of your average mi/kWh'
    if ($v.days.Count -eq 0) { [void]$ui.TripsList.Children.Add((New-Tb4319 $(if ($trips.Count -eq 0) { 'No trips loaded yet (Tessie /drives refreshes every 15 min).' } else { 'No trips in the last ' + $days + ' days.' }) 10 (T 'Caption'))) }
    foreach ($d in $v.days) {
        $hd = New-Object System.Windows.Controls.DockPanel; $hd.Margin = '0,6,0,1'; $hd.LastChildFill = $true
        $tot = New-Tb4319 ('{0} trip{1} · {2:N1} mi · {3:N1} kWh · {4}' -f $d.n, $(if ($d.n -eq 1) { '' } else { 's' }), $d.miles, $d.kwh, (Format-Money $d.cost)) 9.5 (T 'TextSoft') 'SemiBold'
        [System.Windows.Controls.DockPanel]::SetDock($tot, 'Right'); $tot.VerticalAlignment = 'Center'; [void]$hd.Children.Add($tot)
        $lb = New-Tb4319 $d.label.ToUpper() 10 (T 'Caption') 'Bold'; $lb.VerticalAlignment = 'Center'; [void]$hd.Children.Add($lb)
        [void]$ui.TripsList.Children.Add($hd)
        $sep = New-Object System.Windows.Controls.Border; $sep.Height = 1; $sep.Background = T 'Sep'; $sep.Margin = '0,0,0,2'; [void]$ui.TripsList.Children.Add($sep)
        foreach ($r in $d.trips) {
            $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,2,0,2'
            foreach ($gl in @([System.Windows.GridLength]::new(56), [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star), [System.Windows.GridLength]::Auto)) { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $gl; [void]$g.ColumnDefinitions.Add($cd) }
            $c0 = New-Object System.Windows.Controls.StackPanel
            [void]$c0.Children.Add((New-Tb4319 $r.time 10.5 (T 'Text') 'SemiBold')); [void]$c0.Children.Add((New-Tb4319 (Format-TripMin $r.minutes) 9 (T 'Caption')))
            [void]$g.Children.Add($c0)
            $c1 = New-Object System.Windows.Controls.StackPanel; $c1.Margin = '4,0,6,0'
            $rt = New-Tb4319 ($r.from + ' → ' + $r.to) 11 (T 'Text') 'SemiBold'; $rt.TextTrimming = 'CharacterEllipsis'; $rt.ToolTip = ($r.t.from + ' → ' + $r.t.to); [void]$c1.Children.Add($rt)
            $mt = New-Tb4319 ('{0:N1} mi · {1:N2} kWh · {2}' -f $r.miles, $r.kwh, (Format-Mpk $r.mpk)) 9.5 $(if ($r.inefficient) { T 'Amber' } else { T 'TextSoft' }) $(if ($r.inefficient) { 'SemiBold' } else { 'Normal' }); [void]$c1.Children.Add($mt)
            [System.Windows.Controls.Grid]::SetColumn($c1, 1); [void]$g.Children.Add($c1)
            $c2 = New-Object System.Windows.Controls.StackPanel; $c2.HorizontalAlignment = 'Right'
            $ct = New-Tb4319 (Format-Money $r.cost) 11.5 (T 'Text') 'Bold'; $ct.HorizontalAlignment = 'Right'; [void]$c2.Children.Add($ct)
            if ($r.inefficient) { $fl = New-Tb4319 '▼ LOW mi/kWh' 8.5 (T 'Amber') 'Bold'; $fl.HorizontalAlignment = 'Right'; $fl.ToolTip = ('Unusually inefficient: {0:N1} mi/kWh vs your average {1:N1}' -f $r.mpk, $v.refMpk); [void]$c2.Children.Add($fl) }
            [System.Windows.Controls.Grid]::SetColumn($c2, 2); [void]$g.Children.Add($c2)
            [void]$ui.TripsList.Children.Add($g)
        }
    }
    $ui.TripsMoreTxt.Text = $(if ($open) { 'Show less (7 days)' } else { 'Show more (30 days' + $(if ($v.older -gt 0) { ', ' + $v.older + ' more' } else { '' }) + ')' })
    $ui.TripsMoreBtn.Tag = [System.Windows.CornerRadius]::new(5); $ui.TripsMoreBtn.Background = T 'BtnBg'; $ui.TripsMoreBtn.BorderBrush = T 'BtnBorder'; $ui.TripsMoreTxt.Foreground = T 'Text'
    $ui.TripsSumBox.Background = Get-Brush '#14FFFFFF'
}

# ---- 4a. MORNING READY CHECK ----
function Get-ReadyCheck {
    param($Car, $Tires, [DateTime]$Now, [double]$MinPsi = 40)
    $items = New-Object System.Collections.ArrayList
    $push = { param($k, $l, $s, $t) [void]$items.Add([pscustomobject]@{ key = $k; label = $l; state = $s; text = $t }) }
    if ($null -eq $Car) { & $push 'battery' 'Battery' 'unknown' 'no car data' }
    else {
        $soc = $Car.socPct; $lim = $Car.limitPct; $cs = [string]$Car.chargingState
        $atLim = ($null -ne $soc -and $null -ne $lim -and [double]$soc -ge [double]$lim - 1)
        if ($null -eq $soc -or $null -eq $lim) { & $push 'battery' 'Battery' 'unknown' 'battery level unknown' }
        elseif ($atLim) { & $push 'battery' 'Battery' 'ok' ('{0}% (limit {1}%)' -f $soc, $lim) } else { & $push 'battery' 'Battery' 'off' ('{0}%, under the {1}% limit' -f $soc, $lim) }
        if ($cs -eq 'Complete') { & $push 'charging' 'Charging' 'ok' 'finished' }
        elseif ($cs -eq 'Charging' -or $cs -eq 'Starting') { & $push 'charging' 'Charging' 'off' 'still charging' }
        elseif (-not $cs) { & $push 'charging' 'Charging' 'unknown' 'state unknown' }
        elseif ($atLim) { & $push 'charging' 'Charging' 'ok' $(if ($cs -eq 'Disconnected') { 'done, unplugged' } else { 'done' }) }
        else { & $push 'charging' 'Charging' 'off' $(if ($cs -eq 'Disconnected') { 'not plugged in' } else { 'stopped before the limit' }) }
        if ($null -eq $Car.locked) { & $push 'locked' 'Locked' 'unknown' 'unknown' } elseif ([bool]$Car.locked) { & $push 'locked' 'Locked' 'ok' 'locked' } else { & $push 'locked' 'Locked' 'off' 'UNLOCKED' }
        if ($null -eq $Car.windowsOpen) { & $push 'windows' 'Windows' 'unknown' 'unknown' } elseif ([bool]$Car.windowsOpen) { & $push 'windows' 'Windows' 'off' 'a window is OPEN' } else { & $push 'windows' 'Windows' 'ok' 'closed' }
    }
    if ($null -eq $Tires -or $null -eq $Tires.fr) { & $push 'tires' 'Tires' 'unknown' 'no tire data' }
    else {
        $low = @(); foreach ($k in 'fl', 'fr', 'rl', 'rr') { $p = $Tires.$k; if ($null -ne $p -and [double]$p -lt $MinPsi) { $low += ('{0} {1:N0}' -f $k.ToUpper(), [double]$p) } }
        $rf = ('RF {0:N0} PSI' -f [double]$Tires.fr)
        if ($low.Count -gt 0) { & $push 'tires' 'Tires' 'off' ('under ' + $MinPsi + ' PSI: ' + ($low -join ', ')) } else { & $push 'tires' 'Tires' 'ok' ('all ' + $MinPsi + '+ PSI · ' + $rf) }
    }
    if ($null -ne $Car) {
        & $push 'sentry' 'Sentry' 'info' $(if ($null -eq $Car.sentry) { 'unknown' } elseif ([bool]$Car.sentry) { 'on' } else { 'off' })
        & $push 'range' 'Range' 'info' $(if ($null -ne $Car.rangeMi) { ('{0:N0} mi' -f [double]$Car.rangeMi) } else { 'unknown' })
    }
    $off = @($items | Where-Object { $_.state -eq 'off' })
    $morning = ($Now.Hour -ge 5 -and $Now.Hour -lt 10)
    if ($null -eq $Car) { return [pscustomobject]@{ ready = $false; overall = 'NO DATA'; off = @('no car data yet'); items = @($items); morning = $morning; at = $Now } }
    return [pscustomobject]@{ ready = ($off.Count -eq 0); overall = $(if ($off.Count -eq 0) { 'READY' } else { 'CHECK' }); off = @($off | ForEach-Object { $_.label + ': ' + $_.text }); items = @($items); morning = $morning; at = $Now }
}
function Render-Ready {
    $car = Get-Car4319; $tires = $null; if ($null -ne $script:View) { $tires = $script:View.tires }
    $now = Get-Now4319; $r = Get-ReadyCheck $car $tires $now; $script:Ready4319 = $r
    $acc = $(if ($r.ready) { 'Green' } elseif ($r.overall -eq 'NO DATA') { 'Caption' } else { 'Amber' })
    $ui.ReadyBox.BorderBrush = T $acc; $ui.ReadyBox.Background = Get-Brush $(if ($r.ready) { '#1A49DF93' } else { '#26FFB547' })
    $ui.ReadyPill.Background = T $acc; $ui.ReadyPillTxt.Text = $r.overall; $ui.ReadyPillTxt.Foreground = Get-Brush '#FF0B0B0B'
    $ui.ReadyHdr.Text = $(if ($r.morning) { 'MORNING READY CHECK' } else { 'READY CHECK' }); $ui.ReadyHdr.Foreground = T 'Caption'
    $ui.ReadyWhen.Text = $(if ($null -ne $car -and $null -ne $car.atEpoch -and [int64]$car.atEpoch -gt 0) { 'cached · ' + (Format-Clock (ConvertFrom-Epoch $car.atEpoch)) } else { 'cached data' }); $ui.ReadyWhen.Foreground = T 'Caption'
    $ui.ReadyOff.Text = $(if ($r.ready) { '' } else { 'Check: ' + ($r.off -join ' · ') }); Set-Visible $ui.ReadyOff (-not $r.ready); $ui.ReadyOff.Foreground = T 'Amber'
    $ui.ReadyGrid.Children.Clear()
    $ico = @{ ok = [string][char]0x2713; off = '!'; info = [string][char]0x2022; unknown = '?' }
    if ($r.morning) {
        Set-Visible $ui.ReadyGrid $true; Set-Visible $ui.ReadyLine $false; $ui.ReadyPillTxt.FontSize = 13; $ui.ReadyHdr.FontSize = 11.5
        foreach ($it in $r.items) {
            $tb = New-Tb4319 '' 10.5 (T 'TextSoft'); $tb.TextTrimming = 'CharacterEllipsis'; $tb.Margin = '0,1,6,1'
            $b = $(switch ($it.state) { 'ok' { T 'Green' } 'off' { T 'Amber' } default { T 'Caption' } })
            $r1 = New-Object System.Windows.Documents.Run(($ico[$it.state] + ' ')); $r1.Foreground = $b; $r1.FontWeight = 'Bold'
            $r2 = New-Object System.Windows.Documents.Run(($it.label + ': ')); $r2.Foreground = T 'Caption'; $r2.FontWeight = 'SemiBold'
            $r3 = New-Object System.Windows.Documents.Run($it.text); $r3.Foreground = $(if ($it.state -eq 'off') { T 'Amber' } else { T 'Text' })
            [void]$tb.Inlines.Add($r1); [void]$tb.Inlines.Add($r2); [void]$tb.Inlines.Add($r3); $tb.ToolTip = ($it.label + ': ' + $it.text)
            [void]$ui.ReadyGrid.Children.Add($tb)
        }
    } else {
        Set-Visible $ui.ReadyGrid $false; Set-Visible $ui.ReadyLine $true; $ui.ReadyPillTxt.FontSize = 10.5; $ui.ReadyHdr.FontSize = 10.5
        $ui.ReadyLine.Text = (@($r.items | ForEach-Object { $ico[$_.state] + ' ' + $(if ($_.state -eq 'info') { $_.label + ' ' + $_.text } else { $_.text }) }) -join '  ·  '); $ui.ReadyLine.Foreground = T 'TextSoft'; $ui.ReadyLine.FontSize = 9.5
    }
    if ($r.morning -and -not $r.ready -and $null -ne $car) {
        $key = 'morning-' + $now.ToString('yyyy-MM-dd'); $mp = Get-MarkPath4319 'ready-check'
        if ((Get-MarkKey $mp) -ne $key) {
            Set-MarkKey $mp $key
            $script:Toast4319 = @(@($script:Toast4319) + ('ready: ' + $key))
            Show-WinToast 'TessDesk: morning check' ('Check: ' + ($r.off -join ' · '))
        }
    }
}

# ---- 4b. PSO BILL MATCH ----
$BillPrefillNote = 'Prefilled from your Gmail: PSO bill email of Sep 26, 2026, total $442.21 (due Oct 19, 2026). The email has no billing period or kWh: enter them from the bill.'
function Get-BillCfg {
    $o = Get-Merged4319 'billMatch' ([ordered]@{ enabled = $true; from = ''; to = ''; kwh = $null; usd = 442.21; note = $BillPrefillNote })
    $o.enabled = [bool]$o.enabled
    return $o
}
function ConvertTo-BillDate {
    param([string]$S)
    $S = ([string]$S).Trim(); if (-not $S) { return $null }
    $d = [DateTime]::MinValue
    foreach ($f in @('yyyy-MM-dd', 'M/d/yyyy', 'M/d/yy', 'MMM d yyyy', 'MMM d, yyyy')) { if ([DateTime]::TryParseExact($S, $f, $Inv, 'None', [ref]$d)) { return $d.Date } }
    return $null
}
function ConvertTo-BillNum { param($V) if ($null -eq $V) { return $null }; $s = ([string]$V) -replace '[\$,\s]', ''; if (-not $s) { return $null }; $n = 0.0; if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, $Inv, [ref]$n)) { return $n }; return $null }
function Get-BillMatch {
    param($Bill, $Sessions, [double]$PsoRate, [double]$Eff)
    $r = [ordered]@{ ok = $false; need = @(); from = $null; to = $null; billKwh = $null; billUsd = $null; billRate = $null; sessions = 0; teslaKwh = 0.0; trackedUsd = 0.0
        sharePct = $null; shareUsd = $null; estPsoUsd = $null; diffPct = $null; mismatch = $false; dataFrom = $null; partial = $false }
    $f = ConvertTo-BillDate $Bill.from; $t = ConvertTo-BillDate $Bill.to; $k = ConvertTo-BillNum $Bill.kwh; $u = ConvertTo-BillNum $Bill.usd
    if ($null -eq $f) { $r.need += 'period from' }; if ($null -eq $t) { $r.need += 'period to' }; if ($null -eq $k -or $k -le 0) { $r.need += 'total kWh' }; if ($null -eq $u -or $u -le 0) { $r.need += 'total $' }
    if ($null -ne $f -and $null -ne $t -and $t -lt $f) { $r.need += 'a TO date after FROM' }
    $r.from = $f; $r.to = $t; $r.billKwh = $k; $r.billUsd = $u
    if ($null -ne $k -and $k -gt 0 -and $null -ne $u) { $r.billRate = $u / $k }
    $all = @(@($Sessions) | Where-Object { $null -ne $_ -and -not (Test-Fast4319 $_) })
    if ($all.Count -gt 0) { $r.dataFrom = ConvertFrom-Epoch (($all | Measure-Object -Property startEpoch -Minimum).Minimum) }
    if ($null -eq $f -or $null -eq $t -or $t -lt $f) { return [pscustomobject]$r }
    $s0 = ConvertTo-EpochLocal $f; $s1 = ConvertTo-EpochLocal $t.AddDays(1)
    foreach ($s in $all) {
        if ([int64]$s.startEpoch -lt $s0 -or [int64]$s.startEpoch -ge $s1) { continue }
        $w = $(if ($null -ne $s.kwhWall -and [double]$s.kwhWall -gt 0) { [double]$s.kwhWall } elseif ($null -ne $s.kwhAdded -and $Eff -gt 0) { [double]$s.kwhAdded / $Eff } else { 0.0 })
        $r.teslaKwh += $w; $r.trackedUsd += [double](Get-Val $s.costUsdAllIn 0.0); $r.sessions++
    }
    $r.teslaKwh = [math]::Round($r.teslaKwh, 2); $r.trackedUsd = [math]::Round($r.trackedUsd, 2)
    $r.partial = ($null -ne $r.dataFrom -and $r.dataFrom.Date -gt $f)
    $r.estPsoUsd = [math]::Round($r.teslaKwh * $PsoRate, 2)
    if ($r.estPsoUsd -gt 0) { $r.diffPct = [math]::Round(($r.trackedUsd - $r.estPsoUsd) / $r.estPsoUsd * 100, 1); $r.mismatch = ([math]::Abs($r.diffPct) -gt 5) }
    if ($null -ne $k -and $k -gt 0) { $r.sharePct = [math]::Round($r.teslaKwh / $k * 100, 1) }
    if ($null -ne $r.billRate) { $r.shareUsd = [math]::Round($r.teslaKwh * $r.billRate, 2) }
    $r.ok = ($r.need.Count -eq 0)
    return [pscustomobject]$r
}
function Format-BillDate { param($D) if ($null -eq $D) { return '' }; return ([DateTime]$D).ToString('M/d/yyyy', $Inv) }
function Render-Bill {
    $b = Get-BillCfg; $on = [bool]$b.enabled
    $script:BillRendering = $true; try { $ui.BillSwitch.IsChecked = $on } finally { $script:BillRendering = $false }
    Set-Visible $ui.BillBody $on
    $ui.BillHdr.Foreground = T 'Caption'; $ui.BillState.Foreground = T 'Caption'
    if (-not $on) { $ui.BillState.Text = 'off'; $script:Bill4319 = $null; return }
    if (-not $ui.BillFrom.IsKeyboardFocusWithin) { $ui.BillFrom.Text = [string]$b.from }; if (-not $ui.BillTo.IsKeyboardFocusWithin) { $ui.BillTo.Text = [string]$b.to }
    if (-not $ui.BillKwh.IsKeyboardFocusWithin) { $ui.BillKwh.Text = $(if ($null -ne $b.kwh -and [string]$b.kwh -ne '') { [string]$b.kwh } else { '' }) }
    if (-not $ui.BillUsd.IsKeyboardFocusWithin) { $ui.BillUsd.Text = $(if ($null -ne $b.usd -and [string]$b.usd -ne '') { ([double](ConvertTo-BillNum $b.usd)).ToString('0.00', $Inv) } else { '' }) }
    foreach ($n in 'BillFromLbl', 'BillToLbl', 'BillKwhLbl', 'BillUsdLbl') { $ui[$n].Foreground = T 'Caption' }
    foreach ($n in 'BillFrom', 'BillTo', 'BillKwh', 'BillUsd') { $ui[$n].Foreground = T 'Text'; $ui[$n].BorderBrush = T 'BtnBorder' }
    $ui.BillSaveBtn.Tag = [System.Windows.CornerRadius]::new(4); $ui.BillSaveBtn.Background = T 'BtnBg'; $ui.BillSaveBtn.BorderBrush = T 'BtnBorder'
    $m = Get-BillMatch $b @(Get-CompletedForTotals $script:State) ($R_ON + $FCA) $EFFICIENCY; $script:Bill4319 = $m
    $ui.BillSrc.Text = [string]$b.note; $ui.BillSrc.Foreground = T 'Caption'; Set-Visible $ui.BillSrc ([bool]$b.note)
    $ui.BillRes1.Foreground = T 'Text'; $ui.BillRes2.Foreground = T 'TextSoft'
    if ($null -ne $m.from -and $null -ne $m.to -and $m.to -ge $m.from) {
        $ui.BillRes1.Text = ('Tesla share: {0:N1} kWh{1}{2} · {3} home charge{4}' -f $m.teslaKwh, $(if ($null -ne $m.shareUsd) { ' · ' + (Format-Money $m.shareUsd) } else { '' }), $(if ($null -ne $m.sharePct) { (' · {0:N1}% of the bill' -f $m.sharePct) } else { '' }), $m.sessions, $(if ($m.sessions -eq 1) { '' } else { 's' }))
        $ui.BillRes2.Text = ('At the PSO overnight rate ({0}): {1} · TessDesk tracked {2}{3}' -f (Format-C1 ($R_ON + $FCA)), (Format-Money $m.estPsoUsd), (Format-Money $m.trackedUsd), $(if ($null -ne $m.diffPct) { (' ({0}{1:N1}%)' -f $(if ($m.diffPct -ge 0) { '+' } else { '' }), $m.diffPct) } else { '' })) + $(if ($m.partial) { ' · TessDesk charge data starts ' + (Format-BillDate $m.dataFrom) + ', so earlier days are not counted' } else { '' })
        $ui.BillState.Text = $(if ($null -ne $m.sharePct) { ('{0:N1}% Tesla' -f $m.sharePct) } else { '' })
    } else {
        $ui.BillRes1.Text = 'Enter the billing period (from / to) and the total kWh from your PSO bill to see the Tesla share.'
        $ui.BillRes2.Text = $(if ($m.need.Count -gt 0) { 'Missing: ' + ($m.need -join ', ') } else { '' }); $ui.BillState.Text = 'needs the bill'
    }
    if ($m.mismatch) {
        $ui.BillFlagTxt.Text = ('Mismatch over 5%: TessDesk tracked {0} vs {1} at the PSO overnight rate ({2}{3:N1}%). Some charging may have run outside 11 PM-6 AM, or the rates in settings differ from the bill.' -f (Format-Money $m.trackedUsd), (Format-Money $m.estPsoUsd), $(if ($m.diffPct -ge 0) { '+' } else { '' }), $m.diffPct)
        $ui.BillFlagTxt.Foreground = T 'Amber'; $ui.BillFlag.BorderBrush = T 'Amber'; Set-Visible $ui.BillFlag $true
    } else { Set-Visible $ui.BillFlag $false }
}
function Save-BillInputs {
    $b = Get-BillCfg
    $b.from = $(if ($d = ConvertTo-BillDate $ui.BillFrom.Text) { $d.ToString('yyyy-MM-dd') } else { ([string]$ui.BillFrom.Text).Trim() })
    $b.to = $(if ($d = ConvertTo-BillDate $ui.BillTo.Text) { $d.ToString('yyyy-MM-dd') } else { ([string]$ui.BillTo.Text).Trim() })
    $b.kwh = ConvertTo-BillNum $ui.BillKwh.Text; $b.usd = ConvertTo-BillNum $ui.BillUsd.Text
    Save-Cfg4319 'billMatch' $b; Write-WidgetLog ('bill match saved: ' + $b.from + ' to ' + $b.to + ', ' + $b.kwh + ' kWh, $' + $b.usd)
    Render-Bill
}
function Set-BillEnabled { param([bool]$On) $b = Get-BillCfg; $b.enabled = $On; Save-Cfg4319 'billMatch' $b; Write-WidgetLog ('bill match ' + $(if ($On) { 'on' } else { 'off' })); Render-Bill }

# ---- 4c. BATTERY HEALTH TREND + TIPS ----
function Update-HealthCache {
    param([string]$Token, [int64]$NowE)
    $st = $script:State; if ($null -eq $st -or -not $script:VIN) { return }
    $last = [int64](Get-Val $st.healthFetchEpoch 0)
    if (($NowE - $last) -lt 6 * 3600 -and $null -ne $st.health) { return }
    $st.healthFetchEpoch = $NowE
    try {
        $cur = Invoke-Tessie '/battery_health?distance_format=mi' $Token
        $mine = @(@($cur.results) | Where-Object { $null -ne $_ -and [string]$_.vin -eq [string]$script:VIN }) | Select-Object -First 1
        $pts = @()
        try {
            # v4.3.21: first run (no saved history yet) asks for everything Tessie has (10 years, falls back to 400 days); later runs catch up on missed days
            $span = $(if (@(Read-OwnHealth).Count -lt 2) { 3650 } else { 400 })
            try { $h = Invoke-Tessie ("/$($script:VIN)/battery_health?from=" + ($NowE - $span * 86400) + "&to=$NowE&distance_format=mi") $Token }
            catch { if ($span -le 400) { throw }; $h = Invoke-Tessie ("/$($script:VIN)/battery_health?from=" + ($NowE - 400 * 86400) + "&to=$NowE&distance_format=mi") $Token }
            $script:HealthSpan = $span
            $byDay = [ordered]@{}
            $today = (ConvertFrom-Epoch $NowE).ToString('yyyy-MM-dd')
            foreach ($p in @($h.results)) { if ($null -eq $p -or -not $p.timestamp -or $null -eq $p.max_range) { continue }; $k = $(if ($p.timestamp -is [DateTime]) { $p.timestamp.ToUniversalTime().ToString('yyyy-MM-dd') } else { ([string]$p.timestamp).Substring(0, 10) }); if ($k -gt $today) { continue }; $byDay[$k] = $p }   # v4.3.21: never a day after the user's today
            $pts = @($byDay.Keys | ForEach-Object { $p = $byDay[$_]; [pscustomobject]@{ d = $_; range = [math]::Round([double]$p.max_range, 2); cap = $(if ($null -ne $p.capacity) { [math]::Round([double]$p.capacity, 2) } else { $null }); odo = $p.odometer } })
        } catch { Write-WidgetLog ('battery health history: ' + $_.Exception.Message) }
        if ($null -eq $mine) { throw 'no battery health for this car' }
        $st.health = [pscustomobject]@{ healthPct = $mine.health_percent; capacity = $mine.capacity; original = $mine.original_capacity; degradation = $mine.degradation_percent; maxRange = $mine.max_range; odometer = $mine.odometer; at = $NowE; points = $pts }
        Add-OwnHealthPoint $st.health $NowE
    } catch { Write-WidgetLog ('battery health fetch failed: ' + $_.Exception.Message); $st.healthFetchEpoch = $NowE - 6 * 3600 + 1800 }
}
function Get-HHPath { if ($null -ne $script:HealthSandbox) { return $script:HealthSandbox }; return $HealthHistPath }   # v4.3.21: the app's own folder (a self-test can point it at a temp file)
function Read-OwnHealth {
    if ($SelfTest -and $null -ne $script:OwnHealthMock) { return @($script:OwnHealthMock) }
    try { $p = Get-HHPath; if (Test-Path -LiteralPath $p) { $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.vin -and $script:VIN -and [string]$j.vin -ne [string]$script:VIN) { return @() }   # v4.3.21: history of another car (account changed): start fresh
            return @($j.points) } } catch {}; return @() }
function Add-OwnHealthPoint {
    param($H, [int64]$NowE)
    if (($SelfTest -and $null -eq $script:HealthSandbox) -or $null -eq $H -or $null -eq $H.maxRange) { return }
    try {
        $d = (ConvertFrom-Epoch $NowE).ToString('yyyy-MM-dd')
        $pts = Merge-HealthPoints @(Read-OwnHealth) $H $d   # v4.3.20: seeded with Tessie's past daily points, deduped by date, kept indefinitely
        [ordered]@{ note = 'TessDesk battery health history (one entry per day: health %, capacity kWh, est. full-pack range; from Tessie /battery_health with your own token; kept indefinitely)'; vin = [string]$script:VIN; points = @($pts) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-HHPath) -Encoding UTF8
    } catch { Write-WidgetLog ('health history save: ' + $_.Exception.Message) }
}
function Get-HealthSeries {
    param($H, $Own)
    $m = @{}
    foreach ($p in @($Own)) { if ($null -ne $p -and $p.d -and $null -ne $p.range) { $m[[string]$p.d] = [double]$p.range } }
    if ($null -ne $H) { foreach ($p in @($H.points)) { if ($null -ne $p -and $p.d -and $null -ne $p.range) { $m[[string]$p.d] = [double]$p.range } } }
    $keys = @($m.Keys | Sort-Object)
    return @($keys | ForEach-Object { [pscustomobject]@{ d = $_; range = $m[$_] } })
}
function Get-HealthTrend {
    param($Series)
    $s = @($Series); if ($s.Count -lt 2) { return $null }
    # smooth the ends: average of the first / last 7 points (Tessie's estimate moves a few miles day to day)
    $n = [math]::Min(7, [math]::Floor($s.Count / 2)); if ($n -lt 1) { $n = 1 }
    $a = [double](($s | Select-Object -First $n | Measure-Object -Property range -Average).Average); $b = [double](($s | Select-Object -Last $n | Measure-Object -Property range -Average).Average)
    $d0 = [DateTime]::ParseExact($s[0].d, 'yyyy-MM-dd', $Inv)
    return [pscustomobject]@{ fromRange = [math]::Round($a, 1); toRange = [math]::Round($b, 1); deltaPct = $(if ($a -gt 0) { [math]::Round(($b - $a) / $a * 100, 1) } else { $null }); since = $d0; points = $s.Count }
}
function Get-BatteryTips {
    param($Sessions, $Car, $Trips, $Health, [DateTime]$Now)
    $ss = @(@($Sessions) | Where-Object { $null -ne $_ }); $tips = @(); $good = @()
    $span = 60
    if ($ss.Count -gt 0) { $span = [math]::Max(1, [math]::Round(((ConvertTo-EpochLocal $Now) - [int64](($ss | Measure-Object -Property startEpoch -Minimum).Minimum)) / 86400.0)) }
    $full = @($ss | Where-Object { $null -ne $_.socEndPct -and [double]$_.socEndPct -ge 98 })
    $lim = $(if ($null -ne $Car) { $Car.limitPct } else { $null })
    if ($full.Count -ge 4) { $tips += ('You charged to 100% {0} times in the last {1} days. Save 100% for road trips; your daily limit{2} is easier on the battery.' -f $full.Count, $span, $(if ($null -ne $lim) { ' of ' + $lim + '%' } else { '' })) }
    elseif ($full.Count -gt 0) { $good += ('Only {0} charge{1} to 100% in {2} days: good, keep 100% for trips.' -f $full.Count, $(if ($full.Count -eq 1) { '' } else { 's' }), $span) }
    else { $good += ('No charges to 100% in {0} days: good.' -f $span) }
    # sat full: hours between a 95%+ charge ending and the next drive
    $tr = @(@($Trips) | Where-Object { $null -ne $_ } | Sort-Object { [int64]$_.startEpoch })
    if ($full.Count -gt 0 -and $tr.Count -gt 0) {
        $t0 = [int64]$tr[0].startEpoch; $sat = @()
        foreach ($s in @($ss | Where-Object { $null -ne $_.socEndPct -and [double]$_.socEndPct -ge 95 -and [int64]$_.endEpoch -ge $t0 })) {
            $nx = @($tr | Where-Object { [int64]$_.startEpoch -gt [int64]$s.endEpoch } | Select-Object -First 1)
            if ($nx.Count -gt 0) { $sat += (([int64]$nx[0].startEpoch - [int64]$s.endEpoch) / 3600.0) }
        }
        $long = @($sat | Where-Object { $_ -ge 8 })
        if ($long.Count -gt 0) { $tips += ('{0} of {1} recent full charges sat at 95%+ for 8+ hours before the next drive (longest {2:N0} h). Set a departure time so a full charge ends close to when you leave.' -f $long.Count, $sat.Count, ($sat | Measure-Object -Maximum).Maximum) }
        elseif ($sat.Count -gt 0) { $good += 'Your recent full charges were driven soon after: good.' }
    }
    if ($null -ne $lim) { if ([int]$lim -gt 90) { $tips += ('Your charge limit is {0}%. For daily driving, 80% or lower is easier on the battery.' -f $lim) } elseif ([int]$lim -le 80) { $good += ('Daily limit {0}%: right where Tesla suggests for everyday use.' -f $lim) } }
    $fast = @($ss | Where-Object { Test-Fast4319 $_ })
    if ($fast.Count -eq 0 -and $ss.Count -gt 0) { $good += ('No Supercharging in {0} days: all home AC charging, the gentlest kind.' -f $span) } elseif ($fast.Count -ge 6) { $tips += ('{0} fast charges in {1} days. Frequent DC fast charging adds heat; home charging is gentler.' -f $fast.Count, $span) }
    $starts = @($ss | Where-Object { $null -ne $_.socStartPct } | ForEach-Object { [double]$_.socStartPct })
    if ($starts.Count -gt 0) {
        $mn = ($starts | Measure-Object -Minimum).Minimum; $lo = @($starts | Where-Object { $_ -lt 20 })
        if ($lo.Count -gt 0) { $tips += ('{0} charge{1} started below 20% (lowest {2:N0}%). Plugging in before 20% avoids deep discharges.' -f $lo.Count, $(if ($lo.Count -eq 1) { '' } else { 's' }), $mn) } else { $good += ('Never below {0:N0}% before charging in {1} days: no deep discharges.' -f $mn, $span) }
    }
    $c14 = (ConvertTo-EpochLocal $Now) - 14 * 86400
    $temps = @($tr | Where-Object { [int64]$_.startEpoch -ge $c14 -and $null -ne $_.tempF } | ForEach-Object { [double]$_.tempF })
    if ($temps.Count -ge 3) { $avg = ($temps | Measure-Object -Average).Average; if ($avg -ge 85) { $tips += ('Hot weather: your drives averaged {0:N0}°F outside the last 2 weeks. Shade or a garage helps; heat ages a battery faster than miles.' -f $avg) } elseif ($avg -le 32) { $tips += ('Cold weather: your drives averaged {0:N0}°F outside the last 2 weeks. Charging soon after a drive, while the pack is warm, is more efficient.' -f $avg) } }
    $all = @($tips) + @($good)
    return @($all | Select-Object -First 5)
}
function Render-Health {
    $st = $script:State; $h = $null; if ($null -ne $st) { $h = $st.health }
    $own = Read-OwnHealth; $series = Get-HealthSeries $h $own; $tr = Get-HealthTrend $series
    $script:Health4319 = [pscustomobject]@{ health = $h; series = @($series); trend = $tr }
    foreach ($n in 'HealthHdr', 'HealthPctCap', 'HealthAsOf', 'HealthSparkCap', 'TipsHdr') { $ui[$n].Foreground = T 'Caption' }
    $ui.HealthPct.Foreground = T 'Text'; $ui.HealthL1.Foreground = T 'Text'; $ui.HealthL2.Foreground = T 'TextSoft'; $ui.HealthTrend.Foreground = T 'Caption'
    if ($null -ne $h -and $null -ne $h.healthPct) {
        $ui.HealthPct.Text = ('{0:N1}%' -f [double]$h.healthPct)
        $ui.HealthL1.Text = $(if ($null -ne $h.capacity -and $null -ne $h.original) { ('{0:N1} of {1:N1} kWh capacity' -f [double]$h.capacity, [double]$h.original) } else { '' })
        $ui.HealthL2.Text = $(if ($null -ne $h.maxRange) { ('Full-pack range {0:N0} mi (est.)' -f [double]$h.maxRange) } else { '' })
        $ui.HealthAsOf.Text = $(if ($h.at) { 'Tessie · ' + (ConvertFrom-Epoch $h.at).ToString('MMM d', $Inv) } else { '' })
    } else { $ui.HealthPct.Text = '--'; $ui.HealthL1.Text = 'Battery health loads from Tessie (every 6 h).'; $ui.HealthL2.Text = ''; $ui.HealthAsOf.Text = '' }
    $ui.HealthTrend.Text = $(if ($null -ne $tr) { ('Full-pack range {0:N0} → {1:N0} mi since {2} ({3}{4:N1}%)' -f $tr.fromRange, $tr.toRange, $tr.since.ToString('MMM yyyy', $Inv), $(if ($tr.deltaPct -ge 0) { '+' } else { '' }), $tr.deltaPct) } else { 'Trend: history builds up day by day' })
    # sparkline (max range per day, at most 90 points)
    $pts = @($series); $SpW = 130.0; $SpH = 36.0
    if ($pts.Count -gt 90) { $step = $pts.Count / 90.0; $pts = @(0..89 | ForEach-Object { $pts[[int][math]::Floor($_ * $step)] }) + @($series[-1]) }
    $pc = New-Object System.Windows.Media.PointCollection
    if ($pts.Count -ge 2) {
        $vals = @($pts | ForEach-Object { [double]$_.range }); $mn = ($vals | Measure-Object -Minimum).Minimum; $mx = ($vals | Measure-Object -Maximum).Maximum; if ($mx - $mn -lt 2) { $mx = $mn + 2 }
        for ($i = 0; $i -lt $pts.Count; $i++) { $x = 2 + ($SpW - 6) * $i / ($pts.Count - 1); $y = 2 + ($SpH - 6) * (1 - ($vals[$i] - $mn) / ($mx - $mn)); [void]$pc.Add([System.Windows.Point]::new($x, $y)) }
        $lp = $pc[$pc.Count - 1]; [System.Windows.Controls.Canvas]::SetLeft($ui.HealthDot, $lp.X - 3); [System.Windows.Controls.Canvas]::SetTop($ui.HealthDot, $lp.Y - 3); Set-Visible $ui.HealthDot $true
        $ui.HealthSparkCap.Text = ('max range · {0} days' -f $series.Count)
    } else { Set-Visible $ui.HealthDot $false; $ui.HealthSparkCap.Text = 'trend: needs 2+ days' }
    $ui.HealthLine.Points = $pc; $ui.HealthLine.Stroke = T 'Green'; $ui.HealthDot.Fill = T 'Green'
    $tips = @(Get-BatteryTips @(Get-CompletedForTotals $st) (Get-Car4319) @(Get-Val $st.trips @()) $h (Get-Now4319)); $script:Tips4319 = $tips
    $ui.TipsList.Children.Clear()
    foreach ($t in $tips) {
        $tb = New-Tb4319 ([string][char]0x2022 + ' ' + $t) 10 (T 'TextSoft'); $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,1,0,1'
        [void]$ui.TipsList.Children.Add($tb)
    }
    Set-Visible $ui.TipsHdr ($tips.Count -gt 0)
}
# ---- v4.3.20: HEALTH HISTORY (one entry per day: health %, capacity kWh, est. full-pack range; kept indefinitely) ----
# Health for Tessie's past daily points = capacity / original capacity (Tessie's own health_percent is capacity / original too).
function Merge-HealthPoints {
    param($Own, $H, [string]$Day)
    $pts = @(@($Own) | Where-Object { $null -ne $_ -and $_.d -and [string]$_.d -ne $Day })
    $have = @{}; $keep = @(); foreach ($p in $pts) { if (-not $have.ContainsKey([string]$p.d)) { $have[[string]$p.d] = $true; $keep += $p } }; $pts = $keep
    $orig = $null; if ($null -ne $H -and $null -ne $H.original) { $orig = [double]$H.original }
    if ($null -ne $H -and $null -ne $orig -and $orig -gt 0) {
        foreach ($p in @($H.points)) {
            if ($null -eq $p -or -not $p.d -or $null -eq $p.cap -or [string]$p.d -eq $Day -or $have.ContainsKey([string]$p.d)) { continue }
            $pts += [pscustomobject]@{ d = [string]$p.d; range = $p.range; cap = $p.cap; health = [math]::Round([double]$p.cap / $orig * 100, 1); odo = $p.odo; src = 'tessie' }; $have[[string]$p.d] = $true
        }
    }
    if ($null -ne $H -and $null -ne $H.healthPct -and $Day) { $pts += [pscustomobject]@{ d = $Day; range = $(if ($null -ne $H.maxRange) { [math]::Round([double]$H.maxRange, 2) } else { $null }); cap = $H.capacity; health = $H.healthPct; odo = $H.odometer; src = 'daily' } }
    return @($pts | Sort-Object { [string]$_.d })
}
function Get-HealthHistory {
    param($H, $Own)   # returns rows newest first: d, health, cap, range, delta (vs the previous, older entry)
    $orig = $null; if ($null -ne $H -and $null -ne $H.original) { $orig = [double]$H.original }
    $m = @{}
    if ($null -ne $H -and $null -ne $orig -and $orig -gt 0) { foreach ($p in @($H.points)) { if ($null -eq $p -or -not $p.d -or $null -eq $p.cap) { continue }; $m[[string]$p.d] = [pscustomobject]@{ d = [string]$p.d; health = [math]::Round([double]$p.cap / $orig * 100, 1); cap = [double]$p.cap; range = $p.range } } }
    foreach ($p in @($Own)) {
        if ($null -eq $p -or -not $p.d) { continue }
        $hp = $p.health; if ($null -eq $hp -and $null -ne $p.cap -and $null -ne $orig -and $orig -gt 0) { $hp = [double]$p.cap / $orig * 100 }
        if ($null -eq $hp) { continue }
        $m[[string]$p.d] = [pscustomobject]@{ d = [string]$p.d; health = [math]::Round([double]$hp, 1); cap = $(if ($null -ne $p.cap) { [double]$p.cap } else { $null }); range = $p.range }
    }
    $asc = @($m.Keys | Sort-Object | ForEach-Object { $m[$_] }); $cal = Get-HealthCal $asc; $rows = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $asc.Count; $i++) { $r = $asc[$i]; $dl = $(if ($i -gt 0) { [math]::Round($r.health - $asc[$i - 1].health, 1) } else { $null }); [void]$rows.Insert(0, [pscustomobject]@{ d = $r.d; health = $r.health; cap = $r.cap; range = $r.range; delta = $dl; cal = $cal.tags[[string]$r.d] }) }
    return $rows.ToArray()
}
function Get-HealthHistSummary {
    param($Rows)
    $r = @($Rows); if ($r.Count -eq 0) { return $null }
    $last = $r[0]; $ld = [DateTime]::ParseExact([string]$last.d, 'yyyy-MM-dd', $Inv)
    $o = [ordered]@{ latest = $last.health; latestD = $last.d; d30 = $null; d90 = $null; first = $null; firstD = $r[-1].d; count = $r.Count }
    foreach ($n in 30, 90) { $cut = $ld.AddDays(-$n).ToString('yyyy-MM-dd'); $b = @($r | Where-Object { [string]$_.d -le $cut } | Select-Object -First 1); if ($b.Count -gt 0) { $o[('d' + $n)] = [math]::Round($last.health - $b[0].health, 1) } }
    if ($r.Count -ge 2) { $o.first = [math]::Round($last.health - $r[-1].health, 1) }
    return [pscustomobject]$o
}
function Format-HDelta { param($V) if ($null -eq $V) { return '--' }; $v = [double]$V; if ([math]::Abs($v) -lt 0.05) { return '0.0' }; return ($(if ($v -gt 0) { [string][char]0x25B2 } else { [string][char]0x25BC }) + ' ' + ('{0:N1}' -f [math]::Abs($v))) }
function Get-HDeltaBrush { param($V) if ($null -eq $V -or [math]::Abs([double]$V) -lt 0.05) { return (T 'Caption') }; if ([double]$V -gt 0) { return (T 'Green') }; return (T 'Red') }
function Get-HHistOpen { $c = Get-Cfg4319 'healthHistory'; try { if ($null -ne $c -and $null -ne $c.open) { return [bool]$c.open } } catch {}; return $false }
function Set-HHistOpen { param([bool]$On) Save-Cfg4319 'healthHistory' ([ordered]@{ open = $On }); $script:HHistSig = ''; Render-HealthHist }
$script:HHistAll = $false; $script:HHistSig = ''; $script:HHistSeeded = $false
function Format-HDay { param([string]$D) try { return [DateTime]::ParseExact($D, 'yyyy-MM-dd', $Inv).ToString('ddd MMM d, yyyy', $Inv) } catch { return $D } }
# ---- v4.3.22: CHARGE column in HEALTH HISTORY: the highest charge % reached each day (end SoC of that day's charges) + the charge type.
# H = home (the Home spot in settings, else the spot where most AC charging happens), AC = other AC charger, SC = Supercharger, DC = other DC fast charger.
# Fully in the app: Tessie /{vin}/charges with the user's own token. First run asks for everything (10 years, 400 days if that fails); then every 6 h from 2 days before the last fetch (catches up after time away). Offline: the saved file is shown.
$ChargeHistPath = Join-Path $scriptDir 'charge-history.json'
$script:ChargeSandbox = $null; $script:OwnChargesMock = $null; $script:ChgHistNext = 0; $script:ChgHistSpan = $null
function Get-CHPath { if ($null -ne $script:ChargeSandbox) { return $script:ChargeSandbox }; return $ChargeHistPath }
function Read-OwnCharges {
    if ($SelfTest -and $null -ne $script:OwnChargesMock) { return $script:OwnChargesMock }
    try { $p = Get-CHPath; if (Test-Path -LiteralPath $p) { $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.vin -and $script:VIN -and [string]$j.vin -ne [string]$script:VIN) { return $null }   # another car's charges
            return $j } } catch {}; return $null }
function Get-ChargeHome {
    param($Results, $Prev)
    $h = Get-Cfg4319 'home'
    try { if ($null -ne $h -and $null -ne $h.lat -and $null -ne $h.lon) { return [pscustomobject]@{ lat = [double]$h.lat; lon = [double]$h.lon; src = 'settings' } } } catch {}
    if ($null -ne $Prev -and $null -ne $Prev.lat -and $null -ne $Prev.lon) { return [pscustomobject]@{ lat = [double]$Prev.lat; lon = [double]$Prev.lon; src = [string]$Prev.src } }
    $cnt = @{}; $la = @{}; $lo = @{}
    foreach ($c in @($Results)) {
        if ($null -eq $c -or $c.is_supercharger -or $c.is_fast_charger -or $null -eq $c.latitude -or $null -eq $c.longitude) { continue }
        $k = [string]::Format($Inv, '{0:F3},{1:F3}', [double]$c.latitude, [double]$c.longitude)
        $cnt[$k] = 1 + $(if ($cnt.ContainsKey($k)) { $cnt[$k] } else { 0 }); $la[$k] = [double]$c.latitude; $lo[$k] = [double]$c.longitude
    }
    if ($cnt.Count -eq 0) { return $null }
    $best = @($cnt.Keys | Sort-Object { -$cnt[$_] }, { $_ })[0]
    return [pscustomobject]@{ lat = $la[$best]; lon = $lo[$best]; src = 'most AC charging' }
}
function ConvertTo-ChargeDays {
    param($Results, $HomeLL)   # -> hashtable d -> day (d, max, t, fast, fastMax, n, s)
    $days = @{}
    foreach ($c in @($Results | Sort-Object { [int64]$_.ended_at })) {
        if ($null -eq $c -or $null -eq $c.ended_at -or $null -eq $c.ending_battery) { continue }
        $d = (ConvertFrom-Epoch ([int64]$c.ended_at)).ToString('yyyy-MM-dd')
        $t = $(if ($c.is_supercharger) { 'SC' } elseif ($c.is_fast_charger) { 'DC' } elseif ($null -ne $HomeLL -and $null -ne $c.latitude -and $null -ne $c.longitude -and (Get-DistMi ([double]$c.latitude) ([double]$c.longitude) ([double]$HomeLL.lat) ([double]$HomeLL.lon)) -le 0.15) { 'H' } else { 'AC' })
        $e = [int][math]::Round([double]$c.ending_battery); $fast = ($t -eq 'SC' -or $t -eq 'DC')
        $o = $days[$d]; if ($null -eq $o) { $o = [ordered]@{ d = $d; max = -1; t = ''; fast = $false; fastMax = $null; n = 0; s = @() }; $days[$d] = $o }
        $o.n = $o.n + 1
        if ($fast) { $o.fast = $true; if ($null -eq $o.fastMax -or $e -gt $o.fastMax) { $o.fastMax = $e } }
        if ($e -gt $o.max -or ($e -eq $o.max -and $fast)) { $o.max = $e; $o.t = $t }
        $sb = $(if ($null -ne $c.starting_battery) { [string][int][math]::Round([double]$c.starting_battery) } else { '?' })
        $o.s = @($o.s) + ('{0} {1}-{2}% {3}' -f (ConvertFrom-Epoch ([int64]$c.ended_at)).ToString('h:mm tt', $Inv), $sb, $e, $t)
    }
    return $days
}
function Update-ChargeHist {
    param([string]$Token, [int64]$NowE)
    if (-not $script:VIN -or -not $Token -or $NowE -lt $script:ChgHistNext) { return }
    if ($SelfTest -and $null -eq $script:ChargeSandbox) { return }   # self-test: only the sandboxed fresh-install test fetches (mocked)
    $j = Read-OwnCharges; $have = @{}; $fa = [int64]0; $prevHome = $null
    if ($null -ne $j) { foreach ($x in @($j.days)) { if ($null -ne $x -and $x.d) { $have[[string]$x.d] = $x } }; $fa = [int64](Get-Val $j.fetchedAt 0); $prevHome = $j.home }
    if ($fa -gt 0 -and ($NowE - $fa) -lt 6 * 3600) { $script:ChgHistNext = $fa + 6 * 3600; return }
    $first = ($fa -le 0)
    $fromDay = $(if ($first) { (ConvertFrom-Epoch ($NowE - 3650 * 86400)).Date } else { (ConvertFrom-Epoch ([math]::Max($fa - 2 * 86400, $NowE - 400 * 86400))).Date })
    $from = [int64](ConvertTo-EpochLocal $fromDay); $span = [int][math]::Round(($NowE - $from) / 86400)
    try {
        try { $r = Invoke-Tessie ("/$($script:VIN)/charges?from=$from&to=$NowE&distance_format=mi&format=json") $Token }
        catch { if (-not $first) { throw }; $fromDay = (ConvertFrom-Epoch ($NowE - 400 * 86400)).Date; $from = [int64](ConvertTo-EpochLocal $fromDay); $span = 400
            $r = Invoke-Tessie ("/$($script:VIN)/charges?from=$from&to=$NowE&distance_format=mi&format=json") $Token }
    } catch { Write-WidgetLog ('charge history fetch failed: ' + $_.Exception.Message); $script:ChgHistNext = $NowE + 1800; return }
    $script:ChgHistSpan = $span
    $res = @($r.results); $homeLL = Get-ChargeHome $res $(if ($first) { $null } else { $prevHome })
    $new = ConvertTo-ChargeDays $res $homeLL; $fromD = $fromDay.ToString('yyyy-MM-dd')
    $all = @{}; foreach ($k in $have.Keys) { if ($k -le $fromD) { $all[$k] = $have[$k] } }   # later days are replaced with the fresh data (the first day may be partly before 'from', so it is kept unless the new data has it)
    foreach ($k in $new.Keys) { $all[$k] = $new[$k] }
    try {
        $p = Get-CHPath; $tmp = $p + '.tmp'
        [ordered]@{ note = 'TessDesk charge history (one entry per day: highest charge % reached and the charge type; from Tessie /charges with your own token; kept indefinitely)'; vin = [string]$script:VIN; fetchedAt = $NowE; span = $span
            home = $homeLL; days = @($all.Keys | Sort-Object | ForEach-Object { $all[$_] }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $p -Force
    } catch { Write-WidgetLog ('charge history save: ' + $_.Exception.Message) }
    $script:ChgHistNext = $NowE + 6 * 3600; $script:HHistSig = ''
}
function Get-ChargeDayMap {
    $j = Read-OwnCharges; $m = @{}; if ($null -eq $j) { return $m }
    foreach ($x in @($j.days)) { if ($null -ne $x -and $x.d) { $m[[string]$x.d] = $x } }
    return $m
}
function Format-ChargeDay { param($C) if ($null -eq $C -or $null -eq $C.max -or [int]$C.max -lt 0) { return [string][char]0x2014 }; return ([string]$C.t + ' ' + [int]$C.max + '%') }
function New-HChgCell {
    param($C)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.HorizontalAlignment = 'Right'
    if ($null -eq $C -or $null -eq $C.max -or [int]$C.max -lt 0) { [void]$sp.Children.Add((New-Tb4319 ([string][char]0x2014) 10.5 (T 'Caption'))); return $sp }
    $fastT = ($C.t -eq 'SC' -or $C.t -eq 'DC')
    $tb = New-Tb4319 (Format-ChargeDay $C) 10.5 $(if ($fastT) { T 'Amber' } else { T 'TextSoft' }) $(if ($fastT) { 'Bold' } else { 'SemiBold' })
    [void]$sp.Children.Add($tb)
    if ($C.fast -and -not $fastT) { $z = New-Tb4319 ([string][char]0x26A1) 10 (T 'Amber') 'Bold'; $z.Margin = '2,0,0,0'; [void]$sp.Children.Add($z) }
    $names = @{ H = 'home'; AC = 'AC charger'; SC = 'Supercharger'; DC = 'DC fast charger' }
    $sp.ToolTip = ('Highest charge reached: ' + [int]$C.max + '% (' + $names[[string]$C.t] + ')' + $(if ($C.fast -and -not $fastT) { '; fast charging this day too (up to ' + $C.fastMax + '%)' } else { '' }) + "`n" + [int]$C.n + ' charge' + $(if ([int]$C.n -eq 1) { '' } else { 's' }) + ' ended this day: ' + ((@($C.s) | Select-Object -First 8) -join ', '))
    return $sp
}
# ---------------- v4.3.23: CHARGING SCHEDULE (START AT / FINISH BY) in the START / STOP card ----------------
# Sets the car's own schedule through Tessie (developer.tessie.com), so it keeps working with the PC off:
#   START AT on       -> set_scheduled_charging enable=true time=<minutes after midnight>
#   FINISH BY on      -> set_scheduled_charging enable=false (START AT is overridden), then set_scheduled_departure enable=true
#                        departure_time=<finish> off_peak_charging_enabled=true end_off_peak_time=<finish> (the car finishes by that time),
#                        then set_charge_limit percent=<target> only if the target differs from the car's limit
#   FINISH BY off     -> set_scheduled_departure enable=false, then START AT is applied again
# The controls show the car's own schedule from the cached state (charge_state.scheduled_charging_mode / _start_time,
# scheduled_departure_time; never wakes the car). A change is sent ~2 s after the last click (debounced), after a confirm
# unless 'Schedule' is checked in SKIP CONFIRM. Your last picks are kept in config.json chargeSchedule.
$script:Sched = @{ dirty = $false; want = $null; status = 'idle'; reason = ''; applied = $null; appliedAt = 0; lastSteps = @(); log = @(); syncs = 0 }
$script:SchedSync = $false
$script:SchedCarMock = $null
$script:SchedSessMock = $null
$script:SchedSeenStart = $null
$script:SchedCmds = @('set_scheduled_charging', 'set_scheduled_departure', 'set_charge_limit')
$script:SchedTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SchedTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:SchedTimer.Add_Tick({ try { $script:SchedTimer.Stop(); Invoke-SchedSync } catch { $script:Sched.status = 'failed'; $script:Sched.reason = $_.Exception.Message; Write-WidgetLog ('schedule: ' + $_.Exception.Message) } })

function Format-SchedMin { param($Min) if ($null -eq $Min) { return '—' }; $m = ((([int]$Min) % 1440) + 1440) % 1440; return ([DateTime]::new(2000, 1, 1).AddMinutes($m)).ToString('h:mm tt', $Inv) }
function Get-EpochMin { param($E) if ($null -eq $E -or [double]$E -le 0) { return $null }; $d = ConvertFrom-Epoch ([int64]$E); return [int]($d.Hour * 60 + $d.Minute) }
function Get-SchedCar { if ($null -ne $script:SchedCarMock) { return $script:SchedCarMock }; return (Get-CtlCar) }
function Get-CarSched {
    # what the car has now (from the cached state): mode Off / StartAt / DepartBy, times in minutes after midnight (local)
    param($Car)
    $o = [ordered]@{ known = $false; mode = ''; startMin = $null; finishMin = $null; limit = $null; soc = $null; offPeak = $null; offPeakEndMin = $null; precond = $false; limitMin = 50; limitMax = 100 }
    if ($null -eq $Car) { return $o }
    $p = $Car.PSObject.Properties
    if ($null -ne $p['limitPct'] -and $null -ne $Car.limitPct) { $o.limit = [int]$Car.limitPct }
    if ($null -ne $p['socPct'] -and $null -ne $Car.socPct) { $o.soc = [double]$Car.socPct }
    if ($null -ne $p['limitMin'] -and $null -ne $Car.limitMin) { $o.limitMin = [int]$Car.limitMin }
    if ($null -ne $p['limitMax'] -and $null -ne $Car.limitMax) { $o.limitMax = [int]$Car.limitMax }
    if ($null -eq $p['schedMode'] -or -not [string]$Car.schedMode) { return $o }
    $o.known = $true; $o.mode = [string]$Car.schedMode
    $o.startMin = $(if ($null -ne $Car.schedStartMin) { [int]$Car.schedStartMin } else { Get-EpochMin $Car.schedStartEpoch })
    if ($null -ne $o.startMin) { $script:SchedSeenStart = [int]$o.startMin }   # the car leaves the start time out while it is charging
    $o.finishMin = $(if ($null -ne $Car.departMin) { [int]$Car.departMin } else { Get-EpochMin $Car.departEpoch })
    if ($null -ne $Car.offPeak) { $o.offPeak = [bool]$Car.offPeak }
    if ($null -ne $Car.offPeakEndMin) { $o.offPeakEndMin = [int]$Car.offPeakEndMin }
    $o.precond = [bool]$Car.precond
    return $o
}
function Get-SchedCfg {
    $o = [ordered]@{ startOn = $true; startMin = 1380; finishOn = $false; finishMin = 600; target = $null }
    $c = $null; try { $c = Get-Cfg4319 'chargeSchedule' } catch {}
    if ($null -ne $c) { foreach ($k in @($o.Keys)) { $q = $c.PSObject.Properties[$k]; if ($null -ne $q -and $null -ne $q.Value) { $o[$k] = $q.Value } } }
    $o.startOn = [bool]$o.startOn; $o.finishOn = [bool]$o.finishOn; $o.startMin = [int]$o.startMin; $o.finishMin = [int]$o.finishMin
    return $o
}
function Get-SchedFromCar {
    # the controls as the car has them (defaults for anything the car does not report: START AT 11:00 PM, FINISH BY 10:00 AM, target = car limit)
    param($C)
    $cfg = Get-SchedCfg
    $w = [ordered]@{ startOn = $cfg.startOn; startMin = $cfg.startMin; finishOn = $cfg.finishOn; finishMin = $cfg.finishMin; target = $(if ($null -ne $C.limit) { [int]$C.limit } elseif ($null -ne $cfg.target) { [int]$cfg.target } else { 80 }) }
    if ($C.known) {
        $w.finishOn = ($C.mode -eq 'DepartBy')
        if ($C.mode -eq 'StartAt') { $w.startOn = $true; if ($null -ne $C.startMin) { $w.startMin = [int]$C.startMin } elseif ($null -ne $script:SchedSeenStart) { $w.startMin = [int]$script:SchedSeenStart } }
        elseif ($C.mode -eq 'Off') { $w.startOn = $false; if ($null -ne $C.startMin) { $w.startMin = [int]$C.startMin } }
        if ($null -ne $C.finishMin -and ($C.mode -eq 'DepartBy' -or $null -eq (Get-Cfg4319 'chargeSchedule'))) { $w.finishMin = [int]$C.finishMin }
    }
    return $w
}
function Test-SchedMatch {
    param($W, $C)
    if (-not $C.known) { return $false }
    if ($W.finishOn) { return ($C.mode -eq 'DepartBy' -and $C.finishMin -eq $W.finishMin -and ($null -eq $C.limit -or [int]$C.limit -eq [int]$W.target)) }
    if ($W.startOn) { return ($C.mode -eq 'StartAt' -and $C.startMin -eq $W.startMin) }
    return ($C.mode -eq 'Off')
}
function Get-SchedShown {
    $C = Get-CarSched (Get-SchedCar)
    if ($null -ne $script:Sched.want -and ($script:Sched.dirty -or $script:SchedSync)) { return $script:Sched.want }
    if ($null -ne $script:Sched.applied -and ((Get-EpochNow) - [int64]$script:Sched.appliedAt) -lt 900 -and -not (Test-SchedMatch $script:Sched.applied $C)) { return $script:Sched.applied }
    return (Get-SchedFromCar $C)
}
function Get-SchedSteps {
    # the Tessie commands that turn what the car has (C) into what the controls show (W), in order
    param($W, $C)
    $s = @(); $b = { param($v) $(if ($v) { 'true' } else { 'false' }) }
    if ($W.finishOn) {
        if (-not $C.known -or $C.mode -eq 'StartAt') { $s += [pscustomobject]@{ cmd = 'set_scheduled_charging'; query = @{ enable = 'false'; time = [string][int]$W.startMin }; busy = 'Turning off START AT…'; okText = 'START AT off (FINISH BY is on)'; onOk = $null; ann = '' } }
        if (-not $C.known -or $C.mode -ne 'DepartBy' -or $C.finishMin -ne $W.finishMin -or $C.offPeak -ne $true) {
            $s += [pscustomobject]@{ cmd = 'set_scheduled_departure'; query = @{ enable = 'true'; departure_time = [string][int]$W.finishMin; preconditioning_enabled = (& $b $C.precond); preconditioning_weekdays_only = 'false'; off_peak_charging_enabled = 'true'; off_peak_charging_weekdays_only = 'false'; end_off_peak_time = [string][int]$W.finishMin }
                busy = ('Setting FINISH BY ' + (Format-SchedMin $W.finishMin) + '…'); okText = ('FINISH BY ' + (Format-SchedMin $W.finishMin)); onOk = $null; ann = '' } }
        if ($null -ne $W.target -and ($null -eq $C.limit -or [int]$C.limit -ne [int]$W.target)) {
            $s += [pscustomobject]@{ cmd = 'set_charge_limit'; query = @{ percent = [string][int]$W.target }; busy = ('Setting charge limit ' + [int]$W.target + '%…'); okText = ('Charge limit ' + [int]$W.target + '%'); onOk = [scriptblock]::Create('Set-CtlOverride ''limit'' ' + [int]$W.target); ann = '' } }
    } else {
        if (-not $C.known -or $C.mode -eq 'DepartBy') { $s += [pscustomobject]@{ cmd = 'set_scheduled_departure'; query = @{ enable = 'false'; departure_time = [string][int]$W.finishMin }; busy = 'Turning off FINISH BY…'; okText = 'FINISH BY off'; onOk = $null; ann = '' } }
        if ($W.startOn) {
            if (-not $C.known -or $C.mode -ne 'StartAt' -or $C.startMin -ne $W.startMin) { $s += [pscustomobject]@{ cmd = 'set_scheduled_charging'; query = @{ enable = 'true'; time = [string][int]$W.startMin }; busy = ('Setting START AT ' + (Format-SchedMin $W.startMin) + '…'); okText = ('START AT ' + (Format-SchedMin $W.startMin)); onOk = $null; ann = '' } }
        } elseif (-not $C.known -or $C.mode -eq 'StartAt') { $s += [pscustomobject]@{ cmd = 'set_scheduled_charging'; query = @{ enable = 'false'; time = [string][int]$W.startMin }; busy = 'Turning off START AT…'; okText = 'START AT off'; onOk = $null; ann = '' } }
    }
    return @($s)
}
function Get-HomeChargeRate {
    # typical home (AC, not fast) charging from your own Tessie charge history: kW added and kWh per 1%
    param($Sessions)
    $kw = @(); $kpp = @()
    foreach ($x in @($Sessions)) {
        if ($null -eq $x -or [bool]$x.fast -or $null -eq $x.kwhAdded -or $null -eq $x.startEpoch -or $null -eq $x.endEpoch) { continue }
        $h = ([double]$x.endEpoch - [double]$x.startEpoch) / 3600; $k = [double]$x.kwhAdded
        if ($h -ge 0.5 -and $k -gt 2) { $kw += ($k / $h) }
        if ($null -ne $x.socStartPct -and $null -ne $x.socEndPct) { $d = [double]$x.socEndPct - [double]$x.socStartPct; if ($d -ge 10) { $kpp += ($k / $d) } }
    }
    $med = { param($a) $s = @($a | Sort-Object); if ($s.Count -eq 0) { return $null }; $m = [int][math]::Floor($s.Count / 2); if ($s.Count % 2) { return [double]$s[$m] }; return ([double]$s[$m - 1] + [double]$s[$m]) / 2 }
    $o = [ordered]@{ kw = (& $med $kw); kwhPerPct = (& $med $kpp); n = $kw.Count; nPct = $kpp.Count }
    if ($null -eq $o.kwhPerPct) { try { $hc = $script:State.health.capacity; if ($null -ne $hc -and [double]$hc -gt 20) { $o.kwhPerPct = [double]$hc / 100 } } catch {} }
    return $o
}
function Get-SchedEstimate {
    param($W, $C, $Rate)
    $tg = $(if ($null -ne $W.target) { [int]$W.target } else { $C.limit })
    $o = [ordered]@{ text = ''; hours = $null; startMin = $null; doneMin = $null; kwh = $null }
    $need = $null; if ($null -ne $C.soc -and $null -ne $tg) { $need = [double]$tg - [double]$C.soc }
    $canEst = ($null -ne $need -and $need -gt 0 -and $null -ne $Rate -and $null -ne $Rate.kw -and [double]$Rate.kw -gt 0.5 -and $null -ne $Rate.kwhPerPct)
    if ($canEst) { $o.kwh = [math]::Round($need * [double]$Rate.kwhPerPct, 1); $o.hours = $o.kwh / [double]$Rate.kw }
    if ($W.finishOn) {
        $fin = Format-SchedMin $W.finishMin
        if ($canEst) { $o.startMin = [int]((([math]::Round(([int]$W.finishMin - $o.hours * 60) / 5) * 5) % 1440 + 1440) % 1440); $o.text = ('Finishes ~{0} at {1}% (est. start {2})' -f $fin, $tg, (Format-SchedMin $o.startMin)) }
        elseif ($null -ne $need -and $need -le 0) { $o.text = ('Finishes by {0} · already at {1:N0}% (target {2}%)' -f $fin, [double]$C.soc, $tg) }
        else { $o.text = ('Finishes by {0}' -f $fin) + $(if ($null -ne $tg) { ' at ' + $tg + '%' } else { '' }) }
    } elseif ($W.startOn) {
        $st = Format-SchedMin $W.startMin
        if ($canEst) { $o.doneMin = [int]((([math]::Round(([int]$W.startMin + $o.hours * 60) / 5) * 5) % 1440 + 1440) % 1440); $o.text = ('Starts {0} nightly · ~{1:N1} h to {2}% (done ~{3})' -f $st, $o.hours, $tg, (Format-SchedMin $o.doneMin)) }
        else { $o.text = ('Starts {0} nightly' -f $st) }
    } else { $o.text = 'No schedule · charges as soon as it is plugged in' }
    return $o
}
function Get-SchedStatusText {
    $s = $script:Sched; $C = Get-CarSched (Get-SchedCar)
    switch ($s.status) {
        'syncing' { return @('Syncing…', 'Amber') }
        'pending' { return @('Change pending…', 'Amber') }
        'failed' { return @(('Failed: ' + $s.reason), 'Red') }
        'cancelled' { return @('Not sent (cancelled)', 'Caption') }
        'off' { return @($s.reason, 'Caption') }
    }
    if (-not $C.known) { return @('Car schedule unknown', 'Caption') }
    if ($s.status -eq 'synced') { return @(('Synced' + $(if ($CTL_DRYRUN) { ' (dry run)' } else { '' })), 'Green') }
    return @('Synced', 'Green')
}
function Set-SchedTxtCtl { param($Chk, [bool]$On) if ([bool]$Chk.IsChecked -ne $On) { $Chk.IsChecked = $On } }
function Render-Sched {
    param([bool]$En = $true)
    if ($null -eq $ui['SchedBox']) { return }
    $W = Get-SchedShown; $C = Get-CarSched (Get-SchedCar)
    $canSend = ($En -and $CTL_ENABLED -and [bool]$script:CmdAllowed)
    Set-SchedTxtCtl $ui.SchedStartChk ([bool]$W.startOn); Set-SchedTxtCtl $ui.SchedFinishChk ([bool]$W.finishOn)
    $ui.SchedStartVal.Text = Format-SchedMin $W.startMin; $ui.SchedFinishVal.Text = Format-SchedMin $W.finishMin
    $ui.SchedTgtVal.Text = $(if ($null -ne $W.target) { ([int]$W.target).ToString() + '%' } else { '—' })
    $startLive = ([bool]$W.startOn -and -not [bool]$W.finishOn)
    $ui.SchedStartChk.Foreground = $(if ($startLive) { T 'Green' } elseif ([bool]$W.startOn) { T 'Caption' } else { T 'TextSoft' })
    $ui.SchedFinishChk.Foreground = $(if ([bool]$W.finishOn) { T 'Green' } else { T 'TextSoft' })
    $ui.SchedStartVal.Foreground = $(if ($startLive) { T 'Text' } else { T 'Caption' })
    foreach ($n in 'SchedFinishVal', 'SchedTgtVal') { $ui[$n].Foreground = $(if ([bool]$W.finishOn) { T 'Text' } else { T 'Caption' }) }
    $ui.SchedStartChk.ToolTip = $(if ([bool]$W.finishOn) { 'START AT is overridden while FINISH BY is on (it comes back when FINISH BY is turned off)' } else { 'Start charging at this time every night (the car''s own scheduled charging; works with the PC off)' })
    foreach ($n in 'SchedStartChk', 'SchedFinishChk', 'SchedStartDn', 'SchedStartUp', 'SchedFinishDn', 'SchedFinishUp', 'SchedTgtDn', 'SchedTgtUp') { $ui[$n].IsEnabled = ($canSend -and $script:Sched.status -ne 'syncing') }
    foreach ($n in 'SchedStartBox', 'SchedFinishBox', 'SchedTgtBox') { $ui[$n].BorderBrush = T 'BtnBorder'; $ui[$n].Background = T 'BtnBg' }
    $rate = Get-HomeChargeRate $(if ($null -ne $script:SchedSessMock) { $script:SchedSessMock } elseif ($null -ne $script:State) { $script:State.recentSessions } else { @() })
    $est = Get-SchedEstimate $W $C $rate; $script:Sched.est = $est; $script:Sched.rate = $rate
    $ui.SchedEst.Text = $est.text; $ui.SchedEst.Foreground = T 'TextSoft'
    if (-not $canSend -and $script:Sched.status -ne 'failed') { $ui.SchedSync.Text = $(if (-not $CTL_ENABLED) { 'Controls off' } else { 'Commands off' }); $ui.SchedSync.Foreground = T 'Caption' }
    else { $st = Get-SchedStatusText; $ui.SchedSync.Text = $st[0]; $ui.SchedSync.Foreground = T $st[1] }
    $ui.SchedSync.ToolTip = ('Car schedule now: ' + (Get-CarSchedText $C) + $(if ($script:Sched.reason) { "`nLast: " + $script:Sched.reason } else { '' }))
    $ui.SchedBox.BorderBrush = T 'BtnBorder'
}
function Get-CarSchedText {
    param($C)
    if (-not $C.known) { return 'unknown (no schedule data in the cached state yet)' }
    switch ($C.mode) {
        'StartAt' { return ('START AT ' + $(if ($null -ne $C.startMin) { Format-SchedMin $C.startMin } else { '(time not in the car''s report right now' + $(if ($null -ne $script:SchedSeenStart) { '; last seen ' + (Format-SchedMin $script:SchedSeenStart) } else { '' }) + ')' }) + ' (scheduled charging)') }
        'DepartBy' { return ('FINISH BY ' + (Format-SchedMin $C.finishMin) + ' (scheduled departure' + $(if ($C.offPeak) { ', off-peak charging' } else { '' }) + ')' + $(if ($null -ne $C.limit) { ', limit ' + $C.limit + '%' } else { '' })) }
        'Off' { return 'Off (no schedule)' }
    }
    return $C.mode
}
function Set-SchedWant {
    # a control changed: remember it, show it, and send it ~2 s after the last change
    param([hashtable]$Change)
    if ($script:SchedSync) { return }
    $cur = Get-SchedShown; $w = [ordered]@{}; foreach ($k in 'startOn', 'startMin', 'finishOn', 'finishMin', 'target') { $w[$k] = $cur[$k] }
    foreach ($k in $Change.Keys) { $w[$k] = $Change[$k] }
    $C = Get-CarSched (Get-SchedCar)
    $w.startMin = ((([int]$w.startMin) % 1440) + 1440) % 1440; $w.finishMin = ((([int]$w.finishMin) % 1440) + 1440) % 1440
    if ($null -ne $w.target) { $w.target = [int][math]::Max($C.limitMin, [math]::Min($C.limitMax, [int]$w.target)) }
    $script:Sched.want = $w; $script:Sched.dirty = $true; $script:Sched.status = 'pending'; $script:Sched.reason = ''
    $script:SchedTimer.Stop(); $script:SchedTimer.Start()
    Render-Sched $true
}
function Get-SchedSummary { param($W) if ($W.finishOn) { return ('FINISH BY ' + (Format-SchedMin $W.finishMin) + ' at ' + $W.target + '% (off-peak; START AT paused)') }; if ($W.startOn) { return ('START AT ' + (Format-SchedMin $W.startMin) + ' nightly') }; return 'No schedule (charge when plugged in)' }
function Invoke-SchedSync {
    $w = $script:Sched.want; if ($null -eq $w -or -not $script:Sched.dirty) { return }
    $C = Get-CarSched (Get-SchedCar)
    $steps = @(Get-SchedSteps $w $C)
    $script:Sched.lastSteps = @($steps | ForEach-Object { $q = $_.query; $_.cmd + '?' + ((@($q.Keys | Sort-Object) | ForEach-Object { $_ + '=' + $q[$_] }) -join '&') })
    if ($steps.Count -eq 0) { $script:Sched.dirty = $false; $script:Sched.status = 'synced'; $script:Sched.reason = 'already set on the car'; $script:Sched.want = $null; Render-Sched $true; return }
    if ($script:CtlBusy) { $script:Sched.reason = 'waiting for another command'; $script:SchedTimer.Stop(); $script:SchedTimer.Start(); return }
    $sum = Get-SchedSummary $w
    if (-not (Test-SkipConfirm 'schedule') -and -not (Confirm-Ctl ('Update the car''s charging schedule?' + "`n`n" + $sum))) {
        $script:Sched.dirty = $false; $script:Sched.want = $null; $script:Sched.status = 'cancelled'; $script:Sched.reason = 'cancelled'; Set-CtlResult 'idle' 'Charging schedule unchanged'; Render-Sched $true; return }
    $script:SchedSync = $true; $script:Sched.status = 'syncing'; $script:Sched.syncs++
    $script:Sched.log = @(@($script:Sched.log) + ('sync: ' + $sum + ' -> ' + ($script:Sched.lastSteps -join ' ; ')) | Select-Object -Last 20)
    Write-WidgetLog ('charging schedule: ' + $sum + ' (' + $steps.Count + ' command' + $(if ($steps.Count -ne 1) { 's' } else { '' }) + ')')
    $ok = Start-TessieSequence $steps
    if (-not $ok) { $script:SchedSync = $false; $script:Sched.dirty = $false; $script:Sched.want = $null; $script:Sched.status = 'failed'; $script:Sched.reason = $(if ($script:CtlResultText) { ([string]$script:CtlResultText).TrimStart('✕ ') } else { 'could not send' }) }
    Render-Sched $true
}
function Complete-SchedStep {
    param($J, [bool]$Ok, [string]$Why, [bool]$More)
    $script:Sched.log = @(@($script:Sched.log) + ($J.cmd + ' ' + $(if ($Ok) { 'ok' } else { 'FAILED ' + $Why })) | Select-Object -Last 20)
    if (-not $Ok) { $script:SchedSync = $false; $script:Sched.dirty = $false; $script:Sched.want = $null; $script:Sched.status = 'failed'; $script:Sched.reason = ($J.cmd + ': ' + $Why) }
    elseif (-not $More) { $w = $script:Sched.want; try { Save-Cfg4319 'chargeSchedule' ([ordered]@{ startOn = [bool]$w.startOn; startMin = [int]$w.startMin; finishOn = [bool]$w.finishOn; finishMin = [int]$w.finishMin; target = $w.target }) } catch {}
        $script:SchedSync = $false; $script:Sched.applied = $script:Sched.want; $script:Sched.appliedAt = Get-EpochNow; $script:Sched.dirty = $false; $script:Sched.want = $null; $script:Sched.status = 'synced'; $script:Sched.reason = ('sent ' + (Format-Clock (Get-LocalNow))) }
    try { Render-Sched $true } catch {}
}
function Get-SchedInfo {
    $C = Get-CarSched (Get-SchedCar); $W = Get-SchedShown
    return [ordered]@{ car = (Get-CarSchedText $C); carRaw = $C; shown = $W; status = $(if ($null -ne $ui['SchedSync']) { $ui.SchedSync.Text } else { '' }); estimate = $(if ($null -ne $ui['SchedEst']) { $ui.SchedEst.Text } else { '' })
        dirty = $script:Sched.dirty; lastSteps = $script:Sched.lastSteps; log = $script:Sched.log }
}
# controls: toggles, 15-minute steps for the times (buttons or mouse wheel), 5% steps for the target
$ui.SchedStartChk.Add_Click({ try { Set-SchedWant @{ startOn = [bool]$ui.SchedStartChk.IsChecked } } catch { Write-WidgetLog ('schedule: ' + $_.Exception.Message) } })
$ui.SchedFinishChk.Add_Click({ try { Set-SchedWant @{ finishOn = [bool]$ui.SchedFinishChk.IsChecked } } catch { Write-WidgetLog ('schedule: ' + $_.Exception.Message) } })
$script:SchedStep = { param([string]$K, [int]$D)
    $w = Get-SchedShown
    if ($K -eq 'target') { $t = $(if ($null -ne $w.target) { [int]$w.target } else { 80 }); $n = $(if ($D -gt 0) { [math]::Floor($t / 5) * 5 + 5 } else { [math]::Ceiling($t / 5) * 5 - 5 }); Set-SchedWant @{ target = [int]$n; finishOn = $true } }
    elseif ($K -eq 'startMin') { Set-SchedWant @{ startMin = ([int]$w.startMin + $D); startOn = $true } }
    else { Set-SchedWant @{ finishMin = ([int]$w.finishMin + $D); finishOn = $true } } }
$ui.SchedStartDn.Add_Click({ try { & $script:SchedStep 'startMin' -15 } catch {} }); $ui.SchedStartUp.Add_Click({ try { & $script:SchedStep 'startMin' 15 } catch {} })
$ui.SchedFinishDn.Add_Click({ try { & $script:SchedStep 'finishMin' -15 } catch {} }); $ui.SchedFinishUp.Add_Click({ try { & $script:SchedStep 'finishMin' 15 } catch {} })
$ui.SchedTgtDn.Add_Click({ try { & $script:SchedStep 'target' -5 } catch {} }); $ui.SchedTgtUp.Add_Click({ try { & $script:SchedStep 'target' 5 } catch {} })
foreach ($pair in @(@('SchedStartBox', 'startMin', 15), @('SchedFinishBox', 'finishMin', 15), @('SchedTgtBox', 'target', 5))) {
    $ui[$pair[0]].Tag = ($pair[1] + '|' + $pair[2])
    $ui[$pair[0]].Add_PreviewMouseWheel({ param($s9, $e9) try { if ($ui.SchedStartDn.IsEnabled) { $t = ([string]$s9.Tag).Split('|'); & $script:SchedStep $t[0] $(if ($e9.Delta -gt 0) { [int]$t[1] } else { - [int]$t[1] }); $e9.Handled = $true } } catch {} })
}
try { Render-Sched $true } catch {}
function Render-HealthHist {
    $st = $script:State; $h = $null; if ($null -ne $st) { $h = $st.health }
    # seed the saved history once per session from Tessie's past daily points (the next 6-hourly fetch adds today's entry as well)
    if (-not $SelfTest -and -not $script:HHistSeeded -and $null -ne $h -and $null -ne $h.at) { $script:HHistSeeded = $true; Add-OwnHealthPoint $h ([int64]$h.at) }
    $rows = @(Get-HealthHistory $h (Read-OwnHealth)); $sum = Get-HealthHistSummary $rows; $open = Get-HHistOpen
    $script:HHist4320 = [pscustomobject]@{ rows = $rows; summary = $sum; open = $open; showAll = $script:HHistAll }
    $sig = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $open, $script:HHistAll, $rows.Count, $(if ($rows.Count) { $rows[0].d + $rows[0].health } else { '' }), (T 'Text'), (T 'Green'), (Get-Now4319).ToString('yyyyMMdd')
    if ($sig -eq $script:HHistSig) { return }; $script:HHistSig = $sig
    $ui.HHistBtn.Background = Get-Brush '#14FFFFFF'; $ui.HHistBtn.BorderBrush = T 'BtnBorder'; $ui.HHistHdr.Foreground = T 'Text'
    $ui.HHistHdr.Text = 'HEALTH HISTORY ' + $(if ($open) { [string][char]0x25BE } else { [string][char]0x25B8 })
    $ui.HHistSum.Inlines.Clear()
    if ($null -ne $sum) {
        $r1 = New-Object System.Windows.Documents.Run(('{0:N1}%' -f [double]$sum.latest)); $r1.FontWeight = 'Bold'; $r1.Foreground = T 'Text'; $ui.HHistSum.Inlines.Add($r1)
        $r2 = New-Object System.Windows.Documents.Run('  ·  30 days '); $r2.Foreground = T 'Caption'; $ui.HHistSum.Inlines.Add($r2)
        $r3 = New-Object System.Windows.Documents.Run((Format-HDelta $sum.d30)); $r3.FontWeight = 'Bold'; $r3.Foreground = Get-HDeltaBrush $sum.d30; $ui.HHistSum.Inlines.Add($r3)
    } else { $r0 = New-Object System.Windows.Documents.Run('builds up day by day'); $r0.Foreground = T 'Caption'; $ui.HHistSum.Inlines.Add($r0) }
    Set-Visible $ui.HHistBody $open
    $ui.HHistList.Children.Clear()
    if (-not $open) { return }
    foreach ($n in 'HHistC0', 'HHistC1', 'HHistC2', 'HHistC3', 'HHistC4') { $ui[$n].Foreground = T 'Caption' }
    $ui.HHistSummary.Inlines.Clear()
    if ($null -ne $sum) {
        $add = { param($t, $b, [string]$w = 'Normal') $x = New-Object System.Windows.Documents.Run($t); $x.Foreground = $b; $x.FontWeight = $w; $ui.HHistSummary.Inlines.Add($x) }
        & $add 'Change: ' (T 'Caption') 'SemiBold'
        & $add '30 days ' (T 'TextSoft'); & $add (Format-HDelta $sum.d30) (Get-HDeltaBrush $sum.d30) 'Bold'
        & $add '  ·  90 days ' (T 'TextSoft'); & $add (Format-HDelta $sum.d90) (Get-HDeltaBrush $sum.d90) 'Bold'
        & $add ('  ·  since ' + $(try { [DateTime]::ParseExact([string]$sum.firstD, 'yyyy-MM-dd', $Inv).ToString('MMM d, yyyy', $Inv) } catch { $sum.firstD }) + ' ') (T 'TextSoft'); & $add (Format-HDelta $sum.first) (Get-HDeltaBrush $sum.first) 'Bold'
        & $add ('  ·  ' + $sum.count + ' entr' + $(if ($sum.count -eq 1) { 'y' } else { 'ies' })) (T 'Caption')
    } else { $x = New-Object System.Windows.Documents.Run('No history yet: one entry is logged per day from Tessie.'); $x.Foreground = T 'Caption'; $ui.HHistSummary.Inlines.Add($x) }
    Render-HealthCal $rows; $ui.HHistScroll.ScrollToVerticalOffset(0)
    $show = $(if ($script:HHistAll) { $rows } else { @($rows | Select-Object -First 30) })
    foreach ($r in $show) {
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,1,0,1'
        $cm = Get-ChargeDayMap   # v4.3.22
        foreach ($wd in 124, 50, 54, 68) { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = [System.Windows.GridLength]::new($wd); [void]$g.ColumnDefinitions.Add($cd) }
        $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star); [void]$g.ColumnDefinitions.Add($cd)
        $c = @((New-HDateCell $r), (New-Tb4319 ('{0:N1}%' -f [double]$r.health) 10.5 (T 'Text') 'Bold'), (New-Tb4319 (Format-HDelta $r.delta) 10.5 (Get-HDeltaBrush $r.delta) 'SemiBold'), (New-HChgCell $cm[[string]$r.d]), (New-Tb4319 $(if ($null -ne $r.cap) { '{0:N2} kWh' -f [double]$r.cap } else { '--' }) 10.5 (T 'TextSoft')))
        for ($i = 0; $i -lt 5; $i++) { if ($i -ge 1) { $c[$i].HorizontalAlignment = 'Right' }; [System.Windows.Controls.Grid]::SetColumn($c[$i], $i); [void]$g.Children.Add($c[$i]) }
        if ($null -ne $r.range) { $g.ToolTip = ('Est. full-pack range {0:N0} mi' -f [double]$r.range) }
        [void]$ui.HHistList.Children.Add($g)
    }
    Set-Visible $ui.HHistAllBtn ($rows.Count -gt 30)
    $ui.HHistAllTxt.Text = $(if ($script:HHistAll) { 'Show last 30' } else { 'Show all (' + $rows.Count + ')' })
    $ui.HHistAllBtn.Tag = [System.Windows.CornerRadius]::new(5); $ui.HHistAllBtn.Background = T 'BtnBg'; $ui.HHistAllBtn.BorderBrush = T 'BtnBorder'; $ui.HHistAllTxt.Foreground = T 'Text'
}
$ui.HHistBtn.Add_MouseLeftButtonUp({ try { Set-HHistOpen (-not (Get-HHistOpen)) } catch { Write-WidgetLog ('health history: ' + $_.Exception.Message) } })
$ui.HHistAllBtn.Add_Click({ try { $script:HHistAll = -not $script:HHistAll; $script:HHistSig = ''; Render-HealthHist } catch { Write-WidgetLog ('health history all: ' + $_.Exception.Message) } })
# ---- v4.3.21: CALIBRATION INFO (BMS estimate recalibrations in the health history) ----
# A day-to-day change of 1.5 points or more is a likely recalibration of the BMS estimate, not a real change in health.
# A one-day spike that goes back the next day (to within 1.5 points of the day before) is one event: the spike day = 'spike', the day after = 'revert'.
$HealthCalJump = 1.5
function Get-HealthCal {
    param($Asc)   # rows oldest first (d, health); returns tags (d -> step / spike / revert) and events (oldest first)
    $a = @($Asc); $tags = @{}; $ev = @(); $i = 1
    while ($i -lt $a.Count) {
        $d1 = [double]$a[$i].health - [double]$a[$i - 1].health
        if ([math]::Abs($d1) -ge $HealthCalJump - 1e-9) {
            if ($i + 1 -lt $a.Count) {
                $d2 = [double]$a[$i + 1].health - [double]$a[$i].health
                if ([math]::Abs($d2) -ge $HealthCalJump - 1e-9 -and [math]::Sign($d2) -ne [math]::Sign($d1) -and [math]::Abs([double]$a[$i + 1].health - [double]$a[$i - 1].health) -lt $HealthCalJump) {
                    $tags[[string]$a[$i].d] = 'spike'; $tags[[string]$a[$i + 1].d] = 'revert'
                    $ev += [pscustomobject]@{ d = [string]$a[$i].d; kind = 'spike'; from = [double]$a[$i - 1].health; to = [double]$a[$i].health; back = [string]$a[$i + 1].d; backTo = [double]$a[$i + 1].health }; $i += 2; continue
                }
            }
            $tags[[string]$a[$i].d] = 'step'; $ev += [pscustomobject]@{ d = [string]$a[$i].d; kind = 'step'; from = [double]$a[$i - 1].health; to = [double]$a[$i].health; back = $null; backTo = $null }
        }
        $i++
    }
    return [pscustomobject]@{ tags = $tags; events = @($ev) }
}
function Get-HealthCalInfo {
    param($Rows, [DateTime]$Today)   # rows newest first
    $asc = @($Rows); [array]::Reverse($asc)
    $c = Get-HealthCal $asc; $ev = @($c.events)
    if ($ev.Count -eq 0) { return [pscustomobject]@{ events = @(); last = $null; daysSince = $null } }
    $last = $ev[-1]; $ds = [int][math]::Floor(($Today.Date - [DateTime]::ParseExact($last.d, 'yyyy-MM-dd', $Inv)).TotalDays)
    return [pscustomobject]@{ events = $ev; last = $last; daysSince = $ds }
}
function Format-CalDate { param([string]$D) try { return [DateTime]::ParseExact($D, 'yyyy-MM-dd', $Inv).ToString('MMM d, yyyy', $Inv) } catch { return $D } }
function New-HDateCell {
    param($R)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    [void]$sp.Children.Add((New-Tb4319 (Format-HDay $R.d) 10.5 (T 'TextSoft')))
    if ($R.cal -eq 'step' -or $R.cal -eq 'spike' -or $R.cal -eq 'revert') {
        $b = New-Object System.Windows.Controls.Border; $b.CornerRadius = [System.Windows.CornerRadius]::new(3); $b.Padding = '3,0,3,0'; $b.Margin = '5,0,0,0'; $b.VerticalAlignment = 'Center'
        $b.Background = Get-Brush '#33FFB547'; $b.BorderBrush = T 'Amber'; $b.BorderThickness = '1'
        $t = New-Tb4319 'CAL' 8.5 (T 'Amber') 'Bold'; $b.Child = $t
        $b.ToolTip = $(switch ($R.cal) { 'spike' { 'Likely BMS recalibration: a one-day spike that went back the next day (an estimate change, not a real health change)' } 'revert' { 'Back after a one-day recalibration spike (an estimate change, not a real health change)' } default { 'Likely BMS recalibration: a jump of 1.5 points or more in one day (an estimate change, not a real health change)' } })
        [void]$sp.Children.Add($b)
    }
    return $sp
}
function Render-HealthCal {
    param($Rows)
    $ci = Get-HealthCalInfo $Rows (Get-Now4319); $script:HHistCal4321 = $ci
    $ui.HHistCal.Inlines.Clear()
    $a = New-Object System.Windows.Documents.Run('Calibration: '); $a.FontWeight = 'SemiBold'; $a.Foreground = T 'Caption'; $ui.HHistCal.Inlines.Add($a)
    if ($null -ne $ci.last) {
        $l = $ci.last
        $what = $(if ($l.kind -eq 'spike') { ('one-day spike {0:N1}% → {1:N1}%, back to {2:N1}% the next day' -f $l.from, $l.to, $l.backTo) } else { ('{0:N1}% → {1:N1}% in one day' -f $l.from, $l.to) })
        $b = New-Object System.Windows.Documents.Run(('last detected ' + (Format-CalDate $l.d))); $b.FontWeight = 'Bold'; $b.Foreground = T 'Amber'; $ui.HHistCal.Inlines.Add($b)
        $c = New-Object System.Windows.Documents.Run((' (' + $what + ') · ' + $ci.daysSince + ' day' + $(if ($ci.daysSince -eq 1) { '' } else { 's' }) + ' ago · ' + @($ci.events).Count + ' detected: ' + ((@($ci.events) | ForEach-Object { Format-CalDate $_.d }) -join ', '))); $c.Foreground = T 'TextSoft'; $ui.HHistCal.Inlines.Add($c)
        $ui.HHistCalNote.Text = 'CAL = likely BMS recalibration (a jump of 1.5+ points, or a one-day spike that went back): the estimate changed, not the battery.'
    } else {
        $c = New-Object System.Windows.Documents.Run(('no recalibration jumps detected in ' + @($Rows).Count + ' entries')); $c.Foreground = T 'TextSoft'; $ui.HHistCal.Inlines.Add($c)
        $ui.HHistCalNote.Text = ''
    }
    Set-Visible $ui.HHistCalNote ($ui.HHistCalNote.Text -ne '')
    $ui.HHistCalNote.Foreground = T 'Caption'; $ui.HHistTip.Foreground = T 'Caption'
    $ui.HHistTip.Text = 'Tip: to help the BMS calibrate, now and then charge from a low level (about 10-20%) to 90-100%, then let the car sleep for an hour or more.'
}
function Render-V4319 {
    foreach ($n in 'BillSep', 'HealthSep', 'PlugSetSep') { $ui[$n].Background = T 'Sep' }
    try { Render-PlugRem } catch { Write-WidgetLog ('plug reminder: ' + $_.Exception.Message) }
    try { Render-Ready } catch { Write-WidgetLog ('ready check: ' + $_.Exception.Message) }
    try { Render-Bill } catch { Write-WidgetLog ('bill match: ' + $_.Exception.Message) }
    try { Render-Health } catch { Write-WidgetLog ('battery health: ' + $_.Exception.Message) }
    try { Render-HealthHist } catch { Write-WidgetLog ('health history: ' + $_.Exception.Message) }   # v4.3.20
    try { Render-Trips } catch { Write-WidgetLog ('trips: ' + $_.Exception.Message) }
}
# wiring
$ui.PlugRemSwitch.Add_Checked({ try { if (-not (Get-PlugCfg).enabled) { Set-PlugEnabled $true } } catch {} })
$ui.PlugRemSwitch.Add_Unchecked({ try { if ((Get-PlugCfg).enabled) { Set-PlugEnabled $false } } catch {} })
$ui.BillSwitch.Add_Checked({ try { if (-not $script:BillRendering -and -not (Get-BillCfg).enabled) { Set-BillEnabled $true } } catch {} })
$ui.BillSwitch.Add_Unchecked({ try { if (-not $script:BillRendering -and (Get-BillCfg).enabled) { Set-BillEnabled $false } } catch {} })
$ui.BillSaveBtn.Add_Click({ try { Save-BillInputs } catch { Write-WidgetLog ('bill save: ' + $_.Exception.Message) } })
foreach ($bx in @($ui.BillFrom, $ui.BillTo, $ui.BillKwh, $ui.BillUsd)) { $bx.Add_PreviewKeyDown({ param($s9, $e9) try { if ($e9.Key -eq 'Enter') { Save-BillInputs; $e9.Handled = $true } } catch {} }) }
$ui.TripsMoreBtn.Add_Click({ try { Set-TripsOpen (-not (Get-TripsOpen)) } catch { Write-WidgetLog ('trips more: ' + $_.Exception.Message) } })
# v4.3.19: 30% wider (473 px). A layout saved at the old width (or the compact add-on restoring it) is widened back to $winW.
$script:WidthGuard = $false
$window.Add_SizeChanged({
    try {
        if ($script:WidthGuard) { return }
        $off = $false; try { if ($null -ne $script:CbCompact) { $off = [bool]$script:CbCompact.Off } } catch {}
        if (-not $off -and $window.Width -lt ($winW - 0.5) -and $window.Width -ge 300) {
            $script:WidthGuard = $true
            [void]$window.Dispatcher.BeginInvoke([Action]{ try { $o2 = $false; try { if ($null -ne $script:CbCompact) { $o2 = [bool]$script:CbCompact.Off } } catch {}; if (-not $o2 -and $window.Width -lt ($winW - 0.5)) { Write-WidgetLog ('width ' + $window.Width + ' -> ' + $winW); $window.Width = $winW } } catch {}; $script:WidthGuard = $false })
        }
    } catch {}
})
# Show local/cached data immediately; the first Tessie call runs once the window is on screen.
try {
    $script:View = Build-FallbackView (Read-LocalJson) 'Live: connecting…' 'starting'
    Set-CtlResult 'idle' $(if ($CTL_DRYRUN) { 'DRY RUN: buttons are simulated, nothing is sent' } else { 'Ready' })
    Render-View
} catch { Write-WidgetLog ('initial render failed: ' + $_.Exception.Message) }

# ---------------- -SelfTest (DRY RUN only: nothing is sent to the car) ----------------
$script:SelfSteps = $null
$script:LeaveWaitFor = $null; $script:LeaveWaitUntil = $null
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
    # ---- v4.3.21: HEALTH HISTORY (DRY RUN: nothing is sent to the car, nothing announced) ----
    $script:SelfRec.v4321 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text; footerBrand = $ui.FooterText.Text; footerBold = [string]$ui.FooterText.FontWeight; width = $winW }
    $script:ElPng4321 = { param($el, $n)
        $window.UpdateLayout(); $sc = 2.0; $w = [int][math]::Ceiling($el.ActualWidth * $sc); $h = [int][math]::Ceiling($el.ActualHeight * $sc)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $sc), (96 * $sc), [System.Windows.Media.PixelFormats]::Pbgra32)
        $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
        $dc.DrawRectangle((T 'CardBg'), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight))
        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($el)), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight)); $dc.Close(); $bmp.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $f = 'tessdesk-v4321-' + $n + '.png'; $fs = [IO.File]::Create((Join-Path $script:SelfDir $f)); try { $enc.Save($fs) } finally { $fs.Close() }; $script:SelfRec.shots += $f }
    & $add 'v4.3.21 pure: merge (dedupe by date, seed from Tessie, keep all), newest first, change vs previous, 30/90/first summary' @() {
        $H = [pscustomobject]@{ healthPct = 84.1; capacity = 66.28; original = 78.83; maxRange = 274.25; odometer = 54585; at = 0; points = @(
            [pscustomobject]@{ d = '2026-06-01'; range = 276.0; cap = 66.0 }, [pscustomobject]@{ d = '2026-07-09'; range = 275.0; cap = 66.2 },
            [pscustomobject]@{ d = '2026-09-08'; range = 274.0; cap = 65.9 }, [pscustomobject]@{ d = '2026-10-08'; range = 272.9; cap = 65.48 }) }
        $own = @([pscustomobject]@{ d = '2026-09-08'; range = 274.5; cap = 66.2; health = 84.0 }, [pscustomobject]@{ d = '2026-09-08'; range = 1; cap = 1; health = 1 })
        $m = @(Merge-HealthPoints $own $H '2026-10-08')
        $rows = @(Get-HealthHistory $H $m); $s = Get-HealthHistSummary $rows
        $big = @(0..899 | ForEach-Object { [pscustomobject]@{ d = (Get-Date '2023-01-01').AddDays($_).ToString('yyyy-MM-dd'); range = 280; cap = 67; health = 85.0 } })
        $mb = @(Merge-HealthPoints $big $H '2026-10-08'); $json = [ordered]@{ points = @($mb) } | ConvertTo-Json -Depth 4; $back = @(($json | ConvertFrom-Json).points)
        $e = @(Get-HealthHistory $null @()); $es = Get-HealthHistSummary $e
        $fmt = @((Format-HDelta 0.3), (Format-HDelta -0.2), (Format-HDelta 0), (Format-HDelta $null))
        $r = [ordered]@{ mergedDays = @($m | ForEach-Object { $_.d }); mergedHealth = @($m | ForEach-Object { $_.health }); rows = @($rows | ForEach-Object { '{0} {1} {2} {3}' -f $_.d, $_.health, $_.delta, $_.cap })
            summary = $s; keepAll = @($mb).Count; keepAllRoundTrip = $back.Count; uniqueDays = @($mb | ForEach-Object { $_.d } | Sort-Object -Unique).Count; emptyRows = $e.Count; emptySummaryNull = ($null -eq $es); fmt = $fmt }
        $r.pass = (($r.mergedDays -join ',') -eq '2026-06-01,2026-07-09,2026-09-08,2026-10-08' -and ($r.mergedHealth -join ',') -eq '83.7,84,84,84.1' -and
            $rows[0].d -eq '2026-10-08' -and $rows[0].health -eq 84.1 -and $rows[0].delta -eq 0.1 -and $rows[1].delta -eq 0 -and $rows[2].delta -eq 0.3 -and $null -eq $rows[3].delta -and
            $s.latest -eq 84.1 -and $s.d30 -eq 0.1 -and $s.d90 -eq 0.1 -and $s.first -eq 0.4 -and $s.count -eq 4 -and $s.firstD -eq '2026-06-01' -and
            $r.keepAll -eq 904 -and $r.keepAllRoundTrip -eq 904 -and $r.uniqueDays -eq 904 -and $r.emptyRows -eq 0 -and $r.emptySummaryNull -and
            $fmt[0] -eq ([string][char]0x25B2 + ' 0.3') -and $fmt[1] -eq ([string][char]0x25BC + ' 0.2') -and $fmt[2] -eq '0.0' -and $fmt[3] -eq '--')
        $ca = @(80.2, 80.2, 84.9, 85.0, 84.6, 89.2, 84.3, 84.5, 83.2, 84.1); $asc = @(for ($i = 0; $i -lt $ca.Count; $i++) { [pscustomobject]@{ d = ('2026-01-{0:00}' -f ($i + 1)); health = $ca[$i] } })
        $cc = Get-HealthCal $asc; $ci = Get-HealthCalInfo (@($asc | Sort-Object d -Descending)) ([DateTime]'2026-01-20')
        $r.cal = [ordered]@{ tags = (@($cc.tags.Keys | Sort-Object | ForEach-Object { $_ + '=' + $cc.tags[$_] }) -join ','); events = (@($cc.events | ForEach-Object { $_.d + ' ' + $_.kind }) -join ','); last = $ci.last.d; daysSince = $ci.daysSince; none = (Get-HealthCalInfo @([pscustomobject]@{ d = '2026-01-02'; health = 84.5 }, [pscustomobject]@{ d = '2026-01-01'; health = 84 }) ([DateTime]'2026-01-05')).last }
        $r.cal.pass = ($r.cal.tags -eq '2026-01-03=step,2026-01-06=spike,2026-01-07=revert' -and $r.cal.events -eq '2026-01-03 step,2026-01-06 spike' -and $r.cal.last -eq '2026-01-06' -and $r.cal.daysSince -eq 14 -and $null -eq $r.cal.none)
        $r.pass = ($r.pass -and $r.cal.pass)
        $script:SelfRec.v4321.pure = $r }
    & $add 'v4.3.21 UI: HEALTH HISTORY starts collapsed (latest % + 30-day change), big health % kept' @() {
        $script:Keep4321 = $script:State.health
        $real = ($null -ne $script:State.health -and $null -ne $script:State.health.healthPct -and @($script:State.health.points).Count -ge 2)
        if (-not $real) {
            $pts = @(0..44 | ForEach-Object { [pscustomobject]@{ d = (Get-Date '2026-08-25').AddDays($_).ToString('yyyy-MM-dd'); range = 275 - $_ * 0.05; cap = [math]::Round(66.6 - $_ * 0.01, 2) } })
            $script:State.health = [pscustomobject]@{ healthPct = 84.1; capacity = 66.28; original = 78.83; degradation = 15.9; maxRange = 274.25; odometer = 54585; at = (ConvertTo-EpochLocal (Get-LocalNow)); points = $pts } }
        $script:SelfRec.v4321.realData = $real
        try { $script:Cfg.PSObject.Properties.Remove('healthHistory') } catch {}
        $def = Get-HHistOpen; $script:HHistAll = $false; $script:HHistSig = ''
        Render-V4319; $ui.HealthBox.BringIntoView(); $window.UpdateLayout()
        $rows = @($script:HHist4320.rows)
        $script:SelfRec.v4321.collapsed = [ordered]@{ defaultOpen = $def; body = [string]$ui.HHistBody.Visibility; hdr = $ui.HHistHdr.Text; sum = (($ui.HHistSum.Inlines | ForEach-Object { $_.Text }) -join ''); bigPct = $ui.HealthPct.Text; bigSize = $ui.HealthPct.FontSize; entries = $rows.Count; latest = $(if ($rows.Count) { $rows[0].d + ' ' + $rows[0].health } else { '' })
            pass = ($def -eq $false -and [string]$ui.HHistBody.Visibility -eq 'Collapsed' -and $ui.HHistHdr.Text -like '*HEALTH HISTORY*' -and (($ui.HHistSum.Inlines | ForEach-Object { $_.Text }) -join '') -match '^\d+\.\d%  ·  30 days ' -and $ui.HealthPct.Text -match '^\d+\.\d%$' -and $ui.HealthPct.FontSize -ge 26 -and $rows.Count -ge 2) }
        $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout()
        $sc = $ui.BodyScroll; $vp = $sc.ViewportHeight; $mg = $ui.MainGrid
        $y = { param($el, $rel) $p = $el.TranslatePoint([System.Windows.Point]::new(0, 0), $rel); [math]::Round($p.Y, 1) }
        $vis = [ordered]@{}
        foreach ($n in 'ChgCard', 'ChgStartBtn', 'ChgStopBtn', 'HHistBtn') { $t = & $y $ui[$n] $mg; $vis[$n] = ($ui[$n].IsVisible -and $t -ge -0.5 -and ($t + $ui[$n].ActualHeight) -le $mg.ActualHeight + 0.5) }
        foreach ($n in 'CtlCard', 'LeaveBtn', 'LockBtn', 'AnnNowBtn', 'CtlResultBox', 'SkipCfRow', 'BattHdr', 'BattPct') { $t = & $y $ui[$n] $sc; $vis[$n] = ($ui[$n].IsVisible -and $t -ge -0.5 -and ($t + $ui[$n].ActualHeight) -le $vp + 0.5) }
        $btnY = & $y $ui.HHistBtn $window; $stopBottom = (& $y $ui.ChgStopBtn $window) + $ui.ChgStopBtn.ActualHeight; $statsBottom = (& $y $ui.ChgStats $window) + $ui.ChgStats.ActualHeight; $ampsY = & $y $ui.AmpsTrack $window
        $script:SelfRec.v4321.place = [ordered]@{ inChgCard = $ui.ChgCard.IsAncestorOf($ui.HHistBtn); inHealthBox = $ui.HealthBox.IsAncestorOf($ui.HHistBtn); hhistY = $btnY; startStopBottom = $stopBottom; statsBottom = $statsBottom; ampsY = $ampsY; visible = $vis; viewport = [math]::Round($vp, 1); chgCardH = [math]::Round($ui.ChgCard.ActualHeight, 1)
            pass = ($ui.ChgCard.IsAncestorOf($ui.HHistBtn) -and -not $ui.HealthBox.IsAncestorOf($ui.HHistBtn) -and $btnY -gt $stopBottom -and $btnY -ge $statsBottom -and $btnY -lt $ampsY -and @($vis.Values | Where-Object { -not $_ }).Count -eq 0) }
        & $script:ElPng4321 $ui.ChgCard 'chg-collapsed'; & $script:ElPng4321 $ui.HealthBox 'battery-health-no-dropdown'
        Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v4321-window-collapsed.png'); Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v4321-window-collapsed-full.png') -Full; $script:SelfRec.shots += @('tessdesk-v4321-window-collapsed.png', 'tessdesk-v4321-window-collapsed-full.png') }
    & $add 'v4.3.21 UI: click opens it (saved), newest first, last 30 + Show all, summary 30 / 90 days / since first' @() {
        $ui.HHistBtn.RaiseEvent((New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left) -Property @{ RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent }))
        $window.UpdateLayout(); $rows = @($script:HHist4320.rows)
        $saved = $null; try { $saved = [bool](Read-Config).healthHistory.open } catch {}
        $first = $ui.HHistList.Children[0]; $firstTxt = @($first.Children | ForEach-Object { $_.Text }) -join ' | '
        $sumTxt = ($ui.HHistSummary.Inlines | ForEach-Object { $_.Text }) -join ''
        $script:SelfRec.v4321.expanded = [ordered]@{ open = Get-HHistOpen; saved = $saved; body = [string]$ui.HHistBody.Visibility; hdr = $ui.HHistHdr.Text; shown = $ui.HHistList.Children.Count; entries = $rows.Count; firstRow = $firstTxt; summary = $sumTxt; allBtn = [string]$ui.HHistAllBtn.Visibility; allTxt = $ui.HHistAllTxt.Text
            newestFirst = ((@($rows | ForEach-Object { $_.d }) -join ',') -eq (@($rows | ForEach-Object { $_.d } | Sort-Object -Descending) -join ','))
            pass = ((Get-HHistOpen) -and $saved -eq $true -and [string]$ui.HHistBody.Visibility -eq 'Visible' -and $ui.HHistList.Children.Count -eq [math]::Min(30, $rows.Count) -and $sumTxt -like '*30 days*' -and $sumTxt -like '*90 days*' -and $sumTxt -like '*since*' -and $firstTxt -like '*%*kWh*' -and
                    ((@($rows | ForEach-Object { $_.d }) -join ',') -eq (@($rows | ForEach-Object { $_.d } | Sort-Object -Descending) -join ',')) -and (($rows.Count -le 30) -or ([string]$ui.HHistAllBtn.Visibility -eq 'Visible' -and $ui.HHistAllTxt.Text -like 'Show all*'))) }
        $calTxt = ($ui.HHistCal.Inlines | ForEach-Object { $_.Text }) -join ''
        $script:SelfRec.v4321.expanded.cal = [ordered]@{ text = $calTxt; note = $ui.HHistCalNote.Text; tip = $ui.HHistTip.Text; events = @(@($script:HHistCal4321.events) | ForEach-Object { '{0} {1} {2}->{3}{4}' -f $_.d, $_.kind, $_.from, $_.to, $(if ($_.back) { ' back ' + $_.back + ' ' + $_.backTo } else { '' }) }); daysSince = $script:HHistCal4321.daysSince
            pass = ($calTxt -like 'Calibration: *' -and $ui.HHistTip.Text -like '*10-20%*90-100%*hour*' -and ($null -eq $script:HHistCal4321.last -or ($calTxt -like '*last detected*days ago*' -and $ui.HHistCalNote.Text -like 'CAL = *'))) }
        $script:SelfRec.v4321.expanded.pass = ($script:SelfRec.v4321.expanded.pass -and $script:SelfRec.v4321.expanded.cal.pass)
        $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout(); & $script:ElPng4321 $ui.ChgCard 'chg-expanded'
        Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v4321-window-expanded.png'); Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v4321-window-expanded-full.png') -Full; $script:SelfRec.shots += @('tessdesk-v4321-window-expanded.png', 'tessdesk-v4321-window-expanded-full.png') }
    & $add 'v4.3.21 UI: Show all / Show last 30, then close (saved) and open state survives a re-read of config.json' @() {
        $n = @($script:HHist4320.rows).Count
        $ui.HHistAllBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $window.UpdateLayout(); $all = $ui.HHistList.Children.Count; $allTxt = $ui.HHistAllTxt.Text
        $tagged = @($ui.HHistList.Children | Where-Object { $_.Children[0].Children.Count -gt 1 }); $calRows = @($tagged | ForEach-Object { $_.Children[0].Children[0].Text })
        if ($tagged.Count -gt 0) { $tagged[-1].BringIntoView(); $window.UpdateLayout(); & $script:ElPng4321 $ui.ChgCard 'chg-cal-tags' }
        $script:SelfRec.v4321.calTags = [ordered]@{ rows = $calRows; count = $tagged.Count; expected = @(@($script:HHist4320.rows) | Where-Object { $_.cal }).Count; pass = ($tagged.Count -eq @(@($script:HHist4320.rows) | Where-Object { $_.cal }).Count) }
        $ui.HHistAllBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $window.UpdateLayout(); $back = $ui.HHistList.Children.Count
        $ui.HHistBtn.RaiseEvent((New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left) -Property @{ RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent })); $window.UpdateLayout()
        $closedSaved = $null; try { $closedSaved = [bool](Read-Config).healthHistory.open } catch {}
        $script:SelfRec.v4321.showAll = [ordered]@{ entries = $n; all = $all; allTxt = $allTxt; back = $back; closedBody = [string]$ui.HHistBody.Visibility; closedSaved = $closedSaved
            pass = ($all -eq $n -and $back -eq [math]::Min(30, $n) -and ($n -le 30 -or $allTxt -eq 'Show last 30') -and [string]$ui.HHistBody.Visibility -eq 'Collapsed' -and $closedSaved -eq $false) }
        $script:State.health = $script:Keep4321; $script:HHistSig = ''; Render-V4319 }
    & $add 'v4.3.21 fresh install (dry run, no box): empty history + a new token -> VIN from /vehicles, seeds from Tessie, logs daily, catches up after days away, offline keeps the last data' @() {
        $tmp = Join-Path $env:TEMP ('td4321-fresh-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $tmp -Force | Out-Null
        $keep = @($script:VIN, $script:State, ${function:Invoke-Tessie}, ${function:Save-ConfigVin})
        $script:HealthSandbox = Join-Path $tmp 'battery-health-history.json'; $script:FreshCalls = New-Object System.Collections.ArrayList; $script:FreshOnline = $true; $script:FreshVinSaved = $null
        $script:FreshNow = Get-EpochNow
        ${function:Invoke-Tessie} = { param([string]$Path, [string]$Token)
            [void]$script:FreshCalls.Add($Token + ' ' + $Path); if (-not $script:FreshOnline) { throw 'offline (self-test)' }
            if ($Path -like '/vehicles*') { return [pscustomobject]@{ results = @([pscustomobject]@{ vin = 'TESTVIN0000FRESH1' }) } }
            if ($Path -like '/battery_health*') { return [pscustomobject]@{ results = @([pscustomobject]@{ vin = 'TESTVIN0000FRESH1'; health_percent = 88.0; capacity = 70.4; original_capacity = 80.0; degradation_percent = 12.0; max_range = 290.0; odometer = 1000 }) } }
            if ($Path -like '/TESTVIN0000FRESH1/battery_health*') { $res = @(); for ($i = 30; $i -ge 1; $i--) { $e = $script:FreshNow - $i * 86400; $cap = 72.0; if ($i -eq 20) { $cap = 75.6 }; if ($i -le 10) { $cap = 70.4 }
                    $res += [pscustomobject]@{ timestamp = (ConvertFrom-Epoch $e).ToString('yyyy-MM-dd') + 'T12:00:00.000Z'; max_range = 290; capacity = $cap; odometer = 1000 } }
                return [pscustomobject]@{ results = $res } }
            throw ('unexpected path ' + $Path) }
        ${function:Save-ConfigVin} = { param($v) $script:FreshVinSaved = $v }
        $r = [ordered]@{}
        try {
            $script:VIN = ''; $script:State = [pscustomobject]@{ health = $null; healthFetchEpoch = 0 }
            $r.emptyAtStart = @(Read-OwnHealth).Count
            $r.vin = Resolve-Vin 'NEW-TEST-TOKEN'; $r.vinSaved = $script:FreshVinSaved
            Update-HealthCache 'NEW-TEST-TOKEN' $script:FreshNow
            $j = Get-Content -LiteralPath $script:HealthSandbox -Raw -Encoding UTF8 | ConvertFrom-Json
            $r.seeded = @($j.points).Count; $r.fileVin = $j.vin; $r.firstSpan = $script:HealthSpan; $r.today = @($j.points)[-1].d + ' ' + @($j.points)[-1].health
            $rows = @(Get-HealthHistory $script:State.health (Read-OwnHealth)); $ci = Get-HealthCalInfo $rows (ConvertFrom-Epoch $script:FreshNow)
            $r.calEvents = @(@($ci.events) | ForEach-Object { $_.kind }); $r.calTags = @(@($rows) | Where-Object { $_.cal } | ForEach-Object { $_.cal })
            Update-HealthCache 'NEW-TEST-TOKEN' ($script:FreshNow + 3600); $r.sameDayNoRefetch = @($script:FreshCalls).Count
            $script:FreshNow += 4 * 86400; Update-HealthCache 'NEW-TEST-TOKEN' $script:FreshNow
            $r.afterAway = @(Read-OwnHealth).Count; $r.secondSpan = $script:HealthSpan
            $script:FreshOnline = $false; $script:FreshNow += 7 * 3600; Update-HealthCache 'NEW-TEST-TOKEN' $script:FreshNow
            $r.offlineEntries = @(Read-OwnHealth).Count; $r.offlineRows = @(Get-HealthHistory $script:State.health (Read-OwnHealth)).Count; $r.offlineHealth = $script:State.health.healthPct
            $r.calls = @($script:FreshCalls); $r.allOwnToken = (@($script:FreshCalls | Where-Object { $_ -notlike 'NEW-TEST-TOKEN /*' }).Count -eq 0)
            $r.historyPath = $script:HealthSandbox; $r.productionPath = $HealthHistPath; $r.apiBase = $ApiBase
            $code = (@('Update-HealthCache', 'Read-OwnHealth', 'Add-OwnHealthPoint', 'Merge-HealthPoints', 'Get-HealthHistory', 'Get-HealthCal', 'Get-HealthCalInfo', 'Render-HealthHist', 'Render-HealthCal', 'Get-HHPath', 'Resolve-Vin') | ForEach-Object { (Get-Item ('function:' + $_)).ScriptBlock.ToString() }) -join "`n"
            $r.hardcoded = @(@('/workspace', '/home/box', 'Grok', 'tdpub', '7SAYGDEE', 'vanwi', 'routine') | Where-Object { $code -like ('*' + $_ + '*') })
        } finally {
            $script:VIN = $keep[0]; $script:State = $keep[1]; ${function:Invoke-Tessie} = $keep[2]; ${function:Save-ConfigVin} = $keep[3]; $script:HealthSandbox = $null
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
        }
        $r.pass = ($r.emptyAtStart -eq 0 -and $r.vin -eq 'TESTVIN0000FRESH1' -and $r.vinSaved -eq 'TESTVIN0000FRESH1' -and $r.seeded -eq 31 -and $r.fileVin -eq 'TESTVIN0000FRESH1' -and $r.firstSpan -eq 3650 -and $r.today -like '* 88' -and
            @($r.calEvents) -contains 'spike' -and @($r.calEvents) -contains 'step' -and $r.sameDayNoRefetch -eq 3 -and $r.afterAway -eq 35 -and $r.secondSpan -eq 400 -and $r.offlineEntries -eq 35 -and $r.offlineRows -eq 35 -and $r.offlineHealth -eq 88 -and
            $r.allOwnToken -and $r.apiBase -like 'https://api.tessie.com*' -and $r.productionPath -eq (Join-Path $scriptDir 'battery-health-history.json') -and @($r.hardcoded).Count -eq 0)
        $script:SelfRec.v4321.fresh = $r }
    # ---- v4.3.22: CHARGE column in HEALTH HISTORY (DRY RUN: nothing is sent to the car, nothing announced) ----
    $script:SelfRec.v4322 = [ordered]@{ appVersion = $AppVersion }
    $script:ChgCells4322 = { $o = @{}; foreach ($g in @($ui.HHistList.Children)) { $d = [string]$g.Children[0].Children[0].Text; $o[$d] = (@($g.Children[3].Children | ForEach-Object { $_.Text }) -join '') }; return $o }
    & $add 'v4.3.22 pure: charge days (highest end %, type H / AC / SC / DC, fast flag, local day, ties go to fast, no charge = dash)' @() {
        $ep = { param($s) [int64](ConvertTo-EpochLocal ([DateTime]::ParseExact($s, 'yyyy-MM-dd HH:mm', $Inv))) }
        $hl = [pscustomobject]@{ lat = 40.0; lon = -100.0; src = 'test' }
        $mk = { param($s, $e, $sb, $eb, $la, $lo, $sc, $fc) [pscustomobject]@{ started_at = (& $ep $s); ended_at = (& $ep $e); starting_battery = $sb; ending_battery = $eb; latitude = $la; longitude = $lo; is_supercharger = $sc; is_fast_charger = $fc } }
        $res = @((& $mk '2026-01-04 21:30' '2026-01-05 05:53' 60 100 40.0 -100.0 $false $false), (& $mk '2026-01-05 08:03' '2026-01-05 08:11' 73 82 41.0 -101.0 $true $true),
            (& $mk '2026-01-06 10:00' '2026-01-06 10:40' 22 95 41.0 -101.0 $true $true), (& $mk '2026-01-07 12:00' '2026-01-07 14:00' 50 70 40.5 -100.5 $false $false),
            (& $mk '2026-01-08 09:00' '2026-01-08 09:30' 10 80 41.2 -101.2 $false $true), (& $mk '2026-01-08 20:00' '2026-01-08 23:30' 70 80 40.0 -100.0 $false $false),
            (& $mk '2026-01-09 22:00' '2026-01-09 23:55' 40 78 40.0001 -100.0001 $false $false), [pscustomobject]@{ started_at = 1; ended_at = $null; ending_battery = 50 })
        $d = ConvertTo-ChargeDays $res $hl
        $r = [ordered]@{ days = (@($d.Keys | Sort-Object | ForEach-Object { $_ + '=' + (Format-ChargeDay $d[$_]) + $(if ($d[$_].fast) { '+fast' } else { '' }) }) -join ', ')
            n5 = $d['2026-01-05'].n; s5 = @($d['2026-01-05'].s); none = (Format-ChargeDay $null); none2 = (Format-ChargeDay $d['2026-01-10']) }
        $hh = Get-ChargeHome @($res[0], $res[5], $res[6], $res[3], $res[1]) $null; $r.homeGuess = $(if ($null -ne $hh) { '{0},{1} {2}' -f $hh.lat, $hh.lon, $hh.src } else { $null })
        $r.pass = ($r.days -eq '2026-01-05=H 100%+fast, 2026-01-06=SC 95%+fast, 2026-01-07=AC 70%, 2026-01-08=DC 80%+fast, 2026-01-09=H 78%' -and $r.n5 -eq 2 -and $r.s5[0] -like '5:53 AM 60-100% H' -and $r.none -eq [string][char]0x2014 -and $r.none2 -eq [string][char]0x2014 -and
            ($null -ne (Get-Cfg4319 'home') -or $r.homeGuess -like '40*,-100* most AC charging'))
        $script:SelfRec.v4322.pure = $r }
    & $add 'v4.3.22 UI: CHARGE column in the expanded HEALTH HISTORY, real Tessie charges (Mar 16 - Oct 8, 2026), CAL tags + summary kept' @() {
        $f = Join-Path $scriptDir 'charges-real-test.json'; $r = [ordered]@{ fixture = (Test-Path -LiteralPath $f) }
        $res = @(); if ($r.fixture) { $res = @(([System.IO.File]::ReadAllText($f) | ConvertFrom-Json).results) }
        $hl = Get-ChargeHome $res $null; $days = ConvertTo-ChargeDays $res $hl
        $script:OwnChargesMock = [pscustomobject]@{ vin = $script:VIN; fetchedAt = (Get-EpochNow); home = $hl; days = @($days.Keys | Sort-Object | ForEach-Object { [pscustomobject]$days[$_] }) }
        $r.charges = $res.Count; $r.chargeDays = $days.Count; $r.home = $(if ($hl) { '{0:N4},{1:N4} ({2})' -f $hl.lat, $hl.lon, $hl.src } else { $null })
        $r.fastDays = @($days.Keys | Sort-Object | Where-Object { $days[$_].fast } | ForEach-Object { $_ + ' ' + (Format-ChargeDay $days[$_]) + ' fast up to ' + $days[$_].fastMax + '%' })
        Save-Cfg4319 'healthHistory' ([ordered]@{ open = $true }); $script:HHistAll = $false; $script:HHistSig = ''; Render-HealthHist; $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout()
        $hdr = @('HHistC0', 'HHistC1', 'HHistC2', 'HHistC4', 'HHistC3' | ForEach-Object { $ui[$_].Text }); $cells30 = & $script:ChgCells4322
        & $script:ElPng4321 $ui.ChgCard 'v4322-chg-expanded'; Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v4322-window-expanded.png'); $script:SelfRec.shots += 'tessdesk-v4322-window-expanded.png'
        $script:HHistAll = $true; $script:HHistSig = ''; Render-HealthHist; $window.UpdateLayout(); $cells = & $script:ChgCells4322
        $want = [ordered]@{ 'Sun Mar 29, 2026' = 'H 100%' + [char]0x26A1; 'Sun Jul 26, 2026' = 'H 86%' + [char]0x26A1; 'Mon Jul 27, 2026' = 'H 80%'; 'Sat Mar 28, 2026' = 'H 80%' }
        $r.check = [ordered]@{}; foreach ($k in $want.Keys) { $r.check[$k] = [string]$cells[$k] }
        $dash = @($cells.Values | Where-Object { $_ -eq [string][char]0x2014 }).Count; $r.rows = $cells.Count; $r.dashRows = $dash; $r.withCharge = $cells.Count - $dash
        $r.header = $hdr -join ' | '; $r.first30 = @($cells30.Keys | Sort-Object -Descending | Select-Object -First 6 | ForEach-Object { $_ + ' ' + $cells30[$_] })
        $r.calTags = @($ui.HHistList.Children | Where-Object { $_.Children[0].Children.Count -gt 1 }).Count; $r.summary = $ui.HHistSummary.Text; $r.calLine = (($ui.HHistCal.Inlines | ForEach-Object { $_.Text }) -join '')
        $tgt = @($ui.HHistList.Children | Where-Object { [string]$_.Children[0].Children[0].Text -eq 'Sun Jul 26, 2026' })
        if ($tgt.Count) { $tgt[0].BringIntoView(); $window.UpdateLayout(); & $script:ElPng4321 $ui.ChgCard 'v4322-chg-jul26' }
        $tgt = @($ui.HHistList.Children | Where-Object { [string]$_.Children[0].Children[0].Text -eq 'Sun Mar 29, 2026' })
        if ($tgt.Count) { $tgt[0].BringIntoView(); $window.UpdateLayout(); & $script:ElPng4321 $ui.ChgCard 'v4322-chg-mar29' }
        $mis = @($want.Keys | Where-Object { $r.check[$_] -ne $want[$_] })
        $r.mismatch = $mis
        # a day without a charge shows a dash (Van charged every day in this range, so drop Oct 8 from a copy of the data just for this check)
        $script:OwnChargesMock = [pscustomobject]@{ vin = $script:VIN; fetchedAt = (Get-EpochNow); days = @($script:OwnChargesMock.days | Where-Object { $_.d -ne '2026-10-08' }) }; $script:HHistAll = $false; $script:HHistSig = ''; Render-HealthHist; $window.UpdateLayout()
        $c2 = & $script:ChgCells4322; $r.noChargeDay = [string]$c2['Thu Oct 8, 2026']
        $r.pass = ($r.fixture -and $r.charges -gt 400 -and $r.header -eq 'DATE | HEALTH | CHANGE | CHARGE | CAPACITY' -and $mis.Count -eq 0 -and $r.noChargeDay -eq [string][char]0x2014 -and $r.withCharge -gt 100 -and $r.calTags -eq 3 -and $r.calLine -like 'Calibration: last detected Jul 26, 2026*' -and $r.summary -like 'Change: 30 days*')
        $script:OwnChargesMock = $null; $script:HHistAll = $false; $script:HHistSig = ''
        $script:SelfRec.v4322.ui = $r }
    & $add 'v4.3.22 fresh install: charge history seeds from Tessie with the new token (10 years), catches up after days away, keeps the last data offline (no box)' @() {
        $tmp = Join-Path $env:TEMP ('td4322-fresh-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $tmp -Force | Out-Null
        $keep = @($script:VIN, ${function:Invoke-Tessie}, $script:ChgHistNext)
        $hc = Get-Cfg4319 'home'; $script:FHome = $(if ($null -ne $hc -and $null -ne $hc.lat) { @([double]$hc.lat, [double]$hc.lon) } else { @(40.0, -100.0) })
        $script:ChargeSandbox = Join-Path $tmp 'charge-history.json'; $script:FreshCalls = New-Object System.Collections.ArrayList; $script:FreshOnline = $true; $script:FreshNow = Get-EpochNow; $script:FreshFail10y = $false
        ${function:Invoke-Tessie} = { param([string]$Path, [string]$Token)
            [void]$script:FreshCalls.Add($Token + ' ' + $Path); if (-not $script:FreshOnline) { throw 'offline (self-test)' }
            if ($Path -notlike '/TESTVIN0000FRESH2/charges*') { throw ('unexpected path ' + $Path) }
            $q = @{}; foreach ($kv in ($Path.Split('?')[1] -split '&')) { $a = $kv.Split('='); $q[$a[0]] = $a[1] }
            if ($script:FreshFail10y -and ([int64]$q['to'] - [int64]$q['from']) -gt 401 * 86400) { throw 'too large (self-test)' }
            $res = @(); for ($i = 40; $i -ge 0; $i--) { $e = $script:FreshNow - $i * 86400 + 3600; if ($e -lt [int64]$q['from'] -or $e -gt [int64]$q['to']) { continue }
                $sc = ($i % 10 -eq 3); $res += [pscustomobject]@{ started_at = $e - 7200; ended_at = $e; starting_battery = 30; ending_battery = $(if ($sc) { 90 } else { 80 }); latitude = $(if ($sc) { 1.0 } else { $script:FHome[0] }); longitude = $(if ($sc) { 1.0 } else { $script:FHome[1] }); is_supercharger = $sc; is_fast_charger = $sc } }
            return [pscustomobject]@{ results = $res } }
        $r = [ordered]@{}
        try {
            $script:VIN = 'TESTVIN0000FRESH2'; $script:ChgHistNext = 0
            $r.emptyAtStart = ($null -eq (Read-OwnCharges))
            Update-ChargeHist 'NEW-TEST-TOKEN' $script:FreshNow
            $j = Get-Content -LiteralPath $script:ChargeSandbox -Raw -Encoding UTF8 | ConvertFrom-Json; $r.seededDays = @($j.days).Count; $r.vin = $j.vin; $r.firstSpan = $script:ChgHistSpan; $r.home = $j.home.src
            $r.labels = @(@($j.days) | Select-Object -Last 4 | ForEach-Object { Format-ChargeDay $_ })
            Update-ChargeHist 'NEW-TEST-TOKEN' ($script:FreshNow + 3600); $r.sameDayCalls = $script:FreshCalls.Count
            $script:ChgHistNext = 0; $script:FreshNow += 3 * 86400; Update-ChargeHist 'NEW-TEST-TOKEN' $script:FreshNow
            $j = Get-Content -LiteralPath $script:ChargeSandbox -Raw -Encoding UTF8 | ConvertFrom-Json; $r.afterAwayDays = @($j.days).Count; $r.catchUpSpan = $script:ChgHistSpan
            $script:FreshOnline = $false; $script:ChgHistNext = 0; $script:FreshNow += 7 * 3600; Update-ChargeHist 'NEW-TEST-TOKEN' $script:FreshNow
            $r.offlineDays = @((Read-OwnCharges).days).Count; $r.offlineRetryMin = [int](($script:ChgHistNext - $script:FreshNow) / 60)
            Remove-Item -LiteralPath $script:ChargeSandbox -Force; $script:FreshOnline = $true; $script:FreshFail10y = $true; $script:ChgHistNext = 0; Update-ChargeHist 'NEW-TEST-TOKEN' $script:FreshNow; $r.fallbackSpan = $script:ChgHistSpan; $r.fallbackDays = @((Read-OwnCharges).days).Count
            $r.calls = @($script:FreshCalls); $r.allOwnToken = (@($script:FreshCalls | Where-Object { $_ -notlike 'NEW-TEST-TOKEN /TESTVIN0000FRESH2/charges?*' }).Count -eq 0)
            $r.productionPath = $ChargeHistPath
            $code = (@('Update-ChargeHist', 'Read-OwnCharges', 'Get-ChargeHome', 'ConvertTo-ChargeDays', 'Get-ChargeDayMap', 'New-HChgCell', 'Get-CHPath') | ForEach-Object { (Get-Item ('function:' + $_)).ScriptBlock.ToString() }) -join "`n"
            $r.hardcoded = @(@('/workspace', '/home/box', 'Grok', 'tdpub', '7SAYGDEE', 'vanwi', 'routine', '36.10', '-96.03') | Where-Object { $code -like ('*' + $_ + '*') })
        } finally {
            $script:VIN = $keep[0]; ${function:Invoke-Tessie} = $keep[1]; $script:ChgHistNext = $keep[2]; $script:ChargeSandbox = $null
            try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {}
        }
        $r.pass = ($r.emptyAtStart -and $r.seededDays -eq 40 -and $r.vin -eq 'TESTVIN0000FRESH2' -and $r.firstSpan -ge 3650 -and $r.sameDayCalls -eq 1 -and $r.afterAwayDays -eq 43 -and $r.catchUpSpan -le 6 -and $r.offlineDays -eq 43 -and $r.offlineRetryMin -eq 30 -and
            $r.fallbackSpan -le 401 -and $r.fallbackDays -eq 40 -and $r.allOwnToken -and $r.productionPath -eq (Join-Path $scriptDir 'charge-history.json') -and @($r.hardcoded).Count -eq 0 -and @($r.labels | Where-Object { $_ -notmatch '^(H 80%|SC 90%)$' }).Count -eq 0)
        $script:SelfRec.v4322.fresh = $r }
    # ---- v4.3.23: CHARGING SCHEDULE (DRY RUN: nothing is sent to the car, nothing announced) ----
    $script:SelfRec.v4323 = [ordered]@{ appVersion = $AppVersion; dryRun = [bool]$CTL_DRYRUN }
    $script:ElPng4323 = { param($el, $n)
        # render the whole window, then cut out the element (a VisualBrush of a nested card draws it squashed)
        Set-TirePulse $false; $window.UpdateLayout(); $root = $ui.RootBorder; $sc = 2.0
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]($root.ActualWidth * $sc)), ([int]($root.ActualHeight * $sc)), (96 * $sc), (96 * $sc), ([System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($root); Set-TirePulse $true
        $pt = $el.TranslatePoint([System.Windows.Point]::new(0, 0), $root)
        $x = [int][math]::Max(0, [math]::Floor($pt.X * $sc)); $y = [int][math]::Max(0, [math]::Floor($pt.Y * $sc))
        $w = [int][math]::Min($bmp.PixelWidth - $x, [math]::Ceiling($el.ActualWidth * $sc)); $h = [int][math]::Min($bmp.PixelHeight - $y, [math]::Ceiling($el.ActualHeight * $sc))
        $cb = New-Object System.Windows.Media.Imaging.CroppedBitmap($bmp, [System.Windows.Int32Rect]::new($x, $y, $w, $h))
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($cb))
        $f = 'tessdesk-v4323-' + $n + '.png'; $fs = [IO.File]::Create((Join-Path $script:SelfDir $f)); try { $enc.Save($fs) } finally { $fs.Close() }; $script:SelfRec.shots += $f }
    $script:Car4323 = { param([string]$Mode, [int]$StartMin, [int]$FinMin, [int]$Limit, [double]$Soc, $OffPeak)
        $d0 = [DateTime]::new(2026, 10, 8)
        [pscustomobject]@{ socPct = $Soc; limitPct = $Limit; limitMin = 50; limitMax = 100; chargingState = 'Stopped'; schedMode = $Mode
            schedStartEpoch = (ConvertTo-EpochLocal $d0.AddMinutes($StartMin)); schedStartMin = $null; departEpoch = (ConvertTo-EpochLocal $d0.AddMinutes($FinMin)); departMin = $null
            offPeak = $OffPeak; offPeakEndMin = $null; precond = $false; schedPending = $true } }
    $script:Q4323 = { param($from) @(@($script:CtlLog) | Select-Object -Skip $from | ForEach-Object { $q = $_.query; $_.cmd + '?' + ((@($q.Keys | Sort-Object) | ForEach-Object { $_ + '=' + $q[$_] }) -join '&') + $(if ($_.dryRun) { ' [dry]' } else { ' [REAL]' }) }) }
    $script:Fit4323 = {
        $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout()
        $sc = $ui.BodyScroll; $vp = $sc.ViewportHeight; $mg = $ui.MainGrid
        $y = { param($el, $rel) $p = $el.TranslatePoint([System.Windows.Point]::new(0, 0), $rel); [math]::Round($p.Y, 1) }
        $vis = [ordered]@{}; $slack = $null
        foreach ($n in 'ChgCard', 'ChgStartBtn', 'ChgStopBtn', 'SchedBox', 'SchedEst', 'HHistBtn') { $t = & $y $ui[$n] $mg; $vis[$n] = ($ui[$n].IsVisible -and $t -ge -0.5 -and ($t + $ui[$n].ActualHeight) -le $mg.ActualHeight + 0.5) }
        foreach ($n in 'CtlCard', 'LeaveBtn', 'LockBtn', 'AnnNowBtn', 'CtlResultBox', 'SkipCfRow', 'BattHdr', 'BattPct') { $t = & $y $ui[$n] $sc; $vis[$n] = ($ui[$n].IsVisible -and $t -ge -0.5 -and ($t + $ui[$n].ActualHeight) -le $vp + 0.5); if ($n -eq 'BattPct') { $slack = [math]::Round($vp - ($t + $ui[$n].ActualHeight), 1) } }
        [ordered]@{ visible = $vis; viewport = [math]::Round($vp, 1); battPctSlack = $slack; chgCardH = [math]::Round($ui.ChgCard.ActualHeight, 1); schedH = [math]::Round($ui.SchedBox.ActualHeight, 1); windowH = $window.Height
            skipCols = $ui.SkipCfGrid.Columns; skipRowH = [math]::Round($ui.SkipCfRow.ActualHeight, 1); skipSched = ($null -ne $ui['SkipCf_schedule']); allVisible = (@($vis.Values | Where-Object { -not $_ }).Count -eq 0) } }
    & $add 'v4.3.23 pure: car schedule read, command steps, home rate from real charges, estimate line' @() {
        $r = [ordered]@{}
        $real = [pscustomobject]@{ socPct = 61; limitPct = 80; limitMin = 50; limitMax = 100; schedMode = 'StartAt'; schedStartEpoch = 1791518400; schedStartMin = $null; departEpoch = 1775066400; departMin = $null; offPeak = $false; offPeakEndMin = $null; precond = $false }
        $C = Get-CarSched $real; $r.realShape = ('{0} start {1} finish {2} limit {3}' -f $C.mode, (Format-SchedMin $C.startMin), (Format-SchedMin $C.finishMin), $C.limit)
        $r.unknown = (Get-CarSched ([pscustomobject]@{ socPct = 50; limitPct = 80 })).known
        $r.fmt = @((Format-SchedMin 0), (Format-SchedMin 1380), (Format-SchedMin 600), (Format-SchedMin 1455), (Format-SchedMin -15)) -join ','
        $st = { param($W, $car) @(Get-SchedSteps $W (Get-CarSched $car) | ForEach-Object { $q = $_.query; $_.cmd + '?' + ((@($q.Keys | Sort-Object) | ForEach-Object { $_ + '=' + $q[$_] }) -join '&') }) -join ' ; ' }
        $carSA = & $script:Car4323 'StartAt' 1380 600 80 50 $false; $carDB = & $script:Car4323 'DepartBy' 1380 600 80 50 $true; $carOff = & $script:Car4323 'Off' 1380 600 80 50 $false
        $W = { param($so, $sm, $fo, $fm, $t) [ordered]@{ startOn = $so; startMin = $sm; finishOn = $fo; finishMin = $fm; target = $t } }
        $r.cases = [ordered]@{
            finishOn = (& $st (& $W $true 1380 $true 600 80) $carSA)
            finishOn90 = (& $st (& $W $true 1380 $true 600 90) $carSA)
            finishOff = (& $st (& $W $true 1380 $false 600 80) $carDB)
            startMove = (& $st (& $W $true 1350 $false 600 80) $carSA)
            same = (& $st (& $W $true 1380 $false 600 80) $carSA)
            allOff = (& $st (& $W $false 1380 $false 600 80) $carOff)
            startOff = (& $st (& $W $false 1380 $false 600 80) $carSA)
            finishMove = (& $st (& $W $true 1380 $true 630 80) $carDB) }
        $exp = [ordered]@{
            finishOn = 'set_scheduled_charging?enable=false&time=1380 ; set_scheduled_departure?departure_time=600&enable=true&end_off_peak_time=600&off_peak_charging_enabled=true&off_peak_charging_weekdays_only=false&preconditioning_enabled=false&preconditioning_weekdays_only=false'
            finishOn90 = 'set_scheduled_charging?enable=false&time=1380 ; set_scheduled_departure?departure_time=600&enable=true&end_off_peak_time=600&off_peak_charging_enabled=true&off_peak_charging_weekdays_only=false&preconditioning_enabled=false&preconditioning_weekdays_only=false ; set_charge_limit?percent=90'
            finishOff = 'set_scheduled_departure?departure_time=600&enable=false ; set_scheduled_charging?enable=true&time=1380'
            startMove = 'set_scheduled_charging?enable=true&time=1350'; same = ''; allOff = ''; startOff = 'set_scheduled_charging?enable=false&time=1380'
            finishMove = 'set_scheduled_departure?departure_time=630&enable=true&end_off_peak_time=630&off_peak_charging_enabled=true&off_peak_charging_weekdays_only=false&preconditioning_enabled=false&preconditioning_weekdays_only=false' }
        $r.caseFails = @($exp.Keys | Where-Object { $r.cases[$_] -ne $exp[$_] })
        $f = Join-Path $scriptDir 'charges-real-test.json'; $res = @(); if (Test-Path -LiteralPath $f) { $res = @(([System.IO.File]::ReadAllText($f) | ConvertFrom-Json).results) }
        $script:Sess4323 = @($res | Where-Object { $null -ne $_.ended_at } | ForEach-Object { [pscustomobject]@{ startEpoch = [int64]$_.started_at; endEpoch = [int64]$_.ended_at; kwhAdded = $_.energy_added; socStartPct = $_.starting_battery; socEndPct = $_.ending_battery; fast = ([bool]$_.is_supercharger -or [bool]$_.is_fast_charger) } })
        $rate = Get-HomeChargeRate $script:Sess4323; $r.rate = [ordered]@{ kw = [math]::Round([double]$rate.kw, 2); kwhPerPct = [math]::Round([double]$rate.kwhPerPct, 3); n = $rate.n; nPct = $rate.nPct; charges = $res.Count }
        $C50 = Get-CarSched $carSA
        $e1 = Get-SchedEstimate (& $W $true 1380 $true 600 80) $C50 $rate; $e2 = Get-SchedEstimate (& $W $true 1380 $false 600 80) $C50 $rate
        $e3 = Get-SchedEstimate (& $W $true 1380 $true 600 80) $C50 ([ordered]@{ kw = $null; kwhPerPct = $null }); $e4 = Get-SchedEstimate (& $W $true 1380 $true 600 80) (Get-CarSched (& $script:Car4323 'StartAt' 1380 600 80 85 $false)) $rate
        $e5 = Get-SchedEstimate (& $W $false 1380 $false 600 80) $C50 $rate
        $r.est = [ordered]@{ finish = $e1.text; kwh = $e1.kwh; hours = [math]::Round([double]$e1.hours, 2); start = $e2.text; noRate = $e3.text; full = $e4.text; none = $e5.text }
        $r.pass = ($r.realShape -eq 'StartAt start 11:00 PM finish 1:00 PM limit 80' -and $r.unknown -eq $false -and $r.fmt -eq '12:00 AM,11:00 PM,10:00 AM,12:15 AM,11:45 PM' -and $r.caseFails.Count -eq 0 -and
            $r.rate.kw -gt 2 -and $r.rate.kw -lt 5 -and $r.rate.kwhPerPct -gt 0.5 -and $r.rate.kwhPerPct -lt 0.9 -and $e1.text -match '^Finishes ~10:00 AM at 80% \(est\. start \d{1,2}:\d\d AM\)$' -and
            $e2.text -match '^Starts 11:00 PM nightly · ~\d+\.\d h to 80% \(done ~\d{1,2}:\d\d AM\)$' -and $e3.text -eq 'Finishes by 10:00 AM at 80%' -and $e4.text -like 'Finishes by 10:00 AM · already at 85%*' -and $e5.text -like 'No schedule*')
        $script:SelfRec.v4323.pure = $r }
    & $add 'v4.3.23 UI: schedule row in START / STOP shows what the car has (START AT 11:00 PM), estimate, Synced; no-scroll fit kept' @() {
        $script:SchedCarMock = & $script:Car4323 'StartAt' 1380 600 80 50 $false; $script:SchedSessMock = $script:Sess4323
        $script:Sched.status = 'idle'; $script:Sched.want = $null; $script:Sched.applied = $null; $script:Sched.dirty = $false
        Set-SkipConfirm 'schedule' $false $false
        Save-Cfg4319 'healthHistory' ([ordered]@{ open = $false }); $script:HHistAll = $false; $script:HHistSig = ''; Render-HealthHist
        Render-View; Render-Sched $true; $window.UpdateLayout()
        $r = [ordered]@{ startChk = [bool]$ui.SchedStartChk.IsChecked; finishChk = [bool]$ui.SchedFinishChk.IsChecked; start = $ui.SchedStartVal.Text; finish = $ui.SchedFinishVal.Text; target = $ui.SchedTgtVal.Text; est = $ui.SchedEst.Text; sync = $ui.SchedSync.Text
            inChgCard = $ui.ChgCard.IsAncestorOf($ui.SchedBox); skipKeys = ($SkipCfKeys -join ','); skipLabel = $(if ($null -ne $ui['SkipCf_schedule']) { $ui.SkipCf_schedule.Content.Text } else { '' }) }
        $r.fit = & $script:Fit4323
        & $script:ElPng4323 $ui.ChgCard 'chg-schedule-startat'; Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v4323-window.png'); $script:SelfRec.shots += 'tessdesk-v4323-window.png'
        & $script:ElPng4323 $ui.SkipCfRow 'skip-confirm-row'
        $r.pass = ($r.startChk -and -not $r.finishChk -and $r.start -eq '11:00 PM' -and $r.finish -eq '10:00 AM' -and $r.target -eq '80%' -and $r.est -like 'Starts 11:00 PM nightly*' -and $r.sync -eq 'Synced' -and $r.inChgCard -and $r.skipKeys -like '*,schedule' -and $r.skipLabel -eq 'Sched' -and $r.fit.allVisible)
        $script:SelfRec.v4323.ui = $r }
    & $add 'v4.3.23 FINISH BY on + target 90% (debounced, confirm Yes) -> START AT off, departure with off-peak, limit 90 (dry run)' @($true) {
        $r = [ordered]@{ syncsBefore = $script:Sched.syncs }; $script:From4323 = @($script:CtlLog).Count; $script:P4323 = @($script:ConfirmPrompts).Count
        $ui.SchedFinishChk.IsChecked = $true; $ui.SchedFinishChk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        foreach ($i in 1, 2) { $ui.SchedTgtUp.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $r.pendingText = $ui.SchedSync.Text; $r.timerOn = $script:SchedTimer.IsEnabled; $r.syncsWhilePending = $script:Sched.syncs; $r.shownTarget = $ui.SchedTgtVal.Text
        & $script:ElPng4323 $ui.ChgCard 'chg-schedule-pending'
        $script:SchedTimer.Stop(); Invoke-SchedSync
        $r.syncingText = $ui.SchedSync.Text; $r.prompt = (@($script:ConfirmPrompts) | Select-Object -Skip $script:P4323) -join ' | '
        $script:SelfRec.v4323.finishOn = $r }
    & $add 'v4.3.23 FINISH BY result' @() {
        $r = $script:SelfRec.v4323.finishOn; $r.commands = @(& $script:Q4323 $script:From4323); $r.syncText = $ui.SchedSync.Text; $r.est = $ui.SchedEst.Text; $r.finishChk = [bool]$ui.SchedFinishChk.IsChecked; $r.target = $ui.SchedTgtVal.Text
        $r.startDimmed = ([string]$ui.SchedStartVal.Foreground -eq [string](T 'Caption'))
        & $script:ElPng4323 $ui.ChgCard 'chg-schedule-finishby'
        $exp = @('set_scheduled_charging?enable=false&time=1380 [dry]', 'set_scheduled_departure?departure_time=600&enable=true&end_off_peak_time=600&off_peak_charging_enabled=true&off_peak_charging_weekdays_only=false&preconditioning_enabled=false&preconditioning_weekdays_only=false [dry]', 'set_charge_limit?percent=90 [dry]')
        $r.pass = ($r.pendingText -eq 'Change pending…' -and $r.timerOn -and $r.syncsWhilePending -eq $r.syncsBefore -and $r.shownTarget -eq '90%' -and $r.prompt -match '(?s)^Update the car.s charging schedule\?.*FINISH BY 10:00 AM at 90%' -and
            ($r.commands -join '|') -eq ($exp -join '|') -and $r.syncText -eq 'Synced (dry run)' -and $r.finishChk -and $r.target -eq '90%' -and $r.est -match '^Finishes ~10:00 AM at 90% \(est\. start ' -and $r.startDimmed)
        # the car now reports FINISH BY (as Tessie's cached state would after the commands)
        $script:SchedCarMock = & $script:Car4323 'DepartBy' 1380 600 90 50 $true }
    & $add 'v4.3.23 FINISH BY off (Schedule skip-confirm checked: no pop-up) -> departure off, START AT 11:00 PM re-applied (dry run)' @() {
        $r = [ordered]@{ shownBefore = $ui.SchedSync.Text }; $script:From4323 = @($script:CtlLog).Count; $script:P4323 = @($script:ConfirmPrompts).Count
        $ui.SkipCf_schedule.IsChecked = $true; $ui.SkipCf_schedule.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $r.skipOn = [bool]$script:SkipCf['schedule']
        $ui.SchedFinishChk.IsChecked = $false; $ui.SchedFinishChk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $script:SchedTimer.Stop(); Invoke-SchedSync
        $script:SelfRec.v4323.finishOff = $r }
    & $add 'v4.3.23 FINISH BY off result' @() {
        $r = $script:SelfRec.v4323.finishOff; $r.commands = @(& $script:Q4323 $script:From4323); $r.prompts = @(@($script:ConfirmPrompts) | Select-Object -Skip $script:P4323).Count; $r.sync = $ui.SchedSync.Text; $r.startChk = [bool]$ui.SchedStartChk.IsChecked; $r.start = $ui.SchedStartVal.Text
        $r.pass = ($r.skipOn -and $r.prompts -eq 0 -and ($r.commands -join '|') -eq 'set_scheduled_departure?departure_time=600&enable=false [dry]|set_scheduled_charging?enable=true&time=1380 [dry]' -and $r.sync -eq 'Synced (dry run)' -and $r.startChk -and $r.start -eq '11:00 PM')
        $script:SchedCarMock = & $script:Car4323 'StartAt' 1380 600 90 50 $false }
    & $add 'v4.3.23 debounce: 5 quick START AT +15 min clicks -> one sync, one command (12:15 AM, dry run)' @() {
        $r = [ordered]@{ syncsBefore = $script:Sched.syncs }; $script:From4323 = @($script:CtlLog).Count
        foreach ($i in 1..5) { $ui.SchedStartUp.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $r.shown = $ui.SchedStartVal.Text; $r.syncsAfterClicks = $script:Sched.syncs; $r.timerOn = $script:SchedTimer.IsEnabled
        $script:SchedTimer.Stop(); Invoke-SchedSync
        $script:SelfRec.v4323.debounce = $r }
    & $add 'v4.3.23 debounce result' @() {
        $r = $script:SelfRec.v4323.debounce; $r.commands = @(& $script:Q4323 $script:From4323); $r.syncs = $script:Sched.syncs - $r.syncsBefore
        $r.pass = ($r.shown -eq '12:15 AM' -and $r.syncsAfterClicks -eq $r.syncsBefore -and $r.timerOn -and $r.syncs -eq 1 -and ($r.commands -join '|') -eq 'set_scheduled_charging?enable=true&time=15 [dry]')
        $script:SchedCarMock = & $script:Car4323 'StartAt' 15 600 90 50 $false
        Set-SkipConfirm 'schedule' $false $false }
    & $add 'v4.3.23 confirm No -> nothing sent, controls back to the car; failure shows Failed + reason' @($false, $true) {
        $r = [ordered]@{}; $from = @($script:CtlLog).Count
        $ui.SchedStartDn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $script:SchedTimer.Stop(); Invoke-SchedSync
        $r.cancel = [ordered]@{ sync = $ui.SchedSync.Text; start = $ui.SchedStartVal.Text; sent = @($script:CtlLog).Count - $from; busy = $script:CtlBusy }
        $keep = $script:CmdAllowed; $script:CmdAllowed = $false
        try { $script:Sched.want = [ordered]@{ startOn = $true; startMin = 1380; finishOn = $false; finishMin = 600; target = 90 }; $script:Sched.dirty = $true; Invoke-SchedSync; $r.fail = [ordered]@{ sync = $ui.SchedSync.Text; sent = @($script:CtlLog).Count - $from; busy = $script:CtlBusy } }
        finally { $script:CmdAllowed = $keep }
        Render-Sched $true; & $script:ElPng4323 $ui.ChgCard 'chg-schedule-failed'
        $r.pass = ($r.cancel.sync -eq 'Not sent (cancelled)' -and $r.cancel.start -eq '12:15 AM' -and $r.cancel.sent -eq 0 -and $r.fail.sync -like 'Failed: Commands are off*' -and $r.fail.sent -eq 0 -and -not $r.fail.busy)
        $script:SelfRec.v4323.cancelFail = $r
        $script:SchedCarMock = $null; $script:SchedSessMock = $null; $script:SchedSeenStart = $null; $script:Sched.status = 'idle'; $script:Sched.reason = ''; $script:Sched.applied = $null; $script:Sched.want = $null; $script:Sched.dirty = $false; Render-Sched $true }
    & $add 'v4.3.23 real cached state: schedule as Tessie reports it (read only, nothing sent)' @() {
        $car = Get-CtlCar; $C = Get-CarSched $car
        $r = [ordered]@{ haveCar = ($null -ne $car); car = (Get-CarSchedText $C); controls = ('START AT ' + $(if ([bool]$ui.SchedStartChk.IsChecked) { 'on ' } else { 'off ' }) + $ui.SchedStartVal.Text + ' · FINISH BY ' + $(if ([bool]$ui.SchedFinishChk.IsChecked) { 'on ' } else { 'off ' }) + $ui.SchedFinishVal.Text + ' ' + $ui.SchedTgtVal.Text); est = $ui.SchedEst.Text; sync = $ui.SchedSync.Text }
        $r.netCommandsSent = $script:NetCommandsSent; $r.announcementsSent = $script:AnnSent
        & $script:ElPng4323 $ui.ChgCard 'chg-schedule-real'
        $r.cfgSaved = (Get-Cfg4319 'chargeSchedule'); $r.pass = ($r.netCommandsSent -eq 0 -and $r.announcementsSent -eq 0 -and $null -ne $r.cfgSaved -and [int]$r.cfgSaved.startMin -eq 15)
        $script:SelfRec.v4323.real = $r }
    & $add 'v4.3.21 smoke: versions, footer, hook line, width, all cards render, no real commands' @() {
        $me = [System.IO.File]::ReadAllText((Join-Path $scriptDir 'TessDesk.ps1')); $L = $me -split "`r?`n"
        $hook = @($L | Where-Object { $_ -like "try { . 'C:\Users\vanwi\cb_compact_addon.ps1'; Enable-CbCompactMode -Window `$window -Name 'TESSDESK'*" }).Count
        $i = [array]::IndexOf($L, ('[void]$window.' + 'ShowDialog()')); $before = ($i -gt 0 -and $L[$i - 1] -like "try { . 'C:\Users\vanwi\cb_compact_addon.ps1'*")
        $err = $null; try { Render-View } catch { $err = $_.Exception.Message }
        $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout(); Save-RootPng (Join-Path $script:SelfDir 'tessdesk-v4321-top.png'); $script:SelfRec.shots += 'tessdesk-v4321-top.png'
        $real = @($script:CtlLog | Where-Object { $_.dry -eq $false -or $_.real -eq $true }).Count
        $r = $script:SelfRec.v4321
        $r.smoke = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text; brand = $ui.FooterText.Text; bold = [string]$ui.FooterText.FontWeight; hookLines = $hook; hookBeforeShowDialog = $before; width = $window.Width; renderError = $err; dryRun = $CTL_DRYRUN; realCmdLog = $real
            pass = ($AppVersion -eq '4.3.23' -and $ui.FooterVersion.Text -like ('*4.3.23*' + $AppDate) -and [string]$ui.FooterText.FontWeight -eq 'Bold' -and $hook -eq 1 -and $before -and $null -eq $err -and $CTL_DRYRUN -and [math]::Abs($window.Width - $winW) -lt 1) }
        $fails = @(); foreach ($k in 'pure', 'collapsed', 'place', 'expanded', 'calTags', 'showAll', 'fresh', 'smoke') { if ($null -eq $r[$k] -or -not $r[$k].pass) { $fails += $k } }
        $r.summary = [ordered]@{ fails = $fails; allPass = ($fails.Count -eq 0) } }
    & $add 'v4.3.22 summary' @() {
        $r = $script:SelfRec.v4322; $r.smoke = $script:SelfRec.v4321.smoke; $fails = @()
        foreach ($k in 'pure', 'ui', 'fresh', 'smoke') { if ($null -eq $r[$k] -or -not $r[$k].pass) { $fails += $k } }
        $r.v4321Steps = $script:SelfRec.v4321.summary
        $r.summary = [ordered]@{ fails = $fails; allPass = ($fails.Count -eq 0 -and $script:SelfRec.v4321.summary.allPass) } }
    & $add 'v4.3.23 summary' @() {
        $r = $script:SelfRec.v4323; $r.smoke = $script:SelfRec.v4321.smoke; $fails = @()
        foreach ($k in 'pure', 'ui', 'finishOn', 'finishOff', 'debounce', 'cancelFail', 'real', 'smoke') { if ($null -eq $r[$k] -or -not $r[$k].pass) { $fails += $k } }
        $r.netCommandsSent = $script:NetCommandsSent; $r.announcementsSent = $script:AnnSent
        $r.v4322Steps = $script:SelfRec.v4322.summary; $r.v4321Steps = $script:SelfRec.v4321.summary
        $r.summary = [ordered]@{ fails = $fails; allPass = ($fails.Count -eq 0 -and $script:NetCommandsSent -eq 0 -and $script:AnnSent -eq 0) } }
    if ($Quick4323) { return (Start-SelfTimer) }
    # v4.3.17: record the dropdown's start state, then open it (not saved) so the older steps can snapshot the history rows
    $script:SelfRec.v4317pre = [ordered]@{ open = [bool]$script:ChgHist.open; body = [string]$ui.ChgHistBody.Visibility; arrow = $ui.ChgHistArrow.Text; savedSetting = $(try { [string](Read-Config).ui.historyOpen } catch { '' }) }; Set-ChgHistOpen $true $false
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
    & $add 'v4.3.19 test order: let the launch update check finish before the local-feed update test' @() { & $script:Wait4315 { $null -eq $script:UpdJob } }
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
    # ---- v4.3.12: Restore / Remember at the top right, fade in / out like Paycheck Live ----
    $script:Shot4312 = { param($n) $f = 'tessdesk-v4312-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
    $script:DwRect = { param($el) try { $p = $el.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.RootBorder); return [ordered]@{ x = [math]::Round($p.X, 1); y = [math]::Round($p.Y, 1); w = [math]::Round($el.ActualWidth, 1); h = [math]::Round($el.ActualHeight, 1) } } catch { return $null } }
    $script:DwOverlap = { param($a, $b) if ($null -eq $a -or $null -eq $b -or $a.w -le 0 -or $b.w -le 0) { return $false }; return (($a.x -lt $b.x + $b.w) -and ($b.x -lt $a.x + $a.w) -and ($a.y -lt $b.y + $b.h) -and ($b.y -lt $a.y + $a.h)) }
    $script:DwMouse = { $ev = New-Object System.Windows.Input.MouseEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0) -Property @{ RoutedEvent = [System.Windows.UIElement]::PreviewMouseMoveEvent }; $ui.MainGrid.RaiseEvent($ev) }
    & $add 'v4.3.12 Restore / Remember: top right (Paycheck Live spot), hidden until the mouse moves; footer keeps SHARE only' @() {
        $script:SelfRec.v4312 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text }
        $r = $script:SelfRec.v4312
        $r.row = [ordered]@{ parent = [string]$ui.DwRow.Parent.Name; margin = [string]$ui.DwRow.Margin; hAlign = [string]$ui.DwRow.HorizontalAlignment; vAlign = [string]$ui.DwRow.VerticalAlignment; zIndex = [System.Windows.Controls.Panel]::GetZIndex($ui.DwRow)
            order = @($ui.DwRow.Children | ForEach-Object { [string]$_.Name }); opacityAtStart = $ui.DwRow.Opacity; hitTestAtStart = $ui.DwRow.IsHitTestVisible; hideMs = $script:DwHide.Interval.TotalMilliseconds }
        $r.footerButtons = @($ui.ShareBtn.Parent.Children | ForEach-Object { [string]$_.Name })
        $r.restoreStyle = [ordered]@{ bg = [string]$ui.RestoreBtn.Background; corner = [string]$ui.RestoreBtn.CornerRadius; padding = [string]$ui.RestoreBtn.Padding; height = $ui.RestoreBtn.Height; font = [string]$ui.RestoreTxt.FontFamily; size = $ui.RestoreTxt.FontSize; weight = [string]$ui.RestoreTxt.FontWeight; fg = [string]$ui.RestoreTxt.Foreground; text = $ui.RestoreTxt.Text }
        $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout(); & $script:Shot4312 'hidden'
        & $script:DwMouse
        $r.afterMouseMove = [ordered]@{ hitTest = $ui.DwRow.IsHitTestVisible; hideTimerRunning = $script:DwHide.IsEnabled }
    }
    & $add 'v4.3.12 shown: 0.95 opacity, nothing overlaps the date or the Updated status' @() {
        $r = $script:SelfRec.v4312; $window.UpdateLayout()
        $row = & $script:DwRect $ui.DwRow; $dt = & $script:DwRect $ui.DateLabel; $st = & $script:DwRect $ui.StatusLine
        $ft = New-Object System.Windows.Media.FormattedText($ui.DateLabel.Text, [Globalization.CultureInfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, (New-Object System.Windows.Media.Typeface($ui.DateLabel.FontFamily, $ui.DateLabel.FontStyle, $ui.DateLabel.FontWeight, $ui.DateLabel.FontStretch)), $ui.DateLabel.FontSize, [System.Windows.Media.Brushes]::White, 1.0)
        $dtText = [ordered]@{ x = $dt.x; y = $dt.y; w = [math]::Round([math]::Min($ft.WidthIncludingTrailingWhitespace, $dt.w), 1); h = $dt.h }
        $r.shown = [ordered]@{ opacity = [math]::Round($ui.DwRow.Opacity, 2); hitTest = $ui.DwRow.IsHitTestVisible; rowRect = $row; dateRect = $dt; dateText = $ui.DateLabel.Text; dateTextFull = ($ft.WidthIncludingTrailingWhitespace -le $dt.w + 0.5); statusRect = $st
            status = ($ui.LiveBadge.Text + ' ' + $ui.UpdBadge.Text).Trim(); overlapsDate = (& $script:DwOverlap $row $dtText); overlapsStatus = (& $script:DwOverlap $row $st); statusBelowRow = ($st.y -ge $row.y + $row.h) }
        & $script:Shot4312 'shown'
        $script:DwShownAt = [DateTime]::UtcNow
    }
    foreach ($k in 1..6) { & $add 'v4.3.12 (mouse still: waiting for the 2.2 s hide)' @() { } }
    & $add 'v4.3.12 hidden again 2.2 s after the mouse stopped' @() {
        $r = $script:SelfRec.v4312
        $r.hiddenAgain = [ordered]@{ afterMs = [int]([DateTime]::UtcNow - $script:DwShownAt).TotalMilliseconds; opacity = [math]::Round($ui.DwRow.Opacity, 2); hitTest = $ui.DwRow.IsHitTestVisible; timerRunning = $script:DwHide.IsEnabled }
    }
    & $add 'v4.3.12 kept hidden while a pop-up is open' @() {
        $r = $script:SelfRec.v4312
        $ui.ShareOverlay.Visibility = 'Visible'; & $script:DwMouse; $r.blockedByPopup = [ordered]@{ hitTest = $ui.DwRow.IsHitTestVisible }
        $ui.ShareOverlay.Visibility = 'Collapsed'; & $script:DwMouse; $r.afterPopupClosed = [ordered]@{ hitTest = $ui.DwRow.IsHitTestVisible }
    }
    & $add 'v4.3.12 Remember from the top-right row (test copy of the layout file)' @() {
        $r = $script:SelfRec.v4312
        Invoke-KeepSpot; $window.UpdateLayout()
        $r.remember = [ordered]@{ label = $ui.KeepTxt.Text; rowShown = $ui.DwRow.IsHitTestVisible; realFileUntouched = ((Get-DeskLayoutPath) -ne $DeskLayoutPath); tip = [string]$ui.KeepBtn.ToolTip }
    }
    & $add 'v4.3.12 (wait for the label)' @() { & $script:Shot4312 'saved' }
    # ---- v4.3.13: rolling 7 days (left) / 30 days (right) $ beside the big amount ----
    $script:Shot4313 = { param($n) $f = 'tessdesk-v4313-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
    $script:RollRect = { param($el) try { $p = $el.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.RootBorder); return [ordered]@{ x = [math]::Round($p.X, 1); y = [math]::Round($p.Y, 1); w = [math]::Round($el.ActualWidth, 1); h = [math]::Round($el.ActualHeight, 1) } } catch { return $null } }
    $script:RollBaseY = { param($tb) $ft = Get-TbWidth $tb $tb.Text $tb.FontSize; $p = $tb.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.RootBorder); return [math]::Round($p.Y + $ft.Baseline, 2) }
    $script:RollCheck = {
        $window.UpdateLayout()
        $row = & $script:RollRect $ui.HeroRow; $h = & $script:RollRect $ui.HeroCost; $l = & $script:RollRect $ui.Roll7Cost; $r = & $script:RollRect $ui.Roll30Cost
        $lc = & $script:RollRect $ui.HeroL; $rc = & $script:RollRect $ui.HeroR; $dl = & $script:RollRect $ui.HeroDivL; $dr = & $script:RollRect $ui.HeroDivR
        $root = & $script:RollRect $ui.RootBorder
        $hcx = $h.x + $h.w / 2; $rcx = $row.x + $row.w / 2
        $lw = (Get-TbWidth $ui.Roll7Cost $ui.Roll7Cost.Text $ui.Roll7Cost.FontSize).WidthIncludingTrailingWhitespace
        $rw = (Get-TbWidth $ui.Roll30Cost $ui.Roll30Cost.Text $ui.Roll30Cost.FontSize).WidthIncludingTrailingWhitespace
        $bH = & $script:RollBaseY $ui.HeroCost; $bL = & $script:RollBaseY $ui.Roll7Cost; $bR = & $script:RollBaseY $ui.Roll30Cost
        $sideText = ((@($ui.Roll7.Children) + @($ui.Roll30.Children)) | ForEach-Object { [string]$_.Text }) -join ' | '
        return [ordered]@{
            hero = $ui.HeroCost.Text; left = $ui.Roll7Cost.Text; right = $ui.Roll30Cost.Text; leftCap = ($ui.Roll7Cap.Text -replace [string][char]0x2009, ''); rightCap = ($ui.Roll30Cap.Text -replace [string][char]0x2009, '')
            rowsD7 = $ui.D7Cost.Text; rowsD30 = $ui.D30Cost.Text; matchRows = (($ui.Roll7Cost.Text -eq $ui.D7Cost.Text) -and ($ui.Roll30Cost.Text -eq $ui.D30Cost.Text))
            sizes = [ordered]@{ hero = $ui.HeroCost.FontSize; side = $ui.Roll7Cost.FontSize; sideSame = ($ui.Roll7Cost.FontSize -eq $ui.Roll30Cost.FontSize) }
            heroCentered = ([math]::Abs($hcx - $rcx) -le 0.6); heroCenterOff = [math]::Round($hcx - $rcx, 2)
            symmetric = [ordered]@{ leftGap = [math]::Round($h.x - ($dl.x + $dl.w), 1); rightGap = [math]::Round($dr.x - ($h.x + $h.w), 1); leftCenterDist = [math]::Round($hcx - ($l.x + $l.w / 2), 1); rightCenterDist = [math]::Round(($r.x + $r.w / 2) - $hcx, 1) }
            baselines = [ordered]@{ hero = $bH; left = $bL; right = $bR; aligned = (([math]::Abs($bH - $bL) -le 0.75) -and ([math]::Abs($bH - $bR) -le 0.75)) }
            noClip = [ordered]@{ leftFits = ($lw -le $lc.w - $dl.w - 16 + 0.5); rightFits = ($rw -le $rc.w - $dr.w - 16 + 0.5); leftInside = ($l.x -ge $root.x); rightInside = ($r.x + $r.w -le $root.x + $root.w); rowW = $row.w; windowW = $window.ActualWidth }
            moneyOnly = ($sideText -notmatch 'kWh|night|charge|%|/') ; sideText = ($sideText -replace [string][char]0x2009, '')
        }
    }
    & $add 'v4.3.13 rolling 7 days (left) / 30 days (right) beside the big amount: same numbers as the rows' @() {
        $script:SelfRec.v4313 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text }
        $r = $script:SelfRec.v4313
        Render-View; $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout()
        $nowE = Get-EpochNow
        $r.direct = [ordered]@{ d7 = $(try { (Get-PeriodTotal $script:State $nowE 7).costUsdAllIn } catch { $null }); d30 = $(try { (Get-PeriodTotal $script:State $nowE 30).costUsdAllIn } catch { $null }) }
        $r.real = (& $script:RollCheck)
        $r.real.matchDirect = (($r.real.left -eq (Format-Money $r.direct.d7)) -and ($r.real.right -eq (Format-Money $r.direct.d30)))
        $updVis = $ui.UpdateBtn.Visibility; $ui.UpdateBtn.Visibility = 'Collapsed'; $window.UpdateLayout()   # earlier update-test banner hidden for the picture only
        $r.realNoBanner = (& $script:RollCheck)
        & $script:Shot4313 'top'
        $ui.UpdateBtn.Visibility = $updVis; $window.UpdateLayout()
    }
    & $add 'v4.3.13 big figures still fit (wide-value check, display only)' @() {
        $r = $script:SelfRec.v4313
        $keep = @($ui.HeroCost.Text, $ui.Roll7Cost.Text, $ui.Roll30Cost.Text)
        $ui.HeroCost.Text = '$18.88'; $ui.Roll7Cost.Text = '$64.50'; $ui.Roll30Cost.Text = '$212.40'; Set-HeroRollFit
        $updVis = $ui.UpdateBtn.Visibility; $ui.UpdateBtn.Visibility = 'Collapsed'
        $r.wide = (& $script:RollCheck)
        & $script:Shot4313 'wide'
        $ui.UpdateBtn.Visibility = $updVis
        $ui.HeroCost.Text = $keep[0]; $ui.Roll7Cost.Text = $keep[1]; $ui.Roll30Cost.Text = $keep[2]; Render-View; $window.UpdateLayout()
        $r.restored = [ordered]@{ hero = $ui.HeroCost.Text; left = $ui.Roll7Cost.Text; right = $ui.Roll30Cost.Text; side = $ui.Roll7Cost.FontSize }
    }
    & $add 'v4.3.13 refresh: new data updates the rolling amounts with the rows' @() {
        $r = $script:SelfRec.v4313
        $before = @($ui.Roll7Cost.Text, $ui.Roll30Cost.Text)
        Render-View; $window.UpdateLayout()
        $r.afterRender = [ordered]@{ left = $ui.Roll7Cost.Text; right = $ui.Roll30Cost.Text; same = (($before[0] -eq $ui.Roll7Cost.Text) -and ($before[1] -eq $ui.Roll30Cost.Text)); matchRows = (($ui.Roll7Cost.Text -eq $ui.D7Cost.Text) -and ($ui.Roll30Cost.Text -eq $ui.D30Cost.Text)) }
    }
    # ---- v4.3.14: rolling 7 / 14 days (left) and 30 / 60 days (right) $ beside the big amount ----
    $script:Shot4314 = { param($n) $f = 'tessdesk-v4314-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
    $script:R14Rect = { param($el) $p = $el.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.RootBorder); return [ordered]@{ x = [math]::Round($p.X, 1); y = [math]::Round($p.Y, 1); w = [math]::Round($el.ActualWidth, 1); h = [math]::Round($el.ActualHeight, 1) } }
    $script:R14Base = { param($tb) $ft = Get-TbWidth $tb $tb.Text $tb.FontSize; $p = $tb.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.RootBorder); return ($p.Y + $ft.Baseline) }
    $script:R14Check = {
        $window.UpdateLayout()
        $root = & $script:R14Rect $ui.RootBorder; $row = & $script:R14Rect $ui.HeroRow; $h = & $script:R14Rect $ui.HeroCost
        $hcx = $h.x + $h.w / 2; $rcx = $row.x + $row.w / 2
        $heroMid = (& $script:R14Base $ui.HeroCost) - (Get-TbCapH $ui.HeroCost $ui.HeroCost.FontSize) / 2
        $it = [ordered]@{}
        foreach ($n in '7', '14', '30', '60') {
            $c = $ui['Roll' + $n + 'Cost']; $cp = $ui['Roll' + $n + 'Cap']; $rc = & $script:R14Rect $c
            $tw = (Get-TbWidth $c $c.Text $c.FontSize).WidthIncludingTrailingWhitespace
            # fits: the TextBlock got all the width it asked for (WPF Display text mode measures narrower than ideal FormattedText) and sits inside its side column
            $hl = & $script:R14Rect $ui.HeroL; $hr = & $script:R14Rect $ui.HeroR; $dvl = & $script:R14Rect $ui.HeroDivL; $dvr = & $script:R14Rect $ui.HeroDivR
            $col = $(if ($n -eq '7' -or $n -eq '14') { [ordered]@{ x = $hl.x; w = $dvl.x - $hl.x } } else { [ordered]@{ x = $dvr.x + $dvr.w; w = ($hr.x + $hr.w) - ($dvr.x + $dvr.w) } })
            $it['d' + $n] = [ordered]@{ text = $c.Text; cap = ($cp.Text -replace [string][char]0x2009, ''); size = $c.FontSize; cx = [math]::Round($rc.x + $rc.w / 2, 1); y = $rc.y; textW = [math]::Round($tw, 1); boxW = $rc.w; desiredW = [math]::Round($c.DesiredSize.Width, 1)
                                       baseline = [math]::Round((& $script:R14Base $c), 2); fits = (($c.DesiredSize.Width -le $c.ActualWidth + 0.5) -and ($rc.x -ge $col.x - 0.5) -and ($rc.x + $rc.w -le $col.x + $col.w + 0.5)); inside = (($rc.x -ge $root.x) -and ($rc.x + $rc.w -le $root.x + $root.w)) }
        }
        $capTop = { param($cp) (& $script:R14Base $cp) - (Get-TbCapH $cp $cp.FontSize) }
        $lMid = ((& $capTop $ui.Roll7Cap) + $it.d14.baseline) / 2; $rMid = ((& $capTop $ui.Roll30Cap) + $it.d60.baseline) / 2
        $dl = & $script:R14Rect $ui.HeroDivL; $dr = & $script:R14Rect $ui.HeroDivR
        $sideText = ((@($ui.Roll7.Children) + @($ui.Roll14.Children) + @($ui.Roll30.Children) + @($ui.Roll60.Children)) | ForEach-Object { [string]$_.Text }) -join ' | '
        return [ordered]@{
            hero = $ui.HeroCost.Text; items = $it; rowsD7 = $ui.D7Cost.Text; rowsD30 = $ui.D30Cost.Text
            matchRows = (($ui.Roll7Cost.Text -eq $ui.D7Cost.Text) -and ($ui.Roll30Cost.Text -eq $ui.D30Cost.Text))
            sizes = [ordered]@{ hero = $ui.HeroCost.FontSize; side = $ui.Roll7Cost.FontSize; allSame = (@($it.Values | ForEach-Object { $_.size } | Select-Object -Unique).Count -eq 1); heroDominant = ($ui.HeroCost.FontSize -ge 2.4 * $ui.Roll7Cost.FontSize) }
            heroCentered = ([math]::Abs($hcx - $rcx) -le 0.6); heroCenterOff = [math]::Round($hcx - $rcx, 2)
            under = [ordered]@{ left14Under7 = (($it.d14.y -gt $it.d7.y) -and ([math]::Abs($it.d14.cx - $it.d7.cx) -le 0.6)); right60Under30 = (($it.d60.y -gt $it.d30.y) -and ([math]::Abs($it.d60.cx - $it.d30.cx) -le 0.6)) }
            symmetric = [ordered]@{ leftDist = [math]::Round($hcx - $it.d7.cx, 1); rightDist = [math]::Round($it.d30.cx - $hcx, 1); leftGap = [math]::Round($h.x - ($dl.x + $dl.w), 1); rightGap = [math]::Round($dr.x - ($h.x + $h.w), 1)
                                    sameRows = ([math]::Abs($it.d7.baseline - $it.d30.baseline) -le 0.5 -and [math]::Abs($it.d14.baseline - $it.d60.baseline) -le 0.5) }
            vcenter = [ordered]@{ heroMid = [math]::Round($heroMid, 2); leftMid = [math]::Round($lMid, 2); rightMid = [math]::Round($rMid, 2); ok = (([math]::Abs($heroMid - $lMid) -le 1.0) -and ([math]::Abs($heroMid - $rMid) -le 1.0)) }
            noClip = (@($it.Values | Where-Object { -not ($_.fits -and $_.inside) }).Count -eq 0); rowW = $row.w; windowW = $window.ActualWidth
            moneyOnly = ($sideText -notmatch 'kWh|night|charge|%|/'); sideText = ($sideText -replace [string][char]0x2009, '')
        }
    }
    & $add 'v4.3.14 rolling 7/14 days (left) and 30/60 days (right): shared calculation, rows match' @() {
        $script:SelfRec.v4314 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text; historyDays = $HistoryDays }
        $r = $script:SelfRec.v4314
        Render-View; $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout()
        $nowE = Get-EpochNow
        $r.direct = [ordered]@{}; foreach ($d in 7, 14, 30, 60) { $r.direct['d' + $d] = $(try { (Get-PeriodTotal $script:State $nowE $d).costUsdAllIn } catch { $null }) }
        $old = @($script:State.recentSessions | Where-Object { $null -ne $_ } | Sort-Object { [int64]$_.startEpoch })
        $r.sessions = [ordered]@{ count = $old.Count; oldestDaysAgo = $(if ($old.Count) { [math]::Round(($nowE - [int64]$old[0].startEpoch) / 86400, 1) } else { $null }) }
        $r.real = (& $script:R14Check)
        $r.real.matchDirect = (($r.real.items.d7.text -eq (Format-Money $r.direct.d7)) -and ($r.real.items.d14.text -eq (Format-Money $r.direct.d14)) -and ($r.real.items.d30.text -eq (Format-Money $r.direct.d30)) -and ($r.real.items.d60.text -eq (Format-Money $r.direct.d60)))
        $r.real.ordered = (([double]$r.direct.d7 -le [double]$r.direct.d14) -and ([double]$r.direct.d14 -le [double]$r.direct.d30) -and ([double]$r.direct.d30 -le [double]$r.direct.d60))
        $updVis = $ui.UpdateBtn.Visibility; $ui.UpdateBtn.Visibility = 'Collapsed'; $window.UpdateLayout()
        $r.realNoBanner = (& $script:R14Check)
        & $script:Shot4314 'top'
        $ui.UpdateBtn.Visibility = $updVis; $window.UpdateLayout()
    }
    & $add 'v4.3.14 big figures still fit at 473 px (wide-value check, display only)' @() {
        $r = $script:SelfRec.v4314
        $keep = @($ui.HeroCost.Text, $ui.Roll7Cost.Text, $ui.Roll14Cost.Text, $ui.Roll30Cost.Text, $ui.Roll60Cost.Text)
        $ui.HeroCost.Text = '$18.88'; $ui.Roll7Cost.Text = '$64.50'; $ui.Roll14Cost.Text = '$128.90'; $ui.Roll30Cost.Text = '$212.40'; $ui.Roll60Cost.Text = '$1,048.75'; Set-HeroRollFit
        $updVis = $ui.UpdateBtn.Visibility; $ui.UpdateBtn.Visibility = 'Collapsed'
        $r.wide = (& $script:R14Check)
        & $script:Shot4314 'wide'
        $ui.UpdateBtn.Visibility = $updVis
        $ui.HeroCost.Text = $keep[0]; Render-View; $window.UpdateLayout()
        $r.restored = [ordered]@{ hero = $ui.HeroCost.Text; d7 = $ui.Roll7Cost.Text; d14 = $ui.Roll14Cost.Text; d30 = $ui.Roll30Cost.Text; d60 = $ui.Roll60Cost.Text; side = $ui.Roll7Cost.FontSize; same = ($ui.Roll14Cost.Text -eq $keep[2] -and $ui.Roll60Cost.Text -eq $keep[4]) }
    }
    # ---- v4.3.15: LEAVING SOON (dry run, fast waits) ----
    $script:SelfRec.v4315 = [ordered]@{ waitSec = (Get-LeaveWaitSec); device = (Get-LeaveDevice); steps = @($LeaveSteps | ForEach-Object { $_.cmd }) }
    $script:Shot4315 = { param($n) $f = 'tessdesk-v4315-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
    $script:ElPng4315 = { param($el, $n)
        $window.UpdateLayout(); $s = 2.0; $w = [int][math]::Ceiling($el.ActualWidth * $s); $h = [int][math]::Ceiling($el.ActualHeight * $s)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $s), (96 * $s), [System.Windows.Media.PixelFormats]::Pbgra32)
        $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
        $dc.DrawRectangle((T 'CardBg'), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight))
        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($el)), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight)); $dc.Close(); $bmp.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $f = 'tessdesk-v4315-' + $n + '.png'; $fs = [IO.File]::Create((Join-Path $script:SelfDir $f)); try { $enc.Save($fs) } finally { $fs.Close() }; $script:SelfRec.shots += $f }
    $script:Rect4315 = { param($el) $p = $el.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.CtlCard); return [ordered]@{ x = [math]::Round($p.X, 1); y = [math]::Round($p.Y, 1); w = [math]::Round($el.ActualWidth, 1); h = [math]::Round($el.ActualHeight, 1) } }
    $script:Wait4315 = { param($sb) $script:LeaveWaitFor = $sb; $script:LeaveWaitUntil = (Get-Date).AddSeconds(60) }
    & $add 'v4.3.15 LEAVING SOON button: position (heading line, over Flash Lights) + snapshot' @() {
        Render-Controls; $ui.CtlCard.BringIntoView(); $window.UpdateLayout()
        $hd = & $script:Rect4315 $ui.CtlHdr; $bt = & $script:Rect4315 $ui.LeaveBtn; $fl = & $script:Rect4315 $ui.FlashBox; $md = & $script:Rect4315 $ui.CtlMode
        $ft = Get-TbWidth $ui.CtlHdr $ui.CtlHdr.Text $ui.CtlHdr.FontSize; $hdTextR = $hd.x + $ft.WidthIncludingTrailingWhitespace
        $hdTextMid = $hd.y + $ft.Baseline - (Get-TbCapH $ui.CtlHdr $ui.CtlHdr.FontSize) / 2
        $btMid = $bt.y + $bt.h / 2
        $script:SelfRec.v4315.position = [ordered]@{ heading = $hd; headingTextRight = [math]::Round($hdTextR, 1); button = $bt; flash = $fl; mode = $md
            sameLine = ([math]::Abs($btMid - $hdTextMid) -le 1.5); midDiff = [math]::Round($btMid - $hdTextMid, 2)
            noOverlapHeading = ($bt.x -ge $hdTextR + 4); gapToHeading = [math]::Round($bt.x - $hdTextR, 1)
            overFlash = ($bt.x -ge $fl.x - 0.5 -and ($bt.x + $bt.w) -le ($fl.x + $fl.w + 0.5)); aboveFlash = (($bt.y + $bt.h) -le $fl.y)
            text = $ui.LeaveBtnTxt.Text; textFits = ($ui.LeaveBtnTxt.ActualWidth -le $bt.w) }
        & $script:Shot4315 'button'; & $script:ElPng4315 $ui.CtlCard 'button-area' }
    & $add 'v4.3.15 LEAVING SOON: Are you sure? snapshot' @() { [void](Show-ConfirmOverlay 'Are you sure? Start Leaving Soon?' ('Climate turns on now, the windows close {0} later, then the car unlocks {0} after that. Each step is announced on Alexa. Stop cancels the rest.' -f (Format-LeaveSpan 180)) 'Start' 'Cancel' -NoWait); & $script:Shot4315 'confirm'; Close-ConfirmOverlay $false }
    & $add 'v4.3.15 LEAVING SOON: answer NO (nothing sent)' @($false) { $c0 = @($script:CtlLog).Count; $a0 = @($script:AnnLog).Count; Start-LeaveSoon
        $script:SelfRec.v4315.no = [ordered]@{ running = $script:Leave.running; commands = (@($script:CtlLog).Count - $c0); announcements = (@($script:AnnLog).Count - $a0); result = $script:CtlResultText } }
    & $add 'v4.3.15 LEAVING SOON: answer YES (DRY RUN), run to the step 2 countdown' @($true) { $script:Leave0 = @($script:AnnLog).Count; Start-LeaveSoon; & $script:Wait4315 { $script:Leave.phase -eq 'wait' -and $script:Leave.step -eq 1 -and ($script:Leave.dueAt - (Get-Date)).TotalSeconds -le ($script:Leave.waitSec - 1) } }
    & $add 'v4.3.15 LEAVING SOON: countdown snapshot + Stop button' @() { $window.UpdateLayout(); $script:SelfRec.v4315.countdown = [ordered]@{ text = $ui.LeaveStep.Text; stop = $ui.LeaveStopTxt.Text; rowVisible = ($ui.LeaveRow.Visibility -eq 'Visible'); buttonEnabled = $ui.LeaveBtn.IsEnabled }
        & $script:Shot4315 'countdown'; & $script:ElPng4315 $ui.CtlCard 'countdown-area'; & $script:Wait4315 { -not $script:Leave.running -and $null -eq $script:Leave.job } }
    & $add 'v4.3.15 LEAVING SOON: finished (3 of 3)' @() { $L = $script:Leave
        $script:SelfRec.v4315.full = [ordered]@{ phase = $L.phase; result = $L.result; text = $ui.LeaveStep.Text; log = @($L.log); ann = @($L.ann); notes = @($L.notes); stop = $ui.LeaveStopTxt.Text; snap = $L.snap
            urls = @(@($script:CtlLog) | Select-Object -Last 3 | ForEach-Object { ([string]$_.url) -replace '^.*?/command/', '/command/' }) }
        & $script:Shot4315 'done' }
    & $add 'v4.3.15 LEAVING SOON: Stop during the step 2 countdown' @($true) { Stop-LeaveSoon; $script:LeaveFakeStart = [pscustomobject]@{ climate_state = [pscustomobject]@{ is_climate_on = $true }; vehicle_state = [pscustomobject]@{ locked = $false; fd_window = 0; fp_window = 0; rd_window = 0; rp_window = 0 } }; Start-LeaveSoon; & $script:Wait4315 { $script:Leave.phase -eq 'wait' -and $script:Leave.step -eq 1 } }
    & $add 'v4.3.15 LEAVING SOON: press Stop' @() { $ui.LeaveStopBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $script:LeaveStopAt = Get-Date
        & $script:Wait4315 { ((Get-Date) - $script:LeaveStopAt).TotalSeconds -ge ($script:Leave.waitSec + 2) } }
    & $add 'v4.3.15 LEAVING SOON: stopped result (no more commands after Stop)' @() { $L = $script:Leave
        $script:SelfRec.v4315.stop = [ordered]@{ phase = $L.phase; result = $L.result; text = $ui.LeaveStep.Text; log = @($L.log); ann = @($L.ann); running = $L.running }
        & $script:Shot4315 'stopped' }
    & $add 'v4.3.15 LEAVING SOON: failure (close_windows fails, unlock must not run)' @($true) { Stop-LeaveSoon; $script:LeaveFailCmd = 'close_windows'; Start-LeaveSoon; & $script:Wait4315 { -not $script:Leave.running -and $null -eq $script:Leave.job } }
    & $add 'v4.3.15 LEAVING SOON: failure result' @() { $L = $script:Leave; $script:LeaveFailCmd = $null
        $script:SelfRec.v4315.fail = [ordered]@{ phase = $L.phase; result = $L.result; text = $ui.LeaveStep.Text; ctlResult = $script:CtlResultText; log = @($L.log); ann = @($L.ann) }
        & $script:Shot4315 'failed'; & $script:ElPng4315 $ui.CtlCard 'failed-area'; Stop-LeaveSoon }
    # ---- v4.3.16: LEAVING SOON adjustable waits + Stop undoes the steps already done (dry run, 2 s per minute) ----
    $script:SelfRec.v4316 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text; footerBrand = $ui.FooterText.Text; footerBold = [string]$ui.FooterText.FontWeight; secPerMin = (Get-LeaveSecPerMin); defaults = @(Get-LeaveMins); firstRunSnap = $script:SelfRec.v4315.full.snap }
    $script:Shot4316 = { param($n) $f = 'tessdesk-v4316-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
    $script:ElPng4316 = { param($el, $n)
        $window.UpdateLayout(); $s = 2.0; $w = [int][math]::Ceiling($el.ActualWidth * $s); $h = [int][math]::Ceiling($el.ActualHeight * $s)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $s), (96 * $s), [System.Windows.Media.PixelFormats]::Pbgra32)
        $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
        $dc.DrawRectangle((T 'CardBg'), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight))
        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($el)), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight)); $dc.Close(); $bmp.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $f = 'tessdesk-v4316-' + $n + '.png'; $fs = [IO.File]::Create((Join-Path $script:SelfDir $f)); try { $enc.Save($fs) } finally { $fs.Close() }; $script:SelfRec.shots += $f }
    $script:Fake4316 = { param($clim, $fd, $locked) [pscustomobject]@{ climate_state = [pscustomobject]@{ is_climate_on = $clim }; vehicle_state = [pscustomobject]@{ locked = $locked; fd_window = $fd; fp_window = 0; rd_window = 0; rp_window = 0 } } }
    $script:Rec4316 = { $L = $script:Leave
        [ordered]@{ phase = $L.phase; running = $L.running; undoing = $L.undoing; result = $L.result; text = $ui.LeaveStep.Text; ctlResult = $script:CtlResultText; kind = $L.kind; stopBtn = $ui.LeaveStopTxt.Text
            mins = @($L.mins); waits = @($L.waits); waitLog = @($L.waitLog); snap = $L.snap; done = @($L.doneCmds); undo = @($L.undo | ForEach-Object { $_.cmd }); undoDone = @($L.undoDone); undoFailed = @($L.undoFailed); undoKept = @($L.undoKept)
            notes = @($L.notes); cmds = @($L.log | ForEach-Object { $_.kind + ':' + $_.cmd + ':' + $(if ($_.ok) { 'ok' } else { 'FAIL' }) }); log = @($L.log)
            ann = @($L.ann | ForEach-Object { [ordered]@{ tag = $_.tag; text = $_.text; devices = $_.devices; result = $_.result } }); seen = @($script:LeaveSeen | Where-Object { $_ -notmatch ' in \d+:\d\d$' } | Select-Object -First 14)
            countdownFirst = @(@($script:LeaveSeen | Where-Object { $_ -match ' in \d+:\d\d$' }) | Group-Object { $_ -replace ' in \d+:\d\d$', '' } | ForEach-Object { $_.Group[0] })
            undoingSeen = @($script:LeaveSeen | Where-Object { $_ -like 'Undoing*' }) } }
    $script:Gap4316 = { param($log, $a, $b) $x = @($log | Where-Object { $_.kind -eq 'step' -and $_.cmd -eq $a } | Select-Object -First 1); $y = @($log | Where-Object { $_.kind -eq 'step' -and $_.cmd -eq $b } | Select-Object -First 1)
        if ($x.Count -eq 0 -or $y.Count -eq 0) { return $null }; return [math]::Round(([datetime]::ParseExact($y[0].started, 'HH:mm:ss.fff', $Inv) - [datetime]::ParseExact($x[0].ended, 'HH:mm:ss.fff', $Inv)).TotalSeconds, 2) }
    $script:Click4316 = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    $script:NoUndo4316 = (& $script:Fake4316 $true 0 $false)     # climate already on, windows closed, unlocked: nothing to undo
    $script:AllUndo4316 = (& $script:Fake4316 $false 18 $true)   # climate off, driver window open, locked: everything gets undone
    & $add 'v4.3.16 wait controls: position (under LEAVING SOON) + snapshot' @() {
        Stop-LeaveSoon; Render-Controls; $ui.CtlCard.BringIntoView(); $window.UpdateLayout()
        $row = & $script:Rect4315 $ui.LeaveWaitRow; $bt = & $script:Rect4315 $ui.LeaveBtn; $fl = & $script:Rect4315 $ui.FlashBox
        $cardW = $ui.CtlCard.ActualWidth
        $script:SelfRec.v4316.position = [ordered]@{ row = $row; button = $bt; flash = $fl; cardWidth = [math]::Round($cardW, 1)
            belowButton = ($row.y -ge ($bt.y + $bt.h - 0.5)); aboveFlash = (($row.y + $row.h) -le $fl.y + 0.5); insideCard = ($row.x -ge 0 -and ($row.x + $row.w) -le $cardW)
            rightEdgeMatchesFlashRight = [math]::Round(($row.x + $row.w) - ($fl.x + $fl.w), 1); values = @($ui.LeaveWinMin.Text, $ui.LeaveUnlockMin.Text); labels = @($ui.LeaveWinLbl.Text, $ui.LeaveUnlockLbl.Text) }
        & $script:Shot4316 'waits'; & $script:ElPng4316 $ui.CtlCard 'waits-area' }
    & $add 'v4.3.16 wait controls: + / - buttons, wheel, keys, 0-30 clamp, saved to config' @() {
        $r = [ordered]@{}
        & $script:Click4316 $ui.LeaveWinUp; $r.plusBtn = $ui.LeaveWinMin.Text
        & $script:Click4316 $ui.LeaveUnlockDn; $r.minusBtn = $ui.LeaveUnlockMin.Text
        $we = New-Object System.Windows.Input.MouseWheelEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, 120); $we.RoutedEvent = [System.Windows.UIElement]::PreviewMouseWheelEvent; $ui.LeaveWinMin.RaiseEvent($we); $r.wheelUp = $ui.LeaveWinMin.Text
        Set-LeaveMin $ui.LeaveWinMin 45; $r.clampHigh = $ui.LeaveWinMin.Text; Add-LeaveMin $ui.LeaveWinMin 'windowsAfterMin' 1; $r.clampHighPlus = $ui.LeaveWinMin.Text
        Set-LeaveMin $ui.LeaveUnlockMin -4; $r.clampLow = $ui.LeaveUnlockMin.Text; Add-LeaveMin $ui.LeaveUnlockMin 'unlockAfterMin' -1; $r.clampLowMinus = $ui.LeaveUnlockMin.Text
        $ui.LeaveWinMin.Text = 'x'; $r.badTextReadsAs = (Get-LeaveUiMin $ui.LeaveWinMin 'windowsAfterMin')
        Set-LeaveMin $ui.LeaveWinMin 1; Set-LeaveMin $ui.LeaveUnlockMin 2
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $r.savedFile = [ordered]@{ path = (Split-Path -Leaf $ConfigPath); windowsAfterMin = $raw.leavingSoon.windowsAfterMin; unlockAfterMin = $raw.leavingSoon.unlockAfterMin }
        $r.reloaded = @((Get-LeaveCfgMin 'windowsAfterMin'), (Get-LeaveCfgMin 'unlockAfterMin'))
        $script:SelfRec.v4316.controls = $r }
    & $add 'v4.3.16 custom waits 1 / 2 min: YES (DRY RUN), to the step 3 countdown' @($true) { $script:LeaveFakeStart = $script:NoUndo4316; Start-LeaveSoon; & $script:Wait4315 { $script:Leave.phase -eq 'wait' -and $script:Leave.step -eq 2 } }
    & $add 'v4.3.16 custom waits: countdown snapshot' @() { $window.UpdateLayout(); $script:SelfRec.v4316.customCountdown = $ui.LeaveStep.Text; & $script:Shot4316 'custom-countdown'; & $script:ElPng4316 $ui.CtlCard 'custom-countdown-area'
        & $script:Wait4315 { -not $script:Leave.running -and $null -eq $script:Leave.job } }
    & $add 'v4.3.16 custom waits: result' @() { $r = (& $script:Rec4316); $r.prompt = @($script:ConfirmPrompts)[-1]
        $r.gapWindows = (& $script:Gap4316 $script:Leave.log 'start_climate' 'close_windows'); $r.gapUnlock = (& $script:Gap4316 $script:Leave.log 'close_windows' 'unlock'); $script:SelfRec.v4316.custom = $r }
    & $add 'v4.3.16 0-minute waits (0 / 0): YES (DRY RUN), all steps right away' @($true) { Set-LeaveMin $ui.LeaveWinMin 0; Set-LeaveMin $ui.LeaveUnlockMin 0; Stop-LeaveSoon; $script:LeaveFakeStart = $script:NoUndo4316; Start-LeaveSoon
        & $script:Wait4315 { -not $script:Leave.running -and $null -eq $script:Leave.job } }
    & $add 'v4.3.16 0-minute waits: result' @() { $r = (& $script:Rec4316); $r.prompt = @($script:ConfirmPrompts)[-1]
        $r.gapWindows = (& $script:Gap4316 $script:Leave.log 'start_climate' 'close_windows'); $r.gapUnlock = (& $script:Gap4316 $script:Leave.log 'close_windows' 'unlock'); $r.countdownShown = @($script:LeaveSeen | Where-Object { $_ -match ' in \d+:\d\d$' }).Count; $script:SelfRec.v4316.zero = $r; & $script:Shot4316 'zero-done' }
    & $add 'v4.3.16 mixed waits (0 / 1): YES (DRY RUN)' @($true) { Set-LeaveMin $ui.LeaveWinMin 0; Set-LeaveMin $ui.LeaveUnlockMin 1; Stop-LeaveSoon; $script:LeaveFakeStart = $script:NoUndo4316; Start-LeaveSoon
        & $script:Wait4315 { -not $script:Leave.running -and $null -eq $script:Leave.job } }
    & $add 'v4.3.16 mixed waits: result' @() { $r = (& $script:Rec4316); $r.prompt = @($script:ConfirmPrompts)[-1]
        $r.gapWindows = (& $script:Gap4316 $script:Leave.log 'start_climate' 'close_windows'); $r.gapUnlock = (& $script:Gap4316 $script:Leave.log 'close_windows' 'unlock'); $script:SelfRec.v4316.mixed = $r }
    # Stop after each step (start state: climate off, a window open, locked)
    & $add 'v4.3.16 Stop after step 1 (climate on): run to the windows countdown' @($true) { Set-LeaveMin $ui.LeaveWinMin 3; Set-LeaveMin $ui.LeaveUnlockMin 3; Stop-LeaveSoon; $script:LeaveFakeStart = $script:AllUndo4316; Start-LeaveSoon
        & $script:Wait4315 { $script:Leave.phase -eq 'wait' -and $script:Leave.step -eq 1 } }
    & $add 'v4.3.16 Stop after step 1: press Stop, undo runs' @() { & $script:Click4316 $ui.LeaveStopBtn; & $script:Wait4315 { -not $script:Leave.running -and -not $script:Leave.undoing -and $null -eq $script:Leave.job } }
    & $add 'v4.3.16 Stop after step 1: result (stop_climate only)' @() { $r = (& $script:Rec4316); $script:SelfRec.v4316.stop1 = $r; & $script:Shot4316 'stop1-undone' }
    & $add 'v4.3.16 Stop after step 2 (windows closed): run to the unlock countdown' @($true) { Stop-LeaveSoon; $script:LeaveFakeStart = $script:AllUndo4316; Start-LeaveSoon
        & $script:Wait4315 { $script:Leave.phase -eq 'wait' -and $script:Leave.step -eq 2 } }
    & $add 'v4.3.16 Stop after step 2: press Stop, catch Undoing 1 of 2' @() { & $script:Click4316 $ui.LeaveStopBtn; & $script:Wait4315 { $script:Leave.undoing -and $null -ne $script:Leave.job } }
    & $add 'v4.3.16 Stop after step 2: undo progress snapshot' @() { $window.UpdateLayout(); $script:SelfRec.v4316.undoProgress = [ordered]@{ text = $ui.LeaveStep.Text; stop = $ui.LeaveStopTxt.Text; stopEnabled = $ui.LeaveStopBtn.IsEnabled; leaveEnabled = $ui.LeaveBtn.IsEnabled; waitBoxEnabled = $ui.LeaveWinMin.IsEnabled; ctlResult = $script:CtlResultText }
        & $script:Shot4316 'undoing'; & $script:ElPng4316 $ui.CtlCard 'undoing-area'; & $script:Wait4315 { -not $script:Leave.undoing -and $null -eq $script:Leave.job } }
    & $add 'v4.3.16 Stop after step 2: result (vent_windows, stop_climate)' @() { $r = (& $script:Rec4316); $script:SelfRec.v4316.stop2 = $r; & $script:Shot4316 'stop2-undone'; & $script:ElPng4316 $ui.CtlCard 'stop2-undone-area' }
    & $add 'v4.3.16 Stop after step 3 (unlock sent, result pending): run until unlock is on its way' @($true) { Set-LeaveMin $ui.LeaveWinMin 0; Set-LeaveMin $ui.LeaveUnlockMin 0; Stop-LeaveSoon; $script:LeaveFakeStart = $script:AllUndo4316; Start-LeaveSoon
        & $script:Wait4315 { $null -ne $script:Leave.job -and $script:Leave.job.cmd -eq 'unlock' } }
    & $add 'v4.3.16 Stop after step 3: press Stop, unlock completes, then undo all' @() { & $script:Click4316 $ui.LeaveStopBtn; $script:SelfRec.v4316.stop3Pending = $ui.LeaveStep.Text
        & $script:Wait4315 { -not $script:Leave.running -and -not $script:Leave.undoing -and $null -eq $script:Leave.job -and $script:Leave.phase -eq 'cancelled' -and @($script:Leave.log | Where-Object { $_.kind -eq 'undo' }).Count -ge 1 } }
    & $add 'v4.3.16 Stop after step 3: result (lock, vent_windows, stop_climate)' @() { $r = (& $script:Rec4316); $script:SelfRec.v4316.stop3 = $r; & $script:Shot4316 'stop3-undone' }
    & $add 'v4.3.16 Stop with nothing to undo (climate was on, windows closed, unlocked)' @($true) { Set-LeaveMin $ui.LeaveWinMin 1; Set-LeaveMin $ui.LeaveUnlockMin 1; Stop-LeaveSoon; $script:LeaveFakeStart = $script:NoUndo4316; Start-LeaveSoon
        & $script:Wait4315 { $script:Leave.phase -eq 'wait' -and $script:Leave.step -eq 2 } }
    & $add 'v4.3.16 Stop with nothing to undo: press Stop' @() { & $script:Click4316 $ui.LeaveStopBtn; & $script:Wait4315 { -not $script:Leave.running -and -not $script:Leave.undoing -and $null -eq $script:Leave.job } }
    & $add 'v4.3.16 Stop with nothing to undo: result (no undo commands)' @() { $script:SelfRec.v4316.stopNone = (& $script:Rec4316) }
    & $add 'v4.3.16 undo failure (vent_windows fails, stop_climate still runs)' @($true) { Stop-LeaveSoon; $script:LeaveFakeStart = $script:AllUndo4316; Start-LeaveSoon
        & $script:Wait4315 { $script:Leave.phase -eq 'wait' -and $script:Leave.step -eq 2 } }
    & $add 'v4.3.16 undo failure: press Stop' @() { $script:LeaveFailCmd = 'vent_windows'; & $script:Click4316 $ui.LeaveStopBtn; & $script:Wait4315 { -not $script:Leave.running -and -not $script:Leave.undoing -and $null -eq $script:Leave.job } }
    & $add 'v4.3.16 undo failure: result' @() { $script:LeaveFailCmd = $null; $script:SelfRec.v4316.undoFail = (& $script:Rec4316); & $script:Shot4316 'undo-failed' }
    & $add 'v4.3.16 back to 3 / 3 min, close' @() { Stop-LeaveSoon; $script:LeaveFakeStart = $null; Set-LeaveMin $ui.LeaveWinMin 3; Set-LeaveMin $ui.LeaveUnlockMin 3
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json; $script:SelfRec.v4316.finalSaved = @($raw.leavingSoon.windowsAfterMin, $raw.leavingSoon.unlockAfterMin)
        $script:SelfRec.v4316.hookLine = ((Get-Content -LiteralPath (Join-Path $scriptDir 'TessDesk.ps1') -Encoding UTF8 | Where-Object { $_ -like "try { . 'C:\Users\vanwi\cb_compact_addon.ps1'*" }).Count) }
    # ---- v4.3.17: layout (TESLA CONTROLS first, START / STOP under it) + CHARGE HISTORY & TOTALS dropdown (remembered in config.json ui.historyOpen) ----
    $script:SelfRec.v4317 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text; footerBrand = $ui.FooterText.Text; footerBold = [string]$ui.FooterText.FontWeight; atStart = $script:SelfRec.v4317pre }
    $script:Shot4317 = { param($n) $f = 'tessdesk-v4317-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
    $script:Y4317 = { param($el) if ($null -eq $el -or -not $el.IsVisible) { return $null }; return [math]::Round($el.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.MainGrid).Y, 1) }
    $script:Cfg4317 = { $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($null -ne $raw.ui -and $null -ne $raw.ui.PSObject.Properties['historyOpen']) { return [string]$raw.ui.historyOpen }; return '(not set)' }
    $script:Hist4317 = { $window.UpdateLayout(); [ordered]@{ open = [bool]$script:ChgHist.open; body = [string]$ui.ChgHistBody.Visibility; arrow = $ui.ChgHistArrow.Text; title = $ui.ChgHistHdr.Text; sum = $ui.ChgHistSum.Text
        night = ($ui.NightLbl.Text + '  ' + $ui.NightCost.Text); saved = (& $script:Cfg4317); cardHeight = [math]::Round($ui.RowsCard.ActualHeight, 1); totBtnVisible = [bool]$ui.TotBtn.IsVisible
        uiKeys = @((Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json).ui.PSObject.Properties | ForEach-Object { $_.Name }) } }
    $script:Click4317 = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    & $add 'v4.3.17 layout order (hero, TESLA CONTROLS, START / STOP, battery, amps, tiles, day rate, history dropdown)' @() {
        Stop-LeaveSoon; Set-ChgHistOpen $false $false; Render-View; $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout()
        $names = @('HeroCost', 'Roll7Cost', 'Roll60Cost', 'CtlCard', 'LeaveBtn', 'LeaveWaitRow', 'AnnNowBtn', 'ChgCard', 'BattCard', 'VLim', 'AmpsHdr', 'PeakBanner', 'RowsCard', 'SeatsCard', 'TiresCard', 'DrivesCard')
        $ys = [ordered]@{}; foreach ($n in $names) { $ys[$n] = & $script:Y4317 $ui[$n] }
        $chk = @('HeroCost', 'ChgCard', 'CtlCard', 'BattCard', 'AmpsHdr', 'PeakBanner', 'RowsCard', 'SeatsCard'); $seq = @($chk | Where-Object { $null -ne $ys[$_] })
        $inOrder = $true; for ($i = 1; $i -lt $seq.Count; $i++) { if ($ys[$seq[$i]] -le $ys[$seq[$i - 1]]) { $inOrder = $false } }
        $ctlBottom = $ys['CtlCard'] + $ui.CtlCard.ActualHeight + $ui.CtlCard.Margin.Bottom
        $script:SelfRec.v4317.order = [ordered]@{ y = $ys; checked = $seq; inOrder = $inOrder; chgBarAboveControls = ($ys['ChgCard'] -lt $ys['CtlCard'])
            bodyStack = @($ui.BodyStack.Children | ForEach-Object { if ($_.Name) { $_.Name } else { $_.GetType().Name } }); chgButtonsParent = [string]$ui.ChgStartBtn.Parent.Name
            ctlInScrollTop = ($ui.BodyStack.Children.IndexOf($ui.CtlCard) -eq 0); heroRowStillTop = ([System.Windows.Controls.Grid]::GetRow($ui.HeroRow.Parent) -eq 1); layout = (Get-LayoutCheck) }
        & $script:Shot4317 'layout-top' }
    & $add 'v4.3.17 dropdown: starts collapsed when nothing is saved (header shows last night $)' @() {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $raw.ui -and $null -ne $raw.ui.PSObject.Properties['historyOpen']) { $raw.ui.PSObject.Properties.Remove('historyOpen'); $raw | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 }
        $script:Cfg = Read-Config; Set-ChgHistOpen (Get-ChgHistCfg) $false; Render-View
        $script:SelfRec.v4317.fresh = (& $script:Hist4317); $ui.RowsCard.BringIntoView(); $window.UpdateLayout(); & $script:Shot4317 'collapsed' }
    & $add 'v4.3.17 dropdown: click opens it and saves historyOpen = true' @() {
        & $script:Click4317 $ui.ChgHistBtn; $script:SelfRec.v4317.opened = (& $script:Hist4317)
        $ui.RowsCard.BringIntoView(); $window.UpdateLayout(); & $script:Shot4317 'expanded' }
    & $add 'v4.3.17 dropdown: remembered after a restart (config re-read, starts open)' @() {
        $script:ChgHist.open = $false; $ui.ChgHistBody.Visibility = 'Collapsed'; $script:Cfg = Read-Config
        Set-ChgHistOpen (Get-ChgHistCfg) $false; $script:SelfRec.v4317.reloadOpen = (& $script:Hist4317) }
    & $add 'v4.3.17 dropdown: TOTALS pop-up still opens from the expanded row, X closes' @() {
        & $script:Click4317 $ui.TotBtn; $window.UpdateLayout(); $vis = [string]$ui.TotOverlay.Visibility; & $script:Shot4317 'totals'
        & $script:Click4317 $ui.TotClose; $script:SelfRec.v4317.totals = [ordered]@{ opened = $vis; status = $ui.TotStatus.Text; closed = ([string]$ui.TotOverlay.Visibility -ne 'Visible') } }
    & $add 'v4.3.17 dropdown: click closes it, saves false; restart starts collapsed' @() {
        & $script:Click4317 $ui.ChgHistBtn; $r = [ordered]@{ closed = (& $script:Hist4317) }
        $script:ChgHist.open = $true; $ui.ChgHistBody.Visibility = 'Visible'; $script:Cfg = Read-Config; Set-ChgHistOpen (Get-ChgHistCfg) $false
        $r.reloadClosed = (& $script:Hist4317); $script:SelfRec.v4317.close = $r; $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout(); & $script:Shot4317 'final' }
        # ---- v4.3.18: CHARGING STATUS bar (each state, start / stop from the bar, DRY RUN) + fits 364x990 without scrolling ----
    $script:SelfRec.v4318 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text; footerBold = [string]$ui.FooterText.FontWeight; states = [ordered]@{} }
    $script:Orig4318 = $script:View
    $script:New4318 = { param($ref) $L = @($script:CtlLog); $i = -1; for ($k = 0; $k -lt $L.Count; $k++) { if ([object]::ReferenceEquals($L[$k], $ref)) { $i = $k } }; if ($null -ne $ref -and $i -lt 0) { return $L }; return @($L | Select-Object -Skip ($i + 1)) }   # CtlLog keeps only the last 12
    $script:Shot4318 = { param($n) $f = 'tessdesk-v4318-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
    $script:ElPng4318 = { param($el, $n)
        $window.UpdateLayout(); $s = 2.0; $w = [int][math]::Ceiling($el.ActualWidth * $s); $h = [int][math]::Ceiling($el.ActualHeight * $s)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $s), (96 * $s), [System.Windows.Media.PixelFormats]::Pbgra32)
        $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
        $dc.DrawRectangle((T 'RootBg'), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight))
        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($el)), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight)); $dc.Close(); $bmp.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $f = 'tessdesk-v4318-' + $n + '.png'; $fs = [IO.File]::Create((Join-Path $script:SelfDir $f)); try { $enc.Save($fs) } finally { $fs.Close() }; $script:SelfRec.shots += $f }
    $script:Fake4318 = { param([string]$cs, [bool]$live)
        $now = Get-EpochNow; $base = $null; if ($null -ne $script:Orig4318) { $base = $script:Orig4318.car }
        $car = [pscustomobject]@{}; if ($null -ne $base) { foreach ($p in $base.PSObject.Properties) { $car | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }
        foreach ($kv in ([ordered]@{ chargingState = $cs; socPct = 58; limitPct = 80; volts = 240; amps = 32; fastCharger = $false; phases = 1 }).GetEnumerator()) { $car | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force }
        $tires = $null; if ($null -ne $script:Orig4318) { $tires = $script:Orig4318.tires }
        $loc = Read-LocalJson
        if ($live) { $s = [pscustomobject]@{ costUsdAllIn = 0.62; rateNow = 0.0305; kwhAdded = 5.1; socStartPct = 50; limitPct = 80; socPct = 58; chargerKw = 7.7; minutesToFull = 140; lastEpoch = $now; startEpoch = $now - 3960; joinedMid = $false }
            return (Build-LiveView $s $car $tires $loc '' $null) }
        $last = [pscustomobject]@{ startEpoch = $now - 36000; endEpoch = $now - 18000; costUsdAllIn = 1.63; kwhWall = 26.3; kwhAdded = 23.7; socStartPct = 44; socEndPct = 80; source = 'window'; sessions = 1 }
        return (Build-IdleView $last $car $tires $loc '') }
    $script:Rec4318 = { $window.UpdateLayout()
        [ordered]@{ word = $ui.ChgState.Text; kind = $script:ChgStatus.kind; chargingState = $script:ChgStatus.state; color = [string]$ui.ChgState.Foreground; border = [string]$ui.ChgCard.BorderBrush
            stats = @(0..3 | ForEach-Object { $ui['ChgL' + $_].Text + '=' + $ui['ChgV' + $_].Text }); sub = $ui.ChgSub.Text; dotPulsing = [bool]$ui.ChgDot.HasAnimatedProperties; dotFill = [string]$ui.ChgDot.Fill
            start = [ordered]@{ enabled = $ui.ChgStartBtn.IsEnabled; sub = $ui.ChgStartSub.Text }; stop = [ordered]@{ enabled = $ui.ChgStopBtn.IsEnabled; sub = $ui.ChgStopSub.Text }
            glow = [string]$script:GlowMode; theme = [string]$script:Theme.Name; wordFits = ($ui.ChgState.Parent.ActualHeight -gt 0 -and ($ui.ChgState.ActualWidth * ($ui.ChgState.Parent.ActualHeight / [math]::Max(1, $ui.ChgState.ActualHeight))) -le $ui.ChgHead.ActualWidth + 0.5) } }
    $script:State4318 = { param([string]$name, [string]$cs, [bool]$live, [string]$shot)
        $script:CtlOverride.Remove('chargingState'); $script:GlowForce = $null
        $script:View = (& $script:Fake4318 $cs $live); Render-View; $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout()
        $script:SelfRec.v4318.states[$name] = (& $script:Rec4318)
        if ($shot) { & $script:Shot4318 $shot; & $script:ElPng4318 $ui.ChgCard ($shot + '-bar') } }
    & $add 'v4.3.18 status bar: CHARGING (live session, 7.7 kW)' @() { & $script:State4318 'charging' 'Charging' $true 'charging' }
    & $add 'v4.3.18 status bar: NOT CHARGING (plugged in, stopped)' @() { & $script:State4318 'notCharging' 'Stopped' $false 'not-charging' }
    & $add 'v4.3.18 status bar: UNPLUGGED' @() { & $script:State4318 'unplugged' 'Disconnected' $false 'unplugged' }
    & $add 'v4.3.18 status bar: COMPLETE' @() { & $script:State4318 'complete' 'Complete' $false 'complete' }
    & $add 'v4.3.18 status bar: NOT CHARGING (no power), CHARGING (starting), unknown state' @() {
        & $script:State4318 'noPower' 'NoPower' $false ''; & $script:State4318 'starting' 'Starting' $false ''; & $script:State4318 'unknown' '' $false '' }
    & $add 'v4.3.18 layout: fits 473x990 without scrolling (status bar, TESLA CONTROLS, top of BATTERY)' @() {
        & $script:State4318 'layoutCharging' 'Charging' $true ''
        $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout()
        $sc = $ui.BodyScroll; $vp = $sc.ViewportHeight; $mgH = $ui.MainGrid.ActualHeight
        $vis = [ordered]@{}
        foreach ($n in 'HeroCost', 'Roll60Cost', 'ChgCard', 'ChgState', 'ChgStartBtn', 'ChgStopBtn', 'ChgStats', 'ChgSub') { $el = $ui[$n]; $p = $el.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.MainGrid); $vis[$n] = [ordered]@{ top = [math]::Round($p.Y, 1); bottom = [math]::Round($p.Y + $el.ActualHeight, 1); visible = ($el.IsVisible -and ($p.Y + $el.ActualHeight) -le ($sc.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.MainGrid).Y) + 0.5) } }
        foreach ($n in 'CtlCard', 'LeaveBtn', 'LeaveWaitRow', 'LockBtn', 'FlashBox', 'HeatBtn', 'VentBtn', 'TrunkBtn', 'AnnNowBtn', 'CtlResultBox', 'SkipCfRow', 'BattCard', 'BattHdr', 'BattPct', 'BarDark', 'VThumb', 'BarLimitLbl', 'AmpsHdr', 'PeakBanner', 'RowsCard') {
            $el = $ui[$n]; $p = $el.TranslatePoint([System.Windows.Point]::new(0, 0), $sc); $vis[$n] = [ordered]@{ top = [math]::Round($p.Y, 1); bottom = [math]::Round($p.Y + $el.ActualHeight, 1); visible = ($el.IsVisible -and $p.Y -ge -0.5 -and ($p.Y + $el.ActualHeight) -le $vp + 0.5) } }
        $need = @('ChgCard', 'ChgState', 'ChgStartBtn', 'ChgStopBtn', 'ChgStats', 'CtlCard', 'LeaveBtn', 'LockBtn', 'AnnNowBtn', 'CtlResultBox', 'SkipCfRow', 'BattHdr', 'BattPct')
        $script:SelfRec.v4318.fit = [ordered]@{ window = ('{0}x{1}' -f $window.ActualWidth, $window.ActualHeight); viewport = [math]::Round($vp, 1); mainGrid = [math]::Round($mgH, 1)
            allKeyVisible = (@($need | Where-Object { -not $vis[$_].visible }).Count -eq 0); notVisible = @($vis.Keys | Where-Object { -not $vis[$_].visible }); elements = $vis
            tilesHidden = ([string]$ui.TilesRow.Visibility -eq 'Collapsed'); oldChgRowGone = ($null -eq $ui['ChgBtnRow']); chgButtonsParent = [string]$ui.ChgStartBtn.Parent.Name
            ctlCardHeight = [math]::Round($ui.CtlCard.ActualHeight, 1); chgCardHeight = [math]::Round($ui.ChgCard.ActualHeight, 1); layout = (Get-LayoutCheck) }
        & $script:Shot4318 'fit-990' }
    & $add 'v4.3.18 STOP from the status bar: answer NO (nothing sent)' @($false) {
        & $script:State4318 'stopNoBefore' 'Charging' $true ''; $script:N4318 = @($script:CtlLog)[-1]
        $ui.ChgStopBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $script:SelfRec.v4318.stopNo = [ordered]@{ enabledBefore = $script:SelfRec.v4318.states.stopNoBefore.stop.enabled; prompt = @($script:ConfirmPrompts)[-1]; commands = @(& $script:New4318 $script:N4318).Count; result = $script:CtlResultText } }
    & $add 'v4.3.18 STOP from the status bar: answer YES (DRY RUN)' @($true) {
        & $script:State4318 'stopBefore' 'Charging' $true ''; $script:N4318 = @($script:CtlLog)[-1]
        $ui.ChgStopBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    & $add 'v4.3.18 STOP result: stop_charging (dry run), bar shows NOT CHARGING' @() {
        $new = @(& $script:New4318 $script:N4318)
        $script:View = (& $script:Fake4318 'Charging' $true); Render-View; $window.UpdateLayout()
        $script:SelfRec.v4318.stop = [ordered]@{ prompt = @($script:ConfirmPrompts)[-1]; cmds = @($new | ForEach-Object { $_.cmd + ':' + $(if ($_.dryRun) { 'dryRun' } else { 'REAL' }) + ':' + $(if ($_.ok) { 'ok' } else { 'FAIL' }) }); result = $script:CtlResultText; after = (& $script:Rec4318) }
        & $script:Shot4318 'after-stop' }
    & $add 'v4.3.18 START from the status bar (DRY RUN)' @() {
        & $script:State4318 'startBefore' 'Stopped' $false ''; $script:N4318 = @($script:CtlLog)[-1]
        $ui.ChgStartBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    & $add 'v4.3.18 START result: start_charging (dry run), bar shows CHARGING' @() {
        $new = @(& $script:New4318 $script:N4318)
        $script:View = (& $script:Fake4318 'Stopped' $false); Render-View; $window.UpdateLayout()
        $script:SelfRec.v4318.start = [ordered]@{ cmds = @($new | ForEach-Object { $_.cmd + ':' + $(if ($_.dryRun) { 'dryRun' } else { 'REAL' }) + ':' + $(if ($_.ok) { 'ok' } else { 'FAIL' }) }); result = $script:CtlResultText; after = (& $script:Rec4318) }
        & $script:Shot4318 'after-start' }
    & $add 'v4.3.18 back to the real view' @() { $script:CtlOverride.Remove('chargingState'); $script:View = $script:Orig4318; Render-View; $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout(); $script:SelfRec.v4318.real = (& $script:Rec4318); & $script:Shot4318 'real' }
    # ---- v4.3.18 SKIP CONFIRM: each checkbox, unchecked (asks, answer NO, nothing sent) and checked (no pop-up, runs, DRY RUN); saved across restarts ----
    $script:SelfRec.v4318.skip = [ordered]@{ defaults = (Get-SkipCfCfg); uiDefaults = [ordered]@{}; actions = [ordered]@{} }
    foreach ($k in $SkipCfKeys) { $script:SelfRec.v4318.skip.uiDefaults[$k] = [bool]$ui['SkipCf_' + $k].IsChecked }
    $script:SkDefs = @(
        [pscustomobject]@{ key = 'unlock'; cmd = 'unlock'; prep = { Set-CtlOverride 'locked' $true }; act = { Invoke-LockToggle } }
        [pscustomobject]@{ key = 'vent'; cmd = 'vent_windows'; prep = { Set-CtlOverride 'windowsOpen' $false }; act = { Invoke-Vent } }
        [pscustomobject]@{ key = 'trunk'; cmd = 'activate_rear_trunk'; prep = { Set-CtlOverride 'trunkOpen' $false }; act = { Invoke-Trunk } }
        [pscustomobject]@{ key = 'sentry'; cmd = 'disable_sentry'; prep = { Set-CtlOverride 'sentry' $true }; act = { Invoke-SentryToggle } }
        [pscustomobject]@{ key = 'flash'; cmd = 'flash'; prep = { $ui.FlashCount.Text = '1'; $ui.FlashPause.Text = '1.0' }; act = { Invoke-FlashLights } }
        [pscustomobject]@{ key = 'stopCharging'; cmd = 'stop_charging'; prep = { Set-CtlOverride 'chargingState' 'Charging'; Render-View }; act = { $ui.ChgStopBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } }
        [pscustomobject]@{ key = 'limit'; cmd = 'set_charge_limit'; prep = { }; act = { $b = Get-LimitBounds; $p = $(if ($null -ne $script:BarLimitShown -and [int]$script:BarLimitShown -eq 75) { 70 } else { 75 }); $p = [math]::Max($b[0], [math]::Min($b[1], $p)); [void](Request-ChargeLimit $p) } }
        [pscustomobject]@{ key = 'amps'; cmd = 'set_charging_amps'; prep = { }; act = { $c = Get-ShownAmps; $b = Get-AmpsBounds; [void](Request-ChargeAmps $(if ($null -eq $c) { $b[1] - 1 } elseif ([int]$c -gt $b[0]) { [int]$c - 1 } else { [int]$c + 1 })) } }
        [pscustomobject]@{ key = 'announce'; cmd = ''; prep = { }; act = { [void](Invoke-AnnounceNow) } }
        [pscustomobject]@{ key = 'leave'; cmd = 'start_climate'; prep = { Set-CtlOverride 'climateOn' $false; Set-CtlOverride 'locked' $true }; act = { Start-LeaveSoon; & $script:Wait4315 { -not $script:Leave.running -and $null -eq $script:Leave.job } } }
    )
    $script:SkI = 0
    $script:SkStart = {
        $d = $script:SkDefs[$script:SkI]; & $d.prep
        $script:SkRef = @($script:CtlLog)[-1]; $script:SkP0 = @($script:ConfirmPrompts).Count; $script:SkA0 = @($script:AnnLog).Count; $script:SkS0 = @($script:SkipCfLog).Count
        & $d.act }
    $script:SkRes = { param($on)
        $d = $script:SkDefs[$script:SkI]; $new = @(& $script:New4318 $script:SkRef)
        [ordered]@{ checked = [bool]$ui['SkipCf_' + $d.key].IsChecked; prompts = @(@($script:ConfirmPrompts) | Select-Object -Skip $script:SkP0); skipped = (@($script:SkipCfLog).Count - $script:SkS0)
            cmds = @($new | ForEach-Object { $_.cmd + ':' + $(if ($_.dryRun) { 'dryRun' } else { 'REAL' }) + ':' + $(if ($_.ok) { 'ok' } else { 'FAIL' }) }); result = $script:CtlResultText
            pass = $(if ($on) { (@(@($script:ConfirmPrompts) | Select-Object -Skip $script:SkP0).Count -eq 0) -and $(if ($d.cmd) { @($new | Where-Object { $_.cmd -eq $d.cmd -and $_.dryRun }).Count -ge 1 } else { $script:CtlResultText -like '*rundown composed*' }) } else { (@(@($script:ConfirmPrompts) | Select-Object -Skip $script:SkP0).Count -eq 1) -and $new.Count -eq 0 }) } }
    foreach ($d0 in $script:SkDefs) {
        & $add ('v4.3.18 skip confirm OFF: ' + $d0.key + ' asks first (answer NO, nothing sent)') @($false) {
            $d = $script:SkDefs[$script:SkI]; $script:SelfRec.v4318.skip.actions[$d.key] = [ordered]@{}
            Set-SkipConfirm $d.key $false; & $script:SkStart }
        & $add ('v4.3.18 skip confirm OFF: ' + $d0.key + ' result') @() { $d = $script:SkDefs[$script:SkI]; $script:SelfRec.v4318.skip.actions[$d.key].off = (& $script:SkRes $false) }
        & $add ('v4.3.18 skip confirm ON: tick the ' + $d0.key + ' checkbox, runs with no pop-up (DRY RUN)') @() {
            $d = $script:SkDefs[$script:SkI]; $ui['SkipCf_' + $d.key].IsChecked = $true; $script:SelfRec.v4318.skip.actions[$d.key].savedOn = [bool](Get-SkipCfCfg)[$d.key]; & $script:SkStart }
        & $add ('v4.3.18 skip confirm ON: ' + $d0.key + ' result') @() { $d = $script:SkDefs[$script:SkI]; $script:SelfRec.v4318.skip.actions[$d.key].on = (& $script:SkRes $true); $script:SkI++ }
    }
    & $add 'v4.3.18 skip confirm: all checked, saved (restart reads them back), snapshot' @() {
        $window.UpdateLayout(); Render-SkipCf
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:SelfRec.v4318.skip.savedAllOn = [ordered]@{ config = $raw.skipConfirm; reload = (Get-SkipCfCfg); allOn = (@($SkipCfKeys | Where-Object { -not [bool](Get-SkipCfCfg)[$_] }).Count -eq 0) }
        $script:CtlOverride.Remove('chargingState'); $script:View = $script:Orig4318; Render-View; $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout()
        & $script:Shot4318 'skip-confirm-on'; & $script:ElPng4318 $ui.CtlCard 'skip-confirm-controls'
        $p = $ui.SkipCfRow.TranslatePoint([System.Windows.Point]::new(0, 0), $ui.BodyScroll)
        $script:SelfRec.v4318.skip.rowVisible = ($ui.SkipCfRow.IsVisible -and $p.Y -ge -0.5 -and ($p.Y + $ui.SkipCfRow.ActualHeight) -le $ui.BodyScroll.ViewportHeight + 0.5); $script:SelfRec.v4318.skip.rowHeight = [math]::Round($ui.SkipCfRow.ActualHeight, 1) }
    & $add 'v4.3.18 skip confirm: untick all (back to asking), saved' @() {
        foreach ($k in $SkipCfKeys) { $ui['SkipCf_' + $k].IsChecked = $false }
        $script:SelfRec.v4318.skip.savedAllOff = [ordered]@{ reload = (Get-SkipCfCfg); allOff = (@($SkipCfKeys | Where-Object { [bool](Get-SkipCfCfg)[$_] }).Count -eq 0) }
        $script:CtlOverride.Remove('chargingState'); $script:View = $script:Orig4318; Render-View; $window.UpdateLayout(); & $script:ElPng4318 $ui.CtlCard 'skip-confirm-off'
        $acts = $script:SelfRec.v4318.skip.actions; $script:SelfRec.v4318.skip.allPass = (@($acts.Keys | Where-Object { -not ($acts[$_].off.pass -and $acts[$_].on.pass -and $acts[$_].savedOn) }).Count -eq 0) -and $script:SelfRec.v4318.skip.savedAllOn.allOn -and $script:SelfRec.v4318.skip.savedAllOff.allOff }
    # ---- v4.3.19 (DRY RUN: nothing is sent to the car, nothing announced) ----
    $script:SelfRec.v4319 = [ordered]@{ appVersion = $AppVersion; footer = $ui.FooterVersion.Text; footerBrand = $ui.FooterText.Text; footerBold = [string]$ui.FooterText.FontWeight; width = $winW }
    $script:Shot4319 = { param($n) $f = 'tessdesk-v4319-' + $n + '.png'; Save-RootPng (Join-Path $script:SelfDir $f); $script:SelfRec.shots += $f }
    $script:ElPng4319 = { param($el, $n)
        $window.UpdateLayout(); $sc = 2.0; $w = [int][math]::Ceiling($el.ActualWidth * $sc); $h = [int][math]::Ceiling($el.ActualHeight * $sc)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $sc), (96 * $sc), [System.Windows.Media.PixelFormats]::Pbgra32)
        $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
        $dc.DrawRectangle((T 'CardBg'), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight))
        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($el)), $null, [System.Windows.Rect]::new(0, 0, $el.ActualWidth, $el.ActualHeight)); $dc.Close(); $bmp.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $f = 'tessdesk-v4319-' + $n + '.png'; $fs = [IO.File]::Create((Join-Path $script:SelfDir $f)); try { $enc.Save($fs) } finally { $fs.Close() }; $script:SelfRec.shots += $f }
    $script:Car4319 = {
        param([int]$Soc, [int]$Lim, [string]$State, $Locked, $WinOpen, $Sentry, [double]$Range, [double]$Fr, [double]$Other = 42)
        [pscustomobject]@{ socPct = $Soc; limitPct = $Lim; chargingState = $State; lat = 36.10364; lon = -96.03282; locked = $Locked; windowsOpen = $WinOpen; sentry = $Sentry; rangeMi = $Range; atEpoch = (ConvertTo-EpochLocal (Get-Now4319))
            fl = $Other; fr = $Fr; rl = $Other; rr = $Other }
    }
    & $add 'v4.3.19 pure checks: plug reminder, trips, rate, ready check, bill match, health + tips' @() {
    # ---- plug-in reminder conditions ----
    $cfgP = Get-PlugCfg
    $casesP = @(
        @('evening, home, unplugged, under the limit', 21, 55, 80, 'Disconnected', $true, $true, $true),
        @('exactly at the limit: no reminder', 21, 80, 80, 'Disconnected', $true, $true, $false),
        @('above the limit: no reminder', 21, 90, 80, 'Disconnected', $true, $true, $false),
        @('daytime: no reminder', 14, 55, 80, 'Disconnected', $true, $true, $false),
        @('not at home: no reminder', 21, 55, 80, 'Disconnected', $false, $true, $false),
        @('plugged in (charging): no reminder', 21, 55, 80, 'Charging', $true, $true, $false),
        @('plugged in (complete): no reminder', 21, 55, 80, 'Complete', $true, $true, $false),
        @('reminder switched off: no reminder', 21, 55, 80, 'Disconnected', $true, $false, $false)
    )
    $gotP = @()
    foreach ($c in $casesP) {
        $cfgP.enabled = [bool]$c[6]
        $car = [pscustomobject]@{ socPct = $c[2]; limitPct = $c[3]; chargingState = $c[4] }
        $r = Get-PlugReminder $car (Get-Date '2026-10-08').AddHours($c[1]) $cfgP $c[5]
        $gotP += [ordered]@{ case = $c[0]; show = [bool]$r.show; why = $r.why; target = $r.target; pass = ([bool]$r.show -eq [bool]$c[7]) }
    }
    # threshold mode uses the threshold instead of the limit
    $cfgP.mode = 'threshold'; $cfgP.thresholdPct = 60; $cfgP.enabled = $true
    $rT = Get-PlugReminder ([pscustomobject]@{ socPct = 62; limitPct = 80; chargingState = 'Disconnected' }) (Get-Date '2026-10-08').AddHours(21) $cfgP $true
    $gotP += [ordered]@{ case = 'threshold mode: 62% is over the 60% threshold'; show = [bool]$rT.show; pass = (-not $rT.show -and $rT.target -eq 60) }
    $script:SelfRec.v4319.plugCases = $gotP
    # ---- trips: grouping, cost math, inefficient flag (pure functions, fixed data) ----
    $script:NowT4319 = Get-Date '2026-10-08 15:00'
    $e1 = ConvertTo-EpochLocal (Get-Date '2026-10-08 08:10'); $e2 = ConvertTo-EpochLocal (Get-Date '2026-10-08 12:30'); $e3 = ConvertTo-EpochLocal (Get-Date '2026-10-07 09:00'); $e4 = ConvertTo-EpochLocal (Get-Date '2026-10-01 18:00')
    $script:TripsT4319 = @(
        [pscustomobject]@{ id = 1; startEpoch = $e1; endEpoch = ($e1 + 1500); minutes = 25; from = 'Home'; to = 'Store'; miles = 12.0; kwh = 3.0 },
        [pscustomobject]@{ id = 2; startEpoch = $e2; endEpoch = ($e2 + 600); minutes = 10; from = 'Store'; to = 'Home'; miles = 12.0; kwh = 6.0 },
        [pscustomobject]@{ id = 3; startEpoch = $e3; endEpoch = ($e3 + 1800); minutes = 30; from = 'Home'; to = 'Work'; miles = 20.0; kwh = 5.0 },
        [pscustomobject]@{ id = 4; startEpoch = $e4; endEpoch = ($e4 + 900); minutes = 15; from = 'A'; to = 'B'; miles = 8.0; kwh = 2.0 }
    )
    $rateT = 0.10
    $v7 = Get-TripView $script:TripsT4319 $script:NowT4319 7 $rateT; $v30 = Get-TripView $script:TripsT4319 $script:NowT4319 30 $rateT
    $dToday = @($v7.days | Where-Object { $_.label -eq 'Today' }); $dYest = @($v7.days | Where-Object { $_.label -eq 'Yesterday' })
    $bad = @($dToday[0].trips | Where-Object { $_.inefficient })
    $script:SelfRec.v4319.trips = [ordered]@{
        days7 = @($v7.days | ForEach-Object { $_.label }); hiddenIn7 = $v7.older; shownIn30 = $v30.days.Count
        todayTrips = $dToday[0].n; todayMiles = $dToday[0].miles; todayCost = [math]::Round($dToday[0].cost, 2)
        yestTrips = $dYest[0].n; sum7 = $v7.sum7
        inefficient = @($bad | ForEach-Object { '{0}->{1} {2:N1} mi/kWh' -f $_.from, $_.to, $_.mpk })
        refMpk = [math]::Round([double]$v7.refMpk, 3)
        pass = ($v7.days.Count -eq 2 -and $v7.older -eq 1 -and $v30.days.Count -eq 3 -and $dToday[0].n -eq 2 -and [math]::Round($dToday[0].cost, 2) -eq 0.90 -and $bad.Count -eq 1 -and $v7.sum7.trips -eq 3 -and [math]::Round($v7.sum7.miles, 1) -eq 44.0 -and [math]::Round($v7.sum7.cost, 2) -eq 1.40 -and [math]::Round([double]$v7.sum7.avgMpk, 2) -eq 3.14)
    }
    # rate: home average over the last 30 days, else the PSO overnight rate
    $nowE = ConvertTo-EpochLocal $script:NowT4319
    $ss = @(
        [pscustomobject]@{ startEpoch = ($nowE - 5 * 86400); kwhAdded = 10.0; kwhWall = 11.0; costUsdAllIn = 1.0; fast = $false; paidUsd = $null },
        [pscustomobject]@{ startEpoch = ($nowE - 10 * 86400); kwhAdded = 20.0; kwhWall = 22.0; costUsdAllIn = 3.0; fast = $false; paidUsd = $null },
        [pscustomobject]@{ startEpoch = ($nowE - 40 * 86400); kwhAdded = 100.0; kwhWall = 110.0; costUsdAllIn = 50.0; fast = $false; paidUsd = $null },
        [pscustomobject]@{ startEpoch = ($nowE - 2 * 86400); kwhAdded = 40.0; kwhWall = 40.0; costUsdAllIn = 12.0; fast = $true; paidUsd = 12.0 }
    )
    $rt = Get-TripRate $ss $nowE; $rtNone = Get-TripRate @() $nowE
    $script:SelfRec.v4319.tripRate = [ordered]@{ rate = [math]::Round($rt.rate, 4); source = $rt.source; sessions = $rt.sessions; note = $rt.note
        fallbackRate = [math]::Round($rtNone.rate, 6); fallbackSource = $rtNone.source
        pass = ([math]::Round($rt.rate, 4) -eq 0.1333 -and $rt.source -eq 'home' -and $rt.sessions -eq 2 -and $rtNone.source -eq 'pso' -and [math]::Abs($rtNone.rate - ($R_ON + $FCA)) -lt 0.000001) }
    # ---- morning ready check states ----
    $morn = Get-Date '2026-10-08 07:30'; $aft = Get-Date '2026-10-08 15:00'
    $tiresOk = [pscustomobject]@{ fl = 42; fr = 41; rl = 42; rr = 42 }; $tiresLow = [pscustomobject]@{ fl = 42; fr = 37; rl = 42; rr = 42 }
    $rc = [ordered]@{}
    $rc.allGood = Get-ReadyCheck ([pscustomobject]@{ socPct = 80; limitPct = 80; chargingState = 'Complete'; locked = $true; windowsOpen = $false; sentry = $false; rangeMi = 240 }) $tiresOk $morn
    $rc.charging = Get-ReadyCheck ([pscustomobject]@{ socPct = 60; limitPct = 80; chargingState = 'Charging'; locked = $true; windowsOpen = $false; sentry = $true; rangeMi = 180 }) $tiresOk $morn
    $rc.unlocked = Get-ReadyCheck ([pscustomobject]@{ socPct = 80; limitPct = 80; chargingState = 'Disconnected'; locked = $false; windowsOpen = $true; sentry = $false; rangeMi = 240 }) $tiresLow $aft
    $rc.doneUnplugged = Get-ReadyCheck ([pscustomobject]@{ socPct = 79.5; limitPct = 80; chargingState = 'Disconnected'; locked = $true; windowsOpen = $false; sentry = $false; rangeMi = 240 }) $tiresOk $morn
    $rc.noData = Get-ReadyCheck $null $null $morn
    $script:SelfRec.v4319.ready = [ordered]@{
        allGood = [ordered]@{ overall = $rc.allGood.overall; morning = $rc.allGood.morning; off = @($rc.allGood.off) }
        charging = [ordered]@{ overall = $rc.charging.overall; off = @($rc.charging.off); sentry = @($rc.charging.items | Where-Object { $_.key -eq 'sentry' } | ForEach-Object { $_.state + ':' + $_.text }) }
        unlocked = [ordered]@{ overall = $rc.unlocked.overall; morning = $rc.unlocked.morning; off = @($rc.unlocked.off) }
        doneUnplugged = [ordered]@{ overall = $rc.doneUnplugged.overall; off = @($rc.doneUnplugged.off) }
        noData = [ordered]@{ overall = $rc.noData.overall; items = @($rc.noData.items | ForEach-Object { $_.key + ':' + $_.state }) }
        pass = ($rc.allGood.ready -and $rc.allGood.morning -and -not $rc.charging.ready -and @($rc.charging.off | Where-Object { $_ -like 'Battery*' }).Count -eq 1 -and @($rc.charging.off | Where-Object { $_ -like 'Charging*' }).Count -eq 1 -and @($rc.charging.items | Where-Object { $_.key -eq 'sentry' -and $_.state -eq 'info' }).Count -eq 1 -and -not $rc.unlocked.morning -and @($rc.unlocked.off).Count -eq 3 -and $rc.doneUnplugged.ready -and -not $rc.noData.ready -and $rc.noData.overall -eq 'NO DATA')
    }
    # ---- bill match math + mismatch flag + switch default ----
    $pso = $R_ON + $FCA
    $billSs = @(
        [pscustomobject]@{ startEpoch = (ConvertTo-EpochLocal (Get-Date '2026-09-05')); endEpoch = (ConvertTo-EpochLocal (Get-Date '2026-09-05 06:00')); kwhWall = 30.0; kwhAdded = 27.0; costUsdAllIn = [math]::Round(30 * $pso, 4); fast = $false; paidUsd = $null },
        [pscustomobject]@{ startEpoch = (ConvertTo-EpochLocal (Get-Date '2026-09-20')); endEpoch = (ConvertTo-EpochLocal (Get-Date '2026-09-20 06:00')); kwhWall = 20.0; kwhAdded = 18.0; costUsdAllIn = [math]::Round(20.4 * $pso, 4); fast = $false; paidUsd = $null },
        [pscustomobject]@{ startEpoch = (ConvertTo-EpochLocal (Get-Date '2026-08-01')); endEpoch = (ConvertTo-EpochLocal (Get-Date '2026-08-01 06:00')); kwhWall = 99.0; kwhAdded = 90.0; costUsdAllIn = 9.0; fast = $false; paidUsd = $null },
        [pscustomobject]@{ startEpoch = (ConvertTo-EpochLocal (Get-Date '2026-09-10')); endEpoch = (ConvertTo-EpochLocal (Get-Date '2026-09-10 01:00')); kwhWall = 40.0; kwhAdded = 40.0; costUsdAllIn = 12.0; fast = $true; paidUsd = 12.0 }
    )
    $bm = Get-BillMatch ([pscustomobject]@{ from = '2026-09-01'; to = '2026-09-30'; kwh = 500; usd = 100 }) $billSs $pso $EFFICIENCY
    $bmBad = Get-BillMatch ([pscustomobject]@{ from = '2026-09-01'; to = '2026-09-30'; kwh = 500; usd = 100 }) @([pscustomobject]@{ startEpoch = (ConvertTo-EpochLocal (Get-Date '2026-09-05')); kwhWall = 100.0; kwhAdded = 90.0; costUsdAllIn = 20.0; fast = $false; paidUsd = $null }) $pso $EFFICIENCY
    $bmNeed = Get-BillMatch ([pscustomobject]@{ from = ''; to = ''; kwh = $null; usd = 442.21 }) @() $pso $EFFICIENCY
    $script:SelfRec.v4319.bill = [ordered]@{
        kwh = $bm.teslaKwh; sharePct = $bm.sharePct; shareUsd = $bm.shareUsd; estPso = $bm.estPsoUsd; tracked = $bm.trackedUsd; diffPct = $bm.diffPct; mismatch = [bool]$bm.mismatch; sessions = $bm.sessions; ok = [bool]$bm.ok
        mismatchCase = [ordered]@{ diffPct = $bmBad.diffPct; mismatch = [bool]$bmBad.mismatch }
        missing = @($bmNeed.need); switchDefault = [bool](& { $k = $script:Cfg; $script:Cfg = [pscustomobject]@{}; try { (Get-BillCfg).enabled } finally { $script:Cfg = $k } }); plugDefault = [bool](& { $k = $script:Cfg; $script:Cfg = [pscustomobject]@{}; try { (Get-PlugCfg).enabled } finally { $script:Cfg = $k } })
        pass = ($bm.teslaKwh -eq 50 -and $bm.sessions -eq 2 -and $bm.sharePct -eq 10 -and $bm.shareUsd -eq 10 -and [math]::Abs($bm.trackedUsd - [math]::Round(50.4 * $pso, 2)) -lt 0.011 -and -not $bm.mismatch -and $bmBad.mismatch -and [math]::Abs($bm.estPsoUsd - [math]::Round(50 * $pso, 2)) -lt 0.001 -and @($bmNeed.need).Count -eq 3 -and (Get-BillCfg).enabled -and (Get-PlugCfg).enabled)
    }
    # ---- battery health trend (mocked history) + tips grounded in data ----
    $series = @([pscustomobject]@{ d = '2026-03-17'; range = 279.0 }, [pscustomobject]@{ d = '2026-06-01'; range = 276.0 }, [pscustomobject]@{ d = '2026-10-01'; range = 273.0 })
    $tr = Get-HealthTrend $series
    $script:HMock4319 = [pscustomobject]@{ healthPct = 84.1; capacity = 66.28; original = 78.83; maxRange = 274.25; at = (ConvertTo-EpochLocal $script:NowT4319); points = $series }
    $script:OwnHealthMock = @([pscustomobject]@{ d = '2026-10-02'; range = 273.5 })
    $merged = Get-HealthSeries $script:HMock4319 $script:OwnHealthMock
    $tipsIn = Get-BatteryTips @(
        [pscustomobject]@{ startEpoch = ($nowE - 20 * 86400); endEpoch = ($nowE - 20 * 86400 + 3600); socStartPct = 30; socEndPct = 100; fast = $false; paidUsd = $null },
        [pscustomobject]@{ startEpoch = ($nowE - 10 * 86400); endEpoch = ($nowE - 10 * 86400 + 3600); socStartPct = 40; socEndPct = 100; fast = $false; paidUsd = $null },
        [pscustomobject]@{ startEpoch = ($nowE - 5 * 86400); endEpoch = ($nowE - 5 * 86400 + 3600); socStartPct = 25; socEndPct = 80; fast = $false; paidUsd = $null }
    ) ([pscustomobject]@{ limitPct = 80 }) @([pscustomobject]@{ startEpoch = ($nowE - 19 * 86400); tempF = 90 }, [pscustomobject]@{ startEpoch = ($nowE - 9 * 86400); tempF = 92 }, [pscustomobject]@{ startEpoch = ($nowE - 4 * 86400); tempF = 88 }) $script:HMock4319 $script:NowT4319
    $script:SelfRec.v4319.health = [ordered]@{ trend = [ordered]@{ from = $tr.fromRange; to = $tr.toRange; delta = $tr.deltaPct }; mergedDays = @($merged | ForEach-Object { $_.d }); tips = @($tipsIn)
        pass = ($tr.fromRange -eq 279 -and $tr.toRange -eq 273 -and $tr.deltaPct -lt 0 -and $merged.Count -eq 4 -and @($tipsIn | Where-Object { $_ -like '*100%*' }).Count -ge 1 -and @($tipsIn | Where-Object { $_ -like '*No Supercharging*' -or $_ -like '*Supercharging*' }).Count -ge 1) }
    $script:OwnHealthMock = $null
    }
    # ---- UI: bill switch collapses, plug switch, trips show more remembered, width guard ----
    & $add 'v4.3.19 UI: bill switch OFF collapses to one row, ON shows it again (saved)' @() {
        $ui.BillSwitch.IsChecked = $false; $window.UpdateLayout()
        $off = [ordered]@{ visible = [string]$ui.BillBody.Visibility; text = $ui.BillHdr.Text; saved = [bool](Get-BillCfg).enabled }
        try { & $script:ElPng4319 $ui.BattCard 'battery-bill-off' } catch {}
        $ui.BillSwitch.IsChecked = $true; $window.UpdateLayout()
        try { & $script:ElPng4319 $ui.BattCard 'battery-bill-on' } catch {}
        $script:SelfRec.v4319.billSwitch = [ordered]@{ off = $off; onVisible = [string]$ui.BillBody.Visibility; savedOn = [bool](Get-BillCfg).enabled
            pass = (-not $off.saved -and [string]$off.visible -eq 'Collapsed' -and $off.text -eq 'PSO BILL MATCH' -and [string]$ui.BillBody.Visibility -eq 'Visible' -and (Get-BillCfg).enabled) } }
    & $add 'v4.3.19 UI: plug-in reminder switch off/on (saved) and the evening bar' @() {
        foreach ($mk in 'plug-reminder', 'ready-check') { Remove-Item -LiteralPath (Get-MarkPath4319 $mk) -Force -ErrorAction SilentlyContinue }
        $script:Toast4319 = @(); $script:Keep4319 = @($script:View.car, $script:View.tires, $script:State.health)
        $script:Now4319 = Get-Date '2026-10-08 21:30'
        $script:View.car = [pscustomobject]@{ socPct = 55; limitPct = 80; chargingState = 'Disconnected'; lat = 36.10364; lon = -96.03282; locked = $true; windowsOpen = $false; sentry = $false; rangeMi = 160; atEpoch = (ConvertTo-EpochLocal $script:Now4319) }
        Render-V4319; $window.UpdateLayout()
        $on = [ordered]@{ bar = [string]$ui.PlugRemBar.Visibility; word = $ui.PlugRemTxt.Text; toasts = @($script:Toast4319) }
        $ui.PlugRemSwitch.IsChecked = $false; $window.UpdateLayout()
        $off = [ordered]@{ bar = [string]$ui.PlugRemBar.Visibility; saved = [bool](Get-PlugCfg).enabled }
        $ui.PlugRemSwitch.IsChecked = $true; $window.UpdateLayout()
        $again = @($script:Toast4319).Count
        $script:SelfRec.v4319.plugUi = [ordered]@{ on = $on; off = $off; toastsAfterReenable = $again; savedBack = [bool](Get-PlugCfg).enabled
            pass = ([string]$on.bar -eq 'Visible' -and $on.word -eq 'PLUG IN TONIGHT' -and $on.toasts.Count -eq 1 -and [string]$off.bar -eq 'Collapsed' -and -not $off.saved -and $again -eq 1 -and (Get-PlugCfg).enabled) }
        $script:Now4319 = $null }
    & $add 'v4.3.19 UI: trips card groups days, show more is remembered' @() {
        $st = $script:State
        $keep = $st.trips; $keepF = $st.drivesFetchEpoch
        $st.trips = $script:TripsT4319; $st.drivesFetchEpoch = ConvertTo-EpochLocal (Get-Date '2026-10-08 14:55'); $script:TripsSig = ''
        $script:Now4319 = $script:NowT4319
        Set-TripsOpen $false; $window.UpdateLayout()
        $n7 = $ui.TripsList.Children.Count; $txt7 = $ui.TripsMoreTxt.Text; $sum = $ui.TripsS0.Text + '/' + $ui.TripsS1.Text + '/' + $ui.TripsS3.Text + '/' + $ui.TripsS4.Text
        Set-TripsOpen $true; $window.UpdateLayout()
        $n30 = $ui.TripsList.Children.Count; $txt30 = $ui.TripsMoreTxt.Text
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:SelfRec.v4319.tripsUi = [ordered]@{ children7 = $n7; more7 = $txt7; sum7 = $sum; children30 = $n30; more30 = $txt30; saved = [bool]$raw.trips.expanded; rateNote = $ui.TripsRate.Text
            pass = ($n30 -gt $n7 -and $txt7 -like 'Show more*' -and $txt30 -like 'Show less*' -and [bool]$raw.trips.expanded -and $ui.TripsS0.Text -eq '3') }
        $st.trips = $keep; $st.drivesFetchEpoch = $keepF; $script:TripsSig = ''; $script:Now4319 = $null; Set-TripsOpen $false; Render-V4319 }
    & $add 'v4.3.19 UI: ready check, bill match and health render from the view' @() {
        $script:Now4319 = Get-Date '2026-10-08 07:30'
        $script:View.car = [pscustomobject]@{ socPct = 60; limitPct = 80; chargingState = 'Charging'; lat = 36.10364; lon = -96.03282; locked = $false; windowsOpen = $true; sentry = $false; rangeMi = 170; atEpoch = (ConvertTo-EpochLocal $script:Now4319) }
        $script:View.tires = [pscustomobject]@{ fl = 42; fr = 37; rl = 42; rr = 42 }
        $script:State.health = $script:HMock4319
        Render-V4319; $window.UpdateLayout()
        $script:SelfRec.v4319.rendered = [ordered]@{ ready = $ui.ReadyPillTxt.Text; morning = ($ui.ReadyHdr.Text -eq 'MORNING READY CHECK'); off = $ui.ReadyOff.Text; grid = $ui.ReadyGrid.Children.Count
            health = $ui.HealthPct.Text; cap = $ui.HealthL1.Text; trend = $ui.HealthTrend.Text; spark = $ui.HealthLine.Points.Count; tips = $ui.TipsList.Children.Count
            bill = $ui.BillRes1.Text; billSrc = $ui.BillSrc.Text
            pass = ($ui.ReadyPillTxt.Text -eq 'CHECK' -and $ui.ReadyGrid.Children.Count -ge 4 -and $ui.HealthPct.Text -eq '84.1%' -and $ui.HealthLine.Points.Count -ge 2 -and $ui.TipsList.Children.Count -ge 1 -and $ui.BillSrc.Text -like '*442.21*') }
        & $script:ElPng4319 $ui.BattCard 'battery'; & $script:ElPng4319 $ui.TripsCard 'trips'
        $script:Now4319 = $null }
    & $add 'v4.3.19 UI: bill numbers save and the mismatch flag shows' @() {
        $keep = $script:State.recentSessions
        $script:State.recentSessions = @([pscustomobject]@{ source = 'tessie'; startEpoch = (ConvertTo-EpochLocal (Get-Date '2026-09-10')); endEpoch = (ConvertTo-EpochLocal (Get-Date '2026-09-10 06:00')); kwhWall = 100.0; kwhAdded = 90.0; costUsdAllIn = 30.0; fast = $false; paidUsd = $null; home = '3515 W 41st Pl'; socStartPct = 30; socEndPct = 80 })
        $ui.BillFrom.Text = '9/1/2026'; $ui.BillTo.Text = '9/30/2026'; $ui.BillKwh.Text = '500'; $ui.BillUsd.Text = '100'
        $ui.BillSaveBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:SelfRec.v4319.billSave = [ordered]@{ saved = [ordered]@{ from = [string]$raw.billMatch.from; to = [string]$raw.billMatch.to; kwh = $raw.billMatch.kwh; usd = $raw.billMatch.usd }; flag = [string]$ui.BillFlag.Visibility; res = $ui.BillRes1.Text
            pass = ([string]$raw.billMatch.from -eq '2026-09-01' -and [double]$raw.billMatch.kwh -eq 500 -and [string]$ui.BillFlag.Visibility -eq 'Visible' -and $ui.BillRes1.Text -like '*100.0 kWh*') }
        $script:State.recentSessions = $keep }
    & $add 'v4.3.19 width: saved 364 becomes 473 (right edge kept), and a width drop is corrected' @() {
        $l0 = $window.Left; $window.Left = 1500; Set-TdSpot ([pscustomobject]@{ left = 1500; top = $window.Top; width = 364; height = $window.Height })
        $after = [ordered]@{ left = $window.Left; width = $window.Width }
        $window.Width = 400; $window.UpdateLayout()
        $dropped = $window.Width
        $window.Dispatcher.Invoke([Action]{}, 'Background')
        $script:SelfRec.v4319.width = [ordered]@{ after = $after; droppedTo = $dropped; corrected = $window.Width
            pass = ([math]::Abs($after.left - (1500 - (473 - 364))) -lt 1 -and [math]::Abs($after.width - 473) -lt 1 -and [math]::Abs($window.Width - 473) -lt 1) }
        $window.Left = $l0 }
    & $add 'v4.3.19 layout: Leaving Soon waits row (Start after, Windows after, Unlock after) fits inside TESLA CONTROLS at 473 px' @() {
        $window.UpdateLayout()
        $row = $ui.LeaveWaitRow; $fit = $ui.LeaveWaitFit
        $scale = $(if ($row.ActualWidth -gt 0) { [math]::Round($fit.ActualWidth / $row.ActualWidth, 3) } else { 0 })
        $pf = $fit.TransformToAncestor($ui.CtlCard).Transform((New-Object System.Windows.Point(0, 0)))
        $script:SelfRec.v4319.waitsFit = [ordered]@{ rowW = [math]::Round($row.ActualWidth, 1); shownW = [math]::Round($fit.ActualWidth, 1); scale = $scale; leftInCard = [math]::Round($pf.X, 1); cardW = [math]::Round($ui.CtlCard.ActualWidth, 1)
            pass = ($scale -ge 0.9 -and $pf.X -ge 0 -and ($pf.X + $fit.ActualWidth) -le ($ui.CtlCard.ActualWidth + 0.5)) }
        try { & $script:ElPng4319 $ui.CtlCard 'controls-waits' } catch {} }
    # ---- LEAVING SOON: Start after (0 and non-zero, Stop during the countdown) ----
    & $add 'v4.3.19 Start after 0: the sequence begins right away (DRY RUN)' @($true) {
        Set-LeaveMin $ui.LeaveStartMin 0; Set-LeaveMin $ui.LeaveWinMin 1; Set-LeaveMin $ui.LeaveUnlockMin 1
        Set-CtlOverride 'climateOn' $false; Set-CtlOverride 'locked' $true; Set-CtlOverride 'windowsOpen' $true
        $script:N4319 = @($script:CtlLog)[-1]; $script:A4319 = @($script:AnnLog).Count
        Start-LeaveSoon
        & $script:Wait4315 { -not $script:Leave.running -and $null -eq $script:Leave.job } }
    & $add 'v4.3.19 Start after 0: result (no pre phase, 3 dry-run steps)' @() {
        $new = @(& $script:New4318 $script:N4319)
        $seen = @($script:LeaveSeen)
        $script:SelfRec.v4319.start0 = [ordered]@{ phase = $script:Leave.phase; result = $script:Leave.result; seen = @($seen | Select-Object -First 6)
            cmds = @($new | ForEach-Object { $_.cmd + ':' + $(if ($_.dryRun) { 'dryRun' } else { 'REAL' }) }); anns = (@($script:AnnLog).Count - $script:A4319)
            pass = (@($seen | Where-Object { $_ -like 'Starting in*' }).Count -eq 0 -and @($new | Where-Object { $_.cmd -eq 'start_climate' -and $_.dryRun }).Count -eq 1 -and $script:Leave.result -like 'Leaving Soon done*') } }
    & $add 'v4.3.19 Start after 2 min: countdown shows Starting in mm:ss (DRY RUN)' @($true) {
        Set-LeaveMin $ui.LeaveStartMin 2
        $script:N4319b = @($script:CtlLog)[-1]
        Start-LeaveSoon
        & $script:Wait4315 { @($script:LeaveSeen | Where-Object { $_ -like 'Starting in*' }).Count -ge 1 } }
    & $add 'v4.3.19 Start after: STOP during the countdown cancels with nothing to undo' @() {
        try { $window.UpdateLayout(); & $script:ElPng4319 $ui.CtlCard 'leave-countdown' } catch {}
        Stop-LeaveSoon
        $new = @(& $script:New4318 $script:N4319b)
        $script:SelfRec.v4319.startStop = [ordered]@{ phase = $script:Leave.phase; result = $script:Leave.result; text = $ui.LeaveStep.Text; commands = @($new).Count
            saved = [int](Get-LeaveCfg).startAfterMin
            pass = ($script:Leave.result -like '*cancelled before it started*nothing to undo*' -and @($new).Count -eq 0 -and [int](Get-LeaveCfg).startAfterMin -eq 2) } }
    & $add 'v4.3.19 Start after 2 min: the sequence runs after the countdown (DRY RUN)' @($true) {
        Set-LeaveMin $ui.LeaveStartMin 2
        $script:N4319c = @($script:CtlLog)[-1]; $script:LeaveSeen = @()
        Start-LeaveSoon
        & $script:Wait4315 { -not $script:Leave.running -and $null -eq $script:Leave.job } }
    & $add 'v4.3.19 Start after 2 min: result (countdown then the 3 steps)' @() {
        $new = @(& $script:New4318 $script:N4319c)
        $script:SelfRec.v4319.start2 = [ordered]@{ result = $script:Leave.result; sawStarting = (@($script:LeaveSeen | Where-Object { $_ -like 'Starting in*' }).Count -gt 0)
            firstSeen = @($script:LeaveSeen | Select-Object -First 3); cmds = @($new | ForEach-Object { $_.cmd + ':' + $(if ($_.dryRun) { 'dryRun' } else { 'REAL' }) })
            confirm = @($script:ConfirmPrompts | Select-Object -Last 1)
            pass = (@($script:LeaveSeen | Where-Object { $_ -like 'Starting in*' }).Count -gt 0 -and @($new).Count -eq 3 -and @($new | Where-Object { -not $_.dryRun }).Count -eq 0 -and $script:Leave.result -like 'Leaving Soon done*' -and @($script:ConfirmPrompts | Select-Object -Last 1) -like '*Starts in 2 minutes*') }
        Set-LeaveMin $ui.LeaveStartMin 0; Set-LeaveMin $ui.LeaveWinMin 3; Set-LeaveMin $ui.LeaveUnlockMin 3
        & $script:Shot4319 'controls'; & $script:ElPng4319 $ui.CtlCard 'controls' }
    & $add 'v4.3.19 summary' @() {
        $r = $script:SelfRec.v4319
        $fails = @()
        foreach ($k in 'trips', 'tripRate', 'ready', 'bill', 'health') { if (-not $r[$k].pass) { $fails += $k } }
        foreach ($k in 'billSwitch', 'plugUi', 'tripsUi', 'rendered', 'billSave', 'width', 'waitsFit', 'start0', 'startStop', 'start2') { if (-not $r[$k].pass) { $fails += $k } }
        $plugFail = @($r.plugCases | Where-Object { -not $_.pass })
        $r.summary = [ordered]@{ plugFails = @($plugFail | ForEach-Object { $_.case }); fails = $fails; allPass = ($plugFail.Count -eq 0 -and $fails.Count -eq 0) }
        $script:View.car = $script:Keep4319[0]; $script:View.tires = $script:Keep4319[1]; $script:State.health = $script:Keep4319[2]; $script:Now4319 = $null; $script:TripsSig = ''
        Render-View; $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout(); & $script:Shot4319 'top'
        $ui.BattCard.BringIntoView(); $window.UpdateLayout(); & $script:Shot4319 'battery-real'; & $script:ElPng4319 $ui.BattCard 'battery-real'; & $script:ElPng4319 $ui.TripsCard 'trips-real'
        $ui.BodyScroll.ScrollToVerticalOffset(0); $window.UpdateLayout() }

    & $add 'live refresh status' @() { $script:SelfRec.live = (Get-LiveStatus); $script:SelfRec.liveBadge = $ui.UpdBadge.Text; $script:SelfRec.tiresHeader = [ordered]@{ hdr = $ui.TiresHdr.Text; rec = $ui.TiresRec.Text; asOf = $ui.TiresAsOf.Text } }
    & $add 'theme snapshots' @() { Save-Snapshots $script:SelfDir; $script:SelfRec.shots += @($script:LastSnapshot.files | ForEach-Object { Split-Path -Leaf $_ }) }
    Start-SelfTimer
}
function Start-SelfTimer {
    $script:SelfTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SelfTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:SelfTimer.Add_Tick({
        try {
            if ($null -ne $script:LeaveWaitFor) { if ((Get-Date) -gt $script:LeaveWaitUntil) { $script:LeaveWaitFor = $null; $script:SelfRec.steps += 'ERROR v4.3.15 leaving soon wait timed out' } elseif (-not [bool](& $script:LeaveWaitFor)) { return } else { $script:LeaveWaitFor = $null } }
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
