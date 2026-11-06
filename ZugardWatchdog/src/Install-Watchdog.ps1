<#
 Instala Jarvis Watchdog. NO sobrescribe archivos existentes (si difieren, escribe "<archivo>.new").
 No cambia permisos de seguridad ni politicas de ejecucion del sistema (usa -ExecutionPolicy Bypass solo para su propio proceso).
 Uso:  powershell -File Install-Watchdog.ps1 [-InstallRoot E:\ZugardWatchdog] [-WhatIf] [-RunNow]
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallRoot = 'E:\ZugardWatchdog',
    [string]$TaskName = 'ZugardWatchdog',
    [int]$IntervalMinutes = 15,
    [switch]$RunNow
)
$ErrorActionPreference = 'Stop'
$srcRoot = Split-Path -Parent $PSScriptRoot
$tag = 'ZugardWatchdog-managed'

Write-Host "Windows: $([Environment]::OSVersion.VersionString) | PowerShell: $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { throw 'Este instalador solo funciona en Windows.' }
if (-not (Test-Path -LiteralPath (Split-Path -Qualifier $InstallRoot))) { throw "La unidad de $InstallRoot no existe." }

# 1) Copiar archivos sin sobrescribir
foreach ($sub in 'src', 'src\lib', 'config', 'docs', 'logs', 'state', 'reports') {
    $d = Join-Path $InstallRoot $sub
    if (-not (Test-Path -LiteralPath $d) -and $PSCmdlet.ShouldProcess($d, 'Crear carpeta')) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
foreach ($f in Get-ChildItem -LiteralPath $srcRoot -Recurse -File | Where-Object { $_.FullName -match '\\(src|config|docs)\\' -or $_.Name -eq 'README.md' }) {
    $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
    $dest = Join-Path $InstallRoot $rel
    if ($dest -eq $f.FullName) { continue }
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir) -and $PSCmdlet.ShouldProcess($destDir, 'Crear carpeta')) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $dest)) {
        if ($PSCmdlet.ShouldProcess($dest, 'Copiar')) { Copy-Item -LiteralPath $f.FullName -Destination $dest }
    } elseif ((Get-FileHash $dest).Hash -ne (Get-FileHash $f.FullName).Hash) {
        Write-Warning "Existe y difiere (no se sobrescribe): $dest  -> se guarda $dest.new"
        if ($PSCmdlet.ShouldProcess("$dest.new", 'Copiar')) { Copy-Item -LiteralPath $f.FullName -Destination "$dest.new" -Force }
    }
}

# 2) Tarea programada
$script = Join-Path $InstallRoot 'src\Watchdog.ps1'
if (-not (Test-Path -LiteralPath $script) -and -not $WhatIfPreference) { throw "No se encontro $script" }
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing -and $existing.Description -notlike "*$tag*") { throw "Ya existe una tarea '$TaskName' que no fue creada por este instalador. Usa -TaskName distinto." }

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $psExe -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $script)
$rep = (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650))
$logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$logon.Repetition = $rep.Repetition
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

if ($PSCmdlet.ShouldProcess($TaskName, 'Registrar tarea programada')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($rep, $logon) -Settings $settings -Principal $principal `
        -Description "Jarvis Watchdog - World of Zugard ($tag). Cada $IntervalMinutes min." -Force | Out-Null
    Write-Host "Tarea '$TaskName' registrada (cada $IntervalMinutes min y al iniciar sesion)."
    if ($RunNow) {
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 20
        $i = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host "LastRunTime=$($i.LastRunTime) LastTaskResult=$($i.LastTaskResult) NextRunTime=$($i.NextRunTime)"
        $log = Get-ChildItem (Join-Path $InstallRoot 'logs') -Filter 'watchdog-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) { Write-Host "Log: $($log.FullName)"; Get-Content $log.FullName -Tail 5 } else { Write-Warning 'Aun no hay log; revisar en un minuto.' }
    }
}
Write-Host 'Siguiente: ejecutar src\Inspect-Environment.ps1 y configurar el webhook (src\Set-DiscordWebhook.ps1).'
