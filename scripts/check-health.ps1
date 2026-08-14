# dsh-computer-use-windows — health check
# Verifies the helper chain: pwsh, DPI awareness, OCR language packs, window enumeration.
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '..\helper\cu.ps1'
if (-not (Test-Path $helper)) { Write-Host "FAIL: helper not found: $helper" -ForegroundColor Red; exit 1 }
Write-Host "helper: $helper"

$env:CU_ARGS = '{"cmd":"health"}'
$health = & $helper | ConvertFrom-Json
if (-not $health.ok) { Write-Host "FAIL: helper health: $($health.error)" -ForegroundColor Red; exit 1 }
Write-Host ("pwsh      : " + $health.pwsh)
Write-Host ("dpi aware : " + $health.dpi_aware)
Write-Host ("ocr avail : " + $health.ocr_available)
Write-Host ("temp dir  : " + $health.temp_dir)
if (-not $health.ocr_available) { Write-Host "WARN: no Windows OCR language pack (install Chinese/English language pack)" -ForegroundColor Yellow }

$env:CU_ARGS = '{"cmd":"window","action":"list"}'
$win = & $helper | ConvertFrom-Json
if ($win.ok) { Write-Host ("windows   : " + $win.windows.Count + " visible") } else { Write-Host "WARN: window enumeration failed: $($win.error)" -ForegroundColor Yellow }

Write-Host "OK: computer use chain healthy" -ForegroundColor Green
