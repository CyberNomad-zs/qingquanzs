# Daily content + product-card wrapper (Windows Task Scheduler)
# 经营计划 P2：视频行级 video_list + 商品卡 product_traffic → 清泉 Ingest
# 强制 SkipIngest=false（POC 默认 SkipIngest，日更必须上报）
# 默认不写飞书；飞书 T6 走仓库根 post-collect / feishu-tk-daily-sync -ContentOnly
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-content-daily.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-content-daily.ps1 -Modules video_list
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-content-daily.ps1 -Modules product_traffic
#
# 安装计划任务（可选，业务批准后）:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-content-daily-task.ps1

param(
  [string]$ConfigPath = "",
  [string]$Modules = "video_list,product_traffic"
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "content-daily-$stamp.log"

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

Log "===== TK Content Daily START ====="
Log "root=$root"
Log "log=$logFile"
Log "modules=$Modules"

Set-Location $root

$script = Join-Path $root 'scripts\run-content-poc.ps1'
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

# 日更强制入库：-SkipIngest:$false；计划任务下隐藏子进程
Log "invoke run-content-poc.ps1 -SkipIngest:`$false -DryRun false (hidden child)"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Get-Command powershell.exe).Source
$psi.Arguments = @(
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy', 'Bypass',
  '-File', "`"$script`"",
  '-ConfigPath', "`"$ConfigPath`"",
  '-DryRun', 'false',
  '-Modules', "`"$Modules`"",
  '-SkipIngest', 'false'
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
Log "===== TK Content Daily END ====="
exit $code
