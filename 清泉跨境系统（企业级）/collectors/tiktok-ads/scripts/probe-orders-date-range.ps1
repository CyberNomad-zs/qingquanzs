# 探针：验证 set-date-range.js 能否在订单页选中「昨天」。
# 不翻页、不进详情、不入库——只 visit 订单页 + 跑 set-date-range 的 status/open/pick/status。
# 用法（挑订单任务跑完、白天 loop sleep 的间隙跑，避免抢 Bridge）：
#   powershell -ExecutionPolicy Bypass -File .\scripts\probe-orders-date-range.ps1 -StoreId 27758103898326
#   powershell -ExecutionPolicy Bypass -File .\scripts\probe-orders-date-range.ps1 -StoreId 27758103898326 -DateMode today
param(
  [Parameter(Mandatory = $true)][string]$StoreId,
  [string]$DateMode = 'yesterday',
  [string]$ConfigPath = ''
)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\stores.config.json' }
. (Join-Path $PSScriptRoot 'qingquan-client.ps1')
. (Join-Path $PSScriptRoot 'ziniao-window.ps1')

function ConvertTo-ScrapeOneLine([string]$js) {
  return (($js -replace '(?m)^\s*//.*$', '' -replace '\r?\n', ' ' -replace '\s+', ' ').Trim())
}
function Get-ScrapePayload([string]$execOut) {
  if ([string]::IsNullOrWhiteSpace($execOut)) { return $null }
  try {
    $j = $execOut | ConvertFrom-Json
    if ($j.data -and $j.data.data -and $j.data.data.result) { return ([string]$j.data.data.result | ConvertFrom-Json) }
    if ($null -ne $j.ok) { return $j }
  } catch { }
  $m = [regex]::Matches($execOut, '\{(?:[^{}]|(?<o>\{)|(?<-o>\}))+(?(o)(?!))\}')
  if ($m.Count -gt 0) { try { return ($m[$m.Count - 1].Value | ConvertFrom-Json) } catch { } }
  return $null
}
function Invoke-Ziniao([string[]]$CliArgs) {
  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  $runJs = Join-Path $env:APPDATA 'npm\node_modules\@ziniao-open\cli\scripts\run.js'
  if (-not (Test-Path $runJs)) { $cmd = Get-Command ziniao -ErrorAction SilentlyContinue; if ($cmd) { $runJs = $cmd.Source } }
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  $allArgs = @($runJs) + @($CliArgs)
  $argLine = ($allArgs | ForEach-Object { if ($null -eq $_) { '""' } elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $node; $psi.Arguments = $argLine; $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
  $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi; [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  if ($stderr) { Write-Host $stderr }
  return $stdout
}

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$dateRangeJs = Get-Content (Join-Path $root 'scripts\set-date-range.js') -Raw -Encoding UTF8

# 拿这个店的订单 URL（按平台匹配 orderUrl.byPlatform，否则 default）
$listOut = Invoke-Ziniao @('store', 'list')
$storesObj = $listOut | ConvertFrom-Json
$all = @()
if ($storesObj.data) {
  if ($storesObj.data.items) { $all = @($storesObj.data.items) }
  elseif ($storesObj.data -is [System.Array]) { $all = @($storesObj.data) }
}
$store = $all | Where-Object { [string]$_.storeId -eq $StoreId }
if (-not $store) { Write-Host "store $StoreId not found"; exit 1 }
$plat = ''; if ($store.platformName) { $plat = [string]$store.platformName } elseif ($store.platform) { $plat = [string]$store.platform }
$orderUrl = 'https://seller-uk.tiktok.com/order?selected_sort=6&tab=all'
if ($cfg.orderUrl -and $cfg.orderUrl.byPlatform -and $plat) {
  foreach ($p in $cfg.orderUrl.byPlatform.PSObject.Properties) {
    if ($plat -eq [string]$p.Name -or $plat -like ("*{0}*" -f $p.Name)) { $orderUrl = [string]$p.Value; break }
  }
}
if ($cfg.orderUrl -and $cfg.orderUrl.default) { $orderUrl = [string]$cfg.orderUrl.default }

Write-Host "store=$StoreId orderUrl=$orderUrl dateMode=$DateMode"
$openArgs = New-ZiniaoStoreOpenArgs -StoreId $StoreId -Url $orderUrl -Config $cfg
Write-Host (Invoke-Ziniao $openArgs)
Start-Sleep -Seconds 20
$null = Invoke-Ziniao @('page', 'visit', '--store-id', $StoreId, '--url', $orderUrl, '--wait-until', 'networkidle', '--timeout', '90000')
Start-Sleep -Seconds 8

function Run-DateAction([string]$action, [int]$timeoutMs) {
  $js = $dateRangeJs.Replace('__DATE_MODE__', $DateMode).Replace('__ACTION__', $action)
  $line = ConvertTo-ScrapeOneLine $js
  $out = Invoke-Ziniao @('page', 'exec', '--store-id', $StoreId, '--script', $line, '--timeout', ([string]$timeoutMs))
  return (Get-ScrapePayload $out)
}

Write-Host "--- status ---"
$st = Run-DateAction 'status' 15000
$st | ConvertTo-Json -Depth 6
Write-Host "--- open ---"
$op = Run-DateAction 'open' 20000
$op | ConvertTo-Json -Depth 6
Start-Sleep -Milliseconds 600
Write-Host "--- pick ---"
$pk = Run-DateAction 'pick' 20000
$pk | ConvertTo-Json -Depth 6
Start-Sleep -Seconds 8
Write-Host "--- status after pick ---"
$st2 = Run-DateAction 'status' 15000
$st2 | ConvertTo-Json -Depth 6
if ($st2 -and $st2.matched) { Write-Host "RESULT: OK — date range set to $DateMode" }
else { Write-Host "RESULT: NOT_CONFIRMED — date picker may not exist on orders page, or DOM differs" }
