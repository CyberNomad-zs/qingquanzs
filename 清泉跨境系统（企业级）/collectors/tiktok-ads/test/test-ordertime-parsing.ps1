# 方案2 单元测试：Convert-OrderTimeToDate 把订单 createTime 文本换算成 UK 时区绝对日期。
# 不碰 Bridge。验证各格式分支 + 跨天边界 + 星期换算。
# 用法： powershell -ExecutionPolicy Bypass -File .\test\test-ordertime-parsing.ps1

$ErrorActionPreference = 'Stop'

# —— 被测函数（最终会移入 run-orders.ps1 / qingquan-client.ps1）——
function Get-UKTimeZone {
  try { return [System.TimeZoneInfo]::FindSystemTimeZoneById('GMT Standard Time') }
  catch { return [System.TimeZoneInfo]::Utc }  # 兜底：拿不到 UK 时区就用 UTC
}

function Get-UKNow {
  return [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, (Get-UKTimeZone))
}

# 把 TikTok UK 后台的相对时间文本换算成 UK 时区下的绝对日期 (yyyy-MM-dd)。
# 参照系 = UK 当前时间（不是本机时区！本机是 UTC+8 北京时间，会和 UK 错位一天）。
# 返回 $null 表示无法解析（调用方应保守保留该订单、不触发停止翻页）。
function Convert-OrderTimeToDate {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $s = [string]$Raw
  # 去掉订单号粘连（57xxx 18位）
  $s = $s -replace '57\d{16}', ' '
  $s = $s -replace '\b\d{15,20}\b', ' '
  $s = ($s -replace '\s+', ' ').Trim()
  if (-not $s) { return $null }

  $ukNow = Get-UKNow
  $ukToday = $ukNow.Date

  # 1) X 分钟前 / X 小时前 → UK now 减去该时长，取日期（可能跨天）
  $m = $s -match '(\d{1,4})\s*分钟前'
  if ($m) { return ([DateTime]$ukNow).AddMinutes(-[int]$Matches[1]).Date }
  $m = $s -match '(\d{1,4})\s*小时前'
  if ($m) { return ([DateTime]$ukNow).AddHours(-[int]$Matches[1]).Date }

  # 2) X 天前
  $m = $s -match '(\d{1,3})\s*天前'
  if ($m) { return $ukToday.AddDays(-[int]$Matches[1]) }

  # 3) 昨天 HH:mm
  if ($s -match '昨天') { return $ukToday.AddDays(-1) }
  # 4) 今天 HH:mm
  if ($s -match '今天') { return $ukToday }

  # 5) 星期X / 周X → 本周最近的该星期几，不晚于今天；若就是今天则今天
  $weekMap = @{
    '星期一' = 1; '周一' = 1; '星期二' = 2; '周二' = 2; '星期三' = 3; '周三' = 3
    '星期四' = 4; '周四' = 4; '星期五' = 5; '周五' = 5; '星期六' = 6; '周六' = 6
    '星期日' = 7; '周日' = 7; '星期天' = 7; '周天' = 7
  }
  $matchedDay = $null
  foreach ($k in $weekMap.Keys) { if ($s.IndexOf($k) -ge 0) { $matchedDay = $weekMap[$k]; break } }
  if ($null -ne $matchedDay) {
    $todayDow = [int]$ukToday.DayOfWeek  # Sunday=0...Saturday=6，转成 1..7
    if ($todayDow -eq 0) { $todayDow = 7 }
    $diff = $matchedDay - $todayDow
    # 不晚于今天：diff>0 表示该星期几在今周的未来 → 取上周
    if ($diff -gt 0) { $diff = $diff - 7 }
    return $ukToday.AddDays($diff)
  }

  # 6) 绝对日期 2026/8/15 或 2026-08-15 [HH:mm]
  $m = $s -match '(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})'
  if ($m) {
    try {
      $dt = [DateTime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], 12, 0, 0)
      return $dt.Date
    } catch { return $null }
  }

  return $null
}

# —— 测试用例 ——
$ukNow = Get-UKNow
Write-Host ("UK 当前: {0} (星期{1})" -f $ukNow.ToString('yyyy-MM-dd HH:mm'), ('日一二三四五六'[[int]$ukNow.DayOfWeek]))
Write-Host ("UK 昨天: {0}" -f $ukNow.Date.AddDays(-1).ToString('yyyy-MM-dd'))
Write-Host ""

$cases = @(
  @{ raw = '今天 01:37:44'; expect = 'today' }
  @{ raw = '昨天 23:32:10'; expect = 'yesterday' }
  @{ raw = '28 分钟前';     expect = 'today' }
  @{ raw = '3 小时前';      expect = 'today' }
  @{ raw = '5 天前';        expect = 'today-5' }
  @{ raw = '星期一 23:32:30'; expect = 'weekday:1' }
  @{ raw = '星期日 02:00';    expect = 'weekday:0' }
  @{ raw = '2026/8/15 14:00'; expect = '2026-08-15' }
  @{ raw = '2026-08-19';      expect = '2026-08-19' }
  @{ raw = '576939847403412115 买返样品 今天 01:37:44'; expect = 'today' }   # 订单号粘连
  @{ raw = '';                expect = 'null' }
  @{ raw = '送达截止日期：2026/8/27 23:59:59'; expect = 'null_or_future' }   # 截止日不应误判成昨天
)

$pass = 0; $fail = 0
foreach ($c in $cases) {
  $d = Convert-OrderTimeToDate -Raw $c.raw
  $dStr = if ($null -eq $d) { 'null' } else { $d.ToString('yyyy-MM-dd') }
  $ok = $false
  switch ($c.expect) {
    'today'      { $ok = ($null -ne $d -and $d.Date -eq $ukNow.Date) }
    'yesterday'  { $ok = ($null -ne $d -and $d.Date -eq $ukNow.Date.AddDays(-1)) }
    'today-5'    { $ok = ($null -ne $d -and $d.Date -eq $ukNow.Date.AddDays(-5)) }
    'null'       { $ok = ($null -eq $d) }
    'null_or_future' { $ok = ($null -eq $d -or $d.Date -ge $ukNow.Date) }
    default {
      if ($c.expect -like 'weekday:*') {
        $wd = [int]($c.expect -replace 'weekday:','')
        $todayDow = [int]$ukNow.DayOfWeek; if ($todayDow -eq 0) { $todayDow = 7 }
        $diff = $wd - $todayDow; if ($diff -gt 0) { $diff -= 7 }
        $exp = $ukNow.Date.AddDays($diff)
        $ok = ($null -ne $d -and $d.Date -eq $exp)
      } else {
        $ok = ($null -ne $d -and $dStr -eq $c.expect)
      }
    }
  }
  $tag = if ($ok) { 'PASS' } else { 'FAIL' }
  if ($ok) { $pass++ } else { $fail++ }
  Write-Host ("  [{0}] raw='{1}' -> {2} (expect {3})" -f $tag, $c.raw, $dStr, $c.expect)
}
Write-Host ""
Write-Host ("结果: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }