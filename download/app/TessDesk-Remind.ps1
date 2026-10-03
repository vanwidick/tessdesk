﻿# TessDesk-Remind.ps1 · v4.2 · delivers a TessDesk tire reminder: email / text through YOUR OWN email account (SMTP),
# an Alexa announcement (Voice Monkey), and/or a Windows notification (config.json reminders.channels).
# Started by a one-time Windows Task Scheduler task "TessDesk Reminder <id>" created by the widget's
# "Remind me to get air" button. Texts go to your carrier's email-to-SMS gateway over the same SMTP.
# The SMTP password is stored with Windows DPAPI (smtp.secret, readable only by your Windows account).
#   -Id <id>       send reminders\<id>.json, then remove it and this reminder's scheduled task
#   -Test          send a short test message (TessDesk Setup's "Send test reminder")
#   -DryRun        compose and print the message(s) only; nothing is sent (also: reminders.dryRun in config.json)
param([string]$Id, [switch]$Test, [switch]$DryRun, [string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $dir 'config.json' }
$baseDir = Split-Path -Parent $ConfigPath
$logPath = Join-Path $baseDir 'reminders.log'
function Log { param([string]$m) $line = ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m); try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch {}; Write-Output $line }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$r = $cfg.reminders
if ($null -eq $r) { Log 'reminders are not set up'; exit 2 }
$mailOk = -not ($null -ne $cfg.consent -and -not [bool]$cfg.consent.reminders)   # email/text need consent.reminders
$annOk = ($null -ne $cfg.consent -and [bool]$cfg.consent.announcements)          # Alexa needs consent.announcements
$dry = [bool]$DryRun -or [bool]$r.dryRun

$job = $null; $jobPath = $null
if ($Test) {
    $job = [pscustomobject]@{ subject = 'TessDesk test reminder'; body = "This is a test from TessDesk.`r`nIf you got this, your tire reminders will arrive the same way."; sms = 'TessDesk test: tire reminders will arrive like this.'; dryRun = $false }
} else {
    if (-not $Id -or $Id -notmatch '^[0-9-]+$') { Log 'missing or bad -Id'; exit 4 }
    $jobPath = Join-Path (Join-Path $baseDir 'reminders') ($Id + '.json')
    if (-not (Test-Path -LiteralPath $jobPath)) { Log ('reminder ' + $Id + ' not found'); exit 5 }
    $job = Get-Content -LiteralPath $jobPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([bool]$job.dryRun) { $dry = $true }
}

# recipients
$msgs = @()
if ($null -ne $job.channels) { $chans = @($job.channels) } elseif ($null -ne $r.channels) { $chans = @($r.channels) }
else { $chans = @(); switch ([string]$r.channel) { 'email' { $chans = @('email') } 'text' { $chans = @('text') } 'both' { $chans = @('email', 'text') } } }
$ch = $(if ($chans -contains 'email' -and $chans -contains 'text') { 'both' } elseif ($chans -contains 'text') { 'text' } elseif ($chans -contains 'email') { 'email' } else { '' })
if (-not $mailOk) { $ch = '' }
$speech = $(if ($job.speech) { [string]$job.speech } else { [string]$job.subject })
if ($chans -contains 'alexa') { if ($annOk -and $null -ne $cfg.announce -and $cfg.announce.device) { $msgs += [pscustomobject]@{ kind = 'alexa'; to = [string]$cfg.announce.device; subject = ''; body = $speech } } else { Log 'alexa skipped: Voice Monkey not set up or announcements not allowed' } }
if ($chans -contains 'toast') { $msgs += [pscustomobject]@{ kind = 'toast'; to = 'this PC'; subject = [string]$job.subject; body = [string]$job.sms } }
if (($ch -eq 'email' -or $ch -eq 'both') -and $r.email) { $msgs += [pscustomobject]@{ kind = 'email'; to = [string]$r.email; subject = [string]$job.subject; body = [string]$job.body } }
if (($ch -eq 'text' -or $ch -eq 'both') -and $r.phone -and $r.carrierGateway) {
    $digits = ([string]$r.phone) -replace '\D', ''
    if ($digits.Length -eq 11 -and $digits.StartsWith('1')) { $digits = $digits.Substring(1) }
    $msgs += [pscustomobject]@{ kind = 'text'; to = ($digits + '@' + [string]$r.carrierGateway); subject = ''; body = [string]$job.sms }
}
if ($msgs.Count -eq 0) { Log ('nothing to deliver (channels: ' + ($chans -join ',') + ')'); if (-not $Test -and $Id) { try { Unregister-ScheduledTask -TaskName ('TessDesk Reminder ' + $Id) -Confirm:$false -ErrorAction SilentlyContinue } catch {} }; exit $(if ($chans -contains 'calendar') { 0 } else { 6 }) }

