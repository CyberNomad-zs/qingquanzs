# TikTok shop KPI / health / finance multi-store scrape (P2c + P3)
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules.ps1 -Modules shop_daily,health_daily
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules.ps1 -Modules violation,reviews
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules.ps1 -DryRun true -ListOnly
# Daily full-store (Task Scheduler):
#   install-shop-modules-daily-task.ps1  ->  run-shop-modules-daily.ps1  (main stores.config.json)
#
# Requires: Ziniao + Bridge; default config\stores.config.json (full-store filter; empty includeStoreIds)
# Ingest only (no Feishu). URLs: shopDailyUrl / healthUrl / experienceUrl / financeUrl /
#   violationUrl / productReviewsUrl / creatorHealthUrl
# creator_health: list accounts → switch each → scrape score/violations (per-account).

param(
  [string]$ConfigPath = "",
  [switch]$ListOnly,
  [string]$DryRun = "",
  [string]$DateMode = "",
  [string]$Modules = "shop_daily,health_daily,experience_daily,finance_daily,violation,reviews,creator_health"
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
$script:runLogFile = Join-Path $script:logsDir ("shop-modules-run-{0}.log" -f $script:runStamp)

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
function Get-ModuleUrl($store, $cfg, $moduleKey) {
  $plat = ''
  if ($store.platformName) { $plat = [string]$store.platformName }
  elseif ($store.platform) { $plat = [string]$store.platform }
  $mapKey = switch ($moduleKey) {
    'shop_daily' { 'shopDailyUrl' }
    'health_daily' { 'healthUrl' }
    'experience_daily' { 'experienceUrl' }
    'finance_daily' { 'financeUrl' }
    'violation' { 'violationUrl' }
    'reviews' { 'productReviewsUrl' }
    'creator_health' { 'creatorHealthUrl' }
    default { $null }
  }
  $defaults = @{
    # compass/data-overview 常停在 Key metrics 占位；首页卡片稳定有 GMV/订单/客户
    shop_daily    = 'https://seller-uk.tiktok.com/homepage'
    health_daily  = 'https://seller-uk.tiktok.com/health-center'
    experience_daily = 'https://seller-uk.tiktok.com/health-center/experience-score'
    finance_daily = 'https://seller-uk.tiktok.com/finance/bills'
    # 违规记录在账号健康中心 tab；scrape 内会点「违规记录」
    violation     = 'https://seller-uk.tiktok.com/health-center'
    # 商品评分（实页路径因站而异，config.productReviewsUrl 可覆盖）
    reviews       = 'https://seller-uk.tiktok.com/product/rating'
    creator_health = 'https://seller-uk.tiktok.com/health-center/creator-health'
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
  return [string]$defaults[$moduleKey]
}

$modList = @($Modules.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$scriptMap = @{
  shop_daily    = (Join-Path $root 'scripts\scrape-shop-daily-page.js')
  health_daily  = (Join-Path $root 'scripts\scrape-health-daily-page.js')
  experience_daily = (Join-Path $root 'scripts\scrape-experience-daily-page.js')
  finance_daily = (Join-Path $root 'scripts\scrape-finance-daily-page.js')
  violation     = (Join-Path $root 'scripts\scrape-violation-page.js')
  reviews       = (Join-Path $root 'scripts\scrape-product-reviews-page.js')
  creator_health = (Join-Path $root 'scripts\scrape-creator-health-page.js')
}
$sourceMap = @{
  shop_daily    = 'tiktok_shop_daily'
  health_daily  = 'tiktok_health_daily'
  experience_daily = 'tiktok_experience_daily'
  finance_daily = 'tiktok_finance_daily'
  violation     = 'tiktok_violation'
  reviews       = 'tiktok_review'
  creator_health = 'tiktok_creator_health_daily'
}
foreach ($m in $modList) {
  if (-not $scriptMap.ContainsKey($m)) {
    throw "Unknown module: $m (use shop_daily,health_daily,experience_daily,finance_daily,violation,reviews,creator_health)"
  }
  if (-not (Test-Path $scriptMap[$m])) { throw "Missing scrape script: $($scriptMap[$m])" }
}

Write-Step '===== shop-modules multi-store START ====='
Write-Step ("config={0} modules={1}" -f $ConfigPath, ($modList -join ','))
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

# 非广告运营模块排除：欧盟 Pop 等（广告仍可采）
# 兼容字段：opsExclude* 优先合并 ordersExclude*
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
foreach ($s in $selected) { Write-Step ("  - {0} | {1} | {2}" -f $s.storeId, $s.storeName, $s.platform) }
if ($ListOnly) { Write-Step 'ListOnly done'; return }
if ($selected.Count -eq 0) { throw 'No stores matched' }

$dryParsed = Convert-DryRunFlag $DryRun
$useDryRun = if ($null -ne $dryParsed) { [bool]$dryParsed } else {
  if ($cfg.options -and $null -ne $cfg.options.dryRun) { [bool]$cfg.options.dryRun } else { $true }
}
$waitOpen = 28000; $waitVisit = 30000; $retries = 3
if ($cfg.options.waitAfterOpenMs) { $waitOpen = [Math]::Max(15000, [int]$cfg.options.waitAfterOpenMs) }
if ($cfg.options.waitAfterVisitMs) { $waitVisit = [Math]::Max(15000, [int]$cfg.options.waitAfterVisitMs) }
if ($cfg.options.scrapeRetries) { $retries = [Math]::Max(2, [int]$cfg.options.scrapeRetries) }

# biz_date：默认昨天（与广告日更一致）；-DateMode 可覆盖 config.options.dateMode
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
Write-Step ("dryRun={0} dateMode={1} biz_date={2}" -f $useDryRun, $effectiveDateMode, $bizDate)

$oneLiners = @{}
foreach ($m in $modList) {
  $oneLiners[$m] = ConvertTo-ScrapeOneLine (Get-Content $scriptMap[$m] -Raw -Encoding UTF8)
}
$creatorSwitchJsPath = Join-Path $root 'scripts\scrape-creator-health-switch.js'
$creatorSwitchTemplate = ''
if (Test-Path $creatorSwitchJsPath) {
  $creatorSwitchTemplate = Get-Content $creatorSwitchJsPath -Raw -Encoding UTF8
}

function Invoke-CreatorHealthMultiAccountScrape {
  param(
    [string]$StoreId,
    [object]$BasePayload,
    [int]$MaxAccounts = 12
  )
  if (-not $BasePayload) { return $BasePayload }
  if (-not $creatorSwitchTemplate) {
    Write-Step '  creator multi-account: switch template missing, keep list-only scrape'
    return $BasePayload
  }
  $junkName = '切换账号|ScoreHub|违规次数|官方账号|营销账号|了解更多|需要关注|你的店铺已绑定|店铺已绑定|Switch\s*account'
  $names = New-Object System.Collections.Generic.List[string]
  if ($BasePayload.accounts) {
    foreach ($a in @($BasePayload.accounts)) {
      $n = ''
      if ($a.name) { $n = [string]$a.name }
      elseif ($a.creator_name) { $n = [string]$a.creator_name }
      $n = $n.Trim()
      if (-not $n -or $n -match $junkName) { continue }
      if (-not $names.Contains($n)) { [void]$names.Add($n) }
    }
  }
  if ($names.Count -eq 0 -and $BasePayload.selectedName) {
    $sel = ([string]$BasePayload.selectedName).Trim()
    if ($sel -and $sel -notmatch $junkName) { [void]$names.Add($sel) }
  }
  if ($names.Count -eq 0) {
    Write-Step '  creator multi-account: no account names in list'
    return $BasePayload
  }
  if ($names.Count -gt $MaxAccounts) {
    Write-Step ("  creator multi-account: cap {0} -> {1}" -f $names.Count, $MaxAccounts)
    $tmp = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $MaxAccounts; $i++) { [void]$tmp.Add($names[$i]) }
    $names = $tmp
  }
  Write-Step ("  creator multi-account: switch {0} account(s): {1}" -f $names.Count, ($names -join ', '))

  $mergedAccounts = New-Object System.Collections.ArrayList
  $allViolByCreator = @{}
  # seed roles/vc from list scrape
  $seed = @{}
  if ($BasePayload.accounts) {
    foreach ($a in @($BasePayload.accounts)) {
      $n = if ($a.name) { [string]$a.name } else { '' }
      if ($n) { $seed[$n] = $a }
    }
  }

  foreach ($name in $names) {
    $safe = $name -replace "[\\'""]", ''
    if (-not $safe) { continue }
    $js = $creatorSwitchTemplate.Replace('__CREATOR_TARGET__', $safe)
    $one = ConvertTo-ScrapeOneLine $js
    Write-Step ("  switch+scrape creator: {0}" -f $safe)
    $execOut = $null
    $accPayload = $null
    try {
      $execOut = Invoke-Ziniao @('page', 'exec', '--store-id', $StoreId, '--script', $one, '--timeout', '60000')
      $accPayload = Get-ScrapePayload $execOut
    } catch {
      Write-Step ("  creator switch fail {0}: {1}" -f $safe, $_)
    }
    if (-not $accPayload -or -not $accPayload.ok) {
      $err = if ($accPayload -and $accPayload.error) { [string]$accPayload.error } else { 'no payload' }
      Write-Step ("  creator switch incomplete {0}: {1}" -f $safe, $err)
      # still emit shell account from seed
      $role = ''
      $vc = $null
      if ($seed.ContainsKey($safe)) {
        if ($seed[$safe].role) { $role = [string]$seed[$safe].role }
        if ($null -ne $seed[$safe].violationCount) { $vc = [int]$seed[$safe].violationCount }
      }
      [void]$mergedAccounts.Add([pscustomobject]@{
        name = $safe; role = $role; violationCount = $vc; healthScore = $null; switched = $false
      })
      Start-Sleep -Seconds 2
      continue
    }
    $score = $null
    if ($null -ne $accPayload.healthScore) { $score = [double]$accPayload.healthScore }
    $role = ''
    $vc = $null
    if ($seed.ContainsKey($safe)) {
      if ($seed[$safe].role) { $role = [string]$seed[$safe].role }
      if ($null -ne $seed[$safe].violationCount) { $vc = [int]$seed[$safe].violationCount }
    }
    if ($null -ne $accPayload.violationCount) { $vc = [int]$accPayload.violationCount }
    [void]$mergedAccounts.Add([pscustomobject]@{
      name = $safe
      role = $role
      violationCount = $vc
      healthScore = $score
      statusLabel = $(if ($accPayload.statusLabel) { [string]$accPayload.statusLabel } else { '' })
      switched = [bool]$accPayload.switched
    })
    if ($accPayload.violations) {
      $allViolByCreator[$safe] = @($accPayload.violations)
    }
    Start-Sleep -Seconds 2
  }

  # rebuild payload for converter
  # ConvertFrom-Json 对象默认不能直接加新属性（ErrorActionPreference=Stop 会炸成
  # 「在此对象上找不到属性 multiCreatorViolations」）。accounts 字段 JSON 里已有可直接赋；
  # multiCreatorViolations 是切号循环后补的，必须 Add-Member。
  $BasePayload.accounts = @($mergedAccounts.ToArray())
  $BasePayload | Add-Member -NotePropertyName 'multiCreatorViolations' -NotePropertyValue $allViolByCreator -Force
  $scored = @($mergedAccounts | Where-Object { $null -ne $_.healthScore }).Count
  Write-Step ("  creator multi-account done: {0}/{1} with healthScore" -f $scored, $mergedAccounts.Count)
  return $BasePayload
}

$summary = @()
foreach ($store in $selected) {
  $sid = $store.storeId
  $sname = $store.storeName
  $display = Get-DisplayName $store $cfg.storeNameMap
  Write-Step ("==== STORE {0} ({1}) => {2} ====" -f $sname, $sid, $display)

  # open once on first module URL
  $firstUrl = Get-ModuleUrl $store $cfg $modList[0]
  try {
    Write-Step '  open store...'
    $openArgs = New-ZiniaoStoreOpenArgs -StoreId $sid -Url $firstUrl -Config $cfg
    Write-Host (Invoke-Ziniao $openArgs)
    Start-Sleep -Milliseconds $waitOpen
    Invoke-ZiniaoStoreMaximize -StoreId $sid -InvokeZiniao ${function:Invoke-Ziniao} -WriteStep ${function:Write-Step} -Config $cfg | Out-Null

    foreach ($mod in $modList) {
      $item = [ordered]@{
        storeId = $sid; storeName = $sname; displayName = $display; module = $mod
        ok = $false; qingquanAccepted = 0; qingquanDup = 0; error = $null
      }
      $ingestFailed = $false
      $modUrl = Get-ModuleUrl $store $cfg $mod
      Write-Step ("  -- module {0} url={1}" -f $mod, $modUrl)
      try {
        $null = Invoke-Ziniao @('page', 'visit', '--store-id', $sid, '--url', $modUrl, '--wait-until', 'load', '--timeout', '120000')
        # SPA 渲染：finance 快，compass/health/reviews 慢
        $extraWait = [Math]::Max(35000, $waitVisit)
        if ($mod -eq 'finance_daily') { $extraWait = [Math]::Max(15000, [int]($waitVisit * 0.6)) }
        if ($mod -eq 'violation') { $extraWait = [Math]::Max(40000, $waitVisit) }
        if ($mod -eq 'reviews') { $extraWait = [Math]::Max(40000, $waitVisit) }
        if ($mod -eq 'experience_daily') { $extraWait = [Math]::Max(40000, $waitVisit) }
        if ($mod -eq 'creator_health') { $extraWait = [Math]::Max(40000, $waitVisit) }
        Start-Sleep -Milliseconds $extraWait
        $payload = $null
        $lastErr = $null
        for ($attempt = 1; $attempt -le $retries; $attempt++) {
          Write-Step ("  scrape {0} attempt {1}/{2}..." -f $mod, $attempt, $retries)
          $execOut = Invoke-Ziniao @('page', 'exec', '--store-id', $sid, '--script', $oneLiners[$mod], '--timeout', '60000')
          if ([string]::IsNullOrWhiteSpace($execOut)) {
            $lastErr = 'empty page exec'
          } else {
            $payload = Get-ScrapePayload $execOut
            if ($payload -and $payload.ok) { $lastErr = $null; break }
            $lastErr = $null
            if ($payload -and $payload.error) { $lastErr = [string]$payload.error }
            else { $lastErr = 'scrape fail' }
            try {
              Set-Content -LiteralPath (Join-Path $script:logsDir ("{0}-exec-raw-{1}-a{2}.txt" -f $mod, $sid, $attempt)) -Value $execOut -Encoding UTF8
            } catch { }
          }
          Write-Step ("  attempt fail: {0}" -f $lastErr)
          if ($attempt -lt $retries) {
            Start-Sleep -Seconds 12
            # 2026-08-20：导航跑偏防护。scrape 脚本对落错页（如 creator-health 落到 order/detail）
            # 返回 wrong_page_not_*；此类错误光等 SPA 无用，必须重新 visit 目标 URL 把页面拉回来，
            # 并比普通重试多等 SPA 渲染。否则会在订单详情页正文里"凑"出假健康分等脏数据入库。
            if ($lastErr -match 'wrong_page') {
              Write-Step '  wrong page — re-visit target URL + extra SPA wait'
              $null = Invoke-Ziniao @('page', 'visit', '--store-id', $sid, '--url', $modUrl, '--wait-until', 'load', '--timeout', '120000')
              Start-Sleep -Seconds 25
            } elseif ($lastErr -match 'SPA not ready|not ready|no KPI|no health|no violation|no review|no experience|no creator') {
              # 不重复 visit（可能打挂 Bridge）；再等 SPA
              Write-Step '  extra 25s for SPA render'
              Start-Sleep -Seconds 25
            } else {
              $null = Invoke-Ziniao @('page', 'visit', '--store-id', $sid, '--url', $modUrl, '--wait-until', 'load', '--timeout', '120000')
              Start-Sleep -Seconds 15
            }
          }
        }
        if ($lastErr -or -not $payload) {
          if ($lastErr) { throw $lastErr }
          throw 'no payload'
        }

        # 达人健康：列表页后逐账号切换刮分/违规
        if ($mod -eq 'creator_health') {
          $maxAcc = 12
          if ($cfg.options -and $cfg.options.creatorHealthMaxAccounts) {
            $maxAcc = [Math]::Max(1, [int]$cfg.options.creatorHealthMaxAccounts)
          }
          $payload = Invoke-CreatorHealthMultiAccountScrape -StoreId $sid -BasePayload $payload -MaxAccounts $maxAcc
        }

        # finance 等允许部分字段 null，但至少要有一个金额
        if ($mod -eq 'finance_daily') {
          $hasAmt = $false
          if ($null -ne $payload.settlementAmount -or $null -ne $payload.pendingAmount -or $null -ne $payload.refundAmount) { $hasAmt = $true }
          if ($null -ne $payload.settlement_amount -or $null -ne $payload.pending_amount) { $hasAmt = $true }
          if (-not $hasAmt) { throw 'finance scrape ok flag but no amounts' }
        }
        # violation / reviews：emptyOk（暂无记录）也算成功
        if ($mod -in @('violation', 'reviews')) {
          $rc = 0
          if ($null -ne $payload.rowCount) { $rc = [int]$payload.rowCount }
          elseif ($payload.rows) { $rc = @($payload.rows).Count }
          Write-Step ("  {0} rows={1} emptyOk={2}" -f $mod, $rc, [bool]$payload.emptyOk)
        }

        $dbg = Join-Path $script:logsDir ("{0}-debug-{1}-{2}.json" -f $mod, $sid, $script:runStamp)
        (@{ storeId = $sid; displayName = $display; url = $modUrl; bizDate = $bizDate; payload = $payload } |
          ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $dbg -Encoding UTF8

        # 2026-08-20：ingest 失败不再静默吞掉。底层 Send-QingquanIngest 仍 failOpen（不抛异常），
        # 此处检查 ok/failed：失败则 $ingestFailed=$true，使该店该模块标 not-ok + 整批 exit 2。
        if ((Get-Command Send-QingquanIngest -ErrorAction SilentlyContinue) -and $cfg.qingquan -and $cfg.qingquan.enabled) {
          $collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00')
          $qqItems = $null
          switch ($mod) {
            'shop_daily' {
              $qqItems = ConvertTo-QingquanShopDailyIngestItems -Payload $payload -CollectedAt $collectedAt `
                -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $modUrl
            }
            'health_daily' {
              $qqItems = ConvertTo-QingquanHealthDailyIngestItems -Payload $payload -CollectedAt $collectedAt `
                -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $modUrl
            }
            'experience_daily' {
              $qqItems = ConvertTo-QingquanExperienceDailyIngestItems -Payload $payload -CollectedAt $collectedAt `
                -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $modUrl
            }
            'finance_daily' {
              $qqItems = ConvertTo-QingquanFinanceDailyIngestItems -Payload $payload -CollectedAt $collectedAt `
                -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $modUrl
            }
            'violation' {
              $qqItems = ConvertTo-QingquanViolationIngestItems -Payload $payload -CollectedAt $collectedAt `
                -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $modUrl
            }
            'reviews' {
              $qqItems = ConvertTo-QingquanReviewIngestItems -Payload $payload -CollectedAt $collectedAt `
                -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $modUrl
            }
            'creator_health' {
              $qqItems = ConvertTo-QingquanCreatorHealthIngestItems -Payload $payload -CollectedAt $collectedAt `
                -StoreId $sid -StoreName $display -BizDate $bizDate -SourceUrl $modUrl
            }
          }
          $qqCount = 0
          if ($null -ne $qqItems) { $qqCount = @($qqItems).Count }
          if ($useDryRun) {
            Write-Step ("  qingquan dryRun: would report {0} items={1}" -f $sourceMap[$mod], $qqCount)
          } elseif ($qqCount -eq 0 -and $mod -in @('violation', 'reviews', 'creator_health')) {
            Write-Step ("  qingquan skip empty {0} (no rows)" -f $sourceMap[$mod])
          } else {
            # creator_health 可能混合 health + violation source，由 converter 返回 hashtable
            if ($mod -eq 'creator_health' -and $qqItems -is [hashtable]) {
              foreach ($srcKey in @('tiktok_creator_health_daily', 'tiktok_creator_violation')) {
                $batch = $qqItems[$srcKey]
                if (-not $batch) { continue }
                $qq = Send-QingquanIngest -Config $cfg -Items $batch -Source $srcKey
                $item.qingquanAccepted = [int]$item.qingquanAccepted + [int]$qq.accepted
                $item.qingquanDup = [int]$item.qingquanDup + [int]$qq.duplicated
                if (-not $qq.ok -or ([int]$qq.failed -gt 0)) {
                  $ingestFailed = $true
                  $item.error = if ($qq.error) { [string]$qq.error } else { ("ingest {0} failed={1}" -f $srcKey, $qq.failed) }
                  Write-Step ("  INGEST FAIL {0}: {1} — 标 not-ok + exit 2" -f $srcKey, $item.error)
                } elseif ($qq.error -and -not $item.error) {
                  $item.error = [string]$qq.error
                }
                Write-Step ("  qingquan {0} accepted={1} dup={2} ok={3}" -f $srcKey, $qq.accepted, $qq.duplicated, $qq.ok)
              }
            } else {
              $qq = Send-QingquanIngest -Config $cfg -Items $qqItems -Source $sourceMap[$mod]
              $item.qingquanAccepted = $qq.accepted
              $item.qingquanDup = $qq.duplicated
              if (-not $qq.ok -or ([int]$qq.failed -gt 0)) {
                $ingestFailed = $true
                $item.error = if ($qq.error) { [string]$qq.error } else { ("ingest {0} failed={1} (items={2})" -f $sourceMap[$mod], $qq.failed, $qqCount) }
                Write-Step ("  INGEST FAIL {0}: {1} — 标 not-ok + exit 2" -f $sourceMap[$mod], $item.error)
              } elseif ($qq.error) {
                $item.error = [string]$qq.error
              }
              Write-Step ("  qingquan accepted={0} dup={1} ok={2}" -f $qq.accepted, $qq.duplicated, $qq.ok)
            }
          }
        } else {
          Write-Step '  skip qingquan'
        }
        if (-not $ingestFailed) { $item.ok = $true }
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

Write-Step '======== SHOP-MODULES SUMMARY ========'
$summary | Format-Table storeName, module, ok, qingquanAccepted, qingquanDup, error -AutoSize
$okN = @($summary | Where-Object { $_.ok }).Count
Write-Step ("OK {0}/{1}" -f $okN, $summary.Count)
$failN = @($summary | Where-Object { -not $_.ok }).Count
if ($failN -gt 0) {
  # 2026-08-20：ingest/刮取失败的店模块在此列出，便于定位回填。
  Write-Step ("FAIL on {0} module(s):" -f $failN)
  foreach ($s in @($summary | Where-Object { -not $_.ok })) {
    Write-Step ("  - {0} / {1}: {2}" -f $s.displayName, $s.module, $s.error)
  }
}
$sumPath = Join-Path $script:logsDir ("shop-modules-summary-{0}.json" -f $script:runStamp)
($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $sumPath -Encoding UTF8
Write-Step ("summary: {0}" -f $sumPath)
Write-Step '===== shop-modules multi-store END ====='
if ($okN -lt $summary.Count) { exit 2 }
