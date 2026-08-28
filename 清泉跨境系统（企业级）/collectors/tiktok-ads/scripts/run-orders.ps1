# TikTok orders multi-store scrape (P2a) via ziniao-cli
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-orders.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-orders.ps1 -ListOnly
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-orders.ps1 -DryRun true
#
# Requires: Ziniao client + Bridge; config\stores.config.json
# Does NOT write Feishu by default (orders Feishu table optional later) — only Qingquan ingest.

param(
  [string]$ConfigPath = "",
  [switch]$ListOnly,
  [string]$DryRun = ""
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\stores.config.json' }
$scrapeJsPath = Join-Path $root 'scripts\scrape-orders-page.js'
$clickNextJsPath = Join-Path $root 'scripts\orders-click-next.js'
$detailJsPath = Join-Path $root 'scripts\scrape-order-detail-page.js'
$dateRangeJsPath = Join-Path $root 'scripts\set-date-range.js'
$ordersDateFilterJsPath = Join-Path $root 'scripts\set-orders-date-filter.js'
if (-not (Test-Path $ConfigPath)) { throw "Missing config: $ConfigPath" }
if (-not (Test-Path $scrapeJsPath)) { throw "Missing $scrapeJsPath" }

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$scrapeJs = Get-Content $scrapeJsPath -Raw -Encoding UTF8
# 2026-08-20：订单列表默认 tab=all（全部订单），不按日期筛。每次全量翻页 + 进前 N 个详情，
# 大量历史订单每天重抓，靠幂等去重但采集开销全量重复。加载 set-date-range.js 用于在 visit
# 订单页后把日期区间选成「昨天」，使列表只出昨天的订单，详情也只补昨天的。
$dateRangeJsTemplate = ''
if (Test-Path $dateRangeJsPath) { $dateRangeJsTemplate = Get-Content $dateRangeJsPath -Raw -Encoding UTF8 }
$ordersDateFilterJsTemplate = ''
if (Test-Path $ordersDateFilterJsPath) { $ordersDateFilterJsTemplate = Get-Content $ordersDateFilterJsPath -Raw -Encoding UTF8 }
$clickNextJs = ''
if (Test-Path $clickNextJsPath) {
  $clickNextJs = Get-Content $clickNextJsPath -Raw -Encoding UTF8
}
$detailJs = ''
if (Test-Path $detailJsPath) {
  $detailJs = Get-Content $detailJsPath -Raw -Encoding UTF8
}
$qingquanLib = Join-Path $PSScriptRoot 'qingquan-client.ps1'
if (Test-Path $qingquanLib) { . $qingquanLib }
$ziniaoWinLib = Join-Path $PSScriptRoot 'ziniao-window.ps1'
if (-not (Test-Path $ziniaoWinLib)) { throw "Missing $ziniaoWinLib" }
. $ziniaoWinLib

$script:logsDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $script:logsDir | Out-Null
$script:runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:runLogFile = Join-Path $script:logsDir ("orders-run-{0}.log" -f $script:runStamp)

function Write-RunLog([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -LiteralPath $script:runLogFile -Value $line -Encoding UTF8 } catch { }
}
function Write-Step([string]$msg) {
  Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg)
  Write-RunLog $msg
}

function ConvertTo-ProcessArgument([string]$s) {
  if ($null -eq $s) { return '""' }
  if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
  return $s
}

function Initialize-ZiniaoCli {
  if ($script:ZiniaoNode) { return }
  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $node) { throw 'node not found' }
  $runJs = Join-Path $env:APPDATA 'npm\node_modules\@ziniao-open\cli\scripts\run.js'
  if (-not (Test-Path $runJs)) {
    $cmd = Get-Command ziniao -ErrorAction SilentlyContinue
    if ($cmd) { $runJs = $cmd.Source }
  }
  if (-not (Test-Path $runJs)) { throw 'ziniao-cli run.js not found' }
  $script:ZiniaoNode = $node
  $script:ZiniaoRunJs = $runJs
}

