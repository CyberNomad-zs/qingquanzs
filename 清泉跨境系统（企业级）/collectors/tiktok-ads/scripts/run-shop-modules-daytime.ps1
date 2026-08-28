# Daytime shop-modules wrapper (Windows Task Scheduler) — 事件型模块白天补采
# 目的：异常及时提醒。白天加一轮只采"事件型"模块（违规/差评/达人健康），
#   这类是"新事件出现就报"，白天采到立即触发 IM 私信 + 群通知，不用等晚上。
#   刻意不采 shop_daily/experience_daily/finance_daily/ads 等全天累计指标——
#   白天采的是"未结束的中间值"，会和晚上全天最终值冲突/乱（见 docs/ops 讨论）。
# 违规/差评/达人健康按 key 幂等 upsert，白天采晚上再采不乱，且规则看 first_seen_at 触发。
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daytime.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daytime.ps1 -Modules violation,reviews

param(
  [string]$ConfigPath = "",
  # 白天只采事件型三件套；health_daily 一天一个值白天采意义不大且可能和晚上冲突，故默认不含
  [string]$Modules = "violation,reviews,creator_health"
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "shop-modules-daytime-$stamp.log"

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

Log "===== TK Shop-Modules Daytime START ====="
Log "root=$root"
Log "log=$logFile"
Log "modules=$Modules (事件型白天补采，不碰累计指标)"

Set-Location $root

$script = Join-Path $root 'scripts\run-shop-modules.ps1'
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

# Hidden child PS：计划任务下避免弹窗；强制 DryRun=false 实写清泉
Log "invoke run-shop-modules.ps1 -DryRun false (hidden child)"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Get-Command powershell.exe).Source
$psi.Arguments = @(
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy', 'Bypass',
  '-File', "`"$script`"",
  '-ConfigPath', "`"$ConfigPath`"",
  '-DryRun', 'false',
  '-Modules', "`"$Modules`""
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

Log "exitCode=$code"
Log "===== TK Shop-Modules Daytime END ====="
exit $code
