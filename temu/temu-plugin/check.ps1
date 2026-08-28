# Temu plugin release gate — syntax check + unit tests (no Chrome).
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\check.ps1
# Exit 0 = all green; non-zero = fail (do not bump bgVersion / ship zip).

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
Set-Location -LiteralPath $Root

function Find-Node {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  throw 'node not found in PATH. Install Node.js 18+ and retry.'
}

$node = Find-Node
$failed = 0
$passed = 0

function Step([string]$Title, [scriptblock]$Body) {
  Write-Host ''
  Write-Host "=== $Title ===" -ForegroundColor Cyan
  try {
    & $Body
    if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
      throw "exit code $LASTEXITCODE"
    }
    $script:passed++
    Write-Host "PASS  $Title" -ForegroundColor Green
  } catch {
    $script:failed++
    Write-Host "FAIL  $Title :: $($_.Exception.Message)" -ForegroundColor Red
  }
}

Write-Host "Temu plugin check  (node = $node)"
Write-Host "dir = $Root"

$jsFiles = @(
  'background.js',
  'content.js',
  'content-front.js',
  'inject.js',
  'popup.js',
  'options.js',
  'logger.js',
  'feishuApp.js'
)

Step 'syntax (node --check)' {
  foreach ($f in $jsFiles) {
    $p = Join-Path $Root $f
    if (-not (Test-Path -LiteralPath $p)) {
      Write-Host "  skip missing $f" -ForegroundColor Yellow
      continue
    }
    & $node --check $p
    if ($LASTEXITCODE -ne 0) { throw "syntax error: $f" }
    Write-Host "  ok  $f"
  }
}

$tests = @(
  'test_traffic_dedupe.js',
  'test_onsale_ab.js',
  'test_timelines.js',
  'test_sku_parse.js',
  'test_error_report.js',
  'test_front_captcha.js'
)

foreach ($t in $tests) {
  $p = Join-Path $Root $t
  if (-not (Test-Path -LiteralPath $p)) {
    Write-Host ''
    Write-Host "SKIP  $t (file missing)" -ForegroundColor Yellow
    continue
  }
  Step $t {
    & $node $p
    if ($LASTEXITCODE -ne 0) { throw "test failed: $t" }
  }
}

# Soft checks: version string consistency (warn only on options mismatch)
Step 'bgVersion marker present' {
  $bg = Get-Content -LiteralPath (Join-Path $Root 'background.js') -Raw -Encoding UTF8
  if ($bg -notmatch "bgVersion:\s*'v22\.") {
    throw 'background.js getStatus bgVersion missing or not v22.x'
  }
  if ($bg -notmatch 'v22\.3') {
    Write-Host '  warn: background.js may not mention v22.3' -ForegroundColor Yellow
  }
  $mf = Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8
  if ($mf -notmatch '"version"\s*:\s*"0\.2\.') {
    Write-Host '  warn: manifest version not 0.2.x' -ForegroundColor Yellow
  }
  Write-Host '  bgVersion / manifest spot-check done'
}

Write-Host ''
Write-Host '----------------------------------------'
if ($failed -gt 0) {
  Write-Host "RESULT  FAIL  ($failed failed, $passed passed)" -ForegroundColor Red
  Write-Host 'Do not ship. Fix tests before bumping bgVersion.'
  exit 1
}

Write-Host "RESULT  PASS  ($passed steps)" -ForegroundColor Green
Write-Host 'Manual still required: chrome://extensions toggle + popup version string + one store switch smoke.'
Write-Host 'SLO: ../SLO.md  |  parity: ../temu-monitor/PLUGIN_PARITY.md'
exit 0
