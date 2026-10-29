<#
  install.ps1 - Registra el comando `ccr` en tu perfil de PowerShell.
  Se puede ejecutar varias veces: sustituye la línea anterior en vez de duplicarla.
#>
$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'ccr.ps1'
$line   = "function ccr { & `"$script`" @args }  # ccr: selector de sesiones de Claude Code y Codex"

$dir = Split-Path $PROFILE
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

$old = @()
if (Test-Path $PROFILE) { $old = @(Get-Content $PROFILE -Encoding UTF8) }
$new = @($old | Where-Object { $_ -notmatch '^\s*function ccr\s*\{' }) + $line
Set-Content -Path $PROFILE -Value $new -Encoding UTF8

Write-Host "ccr instalado en $PROFILE" -ForegroundColor Green
Write-Host 'Abre una terminal nueva (o ejecuta  . $PROFILE ) y escribe  ccr'
