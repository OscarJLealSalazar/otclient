# Jarvis Watchdog - infraestructura comun. Compatible con Windows PowerShell 5.1.
# NOTA: escrito sin poder ejecutarlo (ver docs/VALIDATION_REPORT.md).
Set-StrictMode -Version 1.0

function Get-Cfg {
    param([string]$Path, $Default = $null)
    $o = $script:Cfg
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $o) { return $Default }
        $pr = $o.PSObject.Properties[$p]
        if ($null -eq $pr) { return $Default }
        $o = $pr.Value
    }
    if ($null -eq $o) { return $Default }
    return $o
}

function ConvertTo-Hashtable {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($Obj -is [System.Array]) { return ,@($Obj | ForEach-Object { ConvertTo-Hashtable $_ }) }
    return $Obj
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonAtomic {
    param([string]$Path, $Object, [int]$Depth = 8)
    $tmp = "$Path.tmp"
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ConvertTo-Json -InputObject $Object -Depth $Depth | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Add-JsonLine {
    param([string]$Path, $Object)
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = (ConvertTo-Json -InputObject $Object -Depth 6 -Compress) + [Environment]::NewLine
        [System.IO.File]::AppendAllText($Path, $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function ConvertTo-Utc {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    try {
        return ([DateTime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
    } catch { return $null }
}

function Get-MinutesSince {
    param($Utc)
    if ($null -eq $Utc) { return $null }
    return [Math]::Round(([DateTime]::UtcNow - $Utc).TotalMinutes, 1)
}

# Elimina webhooks, tokens y secretos de cualquier texto que se registre o envie.
function Protect-Text {
    param([string]$Text, [int]$Max = 500)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, 'https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\S+', '[webhook-redactado]')
    $t = [regex]::Replace($t, '(?i)(token|secret|password|passwd|apikey|api_key|authorization|bearer)(\s*[:=]\s*|\s+)\S+', '$1=[redactado]')
    $t = [regex]::Replace($t, '\b(?:sk|pk|gh[pousr]|xox[abp])[-_][A-Za-z0-9_\-]{16,}', '[token-redactado]')
    $t = [regex]::Replace($t, '\b[A-Za-z0-9+/_\-]{40,}={0,2}', '[cadena-larga-redactada]')
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '...' }
    return $t
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, (Protect-Text $Message 1500)
    try {
        $f = Join-Path $script:Dirs.Logs ('watchdog-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        [System.IO.File]::AppendAllText($f, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    if ($VerbosePreference -eq 'Continue' -or $env:WATCHDOG_CONSOLE) { Write-Host $line }
}

function Initialize-Dirs {
    $root = Get-Cfg 'watchdogRoot' (Split-Path -Parent $PSScriptRoot)
    $script:Dirs = @{
        Root    = $root
        Logs    = Join-Path $root 'logs'
        State   = Join-Path $root 'state'
        Reports = Join-Path $root 'reports'
        Outbox  = Join-Path $root 'state\outbox'
    }
    foreach ($d in $script:Dirs.Values) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Load-State {
    $p = Join-Path $script:Dirs.State 'state.json'
    $raw = Read-JsonFile $p
    $s = $null
    if ($raw) { $s = ConvertTo-Hashtable $raw }
    if ($null -eq $s) { $s = @{} }
    foreach ($k in 'alerts', 'events', 'counters', 'agents', 'files', 'recovery', 'summary', 'once') {
        if (-not ($s[$k] -is [System.Collections.IDictionary])) { $s[$k] = @{} }
    }
    $script:State = $s
}

function Save-State {
    try { Write-JsonAtomic (Join-Path $script:Dirs.State 'state.json') $script:State 8 }
    catch { Write-Log 'ERROR' "No se pudo guardar el estado: $($_.Exception.Message)" }
}

function Add-Finding {
    param([string]$Id, [int]$Tier, [string]$Severity, [string]$Title, [string]$Detail = '')
    [void]$script:Findings.Add([pscustomobject]@{
        Id = $Id; Tier = $Tier; Severity = $Severity; Title = $Title
        Detail = (Protect-Text $Detail); Area = $Id.Split(':')[0]
    })
}

# Hallazgo "pegajoso": sigue activo stickyMinutes aunque el log ya no lo repita.
function Add-Event {
    param([string]$Id, [int]$Tier, [string]$Severity, [string]$Title, [string]$Detail = '', [int]$StickyMinutes = 60)
    $script:State.events[$Id] = @{
        Tier = $Tier; Severity = $Severity; Title = $Title; Detail = (Protect-Text $Detail)
        Expires = ([DateTime]::UtcNow.AddMinutes($StickyMinutes)).ToString('o')
    }
}

function Restore-Events {
    foreach ($id in @($script:State.events.Keys)) {
        $e = $script:State.events[$id]
        $exp = ConvertTo-Utc $e.Expires
        if ($null -eq $exp -or $exp -lt [DateTime]::UtcNow) { $script:State.events.Remove($id); continue }
        Add-Finding $id ([int]$e.Tier) $e.Severity $e.Title $e.Detail
    }
}

# Cuenta ejecuciones consecutivas en que se cumple una condicion.
function Step-Counter {
    param([string]$Key, [bool]$Condition)
    $n = 0
    if ($Condition) { $n = 1 + [int]$script:State.counters[$Key] }
    $script:State.counters[$Key] = $n
    return $n
}

function Invoke-External {
    param([string]$File, [string[]]$ArgList, [int]$TimeoutSec = 30)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = (($ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $psi.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }   # solo procesos propios del watchdog (git)
            return @{ ExitCode = -1; TimedOut = $true; Out = ''; Err = 'timeout' }
        }
        return @{ ExitCode = $p.ExitCode; TimedOut = $false; Out = $so.Result; Err = $se.Result }
    } catch {
        return @{ ExitCode = -2; TimedOut = $false; Out = ''; Err = $_.Exception.Message }
    }
}

function Get-FileTail {
    param([string]$Path, [long]$Start)
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, 'Open', 'Read', 'ReadWrite, Delete')
        [void]$fs.Seek($Start, 'Begin')
        $buf = New-Object byte[] ([int]($fs.Length - $Start))
        $n = $fs.Read($buf, 0, $buf.Length)
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
    } finally { if ($fs) { $fs.Dispose() } }
}

# Analiza solo los bytes NUEVOS de un log. La primera vez fija una linea base (no alerta por historial).
function Scan-LogFile {
    param([string]$Path, $Patterns)
    $res = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $res }
    $len = (Get-Item -LiteralPath $Path).Length
    $key = $Path.ToLowerInvariant()
    $prev = $script:State.files[$key]
    $script:State.files[$key] = $len
    if ($null -eq $prev) { Write-Log 'INFO' "Linea base de log fijada: $Path ($len bytes)"; return $res }
    $start = [long]$prev
    if ($start -gt $len) { $start = 0 }
    if (($len - $start) -gt 1048576) { $start = $len - 1048576 }
    if ($len -le $start) { return $res }
    $text = Get-FileTail $Path $start
    $lines = $text -split "`r?`n"
    foreach ($pat in $Patterns) {
        $min = 1
        if ($pat.PSObject.Properties['minCount']) { $min = [int]$pat.minCount }
        $count = 0; $last = ''
        foreach ($l in $lines) {
            if ($l.Length -gt 0 -and [regex]::IsMatch($l, $pat.regex)) { $count++; $last = $l }
        }
        if ($count -ge $min) { $res[$pat.name] = @{ Count = $count; Last = $last; Pattern = $pat } }
    }
    return $res
}

function Resolve-NewestFile {
    param([string]$PathOrGlob)
    $p = [Environment]::ExpandEnvironmentVariables($PathOrGlob)
    $items = @(Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    if ($items.Count -gt 0) { return $items[0] }
    return $null
}

# Recuperacion Nivel 1 con limites: maximo de intentos por dia e intervalo minimo.
function Invoke-Tier1 {
    param([string]$Name, [scriptblock]$Action)
    $r = $script:State.recovery[$Name]
    if ($null -eq $r) { $r = @{ WindowStart = [DateTime]::UtcNow.ToString('o'); Count = 0; Last = $null } }
    $ws = ConvertTo-Utc $r.WindowStart
    if ($null -eq $ws -or ([DateTime]::UtcNow - $ws).TotalHours -ge 24) { $r.WindowStart = [DateTime]::UtcNow.ToString('o'); $r.Count = 0 }
    $last = ConvertTo-Utc $r.Last
    $maxDay = [int](Get-Cfg 'recovery.maxAttemptsPerDay' 3)
    $minInt = [int](Get-Cfg 'recovery.minIntervalMinutes' 10)
    $result = 'skipped'
    if ([int]$r.Count -ge $maxDay) { $result = 'skipped:limite-diario' }
    elseif ($last -and ([DateTime]::UtcNow - $last).TotalMinutes -lt $minInt) { $result = 'skipped:intervalo-minimo' }
    else {
        $r.Count = [int]$r.Count + 1
        $r.Last = [DateTime]::UtcNow.ToString('o')
        try { & $Action; $result = 'ok' } catch { $result = 'error: ' + $_.Exception.Message }
    }
    $script:State.recovery[$Name] = $r
    Add-JsonLine (Join-Path $script:Dirs.Logs 'recovery.jsonl') @{ tsUtc = (Get-Date).ToUniversalTime().ToString('o'); tier = 1; action = $Name; result = (Protect-Text $result 200) }
    Write-Log 'INFO' "Recuperacion Nivel 1 '$Name': $result"
    return $result
}
