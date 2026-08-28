# 探针：在 Gardena(EU) 店的 compass 上枚举商品数据分析子 tab，找 product 粒度页面。
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-eu-product-tabs.ps1
param(
  [string]$ConfigPath = 'config\stores.config.gardena-only.json',
  [string]$StoreId = '27758103898326'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
Set-Location $root

function Initialize-ZiniaoCli {
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
function ConvertTo-ProcessArgument([string]$arg) {
  # 简化：含空格/特殊字符则双引号包裹并把内部双引号转义
  if ($arg -match '\s|"') { return '"' + ($arg -replace '"','\"') + '"' }
  return $arg
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
function Get-ScrapePayload([string]$execOut) {
  if ([string]::IsNullOrWhiteSpace($execOut)) { return $null }
  try {
    $j = $execOut | ConvertFrom-Json
    if ($j.data -and $j.data.data -and $j.data.data.result) {
      try { return ($j.data.data.result | ConvertFrom-Json) } catch { return $null }
    }
    if ($j.data -and $j.data.result) {
      try { return ($j.data.result | ConvertFrom-Json) } catch { return $null }
    }
    if ($j.result) { try { return ($j.result | ConvertFrom-Json) } catch {} }
    return $j
  } catch { return $null }
}
function ToOneLine([string]$js) {
  return (($js -replace '(?m)^\s*//.*$', '' -replace '\r?\n', ' ' -replace '\s+', ' ').Trim())
}

# ---- main ----
$probeJs = ToOneLine (Get-Content -Raw (Join-Path $here 'probe-eu-product-tabs.js'))
# debug: dump the actual one-liner we will send
$probeDump = Join-Path $here ('probe-eu-oneliner-' + (Get-Date -Format yyyyMMddHHmmss) + '.js')
try { [System.IO.File]::WriteAllText($probeDump, $probeJs, [System.Text.UTF8Encoding]::new($false)); Write-Host "oneliner saved: $probeDump" } catch {}
Write-Host ("oneliner len={0}" -f $probeJs.Length)
$urls = @(
  'https://seller.eu.tiktokshopglobalselling.com/compass/product-analysis?shop_region=GB',
  'https://seller.eu.tiktokshopglobalselling.com/compass/product-traffic-analysis?shop_region=GB',
  'https://seller.eu.tiktokshopglobalselling.com/compass/shop-tab?shop_region=GB'
)

Write-Host "open store $StoreId ..."
$openOut = Invoke-Ziniao @('store','open','--id',$StoreId,'--url',$urls[0])
Write-Host $openOut
Start-Sleep -Seconds 10

foreach ($u in $urls) {
  Write-Host ""
  Write-Host "==== visit: $u ===="
  try { Invoke-Ziniao @('page','visit','--store-id',$StoreId,'--url',$u,'--wait-until','load','--timeout','120000') | Out-Null } catch { Write-Host "visit err: $_" }
  Start-Sleep -Seconds 12
  $execOut = Invoke-Ziniao @('page','exec','--store-id',$StoreId,'--script',$probeJs,'--timeout','60000')
  $payload = Get-ScrapePayload $execOut
  if ($payload) {
    Write-Host ("url={0}" -f $payload.url)
    Write-Host "tabs:"
    foreach ($t in $payload.tabs) { Write-Host ("  {0} -> {1}" -f $t.label, $t.href) }
    Write-Host "tables:"
    foreach ($tb in $payload.tables) {
      Write-Host ("  headers=[{0}] rows={1} parentClass={2}" -f (($tb.headers) -join ' | '), $tb.rowCount, $tb.parentClass)
      Write-Host ("    firstRow: {0}" -f (($tb.firstRowSample) -join ' | '))
    }
  } else {
    Write-Host "no payload; raw(600): $($execOut.Substring(0,[Math]::Min(600,$execOut.Length)))"
  }
  Write-Host ("raw-exec-len={0}" -f $execOut.Length)
  $rawFile = Join-Path $here ("probe-eu-raw-$([System.IO.Path]::GetFileName($u))-$(Get-Date -Format yyyyMMddHHmmss).txt")
  try { [System.IO.File]::WriteAllText($rawFile, $execOut, [System.Text.UTF8Encoding]::new($false)); Write-Host "raw saved: $rawFile" } catch {}
}

try { Invoke-Ziniao @('store','close','--id',$StoreId) | Out-Null } catch {}
Write-Host "`ndone."
