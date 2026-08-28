# TikTok content analysis POC (经营计划 P2.0) — 视频概览 + 商品卡
# 默认只写 logs/*-debug-*.json，不上报中心 fact（门禁前不建表）。
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-content-poc.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-content-poc.ps1 -ConfigPath .\config\stores.config.deal-only.json
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-content-poc.ps1 -Modules content_overview,product_traffic -ListOnly
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-content-poc.ps1 -Modules content_probe
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-content-poc.ps1 -Modules video_list
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-content-poc.ps1 -SkipIngest:$false
#
# Requires: Ziniao + Bridge. URLs: config.contentUrl / productTrafficUrl / videoListUrl.

param(
  [string]$ConfigPath = "",
  [switch]$ListOnly,
  [string]$DryRun = "",
  [string]$DateMode = "",
  [string]$Modules = "content_overview,product_traffic",
  [string]$SkipIngest = "true"
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\stores.config.json' }
if (-not (Test-Path $ConfigPath)) { throw "Missing config: $ConfigPath" }

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$qingquanLib = Join-Path $PSScriptRoot 'qingquan-client.ps1'
if (Test-Path $qingquanLib) { . $qingquanLib }
$ziniaoWinLib = Join-Path $PSScriptRoot 'ziniao-window.ps1'
if (-not (Test-Path $ziniaoWinLib)) { throw "Missing $ziniaoWinLib" }
. $ziniaoWinLib

$script:logsDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $script:logsDir | Out-Null
$script:runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:runLogFile = Join-Path $script:logsDir ("content-poc-run-{0}.log" -f $script:runStamp)

function Write-RunLog([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -LiteralPath $script:runLogFile -Value $line -Encoding UTF8 } catch { }
}
function Write-Step([string]$msg) {
  Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg)
  Write-RunLog $msg
}

function Write-Utf8File([string]$Path, [string]$Content) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "Write-Utf8File: Path is empty" }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $text = if ($null -eq $Content) { '' } else { [string]$Content }
  [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
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
  return (($js -replace '(?m)^\s*//.*$', '' -replace '\r?\n', ' ' -replace '\s+', ' ').Trim())
}
function Get-ScrapePayload([string]$execOut) {
  if ([string]::IsNullOrWhiteSpace($execOut)) { return $null }
  try {
    $j = $execOut | ConvertFrom-Json
    if ($j.data -and $j.data.data -and $j.data.data.result) {
      return ([string]$j.data.data.result | ConvertFrom-Json)
    }
    if ($null -ne $j.ok) { return $j }
  } catch { }
  $m = [regex]::Matches($execOut, '\{(?:[^{}]|(?<o>\{)|(?<-o>\}))+(?(o)(?!))\}')
  if ($m.Count -gt 0) {
    try { return ($m[$m.Count - 1].Value | ConvertFrom-Json) } catch { }
  }
  return $null
}
function Convert-DryRunFlag([string]$raw) {
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  switch -Regex ($raw.Trim()) {
    '^(?i:true|1|yes|y|\$true)$'  { return $true }
    '^(?i:false|0|no|n|\$false)$' { return $false }
    default { throw "Invalid -DryRun '$raw'" }
  }
}
function Get-DisplayName($store, $map) {
  $n = [string]$store.storeName
  if ($map -and $map.PSObject.Properties.Name -contains $n) { return [string]$map.$n }
  return $n
}
function Test-BridgeAlive {
  try {
    $null = Invoke-WebRequest -Uri 'http://127.0.0.1:9481' -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
    return $true
  } catch {
    # Bridge often returns 401 without auth — still means process is up
    $msg = [string]$_.Exception.Message
    if ($msg -match '401|403|Unauthorized|Forbidden') { return $true }
    return $false
  }
}

