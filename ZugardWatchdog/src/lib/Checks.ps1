# Jarvis Watchdog - comprobaciones (solo lectura sobre el proyecto, los agentes y Unreal).
# Un proceso abierto NO se interpreta como progreso: solo se usan indicadores verificables.
Set-StrictMode -Version 1.0

function Get-ProcsByName {
    param([string[]]$Names)
    $out = @()
    foreach ($n in $Names) { if ($n) { $out += @(Get-Process -Name $n -ErrorAction SilentlyContinue) } }
    return $out
}

function Get-NewestActivity {
    param([string[]]$Paths)
    $newest = $null
    foreach ($p in $Paths) {
        $exp = [Environment]::ExpandEnvironmentVariables($p)
        if (-not (Test-Path -Path $exp)) { continue }
        $it = Get-Item -Path $exp -ErrorAction SilentlyContinue
        foreach ($i in @($it)) {
            $t = $i.LastWriteTimeUtc
            if ($i.PSIsContainer) {
                $f = Get-ChildItem -LiteralPath $i.FullName -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                if ($f) { $t = $f.LastWriteTimeUtc }
            }
            if ($null -eq $newest -or $t -gt $newest) { $newest = $t }
        }
    }
    return $newest
}

# ---------------------------------------------------------------- Agentes (Claude / Codex)
function Check-Agent {
    param([string]$Key, [string]$Label)
    if (-not (Get-Cfg "agents.$Key.enabled" $true)) { return }
    $names = @(Get-Cfg "agents.$Key.processNames" @())
    $expected = [bool](Get-Cfg "agents.$Key.expectedRunning" $false)
    $procs = @(Get-ProcsByName $names)
    $cpu = 0.0
    foreach ($p in $procs) { try { $cpu += $p.TotalProcessorTime.TotalSeconds } catch { } }

    $st = $script:State.agents[$Key]
    if ($null -eq $st) { $st = @{ Cpu = $cpu; LastCpuChangeUtc = [DateTime]::UtcNow.ToString('o') } }
    if ([Math]::Abs($cpu - [double]$st.Cpu) -gt 0.5) { $st.LastCpuChangeUtc = [DateTime]::UtcNow.ToString('o') }
    $st.Cpu = $cpu
    $script:State.agents[$Key] = $st

    $activity = Get-NewestActivity @(Get-Cfg "agents.$Key.activityPaths" @())
    $info = @{
        Running = ($procs.Count -gt 0); ProcessCount = $procs.Count
        CpuIdleMinutes = (Get-MinutesSince (ConvertTo-Utc $st.LastCpuChangeUtc))
        LastActivityUtc = $(if ($activity) { $activity.ToString('o') } else { $null })
        Telemetry = $(if (@(Get-Cfg "agents.$Key.activityPaths" @()).Count -gt 0) { 'activityPaths' } else { 'ninguna (solo proceso+CPU; limitacion registrada)' })
    }
    $script:Report.agents[$Key] = $info

    $miss = Step-Counter "agent-missing:$Key" ($expected -and $procs.Count -eq 0)
    if ($miss -ge 2) {
        Add-Finding "agent:${Key}:down" 2 'critical' "$Label no esta en ejecucion" "Sin procesos ($($names -join ', ')) durante $miss revisiones consecutivas. Nivel 2: no se reinicia automaticamente."
    }

    # Errores en logs (si hay logFiles configurados)
    $pats = @(Get-Cfg 'patterns.agent' @())
    $sticky = [int](Get-Cfg 'patterns.stickyMinutes' 60)
    foreach ($lf in @(Get-Cfg "agents.$Key.logFiles" @())) {
        $f = Resolve-NewestFile $lf
        if (-not $f) { continue }
        $hits = Scan-LogFile $f.FullName $pats
        foreach ($name in $hits.Keys) {
            $h = $hits[$name]
            Add-Event "agent:${Key}:log-$name" ([int]$h.Pattern.tier) $h.Pattern.severity "$Label - $name detectado en log" ("{0} coincidencias. Ultima: {1}" -f $h.Count, $h.Last) $sticky
        }
    }
}

