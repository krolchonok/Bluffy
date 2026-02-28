param(
  [string]$Tag,
  [string]$Title,
  [switch]$SkipBuild,
  [switch]$NoAutoClobber,
  [switch]$Draft,
  [switch]$PreRelease,
  [switch]$SkipMar,
  [switch]$SignMar,
  [switch]$SkipMarSign,
  [string]$MarSigningKeyPath = "tools/update-signing/bluffy_update_key.pem",
  [string]$UpdateChannel = "bluffy",
  [string]$MarOutputPath,
  [string]$MarUrlOverride,
  [string]$UpdateXmlPath = "updates/update.xml",
  [switch]$SkipUpdateXml
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$runner = Join-Path $repoRoot "scripts/build-and-release-no-artifact.ps1"
if (-not (Test-Path $runner)) {
  throw "Missing script: $runner"
}

Write-Host ">> Running prod release (no artifact builds)"
Write-Host ">> $runner -UpdateXmlPath $UpdateXmlPath"
& $runner `
  -Tag $Tag `
  -Title $Title `
  -SkipBuild:$SkipBuild `
  -NoAutoClobber:$NoAutoClobber `
  -Draft:$Draft `
  -PreRelease:$PreRelease `
  -SkipMar:$SkipMar `
  -SignMar:$SignMar `
  -SkipMarSign:$SkipMarSign `
  -MarSigningKeyPath $MarSigningKeyPath `
  -UpdateChannel $UpdateChannel `
  -MarOutputPath $MarOutputPath `
  -MarUrlOverride $MarUrlOverride `
  -UpdateXmlPath $UpdateXmlPath `
  -SkipUpdateXml:$SkipUpdateXml
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}
