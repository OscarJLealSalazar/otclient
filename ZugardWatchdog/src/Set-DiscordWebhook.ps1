<#
 Guarda el webhook de Discord cifrado con DPAPI (solo lo descifra el mismo usuario de Windows en el mismo equipo).
 Se pide de forma oculta; nunca se imprime ni se registra.
 Crear el webhook: Discord > Ajustes del canal > Integraciones > Webhooks > Nuevo webhook > Copiar URL.
#>
param([string]$InstallRoot = 'E:\ZugardWatchdog', [switch]$SendTest)
$ErrorActionPreference = 'Stop'
$sec = Read-Host 'Pega la URL del webhook de Discord' -AsSecureString
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
if ($plain -notmatch '^https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w\-]+$') { throw 'La URL no parece un webhook de Discord valido.' }
$dir = Join-Path $InstallRoot 'secrets'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$sec | ConvertFrom-SecureString | Set-Content -LiteralPath (Join-Path $dir 'discord.webhook.dpapi') -Encoding ASCII
Write-Host 'Webhook guardado (cifrado).'
if ($SendTest) {
    Invoke-RestMethod -Method Post -Uri $plain -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes('{"username":"Jarvis Watchdog","content":"Prueba de Jarvis Watchdog: canal configurado."}')) | Out-Null
    Write-Host 'Mensaje de prueba enviado.'
}
