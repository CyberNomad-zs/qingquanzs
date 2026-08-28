# Qingquan center ingest client (Stage A dual-write)
# Dot-sourced by run-multi-store.ps1; can also be used alone.
#
# config.qingquan example:
# {
#   "enabled": true,
#   "baseUrl": "https://qingquan.jmzlai.com",
#   "apiKey": "<must match server INGEST_DEFAULT_API_KEY>",
#   "source": "tiktok_ads",
#   "failOpen": true,
#   "timeoutSec": 30
# }
#
# PS 5.1 pitfalls:
# - @($hashtable) enumerates KEYS, not a single-element array
# - return ,$object[] may still unwrap a single element on assignment
# - Generic type literals like List[object] break the parser
# Keep items in ArrayList; serialize via JavaScriptSerializer.

function Get-QingquanConfig($cfg) {
  if (-not $cfg.qingquan) {
    return [pscustomobject]@{
      enabled    = $false
      baseUrl    = 'http://127.0.0.1:8000'
      apiKey     = ''
      source     = 'tiktok_ads'
      failOpen   = $true
      timeoutSec = 30
    }
  }
  $q = $cfg.qingquan
  $enabled = $false
  if ($null -ne $q.enabled) { $enabled = [bool]$q.enabled }
  $failOpen = $true
  if ($null -ne $q.failOpen) { $failOpen = [bool]$q.failOpen }
  $timeout = 30
  if ($null -ne $q.timeoutSec) { $timeout = [int]$q.timeoutSec }
  $source = 'tiktok_ads'
  if ($q.source) { $source = [string]$q.source }
  $base = 'http://127.0.0.1:8000'
  if ($q.baseUrl) { $base = [string]$q.baseUrl }
  $key = ''
  if ($q.apiKey) { $key = [string]$q.apiKey }
  return [pscustomobject]@{
    enabled    = $enabled
    baseUrl    = $base.TrimEnd('/')
    apiKey     = $key
    source     = $source
    failOpen   = $failOpen
    timeoutSec = $timeout
  }
}

function Get-FeishuWriteMode($cfg) {
  # direct | dual | center
  $mode = 'direct'
  if ($cfg.feishu -and $cfg.feishu.writeMode) {
    $mode = [string]$cfg.feishu.writeMode
  } elseif ($cfg.qingquan -and $cfg.qingquan.enabled) {
    $mode = 'dual'
  }
  $mode = $mode.ToLowerInvariant()
  if ($mode -notin @('direct', 'dual', 'center')) { $mode = 'direct' }
  return $mode
}

function Get-QingquanItemList {
  param($Items)
  $list = New-Object System.Collections.ArrayList
  if ($null -eq $Items) { return $list }

  function Test-IsIngestItem($x) {
    if ($null -eq $x) { return $false }
    if ($x -is [string] -or $x -is [int] -or $x -is [long] -or $x -is [double] -or $x -is [decimal] -or $x -is [bool]) { return $false }
    # 属性访问：PSCustomObject / Hashtable 通用
    try {
      $key = $x.idempotency_key
      $pay = $x.payload
      $sid = $x.shop_id
      if ($null -ne $key -and "$key" -ne '' -and ($null -ne $pay -or $null -ne $sid)) { return $true }
      if ($null -ne $pay -and $null -ne $sid) { return $true }
    } catch {}
    if ($x -is [System.Collections.IDictionary]) {
      return ($x.Contains('idempotency_key') -or ($x.Contains('payload') -and $x.Contains('shop_id')))
    }
    return $false
  }

  if (Test-IsIngestItem $Items) {
    [void]$list.Add($Items)
    return $list
  }

  # 注意：不要用 foreach 直接扫 PSCustomObject（会枚举属性）
  if ($Items -is [System.Collections.ArrayList]) {
    for ($i = 0; $i -lt $Items.Count; $i++) {
      $x = $Items[$i]
      if (Test-IsIngestItem $x) { [void]$list.Add($x) }
    }
    return $list
  }

  if ($Items -is [System.Array]) {
    for ($i = 0; $i -lt $Items.Length; $i++) {
      $x = $Items[$i]
      if (Test-IsIngestItem $x) { [void]$list.Add($x) }
    }
    return $list
  }

  return $list
}

function ConvertTo-QingquanIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Rows,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [string]$Currency = 'USD'
  )
  if ([string]::IsNullOrWhiteSpace($Currency)) { $Currency = 'USD' }
  $items = New-Object System.Collections.ArrayList
  foreach ($r in @($Rows)) {
    $campaign = [string]$r.campaign
    if (-not $campaign) { continue }
    $storeId = [string]$r.storeId
    $bizDate = [string]$r.date
    $spend = 0; if ($null -ne $r.spend) { $spend = [double]$r.spend }
    $orders = 0; if ($null -ne $r.orders) { $orders = [double]$r.orders }
    $roi = $null; if ($null -ne $r.roi) { $roi = [double]$r.roi }
    $revenue = 0; if ($null -ne $r.revenue) { $revenue = [double]$r.revenue }
    $dailyBudget = $null
    if ($null -ne $r.dailyBudget -and "$($r.dailyBudget)" -ne '') { $dailyBudget = [double]$r.dailyBudget }
    $targetRoi = $null
    if ($null -ne $r.targetRoi -and "$($r.targetRoi)" -ne '') { $targetRoi = [double]$r.targetRoi }
    $netCost = $null
    if ($null -ne $r.netCost -and "$($r.netCost)" -ne '') { $netCost = [double]$r.netCost }
    $avgOrderCost = $null
    if ($null -ne $r.avgOrderCost -and "$($r.avgOrderCost)" -ne '') { $avgOrderCost = [double]$r.avgOrderCost }
    $status = 'success'; if ($r.status) { $status = [string]$r.status }
    $planStatus = ''; if ($r.planStatus) { $planStatus = [string]$r.planStatus }
    $deliveryStatus = ''; if ($r.deliveryStatus) { $deliveryStatus = [string]$r.deliveryStatus }
    $sourceUrl = ''; if ($r.sourceUrl) { $sourceUrl = [string]$r.sourceUrl }
    $storeName = ''; if ($r.store) { $storeName = [string]$r.store }
    $rowCurrency = $Currency
    if ($r.currency) { $rowCurrency = [string]$r.currency }

    $payload = @{
      campaign_name   = $campaign
      spend           = $spend
      orders          = $orders
      roi             = $roi
      revenue         = $revenue
      daily_budget    = $dailyBudget
      target_roi      = $targetRoi
      net_cost        = $netCost
      avg_order_cost  = $avgOrderCost
      delivery_status = $deliveryStatus
      row_status      = $status
      plan_status     = $planStatus
      currency        = $rowCurrency
      source_url      = $sourceUrl
    }

    [void]$items.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $storeId
      shop_name       = $storeName
      biz_date        = $bizDate
      collected_at    = $CollectedAt
      idempotency_key = ("tiktok_ads:{0}:{1}:{2}" -f $storeId, $campaign, $bizDate)
      payload         = $payload
      evidence        = @{ source_url = $sourceUrl }
    })
  }
  # PS 5.1 unwraps a 1-element ArrayList into the bare Hashtable on `return`.
  # -NoEnumerate keeps the list intact so .Count == item count (not key count).
  # 返回 object[]；单元素也保持数组，避免解包成 Hashtable
  Write-Output -NoEnumerate @($items.ToArray())
}

function Resolve-TikTokOrderDateTime {
  param(
    [string]$Text,
    [datetime]$Ref = $(Get-Date)
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $s = $Text.Trim()
  if ($s -match '截止|送达日期|delivery\s*by') {
    if ($s -notmatch '分钟前|小时前|天前|今天|昨天|星期|周') { return $null }
  }
  # 先剥 18 位订单号，再取 1~4 位相对量（避免 5769…72428 被当成 2428 分钟）
  $s2 = [regex]::Replace($s, '57\d{16}', ' ')
  $s2 = [regex]::Replace($s2, '\b\d{15,20}\b', ' ')
  $s2 = $s2.Trim()
  if ($s2 -match '(\d{1,4})\s*分钟前') { return $Ref.AddMinutes(-[int]$Matches[1]) }
  if ($s2 -match '(\d{1,4})\s*小时前') { return $Ref.AddHours(-[int]$Matches[1]) }
  if ($s2 -match '(\d{1,4})\s*天前') { return $Ref.AddDays(-[int]$Matches[1]) }
  if ($s2 -match '(今天|昨天)\s*(\d{1,2}):(\d{2})(?::(\d{2}))?') {
    $day = if ($Matches[1] -eq '今天') { $Ref.Date } else { $Ref.Date.AddDays(-1) }
    $sec = 0; if ($Matches[4]) { $sec = [int]$Matches[4] }
    return $day.AddHours([int]$Matches[2]).AddMinutes([int]$Matches[3]).AddSeconds($sec)
  }
  if ($s2 -match '(?:星期|周)([一二三四五六日天])\s*(\d{1,2}):(\d{2})(?::(\d{2}))?') {
    $map = @{ '一' = 1; '二' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '日' = 0; '天' = 0 }
    $target = [int]$map[$Matches[1]]
    $cur = [int]$Ref.DayOfWeek
    $delta = ($cur - $target + 7) % 7
    $day = $Ref.Date.AddDays(-$delta)
    $sec = 0; if ($Matches[4]) { $sec = [int]$Matches[4] }
    return $day.AddHours([int]$Matches[2]).AddMinutes([int]$Matches[3]).AddSeconds($sec)
  }
  $formats = @(
    'yyyy/M/d H:mm:ss', 'yyyy/M/d H:mm', 'yyyy-M-d H:mm:ss', 'yyyy-M-d H:mm',
    'yyyy/MM/dd HH:mm:ss', 'yyyy-MM-dd HH:mm:ss', 'yyyy/MM/dd HH:mm', 'yyyy-MM-dd'
  )
  foreach ($f in $formats) {
    try {
      return [datetime]::ParseExact($s2, $f, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch { }
  }
  try { return [datetime]::Parse($s2) } catch { return $null }
}

function ConvertTo-QingquanOrderIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Rows,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [string]$StoreName = '',
    [string]$BizDate = '',
    [string]$Currency = 'USD',
    [string]$SourceUrl = ''
  )
  if ([string]::IsNullOrWhiteSpace($Currency)) { $Currency = 'USD' }
  $items = New-Object System.Collections.ArrayList
  $refNow = Get-Date
  try { if ($CollectedAt) { $refNow = [datetime]::Parse($CollectedAt) } } catch { $refNow = Get-Date }

  foreach ($r in @($Rows)) {
    $orderId = ''
    if ($r.orderId) { $orderId = [string]$r.orderId }
    elseif ($r.order_id) { $orderId = [string]$r.order_id }
    if (-not $orderId) { continue }

    $qty = 0
    if ($null -ne $r.quantity) { try { $qty = [double]$r.quantity } catch { $qty = 0 } }
    $pay = 0
    if ($null -ne $r.payAmount) { try { $pay = [double]$r.payAmount } catch { $pay = 0 } }
    elseif ($null -ne $r.pay_amount) { try { $pay = [double]$r.pay_amount } catch { $pay = 0 } }

    $rowCurrency = $Currency
    if ($r.currency) { $rowCurrency = [string]$r.currency }
    elseif ($r.currencyHint) { $rowCurrency = [string]$r.currencyHint }

    $rowSourceUrl = $SourceUrl
    if ($r.sourceUrl) { $rowSourceUrl = [string]$r.sourceUrl }

    $rawCreate = ''
    if ($r.createTime) { $rawCreate = [string]$r.createTime }
    elseif ($r.create_time) { $rawCreate = [string]$r.create_time }
    if (-not $rawCreate -and $r.createTimeRaw) { $rawCreate = [string]$r.createTimeRaw }
    elseif (-not $rawCreate -and $r.create_time_raw) { $rawCreate = [string]$r.create_time_raw }
    $rawPay = ''
    if ($r.payTime) { $rawPay = [string]$r.payTime }
    elseif ($r.pay_time) { $rawPay = [string]$r.pay_time }

    $createDt = Resolve-TikTokOrderDateTime -Text $rawCreate -Ref $refNow
    $payDt = Resolve-TikTokOrderDateTime -Text $rawPay -Ref $refNow
    $createIso = ''
    if ($createDt) { $createIso = $createDt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00') }
    $payIso = ''
    if ($payDt) { $payIso = $payDt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00') }

    $biz = $BizDate
    if (-not $biz) {
      $cand = $null
      if ($payDt) { $cand = $payDt.Date }
      elseif ($createDt) { $cand = $createDt.Date }
      if ($cand -and $cand -le $refNow.Date.AddDays(1)) {
        $biz = $cand.ToString('yyyy-MM-dd')
      }
    }

    $payload = @{
      order_id        = $orderId
      order_status    = $(if ($r.orderStatus) { [string]$r.orderStatus } elseif ($r.order_status) { [string]$r.order_status } else { '' })
      pay_time        = $payIso
      create_time     = $createIso
      product_name    = $(if ($r.productName) { [string]$r.productName } elseif ($r.product_name) { [string]$r.product_name } else { '' })
      seller_sku      = $(if ($r.sellerSku) { [string]$r.sellerSku } elseif ($r.seller_sku) { [string]$r.seller_sku } else { '' })
      sku_id          = $(if ($r.skuId) { [string]$r.skuId } elseif ($r.sku_id) { [string]$r.sku_id } else { '' })
      quantity        = $qty
      pay_amount      = $pay
      currency        = $rowCurrency
      shipping_status = $(if ($r.shippingStatus) { [string]$r.shippingStatus } else { '' })
      buyer_region    = $(if ($r.buyerRegion) { [string]$r.buyerRegion } else { '' })
      source_url      = $rowSourceUrl
    }
    if ($r.createTimeRaw) { $payload['create_time_raw'] = [string]$r.createTimeRaw }
    elseif ($rawCreate) { $payload['create_time_raw'] = $rawCreate }

    [void]$items.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $StoreId
      shop_name       = $StoreName
      biz_date        = $(if ($biz) { $biz } else { $null })
      collected_at    = $CollectedAt
      idempotency_key = ("tiktok_orders:{0}:{1}" -f $StoreId, $orderId)
      payload         = $payload
      evidence        = @{ source_url = $rowSourceUrl }
    })
  }
  # 返回 object[]；单元素也保持数组，避免解包成 Hashtable
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanOrderLineIngestItems {
  <#
    订单详情行 → tiktok_order_lines
    输入：scrape-order-detail-page.js 的 lines[]，或已展平的行对象（含 orderId）
  #>
  param(
    [Parameter(Mandatory = $true)] $Lines,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$OrderId,
    [string]$StoreName = '',
    [string]$BizDate = '',
    [string]$Currency = 'GBP',
    [string]$SourceUrl = ''
  )
  if ([string]::IsNullOrWhiteSpace($Currency)) { $Currency = 'GBP' }
  $items = New-Object System.Collections.ArrayList
  $oid = [string]$OrderId
  if (-not $oid) { Write-Output -NoEnumerate @(); return }

  # 解析业务日：参数优先；否则从行内 pay/create 时间抽 yyyy-MM-dd
  $resolvedBiz = ''
  if ($BizDate -and ($BizDate -match '(\d{4}-\d{2}-\d{2})')) {
    $resolvedBiz = $Matches[1]
  } elseif ($BizDate) {
    try {
      $resolvedBiz = ([datetime]::Parse([string]$BizDate, [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd')
    } catch { $resolvedBiz = '' }
  }
  if (-not $resolvedBiz) {
    foreach ($r0 in @($Lines)) {
      foreach ($col in @('bizDate', 'biz_date', 'payTime', 'pay_time', 'createTime', 'create_time')) {
        if ($null -eq $r0) { continue }
        $raw = $null
        try { $raw = $r0.$col } catch { $raw = $null }
        if (-not $raw) { continue }
        $s = [string]$raw
        if ($s -match '(\d{4}-\d{2}-\d{2})') { $resolvedBiz = $Matches[1]; break }
      }
      if ($resolvedBiz) { break }
    }
  }

  $idx = 0
  foreach ($r in @($Lines)) {
    $idx++
    $sellerSku = ''
    if ($r.sellerSku) { $sellerSku = [string]$r.sellerSku }
    elseif ($r.seller_sku) { $sellerSku = [string]$r.seller_sku }
    $skuId = ''
    if ($r.skuId) { $skuId = [string]$r.skuId }
    elseif ($r.sku_id) { $skuId = [string]$r.sku_id }
    $productId = ''
    if ($r.productId) { $productId = [string]$r.productId }
    elseif ($r.product_id) { $productId = [string]$r.product_id }
    $productName = ''
    if ($r.productName) { $productName = [string]$r.productName }
    elseif ($r.product_name) { $productName = [string]$r.product_name }
    $lineNo = $idx
    if ($null -ne $r.lineNo) { try { $lineNo = [int]$r.lineNo } catch { $lineNo = $idx } }
    elseif ($null -ne $r.line_no) { try { $lineNo = [int]$r.line_no } catch { $lineNo = $idx } }
    $lineKey = ''
    if ($r.lineKey) { $lineKey = [string]$r.lineKey }
    elseif ($r.line_key) { $lineKey = [string]$r.line_key }
    if (-not $lineKey) {
      if ($skuId) { $lineKey = "sid:$skuId" }
      elseif ($sellerSku) { $lineKey = "sku:$sellerSku" }
      elseif ($productId) { $lineKey = "pid:${productId}:n$lineNo" }
      else { $lineKey = "n:${lineNo}:$($productName.Substring(0, [Math]::Min(40, $productName.Length)))" }
    }
    if (-not $sellerSku -and -not $skuId -and -not $productId -and -not $productName) { continue }

    $qty = 1
    if ($null -ne $r.quantity -and "$($r.quantity)" -ne '') { try { $qty = [double]$r.quantity } catch { $qty = 1 } }
    $pay = $null
    if ($null -ne $r.payAmount -and "$($r.payAmount)" -ne '') { try { $pay = [double]$r.payAmount } catch {} }
    elseif ($null -ne $r.pay_amount -and "$($r.pay_amount)" -ne '') { try { $pay = [double]$r.pay_amount } catch {} }
    $unit = $null
    if ($null -ne $r.unitPrice -and "$($r.unitPrice)" -ne '') { try { $unit = [double]$r.unitPrice } catch {} }
    elseif ($null -ne $r.unit_price -and "$($r.unit_price)" -ne '') { try { $unit = [double]$r.unit_price } catch {} }

    $rowCurrency = $Currency
    if ($r.currency) { $rowCurrency = [string]$r.currency }
    elseif ($r.currencyHint) { $rowCurrency = [string]$r.currencyHint }
    $rowSourceUrl = $SourceUrl
    if ($r.sourceUrl) { $rowSourceUrl = [string]$r.sourceUrl }

    $payload = @{
      order_id     = $oid
      line_no      = $lineNo
      line_key     = $lineKey
      product_id   = $productId
      product_name = $productName
      seller_sku   = $sellerSku
      sku_id       = $skuId
      quantity     = $qty
      pay_amount   = $pay
      unit_price   = $unit
      currency     = $rowCurrency
      source_url   = $rowSourceUrl
    }
    if ($resolvedBiz) { $payload['biz_date'] = $resolvedBiz }
    if ($r.rawText) { $payload['raw_text'] = [string]$r.rawText }
    # 透传时间字段，便于 ingest 推导 biz_date
    if ($r.payTime) { $payload['pay_time'] = [string]$r.payTime }
    elseif ($r.pay_time) { $payload['pay_time'] = [string]$r.pay_time }
    if ($r.createTime) { $payload['create_time'] = [string]$r.createTime }
    elseif ($r.create_time) { $payload['create_time'] = [string]$r.create_time }

    [void]$items.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $StoreId
      shop_name       = $StoreName
      biz_date        = $(if ($resolvedBiz) { $resolvedBiz } else { $null })
      collected_at    = $CollectedAt
      idempotency_key = ("tiktok_order_lines:{0}:{1}:{2}" -f $StoreId, $oid, $lineKey)
      payload         = $payload
      evidence        = @{ source_url = $rowSourceUrl }
    })
  }
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanProductIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Rows,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [string]$StoreName = '',
    [string]$Currency = 'GBP',
    [string]$SourceUrl = ''
  )
  if ([string]::IsNullOrWhiteSpace($Currency)) { $Currency = 'GBP' }
  $items = New-Object System.Collections.ArrayList
  foreach ($r in @($Rows)) {
    $productId = ''
    if ($r.productId) { $productId = [string]$r.productId }
    elseif ($r.product_id) { $productId = [string]$r.product_id }
    $sellerSku = ''
    if ($r.sellerSku) { $sellerSku = [string]$r.sellerSku }
    elseif ($r.seller_sku) { $sellerSku = [string]$r.seller_sku }
    $sellerSkus = @()
    if ($r.sellerSkus) { $sellerSkus = @($r.sellerSkus | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    elseif ($r.seller_skus) { $sellerSkus = @($r.seller_skus | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    if ($sellerSkus.Count -eq 0 -and $sellerSku) {
      $sellerSkus = @($sellerSku -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $productName = ''
    if ($r.productName) { $productName = [string]$r.productName }
    elseif ($r.product_name) { $productName = [string]$r.product_name }
    # 拒收「N 个 SKU 展开」噪声行
    $noiseBlob = "$productId $productName $sellerSku"
    if ($noiseBlob -match '\d+\s*个\s*SKU|SKU\s*展开|展开全部') { continue }
    if ($productId -match '^name:.*(SKU|展开)') { continue }
    if (-not $productId) {
      if ($sellerSku -and $sellerSku -notmatch '展开|SKU展开') { $productId = "sku:$sellerSku" }
      elseif ($productName -and $productName -notmatch '\d+\s*个\s*SKU|SKU\s*展开') {
        $productId = "name:$($productName.Substring(0, [Math]::Min(80, $productName.Length)))"
      }
    }
    if (-not $productId) { continue }
    if ($productId -match 'SKU展开|展开全部|\d+\s*个\s*SKU') { continue }

    $stock = $null
    if ($null -ne $r.stockQty -and "$($r.stockQty)" -ne '') { try { $stock = [double]$r.stockQty } catch {} }
    $price = $null
    if ($null -ne $r.price -and "$($r.price)" -ne '') { try { $price = [double]$r.price } catch {} }
    $sales = $null
    if ($null -ne $r.salesQty -and "$($r.salesQty)" -ne '') { try { $sales = [double]$r.salesQty } catch {} }

    $rowCurrency = $Currency
    if ($r.currency) { $rowCurrency = [string]$r.currency }
    elseif ($r.currencyHint) { $rowCurrency = [string]$r.currencyHint }
    $rowSourceUrl = $SourceUrl
    if ($r.sourceUrl) { $rowSourceUrl = [string]$r.sourceUrl }

    if (-not $sellerSku -and $sellerSkus.Count -gt 0) {
      if ($sellerSkus.Count -eq 1) { $sellerSku = [string]$sellerSkus[0] }
      else { $sellerSku = ($sellerSkus -join '|') }
    }

    $payload = @{
      product_id   = $productId
      product_name = $productName
      seller_sku   = $sellerSku
      seller_skus  = @($sellerSkus)
      status       = $(if ($r.status) { [string]$r.status } else { '' })
      stock_qty    = $stock
      price        = $price
      sales_qty    = $sales
      currency     = $rowCurrency
      source_url   = $rowSourceUrl
    }

    [void]$items.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $StoreId
      shop_name       = $StoreName
      biz_date        = $null
      collected_at    = $CollectedAt
      idempotency_key = ("tiktok_products:{0}:{1}" -f $StoreId, $productId)
      payload         = $payload
      evidence        = @{ source_url = $rowSourceUrl }
    })
  }
  # 返回 object[]；单元素也保持数组，避免解包成 Hashtable
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanProductTrafficIngestItems {
  <#
    P2.1a 商品卡流量 → tiktok_product_traffic
    输入：scrape-product-traffic-page.js 的 payload（含 products[]）
    语义：窗口快照；一行一 product；biz_date 为窗口锚点日（不拆 7 日）
  #>
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$Currency = 'GBP',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  if (-not $p) { Write-Output -NoEnumerate @(); return }

  $cur = $Currency
  if ($p.currency) { $cur = [string]$p.currency }
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }
  $channelDefault = 'product_card'
  if ($p.channelDefault) { $channelDefault = [string]$p.channelDefault }
  elseif ($p.channel) { $channelDefault = [string]$p.channel }

  $windowLabel = $null
  if ($p.window) { $windowLabel = [string]$p.window }
  elseif ($p.raw -and $p.raw.window) { $windowLabel = [string]$p.raw.window }

  $pageKpis = $null
  if ($p.kpis) { $pageKpis = $p.kpis }

  $rows = @()
  if ($p.products) { $rows = @($p.products) }
  elseif ($p.Rows) { $rows = @($p.Rows) }

  foreach ($r in $rows) {
    $productId = ''
    if ($r.productId) { $productId = [string]$r.productId }
    elseif ($r.product_id) { $productId = [string]$r.product_id }
    $productName = ''
    if ($r.title) { $productName = [string]$r.title }
    elseif ($r.productName) { $productName = [string]$r.productName }
    elseif ($r.product_name) { $productName = [string]$r.product_name }
    if (-not $productId) {
      if ($productName -match '\b(\d{10,})\b') { $productId = $Matches[1] }
    }
    if (-not $productId) { continue }

    $channel = $channelDefault
    if ($r.channel) { $channel = [string]$r.channel }
    if ([string]::IsNullOrWhiteSpace($channel)) { $channel = 'product_card' }

    $rowCur = $cur
    if ($r.currency) { $rowCur = [string]$r.currency }
    $rowSrc = $src
    if ($r.href) { $rowSrc = [string]$r.href }
    elseif ($r.sourceUrl) { $rowSrc = [string]$r.sourceUrl }

    $numImpr = $null; $numClicks = $null; $numCtr = $null
    $numOrders = $null; $numGmv = $null; $numCvr = $null; $numCust = $null
    if ($null -ne $r.impressions -and "$($r.impressions)" -ne '') { try { $numImpr = [double]$r.impressions } catch {} }
    if ($null -ne $r.clicks -and "$($r.clicks)" -ne '') { try { $numClicks = [double]$r.clicks } catch {} }
    if ($null -ne $r.ctr -and "$($r.ctr)" -ne '') { try { $numCtr = [double]$r.ctr } catch {} }
    if ($null -ne $r.orders -and "$($r.orders)" -ne '') { try { $numOrders = [double]$r.orders } catch {} }
    elseif ($null -ne $r.orders_cnt -and "$($r.orders_cnt)" -ne '') { try { $numOrders = [double]$r.orders_cnt } catch {} }
    if ($null -ne $r.gmv -and "$($r.gmv)" -ne '') { try { $numGmv = [double]$r.gmv } catch {} }
    if ($null -ne $r.cvr -and "$($r.cvr)" -ne '') { try { $numCvr = [double]$r.cvr } catch {} }
    if ($null -ne $r.customers -and "$($r.customers)" -ne '') { try { $numCust = [double]$r.customers } catch {} }

    # 英文站 Viewers / View-to-paid 漏映射时，从 rawCells 形态回填（名称|GMV|CVR%|曝光|操作）
    if (($null -eq $numImpr -or $null -eq $numCvr -or $null -eq $numGmv) -and $r.rawCells) {
      foreach ($cell in @($r.rawCells)) {
        $t = [string]$cell
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t -match 'details?|详情|操作') { continue }
        if (($null -eq $numGmv) -and ($t -match '[£$€¥￥]')) {
          if ($t -match '([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)') {
            try { $numGmv = [double]($Matches[1] -replace ',', '') } catch {}
          }
          continue
        }
        if (($null -eq $numCvr) -and ($t -match '([0-9]+(?:\.[0-9]+)?)\s*%')) {
          try { $numCvr = [double]$Matches[1] } catch {}
          continue
        }
        if (($null -eq $numImpr) -and ($t -match '([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s*([KkMm万])')) {
          try {
            $base = [double]($Matches[1] -replace ',', '')
            $u = $Matches[2]
            if ($u -eq 'K' -or $u -eq 'k') { $numImpr = $base * 1000 }
            elseif ($u -eq 'M' -or $u -eq 'm') { $numImpr = $base * 1000000 }
            elseif ($u -eq '万') { $numImpr = $base * 10000 }
            else { $numImpr = $base }
          } catch {}
        }
      }
    }

    $body = @{
      product_id   = $productId
      product_name = $productName
      channel      = $channel
      impressions  = $numImpr
      clicks       = $numClicks
      ctr          = $numCtr
      orders_cnt   = $numOrders
      gmv          = $numGmv
      cvr          = $numCvr
      customers    = $numCust
      currency     = $rowCur
      source_url   = $rowSrc
    }
    if ($windowLabel) { $body['window'] = $windowLabel }
    if ($pageKpis) { $body['page_kpis'] = $pageKpis }
    if ($r.rawCells) { $body['raw_cells'] = $r.rawCells }
    if ($p.raw -and $p.raw.tableHeaders) { $body['table_headers'] = $p.raw.tableHeaders }

    $idem = ("tiktok_product_traffic:{0}:{1}:{2}:{3}" -f $StoreId, $BizDate, $productId, $channel)
    [void]$items.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $StoreId
      shop_name       = $StoreName
      biz_date        = $BizDate
      collected_at    = $CollectedAt
      idempotency_key = $idem
      payload         = $body
      evidence        = @{ source_url = $rowSrc }
    })
  }
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanContentIngestItems {
  <#
    P2.1b 视频内容行 → tiktok_content
    输入：scrape-video-list-page.js 的 payload（含 videos[]）
    语义：窗口快照；一行一 content_id；biz_date 为窗口锚点日（不拆 7 日）
    content_id 必须来自 video-detail-item?id= 等稳定键；无 id 行跳过
  #>
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$Currency = 'GBP',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  if (-not $p) { Write-Output -NoEnumerate @(); return }

  $cur = $Currency
  if ($p.currency) { $cur = [string]$p.currency }
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }
  $channelDefault = 'short_video'
  if ($p.channelDefault) { $channelDefault = [string]$p.channelDefault }
  elseif ($p.channel) { $channelDefault = [string]$p.channel }

  $windowLabel = $null
  if ($p.window) { $windowLabel = [string]$p.window }
  elseif ($p.raw -and $p.raw.window) { $windowLabel = [string]$p.raw.window }

  $rows = @()
  if ($p.videos) { $rows = @($p.videos) }
  elseif ($p.Rows) { $rows = @($p.Rows) }

  foreach ($r in $rows) {
    $contentId = ''
    if ($r.contentId) { $contentId = [string]$r.contentId }
    elseif ($r.content_id) { $contentId = [string]$r.content_id }
    elseif ($r.videoId) { $contentId = [string]$r.videoId }
    elseif ($r.video_id) { $contentId = [string]$r.video_id }
    if (-not $contentId -and $r.href) {
      $href = [string]$r.href
      if ($href -match 'video-detail-item[^#]*[?&]id=(\d{6,})') { $contentId = $Matches[1] }
      elseif ($href -match '[?&](?:video_id|videoId|content_id|contentId)=(\d{6,})') { $contentId = $Matches[1] }
    }
    if (-not $contentId) { continue }

    $title = ''
    if ($r.title) { $title = [string]$r.title }
    elseif ($r.content_title) { $title = [string]$r.content_title }
    elseif ($r.contentTitle) { $title = [string]$r.contentTitle }

    $channel = $channelDefault
    if ($r.channel) { $channel = [string]$r.channel }
    if ([string]::IsNullOrWhiteSpace($channel)) { $channel = 'short_video' }

    $productId = $null
    if ($r.productId) { $productId = [string]$r.productId }
    elseif ($r.product_id) { $productId = [string]$r.product_id }
    elseif ($r.productRef -and ("$($r.productRef)" -match '\b(\d{10,})\b')) { $productId = $Matches[1] }

    $rowCur = $cur
    if ($r.currency) { $rowCur = [string]$r.currency }
    $rowSrc = $src
    if ($r.href) { $rowSrc = [string]$r.href }
    elseif ($r.sourceUrl) { $rowSrc = [string]$r.sourceUrl }

    $numGmv = $null; $numOrders = $null; $numUnits = $null
    $numPlay = $null; $numImpr = $null; $numClicks = $null
    $numCtr = $null; $numCvr = $null; $numCust = $null
    if ($null -ne $r.attributedGmv -and "$($r.attributedGmv)" -ne '') { try { $numGmv = [double]$r.attributedGmv } catch {} }
    elseif ($null -ne $r.attributed_gmv -and "$($r.attributed_gmv)" -ne '') { try { $numGmv = [double]$r.attributed_gmv } catch {} }
    if ($null -ne $r.attributedSkuOrders -and "$($r.attributedSkuOrders)" -ne '') { try { $numOrders = [double]$r.attributedSkuOrders } catch {} }
    elseif ($null -ne $r.attributed_sku_orders -and "$($r.attributed_sku_orders)" -ne '') { try { $numOrders = [double]$r.attributed_sku_orders } catch {} }
    if ($null -ne $r.attributedUnits -and "$($r.attributedUnits)" -ne '') { try { $numUnits = [double]$r.attributedUnits } catch {} }
    elseif ($null -ne $r.attributed_units -and "$($r.attributed_units)" -ne '') { try { $numUnits = [double]$r.attributed_units } catch {} }
    if ($null -ne $r.playCount -and "$($r.playCount)" -ne '') { try { $numPlay = [double]$r.playCount } catch {} }
    elseif ($null -ne $r.play_count -and "$($r.play_count)" -ne '') { try { $numPlay = [double]$r.play_count } catch {} }
    if ($null -ne $r.impressions -and "$($r.impressions)" -ne '') { try { $numImpr = [double]$r.impressions } catch {} }
    if ($null -ne $r.clicks -and "$($r.clicks)" -ne '') { try { $numClicks = [double]$r.clicks } catch {} }
    if ($null -ne $r.ctr -and "$($r.ctr)" -ne '') { try { $numCtr = [double]$r.ctr } catch {} }
    if ($null -ne $r.cvr -and "$($r.cvr)" -ne '') { try { $numCvr = [double]$r.cvr } catch {} }
    if ($null -ne $r.customers -and "$($r.customers)" -ne '') { try { $numCust = [double]$r.customers } catch {} }

    $body = @{
      content_id            = $contentId
      content_title         = $title
      channel               = $channel
      product_id            = $productId
      attributed_gmv        = $numGmv
      attributed_sku_orders = $numOrders
      attributed_units      = $numUnits
      play_count            = $numPlay
      impressions           = $numImpr
      clicks                = $numClicks
      ctr                   = $numCtr
      cvr                   = $numCvr
      customers             = $numCust
      currency              = $rowCur
      source_url            = $rowSrc
    }
    if ($windowLabel) { $body['window'] = $windowLabel }
    if ($r.publishedAt) { $body['published_at'] = [string]$r.publishedAt }
    elseif ($r.published_at) { $body['published_at'] = [string]$r.published_at }
    if ($r.rawCells) { $body['raw_cells'] = $r.rawCells }
    if ($p.raw -and $p.raw.tableHeaders) { $body['table_headers'] = $p.raw.tableHeaders }

    $idem = ("tiktok_content:{0}:{1}:{2}:{3}" -f $StoreId, $BizDate, $contentId, $channel)
    [void]$items.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $StoreId
      shop_name       = $StoreName
      biz_date        = $BizDate
      collected_at    = $CollectedAt
      idempotency_key = $idem
      payload         = $body
      evidence        = @{ source_url = $rowSrc }
    })
  }
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanAffiliateDailyIngestItems {
  <#
    P3.1 联盟表现·店级 → tiktok_affiliate_daily
    输入：scrape-affiliate-performance-page.js 的 payload（kpis + window）
    语义：近 N 天窗口快照；biz_date=锚点日；不拆 7 行
  #>
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$Currency = 'GBP',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  if (-not $p) { Write-Output -NoEnumerate @(); return }

  $cur = $Currency
  if ($p.currency) { $cur = [string]$p.currency }
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }

  $windowLabel = $null
  if ($p.window) { $windowLabel = [string]$p.window }
  elseif ($p.window_label) { $windowLabel = [string]$p.window_label }
  elseif ($p.raw -and $p.raw.window) { $windowLabel = [string]$p.raw.window }

  $k = $null
  if ($p.kpis) { $k = $p.kpis }
  $srcObj = if ($k) { $k } else { $p }

  # 内联取数，避免 PS5.1 嵌套 function 在某些宿主下重复定义
  $gmvA = $null; $ouA = $null; $refA = $null; $vidA = $null; $liveA = $null; $cpA = $null; $csA = $null; $commA = $null
  foreach ($pair in @(
    @{ n = @('gmvAffiliate','gmv_affiliate'); t = 'gmv' },
    @{ n = @('orderUnits','order_units'); t = 'ou' },
    @{ n = @('refundAmount','refund_amount'); t = 'ref' },
    @{ n = @('videoCnt','video_cnt'); t = 'vid' },
    @{ n = @('liveCnt','live_cnt'); t = 'live' },
    @{ n = @('creatorsPublished','creators_published'); t = 'cp' },
    @{ n = @('creatorsSold','creators_sold'); t = 'cs' },
    @{ n = @('estCommission','est_commission'); t = 'comm' }
  )) {
    $val = $null
    foreach ($nm in $pair.n) {
      if ($null -ne $srcObj.$nm -and "$($srcObj.$nm)" -ne '') {
        try { $val = [double]$srcObj.$nm } catch { $val = $null }
        break
      }
    }
    switch ($pair.t) {
      'gmv'  { $gmvA = $val }
      'ou'   { $ouA = $val }
      'ref'  { $refA = $val }
      'vid'  { $vidA = $val }
      'live' { $liveA = $val }
      'cp'   { $cpA = $val }
      'cs'   { $csA = $val }
      'comm' { $commA = $val }
    }
  }

  $body = @{
    window_label       = $windowLabel
    gmv_affiliate      = $gmvA
    order_units        = $ouA
    refund_amount      = $refA
    video_cnt          = $vidA
    live_cnt           = $liveA
    creators_published = $cpA
    creators_sold      = $csA
    est_commission     = $commA
    currency           = $cur
    source_url         = $src
  }
  if ($p.raw) { $body['raw'] = $p.raw }

  $winKey = if ($windowLabel) { ($windowLabel -replace '\s+', '') } else { '近7天' }
  $idem = ("tiktok_affiliate_daily:{0}:{1}:{2}" -f $StoreId, $BizDate, $winKey)
  [void]$items.Add([pscustomobject]@{
    platform        = 'tiktok'
    shop_id         = $StoreId
    shop_name       = $StoreName
    biz_date        = $BizDate
    collected_at    = $CollectedAt
    idempotency_key = $idem
    payload         = $body
    evidence        = @{ source_url = $src }
  })
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanAffiliateCreatorIngestItems {
  <#
    P3.1 联盟表现·达人行 → tiktok_affiliate_creator
    输入：scrape-affiliate-performance-page.js 的 payload.creators[]
    creator_id = handle（POC 门禁主键）；无 id/handle 行跳过
  #>
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$Currency = 'GBP',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  if (-not $p) { Write-Output -NoEnumerate @(); return }

  $cur = $Currency
  if ($p.currency) { $cur = [string]$p.currency }
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }

  $windowLabel = $null
  if ($p.window) { $windowLabel = [string]$p.window }
  elseif ($p.window_label) { $windowLabel = [string]$p.window_label }
  elseif ($p.raw -and $p.raw.window) { $windowLabel = [string]$p.raw.window }
  $winKey = if ($windowLabel) { ($windowLabel -replace '\s+', '') } else { '近7天' }

  $rows = @()
  if ($p.creators) { $rows = @($p.creators) }
  elseif ($p.Rows) { $rows = @($p.Rows) }

  # PS5.1：scriptblock 一次定义，循环内 & 调用（勿 function 嵌套）
  $toD = {
    param($v)
    if ($null -eq $v -or "$v" -eq '') { return $null }
    try { return [double]$v } catch { return $null }
  }

  foreach ($r in $rows) {
    $cid = ''
    if ($r.creatorId) { $cid = [string]$r.creatorId }
    elseif ($r.creator_id) { $cid = [string]$r.creator_id }
    elseif ($r.creatorHandle) { $cid = [string]$r.creatorHandle }
    elseif ($r.creator_handle) { $cid = [string]$r.creator_handle }
    elseif ($r.handle) { $cid = [string]$r.handle }
    if ([string]::IsNullOrWhiteSpace($cid)) { continue }

    $cname = $null
    if ($r.creatorName) { $cname = [string]$r.creatorName }
    elseif ($r.creator_name) { $cname = [string]$r.creator_name }

    $chandle = $null
    if ($r.creatorHandle) { $chandle = [string]$r.creatorHandle }
    elseif ($r.creator_handle) { $chandle = [string]$r.creator_handle }
    elseif ($r.handle) { $chandle = [string]$r.handle }
    if (-not $chandle) { $chandle = $cid }

    $rowCur = $cur
    if ($r.currency) { $rowCur = [string]$r.currency }
    $rowSrc = $src
    if ($r.href) { $rowSrc = [string]$r.href }

    $gmv = & $toD $(if ($null -ne $r.gmv) { $r.gmv } else { $r.gmvAffiliate })
    $ou = & $toD $(if ($null -ne $r.orderUnits) { $r.orderUnits } elseif ($null -ne $r.order_units) { $r.order_units } else { $null })
    $sold = $false
    if (($null -ne $gmv -and $gmv -gt 0) -or ($null -ne $ou -and $ou -gt 0)) { $sold = $true }

    $body = @{
      creator_id       = $cid
      creator_name     = $cname
      creator_handle   = $chandle
      window_label     = $windowLabel
      gmv              = $gmv
      order_units      = $ou
      orders_cnt       = (& $toD $(if ($null -ne $r.orders) { $r.orders } elseif ($null -ne $r.orders_cnt) { $r.orders_cnt } else { $r.ordersCnt }))
      refund_amount    = (& $toD $(if ($null -ne $r.refundAmount) { $r.refundAmount } else { $r.refund_amount }))
      refund_units     = (& $toD $(if ($null -ne $r.refundUnits) { $r.refundUnits } else { $r.refund_units }))
      est_commission   = (& $toD $(if ($null -ne $r.estCommission) { $r.estCommission } else { $r.est_commission }))
      video_cnt        = (& $toD $(if ($null -ne $r.videoCnt) { $r.videoCnt } else { $r.video_cnt }))
      live_cnt         = (& $toD $(if ($null -ne $r.liveCnt) { $r.liveCnt } else { $r.live_cnt }))
      product_sold     = (& $toD $(if ($null -ne $r.productSold) { $r.productSold } else { $r.product_sold }))
      samples_shipped  = (& $toD $(if ($null -ne $r.samplesShipped) { $r.samplesShipped } else { $r.samples_shipped }))
      video_views      = (& $toD $(if ($null -ne $r.videoViews) { $r.videoViews } else { $r.video_views }))
      cvr              = (& $toD $r.cvr)
      sold_flag        = $sold
      currency         = $rowCur
      source_url       = $rowSrc
    }
    if ($r.rawCells) { $body['raw_cells'] = $r.rawCells }
    if ($r.creatorCellRaw) { $body['creator_cell_raw'] = [string]$r.creatorCellRaw }
    elseif ($r.creator_cell_raw) { $body['creator_cell_raw'] = [string]$r.creator_cell_raw }

    $idem = ("tiktok_affiliate_creator:{0}:{1}:{2}:{3}" -f $StoreId, $BizDate, $winKey, $cid)
    [void]$items.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $StoreId
      shop_name       = $StoreName
      biz_date        = $BizDate
      collected_at    = $CollectedAt
      idempotency_key = $idem
      payload         = $body
      evidence        = @{ source_url = $rowSrc }
    })
  }
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanShopDailyIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$Currency = 'GBP',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  $cur = $Currency
  if ($p.currency) { $cur = [string]$p.currency }
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }
  $body = @{
    gmv            = $(if ($null -ne $p.gmv) { [double]$p.gmv } else { $null })
    orders_cnt     = $(if ($null -ne $p.ordersCnt) { [double]$p.ordersCnt } elseif ($null -ne $p.orders_cnt) { [double]$p.orders_cnt } else { $null })
    buyers_cnt     = $(if ($null -ne $p.buyersCnt) { [double]$p.buyersCnt } elseif ($null -ne $p.buyers_cnt) { [double]$p.buyers_cnt } else { $null })
    refund_amount  = $(if ($null -ne $p.refundAmount) { [double]$p.refundAmount } elseif ($null -ne $p.refund_amount) { [double]$p.refund_amount } else { $null })
    currency       = $cur
    source_url     = $src
  }
  if ($p.raw) { $body['scrape_raw'] = $p.raw }
  [void]$items.Add([pscustomobject]@{
    platform        = 'tiktok'
    shop_id         = $StoreId
    shop_name       = $StoreName
    biz_date        = $BizDate
    collected_at    = $CollectedAt
    idempotency_key = ("tiktok_shop_daily:{0}:{1}" -f $StoreId, $BizDate)
    payload         = $body
    evidence        = @{ source_url = $src }
  })
  # 返回 object[]；单元素也保持数组，避免解包成 Hashtable
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanHealthDailyIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }
  $body = @{
    health_score            = $(if ($null -ne $p.healthScore) { [double]$p.healthScore } elseif ($null -ne $p.health_score) { [double]$p.health_score } else { $null })
    late_dispatch_rate      = $(if ($null -ne $p.lateDispatchRate) { [double]$p.lateDispatchRate } elseif ($null -ne $p.late_dispatch_rate) { [double]$p.late_dispatch_rate } else { $null })
    negative_feedback_rate  = $(if ($null -ne $p.negativeFeedbackRate) { [double]$p.negativeFeedbackRate } elseif ($null -ne $p.negative_feedback_rate) { [double]$p.negative_feedback_rate } else { $null })
    status_label            = $(if ($p.statusLabel) { [string]$p.statusLabel } elseif ($p.status_label) { [string]$p.status_label } else { '' })
    source_url              = $src
  }
  if ($p.raw) { $body['scrape_raw'] = $p.raw }
  [void]$items.Add([pscustomobject]@{
    platform        = 'tiktok'
    shop_id         = $StoreId
    shop_name       = $StoreName
    biz_date        = $BizDate
    collected_at    = $CollectedAt
    idempotency_key = ("tiktok_health_daily:{0}:{1}" -f $StoreId, $BizDate)
    payload         = $body
    evidence        = @{ source_url = $src }
  })
  # 返回 object[]；单元素也保持数组，避免解包成 Hashtable
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanExperienceDailyIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }
  $metrics = @{}
  if ($p.metrics) {
    try { $metrics = $p.metrics } catch { $metrics = @{} }
  }
  $body = @{
    experience_score         = $(if ($null -ne $p.experienceScore) { [double]$p.experienceScore } elseif ($null -ne $p.experience_score) { [double]$p.experience_score } else { $null })
    product_satisfaction     = $(if ($null -ne $p.productSatisfaction) { [double]$p.productSatisfaction } elseif ($null -ne $p.product_satisfaction) { [double]$p.product_satisfaction } else { $null })
    fulfillment_score        = $(if ($null -ne $p.fulfillmentScore) { [double]$p.fulfillmentScore } elseif ($null -ne $p.fulfillment_score) { [double]$p.fulfillment_score } else { $null })
    customer_service_score   = $(if ($null -ne $p.customerServiceScore) { [double]$p.customerServiceScore } elseif ($null -ne $p.customer_service_score) { [double]$p.customer_service_score } else { $null })
    metrics_json             = $metrics
    source_url               = $src
  }
  if ($p.raw) { $body['scrape_raw'] = $p.raw }
  [void]$items.Add([pscustomobject]@{
    platform        = 'tiktok'
    shop_id         = $StoreId
    shop_name       = $StoreName
    biz_date        = $BizDate
    collected_at    = $CollectedAt
    idempotency_key = ("tiktok_experience_daily:{0}:{1}" -f $StoreId, $BizDate)
    payload         = $body
    evidence        = @{ source_url = $src }
  })
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanCreatorHealthIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$SourceUrl = ''
  )
  # 返回 hashtable: source -> items[]
  $healthItems = New-Object System.Collections.ArrayList
  $violItems = New-Object System.Collections.ArrayList
  $p = $Payload
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }

  $accounts = @()
  if ($p.accounts) { $accounts = @($p.accounts) }
  $selected = ''
  if ($p.selectedName) { $selected = [string]$p.selectedName }

  if ($accounts.Count -eq 0) {
    $ck = if ($selected) { $selected } else { 'default' }
    [void]$healthItems.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $StoreId
      shop_name       = $StoreName
      biz_date        = $BizDate
      collected_at    = $CollectedAt
      idempotency_key = ("tiktok_creator_health_daily:{0}:{1}:{2}" -f $StoreId, $ck, $BizDate)
      payload         = @{
        creator_key      = $ck
        creator_name     = $ck
        health_score     = $(if ($null -ne $p.healthScore) { [double]$p.healthScore } else { $null })
        status_label     = $(if ($p.statusLabel) { [string]$p.statusLabel } else { '' })
        violation_count  = $null
        source_url       = $src
        scrape_raw       = $(if ($p.raw) { $p.raw } else { $null })
      }
      evidence        = @{ source_url = $src }
    })
  } else {
    foreach ($acc in $accounts) {
      $name = ''
      if ($acc.name) { $name = [string]$acc.name } elseif ($acc.creator_name) { $name = [string]$acc.creator_name }
      if (-not $name) { continue }
      $role = ''
      if ($acc.role) { $role = [string]$acc.role }
      $vc = $null
      if ($null -ne $acc.violationCount) { $vc = [int]$acc.violationCount }
      elseif ($null -ne $acc.violation_count) { $vc = [int]$acc.violation_count }
      $score = $null
      # multi-account switch loop fills healthScore per account
      if ($null -ne $acc.healthScore) { $score = [double]$acc.healthScore }
      elseif ($null -ne $acc.health_score) { $score = [double]$acc.health_score }
      elseif ($selected -and ($name -eq $selected) -and $null -ne $p.healthScore) {
        $score = [double]$p.healthScore
      } elseif ($accounts.Count -eq 1 -and $null -ne $p.healthScore) {
        $score = [double]$p.healthScore
      }
      $st = ''
      if ($acc.statusLabel) { $st = [string]$acc.statusLabel }
      elseif ($p.statusLabel) { $st = [string]$p.statusLabel }
      [void]$healthItems.Add([pscustomobject]@{
        platform        = 'tiktok'
        shop_id         = $StoreId
        shop_name       = $StoreName
        biz_date        = $BizDate
        collected_at    = $CollectedAt
        idempotency_key = ("tiktok_creator_health_daily:{0}:{1}:{2}" -f $StoreId, $name, $BizDate)
        payload         = @{
          creator_key      = $name
          creator_name     = $name
          creator_role     = $role
          health_score     = $score
          status_label     = $st
          violation_count  = $vc
          source_url       = $src
        }
        evidence        = @{ source_url = $src }
      })
    }
  }

  function Add-CreatorViolItems([string]$Owner, $ViolList) {
    if (-not $ViolList) { return }
    foreach ($v in @($ViolList)) {
      $text = ''
      if ($v.text) { $text = [string]$v.text } elseif ($v.reason) { $text = [string]$v.reason }
      $vtype = ''
      if ($v.type) { $vtype = [string]$v.type }
      $vkey = ('{0}|{1}|{2}' -f $Owner, $vtype, $text).GetHashCode().ToString('x8')
      [void]$violItems.Add([pscustomobject]@{
        platform        = 'tiktok'
        shop_id         = $StoreId
        shop_name       = $StoreName
        biz_date        = $BizDate
        collected_at    = $CollectedAt
        idempotency_key = ("tiktok_creator_violation:{0}:{1}:{2}" -f $StoreId, $Owner, $vkey)
        payload         = @{
          creator_key    = $Owner
          creator_name   = $Owner
          violation_key  = $vkey
          violation_type = $vtype
          reason         = $text
          result_text    = ''
          status         = ''
          source_url     = $src
        }
        evidence        = @{ source_url = $src }
      })
    }
  }

  # multi-account switch: violations keyed by creator name.
  # PowerShell 侧补进去的是 Hashtable；若经 ConvertTo-Json 再读回来则是 PSCustomObject。
  # 必须先走 IDictionary，否则 Hashtable.PSObject.Properties 会把 Count/Keys/Values 当达人名。
  $mcv = $null
  if ($p.PSObject.Properties.Name -contains 'multiCreatorViolations') { $mcv = $p.multiCreatorViolations }
  if ($mcv) {
    if ($mcv -is [System.Collections.IDictionary]) {
      foreach ($k in @($mcv.Keys)) {
        Add-CreatorViolItems -Owner ([string]$k) -ViolList $mcv[$k]
      }
    } else {
      foreach ($prop in $mcv.PSObject.Properties) {
        if ($prop.MemberType -ne 'NoteProperty') { continue }
        Add-CreatorViolItems -Owner ([string]$prop.Name) -ViolList $prop.Value
      }
    }
  } else {
    $violations = @()
    if ($p.violations) { $violations = @($p.violations) }
    $owner = if ($selected) { $selected } elseif ($accounts.Count -gt 0 -and $accounts[0].name) { [string]$accounts[0].name } else { 'default' }
    Add-CreatorViolItems -Owner $owner -ViolList $violations
  }

  return @{
    tiktok_creator_health_daily = @($healthItems.ToArray())
    tiktok_creator_violation    = @($violItems.ToArray())
  }
}

