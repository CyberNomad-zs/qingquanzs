# Install Windows Scheduled Task: daily orders (full-store main config)
# 2026-08-21 起【已废弃】：订单任务并入整站 wrapper run-shop-modules-daily.ps1 串行跑
#（08:10 起先整站后订单）。本安装脚本不再创建独立任务；保留仅供回滚/调试单跑订单。
# 回滚方式：powershell -File .\scripts\install-orders-daily-task.ps1 -Time "20:00"
#
# Default 20:00 — 历史夜间时间（回滚用）。现在生产走整站 wrapper 串行。
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-orders-daily-task.ps1 -Time "20:00"
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-orders-daily-task.ps1 -Uninstall

param(
  [string]$Time = '20:00',
  [string]$TaskName = 'TK-Orders-Daily',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$wrapper = Join-Path $root 'scripts\run-orders-daily.ps1'
$mainConfig = Join-Path $root 'config\stores.config.json'

if ($Uninstall) {
  cmd /c "schtasks /Delete /TN `"$TaskName`" /F >nul 2>&1"
  Write-Host "Removed task: $TaskName"
  exit 0
}

if (-not (Test-Path $wrapper)) { throw "Missing $wrapper" }
if (-not (Test-Path $mainConfig)) { throw "Missing $mainConfig" }

if ($Time -notmatch '^(\d{1,2}):(\d{2})$') { throw "Invalid -Time $Time" }
$st = '{0:D2}:{1:D2}' -f [int]$Matches[1], [int]$Matches[2]

try {
  $cfg = Get-Content -LiteralPath $mainConfig -Raw -Encoding UTF8 | ConvertFrom-Json
  $inc = @()
  if ($cfg.filter -and $cfg.filter.includeStoreIds) {
    $inc = @($cfg.filter.includeStoreIds | Where-Object { $_ -and ("$_").Trim() -ne '' })
  }
  if ($inc.Count -gt 0) {
    Write-Host ("WARN: includeStoreIds set -> not full-store: {0}" -f ($inc -join ','))
  } else {
    Write-Host "OK: includeStoreIds empty -> full-store filter."
  }
  if ($cfg.modules -and $cfg.modules.ordersExcludeStoreIds) {
    Write-Host ("NOTE: ordersExcludeStoreIds={0}" -f (@($cfg.modules.ordersExcludeStoreIds) -join ','))
  }
} catch {
  Write-Host ("WARN: config check failed: {0}" -f $_)
}

$ErrorActionPreference = 'Continue'
cmd /c "schtasks /Delete /TN `"$TaskName`" /F >nul 2>&1"
$ErrorActionPreference = 'Stop'

$tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $wrapper
Write-Host ("Creating {0} daily {1} ..." -f $TaskName, $st)
$createOut = cmd /c "schtasks /Create /TN `"$TaskName`" /TR `"$tr`" /SC DAILY /ST $st /RL LIMITED /F 2>&1"
Write-Host $createOut
if ($LASTEXITCODE -ne 0) { throw "schtasks failed: $createOut" }

Write-Host ""
Write-Host "OK. Task $TaskName at $st -> $wrapper"
Write-Host "  Config: $mainConfig (orders; may exclude EU/Pop via modules.ordersExclude*)"
Write-Host "Test: schtasks /Run /TN $TaskName"
Write-Host "Uninstall: powershell -File .\scripts\install-orders-daily-task.ps1 -Uninstall"
