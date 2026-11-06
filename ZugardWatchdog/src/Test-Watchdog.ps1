<#
 Pruebas controladas en un SANDBOX temporal. No toca Claude, Codex, Jarvis, Unreal ni E:\WorldOfZugard.
 Usa datos de prueba (heartbeat vencido, logs falsos, repo git temporal) y notify.mode = "file" (no envia a Discord).
 Resultado: tabla PASS/FAIL y sandbox\results.json. Requiere git en PATH para las pruebas de git.
#>
param([string]$SandboxRoot = (Join-Path $env:TEMP ('zugard-wd-test-' + (Get-Date).ToString('yyyyMMddHHmmss'))))
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$ps = (Get-Process -Id $PID).Path
$results = New-Object System.Collections.ArrayList
function Assert($name, [bool]$ok, $detail = '') { [void]$results.Add([pscustomobject]@{ Test = $name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detail = "$detail" }) }

$wd = Join-Path $SandboxRoot 'wd'; $proj = Join-Path $SandboxRoot 'proj'
foreach ($d in $wd, "$wd\state", "$wd\logs", $proj, "$proj\Saved\Logs") { New-Item -ItemType Directory -Path $d -Force | Out-Null }

# repo git temporal con cambios sin confirmar
if (Get-Command git -ErrorAction SilentlyContinue) {
    git -C $proj init -q 2>$null; git -C $proj config user.email t@t; git -C $proj config user.name t
    Set-Content "$proj\a.txt" 'x'; git -C $proj add a.txt; git -C $proj commit -q -m init
    Set-Content "$proj\b.txt" 'dirty'
}

$cfg = Get-Content (Join-Path (Split-Path -Parent $src) 'config\watchdog.config.json') -Raw | ConvertFrom-Json
$cfg.projectRoot = $proj; $cfg.watchdogRoot = $wd
$cfg.runtime.mutexName = 'Global\ZugardWatchdogTest'
$cfg.jarvis.heartbeatFile = "$wd\state\jarvis_heartbeat.json"
$cfg.unreal.logDir = "$proj\Saved\Logs"; $cfg.unreal.extraLogFiles = @(); $cfg.unreal.automationDir = "$proj\Saved\Automation"
$cfg.agents.claude.expectedRunning = $true; $cfg.agents.claude.processNames = @('zugard_no_existe')
$cfg.agents.codex.configHome = "$wd\codexhome"
$cfg.claims.dir = "$wd\state\claims"
$cfg.git.uncommittedWarnMinutes = 0
$cfg.notify.mode = 'file'; $cfg.notify.dailySummaryHour = 0
$cfg.resources.minFreeDiskGB = 0
$cfgPath = "$wd\test.config.json"
$cfg | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding UTF8

function Run-WD([switch]$Summary) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$src\Watchdog.ps1", '-ConfigPath', $cfgPath)
    if ($Summary) { $a += '-ForceSummary' }
    $p = Start-Process $ps -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
}
function Latest { Get-Content "$wd\reports\latest.json" -Raw | ConvertFrom-Json }

