<#
 Desinstala SOLO la tarea programada del watchdog. No borra archivos, logs ni estado (hazlo manualmente si quieres).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$TaskName = 'ZugardWatchdog')
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $t) { Write-Host "No existe la tarea '$TaskName'."; return }
if ($t.Description -notlike '*ZugardWatchdog-managed*') { throw "La tarea '$TaskName' no fue creada por este instalador; no se toca." }
if ($PSCmdlet.ShouldProcess($TaskName, 'Eliminar tarea programada')) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Tarea '$TaskName' eliminada. Archivos conservados."
}
