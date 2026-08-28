# Install / update Windows Scheduled Task: daily content + product-card (P2)
# 2026-08-21 起【已废弃】：内容任务并入整站 wrapper run-shop-modules-daily.ps1 串行跑
#（08:10 起整站→订单→商品→内容→联盟）。本安装脚本不再创建独立任务；保留仅供回滚/调试单跑。
# 回滚方式：powershell -File .\scripts\install-content-daily-task.ps1 -Time "20:40"
#
# Run on the Ziniao Windows collector PC. Optional — only after business approval.
# Default 20:40 — 历史夜间时间（回滚用）。现在生产走整站 wrapper 串行。
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-content-daily-task.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-content-daily-task.ps1 -Time "20:40"
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-content-daily-task.ps1 -Uninstall

param(
  [string]$Time = '20:40',
  [string]$TaskName = 'TK-Content-Daily',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$wrapper = Join-Path $root 'scripts\run-content-daily.ps1'
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
  throw "Invalid -Time $Time, use HH:mm e.g. 20:40"
}
$hh = [int]$Matches[1]
$mm = [int]$Matches[2]
if ($hh -gt 23 -or $mm -gt 59) { throw "Invalid time $Time" }
$st = '{0:D2}:{1:D2}' -f $hh, $mm

try {
  $cfg = Get-Content -LiteralPath $mainConfig -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not ($cfg.qingquan -and $cfg.qingquan.enabled)) {
    Write-Host "WARN: qingquan.enabled is off - scrape will not ingest to center."
  }
  foreach ($u in @('videoListUrl', 'productTrafficUrl', 'contentUrl')) {
    if (-not $cfg.$u) {
      Write-Host ("NOTE: no config.{0} - runner uses store/platform defaults if any." -f $u)
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
Write-Host "  Modules : video_list, product_traffic -> Qingquan Ingest (SkipIngest forced false)"
Write-Host "  Feishu  : not in this task; use repo tk-p0-post-collect / feishu-tk-daily-sync -ContentOnly"
Write-Host ""
Write-Host "Prerequisites:"
Write-Host "  1) Ziniao + Bridge; desktop session"
Write-Host "  2) PG migrations content/traffic applied; api accepts tiktok_content / product_traffic"
Write-Host "  3) Do NOT also enable conflicting full-site -WithContent at same clock without stagger"
Write-Host ""
Write-Host "Manual test:"
Write-Host ("  schtasks /Run /TN {0}" -f $TaskName)
Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\run-content-daily.ps1"
Write-Host "  Get-ChildItem logs\content-daily-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { Get-Content -LiteralPath `$_.FullName -Tail 80 }"
Write-Host ""
Write-Host "Uninstall:"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\install-content-daily-task.ps1 -Uninstall"