# Heartbeat vencido (datos de prueba, 3 h) + agente responsable "claude" sin proceso
@{ schema = 1; timestampUtc = (Get-Date).ToUniversalTime().AddHours(-3).ToString('o'); agent = 'claude'; task = 'tarea-de-prueba'; status = 'working'
   lastProgressUtc = (Get-Date).ToUniversalTime().AddHours(-3).ToString('o'); pendingErrors = @('error simulado'); handoff = @{ id = 'h1'; from = 'claude'; to = 'codex'; state = 'pending'; createdUtc = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o') } } |
    ConvertTo-Json -Depth 5 | Set-Content "$wd\state\jarvis_heartbeat.json" -Encoding UTF8
# Claims solapados
New-Item -ItemType Directory "$wd\state\claims" -Force | Out-Null
$now = (Get-Date).ToUniversalTime().ToString('o')
@{ agent = 'claude'; files = @('Source/X.cpp'); timestampUtc = $now } | ConvertTo-Json | Set-Content "$wd\state\claims\claude.json"
@{ agent = 'codex'; files = @('Source/X.cpp'); timestampUtc = $now } | ConvertTo-Json | Set-Content "$wd\state\claims\codex.json"
# Log falso de Unreal: la 1a ejecucion fija linea base
Set-Content "$proj\Saved\Logs\Test.log" "LogInit: Display: start"

# 1) Ejecucion manual + linea base
$c1 = Run-WD
Assert 'Ejecucion manual (exit 0)' ($c1 -eq 0) "exit=$c1"
Assert 'Se crea log persistente' ([bool](Get-ChildItem "$wd\logs\watchdog-*.log" -ErrorAction SilentlyContinue))
Assert 'Se crea informe latest.json/md' ((Test-Path "$wd\reports\latest.json") -and (Test-Path "$wd\reports\latest.md"))

# 2) Fallos simulados en log de Unreal (bytes nuevos tras la linea base)
Add-Content "$proj\Saved\Logs\Test.log" "LogCompile: error C2065: 'x': undeclared identifier"
Add-Content "$proj\Saved\Logs\Test.log" "Fatal error: [File:Test] simulated"
$c2 = Run-WD
$ids = @((Latest).findings | ForEach-Object { $_.Id })
Assert 'Detecta heartbeat vencido' ($ids -contains 'jarvis:heartbeat-stale')
Assert 'Detecta tarea sin progreso' ($ids -contains 'jarvis:no-progress')
Assert 'Detecta errores pendientes' ($ids -contains 'jarvis:pending-errors')
Assert 'Detecta handoff incompleto' ($ids -contains 'jarvis:handoff-incomplete')
Assert 'Detecta agente responsable caido (2 revisiones)' ($ids -contains 'agent:claude:down' -or $ids -contains 'jarvis:responsible-agent-down:claude')
Assert 'Detecta compilacion fallida simulada' ($ids -contains 'unreal:log-build-failed')
Assert 'Detecta error fatal simulado' ($ids -contains 'unreal:log-fatal')
Assert 'Detecta solape de archivos entre agentes' (@($ids | Where-Object { $_ -like 'claims:overlap:*' }).Count -gt 0)
Assert 'Detecta respaldos sin configurar' ($ids -contains 'backup:not-configured')
Assert 'Detecta cambios sin commit' ($ids -contains 'git:uncommitted' -or -not (Get-Command git -ErrorAction SilentlyContinue))
Assert 'Detecta confianza de Codex no verificable/registrada' ($ids -contains 'codex:trust-not-registered' -or ((Latest).limitations -join ' ') -match 'config.toml')

# 3) Alertas: se generan y no se repiten dentro del cooldown
$alertLines1 = @(Get-Content "$wd\logs\alerts.jsonl" -ErrorAction SilentlyContinue | Where-Object { $_ -match '"kind":"alert"' }).Count
Assert 'Genera alertas (modo archivo)' ($alertLines1 -ge 1) "alertas=$alertLines1"
$c3 = Run-WD
$alertLines2 = @(Get-Content "$wd\logs\alerts.jsonl" | Where-Object { $_ -match '"kind":"alert"' }).Count
Assert 'No repite alertas dentro del cooldown' ($alertLines2 -eq $alertLines1) "antes=$alertLines1 despues=$alertLines2"

# 4) Redaccion de secretos
. "$src\lib\Common.ps1"
$red = Protect-Text 'url https://discord.com/api/webhooks/123456/abcDEF_ghi token=abc123SECRET ghp_abcdefghijklmnopqrstuv'
Assert 'Redacta webhook/tokens' ($red -notmatch 'abcDEF_ghi' -and $red -notmatch 'abc123SECRET' -and $red -notmatch 'ghp_abcdef') $red

# 5) Prevencion de ejecuciones simultaneas
$m = New-Object System.Threading.Mutex($false, 'Global\ZugardWatchdogTest')
[void]$m.WaitOne(0)
$c4 = Run-WD
$m.ReleaseMutex(); $m.Dispose()
Assert 'Segunda instancia se rechaza (exit 3)' ($c4 -eq 3) "exit=$c4"

# 6) Resumen diario
$c5 = Run-WD -Summary
Assert 'Genera resumen diario' ((Get-Content "$wd\logs\alerts.jsonl" -Raw) -match 'daily-summary')

# 7) Recuperacion Nivel 1 acotada (limite diario)
$st = Get-Content "$wd\state\state.json" -Raw | ConvertFrom-Json
Assert 'Estado persistente escrito' ([bool]$st)
$results | Format-Table -AutoSize
$results | ConvertTo-Json | Set-Content "$SandboxRoot\results.json" -Encoding UTF8
$fail = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host "Sandbox: $SandboxRoot | FAIL: $fail / $($results.Count)"
exit $(if ($fail) { 1 } else { 0 })
