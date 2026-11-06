<#
 Jarvis Watchdog - World of Zugard
 Supervisor independiente. Pensado para ejecutarse cada 15 min desde el Programador de tareas.
 Codigos de salida: 0 ok | 2 error de configuracion/interno | 3 ya habia otra instancia en ejecucion.
 No reinicia, cierra ni modifica Claude/Codex/Jarvis/Unreal ni el repositorio.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\watchdog.config.json'),
    [switch]$ForceSummary
)
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Notify.ps1')
. (Join-Path $PSScriptRoot 'lib\Checks.ps1')

$script:Cfg = $null
try { $script:Cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch {
    $fallback = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
    New-Item -ItemType Directory -Path $fallback -Force | Out-Null
    Add-Content -LiteralPath (Join-Path $fallback 'fatal.log') -Value ("{0} config ilegible: {1}" -f (Get-Date), $_.Exception.Message)
    exit 2
}

Initialize-Dirs
$script:Findings = New-Object System.Collections.ArrayList
$script:Report = @{ agents = @{}; needsSetup = @(); limitations = @(); checks = @() }

# --- Prevencion de ejecuciones simultaneas
$mutexName = [string](Get-Cfg 'runtime.mutexName' 'Global\ZugardWatchdog')
$mutex = $null; $owned = $false
try {
    try { $mutex = New-Object System.Threading.Mutex($false, $mutexName) }
    catch { $mutex = New-Object System.Threading.Mutex($false, ($mutexName -replace '^Global\\', 'Local\')) }
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Write-Log 'WARN' 'Otra instancia del watchdog esta en ejecucion; esta se omite.'; exit 3 }
} catch { Write-Log 'ERROR' "Mutex: $($_.Exception.Message)"; exit 2 }

$sw = [Diagnostics.Stopwatch]::StartNew()
$maxSec = [int](Get-Cfg 'runtime.maxSeconds' 240)
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
Write-Log 'INFO' "=== Inicio ejecucion $runId (PS $($PSVersionTable.PSVersion)) ==="

function Invoke-Check {
    param([string]$Name, [scriptblock]$Body)
    if ($sw.Elapsed.TotalSeconds -gt $maxSec) {
        Write-Log 'WARN' "Limite de tiempo ($maxSec s) alcanzado; se omite '$Name'."
        $script:Report.checks += @{ name = $Name; result = 'omitido-timeout' }
        return
    }
    $t0 = $sw.Elapsed.TotalSeconds
    try { & $Body; $script:Report.checks += @{ name = $Name; result = 'ok'; seconds = [Math]::Round($sw.Elapsed.TotalSeconds - $t0, 1) } }
    catch {
        Write-Log 'ERROR' "Check '$Name' fallo: $($_.Exception.Message)"
        $script:Report.checks += @{ name = $Name; result = 'error' }
        Add-Finding "watchdog:check-failed:$Name" 2 'warning' "Fallo interno del check '$Name'" $_.Exception.Message
    }
}

function Update-Alerts {
    $active = @{}
    foreach ($f in $script:Findings) { if ($f.Severity -ne 'info') { $active[$f.Id] = $f } }
    $alerts = $script:State.alerts
    $newOrRemind = @(); $resolved = @(); $ids = @()
    foreach ($id in $active.Keys) {
        $f = $active[$id]
        $cool = [int](Get-Cfg "notify.cooldownMinutes.$($f.Severity)" 240)
        $a = $alerts[$id]
        if ($null -eq $a) {
            $alerts[$id] = @{ First = [DateTime]::UtcNow.ToString('o'); LastSent = [DateTime]::UtcNow.ToString('o'); Count = 1; Missing = 0; Title = $f.Title }
            $newOrRemind += $f; $ids += $id
        } else {
            $a.Missing = 0
            $since = Get-MinutesSince (ConvertTo-Utc $a.LastSent)
            if ($null -eq $since -or $since -ge $cool) {
                $a.LastSent = [DateTime]::UtcNow.ToString('o'); $a.Count = [int]$a.Count + 1
                $newOrRemind += $f; $ids += $id
            }
        }
    }
    foreach ($id in @($alerts.Keys)) {
        if ($active.ContainsKey($id)) { continue }
        $a = $alerts[$id]; $a.Missing = [int]$a.Missing + 1
        if ($a.Missing -ge 2) { $resolved += $a.Title; $alerts.Remove($id) }
    }
    if ($newOrRemind.Count -eq 0 -and $resolved.Count -eq 0) { return }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('**Jarvis Watchdog - World of Zugard**')
    $need = @($newOrRemind | Where-Object { $_.Tier -eq 3 })
    if ($need.Count -gt 0) { [void]$sb.AppendLine(':warning: **REQUIERE TU AUTORIZACION / ACCION HUMANA**') }
    foreach ($f in ($newOrRemind | Sort-Object Tier -Descending | Select-Object -First 10)) {
        $icon = if ($f.Severity -eq 'critical') { ':red_circle:' } else { ':yellow_circle:' }
        [void]$sb.AppendLine(("{0} [N{1}] {2} - {3}" -f $icon, $f.Tier, $f.Title, $f.Detail))
    }
    if ($newOrRemind.Count -gt 10) { [void]$sb.AppendLine("... y $($newOrRemind.Count - 10) mas (ver reports/latest.md)") }
    foreach ($t in $resolved) { [void]$sb.AppendLine(":white_check_mark: Resuelto: $t") }
    [void](Dispatch-Message 'alert' $ids $sb.ToString())
}

function Send-DailySummaryIfDue {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $hour = [int](Get-Cfg 'notify.dailySummaryHour' 21)
    if (-not $ForceSummary) {
        if ($script:State.summary['last'] -eq $today -or (Get-Date).Hour -lt $hour) { return }
    }
    $script:State.summary['last'] = $today
    $cut = [DateTime]::UtcNow.AddHours(-24)
    $runs = 0; $alertCount = 0
    $rf = Join-Path $script:Dirs.Logs 'runs.jsonl'
    if (Test-Path -LiteralPath $rf) { $runs = @(Get-Content -LiteralPath $rf -Tail 200 | Where-Object { $_ }).Count }
    $af = Join-Path $script:Dirs.Logs 'alerts.jsonl'
    if (Test-Path -LiteralPath $af) {
        foreach ($l in Get-Content -LiteralPath $af -Tail 300) {
            try { $o = $l | ConvertFrom-Json; if ((ConvertTo-Utc $o.tsUtc) -gt $cut -and $o.kind -eq 'alert') { $alertCount++ } } catch { }
        }
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("**Resumen diario - World of Zugard ($today)**")
    [void]$sb.AppendLine("Revisiones registradas (ultimas 200): $runs | Alertas enviadas 24 h: $alertCount")
    $open = @($script:Findings | Where-Object { $_.Severity -ne 'info' })
    [void]$sb.AppendLine("Problemas abiertos ahora: $($open.Count)")
    foreach ($f in ($open | Select-Object -First 8)) { [void]$sb.AppendLine(" - [N$($f.Tier)] $($f.Title)") }
    $git = Get-Command git -ErrorAction SilentlyContinue
    $root = [string](Get-Cfg 'projectRoot' '')
    if ($git -and (Test-Path -LiteralPath $root)) {
        $r = Invoke-External $git.Source @('-C', $root, 'log', '--since=24.hours', '--pretty=%h %s', '-n', '10') 30
        if ($r.ExitCode -eq 0) {
            $c = @($r.Out -split "`r?`n" | Where-Object { $_ })
            [void]$sb.AppendLine("Commits verificables (24 h): $($c.Count)")
            foreach ($x in ($c | Select-Object -First 5)) { [void]$sb.AppendLine(" - $x") }
        }
    }
    $j = $script:Report['jarvis']
    if ($j -and $j.Task) { [void]$sb.AppendLine("Jarvis - tarea actual: $($j.Task) ($($j.Agent), $($j.Status))") }
    $hb = Read-JsonFile ([string](Get-Cfg 'jarvis.heartbeatFile' ''))
    if ($hb -and $hb.nextTasks) { [void]$sb.AppendLine('Proximas tareas: ' + ((@($hb.nextTasks) | Select-Object -First 5) -join '; ')) }
    [void](Dispatch-Message 'daily-summary' @() $sb.ToString())
}

function Write-Reports {
    $open = @($script:Findings)
    $script:Report.generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $script:Report.runId = $runId
    $script:Report.findings = $open
    try {
        Write-JsonAtomic (Join-Path $script:Dirs.Reports 'latest.json') $script:Report 8
        $md = New-Object System.Text.StringBuilder
        [void]$md.AppendLine("# Jarvis Watchdog - ultimo informe`n")
        [void]$md.AppendLine("Generado (UTC): $($script:Report.generatedUtc) - ejecucion $runId`n")
        [void]$md.AppendLine("## Hallazgos ($($open.Count))")
        if ($open.Count -eq 0) { [void]$md.AppendLine('Ninguno.') }
        foreach ($f in $open) { [void]$md.AppendLine("- **[N$($f.Tier)/$($f.Severity)]** $($f.Title) - $($f.Detail)  (id: $($f.Id))") }
        if ($script:Report.needsSetup.Count -gt 0) { [void]$md.AppendLine("`n## Configuracion pendiente"); foreach ($n in ($script:Report.needsSetup | Select-Object -Unique)) { [void]$md.AppendLine("- $n") } }
        if ($script:Report.limitations.Count -gt 0) { [void]$md.AppendLine("`n## Limitaciones"); foreach ($n in ($script:Report.limitations | Select-Object -Unique)) { [void]$md.AppendLine("- $n") } }
        Set-Content -LiteralPath (Join-Path $script:Dirs.Reports 'latest.md') -Value $md.ToString() -Encoding UTF8
    } catch { Write-Log 'ERROR' "No se pudo escribir el informe: $($_.Exception.Message)" }
}

$exit = 0
try {
    Load-State
    Invoke-Check 'agent-claude'  { Check-Agent 'claude' 'Claude' }
    Invoke-Check 'agent-codex'   { Check-Agent 'codex' 'Codex' }
    Invoke-Check 'codex-trust'   { Check-CodexTrust }
    Invoke-Check 'jarvis'        { Check-Jarvis }
    Invoke-Check 'unreal'        { Check-Unreal }
    Invoke-Check 'resources'     { Check-Resources }
    Invoke-Check 'git'           { Check-Git }
    Invoke-Check 'backups'       { Check-Backups }
    Invoke-Check 'claims'        { Check-Claims }
    Restore-Events
    Invoke-Check 'outbox-retry'  { Invoke-OutboxRetry }
    Invoke-Check 'alerts'        { Update-Alerts }
    Invoke-Check 'daily-summary' { Send-DailySummaryIfDue }
    Write-Reports
    Write-JsonAtomic (Join-Path $script:Dirs.State 'watchdog_heartbeat.json') @{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o'); runId = $runId; findings = $script:Findings.Count }
    Add-JsonLine (Join-Path $script:Dirs.Logs 'runs.jsonl') @{ tsUtc = (Get-Date).ToUniversalTime().ToString('o'); runId = $runId; seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1); findings = $script:Findings.Count }
    Write-Log 'INFO' "=== Fin ejecucion $runId: $($script:Findings.Count) hallazgo(s) en $([Math]::Round($sw.Elapsed.TotalSeconds,1)) s ==="
} catch {
    Write-Log 'ERROR' "Fallo no controlado: $($_.Exception.Message)"
    $exit = 2
} finally {
    if ($script:State) { Save-State }
    if ($owned -and $mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
}
exit $exit