function Invoke-EnsurePageReady {
  param(
    [string]$StoreId,
    [string]$TargetUrl,
    [string]$UrlCheckOneLiner,
    [int]$MaxTries = 3
  )
  for ($t = 1; $t -le $MaxTries; $t++) {
    if (-not (Test-BridgeAlive)) {
      Write-Step ("  bridge down try {0}/{1}, wait 15s..." -f $t, $MaxTries)
      Start-Sleep -Seconds 15
      if (-not (Test-BridgeAlive)) {
        if ($t -eq $MaxTries) { return @{ ok = $false; error = 'bridge unreachable' } }
        continue
      }
    }
    try {
      $null = Invoke-Ziniao @('page', 'visit', '--store-id', $StoreId, '--url', $TargetUrl, '--wait-until', 'load', '--timeout', '120000')
    } catch {
      Write-Step ("  visit error try {0}: {1}" -f $t, $_)
      Start-Sleep -Seconds 8
      continue
    }
    Start-Sleep -Seconds 8
    $chkOut = ''
    try {
      $chkOut = Invoke-Ziniao @('page', 'exec', '--store-id', $StoreId, '--script', $UrlCheckOneLiner, '--timeout', '30000')
    } catch {
      Write-Step ("  url-check exec fail try {0}: {1}" -f $t, $_)
      Start-Sleep -Seconds 10
      continue
    }
    $chk = Get-ScrapePayload $chkOut
    $href = ''
    if ($chk -and $chk.href) { $href = [string]$chk.href }
    $blank = $false
    if ($chk -and $chk.blank) { $blank = [bool]$chk.blank }
    if (-not $href -or $href -match 'about:blank' -or $blank) {
      Write-Step ("  page not ready try {0}/{1}: href={2}" -f $t, $MaxTries, $href)
      Start-Sleep -Seconds 12
      continue
    }
    # Wrong landing: content-analysis/* or video-analytics/overview often bounce to data-overview
    if ($href -match 'data-overview' -and $TargetUrl -notmatch 'data-overview') {
      Write-Step ("  landed data-overview (want {0}), retry visit..." -f $TargetUrl)
      Start-Sleep -Seconds 5
      continue
    }
    $bodyLen = 0
    if ($chk -and $chk.bodyLen) { $bodyLen = [int]$chk.bodyLen }
    # video-details SPA: shell chrome ~200-400 chars until table hydrates (2026-08-05 deep POC)
    if ($TargetUrl -match 'video-details|video-analytics/detail' -and $bodyLen -gt 0 -and $bodyLen -lt 800) {
      Write-Step ("  video-details shell only bodyLen={0}, wait hydrate try {1}/{2}..." -f $bodyLen, $t, $MaxTries)
      Start-Sleep -Seconds 28
      $chk2Out = ''
      try {
        $chk2Out = Invoke-Ziniao @('page', 'exec', '--store-id', $StoreId, '--script', $UrlCheckOneLiner, '--timeout', '30000')
      } catch { }
      $chk2 = Get-ScrapePayload $chk2Out
      if ($chk2 -and $chk2.bodyLen) { $bodyLen = [int]$chk2.bodyLen }
      if ($chk2 -and $chk2.href) { $href = [string]$chk2.href }
      if ($bodyLen -lt 800 -and $t -lt $MaxTries) { continue }
    }
    return @{ ok = $true; href = $href; bodyLen = $bodyLen }
  }
  return @{ ok = $false; error = 'page not ready after retries' }
}

