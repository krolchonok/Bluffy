param(
  [Parameter(Mandatory = $true)]
  [string]$InstallDir,
  [string]$AppUpdateURL = "https://github.com/krolchonok/Bluffy/releases/latest/download/update.xml"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$distributionDir = Join-Path $InstallDir "distribution"
$policyPath = Join-Path $distributionDir "policies.json"

if (-not (Test-Path $InstallDir)) {
  throw "InstallDir does not exist: $InstallDir"
}

if (-not (Test-Path $distributionDir)) {
  New-Item -ItemType Directory -Path $distributionDir | Out-Null
}

$doc = @{
  policies = @{}
}

if (Test-Path $policyPath) {
  $existing = Get-Content -Raw -Path $policyPath | ConvertFrom-Json -AsHashtable
  if ($existing.ContainsKey("policies") -and $existing.policies) {
    $doc = $existing
  }
}

if (-not $doc.ContainsKey("policies") -or -not $doc.policies) {
  $doc.policies = @{}
}

$doc.policies.AppUpdateURL = $AppUpdateURL

$json = $doc | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($policyPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))

Write-Host "Updated policy:"
Write-Host "  Path: $policyPath"
Write-Host "  AppUpdateURL: $AppUpdateURL"
