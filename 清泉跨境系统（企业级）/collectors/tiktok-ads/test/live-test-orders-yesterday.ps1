# 方案2 真机小测：对 KK Seagull 订单页 scrape page1，看真实 createTime 文本 + 换算结果。
# 只 visit + scrape 1 页，不翻页不进详情不入库。确认真实数据走通即可。
# powershell -ExecutionPolicy Bypass -File .\test\live-test-orders-yesterday.ps1 -StoreId 27328767468273

param([Parameter(Mandatory=$true)][string]$StoreId)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
# 复用换算函数（已 BOM）
. (Join-Path $PSScriptRoot 'test-ordertime-parsing.ps1') *>$null
function Test-OrderDateRange {
  param([string]$CreateTime, $UKToday)
  $date = Convert-OrderTimeToDate -Raw $CreateTime
  $yest = $UKToday.AddDays(-1)
  if ($null -eq $date) { return @{ keep=$true; beforeYesterday=$false; date=$null } }
  return @{ keep=($date.Date -eq $yest.Date); beforeYesterday=($date.Date -lt $yest.Date); date=$date.ToString('yyyy-MM-dd') }
}
# ziniao 调用
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
$runJs = Join-Path $env:APPDATA 'npm\node_modules\@ziniao-open\cli\scripts\run.js'
if (-not (Test-Path $runJs)) { $cmd = Get-Command ziniao -ErrorAction SilentlyContinue; if ($cmd) { $runJs = $cmd.Source } }
$utf8 = [System.Text.UTF8Encoding]::new($false)
function Invoke-Ziniao([string[]]$CliArgs) {
  $allArgs = @($runJs) + @($CliArgs)
  $argLine = ($allArgs | ForEach-Object { if ($null -eq $_) { '""' } elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $node; $psi.Arguments = $argLine; $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
  $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi; [void]$p.Start()
  $so = $p.StandardOutput.ReadToEnd(); $se = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  if ($se) { Write-Host $se }
  return $so
}
function Get-ScrapePayload([string]$execOut) {
  if ([string]::IsNullOrWhiteSpace($execOut)) { return $null }
  try { $j = $execOut | ConvertFrom-Json; if ($j.data -and $j.data.data -and $j.data.data.result) { return ([string]$j.data.data.result | ConvertFrom-Json) } } catch { }
  $m = [regex]::Matches($execOut, '\{(?:[^{}]|(?<o>\{)|(?<-o>\}))+(?(o)(?!))\}')
  if ($m.Count -gt 0) { try { return ($m[$m.Count - 1].Value | ConvertFrom-Json) } catch { } }
  return $null
}
function ConvertTo-ScrapeOneLine([string]$js) { return (($js -replace '(?m)^\s*//.*$','' -replace '\r?\n',' ' -replace '\s+',' ').Trim()) }

$orderUrl = 'https://seller-uk.tiktok.com/order?selected_sort=6&tab=all'
$scrapeJs = Get-Content (Join-Path $root 'scripts\scrape-orders-page.js') -Raw -Encoding UTF8
$scrapeOneLine = ConvertTo-ScrapeOneLine $scrapeJs

$ukNow = Get-UKNow
$ukToday = $ukNow.Date
$yest = $ukToday.AddDays(-1)
Write-Host ("UK 现在: {0}  今天={1}  昨天={2}" -f $ukNow.ToString('yyyy-MM-dd HH:mm'), $ukToday.ToString('yyyy-MM-dd'), $yest.ToString('yyyy-MM-dd'))
Write-Host ("store={0} url={1}" -f $StoreId, $orderUrl)
Write-Host "visit 订单页..."
$null = Invoke-Ziniao @('page','visit','--store-id',$StoreId,'--url',$orderUrl,'--wait-until','networkidle','--timeout','60000')
Start-Sleep -Seconds 6
Write-Host "scrape page1..."
$out = Invoke-Ziniao @('page','exec','--store-id',$StoreId,'--script',$scrapeOneLine,'--timeout','60000')
$p = Get-ScrapePayload $out
if (-not $p -or -not $p.ok) { Write-Host "scrape fail: $(if($p){$p.error}else{'no payload'})"; exit 1 }
$rows = @($p.rows)
Write-Host ("page1 rowCount={0} source={1} currency={2}" -f $rows.Count, $p.source, $p.currency)
Write-Host ""
Write-Host ("{0,-22} {1,-26} {2,-12} {3}" -f 'orderId','createTime(raw)','换算date','判定')
$cnt = @{ yesterday=0; today=0; older=0; null=0 }
foreach ($r in $rows) {
  $ct = if ($r.createTime) { [string]$r.createTime } else { '' }
  $j = Test-OrderDateRange -CreateTime $ct -UKToday $ukNow
  if ($null -eq $j.date) { $verdict='NULL(保守收)'; $cnt.null++ }
  elseif ($j.beforeYesterday) { $verdict='OLDER(停)'; $cnt.older++ }
  elseif ($j.keep) { $verdict='YESTERDAY(收)'; $cnt.yesterday++ }
  else { $verdict='today(跳过)'; $cnt.today++ }
  Write-Host ("{0,-22} {1,-26} {2,-12} {3}" -f ([string]$r.orderId), $ct, $(if($j.date){$j.date}else{'null'}), $verdict)
}
Write-Host ""
Write-Host ("汇总: yesterday={0} today={1} older={2} null={3} / 共{4}条" -f $cnt.yesterday,$cnt.today,$cnt.older,$cnt.null,$rows.Count)
Write-Host ("方案2在此页行为: 收{0}条昨天的单" -f $cnt.yesterday)
if ($cnt.older -gt 0) { Write-Host "  且本页已出现前天及更早→翻页会停（首页就停）" }
