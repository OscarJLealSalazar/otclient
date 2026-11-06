# Jarvis Watchdog - notificaciones (Discord por webhook). El webhook NUNCA se registra ni se imprime.
Set-StrictMode -Version 1.0

function Get-WebhookUrl {
    $url = $null
    $envName = [string](Get-Cfg 'notify.discordWebhookEnvVar' 'ZUGARD_DISCORD_WEBHOOK')
    $url = [Environment]::GetEnvironmentVariable($envName)
    if (-not $url) { $url = [Environment]::GetEnvironmentVariable($envName, 'User') }
    if (-not $url) {
        $f = Join-Path $script:Dirs.Root 'secrets\discord.webhook.dpapi'
        if (Test-Path -LiteralPath $f) {
            try {
                $sec = (Get-Content -LiteralPath $f -Raw).Trim() | ConvertTo-SecureString
                $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
                try { $url = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
            } catch { Write-Log 'WARN' 'No se pudo descifrar el webhook (usuario distinto al que lo guardo?).' }
        }
    }
    if ($url -and $url -match '^https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w\-]+$') { return $url }
    return $null
}

function Send-Discord {
    param([string]$Text)
    $url = Get-WebhookUrl
    if (-not $url) { return @{ Ok = $false; Reason = 'webhook-no-configurado' } }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $payload = ConvertTo-Json -InputObject @{ username = 'Jarvis Watchdog'; content = $Text } -Compress
        Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 15 | Out-Null
        return @{ Ok = $true; Reason = 'enviado' }
    } catch {
        return @{ Ok = $false; Reason = (Protect-Text $_.Exception.Message 200) }
    }
}

# Envia o encola. Siempre deja constancia local en alerts.jsonl.
function Dispatch-Message {
    param([string]$Kind, [string[]]$Ids, [string]$Text)
    $Text = Protect-Text $Text 1900
    $mode = [string](Get-Cfg 'notify.mode' 'discord')
    $outcome = 'solo-local'
    if ($mode -eq 'discord') {
        $r = Send-Discord $Text
        if ($r.Ok) { $outcome = 'enviado' }
        elseif ($r.Reason -eq 'webhook-no-configurado') {
            $outcome = 'sin-webhook'
            $script:Report.needsSetup += 'Discord: webhook no configurado (ver docs/README.md, Set-DiscordWebhook.ps1)'
        } else {
            $outcome = 'encolado'
            $name = '{0}-{1}.json' -f (Get-Date).ToString('yyyyMMddHHmmssfff'), $Kind
            Write-JsonAtomic (Join-Path $script:Dirs.Outbox $name) @{ text = $Text; attempts = 1; createdUtc = (Get-Date).ToUniversalTime().ToString('o'); lastError = $r.Reason }
            Write-Log 'WARN' "Discord fallo, mensaje encolado: $($r.Reason)"
        }
    }
    Add-JsonLine (Join-Path $script:Dirs.Logs 'alerts.jsonl') @{ tsUtc = (Get-Date).ToUniversalTime().ToString('o'); kind = $Kind; ids = $Ids; outcome = $outcome; text = $Text }
    return $outcome
}

# Recuperacion Nivel 1: reintentar mensajes fallidos (max N intentos, descarta tras 24 h).
function Invoke-OutboxRetry {
    $max = [int](Get-Cfg 'notify.outboxMaxAttempts' 5)
    foreach ($f in @(Get-ChildItem -LiteralPath $script:Dirs.Outbox -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $m = Read-JsonFile $f.FullName
        if (-not $m) { continue }
        $created = ConvertTo-Utc $m.createdUtc
        $age = Get-MinutesSince $created
        if ([int]$m.attempts -ge $max -or ($null -ne $age -and $age -gt 1440)) {
            # No se borra: se renombra para auditoria.
            Move-Item -LiteralPath $f.FullName -Destination ($f.FullName + '.abandoned') -Force
            Write-Log 'WARN' "Mensaje de outbox abandonado: $($f.Name)"
            continue
        }
        $name = $f.Name
        $res = Invoke-Tier1 "outbox:$name" {
            $r = Send-Discord $m.text
            if (-not $r.Ok) { throw $r.Reason }
        }
        if ($res -eq 'ok') { Move-Item -LiteralPath $f.FullName -Destination ($f.FullName + '.sent') -Force }
        else {
            $m.attempts = [int]$m.attempts + 1
            Write-JsonAtomic $f.FullName $m
        }
    }
}
