# Install / update Windows Scheduled Task: DAYTIME shop-modules (violation/reviews/creator_health only)
# 白天补采事件型模块，让违规/差评/达人违规等 P0 异常白天就触发 IM 私信提醒，不用等晚上。
# 刻意不采 shop_daily/experience_daily/finance_daily/ads 等全天累计指标（白天中间值会和晚上全天值冲突）。
# Run on the Ziniao Windows collector PC.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-shop-modules-daytime-task.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-shop-modules-daytime-task.ps1 -Time "12:00"
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-shop-modules-daytime-task.ps1 -Uninstall
#
# Default 12:00 - 白天补采一次；避开采集机业务高峰，运营下午能先看到白天出的违规/差评。

param(
  [string]$Time = '12:00',
  [string]$TaskName = 'TK-Shop-Modules-Daytime',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$wrapper = Join-Path $root 'scripts\run-shop-modules-daytime.ps1'
$mainConfig = Join-Path $root 'config\stores.config.json'

if ($Uninstall) {
  cmd /c "schtasks /Delete /TN `"$TaskName`" /F >nul 2>&1"
  Write-Host "Removed task: $TaskName"
  exit 0
}

if (-not (Test-Path $wrapper)) {
  throw "Missing $wrapper"
}
if (-not (Test-Path $mainConfig)) {
  throw "Missing main config: $mainConfig (copy from stores.config.example.json)"
}

if ($Time -notmatch '^(\d{1,2}):(\d{2})$') {
  throw "Invalid -Time $Time, use HH:mm e.g. 12:00"
}
$hh = [int]$Matches[1]
$mm = [int]$Matches[2]
if ($hh -gt 23 -or $mm -gt 59) { throw "Invalid time $Time" }
$st = '{0:D2}:{1:D2}' -f $hh, $mm

# Config self-check (与全天任务一致，复用同一 config)
try {
  $cfg = Get-Content -LiteralPath $mainConfig -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not ($cfg.qingquan -and $cfg.qingquan.enabled)) {
    Write-Host "WARN: qingquan.enabled is off - scrape will not ingest to center."
  }
} catch {
  Write-Host ("WARN: config self-check failed: {0}" -f $_)
}

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
cmd /c "schtasks /Delete /TN `"$TaskName`" /F >nul 2>&1"
$ErrorActionPreference = $prevEap

$tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $wrapper

Write-Host ("Creating daytime task {0} at daily {1} ..." -f $TaskName, $st)
Write-Host ("Command: {0}" -f $tr)
$createOut = cmd /c "schtasks /Create /TN `"$TaskName`" /TR `"$tr`" /SC DAILY /ST $st /RL LIMITED /F 2>&1"
Write-Host $createOut
if ($LASTEXITCODE -ne 0) {
  throw ("schtasks create failed exit={0}`n{1}" -f $LASTEXITCODE, $createOut)
}

Write-Host ""
Write-Host "OK. Daytime task installed."
Write-Host ("  Name    : {0}" -f $TaskName)
Write-Host ("  When    : every day {0} (local time)" -f $st)
Write-Host ("  Run     : {0}" -f $wrapper)
Write-Host ("  Config  : {0}" -f $mainConfig)
Write-Host "  Modules : violation, reviews, creator_health -> 事件型白天补采(不碰累计指标)"
Write-Host "  vs 全天任务 TK-Shop-Modules-Daily(19:45) 跑全部7模块"
Write-Host ""
Write-Host "注意: 白天这轮只采违规/差评/达人健康。这类是新事件触发型,白天采到立即 IM 私信两负责人。"
Write-Host "      不采 shop_daily/experience/finance/ads - 白天是未结束中间值,会和晚上全天值冲突。"
Write-Host ""
Write-Host "Prerequisites at run time (同全天任务):"
Write-Host "  1) Windows user logged on (desktop session for Ziniao)"
Write-Host "  2) Ziniao client running + logged in (ziniao-cli doctor)"
Write-Host "  3) Bridge up (127.0.0.1:9481)"
Write-Host "  4) stores.config.json qingquan.enabled + production apiKey"
Write-Host ""
Write-Host "Manual test:"
Write-Host ("  schtasks /Run /TN {0}" -f $TaskName)
Write-Host ("  powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daytime.ps1")
Write-Host "  Get-ChildItem logs\shop-modules-daytime-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { Get-Content -LiteralPath `$_.FullName -Tail 60 }"
Write-Host ""
Write-Host "Query / Uninstall:"
Write-Host ("  schtasks /Query /TN {0} /V /FO LIST" -f $TaskName)
Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\install-shop-modules-daytime-task.ps1 -Uninstall"
