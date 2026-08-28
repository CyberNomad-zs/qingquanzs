# Daily report wrapper (for Windows Task Scheduler + GUI [4])
# Spawns run-multi-store.ps1 in a hidden PowerShell (no second menu / no flashy window).
# Default: real Feishu write; dateMode from config.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-daily-report.ps1

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "daily-report-$stamp.log"

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

Log "===== TK Ad Daily Report START ====="
Log "root=$root"
Log "log=$logFile"

Set-Location $root

$script = Join-Path $root 'scripts\run-multi-store.ps1'
if (-not (Test-Path $script)) {
  Log "FATAL missing $script"
  exit 1
}

# Hidden child PS: avoids Start-Process console quirks; child exit does not kill this host
Log "invoke run-multi-store.ps1 -DryRun false (hidden child)"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Get-Command powershell.exe).Source
$psi.Arguments = @(
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy', 'Bypass',
  '-File', "`"$script`"",
  '-DryRun', 'false'
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
Log "===== TK Ad Daily Report END ====="
exit $code
