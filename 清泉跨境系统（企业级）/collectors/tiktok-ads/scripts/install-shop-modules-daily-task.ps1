# Install / update Windows Scheduled Task: daily shop-modules 串行5段（08:10 起全量）
# Full-store via main config stores.config.json (same filter as ads).
# Run on the Ziniao Windows collector PC.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-shop-modules-daily-task.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-shop-modules-daily-task.ps1 -Time "08:10"
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-shop-modules-daily-task.ps1 -Uninstall
#
# Default 08:10 - 2026-08-21 从夜间挪到早上 8:10（用户要求）。wrapper run-shop-modules-daily.ps1
# 串行跑 5 段：整站7模块→订单→商品→内容→联盟。白天 loop 避开 08:00~11:30 让出 Bridge。
# 运营上午能看到昨天的全部数据，不用等到深夜。原 TK-Orders/Products/Content/Affiliate-Daily 夜间任务已删并入。

param(
  [string]$Time = '08:10',
  [string]$TaskName = 'TK-Shop-Modules-Daily',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$wrapper = Join-Path $root 'scripts\run-shop-modules-daily.ps1'
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
  throw "Invalid -Time $Time, use HH:mm e.g. 19:45"
}
$hh = [int]$Matches[1]
$mm = [int]$Matches[2]
if ($hh -gt 23 -or $mm -gt 59) { throw "Invalid time $Time" }
$st = '{0:D2}:{1:D2}' -f $hh, $mm

# Config self-check (full-store = empty includeStoreIds)
try {
  $cfg = Get-Content -LiteralPath $mainConfig -Raw -Encoding UTF8 | ConvertFrom-Json
  $inc = @()
  if ($cfg.filter -and $cfg.filter.includeStoreIds) {
    $inc = @($cfg.filter.includeStoreIds | Where-Object { $_ -and ("$_").Trim() -ne '' })
  }
  if ($inc.Count -gt 0) {
    Write-Host ("WARN: filter.includeStoreIds is set -> only these stores: {0}" -f ($inc -join ','))
    Write-Host "      Clear includeStoreIds for full-store daily (keep platformContains + requireIp + exclude)."
  } else {
    Write-Host "OK: includeStoreIds empty -> full-store by filter (TikTok + requireIp + exclude)."
  }
  if ($cfg.options -and $null -ne $cfg.options.dryRun -and [bool]$cfg.options.dryRun) {
    Write-Host "NOTE: options.dryRun=true in config; wrapper forces -DryRun false for this task."
  }
  if (-not ($cfg.qingquan -and $cfg.qingquan.enabled)) {
    Write-Host "WARN: qingquan.enabled is off - scrape will not ingest to center."
  }
  foreach ($u in @('shopDailyUrl', 'healthUrl', 'financeUrl')) {
    if (-not $cfg.$u) {
      Write-Host ("NOTE: no config.{0} - runner uses built-in UK defaults." -f $u)
    }
  }
} catch {
  Write-Host ("WARN: config self-check failed: {0}" -f $_)
}

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
cmd /c "schtasks /Delete /TN `"$TaskName`" /F >nul 2>&1"
$ErrorActionPreference = $prevEap

$tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $wrapper

Write-Host ("Creating task {0} at daily {1} ..." -f $TaskName, $st)
Write-Host ("Command: {0}" -f $tr)
$createOut = cmd /c "schtasks /Create /TN `"$TaskName`" /TR `"$tr`" /SC DAILY /ST $st /RL LIMITED /F 2>&1"
Write-Host $createOut
if ($LASTEXITCODE -ne 0) {
  throw ("schtasks create failed exit={0}`n{1}" -f $LASTEXITCODE, $createOut)
}

Write-Host ""
Write-Host "OK. Task installed."
Write-Host ("  Name    : {0}" -f $TaskName)
Write-Host ("  When    : every day {0} (local time)" -f $st)
Write-Host ("  Run     : {0}" -f $wrapper)
Write-Host ("  Config  : {0}" -f $mainConfig)
Write-Host "  Modules : shop_daily, health_daily, experience_daily, finance_daily, violation, reviews, creator_health -> Qingquan Ingest only"
Write-Host "  +Orders : 串行 run-orders.ps1（方案2 只抓昨天）"
Write-Host "  +Products : 串行 run-products.ps1（全店商品卡）"
Write-Host "  +Content : 串行 run-content-poc.ps1（video_list+product_traffic，强制入库）"
Write-Host "  +Affiliate : 串行 run-affiliate-poc.ps1（enter_center+performance，强制入库）"
Write-Host "  串行5段单 Bridge 零冲突；各段失败不阻断后续。原 TK-Orders/Products/Content/Affiliate-Daily 夜间任务已删并入。"
Write-Host "  loop避 : daytime-loop 避开 08:00~11:30 让本任务整段（见 run-shop-modules-daytime-loop.ps1）"
Write-Host ""
Write-Host "Prerequisites at run time:"
Write-Host "  1) Windows user logged on (desktop session for Ziniao)"
Write-Host "  2) Ziniao client running + logged in (ziniao-cli doctor)"
Write-Host "  3) Bridge up (127.0.0.1:9481)"
Write-Host "  4) stores.config.json qingquan.enabled + production apiKey"
Write-Host "  5) Stores IP-bound (requireIp skips unbound)"
Write-Host ""
Write-Host "Manual test:"
Write-Host ("  schtasks /Run /TN {0}" -f $TaskName)
Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules.ps1 -ListOnly"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daily.ps1"
Write-Host "  Get-ChildItem logs\shop-modules-daily-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { Get-Content -LiteralPath `$_.FullName -Tail 60 }"
Write-Host ""
Write-Host "Query / Uninstall:"
Write-Host ("  schtasks /Query /TN {0} /V /FO LIST" -f $TaskName)
Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\install-shop-modules-daily-task.ps1 -Uninstall"
