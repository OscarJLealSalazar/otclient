# Informe de instalación y validación

Fecha: 2026-11-06 · Entorno de ejecución: contenedor Linux en la nube (no Windows).

## Acceso a Windows — comprobado
| Comprobación | Resultado real |
|---|---|
| `list_computer_folders` (Remote Control) | `folders: []`, `cannot_be_used: []` → **ningún PC conectado** |
| SO local | `Linux 6.18 x86_64` |
| `powershell`, `pwsh`, `cmd.exe` | no existen |
| `E:\`, `/mnt/e` | no existen |

**Conexión que falta:** sesión de Claude Code con acceso a tu PC (Claude Desktop en Windows → Settings → Claude Code → Remote Control, compartiendo la carpeta `E:\ZugardWatchdog` o `E:\WorldOfZugard`; o `claude remote-control` en esa carpeta). Con ello puedo instalar y validar sin que tú ejecutes nada. El PC debe estar encendido y con Claude abierto.

## Qué se hizo
Solo generación de archivos (este directorio), en la rama de trabajo del repositorio `otclient` porque es la única disponible en esta sesión. Es un directorio nuevo; no se modificó código existente.

## Qué NO se hizo / no se verificó
- Inspección del entorno (Windows, procesos, Git de WorldOfZugard, tareas programadas, Discord existente, canales Claude↔Codex↔Jarvis): **no realizada** (no hay acceso). `Inspect-Environment.ps1` la hace en un paso.
- Instalación, tarea programada, 15 min, persistencia tras reinicio: **no realizadas**.
- Ejecución de cualquier script: **ninguna**. Intenté descargar PowerShell para Linux solo para validar sintaxis; el sistema bloqueó ejecutarlo y no lo eludí. **Los scripts no han sido ni siquiera analizados sintácticamente**; es probable que haya errores a corregir en el primer arranque.
- Alertas a Discord: no probadas (no hay webhook; se desconoce si existe integración).
- Diagnóstico del error de confianza de Codex: no posible (ver `CODEX_TRUST.md`).

## Pruebas preparadas (pendientes de ejecutar en el PC)
`Test-Watchdog.ps1` (sandbox, sin tocar procesos reales): ejecución manual, creación de logs/informes, heartbeat vencido, sin progreso, errores pendientes, handoff incompleto, agente caído, compilación fallida/fatal simulados, solape de claims, cambios sin commit, alertas generadas y sin repetición, redacción de secretos, rechazo de segunda instancia (exit 3), resumen diario.
Pendientes además: ejecución vía Programador de tareas (`Install-Watchdog.ps1 -RunNow`), webhook real (`Set-DiscordWebhook.ps1 -SendTest`), reinicio de Windows.

## Criterios de finalización
**Ninguno cumplido todavía.** La misión no está completada.
