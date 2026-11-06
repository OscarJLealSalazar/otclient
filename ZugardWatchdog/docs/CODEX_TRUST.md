# Codex Remote Control: «Can't verify project trust for E:\WorldOfZugard.»

**No diagnosticable desde el entorno actual** (Linux en la nube, sin acceso a tu PC). No se intenta eludir la comprobación de confianza. Lo siguiente son hipótesis a comprobar, no hechos.

## Hipótesis (de más a menos probable)
1. **El proyecto no está marcado como confiable** en la config de Codex del PC.
2. **Git no puede verificar el repo** («dubious ownership» si el dueño de `E:\WorldOfZugard` difiere del usuario actual, típico en discos externos/copiados), o la carpeta no es un repo.
3. **Ruta inaccesible** en ese momento (unidad `E:` desconectada, PC bloqueado/dormido, Remote Control con otro usuario).

## Procedimiento humano (requiere estar en el PC, o una sesión con acceso al PC y tu aprobación)
1. En PowerShell: `git -C E:\WorldOfZugard rev-parse --show-toplevel`
   - Si dice *dubious ownership*: decidir si confías en esa carpeta y entonces `git config --global --add safe.directory E:/WorldOfZugard` (**cambio de seguridad: solo con tu decisión**).
2. Abrir Codex en `E:\WorldOfZugard` en el PC y aceptar el diálogo de confianza **tú mismo**. Debería quedar en `%USERPROFILE%\.codex\config.toml` (o `%CODEX_HOME%`):
   ```toml
   [projects.'E:\WorldOfZugard']
   trust_level = "trusted"
   ```
3. Reiniciar el servicio de Remote Control de Codex y reintentar desde Android.
4. Si persiste, copiar el texto exacto del error y los logs de Codex a una sesión con acceso al PC.

## Detección anticipada (ya implementada en `Check-CodexTrust`)
Cada 15 min: (a) existe la ruta del proyecto, (b) `config.toml` registra `trust_level = "trusted"` para ella, (c) `git rev-parse` funciona (detecta *dubious ownership*), (d) patrones `trust`/`auth` en los logs de Codex que configures en `agents.codex.logFiles`. Cualquier fallo → alerta Nivel 3 por Discord. Limitación: el formato de `config.toml` se basa en la documentación de Codex; verificar tras el primer informe (`reports\latest.json` → `codexTrust`).
