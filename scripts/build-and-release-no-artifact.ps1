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
$sourceMozconfig = Join-Path $repoRoot "mozconfig"
if (-not (Test-Path $sourceMozconfig)) {
  throw "mozconfig not found: $sourceMozconfig"
}

$rawMozconfig = Get-Content -Raw -Path $sourceMozconfig
$filteredMozconfig = ($rawMozconfig -split "`r?`n") | Where-Object {
  $_ -notmatch "^\s*ac_add_options\s+--enable-artifact-builds\s*$" -and
  $_ -notmatch "^\s*export\s+MOZ_ARTIFACT_FILE="
}

$tempMozconfig = Join-Path $env:TEMP ("mozconfig-no-artifact-" + [guid]::NewGuid().ToString("N"))
[System.IO.File]::WriteAllText(
  $tempMozconfig,
  (($filteredMozconfig -join "`n").TrimEnd() + "`n"),
  [System.Text.UTF8Encoding]::new($false)
)

$prevMozconfig = $env:MOZCONFIG
$hadMozconfig = Test-Path Env:MOZCONFIG
$prevArtifact = $env:MOZ_ARTIFACT_FILE
$hadArtifact = Test-Path Env:MOZ_ARTIFACT_FILE

try {
  $env:MOZCONFIG = $tempMozconfig
  Remove-Item Env:MOZ_ARTIFACT_FILE -ErrorAction SilentlyContinue

  & (Join-Path $repoRoot "scripts/build-and-release.ps1") `
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
} finally {
  if ($hadMozconfig) {
    $env:MOZCONFIG = $prevMozconfig
  } else {
    Remove-Item Env:MOZCONFIG -ErrorAction SilentlyContinue
  }

  if ($hadArtifact) {
    $env:MOZ_ARTIFACT_FILE = $prevArtifact
  } else {
    Remove-Item Env:MOZ_ARTIFACT_FILE -ErrorAction SilentlyContinue
  }

  Remove-Item -LiteralPath $tempMozconfig -ErrorAction SilentlyContinue
}
