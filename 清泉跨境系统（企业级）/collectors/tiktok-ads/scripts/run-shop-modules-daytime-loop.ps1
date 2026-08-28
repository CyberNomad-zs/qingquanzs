# Daytime loop: 白天一直跑事件型补采(违规/差评/达人健康)，避开夜间采集窗口。
# 每隔 IntervalSec 跑一轮 run-shop-modules-daytime.ps1(violation/reviews/creator_health)。
# 时间窗避开（两段，都让出 Bridge）：
#   08:00 ~ 11:30  整站 08:10 + 订单串行（2026-08-21 订单并入整站 wrapper 串行跑，方案2只抓昨天≈1-2h）
#   17:00 ~ 21:30  广告日报17:20 + 旧夜间堆叠残留 + 兜底尾巴
# Bridge 探测：紫鸟 Bridge 不在线则跳过该轮(不抢紫鸟/不空跑)。
# 一直跑直到手动停止(美化启动器「停止当前任务」或关窗口)。
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daytime-loop.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daytime-loop.ps1 -IntervalSec 1800
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-shop-modules-daytime-loop.ps1 -Modules violation,reviews

param(
  [int]$IntervalSec = 1800,          # 默认 30 分钟一轮
  [string]$Modules = "violation,reviews,creator_health",
  # 旧单窗口参数（向后兼容；若传了则并入 $BlacklistWindows）。默认空，靠 $BlacklistWindows。
  [int]$BlacklistStartHour = -1,
  [int]$BlacklistEndHour = -1,
  [int]$BlacklistEndMinute = 0,
  # 多窗口列表：每个元素 [startHour,startMin,endHour,endMin]。默认含两段。
  [int[][]]$BlacklistWindows = @(
    ,@(8, 0, 11, 30)    # 08:00 ~ 11:30 让整站08:10 + 订单串行
    ,@(17, 0, 21, 30)   # 17:00 ~ 21:30 广告+旧夜间堆叠+兜底
  )
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$logFile = Join-Path $logs ("daytime-loop-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $line
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Test-Bridge {
  try {
    $tnc = Test-NetConnection -ComputerName '127.0.0.1' -Port 9481 -WarningAction SilentlyContinue
    if ($tnc -and $tnc.TcpTestSucceeded) { return $true }
  } catch { }
  try {
    Invoke-WebRequest -Uri 'http://127.0.0.1:9481/' -TimeoutSec 3 -UseBasicParsing | Out-Null
    return $true
  } catch {
    $msg = [string]$_.Exception.Message
    if ($msg -match '401|403|400|200') { return $true }
    if ($_.Exception.Response) { return $true }
    return $false
  }
}

function Test-InBlacklist {
  # 支持多段避开窗口 $BlacklistWindows（每个 [startH,startM,endH,endM]）。
  # 旧单窗口参数若被显式传入（StartHour>=0），并入窗口列表（向后兼容）。
  $now = Get-Date
  $h = $now.Hour
  $m = $now.Minute
  $windows = @()
  if ($BlacklistWindows) { $windows += @($BlacklistWindows) }
  if ($BlacklistStartHour -ge 0 -and $BlacklistEndHour -ge 0) {
    $windows += ,@($BlacklistStartHour, 0, $BlacklistEndHour, $BlacklistEndMinute)
  }
  foreach ($w in $windows) {
    $sH = [int]$w[0]; $sM = [int]$w[1]; $eH = [int]$w[2]; $eM = [int]$w[3]
    $startMin = $sH * 60 + $sM
    $endMin = $eH * 60 + $eM
    $curMin = $h * 60 + $m
    if ($curMin -ge $startMin -and $curMin -le $endMin) { return $true }
  }
  return $false
}

Log "daytime-loop start interval=${IntervalSec}s modules=$Modules"
$blDesc = ($BlacklistWindows | ForEach-Object { ('{0:D2}:{1:D2}~{2:D2}:{3:D2}' -f [int]$_[0],[int]$_[1],[int]$_[2],[int]$_[3]) }) -join ' + '
Log "避开窗口: $blDesc (整站08:10+订单串行 / 广告/夜间堆叠)"
$round = 0
while ($true) {
  $round++
  Log "===== round $round ====="
  if (Test-InBlacklist) {
    Log "在避开窗口内 — 跳过本轮(不与广告/整站抢紫鸟)"
  } elseif (-not (Test-Bridge)) {
    Log "Bridge down — 跳过本轮"
  } else {
    Log "Bridge up — run shop-modules-daytime (modules=$Modules)"
    try {
      # 用 Start-Process -ArgumentList <数组> 启动子脚本：
      #   - 数组先赋给 $childArgs 变量(单行)，避开反引号续行在 Hidden 进程里把数组解析坏的问题
      #   - 数组形式每个 token 是独立元素，PowerShell 自动正确转义含逗号的 $Modules，不手工拼字符串
      #   - -Wait -PassThru 拿子进程退出码；子脚本自己写 logs\shop-modules-daytime-*.log 记录采集详情
      #   - -WindowStyle Hidden，计划任务/Hidden 父进程下不弹窗
      # 注意：本文件必须保存为 UTF-8 *带 BOM*，否则 Windows PowerShell 5.1 会按系统 ANSI(GBK)
      #       读取无 BOM 的 .ps1，中文注释字节被错解，导致 param 默认值丢失、$PSScriptRoot 为空。
      $childScript = Join-Path $PSScriptRoot 'run-shop-modules-daytime.ps1'
      $psExe = (Get-Command powershell.exe).Source
      $childArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$childScript,'-Modules',$Modules)
      $child = Start-Process -FilePath $psExe -ArgumentList $childArgs -Wait -PassThru -WindowStyle Hidden
      Log ("shop-modules-daytime exit={0}" -f $child.ExitCode)
    } catch {
      Log ("shop-modules-daytime error: {0}" -f $_)
    }
  }
  Log "sleep ${IntervalSec}s"
  Start-Sleep -Seconds $IntervalSec
}