function ConvertTo-QingquanFinanceDailyIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$Currency = 'GBP',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  $cur = $Currency
  if ($p.currency) { $cur = [string]$p.currency }
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }
  $body = @{
    settlement_amount = $(if ($null -ne $p.settlementAmount) { [double]$p.settlementAmount } elseif ($null -ne $p.settlement_amount) { [double]$p.settlement_amount } else { $null })
    pending_amount    = $(if ($null -ne $p.pendingAmount) { [double]$p.pendingAmount } elseif ($null -ne $p.pending_amount) { [double]$p.pending_amount } else { $null })
    refund_amount     = $(if ($null -ne $p.refundAmount) { [double]$p.refundAmount } elseif ($null -ne $p.refund_amount) { [double]$p.refund_amount } else { $null })
    currency          = $cur
    source_url        = $src
  }
  if ($p.raw) { $body['scrape_raw'] = $p.raw }
  [void]$items.Add([pscustomobject]@{
    platform        = 'tiktok'
    shop_id         = $StoreId
    shop_name       = $StoreName
    biz_date        = $BizDate
    collected_at    = $CollectedAt
    idempotency_key = ("tiktok_finance_daily:{0}:{1}" -f $StoreId, $BizDate)
    payload         = $body
    evidence        = @{ source_url = $src }
  })
  # 返回 object[]；单元素也保持数组，避免解包成 Hashtable
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanViolationIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }
  $rows = @()
  if ($p.rows) { $rows = @($p.rows) }
  elseif ($p.PSObject.Properties.Name -contains 'violationKey' -or $p.PSObject.Properties.Name -contains 'violation_key') {
    $rows = @($p)
  }
  # 空列表仍返回 0 items（调用方可 skip）；emptyOk 页不报错
  foreach ($r in $rows) {
    if ($null -eq $r) { continue }
    $vkey = ''
    if ($r.violationKey) { $vkey = [string]$r.violationKey }
    elseif ($r.violation_key) { $vkey = [string]$r.violation_key }
    elseif ($r.id) { $vkey = [string]$r.id }
    if ([string]::IsNullOrWhiteSpace($vkey)) { continue }
    $rowBiz = $BizDate
    if ($r.bizDate) { $rowBiz = [string]$r.bizDate }
    elseif ($r.biz_date) { $rowBiz = [string]$r.biz_date }
    $body = @{
      violation_key = $vkey
      penalty_text  = $(if ($r.penaltyText) { [string]$r.penaltyText } elseif ($r.penalty_text) { [string]$r.penalty_text } else { '' })
      penalty_score = $(if ($null -ne $r.penaltyScore) { [double]$r.penaltyScore } elseif ($null -ne $r.penalty_score) { [double]$r.penalty_score } else { $null })
      reason        = $(if ($r.reason) { [string]$r.reason } else { '' })
      status        = $(if ($r.status) { [string]$r.status } else { '' })
      violation_at  = $(if ($r.violationAt) { [string]$r.violationAt } elseif ($r.violation_at) { [string]$r.violation_at } else { $null })
      biz_date      = $rowBiz
      product_id    = $(if ($r.productId) { [string]$r.productId } elseif ($r.product_id) { [string]$r.product_id } else { $null })
      order_id      = $(if ($r.orderId) { [string]$r.orderId } elseif ($r.order_id) { [string]$r.order_id } else { $null })
      source_url    = $src
    }
    if ($r.rawText) { $body['raw_text'] = [string]$r.rawText }
    elseif ($r.raw_text) { $body['raw_text'] = [string]$r.raw_text }
    if ($r.rawCells) { $body['raw_cells'] = $r.rawCells }
    elseif ($r.raw_cells) { $body['raw_cells'] = $r.raw_cells }
    [void]$items.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $StoreId
      shop_name       = $StoreName
      biz_date        = $rowBiz
      collected_at    = $CollectedAt
      idempotency_key = ("tiktok_violation:{0}:{1}" -f $StoreId, $vkey)
      payload         = $body
      evidence        = @{ source_url = $src }
    })
  }
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanReviewIngestItems {
  param(
    [Parameter(Mandatory = $true)] $Payload,
    [Parameter(Mandatory = $true)] [string]$CollectedAt,
    [Parameter(Mandatory = $true)] [string]$StoreId,
    [Parameter(Mandatory = $true)] [string]$BizDate,
    [string]$StoreName = '',
    [string]$SourceUrl = ''
  )
  $items = New-Object System.Collections.ArrayList
  $p = $Payload
  $src = $SourceUrl
  if ($p.url) { $src = [string]$p.url }
  $rows = @()
  if ($p.rows) { $rows = @($p.rows) }
  elseif ($p.PSObject.Properties.Name -contains 'reviewKey' -or $p.PSObject.Properties.Name -contains 'review_key') {
    $rows = @($p)
  }
  foreach ($r in $rows) {
    if ($null -eq $r) { continue }
    $rkey = ''
    if ($r.reviewKey) { $rkey = [string]$r.reviewKey }
    elseif ($r.review_key) { $rkey = [string]$r.review_key }
    $orderId = $(if ($r.orderId) { [string]$r.orderId } elseif ($r.order_id) { [string]$r.order_id } else { '' })
    $productId = $(if ($r.productId) { [string]$r.productId } elseif ($r.product_id) { [string]$r.product_id } else { '' })
    if ([string]::IsNullOrWhiteSpace($rkey)) {
      if ($orderId -and $productId) { $rkey = "{0}:{1}" -f $orderId, $productId }
      elseif ($orderId) { $rkey = "o:{0}" -f $orderId }
      elseif ($productId) { $rkey = "p:{0}" -f $productId }
    }
    if ([string]::IsNullOrWhiteSpace($rkey)) { continue }
    $rowBiz = $BizDate
    if ($r.bizDate) { $rowBiz = [string]$r.bizDate }
    elseif ($r.biz_date) { $rowBiz = [string]$r.biz_date }
    $hasReply = $false
    if ($null -ne $r.hasReply) { $hasReply = [bool]$r.hasReply }
    elseif ($null -ne $r.has_reply) { $hasReply = [bool]$r.has_reply }
    elseif ($r.replyText -or $r.reply_text) { $hasReply = $true }
    $body = @{
      review_key   = $rkey
      order_id     = $(if ($orderId) { $orderId } else { $null })
      product_id   = $(if ($productId) { $productId } else { $null })
      product_name = $(if ($r.productName) { [string]$r.productName } elseif ($r.product_name) { [string]$r.product_name } else { $null })
      rating       = $(if ($null -ne $r.rating) { [double]$r.rating } elseif ($null -ne $r.stars) { [double]$r.stars } else { $null })
      review_text  = $(if ($r.reviewText) { [string]$r.reviewText } elseif ($r.review_text) { [string]$r.review_text } else { '' })
      review_at    = $(if ($r.reviewAt) { [string]$r.reviewAt } elseif ($r.review_at) { [string]$r.review_at } else { $null })
      biz_date     = $rowBiz
      buyer_name   = $(if ($r.buyerName) { [string]$r.buyerName } elseif ($r.buyer_name) { [string]$r.buyer_name } else { $null })
      reply_text   = $(if ($r.replyText) { [string]$r.replyText } elseif ($r.reply_text) { [string]$r.reply_text } else { $null })
      reply_at     = $(if ($r.replyAt) { [string]$r.replyAt } elseif ($r.reply_at) { [string]$r.reply_at } else { $null })
      has_reply    = $hasReply
      source_url   = $src
    }
    if ($r.rawText) { $body['raw_text'] = [string]$r.rawText }
    elseif ($r.raw_text) { $body['raw_text'] = [string]$r.raw_text }
    [void]$items.Add([pscustomobject]@{
      platform        = 'tiktok'
      shop_id         = $StoreId
      shop_name       = $StoreName
      biz_date        = $rowBiz
      collected_at    = $CollectedAt
      idempotency_key = ("tiktok_review:{0}:{1}" -f $StoreId, $rkey)
      payload         = $body
      evidence        = @{ source_url = $src }
    })
  }
  Write-Output -NoEnumerate @($items.ToArray())
}