function Get-ModuleUrl($store, $cfg, $moduleKey) {
  $plat = ''
  if ($store.platformName) { $plat = [string]$store.platformName }
  elseif ($store.platform) { $plat = [string]$store.platform }
  $mapKey = switch ($moduleKey) {
    'content_overview' { 'contentUrl' }
    'product_traffic' { 'productTrafficUrl' }
    'video_list' { 'videoListUrl' }
    'content_probe' { 'contentUrl' }
    'content_nav_discover' { 'contentNavStartUrl' }
    default { $null }
  }
  # 2026-08-04 实勘默认（Deal UK）；content-analysis/* 会回 data-overview
  # video_list: 视频详情候选 path（P2.1b）；以实跑矩阵为准
  $defaults = @{
    content_overview     = 'https://seller-uk.tiktok.com/compass/video-analytics?shop_region=GB'
    product_traffic      = 'https://seller-uk.tiktok.com/compass/product-card-analytics?shop_region=GB'
    # 2026-08-05 实勘：真 path 是 video-details（复数）；detail 单数会回 data-overview
    video_list           = 'https://seller-uk.tiktok.com/compass/video-analytics/video-details?shop_region=GB'
    content_probe        = 'https://seller-uk.tiktok.com/compass/video-analytics?shop_region=GB'
    content_nav_discover = 'https://seller-uk.tiktok.com/homepage'
  }
  if ($mapKey -and $cfg.$mapKey) {
    $block = $cfg.$mapKey
    if ($block.byPlatform -and $plat) {
      foreach ($p in $block.byPlatform.PSObject.Properties) {
        if ($plat -eq [string]$p.Name -or $plat -like ("*{0}*" -f $p.Name)) { return [string]$p.Value }
      }
    }
    if ($block.default) { return [string]$block.default }
  }
  if ($cfg.urls -and $cfg.urls.$moduleKey) { return [string]$cfg.urls.$moduleKey }
  if ($moduleKey -eq 'content_nav_discover') {
    # 从首页或 data-overview 扫导航，比猜 content-analysis path 稳
    if ($cfg.shopDailyUrl -and $cfg.shopDailyUrl.default) { return [string]$cfg.shopDailyUrl.default }
    return 'https://seller-uk.tiktok.com/homepage'
  }
  return [string]$defaults[$moduleKey]
}

