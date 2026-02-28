param(
  [Parameter(Mandatory = $true)]
  [string]$MarPath,
  [Parameter(Mandatory = $true)]
  [string]$MarURL,
  [Parameter(Mandatory = $true)]
  [string]$Version,
  [Parameter(Mandatory = $true)]
  [string]$BuildID,
  [string]$OutputPath = "updates/update.xml"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

if (-not (Test-Path $MarPath)) {
  throw "MAR file does not exist: $MarPath"
}

$marFile = Get-Item -LiteralPath $MarPath
$size = $marFile.Length
$hash = (Get-FileHash -Algorithm SHA512 -LiteralPath $MarPath).Hash.ToLowerInvariant()

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path $outputDir)) {
  New-Item -ItemType Directory -Path $outputDir | Out-Null
}

$xml = @"
<?xml version="1.0"?>
<updates>
  <update type="minor" displayVersion="$Version" appVersion="$Version" platformVersion="$Version" buildID="$BuildID">
    <patch type="complete" URL="$MarURL" hashFunction="sha512" hashValue="$hash" size="$size"/>
  </update>
</updates>
"@

[System.IO.File]::WriteAllText($OutputPath, $xml, [System.Text.UTF8Encoding]::new($false))

Write-Host "Generated:"
Write-Host "  XML: $OutputPath"
Write-Host "  MAR: $MarPath"
Write-Host "  Size: $size"
Write-Host "  SHA512: $hash"
