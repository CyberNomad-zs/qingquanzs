# Multi-store TikTok ad scrape via ziniao-cli (dynamic store list)
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-multi-store.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-multi-store.ps1 -DryRun true
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-multi-store.ps1 -DryRun false
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-multi-store.ps1 -ListOnly
#
# Requires: Ziniao client running + ziniao-cli doctor OK
# Config: config\stores.config.json

param(
  [string]$ConfigPath = "",
  [switch]$ListOnly,
  # string so -File callers work (Nullable[bool] cannot bind "$true"/"$false" from -File)
  # omit / empty => use config.options.dryRun; true|1|yes / false|0|no
  [string]$DryRun = "",
  # today | yesterday | yyyy-MM-dd（点日历补历史日）。
  # 不要叫 DateMode：PS 参数大小写不敏感，会和脚本里的 $dateMode 撞名，
  # `$dateMode = 'yesterday'` 会把传入值盖掉。
  [string]$PageDate = ""
)

$ErrorActionPreference = 'Stop'
# ziniao-cli writes progress to stderr; do not treat as terminating
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent
if (-not $ConfigPath) {
  $ConfigPath = Join-Path $root 'config\stores.config.json'
}
$scrapeJsPath = Join-Path $root 'scripts\scrape-ads-page.js'
$dateRangeJsPath = Join-Path $root 'scripts\set-date-range.js'

if (-not (Test-Path $ConfigPath)) {
  throw "Missing config: $ConfigPath (copy config\stores.config.example.json)"
}
if (-not (Test-Path $scrapeJsPath)) {
  throw "Missing scrape script: $scrapeJsPath"
}
if (-not (Test-Path $dateRangeJsPath)) {
  throw "Missing date-range script: $dateRangeJsPath"
}

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$scrapeJs = Get-Content $scrapeJsPath -Raw -Encoding UTF8
$dateRangeJsTemplate = Get-Content $dateRangeJsPath -Raw -Encoding UTF8
$analysisLib = Join-Path $PSScriptRoot 'daily-analysis.ps1'
if (Test-Path $analysisLib) { . $analysisLib }
$qingquanLib = Join-Path $PSScriptRoot 'qingquan-client.ps1'
if (Test-Path $qingquanLib) { . $qingquanLib }
$ziniaoWinLib = Join-Path $PSScriptRoot 'ziniao-window.ps1'
if (-not (Test-Path $ziniaoWinLib)) { throw "Missing $ziniaoWinLib" }
. $ziniaoWinLib

# Always create logs/ first so early failures (Bridge down, ListOnly, throw) still leave a file
$script:logsDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $script:logsDir | Out-Null
$script:runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:runLogFile = Join-Path $script:logsDir ("multi-store-run-{0}.log" -f $script:runStamp)
$script:runMode = if ($ListOnly) { 'listOnly' } else { 'scrape' }