$modList = @($Modules.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$scriptMap = @{
  content_overview     = (Join-Path $root 'scripts\scrape-content-overview-page.js')
  product_traffic      = (Join-Path $root 'scripts\scrape-product-traffic-page.js')
  video_list           = (Join-Path $root 'scripts\scrape-video-list-page.js')
  content_probe        = (Join-Path $root 'scripts\_probe-content-page.js')
  content_nav_discover = (Join-Path $root 'scripts\_discover-content-nav.js')
}
$urlCheckScript = Join-Path $root 'scripts\_check-page-url.js'
if (-not (Test-Path $urlCheckScript)) { throw "Missing url check script: $urlCheckScript" }
foreach ($m in $modList) {
  if (-not $scriptMap.ContainsKey($m)) { throw "Unknown module: $m (use content_overview,product_traffic,video_list,content_probe,content_nav_discover)" }
  if (-not (Test-Path $scriptMap[$m])) { throw "Missing scrape script: $($scriptMap[$m])" }
}

$skipParsed = Convert-DryRunFlag $SkipIngest
$useSkipIngest = if ($null -ne $skipParsed) { [bool]$skipParsed } else { $true }

Write-Step '===== content-poc multi-store START (P2.0 gate) ====='
Write-Step ("config={0} modules={1} SkipIngest={2}" -f $ConfigPath, ($modList -join ','), $useSkipIngest)
Write-Step 'NOTE: POC does not create PG fact tables. Debug JSON only unless you opt into raw dump.'
Initialize-ZiniaoCli
$listOut = Invoke-Ziniao @('store', 'list')
$storesObj = $listOut | ConvertFrom-Json
$all = @()
if ($storesObj.data) {
  if ($storesObj.data.items) { $all = @($storesObj.data.items) }
  elseif ($storesObj.data -is [System.Array]) { $all = @($storesObj.data) }
  elseif ($storesObj.data.list) { $all = @($storesObj.data.list) }
  elseif ($storesObj.data.stores) { $all = @($storesObj.data.stores) }
}
$norm = @()
foreach ($s in $all) {
  $sid = ''; if ($s.storeId) { $sid = [string]$s.storeId } elseif ($s.id) { $sid = [string]$s.id }
  $sname = ''; if ($s.storeName) { $sname = [string]$s.storeName } elseif ($s.name) { $sname = [string]$s.name }
  $plat = ''; if ($s.platformName) { $plat = [string]$s.platformName } elseif ($s.platform) { $plat = [string]$s.platform }
  if (-not $sid) { continue }
  $norm += [pscustomobject]@{
    storeId = $sid; storeName = $sname; platform = $plat; platformName = $plat
    ip = $(if ($s.ip) { [string]$s.ip } else { '' })
  }
}
$selected = @($norm)
if ($cfg.filter) {
  if ($cfg.filter.platformContains -and @($cfg.filter.platformContains).Count -gt 0) {
    $selected = @($selected | Where-Object {
      $p = $_.platform; $ok = $false
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

# 与 shop-modules 相同：读取 opsExclude*（配置已清空，三店全跑）
if ($cfg.modules) {
  $oex = @()
  if ($cfg.modules.opsExcludeStoreIds) { $oex += @($cfg.modules.opsExcludeStoreIds | ForEach-Object { [string]$_ }) }
  if ($cfg.modules.ordersExcludeStoreIds) { $oex += @($cfg.modules.ordersExcludeStoreIds | ForEach-Object { [string]$_ }) }
  $oex = @($oex | Select-Object -Unique | Where-Object { $_ })
  if ($oex.Count -gt 0) {
    $before = $selected.Count
    $selected = @($selected | Where-Object { $oex -notcontains $_.storeId })
    if ($before -ne $selected.Count) {
      Write-Step ("opsExcludeStoreIds removed {0} store(s)" -f ($before - $selected.Count))
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
foreach ($s in $selected) { Write-Step ("  - {0} | {1} | {2}" -f $s.storeId, $s.storeName, $s.platform) }
if ($ListOnly) { Write-Step 'ListOnly done'; return }
if ($selected.Count -eq 0) { throw 'No stores matched' }

$dryParsed = Convert-DryRunFlag $DryRun
$useDryRun = if ($null -ne $dryParsed) { [bool]$dryParsed } else {
  if ($cfg.options -and $null -ne $cfg.options.dryRun) { [bool]$cfg.options.dryRun } else { $true }
}
$waitOpen = 28000; $waitVisit = 35000; $retries = 3
if ($cfg.options.waitAfterOpenMs) { $waitOpen = [Math]::Max(15000, [int]$cfg.options.waitAfterOpenMs) }
if ($cfg.options.waitAfterVisitMs) { $waitVisit = [Math]::Max(15000, [int]$cfg.options.waitAfterVisitMs) }
if ($cfg.options.scrapeRetries) { $retries = [Math]::Max(2, [int]$cfg.options.scrapeRetries) }

$effectiveDateMode = 'yesterday'
if (-not [string]::IsNullOrWhiteSpace($DateMode)) {
  $effectiveDateMode = $DateMode.Trim().ToLowerInvariant()
} elseif ($cfg.options -and $cfg.options.dateMode) {
  $effectiveDateMode = [string]$cfg.options.dateMode
}
if ($effectiveDateMode -notin @('today', 'yesterday')) {
  throw "Invalid dateMode '$effectiveDateMode' (use today|yesterday)"
}
$bizDate = if ($effectiveDateMode -eq 'today') {
  (Get-Date).Date.ToString('yyyy-MM-dd')
} else {
  (Get-Date).Date.AddDays(-1).ToString('yyyy-MM-dd')
}
Write-Step ("dryRun={0} dateMode={1} biz_date={2} (content page window may still be 近N天 — see payload.window)" -f $useDryRun, $effectiveDateMode, $bizDate)

$oneLiners = @{}
foreach ($m in $modList) {
  $oneLiners[$m] = ConvertTo-ScrapeOneLine (Get-Content $scriptMap[$m] -Raw -Encoding UTF8)
}
$urlCheckOneLiner = ConvertTo-ScrapeOneLine (Get-Content $urlCheckScript -Raw -Encoding UTF8)

$summary = @()
foreach ($store in $selected) {
  $sid = $store.storeId
  $sname = $store.storeName
  $display = Get-DisplayName $store $cfg.storeNameMap
  Write-Step ("==== STORE {0} ({1}) => {2} ====" -f $sname, $sid, $display)

  $firstUrl = Get-ModuleUrl $store $cfg $modList[0]
  try {
    if (-not (Test-BridgeAlive)) {
      Write-Step '  bridge not up yet, wait 20s...'
      Start-Sleep -Seconds 20
    }
    Write-Step '  open store...'
    $openArgs = New-ZiniaoStoreOpenArgs -StoreId $sid -Url $firstUrl -Config $cfg
    Write-Host (Invoke-Ziniao $openArgs)
    Start-Sleep -Milliseconds $waitOpen
    Invoke-ZiniaoStoreMaximize -StoreId $sid -InvokeZiniao ${function:Invoke-Ziniao} -WriteStep ${function:Write-Step} -Config $cfg | Out-Null

    foreach ($mod in $modList) {
      $item = [ordered]@{
        storeId = $sid; storeName = $sname; displayName = $display; module = $mod
        ok = $false; url = $null; error = $null; debugPath = $null
        contentIdCount = $null
      }
      $modUrl = Get-ModuleUrl $store $cfg $mod
      $item.url = $modUrl
      Write-Step ("  -- module {0} url={1}" -f $mod, $modUrl)
      try {
        $ready = Invoke-EnsurePageReady -StoreId $sid -TargetUrl $modUrl -UrlCheckOneLiner $urlCheckOneLiner -MaxTries 3
        if (-not $ready.ok) {
          throw ("page gate failed: {0}" -f $ready.error)
        }
        Write-Step ("  page ready href={0} bodyLen={1}" -f $ready.href, $ready.bodyLen)
        # visit 后再拉一次最大化（开店瞬间窗口有时还没出来）
        Invoke-ZiniaoStoreMaximize -StoreId $sid -InvokeZiniao ${function:Invoke-Ziniao} -WriteStep ${function:Write-Step} -Config $cfg | Out-Null
        # content SPA often slower than homepage
        $extraWait = [Math]::Max(25000, [Math]::Min($waitVisit, 45000))
        Start-Sleep -Milliseconds $extraWait
        $payload = $null
        $lastErr = $null
        for ($attempt = 1; $attempt -le $retries; $attempt++) {
          if (-not (Test-BridgeAlive)) {
            $lastErr = 'bridge unreachable mid-scrape'
            Write-Step ("  {0}, wait 15s..." -f $lastErr)
            Start-Sleep -Seconds 15
            if ($attempt -lt $retries) {
              $null = Invoke-EnsurePageReady -StoreId $sid -TargetUrl $modUrl -UrlCheckOneLiner $urlCheckOneLiner -MaxTries 2
              continue
            }
            break
          }
          Write-Step ("  scrape {0} attempt {1}/{2}..." -f $mod, $attempt, $retries)
          $execOut = Invoke-Ziniao @('page', 'exec', '--store-id', $sid, '--script', $oneLiners[$mod], '--timeout', '60000')
          if ([string]::IsNullOrWhiteSpace($execOut)) {
            $lastErr = 'empty page exec'
          } else {
            $payload = Get-ScrapePayload $execOut
            $payloadUrl = ''
            if ($payload -and $payload.url) { $payloadUrl = [string]$payload.url }
            # store reuse / Bridge 抖动时偶发 about:blank，强制 revisit
            if ($payloadUrl -match 'about:blank' -or ($payload -and $payload.error -match 'about:blank')) {
              $lastErr = 'page is about:blank — revisit'
              $payload = $null
            } elseif ($payload -and $payload.ok) {
              $lastErr = $null
              break
            } else {
              $lastErr = $null
              if ($payload -and $payload.error) { $lastErr = [string]$payload.error }
              else { $lastErr = 'scrape fail' }
            }
            try {
              $rawPath = Join-Path $script:logsDir ("{0}-exec-raw-{1}-a{2}.txt" -f $mod, $sid, $attempt)
              Write-Utf8File -Path $rawPath -Content ([string]$execOut)
            } catch { Write-Step ("  warn write exec-raw: {0}" -f $_) }
          }
          Write-Step ("  attempt fail: {0}" -f $lastErr)
          if ($attempt -lt $retries) {
            Start-Sleep -Seconds 12
            # 2026-08-21：导航跑偏防护（对齐 run-shop-modules.ps1 的 creator_health 模式）。
            # scrape-product-traffic-page.js 对落错页（order/detail、compass/shop-tab 商城概览）
            # 返回 wrong_page_not_product_traffic；此类错误光等 SPA 无用，必须重新 visit 目标 URL
            # 把页面拉回 product-card-analytics，并比普通重试多等 SPA 渲染。否则会在错页正文里
            # “凑”出假 KPI（订单号被误抓成 orders、概览卡 customers=16）静默入库空数据。
            if ($lastErr -match 'wrong_page') {
              Write-Step '  wrong page — re-visit target URL + extra SPA wait'
              $null = Invoke-Ziniao @('page', 'visit', '--store-id', $sid, '--url', $modUrl, '--wait-until', 'load', '--timeout', '120000')
              Start-Sleep -Seconds 25
            } elseif ($lastErr -match 'about:blank|bridge') {
              Write-Step '  re-gate page after blank/bridge'
              $null = Invoke-EnsurePageReady -StoreId $sid -TargetUrl $modUrl -UrlCheckOneLiner $urlCheckOneLiner -MaxTries 2
              Start-Sleep -Seconds 20
            } elseif ($lastErr -match 'SPA not ready|not ready|no content|no product|no video') {
              Write-Step '  extra 30s for content SPA render'
              Start-Sleep -Seconds 30
            } else {
              $null = Invoke-EnsurePageReady -StoreId $sid -TargetUrl $modUrl -UrlCheckOneLiner $urlCheckOneLiner -MaxTries 2
              Start-Sleep -Seconds 15
            }
          }
        }

        # 即使 ok=false 也落 debug，便于改 URL/选择器
        $dbg = Join-Path $script:logsDir ("{0}-debug-{1}-{2}.json" -f $mod, $sid, $script:runStamp)
        $dbgObj = @{
          storeId = $sid
          displayName = $display
          url = $modUrl
          bizDate = $bizDate
          module = $mod
          scrapeOk = [bool]($payload -and $payload.ok)
          payload = $payload
          lastError = $lastErr
        }
        try {
          $json = $dbgObj | ConvertTo-Json -Depth 12 -Compress:$false
          Write-Utf8File -Path $dbg -Content $json
          $item.debugPath = $dbg
          Write-Step ("  debug: {0}" -f $dbg)
        } catch {
          Write-Step ("  warn write debug: {0}" -f $_)
        }

        if ($lastErr -or -not $payload -or -not $payload.ok) {
          if ($lastErr) { throw $lastErr }
          throw 'no payload'
        }

        if ($payload -and $null -ne $payload.contentIdCount) {
          $item.contentIdCount = [int]$payload.contentIdCount
          Write-Step ("  contentIdCount={0}" -f $item.contentIdCount)
        } elseif ($payload -and $payload.videos) {
          $cidN = @($payload.videos | Where-Object { $_.contentId -or $_.content_id }).Count
          $item.contentIdCount = $cidN
          Write-Step ("  contentIdCount={0}" -f $cidN)
        }

        if (-not $useSkipIngest) {
          if ($mod -eq 'product_traffic' -and (Get-Command Send-QingquanIngest -ErrorAction SilentlyContinue) -and $cfg.qingquan -and $cfg.qingquan.enabled) {
            $collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00')
            $qqItems = ConvertTo-QingquanProductTrafficIngestItems -Payload $payload -CollectedAt $collectedAt `
              -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $modUrl
            $qqN = @($qqItems).Count
            if ($qqN -le 0) {
              Write-Step '  qingquan: no product_traffic rows to report (empty products[])'
            } elseif ($useDryRun) {
              Write-Step ("  qingquan dryRun: would report tiktok_product_traffic x{0}" -f $qqN)
            } else {
              $qq = Send-QingquanIngest -Config $cfg -Items $qqItems -Source 'tiktok_product_traffic'
              Write-Step ("  qingquan product_traffic accepted={0} dup={1} ok={2}" -f $qq.accepted, $qq.duplicated, $qq.ok)
              if ($qq.error) { $item.error = [string]$qq.error }
            }
          } elseif ($mod -eq 'video_list' -and (Get-Command Send-QingquanIngest -ErrorAction SilentlyContinue) -and $cfg.qingquan -and $cfg.qingquan.enabled) {
            $collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00')
            $qqItems = ConvertTo-QingquanContentIngestItems -Payload $payload -CollectedAt $collectedAt `
              -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $modUrl
            $qqN = @($qqItems).Count
            if ($qqN -le 0) {
              Write-Step '  qingquan: no content rows to report (empty videos[] / no content_id)'
            } elseif ($useDryRun) {
              Write-Step ("  qingquan dryRun: would report tiktok_content x{0}" -f $qqN)
            } else {
              $qq = Send-QingquanIngest -Config $cfg -Items $qqItems -Source 'tiktok_content'
              Write-Step ("  qingquan content accepted={0} dup={1} ok={2}" -f $qq.accepted, $qq.duplicated, $qq.ok)
              if ($qq.error) { $item.error = [string]$qq.error }
            }
          } elseif ($mod -eq 'content_overview') {
            Write-Step '  skip content_overview ingest (store-level KPI only; row fact is video_list → tiktok_content)'
          } else {
            Write-Step ("  skip qingquan for module {0}" -f $mod)
          }
        } else {
          Write-Step '  skip qingquan (POC default SkipIngest)'
        }
        $item.ok = $true
      } catch {
        $item.error = [string]$_
        Write-Step ("  FAIL {0}: {1}" -f $mod, $item.error)
      }
      $summary += [pscustomobject]$item
    }
  } catch {
    Write-Step ("  STORE FAIL {0}: {1}" -f $sname, $_)
  } finally {
    if ($cfg.options -and $null -ne $cfg.options.closeAfter -and -not [bool]$cfg.options.closeAfter) {
      Write-Step '  leave store open'
    } else {
      try { $null = Invoke-Ziniao @('store', 'close', '--id', $sid) } catch { }
    }
  }
  if ($cfg.options.delayBetweenStoresMs) { Start-Sleep -Milliseconds ([int]$cfg.options.delayBetweenStoresMs) }
}

Write-Step '======== CONTENT-POC SUMMARY ========'
$summary | Format-Table storeName, module, ok, contentIdCount, error -AutoSize
$okN = @($summary | Where-Object { $_.ok }).Count
Write-Step ("OK {0}/{1}" -f $okN, $summary.Count)
$sumPath = Join-Path $script:logsDir ("content-poc-summary-{0}.json" -f $script:runStamp)
Write-Utf8File -Path $sumPath -Content (($summary | ConvertTo-Json -Depth 6))
Write-Step ("summary: {0}" -f $sumPath)
Write-Step 'Next: fill docs/TK-P2-内容分析POC结论.md from debug JSON; do NOT create empty fact tables until gate passes.'
Write-Step '===== content-poc multi-store END ====='
