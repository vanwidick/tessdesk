﻿#Requires -Version 5.1
# TessDesk v4.3 - scheduled Alexa announcement (run by a per-user Windows scheduled task "TessDesk Announce <type> <n>").
# -Type cost   : last night's / tonight's charging cost + kWh (from the widget's latest totals, widget-status.json) and the last 7 days
# -Type tires  : all four tire pressures, flags any low / high (Tessie cached state: use_cache=true, never wakes the car)
# -Type status : battery %, range, charging state, locks, windows, climate (Tessie cached state)
# Speaks it through Voice Monkey (POST https://api-v3.voicemonkey.io/announce {token, device, speech}) on every chosen speaker (default: All Echos).
# -DryRun prints the text and sends nothing. Requires consent.announcements = true in config.json and a saved Voice Monkey token.
param(
    [ValidateSet('cost', 'tires', 'status')][string]$Type = 'status',
    [switch]$DryRun,
    [string]$ConfigPath,
    [string]$StateFile,     # testing: use this Tessie state JSON instead of calling Tessie
    [string]$StatusFile     # testing: use this widget-status.json
)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $dir 'config.json' }
$logPath = Join-Path $dir 'announce.log'
function Log { param([string]$m) try { Add-Content -LiteralPath $logPath -Value ((Get-Date).ToString('s') + ' [' + $Type + '] ' + $m) -Encoding UTF8 } catch {} }
function Read-Dpapi { param([string]$p) $ss = (Get-Content -LiteralPath $p -Raw).Trim() | ConvertTo-SecureString; $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss); try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) } }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$cfg = $null; if (Test-Path -LiteralPath $ConfigPath) { $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
if ($null -eq $cfg) { $cfg = [pscustomobject]@{} }
$consentOk = ($null -ne $cfg.consent -and [bool]$cfg.consent.agreed -and [bool]$cfg.consent.readVehicleData -and [bool]$cfg.consent.announcements)
if ($null -ne $cfg.announce -and [bool]$cfg.announce.dryRun) { $DryRun = $true }

function Get-TessieState {
    if ($StateFile) { return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    $cred = [string]$cfg.tokenFile; if (-not $cred) { $cred = 'tessie.token' }
    $cred = [Environment]::ExpandEnvironmentVariables($cred); if (-not [IO.Path]::IsPathRooted($cred)) { $cred = Join-Path $dir $cred }
    $tok = $null
    if (Test-Path -LiteralPath ($cred + '.dpapi')) { $tok = Read-Dpapi ($cred + '.dpapi') }
    elseif (Test-Path -LiteralPath $cred) { $tok = ((Get-Content -LiteralPath $cred -Raw) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim() -replace '^(?i)bearer\s+', '' }
    if (-not $tok) { throw 'no Tessie token' }
    if (-not $cfg.vin) { throw 'no VIN in config.json' }
    # cached state only: never wakes the car
    return (Invoke-RestMethod -Uri ('https://api.tessie.com/' + $cfg.vin + '/state?use_cache=true') -Headers @{ Authorization = ('Bearer ' + $tok) } -TimeoutSec 20 -UseBasicParsing)
}
$unitsF = $true
function Temp { param($c) if ($null -eq $c) { return 'unknown' }; if ($unitsF) { return ('{0:N0} degrees' -f ([double]$c * 9 / 5 + 32)) }; return ('{0:0.#} degrees' -f [double]$c) }
function Money { param([string]$m) if (-not $m -or $m -notmatch '\$') { return $null }; $v = [double]($m -replace '[^0-9.]', ''); $d = [math]::Floor($v); $c = [math]::Round(($v - $d) * 100); return $(if ($d -ge 1) { ('{0} dollar{1}' -f $d, $(if ($d -eq 1) { '' } else { 's' })) + $(if ($c -gt 0) { (' and {0} cents' -f $c) } else { '' }) } else { ('{0} cents' -f $c) }) }
function Kwh { param([string]$k) if (-not $k -or $k -notmatch '[0-9]') { return $null }; return (($k -replace '[^0-9.]', '') + ' kilowatt hours') }

$text = ''
switch ($Type) {
    'cost' {
        $sp = $StatusFile; if (-not $sp) { $sp = Join-Path $dir 'widget-status.json' }
        if (-not (Test-Path -LiteralPath $sp)) { $text = 'TessDesk does not have charging totals yet. Open the TessDesk widget first.'; break }
        $st = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json
        $n = $st.rows.night; $lbl = [string]$n.label; if (-not $lbl) { $lbl = 'Last night' }
        $c = Money $n.cost; $k = Kwh $n.kwh
        if ($c) { $text = ('{0}, your Tesla charging cost {1}' -f $lbl, $c) + $(if ($k) { ' for ' + $k } else { '' }) + '.' } else { $text = ('No charging cost recorded for {0}.' -f $lbl.ToLower()) }
        $w = Money $st.rows.d7.cost; if ($w) { $text += (' The last 7 days cost {0}.' -f $w) }
        try { $age = ((Get-Date) - [datetime]$st.at).TotalHours; if ($age -gt 3) { $text += (' These totals are from {0}.' -f ([datetime]$st.at).ToString('h:mm tt', [Globalization.CultureInfo]::InvariantCulture)) } } catch {}
    }
    default {
        try { $v = Get-TessieState } catch { $text = 'TessDesk could not read your Tesla data from Tessie.'; Log ('state failed: ' + $_.Exception.Message); break }
        $cs = $v.charge_state; $vs = $v.vehicle_state; $cl = $v.climate_state
        if ($null -ne $v.gui_settings -and [string]$v.gui_settings.gui_temperature_units -eq 'C') { $unitsF = $false }
        if ($Type -eq 'tires') {
            $yel = 5.0; $red = 10.0; if ($null -ne $cfg.tires) { if ($null -ne $cfg.tires.yellowPct) { $yel = [double]$cfg.tires.yellowPct }; if ($null -ne $cfg.tires.redPct) { $red = [double]$cfg.tires.redPct } }
            $names = [ordered]@{ fl = 'front left'; fr = 'front right'; rl = 'rear left'; rr = 'rear right' }
            $parts = @(); $flags = @()
            foreach ($k in $names.Keys) {
                $bar = $vs.('tpms_pressure_' + $k); if ($null -eq $bar) { continue }
                $psi = [math]::Round([double]$bar * 14.5038)
                $rb = $(if ($k -like 'f*') { $vs.tpms_rcp_front_value } else { $vs.tpms_rcp_rear_value })
                $parts += ('{0} {1}' -f $names[$k], $psi)
                $soft = [bool]$vs.('tpms_soft_warning_' + $k); $hard = [bool]$vs.('tpms_hard_warning_' + $k)
                if ($null -ne $rb) {
                    $rec = [double]$rb * 14.5038; $dev = ([double]$bar * 14.5038 - $rec) / $rec * 100
                    if ($hard -or [math]::Abs($dev) -gt $red) { $flags += ('{0} is really {1}' -f $names[$k], $(if ($dev -gt 0 -and -not $hard) { 'high' } else { 'low' })) }
                    elseif ($soft -or [math]::Abs($dev) -gt $yel) { $flags += ('{0} is a little {1}' -f $names[$k], $(if ($dev -gt 0 -and -not $soft) { 'high' } else { 'low' })) }
                } elseif ($hard -or $soft) { $flags += ('{0} has a pressure warning' -f $names[$k]) }
            }
            if ($parts.Count -eq 0) { $text = 'Tire pressures are not available right now.' }
            else {
                $text = 'Tire pressure in PSI: ' + ($parts -join ', ') + '.'
                if ($null -ne $vs.tpms_rcp_front_value) { $text += (' Recommended is {0}.' -f [math]::Round([double]$vs.tpms_rcp_front_value * 14.5038)) }
                $text += $(if ($flags.Count -gt 0) { ' Heads up: ' + ($flags -join ', and ') + '.' } else { ' All four tires look good.' })
            }
        } else {
            $range = $cs.battery_range; if ($null -ne $v.gui_settings -and [string]$v.gui_settings.gui_range_display -eq 'Ideal' -and $cs.ideal_battery_range) { $range = $cs.ideal_battery_range }
            $text = ('Your Tesla is at {0} percent' -f $cs.battery_level) + $(if ($null -ne $range) { (', with {0:N0} miles of range' -f [double]$range) } else { '' }) + '. '
            $chs = [string]$cs.charging_state
            $text += $(switch ($chs) { 'Charging' { ('It is charging at {0} amps, up to {1} percent. ' -f $cs.charger_actual_current, $cs.charge_limit_soc) } 'Complete' { 'Charging is complete. ' } 'Stopped' { 'It is plugged in, not charging. ' } 'Disconnected' { 'It is not plugged in. ' } default { if ($chs) { 'Charging state: ' + $chs + '. ' } else { '' } } })
            if ($null -ne $vs.locked) { $text += $(if ([bool]$vs.locked) { 'It is locked. ' } else { 'It is unlocked. ' }) }
            $w = @($vs.fd_window, $vs.fp_window, $vs.rd_window, $vs.rp_window) | Where-Object { $null -ne $_ }
            if (@($w).Count -gt 0) { $text += $(if (@($w | Where-Object { [int]$_ -ne 0 }).Count -gt 0) { 'Some windows are open. ' } else { 'All windows are closed. ' }) }
            if ($null -ne $cl) { $text += $(if ([bool]$cl.is_climate_on) { 'Climate is on, set to ' + (Temp $cl.driver_temp_setting) + '.' } else { 'Climate is off' + $(if ($null -ne $cl.inside_temp) { ', and it is ' + (Temp $cl.inside_temp) + ' inside.' } else { '.' }) }) }
            try { $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]([double]$cs.timestamp / 1000); if ($age -gt 1800) { $text += (' This is from {0} minutes ago.' -f [math]::Round($age / 60)) } } catch {}
        }
    }
}
$text = $text.Trim()
# v4.3: all Echos by default (announce.speakers {all, ids} + announce.speakerList from Announce Setup / Refresh devices).
# Voice Monkey has no device groups, so each speaker gets its own /announce call. Falls back to announce.device (living room).
$dev = ''; $targets = @()
if ($null -ne $cfg.announce) {
    $dev = [string]$cfg.announce.device
    $sp = $cfg.announce.speakers; $all = $true; if ($null -ne $sp -and $null -ne $sp.all) { $all = [bool]$sp.all }
    if ($all) { $targets = @(@($cfg.announce.speakerList) | Where-Object { $null -ne $_ -and [string]$_.id } | ForEach-Object { [string]$_.id }) }
    elseif ($null -ne $sp) { $targets = @(@($sp.ids) | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
}
$targets = @($targets | Select-Object -Unique); if ($targets.Count -eq 0 -and $dev) { $targets = @($dev) }
$tp = Join-Path $dir 'voicemonkey.token.dpapi'
if ($DryRun) { Write-Output ('DRY RUN (nothing sent) -> ' + $targets.Count + ' speaker(s) "' + ($targets -join ', ') + '": ' + $text); Log ('DRY RUN -> ' + ($targets -join ', ') + ': ' + $text); exit 0 }
if (-not $consentOk) { Log 'skipped: announcement disclosure not accepted in config.json'; exit 0 }
if ($targets.Count -eq 0 -or -not (Test-Path -LiteralPath $tp)) { Log 'skipped: Voice Monkey token / speaker not set up'; exit 0 }
$tok = Read-Dpapi $tp; $okN = 0
foreach ($d in $targets) {
    try {
        $body = @{ token = $tok; device = $d; speech = $text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri 'https://api-v3.voicemonkey.io/announce' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 20 -UseBasicParsing | Out-Null
        $okN++; Log ('announced on ' + $d + ': ' + $text)
    } catch { Log ('announce failed on ' + $d + ': ' + $_.Exception.Message) }
}
if ($okN -eq 0) { exit 1 }
