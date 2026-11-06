# Riesgos y mejoras futuras

## Riesgos
- **R0 Sin probar.** Código sin ejecutar ni validar sintaxis; esperar correcciones en la primera ejecución.
- **R1 El watchdog puede caer en silencio.** Mitigación futura (requiere tu autorización por ser servicio externo): ping a un monitor tipo dead-man (healthchecks.io u otro) cada ejecución; o segunda tarea de verificación cruzada con Jarvis.
- **R2 Falsos negativos de Claude/Codex:** sin telemetría oficial; depende de que Jarvis declare `-Progress` y de `activityPaths/logFiles` correctos.
- **R3 Tarea solo con sesión iniciada:** si Windows reinicia sin iniciar sesión, no hay supervisión. Alternativa: S4U/cuenta de servicio (implica decisión de seguridad tuya y rehacer el almacenamiento del webhook).
- **R4 Webhook en el PC:** cifrado DPAPI por usuario; quien controle tu sesión puede usarlo. Rotarlo si se sospecha filtración.
- **R5 `git status` en proyectos UE grandes** puede ser lento (timeout 60 s, `GIT_OPTIONAL_LOCKS=0`, `untrackedMode` configurable).
- **R6 Sin política de respaldo/commit automático** por mandato: el riesgo de pérdida solo se **avisa**.
- **R7 Ventana de PowerShell oculta** puede parpadear cada 15 min.
- **R8 Patrones de log** pueden dar falsos positivos (p. ej. «error-burst»); ajustar `patterns` en la config.

## Mejoras
Política de respaldos (destino verificado, exclusión de secretos) y commits en rama `wip/` con aprobación; wrapper que lance Claude/Codex y emita heartbeats solo; notificación con botones de aprobación (Discord bot); métricas históricas; rotación/archivado de logs; pruebas Pester; cuenta de servicio dedicada.