function Write-RunLog([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try {
    Add-Content -LiteralPath $script:runLogFile -Value $line -Encoding UTF8
  } catch { }
}

function Write-Step([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
  Write-Host $line
  Write-RunLog $msg
}

function Save-FailArtifact([string]$errorText, [hashtable]$extra = @{}) {
  $obj = [ordered]@{
    ok        = $false
    mode      = $script:runMode
    time      = (Get-Date).ToString('o')
    error     = $errorText
    runLog    = $script:runLogFile
    config    = $ConfigPath
    root      = $root
  }
  foreach ($k in $extra.Keys) { $obj[$k] = $extra[$k] }
  $failPath = Join-Path $script:logsDir ("multi-store-fail-{0}.json" -f $script:runStamp)
  try {
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $failPath -Encoding UTF8
    Write-Step ("fail log: {0}" -f $failPath)
  } catch {
    Write-Host ("[warn] could not write fail log: {0}" -f $_)
  }
  Write-Step ("run log: {0}" -f $script:runLogFile)
  return $failPath
}

Write-Step ("===== multi-store START mode={0} =====" -f $script:runMode)
Write-Step ("root={0}" -f $root)
Write-Step ("config={0}" -f $ConfigPath)
Write-Step ("runLog={0}" -f $script:runLogFile)

trap {
  $errText = ($_ | Out-String).Trim()
  try {
    Write-Host ""
    Write-Host "===== FATAL (see logs/) =====" -ForegroundColor Red
    Write-Host $errText
    if ($errText -match '9481|Bridge|store list failed|无法连接|network') {
      Write-Host ""
      Write-Host "HINT: 紫鸟 Bridge 不可用。请打开并登录「紫鸟」桌面客户端后重试。" -ForegroundColor Yellow
      Write-Host "      仅安装 Node/ziniao-cli 不够；本机客户端须在线 (127.0.0.1:9481)。" -ForegroundColor Yellow
    }
    Save-FailArtifact $errText | Out-Null
  } catch { }
  break
}

function Get-BizDate([string]$mode) {
  if ($mode -match '^\d{4}-\d{2}-\d{2}$') { return $mode }
  $d = Get-Date
  if ($mode -eq 'yesterday') { $d = $d.AddDays(-1) }
  return $d.ToString('yyyy-MM-dd')
}

# 计划开关归一：on | off | unknown
function Normalize-PlanStatus($raw) {
  if ($null -eq $raw) { return 'unknown' }
  $s = ([string]$raw).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($s)) { return 'unknown' }
  if ($s -match '^(on|1|true|open|enable|enabled|active|running|投放中|开启|开)$') { return 'on' }
  if ($s -match '^(off|0|false|close|closed|disable|disabled|paused|inactive|已关闭|关闭|关|暂停)$') { return 'off' }
  return 'unknown'
}

# 策略 C：已关闭 且 花费=0 且 销售额=0 → 跳过；有花费/销售额的关闭计划仍保留
function Test-SkipZeroDisabledCampaign($row) {
  $ps = Normalize-PlanStatus $row.planStatus
  if ($ps -ne 'off') { return $false }
  $spend = 0.0
  if ($null -ne $row.spend) { $spend = [double]$row.spend }
  $revenue = 0.0
  if ($null -ne $row.revenue) { $revenue = [double]$row.revenue }
  return ($spend -eq 0 -and $revenue -eq 0)
}

function Test-StoreFilter($store, $filter) {
  if ($filter.includeStoreIds -and @($filter.includeStoreIds).Count -gt 0) {
    if ($store.storeId -notin @($filter.includeStoreIds)) { return $false }
  }
  if ($filter.excludeStoreIds -and ($store.storeId -in @($filter.excludeStoreIds))) {
    return $false
  }
  if ($filter.requireIp -eq $true) {
    if (-not $store.ip -or [string]::IsNullOrWhiteSpace([string]$store.ip)) { return $false }
  }
  $platform = [string]$store.platformName
  $name = [string]$store.storeName
  if ($filter.platformContains -and @($filter.platformContains).Count -gt 0) {
    $ok = $false
    foreach ($p in @($filter.platformContains)) {
      if ($platform -like "*$p*") { $ok = $true; break }
    }
    if (-not $ok) { return $false }
  }
  if ($filter.nameContains -and @($filter.nameContains).Count -gt 0) {
    $ok = $false
    foreach ($p in @($filter.nameContains)) {
      if ($name -like "*$p*") { $ok = $true; break }
    }
    if (-not $ok) { return $false }
  }
  if ($filter.nameExclude) {
    foreach ($p in @($filter.nameExclude)) {
      if ($name -like "*$p*") { return $false }
    }
  }
  return $true
}

function Get-AdsUrl($store, $adsUrlCfg) {
  $platform = [string]$store.platformName
  if ($adsUrlCfg.byPlatform) {
    foreach ($p in $adsUrlCfg.byPlatform.PSObject.Properties) {
      if ($p.Name -eq $platform) { return [string]$p.Value }
    }
    foreach ($p in $adsUrlCfg.byPlatform.PSObject.Properties) {
      if ($platform -like "*$($p.Name)*") { return [string]$p.Value }
    }
  }
  return [string]$adsUrlCfg.default
}

function Get-DisplayName($store, $map) {
  $name = [string]$store.storeName
  if ($map) {
    foreach ($p in $map.PSObject.Properties) {
      if ($p.Name -eq $name) { return [string]$p.Value }
    }
    foreach ($p in $map.PSObject.Properties) {
      if ($name -like "*$($p.Name)*" -or $p.Name -like "*$name*") {
        return [string]$p.Value
      }
    }
  }
  return $name
}

# Maximize-ZiniaoBrowserWindows / Invoke-ZiniaoStoreMaximize → ziniao-window.ps1

function Get-CurrencyConfig($cfg) {
  # 与 TikTok 广告后台一致：广告花费 / 销售额统一按美金(USD) 落库与写飞书
  $target = 'USD'
  $pageDefault = 'USD'
  $convert = $true
  $rates = @{
    USD = 1.0
    GBP = 1.27
    EUR = 1.08
    CNY = 0.14
  }
  if ($cfg.currency) {
    if ($cfg.currency.target) { $target = ([string]$cfg.currency.target).ToUpperInvariant() }
    if ($cfg.currency.pageDefault) { $pageDefault = ([string]$cfg.currency.pageDefault).ToUpperInvariant() }
    if ($null -ne $cfg.currency.convert) { $convert = [bool]$cfg.currency.convert }
    if ($cfg.currency.ratesToUsd) {
      foreach ($p in $cfg.currency.ratesToUsd.PSObject.Properties) {
        try { $rates[$p.Name.ToUpperInvariant()] = [double]$p.Value } catch { }
      }
    }
  }
  return [pscustomobject]@{
    target      = $target
    pageDefault = $pageDefault
    convert     = $convert
    ratesToUsd  = $rates
  }
}

function Convert-MoneyToTarget {
  param(
    [double]$Amount,
    [string]$FromCurrency,
    [string]$TargetCurrency,
    $RatesToUsd
  )
  $from = if ($FromCurrency) { $FromCurrency.ToUpperInvariant() } else { 'USD' }
  $to = if ($TargetCurrency) { $TargetCurrency.ToUpperInvariant() } else { 'USD' }
  if ($from -eq $to) { return [math]::Round($Amount, 2) }
  $rateFrom = 1.0
  $rateTo = 1.0
  if ($RatesToUsd.ContainsKey($from)) { $rateFrom = [double]$RatesToUsd[$from] }
  if ($RatesToUsd.ContainsKey($to)) { $rateTo = [double]$RatesToUsd[$to] }
  if ($rateFrom -le 0 -or $rateTo -le 0) { return [math]::Round($Amount, 2) }
  # ratesToUsd: 1 unit of currency → USD；先转 USD 再转目标币
  $usd = $Amount * $rateFrom
  return [math]::Round($usd / $rateTo, 2)
}

function Get-FeishuToken($appId, $appSecret) {
  $body = @{ app_id = $appId; app_secret = $appSecret } | ConvertTo-Json
  $r = Invoke-RestMethod -Method POST -Uri 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal' `
    -ContentType 'application/json; charset=utf-8' -Body $body
  if ($r.code -ne 0) { throw "Feishu token failed: $($r.msg)" }
  return $r.tenant_access_token
}

function Write-FeishuRows($feishu, $rows, $dryRun) {
  if ($dryRun) {
    Write-Step ("  [dry-run] skip Feishu write, rows={0}" -f $rows.Count)
    return @{ written = 0; dryRun = $true }
  }
  if (-not $rows.Count) { return @{ written = 0; dryRun = $false } }

  $token = Get-FeishuToken $feishu.appId $feishu.appSecret
  $url = "https://open.feishu.cn/open-apis/bitable/v1/apps/$($feishu.appToken)/tables/$($feishu.tableId)/records/batch_create"
  $fieldsUrl = "https://open.feishu.cn/open-apis/bitable/v1/apps/$($feishu.appToken)/tables/$($feishu.tableId)/fields?page_size=100"
  $fieldList = Invoke-RestMethod -Method GET -Uri $fieldsUrl -Headers @{ Authorization = "Bearer $token" }
  $names = @($fieldList.data.items | ForEach-Object { $_.field_name })

  function Pick-Name([string[]]$aliases) {
    foreach ($a in $aliases) { if ($names -contains $a) { return $a } }
    return $null
  }

  # UTF-8 field names (same as extension BITABLE_FIELDS)
  $utf8 = [System.Text.Encoding]::UTF8
  $A_DATE = @($utf8.GetString([byte[]](0xE6,0x97,0xA5,0xE6,0x9C,0x9F)))
  $A_STORE = @($utf8.GetString([byte[]](0xE5,0xBA,0x97,0xE9,0x93,0xBA)))
  $A_STORE_ID = @($utf8.GetString([byte[]](0xE5,0xBA,0x97,0xE9,0x93,0xBA,0x49,0x44)))
  $A_CAMPAIGN = @(
    $utf8.GetString([byte[]](0xE5,0x93,0x81,0xE5,0x90,0x8D)),
    $utf8.GetString([byte[]](0xE5,0xB9,0xBF,0xE5,0x91,0x8A,0xE7,0xB3,0xBB,0xE5,0x88,0x97,0xE5,0x90,0x8D,0xE7,0xA7,0xB0))
  )
  $A_SPEND = @(
    $utf8.GetString([byte[]](0xE5,0xB9,0xBF,0xE5,0x91,0x8A,0xE8,0x8A,0xB1,0xE8,0xB4,0xB9)),
    $utf8.GetString([byte[]](0xE6,0x88,0x90,0xE6,0x9C,0xAC))
  )
  $A_ORDERS = @($utf8.GetString([byte[]](0xE9,0x94,0x80,0xE9,0x87,0x8F)))
  $A_ROI = @('ROI')
  $A_REVENUE = @(
    $utf8.GetString([byte[]](0xE9,0x94,0x80,0xE5,0x94,0xAE,0xE9,0xA2,0x9D)),
    $utf8.GetString([byte[]](0xE6,0x80,0xBB,0xE6,0x94,0xB6,0xE5,0x85,0xA5))
  )
  $A_SCRAPED = @($utf8.GetString([byte[]](0xE6,0x8A,0x93,0xE5,0x8F,0x96,0xE6,0x97,0xB6,0xE9,0x97,0xB4)))
  $A_URL = @($utf8.GetString([byte[]](0xE6,0x95,0xB0,0xE6,0x8D,0xAE,0xE6,0xBA,0x90,0x55,0x52,0x4C)))
  $A_STATUS = @($utf8.GetString([byte[]](0xE7,0x8A,0xB6,0xE6,0x80,0x81)))
  # 计划状态（开关）≠ 投放状态（已生效等）
  $A_PLAN = @(
    $utf8.GetString([byte[]](0xE8,0xAE,0xA1,0xE5,0x88,0x92,0xE7,0x8A,0xB6,0xE6,0x80,0x81)),
    $utf8.GetString([byte[]](0xE5,0xBC,0x80,0xE5,0x85,0xB3))
  )
  $A_DELIVERY = @(
    $utf8.GetString([byte[]](0xE6,0x8A,0x95,0xE6,0x94,0xBE,0xE7,0x8A,0xB6,0xE6,0x80,0x81))
  )
  # P1
  $A_BUDGET = @(
    $utf8.GetString([byte[]](0xE6,0x97,0xA5,0xE9,0xA2,0x84,0xE7,0xAE,0x97)),
    $utf8.GetString([byte[]](0xE5,0xBD,0x93,0xE5,0x89,0x8D,0xE9,0xA2,0x84,0xE7,0xAE,0x97))
  )
  $A_TARGET_ROI = @(
    $utf8.GetString([byte[]](0xE7,0x9B,0xAE,0xE6,0xA0,0x87,0x52,0x4F,0x49)),
    $utf8.GetString([byte[]](0xE7,0x9B,0xAE,0xE6,0xA0,0x87,0x20,0x52,0x4F,0x49))
  )
  $A_NET = @($utf8.GetString([byte[]](0xE5,0x87,0x80,0xE6,0x88,0x90,0xE6,0x9C,0xAC)))
  $A_CPA = @(
    $utf8.GetString([byte[]](0xE5,0xB9,0xB3,0xE5,0x9D,0x87,0xE4,0xB8,0x8B,0xE5,0x8D,0x95,0xE6,0x88,0x90,0xE6,0x9C,0xAC)),
    'CPA'
  )

  $fn = @{
    date           = Pick-Name $A_DATE
    store          = Pick-Name $A_STORE
    storeId        = Pick-Name $A_STORE_ID
    campaign       = Pick-Name $A_CAMPAIGN
    spend          = Pick-Name $A_SPEND
    orders         = Pick-Name $A_ORDERS
    roi            = Pick-Name $A_ROI
    revenue        = Pick-Name $A_REVENUE
    scrapedAt      = Pick-Name $A_SCRAPED
    sourceUrl      = Pick-Name $A_URL
    status         = Pick-Name $A_STATUS
    planStatus     = Pick-Name $A_PLAN
    deliveryStatus = Pick-Name $A_DELIVERY
    dailyBudget    = Pick-Name $A_BUDGET
    targetRoi      = Pick-Name $A_TARGET_ROI
    netCost        = Pick-Name $A_NET
    avgOrderCost   = Pick-Name $A_CPA
  }

  if (-not $fn.campaign -or -not $fn.store) {
    throw ("Feishu fields incomplete. Have: {0}" -f ($names -join ', '))
  }

  $records = @()
  foreach ($row in $rows) {
    $fields = @{}
    if ($fn.date) {
      $dt = [DateTime]::ParseExact($row.date, 'yyyy-MM-dd', $null)
      $fields[$fn.date] = [DateTimeOffset]::new($dt).ToUnixTimeMilliseconds()
    }
    if ($fn.store) { $fields[$fn.store] = $row.store }
    if ($fn.storeId) { $fields[$fn.storeId] = $row.storeId }
    if ($fn.campaign) { $fields[$fn.campaign] = $row.campaign }
    if ($fn.spend) { $fields[$fn.spend] = [double]$row.spend }
    if ($fn.orders) { $fields[$fn.orders] = [double]$row.orders }
    if ($fn.roi) { $fields[$fn.roi] = [double]$row.roi }
    if ($fn.revenue) { $fields[$fn.revenue] = [double]$row.revenue }
    if ($fn.scrapedAt) { $fields[$fn.scrapedAt] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    if ($fn.sourceUrl) { $fields[$fn.sourceUrl] = $row.sourceUrl }
    if ($fn.status) { $fields[$fn.status] = $row.status }
    if ($fn.planStatus -and $row.planStatus) {
      $ps = [string]$row.planStatus
      # 飞书展示：on/off/unknown → 投放中/已关闭/未知
      if ($ps -eq 'on') { $ps = $utf8.GetString([byte[]](0xE6,0x8A,0x95,0xE6,0x94,0xBE,0xE4,0xB8,0xAD)) }
      elseif ($ps -eq 'off') { $ps = $utf8.GetString([byte[]](0xE5,0xB7,0xB2,0xE5,0x85,0xB3,0xE9,0x97,0xAD)) }
      elseif ($ps -eq 'unknown') { $ps = $utf8.GetString([byte[]](0xE6,0x9C,0xAA,0xE7,0x9F,0xA5)) }
      $fields[$fn.planStatus] = $ps
    }
    if ($fn.deliveryStatus -and $row.deliveryStatus) {
      $fields[$fn.deliveryStatus] = [string]$row.deliveryStatus
    }
    if ($fn.dailyBudget -and $null -ne $row.dailyBudget -and "$($row.dailyBudget)" -ne '') {
      $fields[$fn.dailyBudget] = [double]$row.dailyBudget
    }
    if ($fn.targetRoi -and $null -ne $row.targetRoi -and "$($row.targetRoi)" -ne '') {
      $fields[$fn.targetRoi] = [double]$row.targetRoi
    }
    if ($fn.netCost -and $null -ne $row.netCost -and "$($row.netCost)" -ne '') {
      $fields[$fn.netCost] = [double]$row.netCost
    }
    if ($fn.avgOrderCost -and $null -ne $row.avgOrderCost -and "$($row.avgOrderCost)" -ne '') {
      $fields[$fn.avgOrderCost] = [double]$row.avgOrderCost
    }
    $records += @{ fields = $fields }
  }

  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ records = $records } | ConvertTo-Json -Depth 8 -Compress))
  $resp = Invoke-RestMethod -Method POST -Uri $url -Headers @{ Authorization = "Bearer $token" } `
    -ContentType 'application/json; charset=utf-8' -Body $bodyBytes
  if ($resp.code -ne 0) {
    throw ("Feishu write failed: code={0} msg={1}" -f $resp.code, $resp.msg)
  }
  return @{ written = $records.Count; dryRun = $false }
}

# --- main ---
function ConvertTo-ProcessArgument([string]$arg) {
  # CommandLineToArgvW-style quoting for ProcessStartInfo.Arguments
  if ($null -eq $arg) { return '""' }
  if ($arg -notmatch '[\s"]') { return $arg }
  $bs = [char]0x5C
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append([char]0x22)
  $backslashes = 0
  foreach ($ch in $arg.ToCharArray()) {
    if ($ch -eq $bs) {
      $backslashes++
      continue
    }
    if ($ch -eq [char]0x22) {
      [void]$sb.Append($bs, $backslashes * 2 + 1)
      [void]$sb.Append([char]0x22)
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$sb.Append($bs, $backslashes)
      $backslashes = 0
    }
    [void]$sb.Append($ch)
  }
  if ($backslashes -gt 0) { [void]$sb.Append($bs, $backslashes * 2) }
  [void]$sb.Append([char]0x22)
  return $sb.ToString()
}

# Cache: npm ziniao-cli is a .ps1 shim — Process.Start cannot run it; invoke node + run.js directly
$script:ZiniaoNode = $null
$script:ZiniaoRunJs = $null

function Initialize-ZiniaoCli {
  if ($script:ZiniaoNode -and $script:ZiniaoRunJs) { return }

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) { throw "node not found in PATH (required by ziniao-cli)" }
  $script:ZiniaoNode = $nodeCmd.Source

  $candidates = @()
  $npmDir = Join-Path $env:APPDATA 'npm'
  if ($npmDir) {
    $candidates += (Join-Path $npmDir 'node_modules\@ziniao-open\cli\scripts\run.js')
  }
  $cmd = Get-Command ziniao-cli -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) {
    $base = Split-Path $cmd.Source -Parent
    $candidates += (Join-Path $base 'node_modules\@ziniao-open\cli\scripts\run.js')
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) {
      $script:ZiniaoRunJs = (Resolve-Path -LiteralPath $c).Path
      break
    }
  }
  if (-not $script:ZiniaoRunJs) {
    throw "ziniao-cli run.js not found. Install: npm i -g @ziniao-open/cli  (looked under %APPDATA%\npm\node_modules\@ziniao-open\cli)"
  }
  Write-Step ("ziniao runtime: node={0} run.js={1}" -f $script:ZiniaoNode, $script:ZiniaoRunJs)
}

function Invoke-Ziniao([string[]]$CliArgs) {
  # UTF-8 capture via ProcessStartInfo. npm ziniao-cli is .ps1 — call node run.js instead.
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
  try {
    [void]$p.Start()
  } catch {
    throw "Failed to start ziniao (node): $($_.Exception.Message)"
  }
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  $parts = @()
  if (-not [string]::IsNullOrEmpty($stdout)) { $parts += $stdout.TrimEnd("`r", "`n") }
  if (-not [string]::IsNullOrEmpty($stderr)) { $parts += $stderr.TrimEnd("`r", "`n") }
  return ($parts -join "`n")
}

