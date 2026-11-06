<#
 Integracion de heartbeat para Jarvis (y para Claude/Codex si se desea).
 Llamar al inicio de cada tarea, al avanzar (-Progress) y al terminar.
 Ejemplos:
   .\Send-JarvisHeartbeat.ps1 -Agent claude -Task "Compilar modulo Combat" -Status working -Progress
   .\Send-JarvisHeartbeat.ps1 -Agent codex  -Task "Revisar PR 12" -Status blocked -PendingError "401 en API"
   .\Send-JarvisHeartbeat.ps1 -Agent claude -Task "Handoff" -Handoff h-042 -HandoffFrom claude -HandoffTo codex -HandoffState pending
   .\Send-JarvisHeartbeat.ps1 -Agent claude -Task "Editar" -Claim "Source/Zugard/Combat.cpp","Content/Maps/Main.umap"
 Status: idle | working | blocked | waiting_human
 -Progress: marca avance verificable (actualiza lastProgressUtc). Sin -Progress solo prueba que Jarvis esta vivo.
#>
[CmdletBinding()]
param(
    [string]$Agent = 'jarvis',
    [string]$Task = '',
    [ValidateSet('idle', 'working', 'blocked', 'waiting_human')][string]$Status = 'working',
    [switch]$Progress,
    [string[]]$PendingError = @(),
    [string]$Handoff, [string]$HandoffFrom, [string]$HandoffTo,
    [ValidateSet('pending', 'incomplete', 'complete')][string]$HandoffState,
    [string[]]$NextTasks = @(),
    [string[]]$Claim = @(),
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\watchdog.config.json')
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$root = $cfg.watchdogRoot
$hbFile = if ($cfg.jarvis.heartbeatFile) { $cfg.jarvis.heartbeatFile } else { Join-Path $root 'state\jarvis_heartbeat.json' }
$now = (Get-Date).ToUniversalTime().ToString('o')

$prev = $null
if (Test-Path -LiteralPath $hbFile) { try { $prev = Get-Content -LiteralPath $hbFile -Raw | ConvertFrom-Json } catch { } }
$lastProgress = $now
if (-not $Progress -and $prev -and $prev.lastProgressUtc -and $prev.task -eq $Task) { $lastProgress = $prev.lastProgressUtc }

$hb = [ordered]@{
    schema = 1; timestampUtc = $now; agent = $Agent; task = $Task; status = $Status
    lastProgressUtc = $lastProgress; pendingErrors = @($PendingError); nextTasks = @($NextTasks)
}
if ($Handoff) { $hb.handoff = [ordered]@{ id = $Handoff; from = $HandoffFrom; to = $HandoffTo; state = $HandoffState; createdUtc = $now } }
elseif ($prev -and $prev.handoff -and $prev.handoff.state -ne 'complete') { $hb.handoff = $prev.handoff }

New-Item -ItemType Directory -Path (Split-Path -Parent $hbFile) -Force | Out-Null
$tmp = "$hbFile.tmp"
($hb | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $hbFile -Force
Add-Content -LiteralPath (Join-Path $root 'logs\heartbeats.jsonl') -Value (($hb | ConvertTo-Json -Depth 6 -Compress)) -ErrorAction SilentlyContinue

if ($Claim.Count -gt 0) {
    $cdir = if ($cfg.claims.dir) { $cfg.claims.dir } else { Join-Path $root 'state\claims' }
    New-Item -ItemType Directory -Path $cdir -Force | Out-Null
    $c = [ordered]@{ agent = $Agent; task = $Task; files = @($Claim); timestampUtc = $now }
    ($c | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $cdir "$Agent.json") -Encoding UTF8
}
Write-Output "Heartbeat escrito: $hbFile"