function Check-CodexTrust {
    if (-not (Get-Cfg 'agents.codex.enabled' $true)) { return }
    $root = [string](Get-Cfg 'projectRoot' '')
    $problems = @()

    if (-not (Test-Path -LiteralPath $root)) {
        Add-Finding 'codex:project-missing' 3 'critical' 'Ruta del proyecto inaccesible' "No existe o no es accesible: $root (unidad desconectada?)."
        return
    }

    # 1) Registro de confianza en config.toml (formato documentado: [projects."RUTA"] trust_level = "trusted")
    $home_ = [string](Get-Cfg 'agents.codex.configHome' '')
    if (-not $home_) { $home_ = $env:CODEX_HOME }
    if (-not $home_) { $home_ = Join-Path $env:USERPROFILE '.codex' }
    $toml = Join-Path $home_ 'config.toml'
    $trusted = $null
    if (Test-Path -LiteralPath $toml) {
        $txt = Get-Content -LiteralPath $toml -Raw
        $norm = { param($s) ($s -replace '\\\\', '\' -replace '/', '\').TrimEnd('\').ToLowerInvariant() }
        $want = & $norm $root
        $trusted = $false
        foreach ($m in [regex]::Matches($txt, '(?ims)^\s*\[projects\.(["''])(?<p>.+?)\1\]\s*(?<b>.*?)(?=^\s*\[|\z)')) {
            if ((& $norm $m.Groups['p'].Value) -eq $want -and $m.Groups['b'].Value -match '(?i)trust_level\s*=\s*["'']trusted["'']') { $trusted = $true }
        }
        $script:Report.codexTrust = @{ ConfigToml = $toml; Registered = $trusted }
        if (-not $trusted) {
            Add-Finding 'codex:trust-not-registered' 3 'warning' 'Codex: el proyecto no figura como confiable' "Sin trust_level=trusted para $root en $toml. Requiere accion humana (docs/CODEX_TRUST.md)."
        }
    } else {
        $script:Report.codexTrust = @{ ConfigToml = $toml; Registered = $null; Note = 'config.toml no encontrado' }
        $script:Report.limitations += "Codex config.toml no encontrado en $home_ (no se puede verificar la confianza)."
    }

    # 2) Causa frecuente de 'no se puede verificar': git rechaza el repo (dubious ownership) o no es repo
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $r = Invoke-External $git.Source @('-C', $root, 'rev-parse', '--show-toplevel') 20
        if ($r.ExitCode -ne 0) {
            $sev = 'warning'
            if ($r.Err -match 'dubious ownership') { $sev = 'critical' }
            Add-Finding 'codex:git-cannot-verify' 3 $sev 'Git no puede verificar el repositorio (posible causa del error de confianza de Codex)' $r.Err
        }
    }
}

# ---------------------------------------------------------------- Jarvis
function Check-Jarvis {
    if (-not (Get-Cfg 'jarvis.enabled' $true)) { return }
    $hbFile = [string](Get-Cfg 'jarvis.heartbeatFile' (Join-Path $script:Dirs.State 'jarvis_heartbeat.json'))
    $hb = Read-JsonFile $hbFile
    $j = @{ HeartbeatFile = $hbFile; HeartbeatPresent = ($null -ne $hb) }
    $script:Report.jarvis = $j

    if ($null -eq $hb) {
        if (-not $script:State.once['jarvis-no-heartbeat']) {
            $script:State.once['jarvis-no-heartbeat'] = $true
        }
        Add-Finding 'jarvis:no-heartbeat' 2 'warning' 'Jarvis: no hay heartbeat' "No existe/ilegible: $hbFile. Integrar Send-JarvisHeartbeat.ps1 en el coordinador."
        return
    }
    $stale = [int](Get-Cfg 'jarvis.staleMinutes' 30)
    $noProg = [int](Get-Cfg 'jarvis.noProgressMinutes' 90)
    $ts = ConvertTo-Utc $hb.timestampUtc
    $age = Get-MinutesSince $ts
    $j.LastHeartbeatUtc = $(if ($ts) { $ts.ToString('o') } else { $null })
    $j.AgeMinutes = $age
    $j.Task = [string]$hb.task; $j.Agent = [string]$hb.agent; $j.Status = [string]$hb.status

    if ($null -eq $age -or $age -gt $stale) {
        Add-Finding 'jarvis:heartbeat-stale' 2 'critical' 'Jarvis dejo de responder (heartbeat vencido)' "Ultimo heartbeat hace $age min (limite $stale). Tarea: $($hb.task). Agente: $($hb.agent)."
    }

    $lp = ConvertTo-Utc $hb.lastProgressUtc
    $status = [string]$hb.status
    if ($status -eq 'working' -and $lp) {
        $pm = Get-MinutesSince $lp
        $j.NoProgressMinutes = $pm
        if ($pm -gt $noProg) {
            Add-Finding 'jarvis:no-progress' 2 'warning' 'Tarea sin progreso verificable' "Tarea '$($hb.task)' ($($hb.agent)) sin progreso hace $pm min (limite $noProg). Heartbeat vivo no implica progreso."
        }
    }
    if ($status -eq 'blocked') { Add-Finding 'jarvis:task-blocked' 2 'warning' 'Tarea bloqueada' "Tarea '$($hb.task)' reportada como bloqueada por $($hb.agent)." }
    if ($status -eq 'waiting_human') { Add-Finding 'jarvis:needs-human' 3 'critical' 'Se necesita tu autorizacion' "Tarea '$($hb.task)' espera decision humana." }

    $errs = @($hb.pendingErrors)
    if ($errs.Count -gt 0 -and $errs[0]) { Add-Finding 'jarvis:pending-errors' 2 'warning' "Jarvis: $($errs.Count) error(es) pendiente(s)" (($errs | Select-Object -First 3) -join ' | ') }

    if ($hb.handoff -and [string]$hb.handoff.state -in @('pending', 'incomplete')) {
        $hm = Get-MinutesSince (ConvertTo-Utc $hb.handoff.createdUtc)
        if ($null -ne $hm -and $hm -gt [int](Get-Cfg 'jarvis.handoffStaleMinutes' 60)) {
            Add-Finding 'jarvis:handoff-incomplete' 2 'warning' 'Handoff incompleto' "Handoff $($hb.handoff.id) $($hb.handoff.from)->$($hb.handoff.to) en estado $($hb.handoff.state) hace $hm min."
        }
    }

    # Agente responsable: contrastar con actividad verificable (si existe telemetria)
    $ag = [string]$hb.agent
    if ($status -eq 'working' -and $ag -and $script:Report.agents[$ag]) {
        $a = $script:Report.agents[$ag]
        if (-not $a.Running -and (Get-Cfg "agents.$ag.processNames" $null)) {
            Add-Finding "jarvis:responsible-agent-down:$ag" 2 'critical' "Agente responsable ($ag) sin proceso" "Jarvis dice que $ag trabaja en '$($hb.task)' pero no hay procesos."
        }
        if ($a.LastActivityUtc) {
            $am = Get-MinutesSince (ConvertTo-Utc $a.LastActivityUtc)
            if ($am -gt $noProg) { Add-Finding "jarvis:agent-silent:$ag" 2 'warning' "Sin actividad verificable de $ag" "Ultima escritura de telemetria hace $am min mientras la tarea figura 'working'." }
        }
    }
}

# ---------------------------------------------------------------- Unreal
function Check-Unreal {
    if (-not (Get-Cfg 'unreal.enabled' $true)) { return }
    $editors = @(Get-ProcsByName @(Get-Cfg 'unreal.editorProcessNames' @()))
    $builders = @(Get-ProcsByName @(Get-Cfg 'unreal.buildProcessNames' @()))
    $u = @{ EditorRunning = ($editors.Count -gt 0); EditorCount = $editors.Count; BuildProcesses = $builders.Count }
    $script:Report.unreal = $u

    $notResp = 0
    foreach ($e in $editors) { try { if (-not $e.Responding) { $notResp++ } } catch { } }
    $n = Step-Counter 'unreal-not-responding' ($notResp -gt 0)
    if ($n -ge [int](Get-Cfg 'unreal.notRespondingRuns' 2)) {
        Add-Finding 'unreal:not-responding' 2 'warning' 'Unreal Editor no responde' "$notResp proceso(s) sin respuesta durante $n revisiones. No se cierra automaticamente (Nivel 3)."
    }
    $maxB = [int](Get-Cfg 'unreal.buildMaxMinutes' 90)
    foreach ($b in $builders) {
        try {
            $m = [Math]::Round(([DateTime]::Now - $b.StartTime).TotalMinutes, 0)
            if ($m -gt $maxB -and $b.ProcessName -ne 'ShaderCompileWorker') {
                Add-Finding "unreal:build-long:$($b.ProcessName)" 2 'warning' 'Compilacion inusualmente larga' "$($b.ProcessName) lleva $m min (limite $maxB). Posible bloqueo; no se interrumpe."
            }
        } catch { }
    }

    $pats = @(Get-Cfg 'patterns.unreal' @())
    $sticky = [int](Get-Cfg 'patterns.stickyMinutes' 60)
    $logs = @()
    $ld = [Environment]::ExpandEnvironmentVariables([string](Get-Cfg 'unreal.logDir' ''))
    if ($ld -and (Test-Path -LiteralPath $ld)) {
        $nl = Get-ChildItem -LiteralPath $ld -Filter *.log -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($nl) { $logs += $nl.FullName }
    }
    foreach ($x in @(Get-Cfg 'unreal.extraLogFiles' @())) { $f = Resolve-NewestFile $x; if ($f) { $logs += $f.FullName } }
    $u.LogsScanned = $logs
    foreach ($lf in $logs) {
        $hits = Scan-LogFile $lf $pats
        foreach ($name in $hits.Keys) {
            $h = $hits[$name]
            Add-Event "unreal:log-$name" ([int]$h.Pattern.tier) $h.Pattern.severity "Unreal - $name" ("{0} coincidencia(s) en {1}. Ultima: {2}" -f $h.Count, (Split-Path -Leaf $lf), $h.Last) $sticky
        }
    }

    # Resultados de pruebas automatizadas (formato index.json; si difiere se registra la limitacion)
    $ad = [string](Get-Cfg 'unreal.automationDir' '')
    if ($ad -and (Test-Path -LiteralPath $ad)) {
        $idx = Get-ChildItem -LiteralPath $ad -Filter index.json -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($idx) {
            $key = 'automation:' + $idx.FullName.ToLowerInvariant()
            if (-not $script:State.once[$key]) {
                $script:State.once[$key] = $true
                $rep = Read-JsonFile $idx.FullName
                if ($rep -and $rep.PSObject.Properties['failed']) {
                    $u.AutomationFailed = [int]$rep.failed
                    if ([int]$rep.failed -gt 0) { Add-Event 'unreal:tests-failed' 2 'warning' 'Pruebas automatizadas con fallos' "$($rep.failed) fallida(s), $($rep.succeeded) correcta(s) en $($idx.Name)." $sticky }
                } else { $script:Report.limitations += 'Reporte de Automation sin campo "failed": formato no reconocido.' }
            }
        }
    }
}

# ---------------------------------------------------------------- Recursos
function Check-Resources {
    $r = @{}
    $root = [string](Get-Cfg 'projectRoot' 'C:\')
    try {
        $drive = (Split-Path -Qualifier $root).TrimEnd(':')
        $d = Get-PSDrive -Name $drive -ErrorAction Stop
        $r.FreeDiskGB = [Math]::Round($d.Free / 1GB, 1)
        if ($r.FreeDiskGB -lt [double](Get-Cfg 'resources.minFreeDiskGB' 20)) {
            Add-Finding 'resources:disk' 2 'warning' 'Poco espacio en disco' "$($r.FreeDiskGB) GB libres en ${drive}: (minimo $(Get-Cfg 'resources.minFreeDiskGB' 20) GB). No se borra nada automaticamente."
        }
    } catch { $script:Report.limitations += "Disco no consultable para $root" }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $r.FreeRamMB = [Math]::Round($os.FreePhysicalMemory / 1024, 0)
        if ($r.FreeRamMB -lt [double](Get-Cfg 'resources.minFreeRamMB' 1024)) {
            Add-Finding 'resources:ram' 2 'warning' 'Poca RAM libre' "$($r.FreeRamMB) MB libres."
        }
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $r.CpuPercent = $cpu
        $n = Step-Counter 'cpu-high' ($cpu -gt [double](Get-Cfg 'resources.maxCpuPercent' 95))
        if ($n -ge 3) { Add-Finding 'resources:cpu' 2 'warning' 'CPU saturada de forma sostenida' "CPU al $cpu% durante $n revisiones." }
    } catch { $script:Report.limitations += 'RAM/CPU no consultables.' }
    $script:Report.resources = $r
}

# ---------------------------------------------------------------- Git / proteccion del trabajo
function Check-Git {
    if (-not (Get-Cfg 'git.enabled' $true)) { return }
    $root = [string](Get-Cfg 'projectRoot' '')
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { $script:Report.limitations += 'git no encontrado en PATH.'; return }
    if (-not (Test-Path -LiteralPath $root)) { return }
    $to = [int](Get-Cfg 'runtime.gitTimeoutSeconds' 60)

    if ([bool](Get-Cfg 'git.allowFetch' $false)) {
        [void](Invoke-External $git.Source @('-C', $root, 'fetch', '--quiet', '--no-tags') $to)   # solo actualiza refs remotas
    }
    $um = [string](Get-Cfg 'git.untrackedMode' 'normal')
    $r = Invoke-External $git.Source @('-C', $root, 'status', '--porcelain=v1', '-b', "--untracked-files=$um") $to
    if ($r.TimedOut) { Add-Finding 'git:status-timeout' 2 'warning' 'git status excedio el tiempo' "Mas de $to s. Repositorio muy grande o bloqueado."; return }
    if ($r.ExitCode -ne 0) { Add-Finding 'git:status-failed' 2 'warning' 'git status fallo' $r.Err; return }

    $lines = @($r.Out -split "`r?`n" | Where-Object { $_ })
    $branchLine = ''
    if ($lines.Count -gt 0 -and $lines[0].StartsWith('##')) { $branchLine = $lines[0]; $lines = @($lines | Select-Object -Skip 1) }
    $conflicts = @($lines | Where-Object { $_ -match '^(UU|AA|DD|AU|UA|DU|UD) ' })
    $g = @{ Branch = $branchLine; Changed = $lines.Count; Conflicts = $conflicts.Count }

    $head = Invoke-External $git.Source @('-C', $root, 'rev-parse', '--short', 'HEAD') 20
    if ($head.ExitCode -eq 0) {
        $sha = $head.Out.Trim(); $g.Head = $sha
        if ($script:State.once['git-head'] -ne $sha) {
            Add-JsonLine (Join-Path $script:Dirs.Logs 'git-history.jsonl') @{ tsUtc = (Get-Date).ToUniversalTime().ToString('o'); head = $sha; branch = (Protect-Text $branchLine 200) }
            $script:State.once['git-head'] = $sha
        }
    }
    if ($conflicts.Count -gt 0) {
        Add-Finding 'git:conflicts' 3 'critical' 'Conflictos de merge sin resolver' "$($conflicts.Count) archivo(s): $((($conflicts | Select-Object -First 5) -join '; '))"
    }
    if ($lines.Count -gt 0) {
        $firstSeen = ConvertTo-Utc $script:State.once['git-dirty-since']
        if ($null -eq $firstSeen) { $firstSeen = [DateTime]::UtcNow; $script:State.once['git-dirty-since'] = $firstSeen.ToString('o') }
        $mins = Get-MinutesSince $firstSeen
        $g.DirtyMinutes = $mins
        if ($mins -gt [int](Get-Cfg 'git.uncommittedWarnMinutes' 120)) {
            Add-Finding 'git:uncommitted' 2 'warning' 'Riesgo de perdida: cambios sin confirmar' "$($lines.Count) archivo(s) modificados/nuevos sin commit desde hace ~$mins min. No se hace commit automatico."
        }
    } else { $script:State.once.Remove('git-dirty-since') }

    if ($branchLine -match '\[(?<s>[^\]]+)\]') {
        $s = $Matches['s']
        if ($s -match 'ahead (\d+)') { $g.Ahead = [int]$Matches[1] }
        if ($s -match 'behind (\d+)') { $g.Behind = [int]$Matches[1] }
        if ($s -match 'gone') { Add-Finding 'git:upstream-gone' 2 'warning' 'La rama remota ya no existe' $branchLine }
        elseif ($s -match 'ahead|behind') { Add-Finding 'git:out-of-sync' 2 'warning' 'Repositorio no sincronizado con el remoto' "Estado: $s (segun ultimo fetch)." }
    } elseif ($branchLine -and $branchLine -notmatch '\.\.\.') {
        Add-Finding 'git:no-upstream' 2 'warning' 'La rama no tiene remoto configurado' $branchLine
    }
    $lock = Join-Path $root '.git\index.lock'
    if (Test-Path -LiteralPath $lock) {
        $lm = Get-MinutesSince (Get-Item -LiteralPath $lock).LastWriteTimeUtc
        $n = Step-Counter 'git-lock' ($lm -gt 10)
        if ($n -ge 1) { Add-Finding 'git:index-lock' 3 'warning' 'index.lock antiguo en el repositorio' "Lleva $lm min. No se borra automaticamente (Nivel 3)." }
    }
    $script:Report.git = $g
}

function Check-Backups {
    $paths = @(Get-Cfg 'backup.paths' @())
    if ($paths.Count -eq 0) {
        Add-Finding 'backup:not-configured' 2 'warning' 'Respaldos no configurados' 'backup.paths esta vacio: el watchdog no puede verificar ningun respaldo. Define una politica y destino (ver docs/README.md).'
        return
    }
    $maxH = [double](Get-Cfg 'backup.maxAgeHours' 26)
    foreach ($p in $paths) {
        $exp = [Environment]::ExpandEnvironmentVariables($p)
        if (-not (Test-Path -LiteralPath $exp)) { Add-Finding "backup:missing:$p" 2 'critical' 'Destino de respaldo inaccesible' "No accesible: $p"; continue }
        $newest = Get-NewestActivity @($exp)
        $h = $null; if ($newest) { $h = [Math]::Round((Get-MinutesSince $newest) / 60, 1) }
        if ($null -eq $h -or $h -gt $maxH) { Add-Finding "backup:stale:$p" 2 'warning' 'Respaldo desactualizado' "Ultima escritura en $p hace $h h (limite $maxH h)." }
    }
}

# Coordinacion entre agentes: cada agente declara los archivos que edita (Send-JarvisHeartbeat -Claim).
function Check-Claims {
    $dir = [string](Get-Cfg 'claims.dir' (Join-Path $script:Dirs.State 'claims'))
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $exp = [int](Get-Cfg 'claims.expireMinutes' 240)
    $claims = @()
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue) {
        $c = Read-JsonFile $f.FullName
        if (-not $c) { continue }
        $age = Get-MinutesSince (ConvertTo-Utc $c.timestampUtc)
        if ($null -ne $age -and $age -le $exp) { $claims += $c }
    }
    for ($i = 0; $i -lt $claims.Count; $i++) {
        for ($j = $i + 1; $j -lt $claims.Count; $j++) {
            $a = $claims[$i]; $b = $claims[$j]
            if ($a.agent -eq $b.agent) { continue }
            $common = @(@($a.files) | Where-Object { $_ -and (@($b.files) -contains $_) })
            if ($common.Count -gt 0) {
                Add-Finding "claims:overlap:$($a.agent)-$($b.agent)" 3 'critical' 'Dos agentes editan los mismos archivos' "$($a.agent) y $($b.agent): $((($common | Select-Object -First 5) -join '; '))"
            }
        }
    }
    $script:Report.claims = $claims.Count
}
