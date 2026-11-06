# Jarvis Watchdog — World of Zugard

Supervisor independiente (PowerShell 5.1 + Programador de tareas) que se ejecuta cada 15 min, **solo observa y avisa**: no reinicia, cierra ni modifica Claude, Codex, Jarvis, Unreal ni el repositorio.

> **Estado: ESCRITO, NO INSTALADO NI PROBADO.** Se generó desde un contenedor Linux sin acceso a Windows. Ver `docs/VALIDATION_REPORT.md`.

## Estructura
```
src/Watchdog.ps1              ciclo principal (mutex, límites de tiempo, informes, alertas)
src/lib/Common.ps1            config, estado, logs, redacción de secretos, recuperación Nivel 1 acotada
src/lib/Checks.ps1            Claude/Codex, confianza Codex, Jarvis, Unreal, recursos, Git, respaldos, claims
src/lib/Notify.ps1            Discord (webhook), outbox con reintentos limitados
src/Install-Watchdog.ps1      copia sin sobrescribir + tarea programada (15 min + al iniciar sesión)
src/Uninstall-Watchdog.ps1    quita solo la tarea; conserva archivos
src/Send-JarvisHeartbeat.ps1  integración para Jarvis/agentes (heartbeat, progreso, handoff, claims)
src/Set-DiscordWebhook.ps1    guarda el webhook cifrado (DPAPI)
src/Inspect-Environment.ps1   inspección de solo lectura del entorno
src/Test-Watchdog.ps1         pruebas en sandbox con datos simulados
config/watchdog.config.json   toda la configuración
docs/                         operación, confianza de Codex, validación, riesgos
```

## Instalación (en el PC, una vez que Claude tenga acceso o con tú en el teclado)
```powershell
powershell -ExecutionPolicy Bypass -File .\src\Inspect-Environment.ps1      # solo lectura
powershell -ExecutionPolicy Bypass -File .\src\Test-Watchdog.ps1            # sandbox, sin enviar nada
powershell -ExecutionPolicy Bypass -File .\src\Install-Watchdog.ps1 -WhatIf # simulación
powershell -ExecutionPolicy Bypass -File .\src\Install-Watchdog.ps1 -RunNow # instala y ejecuta una vez
powershell -ExecutionPolicy Bypass -File .\src\Set-DiscordWebhook.ps1 -SendTest
```
Luego revisar `config\watchdog.config.json` (nombres de proceso, `expectedRunning`, rutas de logs/telemetría de agentes, `backup.paths`).

## Integrar Jarvis
Al iniciar/avanzar/terminar cada tarea: `Send-JarvisHeartbeat.ps1 -Agent claude -Task "..." -Status working -Progress`.
Sin `-Progress` el heartbeat solo prueba que Jarvis está vivo; con `-Progress` se declara avance verificable. Formato en `state\jarvis_heartbeat.json`. Para coordinar ediciones: `-Claim archivo1,archivo2`.

## Verificar desde Android
1. **Discord**: llegan alertas (🔴/🟡), avisos «Resuelto» y un resumen diario (21:00 por defecto).
2. **Sin Discord**: pide a Claude (sesión con acceso al PC) leer `E:\ZugardWatchdog\reports\latest.md` y `state\watchdog_heartbeat.json` (debe tener < 20 min).
3. Si **dejan de llegar** el resumen diario y los mensajes, el propio watchdog puede estar caído (ver riesgo R1).