function Invoke-Ziniao([string[]]$CliArgs) {
  Initialize-ZiniaoCli
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  $allArgs = @($script:ZiniaoRunJs) + @($CliArgs)
  $argLine = ($allArgs | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:ZiniaoNode
  $psi.Arguments = $argLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if ($stderr) { Write-Host $stderr }
  return $stdout
}

function ConvertTo-ScrapeOneLine([string]$js) {
  $one = ($js -replace '(?m)^\s*//.*$', '' -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
  return $one
}

function Get-OrdersUrl($store, $cfg) {
  $plat = ''
  if ($store.platformName) { $plat = [string]$store.platformName }
  elseif ($store.platform) { $plat = [string]$store.platform }
  if ($cfg.orderUrl -and $cfg.orderUrl.byPlatform -and $plat) {
    foreach ($p in $cfg.orderUrl.byPlatform.PSObject.Properties) {
      if ($plat -eq [string]$p.Name -or $plat -like ("*{0}*" -f $p.Name) -or ([string]$p.Name -like ("*{0}*" -f $plat))) {
        return [string]$p.Value
      }
    }
  }
  if ($cfg.orderUrl -and $cfg.orderUrl.default) { return [string]$cfg.orderUrl.default }
  if ($cfg.urls -and $cfg.urls.orders) { return [string]$cfg.urls.orders }
  return 'https://seller-uk.tiktok.com/order?selected_sort=6&tab=all'
}

function Get-OrderDetailBaseUrl([string]$orderListUrl) {
  # https://seller-uk.tiktok.com/order?... -> https://seller-uk.tiktok.com/order/detail
  try {
    $u = [uri]$orderListUrl
    $origin = "{0}://{1}" -f $u.Scheme, $u.Host
    return ($origin.TrimEnd('/') + '/order/detail')
  } catch {
    return 'https://seller-uk.tiktok.com/order/detail'
  }
}

function Get-OrderRegionQuery([string]$orderListUrl) {
  if ($orderListUrl -match 'shop_region=([A-Za-z]{2})') { return $Matches[1] }
  if ($orderListUrl -match 'seller-uk') { return 'GB' }
  if ($orderListUrl -match 'seller\.eu') { return '' }
  return 'GB'
}

function Get-DisplayName($store, $map) {
  $n = [string]$store.storeName
  if ($map -and $map.PSObject.Properties.Name -contains $n) { return [string]$map.$n }
  return $n
}

function Get-ScrapePayload([string]$execOut) {
  if ([string]::IsNullOrWhiteSpace($execOut)) { return $null }
  # ziniao wraps result JSON in data.data.result string sometimes
  try {
    $j = $execOut | ConvertFrom-Json
    if ($j.data -and $j.data.data -and $j.data.data.result) {
      $inner = [string]$j.data.data.result
      return ($inner | ConvertFrom-Json)
    }
    if ($j.ok -ne $null -and $j.rows) { return $j }
    if ($j.ok -ne $null) { return $j }
  } catch { }
  # last {...} object in output
  $m = [regex]::Matches($execOut, '\{(?:[^{}]|(?<o>\{)|(?<-o>\}))+(?(o)(?!))\}')
  if ($m.Count -gt 0) {
    try { return ($m[$m.Count - 1].Value | ConvertFrom-Json) } catch { }
  }
  return $null
}

# 2026-08-24 方案3：订单页筛选抽屉日期过滤（set-orders-date-filter.js）。
# 降级设计：选不上不阻断，按当前页抓 + ordersOnlyYesterday 安全网兜底。
function Get-OrdersFilterScriptOneLine([string]$action) {
  $js = $ordersDateFilterJsTemplate.Replace('__ACTION__', $action)
  return (ConvertTo-ScrapeOneLine $js)
}
function Invoke-OrdersFilterAction([string]$storeId, [string]$action, [int]$timeoutMs = 20000) {
  $scriptLine = Get-OrdersFilterScriptOneLine $action
  $out = Invoke-Ziniao @('page', 'exec', '--store-id', $storeId, '--script', $scriptLine, '--timeout', ([string]$timeoutMs))
  return (Get-ScrapePayload $out)
}
function Get-DateRangeScriptOneLine([string]$action) {
  $js = $dateRangeJsTemplate.Replace('__DATE_MODE__', $dateMode).Replace('__ACTION__', $action)
  return (ConvertTo-ScrapeOneLine $js)
}
function Invoke-DateRangeAction([string]$storeId, [string]$action, [int]$timeoutMs = 20000) {
  $scriptLine = Get-DateRangeScriptOneLine $action
  $out = Invoke-Ziniao @('page', 'exec', '--store-id', $storeId, '--script', $scriptLine, '--timeout', ([string]$timeoutMs))
  return (Get-ScrapePayload $out)
}
function Invoke-SetPageDateRange([string]$storeId) {
  if (-not $setPageDateRange) {
    Write-Step "  skip set page date range (setPageDateRange=false or no script)"
    return $true
  }
  # 方案3优先：用筛选抽屉脚本
  if ($ordersDateFilterJsTemplate) {
    Write-Step ("  set orders date filter => {0} (filter drawer: open -> pick -> wait)..." -f $dateMode)
    try {
      # 1) 打开筛选抽屉
      $op = Invoke-OrdersFilterAction $storeId 'open' 20000
      if ($null -eq $op) {
        Write-Step "  WARN filter open: unrecognized payload"
      } elseif ($op.alreadyOpen) {
        Write-Step "  filter drawer already open"
      } elseif ($op.ok) {
        Write-Step ("  filter drawer opened via={0}" -f $op.triggerVia)
      } else {
        Write-Step ("  WARN filter open failed: {0}" -f $(if ($op.error) { $op.error } else { $op.message }))
        return $false
      }
      Start-Sleep -Milliseconds 800
      # 2) 选昨天 + 应用
      $pk = Invoke-OrdersFilterAction $storeId 'pick' 20000
      if ($null -eq $pk) {
        Write-Step "  WARN filter pick: unrecognized payload (will still scrape)"
      } elseif ($pk.ok) {
        Write-Step ("  filter pick OK: shortcut={0} applied={1}" -f $pk.shortcutText, $pk.applied)
      } elseif ($pk.softOk) {
        Write-Step ("  filter pick partial: shortcut={0} but apply not found" -f $pk.shortcutText)
      } else {
        Write-Step ("  WARN filter pick failed: {0}" -f $(if ($pk.error) { $pk.error } else { $pk.message }))
      }
      # 3) 等页面按筛选条件重载
      if ($waitAfterDateChangeMs -gt 0) {
        Write-Step ("  wait after filter apply {0}ms (page reload)..." -f $waitAfterDateChangeMs)
        Start-Sleep -Milliseconds $waitAfterDateChangeMs
      }
      return ($pk -and ($pk.ok -or $pk.softOk))
    } catch {
      Write-Step ("  WARN set orders date filter error: {0} (will scrape current page)" -f $_)
      return $false
    }
  }
  # 方案1 回退（旧 set-date-range.js，留作调试）
  Write-Step ("  set page date range => {0} (open -> pick -> wait)..." -f $dateMode)
  try {
    $st = Invoke-DateRangeAction $storeId 'status' 15000
    if ($st -and $st.matched) {
      Write-Step ("  date range already {0}: {1} ~ {2}" -f $dateMode, $st.range.start, $st.range.end)
      return $true
    }
    if ($st -and $st.range) {
      Write-Step ("  current page range: {0} ~ {1}" -f $st.range.start, $st.range.end)
    }
    $op = Invoke-DateRangeAction $storeId 'open' 20000
    if ($null -eq $op) {
      Write-Step "  WARN date open: unrecognized payload"
    } elseif (-not $op.ok -and -not $op.skipped) {
      Write-Step ("  WARN date open failed: {0}" -f $(if ($op.error) { $op.error } else { 'unknown' }))
    } else {
      Write-Step ("  date picker open panelOpen={0}" -f $op.panelOpen)
    }
    Start-Sleep -Milliseconds 600
    $pk = Invoke-DateRangeAction $storeId 'pick' 20000
    if ($null -eq $pk) {
      Write-Step "  WARN date pick: unrecognized payload (will still scrape)"
    } elseif ($pk.skipped) {
      Write-Step ("  date range already {0}" -f $dateMode)
      return $true
    } elseif ($pk.ok -or $pk.softOk) {
      $beforeTxt = if ($pk.before) { "{0}~{1}" -f $pk.before.start, $pk.before.end } else { '?' }
      $afterTxt = if ($pk.after) { "{0}~{1}" -f $pk.after.start, $pk.after.end } else { '(pending reload)' }
      Write-Step ("  date pick clicked={0} before={1} after={2}" -f $pk.clicked, $beforeTxt, $afterTxt)
    } else {
      Write-Step ("  WARN date pick failed: {0}" -f $(if ($pk.error) { $pk.error } else { 'unknown' }))
    }
    if ($waitAfterDateChangeMs -gt 0) {
      Write-Step ("  wait after date change {0}ms (table reload)..." -f $waitAfterDateChangeMs)
      Start-Sleep -Milliseconds $waitAfterDateChangeMs
    }
    $st2 = Invoke-DateRangeAction $storeId 'status' 15000
    if ($st2 -and $st2.matched) {
      Write-Step ("  date range confirmed: {0} ~ {1}" -f $st2.range.start, $st2.range.end)
      return $true
    }
    if ($st2 -and $st2.range) {
      Write-Step ("  WARN date after pick still {0} ~ {1} (target {2}); will scrape current page anyway" -f `
        $st2.range.start, $st2.range.end, $dateMode)
      return $false
    }
    Write-Step "  WARN could not confirm date range after pick; will scrape current page anyway"
    return $false
  } catch {
    Write-Step ("  WARN set page date range error: {0} (will scrape current page)" -f $_)
    return $false
  }
}

# ===== 方案2：翻页按订单 orderTime 早于昨天即停（2026-08-21）=====
# 订单页 /order 没有日期区间控件（方案1 set-date-range.js 套不上，见上文实测注释）。
# 订单按创建时间倒序排列，每条带 createTime 文本（今天/昨天/X分钟前/X天前/星期X/绝对日期）。
# 方案2：翻页时逐条把 createTime 换算成 UK 时区绝对日期，只保留「昨天」的单；
#        一旦出现「前天及更早」的单，说明昨天的单已全部在前面页里，停止翻页。
# 参照系 = UK 时区（GMT Standard Time，自动 BST/GMT 切换），不是本机时区（本机 UTC+8 会和 UK 错位一天）。
function Get-UKTimeZone {
  try { return [System.TimeZoneInfo]::FindSystemTimeZoneById('GMT Standard Time') }
  catch { return [System.TimeZoneInfo]::Utc }
}
function Get-UKNow {
  return [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, (Get-UKTimeZone))
}
# 把 TikTok UK 后台相对时间文本换算成 UK 时区绝对日期 (yyyy-MM-dd)。无法解析返回 $null。
function Convert-OrderTimeToDate {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $s = [string]$Raw
  $s = $s -replace '57\d{16}', ' '        # 剥离粘连的订单号
  $s = $s -replace '\b\d{15,20}\b', ' '
  $s = ($s -replace '\s+', ' ').Trim()
  if (-not $s) { return $null }
  $ukNow = Get-UKNow
  $ukToday = $ukNow.Date
  $m = $null
  if ($s -match '(\d{1,4})\s*分钟前') { return ([DateTime]$ukNow).AddMinutes(-[int]$Matches[1]).Date }
  if ($s -match '(\d{1,4})\s*小时前') { return ([DateTime]$ukNow).AddHours(-[int]$Matches[1]).Date }
  if ($s -match '(\d{1,3})\s*天前')   { return $ukToday.AddDays(-[int]$Matches[1]) }
  if ($s -match '昨天') { return $ukToday.AddDays(-1) }
  if ($s -match '今天') { return $ukToday }
  # 星期X/周X → 本周最近的该星期几，不晚于今天
  $weekMap = @{
    '星期一' = 1; '周一' = 1; '星期二' = 2; '周二' = 2; '星期三' = 3; '周三' = 3
    '星期四' = 4; '周四' = 4; '星期五' = 5; '周五' = 5; '星期六' = 6; '周六' = 6
    '星期日' = 7; '周日' = 7; '星期天' = 7; '周天' = 7
  }
  $matchedDay = $null
  foreach ($k in $weekMap.Keys) { if ($s.IndexOf($k) -ge 0) { $matchedDay = $weekMap[$k]; break } }
  if ($null -ne $matchedDay) {
    $todayDow = [int]$ukToday.DayOfWeek; if ($todayDow -eq 0) { $todayDow = 7 }
    $diff = $matchedDay - $todayDow
    if ($diff -gt 0) { $diff -= 7 }   # 该星期几在今周未来 → 取上周
    return $ukToday.AddDays($diff)
  }
  if ($s -match '(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})') {
    try { return ([DateTime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], 12, 0, 0)).Date } catch { return $null }
  }
  return $null
}
# 对一条订单的 createTime 做过滤判定。返回 hashtable：
#   keep            = 是否收入 rawRows（只收昨天；今天的单不收，因为今天未结束；
#                     解析失败 null 保守收入，避免丢单）
#   beforeYesterday = 是否早于昨天（用于触发停止翻页；解析失败不触发，避免误停）
#   date            = 换算出的 UK 绝对日期（null 表示解析不出）
#   todayYmd        = UK 今天 yyyy-MM-dd（调试用）
function Test-OrderDateRange {
  param([string]$CreateTime, $UKToday)
  $date = Convert-OrderTimeToDate -Raw $CreateTime
  $yest = $UKToday.AddDays(-1)
  if ($null -eq $date) {
    return @{ keep = $true; beforeYesterday = $false; date = $null; todayYmd = $UKToday.ToString('yyyy-MM-dd') }
  }
  $keep = ($date.Date -eq $yest.Date)
  $before = ($date.Date -lt $yest.Date)
  return @{ keep = $keep; beforeYesterday = $before; date = $date.ToString('yyyy-MM-dd'); todayYmd = $UKToday.ToString('yyyy-MM-dd') }
}

function Convert-DryRunFlag([string]$raw) {
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  switch -Regex ($raw.Trim()) {
    '^(?i:true|1|yes|y|\$true)$'  { return $true }
    '^(?i:false|0|no|n|\$false)$' { return $false }
    default { throw "Invalid -DryRun '$raw'" }
  }
}

Write-Step '===== orders multi-store START ====='
Write-Step ("config={0}" -f $ConfigPath)
Initialize-ZiniaoCli
Write-Step 'list stores...'
$listOut = Invoke-Ziniao @('store', 'list')
$storesObj = $null
try { $storesObj = $listOut | ConvertFrom-Json } catch { throw "store list parse fail: $listOut" }
$all = @()
if ($storesObj.data) {
  if ($storesObj.data.items) { $all = @($storesObj.data.items) }
  elseif ($storesObj.data -is [System.Array]) { $all = @($storesObj.data) }
  elseif ($storesObj.data.list) { $all = @($storesObj.data.list) }
  elseif ($storesObj.data.stores) { $all = @($storesObj.data.stores) }
}
# normalize — ziniao fields: storeId / storeName / platformName / ip
$norm = @()
foreach ($s in $all) {
  $sid = ''
  if ($s.storeId) { $sid = [string]$s.storeId } elseif ($s.id) { $sid = [string]$s.id }
  $sname = ''
  if ($s.storeName) { $sname = [string]$s.storeName } elseif ($s.name) { $sname = [string]$s.name }
  $plat = ''
  if ($s.platformName) { $plat = [string]$s.platformName }
  elseif ($s.platform) { $plat = [string]$s.platform }
  if (-not $sid) { continue }
  $norm += [pscustomobject]@{
    storeId = $sid
    storeName = $sname
    platform = $plat
    platformName = $plat
    ip = $(if ($s.ip) { [string]$s.ip } else { '' })
    raw = $s
  }
}

$selected = @($norm)
if ($cfg.filter) {
  if ($cfg.filter.platformContains -and @($cfg.filter.platformContains).Count -gt 0) {
    $selected = @($selected | Where-Object {
      $p = $_.platform
      $ok = $false
      foreach ($k in @($cfg.filter.platformContains)) { if ($p -like ("*{0}*" -f $k)) { $ok = $true } }
      $ok
    })
  }
  if ($cfg.filter.requireIp) {
    $selected = @($selected | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ip) })
  }
  if ($cfg.filter.excludeStoreIds) {
    $ex = @($cfg.filter.excludeStoreIds | ForEach-Object { [string]$_ })
    $selected = @($selected | Where-Object { $ex -notcontains $_.storeId })
  }
  if ($cfg.filter.includeStoreIds -and @($cfg.filter.includeStoreIds).Count -gt 0) {
    $inc = @($cfg.filter.includeStoreIds | ForEach-Object { [string]$_ })
    $selected = @($selected | Where-Object { $inc -contains $_.storeId })
  }
}

# 非广告排除：欧盟 Pop 等（广告 dual 仍可采 Pop）
if ($cfg.modules) {
  $oex = @()
  if ($cfg.modules.opsExcludeStoreIds) { $oex += @($cfg.modules.opsExcludeStoreIds | ForEach-Object { [string]$_ }) }
  if ($cfg.modules.ordersExcludeStoreIds) { $oex += @($cfg.modules.ordersExcludeStoreIds | ForEach-Object { [string]$_ }) }
  $oex = @($oex | Select-Object -Unique | Where-Object { $_ })
  if ($oex.Count -gt 0) {
    $before = $selected.Count
    $selected = @($selected | Where-Object { $oex -notcontains $_.storeId })
    if ($before -ne $selected.Count) {
      Write-Step ("opsExcludeStoreIds removed {0} store(s): {1}" -f ($before - $selected.Count), ($oex -join ','))
    }
  }
  $pex = @()
  if ($cfg.modules.opsExcludePlatformContains) { $pex += @($cfg.modules.opsExcludePlatformContains | ForEach-Object { [string]$_ }) }
  if ($cfg.modules.ordersExcludePlatformContains) { $pex += @($cfg.modules.ordersExcludePlatformContains | ForEach-Object { [string]$_ }) }
  $pex = @($pex | Select-Object -Unique | Where-Object { $_ })
  if ($pex.Count -gt 0) {
    $before = $selected.Count
    $selected = @($selected | Where-Object {
      $p = [string]$_.platform
      $hit = $false
      foreach ($k in $pex) { if ($k -and $p -like ("*{0}*" -f $k)) { $hit = $true } }
      -not $hit
    })
    if ($before -ne $selected.Count) {
      Write-Step ("opsExcludePlatformContains removed {0} store(s)" -f ($before - $selected.Count))
    }
  }
}

Write-Step ("stores selected: {0}" -f $selected.Count)
foreach ($s in $selected) {
  Write-Step ("  - {0} | {1} | {2}" -f $s.storeId, $s.storeName, $s.platform)
}
if ($ListOnly) { Write-Step 'ListOnly done'; return }
if ($selected.Count -eq 0) { throw 'No stores matched' }

$dryParsed = Convert-DryRunFlag $DryRun
$useDryRun = if ($null -ne $dryParsed) { [bool]$dryParsed } else {
  if ($cfg.options -and $null -ne $cfg.options.dryRun) { [bool]$cfg.options.dryRun } else { $true }
}
$waitOpen = 28000
$waitVisit = 35000
$retries = 3
$orderMaxPages = 10
$orderPageWaitMs = 5000
if ($cfg.options.waitAfterOpenMs) { $waitOpen = [Math]::Max(20000, [int]$cfg.options.waitAfterOpenMs) }
if ($cfg.options.waitAfterVisitMs) { $waitVisit = [Math]::Max(25000, [int]$cfg.options.waitAfterVisitMs) }
if ($cfg.options.scrapeRetries) { $retries = [Math]::Max(2, [int]$cfg.options.scrapeRetries) }
if ($null -ne $cfg.options.orderMaxPages) { $orderMaxPages = [Math]::Max(1, [int]$cfg.options.orderMaxPages) }
if ($null -ne $cfg.options.orderPageWaitMs) { $orderPageWaitMs = [Math]::Max(1500, [int]$cfg.options.orderPageWaitMs) }
# 订单详情补 SKU：默认开；options.orderDetailEnabled=false 可关；orderDetailMax 限制本店最多进详情数
$orderDetailEnabled = $true
$orderDetailMax = 40
$orderDetailWaitMs = 3500
if ($cfg.options -and $null -ne $cfg.options.orderDetailEnabled) {
  $orderDetailEnabled = [bool]$cfg.options.orderDetailEnabled
}
if ($cfg.options -and $null -ne $cfg.options.orderDetailMax) {
  $orderDetailMax = [Math]::Max(0, [int]$cfg.options.orderDetailMax)
}
if ($cfg.options -and $null -ne $cfg.options.orderDetailWaitMs) {
  $orderDetailWaitMs = [Math]::Max(1500, [int]$cfg.options.orderDetailWaitMs)
}
if (-not $detailJs) { $orderDetailEnabled = $false }

# 2026-08-20：方案1（复用 set-date-range.js arco-picker 选昨天）在订单页失败，无 arco-picker。
# 2026-08-21：方案2（翻页按 orderTime 停）落地。
# 2026-08-24：方案3（点筛选抽屉→订单创建时间→昨天→应用），替代方案1。
# 订单页的日期选择器藏在「筛选」按钮的右侧抽屉面板内，不是页面顶部直接露出的 arco-picker。
# 新脚本 set-orders-date-filter.js 专门处理这个 UI。方案2 保留为安全网。
$dateMode = 'yesterday'
if ($cfg.options -and $cfg.options.dateMode) {
  $dm = ([string]$cfg.options.dateMode).Trim().ToLowerInvariant()
  if ($dm -eq 'today' -or $dm -eq 'yesterday') { $dateMode = $dm }
}
$setPageDateRange = $true
if ($cfg.options -and $null -ne $cfg.options.setPageDateRange) { $setPageDateRange = [bool]$cfg.options.setPageDateRange }
$waitAfterDateChangeMs = 8000
if ($cfg.options -and $null -ne $cfg.options.waitAfterDateChangeMs) { $waitAfterDateChangeMs = [int]$cfg.options.waitAfterDateChangeMs }
if (-not $ordersDateFilterJsTemplate -and -not $dateRangeJsTemplate) { $setPageDateRange = $false }
# 方案2 安全网：翻页按 orderTime 早于昨天即停，双保险。
# 参照系 UK 时区（本机 UTC+8 与 UK 错位一天，函数内用 GMT Standard Time 纠正）。
$ordersOnlyYesterday = $true
if ($cfg.options -and $null -ne $cfg.options.ordersOnlyYesterday) {
  $ordersOnlyYesterday = [bool]$cfg.options.ordersOnlyYesterday
}
#昨天边界（UK 时区），循环开始时重算一次即可；这里先占位，进店循环里赋值
$ukTodayDate = $null
$scrapeOneLine = ConvertTo-ScrapeOneLine $scrapeJs
$clickNextOneLine = ''
if ($clickNextJs) { $clickNextOneLine = ConvertTo-ScrapeOneLine $clickNextJs }
$detailOneLine = ''
if ($detailJs) { $detailOneLine = ConvertTo-ScrapeOneLine $detailJs }
Write-Step ("dryRun={0} scrapeLen={1} orderMaxPages={2} pageWaitMs={3} detail={4} detailMax={5} dateMode={6} setPageDateRange={7} onlyYesterday={8}" -f `
  $useDryRun, $scrapeOneLine.Length, $orderMaxPages, $orderPageWaitMs, $orderDetailEnabled, $orderDetailMax, $dateMode, $setPageDateRange, $ordersOnlyYesterday)

$summary = @()
foreach ($store in $selected) {
  $sid = $store.storeId
  $sname = $store.storeName
  $display = Get-DisplayName $store $cfg.storeNameMap
  $orderUrl = Get-OrdersUrl $store $cfg
  $item = [ordered]@{
    storeId = $sid; storeName = $sname; displayName = $display
    ok = $false; rows = 0; detailOk = 0; detailFail = 0; lineItems = 0
    qingquanAccepted = 0; qingquanDup = 0; lineAccepted = 0; lineDup = 0; error = $null
  }
  Write-Step ("==== ORDERS {0} ({1}) => {2} ====" -f $sname, $sid, $display)
  try {
    Write-Step '  open store...'
    $openArgs = New-ZiniaoStoreOpenArgs -StoreId $sid -Url $orderUrl -Config $cfg
    Write-Host (Invoke-Ziniao $openArgs)
    Start-Sleep -Milliseconds $waitOpen
    Invoke-ZiniaoStoreMaximize -StoreId $sid -InvokeZiniao ${function:Invoke-Ziniao} -WriteStep ${function:Write-Step} -Config $cfg | Out-Null
    Write-Step '  visit orders page...'
    $null = Invoke-Ziniao @('page', 'visit', '--store-id', $sid, '--url', $orderUrl, '--wait-until', 'networkidle', '--timeout', '90000')
    Invoke-ZiniaoStoreMaximize -StoreId $sid -InvokeZiniao ${function:Invoke-Ziniao} -WriteStep ${function:Write-Step} -Config $cfg | Out-Null
    Start-Sleep -Milliseconds $waitVisit

    # 方案3：筛选抽屉选昨天 + 应用；选不上不阻断（ordersOnlyYesterday 兜底）。
    $null = Invoke-SetPageDateRange $sid

    $payload = $null
    $rawRows = @()
    $lastErr = $null
    $pagesDone = 0
    $seenIds = @{}
    # 方案2：只收昨天的单；越过昨天（出现前天及更早）即停翻页。
    $reachedBeforeYesterday = $false
    $ukTodayDate = Get-UKNow
    $yestDate = $ukTodayDate.Date.AddDays(-1)
    if ($ordersOnlyYesterday) {
      Write-Step ("  onlyYesterday=ON: keep orders dated {0} (UK), stop paging once older seen" -f $yestDate.ToString('yyyy-MM-dd'))
    }

    for ($attempt = 1; $attempt -le $retries; $attempt++) {
      Write-Step ("  scrape attempt {0}/{1} (page 1)..." -f $attempt, $retries)
      $execOut = Invoke-Ziniao @('page', 'exec', '--store-id', $sid, '--script', $scrapeOneLine, '--timeout', '60000')
      $payload = Get-ScrapePayload $execOut
      if ($payload -and $payload.ok -and $payload.rows) {
        $pageRows = @($payload.rows)
        $kept = 0; $skippedToday = 0; $skippedOld = 0
        foreach ($r in $pageRows) {
          $oid = ''
          if ($r.orderId) { $oid = [string]$r.orderId } elseif ($r.order_id) { $oid = [string]$r.order_id }
          if (-not $oid -or $seenIds.ContainsKey($oid)) { continue }
          $seenIds[$oid] = $true
          if (-not $ordersOnlyYesterday) { $rawRows += $r; $kept++; continue }
          $ct = if ($r.createTime) { [string]$r.createTime } else { '' }
          $j = Test-OrderDateRange -CreateTime $ct -UKToday $ukTodayDate
          if ($j.beforeYesterday) { $reachedBeforeYesterday = $true; $skippedOld++; continue }
          if (-not $j.keep) { $skippedToday++; continue }   # 今天或未来日（截止日漏过），跳过不收
          $rawRows += $r; $kept++
        }
        if ($ordersOnlyYesterday) {
          Write-Step ("  page 1 rows={0} keptYesterday={1} skipToday={2} skipOlder={3}" -f $pageRows.Count, $kept, $skippedToday, $skippedOld)
        }
        # page 1 只要 scrape 到 rows 就算成功（即便 onlyYesterday 过滤后为 0，也要继续翻页找昨天的单）
        $lastErr = $null; $pagesDone = 1; break
      } else {
        $lastErr = if ($payload -and $payload.error) { [string]$payload.error } else { 'scrape failed' }
        Write-Step ("  attempt fail: {0}" -f $lastErr)
      }
      if ($attempt -lt $retries) {
        Start-Sleep -Seconds 8
        $null = Invoke-Ziniao @('page', 'visit', '--store-id', $sid, '--url', $orderUrl, '--wait-until', 'networkidle', '--timeout', '90000')
        $null = Invoke-SetPageDateRange $sid
        Start-Sleep -Seconds 10
      }
    }
    # onlyYesterday 模式下 page1 过滤后 0 条不报错（今天可能还没昨天的新单出现在第1页）；scrape 完全失败才 throw
    if ($lastErr) { throw $lastErr }
    if ((-not $ordersOnlyYesterday) -and $rawRows.Count -eq 0) { throw '0 rows' }

    Write-Step ("  page 1 rows={0} (unique total={1})" -f $pagesDone, $rawRows.Count)

    # 翻页：点击下一页 → 等待 → 再 scrape，按 orderId 去重；onlyYesterday 时越过昨天即停
    if ($orderMaxPages -gt 1 -and $clickNextOneLine) {
      for ($page = 2; $page -le $orderMaxPages; $page++) {
        if ($ordersOnlyYesterday -and $reachedBeforeYesterday) {
          Write-Step ("  stop paging at page {0}: reached orders older than yesterday" -f $page)
          break
        }
        Write-Step ("  click next for page {0}..." -f $page)
        $nextOut = Invoke-Ziniao @('page', 'exec', '--store-id', $sid, '--script', $clickNextOneLine, '--timeout', '30000')
        $nextPayload = Get-ScrapePayload $nextOut
        $hasNext = $false
        if ($nextPayload -and $nextPayload.ok -and $nextPayload.clicked) { $hasNext = $true }
        elseif ($nextPayload -and $nextPayload.hasNext -eq $false) {
          Write-Step ("  no more pages (next disabled/missing): {0}" -f $(if ($nextPayload.error) { $nextPayload.error } else { 'end' }))
          break
        } else {
          # 解析失败时也尝试看 raw
          if ($nextOut -match '"clicked"\s*:\s*true') { $hasNext = $true }
          else {
            Write-Step ("  stop paging: cannot click next | {0}" -f $(if ($nextPayload -and $nextPayload.error) { $nextPayload.error } elseif ($nextOut.Length -gt 120) { $nextOut.Substring(0,120) } else { $nextOut }))
            break
          }
        }
        if (-not $hasNext) { break }

        Start-Sleep -Milliseconds $orderPageWaitMs
        $execOut = Invoke-Ziniao @('page', 'exec', '--store-id', $sid, '--script', $scrapeOneLine, '--timeout', '60000')
        $pagePayload = Get-ScrapePayload $execOut
        if (-not ($pagePayload -and $pagePayload.ok -and $pagePayload.rows)) {
          Write-Step ("  page {0} scrape empty/fail — stop paging" -f $page)
          break
        }
        $added = 0; $skippedToday = 0; $skippedOld = 0
        foreach ($r in @($pagePayload.rows)) {
          $oid = ''
          if ($r.orderId) { $oid = [string]$r.orderId } elseif ($r.order_id) { $oid = [string]$r.order_id }
          if (-not $oid -or $seenIds.ContainsKey($oid)) { continue }
          $seenIds[$oid] = $true
          if (-not $ordersOnlyYesterday) { $rawRows += $r; $added++; continue }
          $ct = if ($r.createTime) { [string]$r.createTime } else { '' }
          $j = Test-OrderDateRange -CreateTime $ct -UKToday $ukTodayDate
          if ($j.beforeYesterday) { $reachedBeforeYesterday = $true; $skippedOld++; continue }
          if (-not $j.keep) { $skippedToday++; continue }
          $rawRows += $r; $added++
        }
        $pagesDone++
        $payload = $pagePayload
        if ($ordersOnlyYesterday) {
          Write-Step ("  page {0} keptYesterday={1} skipToday={2} skipOlder={3} unique total={4}" -f $page, $added, $skippedToday, $skippedOld, $rawRows.Count)
        } else {
          Write-Step ("  page {0} new={1} unique total={2}" -f $page, $added, $rawRows.Count)
        }
        if ($added -eq 0 -and (-not $ordersOnlyYesterday)) {
          Write-Step '  no new order ids — stop paging'
          break
        }
      }
    } elseif ($orderMaxPages -gt 1 -and -not $clickNextOneLine) {
      Write-Step '  WARN orders-click-next.js missing — only first page scraped'
    }

    $item.rows = $rawRows.Count
    Write-Step ("  scraped {0} order rows source={1} pages={2}" -f $rawRows.Count, $(if ($payload.source) { $payload.source } else { '?' }), $pagesDone)

    # save debug
    $dbg = Join-Path $script:logsDir ("orders-debug-{0}-{1}.json" -f $sid, $script:runStamp)
    (@{ storeId = $sid; displayName = $display; url = $orderUrl; payload = $payload } | ConvertTo-Json -Depth 12) |
      Set-Content -LiteralPath $dbg -Encoding UTF8

    $currency = 'USD'
    if ($payload.currency) { $currency = [string]$payload.currency }
    $srcUrl = $orderUrl
    if ($payload.url) { $srcUrl = [string]$payload.url }

    if ((Get-Command Send-QingquanIngest -ErrorAction SilentlyContinue) -and $cfg.qingquan -and $cfg.qingquan.enabled) {
      if ($useDryRun) {
        Write-Step ("  qingquan dryRun: would report {0} orders" -f $rawRows.Count)
      } else {
        $collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00')
        $qqItems = ConvertTo-QingquanOrderIngestItems -Rows $rawRows -CollectedAt $collectedAt `
          -StoreId $sid -StoreName $display -Currency $currency -SourceUrl $srcUrl
        Write-Step ("  report Qingquan tiktok_orders items={0}..." -f $qqItems.Count)
        $qq = Send-QingquanIngest -Config $cfg -Items $qqItems -Source 'tiktok_orders'
        $item.qingquanAccepted = $qq.accepted
        $item.qingquanDup = $qq.duplicated
        if ($qq.error) { $item.error = [string]$qq.error }
        Write-Step ("  qingquan accepted={0} dup={1} failed={2} ok={3}" -f $qq.accepted, $qq.duplicated, $qq.failed, $qq.ok)
      }
    } else {
      Write-Step '  skip qingquan (disabled or client missing)'
    }

    # —— 订单详情补 SKU 行（fact_tiktok_order_line）——
    if ($orderDetailEnabled -and $detailOneLine -and $orderDetailMax -gt 0 -and $rawRows.Count -gt 0) {
      $detailBase = Get-OrderDetailBaseUrl $orderUrl
      $region = Get-OrderRegionQuery $orderUrl
      $targets = @($rawRows | Select-Object -First $orderDetailMax)
      Write-Step ("  order detail enrich: {0}/{1} orders base={2}" -f $targets.Count, $rawRows.Count, $detailBase)
      $detailSamples = New-Object System.Collections.ArrayList
      $allLineItems = New-Object System.Collections.ArrayList
      $di = 0
      foreach ($orow in $targets) {
        $di++
        $oid = ''
        if ($orow.orderId) { $oid = [string]$orow.orderId }
        elseif ($orow.order_id) { $oid = [string]$orow.order_id }
        if (-not $oid) { continue }
        $detailUrl = "{0}?order_no={1}" -f $detailBase, $oid
        if ($region) { $detailUrl = "{0}&shop_region={1}" -f $detailUrl, $region }
        Write-Step ("  detail [{0}/{1}] {2}" -f $di, $targets.Count, $oid)
        try {
          $null = Invoke-Ziniao @('page', 'visit', '--store-id', $sid, '--url', $detailUrl, '--wait-until', 'domcontentloaded', '--timeout', '60000')
          Start-Sleep -Milliseconds $orderDetailWaitMs
          $dout = Invoke-Ziniao @('page', 'exec', '--store-id', $sid, '--script', $detailOneLine, '--timeout', '45000')
          $dp = Get-ScrapePayload $dout
          if ($dp -and $dp.ok -and $dp.lines -and @($dp.lines).Count -gt 0) {
            $item.detailOk++
            $lines = @($dp.lines)
            $item.lineItems += $lines.Count
            if ($detailSamples.Count -lt 3) {
              [void]$detailSamples.Add(@{ orderId = $oid; url = $detailUrl; lineCount = $lines.Count; sample = $lines[0] })
            }
            # 回填列表行上的 sellerSku/skuId（首行）方便本地 debug
            $first = $lines[0]
            if ($first.sellerSku -and -not $orow.sellerSku) { try { $orow | Add-Member -NotePropertyName sellerSku -NotePropertyValue ([string]$first.sellerSku) -Force } catch {} }
            if ($first.skuId -and -not $orow.skuId) { try { $orow | Add-Member -NotePropertyName skuId -NotePropertyValue ([string]$first.skuId) -Force } catch {} }
            if ($first.productName -and ("$($orow.productName)" -match '件商品')) {
              try { $orow | Add-Member -NotePropertyName productName -NotePropertyValue ([string]$first.productName) -Force } catch {}
            }
            foreach ($ln in $lines) {
              [void]$allLineItems.Add([pscustomobject]@{
                orderId = $oid
                line = $ln
                detailUrl = $(if ($dp.url) { [string]$dp.url } else { $detailUrl })
                currency = $(if ($dp.currency) { [string]$dp.currency } else { $currency })
              })
            }
          } else {
            $item.detailFail++
            $err = if ($dp -and $dp.error) { [string]$dp.error } else { 'detail scrape empty' }
            Write-Step ("    detail fail: {0}" -f $err)
          }
        } catch {
          $item.detailFail++
          Write-Step ("    detail exception: {0}" -f $_)
        }
      }

      $detDbg = Join-Path $script:logsDir ("orders-detail-debug-{0}-{1}.json" -f $sid, $script:runStamp)
      (@{
        storeId = $sid; displayName = $display
        detailOk = $item.detailOk; detailFail = $item.detailFail; lineItems = $item.lineItems
        samples = @($detailSamples)
      } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $detDbg -Encoding UTF8

      if ((Get-Command ConvertTo-QingquanOrderLineIngestItems -ErrorAction SilentlyContinue) -and `
          (Get-Command Send-QingquanIngest -ErrorAction SilentlyContinue) -and `
          $cfg.qingquan -and $cfg.qingquan.enabled -and $allLineItems.Count -gt 0) {
        if ($useDryRun) {
          Write-Step ("  qingquan dryRun: would report {0} order lines" -f $allLineItems.Count)
        } else {
          $collectedAt2 = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00')
          $lineEnvelope = New-Object System.Collections.ArrayList
          # 按订单分组转换
          $byOrder = @{}
          foreach ($wrap in $allLineItems) {
            $k = [string]$wrap.orderId
            if (-not $byOrder.ContainsKey($k)) { $byOrder[$k] = @{ lines = New-Object System.Collections.ArrayList; url = [string]$wrap.detailUrl; currency = [string]$wrap.currency } }
            [void]$byOrder[$k].lines.Add($wrap.line)
            if ($wrap.detailUrl) { $byOrder[$k].url = [string]$wrap.detailUrl }
            if ($wrap.currency) { $byOrder[$k].currency = [string]$wrap.currency }
          }
          foreach ($okey in $byOrder.Keys) {
            $pack = $byOrder[$okey]
            $bizHint = ''
            # 从列表行找 biz
            foreach ($rr in $rawRows) {
              $rid = ''
              if ($rr.orderId) { $rid = [string]$rr.orderId } elseif ($rr.order_id) { $rid = [string]$rr.order_id }
              if ($rid -eq $okey) {
                # ConvertTo-QingquanOrderIngestItems 会算 biz；这里尽量从 createTime 留给后端
                break
              }
            }
            $part = ConvertTo-QingquanOrderLineIngestItems -Lines @($pack.lines) -CollectedAt $collectedAt2 `
              -StoreId $sid -OrderId $okey -StoreName $display -Currency $pack.currency -SourceUrl $pack.url -BizDate $bizHint
            foreach ($it in @($part)) { [void]$lineEnvelope.Add($it) }
          }
          Write-Step ("  report Qingquan tiktok_order_lines items={0}..." -f $lineEnvelope.Count)
          $qqL = Send-QingquanIngest -Config $cfg -Items @($lineEnvelope.ToArray()) -Source 'tiktok_order_lines'
          $item.lineAccepted = $qqL.accepted
          $item.lineDup = $qqL.duplicated
          if ($qqL.error -and -not $item.error) { $item.error = [string]$qqL.error }
          Write-Step ("  order_lines accepted={0} dup={1} failed={2} ok={3}" -f $qqL.accepted, $qqL.duplicated, $qqL.failed, $qqL.ok)
        }
      } elseif ($allLineItems.Count -eq 0) {
        Write-Step '  no order line items scraped from details'
      }
    } elseif (-not $orderDetailEnabled) {
      Write-Step '  skip order detail enrich (disabled or script missing)'
    }

    $item.ok = $true
  } catch {
    $item.error = [string]$_
    Write-Step ("  FAIL: {0}" -f $item.error)
  } finally {
    if ($cfg.options -and $null -ne $cfg.options.closeAfter -and -not [bool]$cfg.options.closeAfter) {
      Write-Step '  leave store open'
    } else {
      try { $null = Invoke-Ziniao @('store', 'close', '--id', $sid) } catch { }
    }
  }
  $summary += [pscustomobject]$item
  if ($cfg.options.delayBetweenStoresMs) { Start-Sleep -Milliseconds ([int]$cfg.options.delayBetweenStoresMs) }
}

Write-Step '======== ORDERS SUMMARY ========'
$summary | Format-Table storeName, displayName, ok, rows, detailOk, lineItems, qingquanAccepted, lineAccepted, error -AutoSize
$okN = @($summary | Where-Object { $_.ok }).Count
Write-Step ("OK {0}/{1}" -f $okN, $summary.Count)
$sumPath = Join-Path $script:logsDir ("orders-summary-{0}.json" -f $script:runStamp)
($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $sumPath -Encoding UTF8
Write-Step ("summary: {0}" -f $sumPath)
Write-Step '===== orders multi-store END ====='