function ConvertTo-QingquanIngestJson {
  param([Parameter(Mandatory = $true)] $Items)
  $list = Get-QingquanItemList $Items
  if ($list.Count -eq 0) {
    throw 'qingquan payload has 0 items'
  }

  try {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 50MB
    $payload = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $payload['items'] = $list.ToArray()
    $json = $ser.Serialize($payload)
  } catch {
    $parts = New-Object System.Collections.ArrayList
    foreach ($it in $list) {
      $piece = ($it | ConvertTo-Json -Depth 12 -Compress)
      [void]$parts.Add($piece)
    }
    $json = '{"items":[' + ($parts -join ',') + ']}'
  }

  if ([string]::IsNullOrWhiteSpace($json) -or $json -notmatch '"items"\s*:\s*\[') {
    $preview = ''
    if ($json) { $preview = $json.Substring(0, [Math]::Min(120, $json.Length)) }
    $len = 0
    if ($json) { $len = $json.Length }
    throw ("qingquan payload json invalid (len={0}): {1}" -f $len, $preview)
  }
  if ($json -match '"items"\s*:\s*\[\s*\]') {
    throw 'qingquan payload items array is empty after serialize'
  }
  return $json
}

function Send-QingquanIngest {
  param(
    [Parameter(Mandatory = $true)] $Config,
    [Parameter(Mandatory = $true)] $Items,
    [string]$Source = '',
    [switch]$Quiet
  )
  $q = Get-QingquanConfig $Config
  if (-not $q.enabled) {
    return [pscustomobject]@{ ok = $true; skipped = $true; reason = 'qingquan.disabled'; accepted = 0; duplicated = 0; failed = 0 }
  }
  if (-not $q.apiKey) {
    $msg = 'qingquan.apiKey empty'
    if ($q.failOpen) {
      if (-not $Quiet) { Write-Warning $msg }
      return [pscustomobject]@{ ok = $false; skipped = $false; error = $msg; accepted = 0; duplicated = 0; failed = 0 }
    }
    throw $msg
  }

  $itemList = Get-QingquanItemList $Items
  if ($itemList.Count -eq 0) {
    return [pscustomobject]@{ ok = $true; skipped = $true; reason = 'empty-items'; accepted = 0; duplicated = 0; failed = 0 }
  }

  # 大批量（订单 400 行 refresh）单请求易超时；按批发送并汇总
  $batchSize = 80
  if ($itemList.Count -gt 120) { $batchSize = 50 }
  $chunks = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $itemList.Count; $i += $batchSize) {
    $end = [Math]::Min($i + $batchSize - 1, $itemList.Count - 1)
    $chunk = New-Object System.Collections.ArrayList
    for ($j = $i; $j -le $end; $j++) { [void]$chunk.Add($itemList[$j]) }
    # 关键：不要把单元素 ArrayList 直接当 $Items 传——PS 会解包成 Hashtable，
    # Get-QingquanItemList 再按字典 key 枚举 → 0 items → 假成功 accepted=0
    [void]$chunks.Add(@($chunk.ToArray()))
  }

  $totAccepted = 0; $totDup = 0; $totFailed = 0; $lastErr = $null; $anyOk = $false
  $idx = 0
  # 2026-08-20：curl schannel 在大 POST + 连续请求下偶发 (56) server closed abruptly，
  # curl 自带 --retry 对 mid-transfer 错误覆盖不全。此处加 PS 层重试：传输类失败间隔重发。
  $maxAttempts = 3
  foreach ($chunk in $chunks) {
    $idx++
    $n = @($chunk).Count
    if ($chunks.Count -gt 1 -and -not $Quiet) {
      Write-Host ("  qingquan batch {0}/{1} items={2}" -f $idx, $chunks.Count, $n)
    }
    $one = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
      $one = Send-QingquanIngestBatch -Config $Config -Items $chunk -Source $Source -Quiet:$Quiet -TimeoutSecOverride $(if ($n -gt 40) { 90 } else { 0 })
      if ($one.ok) { break }
      # 仅对传输/网络类错误重试（schannel 56、timeout、connect-failed、empty response）；
      # 4xx 业务错误（apiKey/字段）重试无意义，直接跳出。
      $isTransport = $false
      if ($one.error) {
        $e = [string]$one.error
        if ($e -match 'schannel|closed abruptly|missing close_notify|connect|timeout|timed out|empty|network|Failed to receive|curl failed|HTTP 5\d\d') {
          $isTransport = $true
        }
      }
      if (-not $isTransport) { break }
      if ($attempt -lt $maxAttempts) {
        $backoff = 5 + ($attempt - 1) * 5   # 5s, 10s
        if (-not $Quiet) {
          Write-Host ("  qingquan batch {0} 传输失败(attempt {1}/{2})，{3}s 后重试：{4}" -f $idx, $attempt, $maxAttempts, $backoff, $one.error)
        }
        Start-Sleep -Seconds $backoff
      }
    }
    if ($one.ok) { $anyOk = $true }
    $totAccepted += [int]$one.accepted
    $totDup += [int]$one.duplicated
    $totFailed += [int]$one.failed
    if ($one.error) { $lastErr = [string]$one.error }
  }
  return [pscustomobject]@{
    ok = $anyOk -or ($totFailed -eq 0)
    skipped = $false
    accepted = $totAccepted
    duplicated = $totDup
    failed = $totFailed
    error = $lastErr
  }
}

