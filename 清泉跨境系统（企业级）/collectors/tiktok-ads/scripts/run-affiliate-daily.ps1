# Daily affiliate / creator performance wrapper (Windows Task Scheduler)
# 经营计划 P3：联盟中心·表现 → tiktok_affiliate_daily + tiktok_affiliate_creator
# 强制 SkipIngest=false（POC 默认 SkipIngest，日更必须上报）
# 默认模块：enter_center + performance（跳过 probe，减一轮打开）
# 默认不写飞书；T7 走仓库根 feishu-tk-daily-sync -AffiliateOnly / post-collect
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-affiliate-daily.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-affiliate-daily.ps1 -StoreIds 27501502216807
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-affiliate-daily.ps1 -Modules affiliate_enter_center,affiliate_performance
#
# 安装计划任务（可选，业务批准后）:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-affiliate-daily-task.ps1
#
# 注意：全店策略 — 不特殊排除 Pop/EU；与 shop-modules 一致三店全跑。

param(
  [string]$ConfigPath = "",
  [string]$Modules = "affiliate_enter_center,affiliate_performance",
  [string]$StoreIds = ""
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "affiliate-daily-$stamp.log"

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

Log "===== TK Affiliate Daily START ====="
Log "root=$root"
Log "log=$logFile"
Log "modules=$Modules"
if ($StoreIds) { Log "storeIds=$StoreIds" }

Set-Location $root

$script = Join-Path $root 'scripts\run-affiliate-poc.ps1'
if (-not (Test-Path $script)) {
  Log "FATAL missing $script"
  exit 1
}

if (-not $ConfigPath) {
  $ConfigPath = Join-Path $root 'config\stores.config.json'
}
if (-not (Test-Path $ConfigPath)) {
  Log "FATAL missing config $ConfigPath"
  exit 1
}
Log "config=$ConfigPath"

Log "invoke run-affiliate-poc.ps1 -SkipIngest:`$false -DryRun false (hidden child)"
$argParts = @(
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy', 'Bypass',
  '-File', "`"$script`"",
  '-ConfigPath', "`"$ConfigPath`"",
  '-DryRun', 'false',
  '-Modules', "`"$Modules`"",
  '-SkipIngest', 'false'
)
if ($StoreIds -and $StoreIds.Trim() -ne '') {
  $argParts += @('-StoreIds', "`"$StoreIds`"")
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Get-Command powershell.exe).Source
$psi.Arguments = ($argParts -join ' ')
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

Log "exitCode=$code"
Log "===== TK Affiliate Daily END ====="
exit $code
