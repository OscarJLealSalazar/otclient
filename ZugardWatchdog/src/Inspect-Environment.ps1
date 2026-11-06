<#
 Inspeccion del entorno (SOLO LECTURA). Escribe reports\environment-<fecha>.json y un resumen en pantalla.
 No imprime valores de variables de entorno ni credenciales (solo si existen). Las URLs de remotos se limpian de credenciales.
#>
param([string]$ProjectRoot = 'E:\WorldOfZugard', [string]$InstallRoot = 'E:\ZugardWatchdog')
$ErrorActionPreference = 'Continue'
function Strip($s) { [regex]::Replace("$s", '://[^/@\s]+@', '://[redactado]@') }
$r = [ordered]@{}
$r.collectedUtc = (Get-Date).ToUniversalTime().ToString('o')
$r.windows = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture)
$r.powershell = $PSVersionTable.PSVersion.ToString()
$r.user = "$env:USERDOMAIN\$env:USERNAME"
$r.paths = [ordered]@{ project = (Test-Path $ProjectRoot); installRoot = (Test-Path $InstallRoot) }

$pat = 'claude|codex|jarvis|unreal|ue4|ue5|ShaderCompile|UnrealBuildTool|MSBuild|node|python|discord'
$r.processes = @(Get-Process | Where-Object { $_.ProcessName -match $pat } | ForEach-Object {
    $resp = $null; try { $resp = $_.Responding } catch { }
    [ordered]@{ name = $_.ProcessName; pid = $_.Id; start = $(try { $_.StartTime.ToString('o') } catch { $null }); responding = $resp }
})

$r.tools = [ordered]@{}
foreach ($t in 'git', 'node', 'npm', 'python', 'claude', 'codex', 'pwsh', 'dotnet', 'msbuild') {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    $r.tools[$t] = $(if ($c) { $c.Source } else { $null })
}

if ((Test-Path $ProjectRoot) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $g = [ordered]@{}
    $g.toplevel = (git -C $ProjectRoot rev-parse --show-toplevel 2>&1 | Out-String).Trim()
    $g.branch   = (git -C $ProjectRoot branch --show-current 2>&1 | Out-String).Trim()
    $g.remotes  = @(git -C $ProjectRoot remote -v 2>&1 | ForEach-Object { Strip $_ })
    $g.statusCount = @(git -C $ProjectRoot status --porcelain 2>&1).Count
    $r.git = $g
}

$r.scheduledTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'jarvis|zugard|claude|codex|unreal|backup' } |
    ForEach-Object { [ordered]@{ name = $_.TaskName; path = $_.TaskPath; state = "$($_.State)" } })

$r.codex = [ordered]@{
    configHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
    configTomlExists = (Test-Path (Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }) 'config.toml'))
}
$r.claude = [ordered]@{ homeExists = (Test-Path (Join-Path $env:USERPROFILE '.claude')) }
$r.notifications = [ordered]@{
    discordEnvVarPresent = [bool]([Environment]::GetEnvironmentVariable('ZUGARD_DISCORD_WEBHOOK', 'User') -or $env:ZUGARD_DISCORD_WEBHOOK)
    dpapiWebhookPresent  = (Test-Path (Join-Path $InstallRoot 'secrets\discord.webhook.dpapi'))
}
$r.candidates = [ordered]@{}
if (Test-Path $ProjectRoot) {
    $r.candidates.unrealLogs = (Test-Path (Join-Path $ProjectRoot 'Saved\Logs'))
    $r.candidates.uprojectFiles = @(Get-ChildItem $ProjectRoot -Filter *.uproject -File -ErrorAction SilentlyContinue | ForEach-Object Name)
}
$r.candidates.ubtLog = (Test-Path (Join-Path $env:LOCALAPPDATA 'UnrealBuildTool\Log.txt'))
$drive = Split-Path -Qualifier $ProjectRoot
$r.candidates.jarvisLike = @(Get-ChildItem "$drive\" -Directory -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'jarvis|coordinator|agents' } | ForEach-Object FullName)

$out = Join-Path $InstallRoot ('reports\environment-{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path (Split-Path $out) -Force | Out-Null
$r | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host "Inspeccion guardada en $out"
$r | ConvertTo-Json -Depth 4
