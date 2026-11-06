# Operación, niveles de recuperación y mantenimiento

## Niveles
| Nivel | Qué hace el watchdog | Implementado |
|---|---|---|
| 1 Automático | Reintentar mensajes Discord fallidos (outbox, máx. 5 intentos, descarta a las 24 h); regenerar `reports\latest.*`; la tarea programada reintenta (2 veces, 5 min) | Sí, vía `Invoke-Tier1` (máx. 3 intentos/día por acción, ≥10 min entre intentos; cada intento en `logs\recovery.jsonl`) |
| 2 Diagnóstico + aviso | Proceso caído, heartbeat vencido, tarea sin progreso/bloqueada, handoff incompleto, compilación/prueba fallida, Unreal sin responder, repo desincronizado, cambios sin commit, disco/RAM/CPU, respaldos | Sí |
| 3 Requiere autorización | Conflictos git, `index.lock`, solape de archivos entre agentes, confianza/autenticación de Codex, tarea `waiting_human`. Mensaje marcado «REQUIERE TU AUTORIZACIÓN» | Solo aviso; el watchdog **nunca** ejecuta estas acciones |

Nunca se ejecuta: `git reset/clean/push/commit`, cierre de procesos, borrado de cachés, cambios de permisos o confianza.

## Anti-spam
- Una alerta por problema; recordatorio cada 60 min (crítico) / 240 min (warning); un solo mensaje agrupado por ejecución.
- «Resuelto» tras 2 revisiones limpias. Hallazgos de logs son «pegajosos» 60 min.
- Primera lectura de cada log = línea base (no alerta por historial).

## Archivos de datos (`E:\ZugardWatchdog`)
`logs\watchdog-AAAAMMDD.log`, `runs.jsonl`, `alerts.jsonl`, `recovery.jsonl`, `git-history.jsonl`, `heartbeats.jsonl` · `state\state.json`, `watchdog_heartbeat.json`, `outbox\`, `claims\` · `reports\latest.json|md`. Los logs no se borran solos: archivar a mano ocasionalmente.

## Mantenimiento
- Actualizar: copiar nueva versión y ejecutar `Install-Watchdog.ps1`; lo que difiera queda como `*.new` (comparar y reemplazar a mano). `config` nunca se pisa.
- Desinstalar: `Uninstall-Watchdog.ps1` (conserva archivos).
- Parar temporalmente: `Disable-ScheduledTask -TaskName ZugardWatchdog`.
- Tarea: usuario actual, solo con sesión iniciada (necesario para el webhook DPAPI y ver procesos de la sesión), disparadores: cada 15 min + al iniciar sesión, `IgnoreNew`, límite 10 min.

## Limitaciones conocidas (indicadores verificables únicamente)
- Claude/Codex: sin API de estado → solo proceso, delta de CPU, y archivos/logs que configures en `activityPaths`/`logFiles`. Un proceso abierto no prueba progreso; el progreso real lo declara Jarvis con `-Progress`.
- Rutas de logs de Claude/Codex y nombres exactos de procesos: confirmar con `Inspect-Environment.ps1`.
- Formato de `Saved\Automation\**\index.json` asumido (`failed`/`succeeded`); si difiere se registra la limitación.
