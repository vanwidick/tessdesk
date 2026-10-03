#Requires -Version 5.1
# TessDesk v4.3 - list the Voice Monkey speakers on this account (read-only GET /devices; never announces, never prints the token).
# -Save writes them to config.json announce.speakerList (used by "All Echos").
param([string]$ConfigPath, [switch]$Save)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $dir 'config.json' }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$tp = Join-Path $dir 'voicemonkey.token.dpapi'
if (-not (Test-Path -LiteralPath $tp)) { Write-Output (@{ ok = $false; error = 'no saved Voice Monkey token (voicemonkey.token.dpapi)' } | ConvertTo-Json -Compress); exit 1 }
$ss = (Get-Content -LiteralPath $tp -Raw).Trim() | ConvertTo-SecureString
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
try { $tok = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
try {
    $r = Invoke-RestMethod -Uri 'https://api-v3.voicemonkey.io/devices' -Headers @{ Authorization = ('Bearer ' + $tok) } -Method Get -TimeoutSec 15 -UseBasicParsing
} catch { $c = $null; try { $c = [int]$_.Exception.Response.StatusCode } catch {}; Write-Output (@{ ok = $false; error = $(if ($c) { 'HTTP ' + $c } else { $_.Exception.Message }) } | ConvertTo-Json -Compress); exit 1 }
$tok = $null
$all = @(@($r.data) | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name; capability = [string]$_.capability } })
$spk = @($all | Where-Object { $_.capability -eq 'speakers' -or -not $_.capability })
if ($Save -and $spk.Count -gt 0) {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $a = [ordered]@{}; if ($null -ne $cfg.announce) { foreach ($p in $cfg.announce.PSObject.Properties) { $a[$p.Name] = $p.Value } }
    $a['speakerList'] = @($spk | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name } })
    if (-not $a.Contains('speakers')) { $a['speakers'] = [pscustomobject]@{ all = $true; ids = @() } }
    $cfg | Add-Member -NotePropertyName announce -NotePropertyValue ([pscustomobject]$a) -Force
    $cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}
Write-Output ([ordered]@{ ok = $true; count = $all.Count; speakers = $spk.Count; devices = $all; saved = [bool]($Save -and $spk.Count -gt 0) } | ConvertTo-Json -Depth 4 -Compress)
