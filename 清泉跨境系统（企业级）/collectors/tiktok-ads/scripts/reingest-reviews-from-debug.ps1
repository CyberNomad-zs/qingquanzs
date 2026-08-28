# 把已刮到但因入库传输中断未写清泉的 reviews，从 debug json 补入库。
# 用途：run-shop-modules 的 reviews 模块刮取成功但 Send-QingquanIngest 偶发 curl (56) schannel
#       中断时，数据已存 logs\reviews-debug-<storeId>-<stamp>.json，此脚本读取并重新入库。
# 幂等：idempotency_key = tiktok_review:<storeId>:<reviewKey>，重复入库由清泉去重。
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\reingest-reviews-from-debug.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\reingest-reviews-from-debug.ps1 -Stamp 20260820-161235
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\reingest-reviews-from-debug.ps1 -DryRun

param(
  [string]$Stamp = "",
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$logsDir = Join-Path $root 'logs'
$logFile = Join-Path $logsDir ("reingest-reviews-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $line
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

# 加载 qingquan client + config
$qingquanLib = Join-Path $PSScriptRoot 'qingquan-client.ps1'
if (-not (Test-Path $qingquanLib)) { Log "FATAL missing $qingquanLib"; exit 1 }
. $qingquanLib

$cfgPath = Join-Path $root 'config\stores.config.json'
if (-not (Test-Path $cfgPath)) { Log "FATAL missing config $cfgPath"; exit 1 }
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not ($cfg.qingquan -and $cfg.qingquan.enabled)) {
  Log "qingquan.enabled=false，无需补入库"; exit 0
}

# 收集 reviews debug 文件
$pattern = if ($Stamp) { "reviews-debug-*-$Stamp.json" } else { "reviews-debug-*.json" }
$files = @(Get-ChildItem -Path $logsDir -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object Name)
if ($files.Count -eq 0) { Log "no reviews-debug files matching $pattern in $logsDir"; exit 0 }

Log "===== reingest reviews START ====="
Log "config=$cfgPath  files=$($files.Count)  DryRun=$([bool]$DryRun)"
$collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00')
$totAccepted = 0; $totDup = 0; $totFailed = 0

foreach ($f in $files) {
  try {
    $doc = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Log "skip $($f.Name): parse fail $_"; continue
  }
  $sid = [string]$doc.storeId
  $display = [string]$doc.displayName
  $bizDate = [string]$doc.bizDate
  $url = [string]$doc.url
  $payload = $doc.payload
  if (-not $payload -or -not $payload.rows) {
    Log "skip $($f.Name): no payload.rows"; continue
  }
  $rowCount = @($payload.rows).Count
  Log "-- $($f.Name)  store=$display($sid)  biz=$bizDate  rows=$rowCount"

  $items = ConvertTo-QingquanReviewIngestItems -Payload $payload -CollectedAt $collectedAt `
    -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $url
  $n = @($items).Count
  if ($n -eq 0) { Log "  converter returned 0 items, skip"; continue }

  if ($DryRun) {
    Log "  DryRun: would ingest $n items (idempotency_key=tiktok_review:${sid}:<reviewKey>)"
    continue
  }
  $qq = Send-QingquanIngest -Config $cfg -Items $items -Source 'tiktok_review'
  $totAccepted += [int]$qq.accepted
  $totDup += [int]$qq.duplicated
  $totFailed += [int]$qq.failed
  $status = if ($qq.ok) { 'OK' } else { 'FAIL' }
  $errLine = if ($qq.error) { " err=$($qq.error)" } else { '' }
  Log ("  {0}: accepted={1} dup={2} failed={3}{4}" -f $status, $qq.accepted, $qq.duplicated, $qq.failed, $errLine)
}

Log ("SUMMARY: accepted={0} dup={1} failed={2}" -f $totAccepted, $totDup, $totFailed)
Log "===== reingest reviews END ====="
if ($totFailed -gt 0) { exit 2 }