function Save-ScrapeDebug {
  param(
    [string]$StoreId,
    [string]$StoreName,
    [string]$DisplayName,
    [string]$AdsUrl,
    [string]$ExecOut,
    $Payload,
    [string]$ErrorMsg,
    [switch]$AsLast
  )
  $logsDir = Join-Path $root 'logs'
  New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $path = if ($AsLast) {
    Join-Path $logsDir 'scrape-debug-last.json'
  } else {
    Join-Path $logsDir ("scrape-debug-{0}-{1}.json" -f $StoreId, $stamp)
  }
  $previewLen = 8000
  $execPreview = $ExecOut
  if ($execPreview -and $execPreview.Length -gt $previewLen) {
    $execPreview = $execPreview.Substring(0, $previewLen) + '...[truncated]'
  }
  $obj = [ordered]@{
    storeId       = $StoreId
    storeName     = $StoreName
    displayName   = $DisplayName
    adsUrl        = $AdsUrl
    error         = $ErrorMsg
    execOutLength = if ($ExecOut) { $ExecOut.Length } else { 0 }
    execOut       = $execPreview
    payload       = $Payload
    payloadUrl    = if ($Payload -and $Payload.url) { [string]$Payload.url } else { $null }
    capturedAt    = (Get-Date).ToString('o')
  }
  ($obj | ConvertTo-Json -Depth 10) | Set-Content -Path $path -Encoding UTF8
  Write-Step ("  debug saved: {0}" -f $path)
  return $path
}

