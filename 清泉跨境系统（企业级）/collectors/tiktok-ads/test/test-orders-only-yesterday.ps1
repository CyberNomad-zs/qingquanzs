# 方案2 端到端模拟测试：模拟翻页累加 + onlyYesterday 过滤 + 越过昨天停止。
# 不碰 Bridge。复用 test-ordertime-parsing.ps1 里已验证的换算函数。
# powershell -ExecutionPolicy Bypass -File .\test\test-orders-only-yesterday.ps1

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-ordertime-parsing.ps1') *>$null  # 拿到 Convert-OrderTimeToDate/Test-OrderDateRange/Get-UKNow

# 复刻 run-orders.ps1 里的 Test-OrderDateRange（test-ordertime-parsing.ps1 里没定义这个）
function Test-OrderDateRange {
  param([string]$CreateTime, $UKToday)
  $date = Convert-OrderTimeToDate -Raw $CreateTime
  $yest = $UKToday.AddDays(-1)
  if ($null -eq $date) { return @{ keep = $true; beforeYesterday = $false; date = $null; todayYmd = $UKToday.ToString('yyyy-MM-dd') } }
  $keep = ($date.Date -eq $yest.Date)
  $before = ($date.Date -lt $yest.Date)
  return @{ keep = $keep; beforeYesterday = $before; date = $date.ToString('yyyy-MM-dd'); todayYmd = $UKToday.ToString('yyyy-MM-dd') }
}

$ukToday = (Get-UKNow).Date
$yestStr = $ukToday.AddDays(-1).ToString('yyyy-MM-dd')
$todayStr = $ukToday.ToString('yyyy-MM-dd')
Write-Host ("UK 今天=$todayStr  昨天=$yestStr")
Write-Host ""

# 模拟 3 页订单（倒序：page1 最新=今天，page2 跨昨天/前天，page3 全是前天及更早）
$script:seenIds = @{}
$script:rawRows = @()
$script:reachedBeforeYesterday = $false

function Add-Page([array]$rows, [bool]$onlyYest, $ukTodayDate) {
  $added = 0; $skToday = 0; $skOld = 0
  foreach ($r in $rows) {
    $oid = [string]$r.orderId
    if (-not $oid -or $script:seenIds.ContainsKey($oid)) { continue }
    $script:seenIds[$oid] = $true
    if (-not $onlyYest) { $script:rawRows += $r; $added++; continue }
    $j = Test-OrderDateRange -CreateTime ([string]$r.createTime) -UKToday $ukTodayDate
    if ($j.beforeYesterday) { $script:reachedBeforeYesterday = $true; $skOld++; continue }
    if (-not $j.keep) { $skToday++; continue }
    $script:rawRows += $r; $added++
  }
  return @{ added=$added; skipToday=$skToday; skipOlder=$skOld }
}

# page1: 3条今天 + 1条昨天（订单倒序，今天的新单在前）
$p1 = @(
  @{ orderId='576900000000000001'; createTime="今天 09:10" }
  @{ orderId='576900000000000002'; createTime="今天 08:30" }
  @{ orderId='576900000000000003'; createTime="2 小时前" }
  @{ orderId='576900000000000004'; createTime="昨天 23:50" }
)
# page2: 2条昨天 + 1条前天（边界页）
$p2 = @(
  @{ orderId='576900000000000005'; createTime="昨天 18:20" }
  @{ orderId='576900000000000006'; createTime="昨天 10:05" }
  @{ orderId='576900000000000007'; createTime="2026/8/19 14:00" }   # 前天（绝对日期）
)
# page3: 全前天及更早（不应被处理，因为 page2 已 reachedBeforeYesterday）
$p3 = @(
  @{ orderId='576900000000000008'; createTime="2026/8/18 09:00" }
  @{ orderId='576900000000000009'; createTime="3 天前" }
)

Write-Host "=== onlyYesterday = TRUE (方案2) ==="
$r1 = Add-Page $p1 $true $ukToday
Write-Host ("page1: keptYesterday={0} skipToday={1} skipOlder={2} rawRows={3} reachedOld={4}" -f $r1.added,$r1.skipToday,$r1.skipOlder,$script:rawRows.Count,$script:reachedBeforeYesterday)
$r2 = Add-Page $p2 $true $ukToday
Write-Host ("page2: keptYesterday={0} skipToday={1} skipOlder={2} rawRows={3} reachedOld={4}" -f $r2.added,$r2.skipToday,$r2.skipOlder,$script:rawRows.Count,$script:reachedBeforeYesterday)
# page2 后 reachedBeforeYesterday=true，run-orders 会在此停，不调 page3
if ($script:reachedBeforeYesterday) { Write-Host "page3: SKIPPED (reachedBeforeYesterday=stop paging) ✓" }
else { $r3 = Add-Page $p3 $true $ukToday; Write-Host ("page3: keptYesterday={0} skipOlder={1} rawRows={2} (should not happen)" -f $r3.added,$r3.skipOlder,$script:rawRows.Count) }

Write-Host ""
Write-Host ("结果: rawRows={0} 条，应全是昨天({1})" -f $script:rawRows.Count, $yestStr)
$badCount = 0
foreach ($r in $script:rawRows) {
  $d = (Test-OrderDateRange -CreateTime ([string]$r.createTime) -UKToday $ukToday).date
  $tag = if ($d -eq $yestStr) { 'OK' } else { 'BAD' }; if ($tag -eq 'BAD') { $badCount++ }
  Write-Host ("  {0} createTime='{1}' date={2} [{3}]" -f $r.orderId, $r.createTime, $d, $tag)
}
$pass = ($script:rawRows.Count -eq 3 -and $badCount -eq 0 -and $script:reachedBeforeYesterday)
Write-Host ""
if ($pass) { Write-Host "PASS: 只收3条昨天的单，前天出现即停，今天跳过"; exit 0 }
else { Write-Host "FAIL: rawRows=$($script:rawRows.Count) bad=$badCount reachedOld=$($script:reachedBeforeYesterday) (期望 3/0/true)"; exit 1 }