function Send-QingquanIngestBatch {
  param(
    [Parameter(Mandatory = $true)] $Config,
    [Parameter(Mandatory = $true)] $Items,
    [string]$Source = '',
    [switch]$Quiet,
    [int]$TimeoutSecOverride = 0
  )
  $q = Get-QingquanConfig $Config
  if (-not $q.enabled) {
    return [pscustomobject]@{ ok = $true; skipped = $true; reason = 'qingquan.disabled'; accepted = 0; duplicated = 0; failed = 0 }
  }
  if (-not $q.apiKey) {
    $msg = 'qingquan.apiKey empty'
    if ($q.failOpen) {
      if (-not $Quiet) { Write-Warning $msg }
      return [pscustomobject]@{ ok = $false; skipped = $false; error = $msg; accepted = 0; duplicated = 0; failed = 0 }
    }
    throw $msg
  }

  $itemList = Get-QingquanItemList $Items
  if ($itemList.Count -eq 0) {
    return [pscustomobject]@{ ok = $true; skipped = $true; reason = 'empty-items'; accepted = 0; duplicated = 0; failed = 0 }
  }

  $useSource = $q.source
  if (-not [string]::IsNullOrWhiteSpace($Source)) { $useSource = $Source.Trim() }
  $url = "{0}/api/v1/ingest/{1}" -f $q.baseUrl, $useSource
  try {
    $json = ConvertTo-QingquanIngestJson -Items $itemList
  } catch {
    $msg = [string]$_
    if ($q.failOpen) {
      if (-not $Quiet) { Write-Warning $msg }
      return [pscustomobject]@{ ok = $false; skipped = $false; error = $msg; accepted = 0; duplicated = 0; failed = $itemList.Count }
    }
    throw
  }

  $utf8 = New-Object System.Text.UTF8Encoding $false
  $bodyBytes = $utf8.GetBytes($json)
  if ($bodyBytes.Length -lt 10) {
    $msg = ("qingquan body too short: {0} bytes" -f $bodyBytes.Length)
    if ($q.failOpen) {
      if (-not $Quiet) { Write-Warning $msg }
      return [pscustomobject]@{ ok = $false; skipped = $false; error = $msg; accepted = 0; duplicated = 0; failed = $itemList.Count }
    }
    throw $msg
  }

  $timeoutSec = [Math]::Max(10, [int]$q.timeoutSec)
  if ($TimeoutSecOverride -gt 0) { $timeoutSec = [Math]::Max($timeoutSec, $TimeoutSecOverride) }

  try {
    $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    $text = $null
    $httpCode = 0
    if ($curlCmd) {
      $tmp = [System.IO.Path]::GetTempFileName()
      try {
        [System.IO.File]::WriteAllBytes($tmp, $bodyBytes)
        $outFile = [System.IO.Path]::GetTempFileName()
        try {
          $curlArgs = @(
            '-sS', '-X', 'POST', $url,
            '-H', 'Content-Type: application/json; charset=utf-8',
            '-H', ("X-Api-Key: {0}" -f $q.apiKey),
            '--data-binary', ("@{0}" -f $tmp),
            '-o', $outFile,
            '-w', '%{http_code}',
            '--connect-timeout', '30',
            '--max-time', ([string]$timeoutSec),
            '--retry', '2',
            '--retry-delay', '2',
            '--retry-all-errors'
          )
          $httpCodeStr = & curl.exe @curlArgs 2>&1
          if ($LASTEXITCODE -ne 0 -and -not (Test-Path $outFile)) {
            throw ("curl failed: {0}" -f $httpCodeStr)
          }
          if ($httpCodeStr -match '(\d{3})\s*$') { $httpCode = [int]$Matches[1] }
          elseif ("$httpCodeStr" -match '^\d{3}$') { $httpCode = [int]$httpCodeStr }
          $text = [System.IO.File]::ReadAllText($outFile, $utf8)
          if ($httpCode -ge 400) {
            throw ("HTTP {0}: {1}" -f $httpCode, $text)
          }
        } finally {
          Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        }
      } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      }
    } else {
      $req = [System.Net.HttpWebRequest]::Create($url)
      $req.Method = 'POST'
      $req.Timeout = [Math]::Max(5000, [int]($timeoutSec * 1000))
      $req.ReadWriteTimeout = $req.Timeout
      $req.ContentType = 'application/json; charset=utf-8'
      $req.Accept = 'application/json'
      $req.Headers.Add('X-Api-Key', $q.apiKey)
      $req.ContentLength = $bodyBytes.Length
      $req.ServicePoint.Expect100Continue = $false
      $stream = $req.GetRequestStream()
      try { $stream.Write($bodyBytes, 0, $bodyBytes.Length) } finally { $stream.Close() }

      $httpResp = $req.GetResponse()
      try {
        $httpCode = [int]$httpResp.StatusCode
        $reader = New-Object System.IO.StreamReader($httpResp.GetResponseStream(), $utf8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
      } finally { $httpResp.Close() }
    }

    $resp = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      try { $resp = $text | ConvertFrom-Json } catch { $resp = $null }
    }
    $accepted = 0; $duplicated = 0; $failed = 0
    if ($null -ne $resp -and $null -ne $resp.accepted) { $accepted = [int]$resp.accepted }
    if ($null -ne $resp -and $null -ne $resp.duplicated) { $duplicated = [int]$resp.duplicated }
    if ($null -ne $resp -and $null -ne $resp.failed) { $failed = [int]$resp.failed }
    return [pscustomobject]@{
      ok         = ($failed -eq 0)
      skipped    = $false
      accepted   = $accepted
      duplicated = $duplicated
      failed     = $failed
      resp       = $resp
      error      = $null
      httpCode   = $httpCode
      bodyBytes  = $bodyBytes.Length
    }
  }
  catch {
    $err = [string]$_
    $statusCode = 0
    try {
      $ex = $_.Exception
      while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
      if ($ex -is [System.Net.WebException] -and $ex.Response) {
        $statusCode = [int]$ex.Response.StatusCode
        $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream(), $utf8)
        $bodyErr = $sr.ReadToEnd()
        $sr.Close()
        if ($bodyErr) { $err = ("HTTP {0}: {1}" -f $statusCode, $bodyErr) }
      }
    } catch {}
    if ($err -match 'API Key|401') {
      $err = $err + ' | check stores.config.json qingquan.apiKey == server INGEST_DEFAULT_API_KEY'
    }
    if ($err -match 'Field required' -and $err -match 'body') {
      $err = $err + (" | local bodyBytes={0} url={1}" -f $bodyBytes.Length, $url)
    }
    if ($q.failOpen) {
      if (-not $Quiet) { Write-Warning ("qingquan ingest failed (failOpen): {0}" -f $err) }
      return [pscustomobject]@{
        ok         = $false
        skipped    = $false
        accepted   = 0
        duplicated = 0
        failed     = $itemList.Count
        resp       = $null
        error      = $err
        httpCode   = $statusCode
        bodyBytes  = $bodyBytes.Length
      }
    }
    throw
  }
}

function Test-QingquanHealth {
  param([Parameter(Mandatory = $true)] $Config)
  $q = Get-QingquanConfig $Config
  $url = "{0}/health" -f $q.baseUrl
  try {
    $r = Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 10
    return [pscustomobject]@{ ok = ($r.status -eq 'ok'); resp = $r; error = $null }
  }
  catch {
    return [pscustomobject]@{ ok = $false; resp = $null; error = [string]$_ }
  }
}