$smtp = $r.smtp
$from = $(if ($smtp.from) { [string]$smtp.from } else { [string]$smtp.user })
$ok = $true
foreach ($m in $msgs) {
    if ($dry -and $m.kind -in @('alexa', 'toast')) {
        Log ('DRY RUN (nothing sent) · {0} to {1}: {2}' -f $m.kind, $m.to, $m.body); Write-Output ('  ' + $m.kind + ': ' + $m.body); continue
    }
    if ($m.kind -eq 'toast') {
        try {
            [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
            $x = New-Object Windows.Data.Xml.Dom.XmlDocument
            $esc = { param($t) [Security.SecurityElement]::Escape([string]$t) }
            $x.LoadXml('<toast scenario="reminder"><visual><binding template="ToastGeneric"><text>' + (& $esc $m.subject) + '</text><text>' + (& $esc $m.body) + '</text></binding></visual><actions><action content="Dismiss" arguments="dismiss" activationType="system"/></actions></toast>')
            $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($x))
            Log 'sent toast (Windows notification)'
        } catch { $ok = $false; Log ('toast FAILED: ' + $_.Exception.Message) }
        continue
    }
    if ($m.kind -eq 'alexa') {
        try {
            $tp = Join-Path $baseDir 'voicemonkey.token.dpapi'
            $ss = (Get-Content -LiteralPath $tp -Raw).Trim() | ConvertTo-SecureString; $bs = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
            try { $vt = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bs).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bs) }
            $bd = @{ token = $vt; device = $m.to; speech = $m.body } | ConvertTo-Json -Compress
            [void](Invoke-RestMethod -Uri 'https://api-v3.voicemonkey.io/announce' -Method Post -ContentType 'application/json' -Body $bd -TimeoutSec 20 -UseBasicParsing)
            Log ('sent alexa announcement to ' + $m.to)
        } catch { $ok = $false; Log ('alexa FAILED: ' + $_.Exception.Message) }
        continue
    }
    if ($dry) {
        Log ('DRY RUN (nothing sent) · {0} via {1}:{2} as {3}' -f $m.kind, $smtp.host, $smtp.port, $smtp.user)
        Write-Output ('  To: ' + $m.to)
        if ($m.subject) { Write-Output ('  Subject: ' + $m.subject) }
        Write-Output '  ---'; foreach ($l in ($m.body -split "`r?`n")) { Write-Output ('  ' + $l) }; Write-Output '  ---'
        continue
    }
    try {
        $secFile = Join-Path $baseDir $(if ($r.smtpSecretFile) { [string]$r.smtpSecretFile } else { 'smtp.secret' })
        $ss = (Get-Content -LiteralPath $secFile -Raw).Trim() | ConvertTo-SecureString
        $client = New-Object System.Net.Mail.SmtpClient([string]$smtp.host, [int]$smtp.port)
        $client.EnableSsl = $(if ($null -ne $smtp.ssl) { [bool]$smtp.ssl } else { $true })
        $client.Credentials = New-Object System.Net.NetworkCredential([string]$smtp.user, $ss)
        $client.Timeout = 30000
        $mm = New-Object System.Net.Mail.MailMessage($from, $m.to)
        $mm.Subject = $m.subject; $mm.Body = $m.body; $mm.IsBodyHtml = $false
        $client.Send($mm); $mm.Dispose(); $client.Dispose()
        Log ('sent {0} to {1}' -f $m.kind, $m.to)
    } catch { $ok = $false; Log ('send FAILED ({0} to {1}): {2}' -f $m.kind, $m.to, $_.Exception.Message) }
}

# one-time reminder: clean up its file and task
if (-not $Test -and $Id) {
    try { if ($jobPath) { Remove-Item -LiteralPath $jobPath -Force -ErrorAction SilentlyContinue } } catch {}
    try { Unregister-ScheduledTask -TaskName ('TessDesk Reminder ' + $Id) -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Log ('reminder ' + $Id + ' done (task removed)')
}
if ($ok) { exit 0 } else { exit 1 }
