# Daily shop-modules wrapper (Windows Task Scheduler) — 08:10 全量串行
# 主配置全店，5 段串行（单 Bridge 零冲突，loop 避 08:00~11:30 让整段）：
#   1. 整站 7 模块  run-shop-modules.ps1        (KPI/健康/体验/财务/违规/差评/达人健康)
#   2. 订单         run-orders.ps1             (方案2 只抓昨天)
#   3. 商品         run-products.ps1           (全店商品卡)
#   4. 内容         run-content-poc.ps1        (video_list + product_traffic，强制入库)
#   5. 联盟         run-affiliate-poc.ps1      (enter_center + performance，强制入库)
# 使用 config\stores.config.json 的 filter（TikTok + requireIp 等），不绑死单店。
# 只写清泉 Ingest，不写飞书。各段失败不阻断后续段（各自记 exit，任一非0则整体非0）。
#
# 2026-08-21：原独立夜间任务已全部删除并入本 wrapper 串行——
#   TK-Orders-Daily(20:00)、TK-Products-Daily(20:20)、TK-Content-Daily(20:40)、
#   TK-Affiliate-Daily(20:55)。整站挪早上08:10，运营上午就能看昨天数据，不用等深夜。
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daily.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daily.ps1 -Modules shop_daily,health_daily
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daily.ps1 -SkipOrders
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daily.ps1 -SkipModules        # 跳整站
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daily.ps1 -SkipProducts      # 跳商品
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daily.ps1 -SkipContent       # 跳内容
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daily.ps1 -SkipAffiliate     # 跳联盟

param(
  [string]$ConfigPath = "",
  [string]$Modules = "shop_daily,health_daily,experience_daily,finance_daily,violation,reviews,creator_health",
  [switch]$SkipModules,    # 跳过整站
  [switch]$SkipOrders,     # 跳过订单
  [switch]$SkipProducts,   # 跳过商品
  [switch]$SkipContent,    # 跳过内容
  [switch]$SkipAffiliate   # 跳过联盟
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "shop-modules-daily-$stamp.log"

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

Log "===== TK Shop-Modules Daily START ====="
Log "root=$root"
Log "log=$logFile"
Log "modules=$Modules"

Set-Location $root

if (-not $ConfigPath) {
  $ConfigPath = Join-Path $root 'config\stores.config.json'
}
if (-not (Test-Path $ConfigPath)) {
  Log "FATAL missing config $ConfigPath"
  exit 1
}
Log "config=$ConfigPath"
Log "segments: shop-modules=$(-not $SkipModules) orders=$(-not $SkipOrders) products=$(-not $SkipProducts) content=$(-not $SkipContent) affiliate=$(-not $SkipAffiliate)"

# 通用：hidden child PS 跑一个子脚本，stdout/stderr 行写入 wrapper 日志，返回退出码。
function Invoke-ChildScript([string]$childPath, [string]$argString) {
  if (-not (Test-Path $childPath)) { Log "FATAL missing $childPath"; return 1 }
  Log "invoke $([System.IO.Path]::GetFileName($childPath)) $argString (hidden child)"
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command powershell.exe).Source
  $psi.Arguments = @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$childPath`"",
    '-ConfigPath', "`"$ConfigPath`"",
    $argString
  ) -join ' '
  $psi.WorkingDirectory = $root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  $code = $p.ExitCode

  if ($stdout) {
    foreach ($line in ($stdout -split "`r?`n")) {
      if ($line.Length -gt 0) { Log "OUT $line" }
    }
  }
  if ($stderr) {
    foreach ($line in ($stderr -split "`r?`n")) {
      if ($line.Length -gt 0) { Log "ERR $line" }
    }
  }
  Log "exitCode=$code ($([System.IO.Path]::GetFileName($childPath)))"
  return $code
}

# —— 第1段：整站 7 模块 ——
$modulesCode = 0
if ($SkipModules) {
  Log "SKIP shop-modules (-SkipModules)"
} else {
  Log "===== SEGMENT 1: shop-modules ($Modules) ====="
  $modulesCode = Invoke-ChildScript (Join-Path $root 'scripts\run-shop-modules.ps1') "-DryRun false -Modules `"$Modules`""
}

# —— 第2段：订单（方案2 只抓昨天）——
# 整站失败不阻断订单：两个子脚本各用 Bridge，串行天然互斥，互不影响。
$ordersCode = 0
if ($SkipOrders) {
  Log "SKIP orders (-SkipOrders)"
} else {
  Log "===== SEGMENT 2: orders (onlyYesterday) ====="
  $ordersCode = Invoke-ChildScript (Join-Path $root 'scripts\run-orders.ps1') '-DryRun false'
}

# —— 第3段：商品（全店商品卡）——
$productsCode = 0
if ($SkipProducts) {
  Log "SKIP products (-SkipProducts)"
} else {
  Log "===== SEGMENT 3: products ====="
  $productsCode = Invoke-ChildScript (Join-Path $root 'scripts\run-products.ps1') '-DryRun false'
}

# —— 第4段：内容（video_list + product_traffic，强制入库）——
# run-content-poc.ps1 默认 SkipIngest=true 且默认模块含 content_overview；日更必须显式
# 指定 -Modules video_list,product_traffic + -SkipIngest false，否则跑错模块且不入库。
$contentCode = 0
if ($SkipContent) {
  Log "SKIP content (-SkipContent)"
} else {
  Log "===== SEGMENT 4: content (video_list+product_traffic) ====="
  $contentCode = Invoke-ChildScript (Join-Path $root 'scripts\run-content-poc.ps1') '-DryRun false -Modules "video_list,product_traffic" -SkipIngest false'
}

# —— 第5段：联盟（enter_center + performance，强制入库）——
# run-affiliate-poc.ps1 默认模块含 affiliate_probe 且默认 SkipIngest=true；日更必须显式
# 指定 -Modules affiliate_enter_center,affiliate_performance + -SkipIngest false。
$affiliateCode = 0
if ($SkipAffiliate) {
  Log "SKIP affiliate (-SkipAffiliate)"
} else {
  Log "===== SEGMENT 5: affiliate (enter_center+performance) ====="
  $affiliateCode = Invoke-ChildScript (Join-Path $root 'scripts\run-affiliate-poc.ps1') '-DryRun false -Modules "affiliate_enter_center,affiliate_performance" -SkipIngest false'
}

Log "summary: shop-modules exit=$modulesCode, orders exit=$ordersCode, products exit=$productsCode, content exit=$contentCode, affiliate exit=$affiliateCode"
Log "===== TK Shop-Modules Daily END ====="
# 任一段失败即整体非0（计划任务 Last Result 能看出异常）；全段都成功才 0
if ($modulesCode -ne 0 -or $ordersCode -ne 0 -or $productsCode -ne 0 -or $contentCode -ne 0 -or $affiliateCode -ne 0) { exit 1 }
exit 0