function ConvertTo-ScrapeOneLine([string]$js) {
  # // comments become catastrophic when newlines are removed — strip first
  $s = [regex]::Replace($js, '/\*[\s\S]*?\*/', ' ')
  $s = [regex]::Replace($s, '(?m)^\s*//.*$', '')
  $s = [regex]::Replace($s, '(?m)([^:"''\\])//[^\r\n]*', '$1')
  $s = ($s -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
  if ($s -notmatch '\)\s*\(\s*\)\s*;?\s*$' -and $s -notmatch '\}\s*\)\s*\(\s*\)\s*;?\s*$') {
    Write-Step "WARN scrape script may be truncated (len=$($s.Length))"
  }
  return $s
}

function ConvertFrom-JsonSafe([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Get-PageExecJsonPayload([string]$execOut, [scriptblock]$shapeTest) {
  function Convert-MaybeJsonString($v) {
    if ($v -is [string]) {
      $inner = ConvertFrom-JsonSafe $v
      if ($null -ne $inner -and (& $shapeTest $inner)) { return $inner }
      return $null
    }
    if (& $shapeTest $v) { return $v }
    return $null
  }

  $root = ConvertFrom-JsonSafe $execOut
  if ($null -ne $root) {
    $candidates = @(
      $root
      $(if ($root.data) { $root.data } else { $null })
      $(if ($root.data -and $root.data.data) { $root.data.data } else { $null })
      $(if ($root.data -and $root.data.data -and $root.data.data.result) { $root.data.data.result } else { $null })
      $(if ($root.data -and $root.data.result) { $root.data.result } else { $null })
      $(if ($root.result) { $root.result } else { $null })
    )
    foreach ($c in $candidates) {
      if ($null -eq $c) { continue }
      if ($c -is [string]) {
        $hit = Convert-MaybeJsonString $c
        if ($hit) { return $hit }
        continue
      }
      if ($c.PSObject.Properties.Name -contains 'value') {
        $hit = Convert-MaybeJsonString $c.value
        if ($hit) { return $hit }
      }
      if ($c.PSObject.Properties.Name -contains 'result') {
        $hit = Convert-MaybeJsonString $c.result
        if ($hit) { return $hit }
        if ($c.result -and ($c.result.PSObject.Properties.Name -contains 'value')) {
          $hit = Convert-MaybeJsonString $c.result.value
          if ($hit) { return $hit }
        }
      }
      $hit = Convert-MaybeJsonString $c
      if ($hit) { return $hit }
    }
  }

  if ($execOut -match '(?s)(\{\s*"ok"\s*:\s*(?:true|false)[\s\S]{0,8000}\})') {
    $m = ConvertFrom-JsonSafe $Matches[1]
    if ($m -and (& $shapeTest $m)) { return $m }
  }
  return $null
}

function Get-DateRangePayload([string]$execOut) {
  $shape = {
    param($o)
    if ($null -eq $o) { return $false }
    if ($o -is [string]) { return $false }
    $names = @($o.PSObject.Properties.Name)
    return ($names -contains 'ok') -and (
      ($names -contains 'mode') -or ($names -contains 'action') -or
      ($names -contains 'before') -or ($names -contains 'after') -or
      ($names -contains 'clicked') -or ($names -contains 'matched') -or
      ($names -contains 'range') -or ($names -contains 'panelOpen')
    )
  }
  return Get-PageExecJsonPayload $execOut $shape
}

function Get-ScrapePayload([string]$execOut) {
  # ziniao-cli page exec shapes seen in the wild:
  #   { ok, data: { ok, storeId, data: { exceptionDetails, result: "<json string>", targetId } } }
  #   { ok, data: { data: { result: { type, value: "<json string>" } } } }  (raw CDP)
  # Our scraper returns JSON.stringify({ ok, rows, source, url, error })
  function Test-ScrapeShape($o) {
    if ($null -eq $o) { return $false }
    if ($o -is [string]) { return $false }
    $names = @($o.PSObject.Properties.Name)
    return ($names -contains 'rows') -or (($names -contains 'ok') -and ($names -contains 'source' -or $names -contains 'error'))
  }
  function Convert-MaybeJsonString($v) {
    if ($v -is [string]) {
      $inner = ConvertFrom-JsonSafe $v
      if (Test-ScrapeShape $inner) { return $inner }
      return $null
    }
    if (Test-ScrapeShape $v) { return $v }
    if ($v -and ($v.PSObject.Properties.Name -contains 'value')) {
      return Convert-MaybeJsonString $v.value
    }
    return $null
  }

  $root = ConvertFrom-JsonSafe $execOut
  if (-not $root) {
    if ($execOut -match '(?s)(\{\s*"ok"\s*:\s*(?:true|false)\s*,\s*"source"[\s\S]*?"rows"\s*:\s*\[[\s\S]*?\})') {
      return (ConvertFrom-JsonSafe $Matches[1])
    }
    return $null
  }

  # Walk common nest paths first
  $paths = @(
    { param($r) $r },
    { param($r) $r.data },
    { param($r) $r.data.data },
    { param($r) $r.data.result },
    { param($r) $r.data.data.result },
    { param($r) $r.data.data.result.value },
    { param($r) $r.result },
    { param($r) $r.result.value }
  )
  foreach ($get in $paths) {
    try {
      $node = & $get $root
    } catch { continue }
    if ($null -eq $node) { continue }

    # exception on this node?
    if ($node -isnot [string] -and $node.PSObject.Properties.Name -contains 'exceptionDetails' -and $node.exceptionDetails) {
      $ex = $node.exceptionDetails
      $msg = if ($ex.exception -and $ex.exception.description) { [string]$ex.exception.description }
             elseif ($ex.text) { [string]$ex.text }
             else { 'page exec exception' }
      return [pscustomobject]@{ ok = $false; rows = @(); error = $msg; source = 'exception' }
    }

    $parsed = Convert-MaybeJsonString $node
    if ($parsed) { return $parsed }

    # node has .result string/object
    if ($node -isnot [string] -and $node.PSObject.Properties.Name -contains 'result') {
      $parsed = Convert-MaybeJsonString $node.result
      if ($parsed) { return $parsed }
    }
  }

  # Fallback: unescaped scrape JSON embedded in the CLI text
  if ($execOut -match '(?s)(\{\s*"ok"\s*:\s*(?:true|false)\s*,\s*"source"\s*:[\s\S]*?"rows"\s*:\s*\[[\s\S]*?\})') {
    $inner = ConvertFrom-JsonSafe $Matches[1]
    if ($inner) { return $inner }
  }
  # Escaped form inside result:"{...}"
  if ($execOut -match '"result"\s*:\s*"(\{\\"ok\\".+?\})"') {
    $unescaped = $Matches[1] -replace '\\"', '"' -replace '\\\\', '\'
    $inner = ConvertFrom-JsonSafe $unescaped
    if ($inner) { return $inner }
  }

  return [pscustomobject]@{
    ok         = $false
    rows       = @()
    error      = 'unrecognized page exec payload'
    source     = 'parse'
    rawPreview = if ($execOut.Length -gt 400) { $execOut.Substring(0, 400) } else { $execOut }
  }
}

Write-Step "check ziniao-cli..."
$doctorText = Invoke-Ziniao @('doctor')
$docOneLine = [string]($doctorText -replace '\r?\n', ' | ')
if ($docOneLine.Length -gt 500) { $docOneLine = $docOneLine.Substring(0, 500) }
Write-RunLog ("doctor: {0}" -f $docOneLine)
if ($doctorText -notmatch 'ZClaw|Bridge|ok|OK|通过') {
  Write-Host $doctorText
  Write-Step "WARN: ziniao doctor 未明确通过，若随后 store list 失败请先打开紫鸟客户端"
}

Write-Step "list stores (dynamic)..."
$listRaw = Invoke-Ziniao @('store', 'list', '--format', 'json')
if ($listRaw -match '(?s)\{[\s\S]*"ok"\s*:\s*true[\s\S]*\}') {
  $listRaw = $Matches[0]
}
try {
  $listObj = $listRaw | ConvertFrom-Json
} catch {
  Save-FailArtifact "store list JSON parse failed: $_" @{ rawPreview = if ($listRaw.Length -gt 800) { $listRaw.Substring(0, 800) } else { $listRaw } } | Out-Null
  throw "store list JSON parse failed: $_ | raw=$listRaw"
}
if (-not $listObj.ok) {
  $errMsg = "store list failed: $listRaw"
  $hint = $null
  if ($listRaw -match '9481|Bridge|network|无法连接') {
    $hint = "无法连接紫鸟 Bridge (http://127.0.0.1:9481)。请打开并登录紫鸟桌面客户端后重试。"
    Write-Host ""
    Write-Host "===== 紫鸟未连接 =====" -ForegroundColor Red
    Write-Host $hint -ForegroundColor Yellow
    Write-Host "步骤: 启动紫鸟客户端 → 登录 → 等待就绪 → 再点「预览店铺列表」" -ForegroundColor Yellow
    Write-Host ""
  }
  Save-FailArtifact $errMsg @{ hint = $hint; listRaw = $listRaw } | Out-Null
  throw $errMsg
}
$all = @($listObj.data.items)
Write-Step ("ziniao stores total: {0}" -f $all.Count)

$selected = @($all | Where-Object { Test-StoreFilter $_ $cfg.filter })
Write-Step ("after filter: {0}" -f $selected.Count)
$listLines = @()
foreach ($s in $selected) {
  $disp = Get-DisplayName $s $cfg.storeNameMap
  $ip = if ($s.ip) { $s.ip } else { '(no-ip)' }
  $line = ("  - {0} | {1} => Feishu[{2}] | {3} | {4}" -f $s.storeId, $s.storeName, $disp, $s.platformName, $ip)
  Write-Host $line
  $listLines += $line.Trim()
  Write-RunLog $line.Trim()
}

if ($ListOnly) {
  $listOut = Join-Path $script:logsDir ("multi-store-list-{0}.json" -f $script:runStamp)
  [pscustomobject]@{
    ok            = $true
    mode          = 'listOnly'
    time          = (Get-Date).ToString('o')
    totalStores   = $all.Count
    selectedCount = $selected.Count
    selected      = @($selected | ForEach-Object {
        [pscustomobject]@{
          storeId      = $_.storeId
          storeName    = $_.storeName
          displayName  = (Get-DisplayName $_ $cfg.storeNameMap)
          platformName = $_.platformName
          ip           = $_.ip
        }
      })
    runLog = $script:runLogFile
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $listOut -Encoding UTF8
  Write-Step ("ListOnly done. log: {0}" -f $listOut)
  Write-Step ("run log: {0}" -f $script:runLogFile)
  exit 0
}

if ($selected.Count -eq 0) {
  throw "No stores matched filter. Adjust requireIp / platformContains / excludeStoreIds."
}

function Convert-DryRunFlag([string]$raw) {
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  switch -Regex ($raw.Trim()) {
    '^(?i:true|1|yes|y|\$true)$'  { return $true }
    '^(?i:false|0|no|n|\$false)$' { return $false }
    default { throw "Invalid -DryRun value '$raw' (use true/false, or omit to use config)" }
  }
}
$dryRunParsed = Convert-DryRunFlag $DryRun
$useDryRun = if ($null -ne $dryRunParsed) { [bool]$dryRunParsed } else { [bool]$cfg.options.dryRun }
$pageDateArg = $PageDate
$dateMode = 'yesterday'
if (-not [string]::IsNullOrWhiteSpace($pageDateArg)) {
  $dateMode = $pageDateArg.Trim().ToLowerInvariant()
} elseif ($cfg.options -and $cfg.options.dateMode) {
  $dateMode = ([string]$cfg.options.dateMode).Trim().ToLowerInvariant()
}
if ($dateMode -ne 'today' -and $dateMode -ne 'yesterday' -and $dateMode -notmatch '^\d{4}-\d{2}-\d{2}$') {
  Write-Step ("dateMode={0} is not today/yesterday/yyyy-MM-dd; page date range will use yesterday" -f $dateMode)
  $dateMode = 'yesterday'
}
$bizDate = Get-BizDate $dateMode
$currencyCfg = Get-CurrencyConfig $cfg
$scrapeRetries = 3
$scrapeRetryWaitMs = 15000
$waitAfterDateChangeMs = 8000
$setPageDateRange = $true
$reopenOnBlank = $true
$bridgeRetryWaitMs = 20000
if ($null -ne $cfg.options.scrapeRetries) { $scrapeRetries = [int]$cfg.options.scrapeRetries }
if ($null -ne $cfg.options.scrapeRetryWaitMs) { $scrapeRetryWaitMs = [int]$cfg.options.scrapeRetryWaitMs }
if ($null -ne $cfg.options.waitAfterDateChangeMs) { $waitAfterDateChangeMs = [int]$cfg.options.waitAfterDateChangeMs }
if ($null -ne $cfg.options.setPageDateRange) { $setPageDateRange = [bool]$cfg.options.setPageDateRange }
if ($null -ne $cfg.options.reopenOnBlank) { $reopenOnBlank = [bool]$cfg.options.reopenOnBlank }
if ($null -ne $cfg.options.bridgeRetryWaitMs) { $bridgeRetryWaitMs = [int]$cfg.options.bridgeRetryWaitMs }
if ($scrapeRetries -lt 1) { $scrapeRetries = 1 }
$skipZeroDisabled = $true
if ($null -ne $cfg.options -and $null -ne $cfg.options.skipZeroDisabledCampaigns) {
  $skipZeroDisabled = [bool]$cfg.options.skipZeroDisabledCampaigns
}
Write-Step ("bizDate={0} dateMode={1} setPageDateRange={2} waitAfterDateChangeMs={3}" -f $bizDate, $dateMode, $setPageDateRange, $waitAfterDateChangeMs)
Write-Step ("dryRun={0} scrapeRetries={1} waitAfterVisitMs={2}" -f $useDryRun, $scrapeRetries, $cfg.options.waitAfterVisitMs)
Write-Step ("currency target={0} pageDefault={1} convert={2} (广告花费/销售额统一按美金)" -f $currencyCfg.target, $currencyCfg.pageDefault, $currencyCfg.convert)
Write-Step ("skipZeroDisabledCampaigns={0} (C: skip off+spend0+revenue0 only)" -f $skipZeroDisabled)
if (-not $useDryRun) {
  Write-Step "NOTE: Feishu write is APPEND — same bizDate re-run will create duplicate rows. Clean Feishu if you re-ran today."
}

function Get-FriendlyScrapeError($payload, [string]$fallback) {
  $url = ''
  if ($payload -and $payload.url) { $url = [string]$payload.url }
  if ($url -match 'settle/verification|verification') {
    return "店铺被重定向到核验/结算页，无法进广告面板: $url （请在卖家中心完成核验后重试）"
  }
  if ($url -match 'login|passport|signin') {
    return "页面疑似未登录/掉登录: $url"
  }
  $base = if ($fallback) { $fallback } else { 'scrape failed' }
  if ($url) { return "$base | url=$url" }
  return $base
}

$summary = @()
$allCampaignRows = @()
$scrapeOneLine = ConvertTo-ScrapeOneLine $scrapeJs
Write-Step ("scrape script one-line length={0}" -f $scrapeOneLine.Length)

function Get-DateRangeScriptOneLine([string]$action) {
  $js = $dateRangeJsTemplate.Replace('__DATE_MODE__', $dateMode).Replace('__ACTION__', $action)
  return (ConvertTo-ScrapeOneLine $js)
}

function Invoke-DateRangeAction([string]$storeId, [string]$action, [int]$timeoutMs = 20000) {
  $scriptLine = Get-DateRangeScriptOneLine $action
  $out = Invoke-Ziniao @(
    'page', 'exec',
    '--store-id', $storeId,
    '--script', $scriptLine,
    '--timeout', ([string]$timeoutMs)
  )
  Write-Host $out
  return (Get-DateRangePayload $out)
}

function Invoke-SetPageDateRange([string]$storeId) {
  if (-not $setPageDateRange) {
    Write-Step "  skip set page date range (options.setPageDateRange=false)"
    return $true
  }
  Write-Step ("  set page date range => {0} (open -> pick -> wait)..." -f $dateMode)

  try {
    # 1) 若已是目标区间则跳过
    $st = Invoke-DateRangeAction $storeId 'status' 15000
    if ($st -and $st.matched) {
      Write-Step ("  date range already {0}: {1} ~ {2}" -f $dateMode, $st.range.start, $st.range.end)
      return $true
    }
    if ($st -and $st.range) {
      Write-Step ("  current page range: {0} ~ {1}" -f $st.range.start, $st.range.end)
    }

    # 2) 打开日期面板
    $op = Invoke-DateRangeAction $storeId 'open' 20000
    if ($null -eq $op) {
      Write-Step "  WARN date open: unrecognized payload"
    } elseif (-not $op.ok -and -not $op.skipped) {
      Write-Step ("  WARN date open failed: {0}" -f $(if ($op.error) { $op.error } else { 'unknown' }))
    } else {
      Write-Step ("  date picker open panelOpen={0}" -f $op.panelOpen)
    }
    Start-Sleep -Milliseconds 600

    # 3) 点击「昨天/今天」
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

    # 4) 等表格按新日期重载，再校验显示区间
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
    Write-Step ("  WARN set date range failed: {0}" -f $_)
    return $false
  }
}

$analysisEnabled = $true
$lowRoi = 3.0
$writeSummaryFeishu = $true
if ($cfg.analysis) {
  if ($null -ne $cfg.analysis.enabled) { $analysisEnabled = [bool]$cfg.analysis.enabled }
  if ($null -ne $cfg.analysis.lowRoiThreshold) { $lowRoi = [double]$cfg.analysis.lowRoiThreshold }
  if ($null -ne $cfg.analysis.writeSummaryToFeishu) { $writeSummaryFeishu = [bool]$cfg.analysis.writeSummaryToFeishu }
}

foreach ($store in $selected) {
  $sid = $store.storeId
  $sname = $store.storeName
  $display = Get-DisplayName $store $cfg.storeNameMap
  $adsUrl = Get-AdsUrl $store $cfg.adsUrl
  $item = [ordered]@{
    storeId          = $sid
    storeName        = $sname
    displayName      = $display
    ok               = $false
    rows             = 0
    written          = 0
    qingquanAccepted = 0
    qingquanDup      = 0
    qingquanError    = $null
    error            = $null
  }

  Write-Step ("==== START {0} ({1}) => {2} ====" -f $sname, $sid, $display)
  $execOut = $null
  $payload = $null
  $debugSaved = $false
  $ingestFailed = $false
  $ingestErr = $null
  try {
    Write-Step "  open store..."
    # 默认尽量拉大窗口：--window-ratio full + Win32 最大化 + page resize（ziniao-window.ps1）
    $windowRatio = Get-ZiniaoWindowRatio $cfg
    $openArgs = New-ZiniaoStoreOpenArgs -StoreId $sid -Url $adsUrl -Config $cfg
    if ($windowRatio -and $windowRatio -ne 'default' -and $windowRatio -ne 'none') {
      Write-Step ("  open with --window-ratio {0}" -f $windowRatio)
    }
    Write-Host (Invoke-Ziniao $openArgs)
    Start-Sleep -Milliseconds ([int]$cfg.options.waitAfterOpenMs)

    $doMaximize = Test-ZiniaoMaximizeEnabled $cfg
    if ($doMaximize) {
      Write-Step "  maximize store window..."
      Invoke-ZiniaoStoreMaximize -StoreId $sid -InvokeZiniao ${function:Invoke-Ziniao} -WriteStep ${function:Write-Step} -Config $cfg | Out-Null
    }

    Write-Step "  visit ads page..."
    # visit may fail (Bridge glitch) while page still usable — soft-log and continue
    $visitOut = Invoke-Ziniao @('page', 'visit', '--store-id', $sid, '--url', $adsUrl, '--wait-until', 'networkidle', '--timeout', '90000')
    Write-Host $visitOut
    if ($visitOut -match '"ok"\s*:\s*false' -or $visitOut -match 'Bridge|无法连接|network') {
      Write-Step "  WARN page visit soft-failed; will still try scrape after wait"
    }
    if ($doMaximize) {
      Invoke-ZiniaoStoreMaximize -StoreId $sid -InvokeZiniao ${function:Invoke-Ziniao} -WriteStep ${function:Write-Step} -Config $cfg | Out-Null
    }
    Start-Sleep -Milliseconds ([int]$cfg.options.waitAfterVisitMs)

    # 面板默认常为「近 7 天」；先切到 dateMode（默认昨天）再抓表，否则 bizDate=昨天但数值是周汇总
    $null = Invoke-SetPageDateRange $sid

    $rawRows = @()
    $lastErr = $null
    for ($attempt = 1; $attempt -le $scrapeRetries; $attempt++) {
      Write-Step ("  page exec scrape (attempt {0}/{1})..." -f $attempt, $scrapeRetries)
      $execOut = Invoke-Ziniao @('page', 'exec', '--store-id', $sid, '--script', $scrapeOneLine, '--timeout', '60000')
      Write-Host $execOut

      $needReopen = $false
      $needBridgeWait = $false
      $payload = Get-ScrapePayload $execOut
      if (-not $payload) {
        # Bridge 断连时常返回 network 错误 JSON，而不是 scrape payload
        if ($execOut -match 'Bridge|无法连接|9481|ECONNREFUSED') {
          $lastErr = '紫鸟 Bridge 断开或不可达'
          $needBridgeWait = $true
          $needReopen = $true
        } else {
          $lastErr = 'scrape failed: empty payload'
        }
        Write-Step ("  attempt {0}: {1}" -f $attempt, $lastErr)
      } elseif (-not $payload.ok) {
        $lastErr = Get-FriendlyScrapeError $payload $(if ($payload.error) { [string]$payload.error } else { 'scrape failed (ok=false)' })
        $pageUrl = ''
        if ($payload.url) { $pageUrl = [string]$payload.url }
        # Hard fail: verification page won't fix by waiting
        if ($pageUrl -match 'settle/verification|verification') {
          break
        }
        # about:blank / 空白页：关店重开比单纯 re-visit 更有效
        if ($pageUrl -match 'about:blank' -or [string]::IsNullOrWhiteSpace($pageUrl)) {
          $needReopen = $true
        }
        Write-Step ("  attempt {0}: {1}" -f $attempt, $lastErr)
      } else {
        $rawRows = @()
        if ($null -ne $payload.rows) {
          if ($payload.rows -is [System.Array]) { $rawRows = @($payload.rows) }
          else { $rawRows = @($payload.rows) }
        }
        $rawRows = @($rawRows | Where-Object { $_ -and ($_.campaign -or $null -ne $_.spend -or $null -ne $_.revenue) })
        if ($rawRows.Count -gt 0) {
          $lastErr = $null
          break
        }
        # On ads dashboard but 0 data rows — likely still loading
        $lastErr = Get-FriendlyScrapeError $payload '广告页已打开但表格 0 行（可能仍在加载）'
        Write-Step ("  attempt {0}: {1}" -f $attempt, $lastErr)
      }

      if ($attempt -lt $scrapeRetries) {
        if ($needBridgeWait) {
          Write-Step ("  bridge wait {0}ms before reopen..." -f $bridgeRetryWaitMs)
          Start-Sleep -Milliseconds $bridgeRetryWaitMs
        } else {
          Write-Step ("  retry wait {0}ms..." -f $scrapeRetryWaitMs)
          Start-Sleep -Milliseconds $scrapeRetryWaitMs
        }

        if ($reopenOnBlank -and $needReopen) {
          Write-Step "  reopen store (blank/bridge recovery)..."
          try {
            $null = Invoke-Ziniao @('store', 'close', '--id', $sid)
          } catch {
            Write-Step ("  WARN store close: {0}" -f $_)
          }
          Start-Sleep -Milliseconds 3000
          $reopenArgs = New-ZiniaoStoreOpenArgs -StoreId $sid -Url $adsUrl -Config $cfg
          try {
            Write-Host (Invoke-Ziniao $reopenArgs)
          } catch {
            Write-Step ("  WARN store reopen: {0}" -f $_)
          }
          Start-Sleep -Milliseconds ([int]$cfg.options.waitAfterOpenMs)
          if ($doMaximize) {
            Invoke-ZiniaoStoreMaximize -StoreId $sid -InvokeZiniao ${function:Invoke-Ziniao} -WriteStep ${function:Write-Step} -Config $cfg | Out-Null
          }
        }

        Write-Step "  re-visit ads page..."
        $rv = Invoke-Ziniao @('page', 'visit', '--store-id', $sid, '--url', $adsUrl, '--wait-until', 'networkidle', '--timeout', '90000')
        if ($rv -match '"ok"\s*:\s*false' -or $rv -match 'Bridge|无法连接') {
          Write-Step "  WARN re-visit soft-failed; continue after wait"
        }
        Start-Sleep -Milliseconds ([Math]::Min([int]$cfg.options.waitAfterVisitMs, 20000))
        # 重访后页面日期会回到默认近 7 天，必须再切一次
        $null = Invoke-SetPageDateRange $sid
      }
    }

    if ($lastErr -or $rawRows.Count -eq 0) {
      $errMsg = if ($lastErr) { $lastErr } else { '广告表格 0 行' }
      $null = Save-ScrapeDebug -StoreId $sid -StoreName $sname -DisplayName $display -AdsUrl $adsUrl `
        -ExecOut $execOut -Payload $payload -ErrorMsg $errMsg
      $debugSaved = $true
      throw $errMsg
    }

    # 页面币种：抓取脚本检测符号；未识别时用 pageDefault（默认 USD，与广告后台一致）
    $pageCurrency = $currencyCfg.pageDefault
    if ($payload.currency) {
      $pageCurrency = ([string]$payload.currency).ToUpperInvariant()
    }
    $targetCurrency = $currencyCfg.target
    $needConvert = $currencyCfg.convert -and ($pageCurrency -ne $targetCurrency)
    if ($needConvert) {
      Write-Step ("  currency convert {0} -> {1} (ratesToUsd.{0}={2})" -f `
        $pageCurrency, $targetCurrency, $currencyCfg.ratesToUsd[$pageCurrency])
    } else {
      Write-Step ("  currency={0} (no convert; spend/revenue as {1})" -f $pageCurrency, $targetCurrency)
    }

    $rows = @()
    $skippedDisabled = 0
    foreach ($r in $rawRows) {
      $spendRaw = 0.0
      if ($null -ne $r.spend) { $spendRaw = [double]$r.spend }
      $revenueRaw = 0.0
      if ($null -ne $r.revenue) { $revenueRaw = [double]$r.revenue }
      $spendOut = $spendRaw
      $revenueOut = $revenueRaw
      if ($needConvert) {
        $spendOut = Convert-MoneyToTarget -Amount $spendRaw -FromCurrency $pageCurrency `
          -TargetCurrency $targetCurrency -RatesToUsd $currencyCfg.ratesToUsd
        $revenueOut = Convert-MoneyToTarget -Amount $revenueRaw -FromCurrency $pageCurrency `
          -TargetCurrency $targetCurrency -RatesToUsd $currencyCfg.ratesToUsd
      } else {
        $spendOut = [math]::Round($spendRaw, 2)
        $revenueOut = [math]::Round($revenueRaw, 2)
      }
      $planStatus = Normalize-PlanStatus $r.planStatus
      # P1 金额字段：与 spend/revenue 同币种换算规则
      $dailyBudgetOut = $null
      if ($null -ne $r.dailyBudget -and "$($r.dailyBudget)" -ne '') {
        $dbRaw = [double]$r.dailyBudget
        if ($needConvert) {
          $dailyBudgetOut = Convert-MoneyToTarget -Amount $dbRaw -FromCurrency $pageCurrency `
            -TargetCurrency $targetCurrency -RatesToUsd $currencyCfg.ratesToUsd
        } else { $dailyBudgetOut = [math]::Round($dbRaw, 2) }
      }
      $netCostOut = $null
      if ($null -ne $r.netCost -and "$($r.netCost)" -ne '') {
        $ncRaw = [double]$r.netCost
        if ($needConvert) {
          $netCostOut = Convert-MoneyToTarget -Amount $ncRaw -FromCurrency $pageCurrency `
            -TargetCurrency $targetCurrency -RatesToUsd $currencyCfg.ratesToUsd
        } else { $netCostOut = [math]::Round($ncRaw, 2) }
      }
      $avgOrderCostOut = $null
      if ($null -ne $r.avgOrderCost -and "$($r.avgOrderCost)" -ne '') {
        $cpaRaw = [double]$r.avgOrderCost
        if ($needConvert) {
          $avgOrderCostOut = Convert-MoneyToTarget -Amount $cpaRaw -FromCurrency $pageCurrency `
            -TargetCurrency $targetCurrency -RatesToUsd $currencyCfg.ratesToUsd
        } else { $avgOrderCostOut = [math]::Round($cpaRaw, 2) }
      }
      $targetRoiOut = $null
      if ($null -ne $r.targetRoi -and "$($r.targetRoi)" -ne '') { $targetRoiOut = [double]$r.targetRoi }
      $deliveryStatus = ''
      if ($r.deliveryStatus) { $deliveryStatus = [string]$r.deliveryStatus }

      $candidate = [pscustomobject]@{
        date            = $bizDate
        store           = $display
        storeId         = $sid
        campaign        = [string]$r.campaign
        spend           = $spendOut
        orders          = if ($null -ne $r.orders) { $r.orders } else { 0 }
        roi             = if ($null -ne $r.roi) { $r.roi } else { 0 }
        revenue         = $revenueOut
        dailyBudget     = $dailyBudgetOut
        targetRoi       = $targetRoiOut
        netCost         = $netCostOut
        avgOrderCost    = $avgOrderCostOut
        deliveryStatus  = $deliveryStatus
        currency        = $targetCurrency
        pageCurrency    = $pageCurrency
        sourceUrl       = [string]$payload.url
        status          = 'success'
        planStatus      = $planStatus
      }
      if ($skipZeroDisabled -and (Test-SkipZeroDisabledCampaign $candidate)) {
        $skippedDisabled++
        Write-Step ("  skip closed+zero: {0} (planStatus=off spend=0 revenue=0)" -f $candidate.campaign)
        continue
      }
      $rows += $candidate
    }
    if ($skippedDisabled -gt 0) {
      Write-Step ("  filtered {0} closed zero-metric campaign(s)" -f $skippedDisabled)
    }
    $item.rows = $rows.Count
    if ($rows.Count -gt 0) { $allCampaignRows += $rows }

    # --- Stage A: 旁路上报清泉中心 ---
    # 2026-08-20：ingest 失败不再静默吞掉。底层 Send-QingquanIngest 仍 failOpen（不抛异常、
    # 不阻断下方飞书写入），但此处检查 ok/failed：失败则该店标 not-ok + 记 error，
    # 使 summary 醒目、整批 exit 2（任务计划程序判定夜间任务失败，便于发现丢店）。
    $writeMode = 'direct'
    if (Get-Command Get-FeishuWriteMode -ErrorAction SilentlyContinue) {
      $writeMode = Get-FeishuWriteMode $cfg
    }
    $qingquanEnabled = $false
    if ($cfg.qingquan -and $null -ne $cfg.qingquan.enabled) { $qingquanEnabled = [bool]$cfg.qingquan.enabled }

    $ingestFailed = $false
    if ($qingquanEnabled -and (Get-Command Send-QingquanIngest -ErrorAction SilentlyContinue)) {
      if ($useDryRun) {
        Write-Step ("  qingquan dryRun: would report {0} rows (writeMode={1}, currency={2})" -f $rows.Count, $writeMode, $targetCurrency)
      } else {
        $collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00')
        $qqItems = ConvertTo-QingquanIngestItems -Rows $rows -CollectedAt $collectedAt -Currency $targetCurrency
        Write-Step ("  report Qingquan center ({0} items, writeMode={1}, currency={2})..." -f $qqItems.Count, $writeMode, $targetCurrency)
        $qq = Send-QingquanIngest -Config $cfg -Items $qqItems
        $item.qingquanAccepted = $qq.accepted
        $item.qingquanDup = $qq.duplicated
        if ($qq.error) { $item.qingquanError = [string]$qq.error }
        Write-Step ("  qingquan accepted={0} duplicated={1} failed={2} ok={3}" -f $qq.accepted, $qq.duplicated, $qq.failed, $qq.ok)
        # 关键：ingest 失败（curl 超时/网络/401）不能再当成功。failed>0 或 ok=false 即视为丢店。
        if (-not $qq.ok -or ([int]$qq.failed -gt 0)) {
          $ingestFailed = $true
          $ingestErr = if ($qq.error) { [string]$qq.error } else { ("ingest failed={0} accepted={1} (rows={2})" -f $qq.failed, $qq.accepted, $rows.Count) }
          Write-Step ("  INGEST FAIL: {0} — 该店数据未进 PG，标 not-ok + exit 2" -f $ingestErr)
        }
      }
    }

    # direct / dual → 写飞书；center → 仅中心（飞书由中心同步）
    # 飞书写入是独立路径，不被 ingest 失败拖累——即使 ingest 丢店，飞书日报仍写（便于回填对照）。
    $shouldWriteFeishu = ($writeMode -ne 'center')
    if ($shouldWriteFeishu) {
      Write-Step ("  scraped {0} rows (source={1}), write Feishu..." -f $rows.Count, $payload.source)
      $w = Write-FeishuRows $cfg.feishu $rows $useDryRun
      $item.written = $w.written
      Write-Step ("  done written={0}" -f $w.written)
    } else {
      Write-Step ("  scraped {0} rows (source={1}), skip Feishu direct write (writeMode=center)" -f $rows.Count, $payload.source)
      $item.written = 0
    }
    # ok 仅当飞书/ingest 都成功；ingest 失败（丢店）即使飞书写了也标 not-ok，触发 exit 2
    if ($ingestFailed) {
      $item.ok = $false
      $item.error = $ingestErr
    } else {
      $item.ok = $true
    }
    $null = Save-ScrapeDebug -StoreId $sid -StoreName $sname -DisplayName $display -AdsUrl $adsUrl `
      -ExecOut $execOut -Payload $payload -ErrorMsg $null -AsLast
    $debugSaved = $true
  }
  catch {
    $item.error = [string]$_
    Write-Step ("  FAIL: {0}" -f $_)
    if (-not $debugSaved) {
      try {
        $null = Save-ScrapeDebug -StoreId $sid -StoreName $sname -DisplayName $display -AdsUrl $adsUrl `
          -ExecOut $execOut -Payload $payload -ErrorMsg ([string]$_)
      } catch {
        Write-Step ("  debug save failed: {0}" -f $_)
      }
    }
  }
  finally {
    if ($cfg.options.closeAfter) {
      try {
        Write-Step "  close store..."
        $null = Invoke-Ziniao @('store', 'close', '--id', $sid)
      } catch { }
    }
    Start-Sleep -Milliseconds ([int]$cfg.options.delayBetweenStoresMs)
  }
  $summary += [pscustomobject]$item
}

Write-Step "======== SUMMARY ========"
$summary | Format-Table storeName, displayName, ok, rows, written, qingquanAccepted, qingquanDup, error -AutoSize
$okCount = @($summary | Where-Object { $_.ok }).Count
Write-Step ("OK {0} / {1}" -f $okCount, $summary.Count)
$qqFail = @($summary | Where-Object { $_.qingquanError }).Count
if ($qqFail -gt 0) {
  # 2026-08-20：ingest 失败现已标 not-ok（不再 failOpen 静默）。列出丢店，便于定位回填。
  Write-Step ("INGEST FAIL on {0} store(s) — 数据未进 PG，需从飞书日报回填:" -f $qqFail)
  foreach ($s in @($summary | Where-Object { $_.qingquanError })) {
    Write-Step ("  - {0}: {1}" -f $s.displayName, $s.qingquanError)
  }
}
$outPath = Join-Path $script:logsDir ("multi-store-{0}.json" -f $script:runStamp)
New-Item -ItemType Directory -Force -Path $script:logsDir | Out-Null
$summary | ConvertTo-Json -Depth 6 | Set-Content $outPath -Encoding UTF8
Write-Step ("log: {0}" -f $outPath)
Write-Step ("run log: {0}" -f $script:runLogFile)
Write-Step ("===== multi-store END OK {0}/{1} =====" -f $okCount, $summary.Count)

# --- daily analysis (saved under 日报/ for easy browsing; logs/ keeps scrape debug only) ---
if ($analysisEnabled -and (Get-Command Build-DailyAnalysis -ErrorAction SilentlyContinue)) {
  try {
    Write-Step "build daily analysis..."
    $analysis = Build-DailyAnalysis -CampaignRows $allCampaignRows -RunSummary $summary -BizDate $bizDate -LowRoiThreshold $lowRoi
    $reportDir = Join-Path $root '日报'
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $mdPath = Join-Path $reportDir ("日报-{0}.md" -f $bizDate)
    $analysis.markdown | Set-Content -Path $mdPath -Encoding UTF8
    $briefPath = Join-Path $reportDir ("简报-{0}.txt" -f $bizDate)
    $analysis.briefText | Set-Content -Path $briefPath -Encoding UTF8
    $analysisJson = Join-Path $reportDir ("日报-{0}.json" -f $bizDate)
    [pscustomobject]@{
      bizDate        = $analysis.bizDate
      totalSpend     = $analysis.totalSpend
      totalOrders    = $analysis.totalOrders
      totalRevenue   = $analysis.totalRevenue
      totalCampaigns = $analysis.totalCampaigns
      overallRoi     = $analysis.overallRoi
      highlights     = $analysis.highlights
      risks          = $analysis.risks
      storeRollups   = $analysis.storeRollups
    } | ConvertTo-Json -Depth 6 | Set-Content $analysisJson -Encoding UTF8
    # One-click latest aliases
    Copy-Item -LiteralPath $mdPath -Destination (Join-Path $reportDir '最新日报.md') -Force
    Copy-Item -LiteralPath $briefPath -Destination (Join-Path $reportDir '最新简报.txt') -Force
    Write-Step ("日报目录: {0}" -f $reportDir)
    Write-Step ("analysis md: {0}" -f $mdPath)
    Write-Host ""
    Write-Host $analysis.briefText
    Write-Host ""
    if ($analysis.storeRollups.Count -gt 0) {
      $analysis.storeRollups | Format-Table store, campaigns, spend, orders, revenue, roi, topCampaign -AutoSize
    }

    if ($writeSummaryFeishu) {
      $sumRows = New-SummaryFeishuRows -Analysis $analysis -BizDate $bizDate
      Write-Step ("write summary rows to Feishu: {0}" -f $sumRows.Count)
      $sw = Write-FeishuRows $cfg.feishu $sumRows $useDryRun
      Write-Step ("summary written={0} dryRun={1}" -f $sw.written, $sw.dryRun)
    }
  }
  catch {
    Write-Step ("analysis FAILED (non-fatal): {0}" -f $_)
  }
}

if ($okCount -lt $summary.Count) { exit 2 }
