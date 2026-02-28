param(
  [string]$ArtifactPath = "artifacts/local/firefox-local-artifact.zip",
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-CheckedCommand([string]$Exe, [string[]]$CmdArgs) {
  Write-Host ">> $Exe $($CmdArgs -join ' ')"
  & $Exe @CmdArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $Exe $($CmdArgs -join ' ')"
  }
}

function Resolve-MachPath([string]$RepoRoot) {
  $candidates = @(
    (Join-Path $RepoRoot "mach.ps1"),
    (Join-Path $RepoRoot "mach")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }
  throw "mach entrypoint not found in $RepoRoot"
}

function Get-TopObjDir([string]$RepoRoot, [string]$MachPath) {
  $envJson = & $MachPath environment --format json
  if ($LASTEXITCODE -ne 0) {
    return $null
  }
  if (-not $envJson) {
    return $null
  }
  $objDir = ($envJson | ConvertFrom-Json).topobjdir
  if (-not $objDir) {
    return $null
  }
  return $objDir
}

function Set-MozconfigArtifact([string]$MozconfigPath, [string]$ArtifactValue) {
  $lines = Get-Content -Path $MozconfigPath
  $result = New-Object System.Collections.Generic.List[string]
  $hasArtifactBuilds = $false
  $artifactSet = $false

  foreach ($line in $lines) {
    if ($line -match "^\s*ac_add_options\s+--enable-artifact-builds\s*$") {
      $hasArtifactBuilds = $true
      $result.Add("ac_add_options --enable-artifact-builds")
      continue
    }
    if ($line -match "^\s*export\s+MOZ_ARTIFACT_FILE=") {
      if (-not $artifactSet) {
        $result.Add("export MOZ_ARTIFACT_FILE=$ArtifactValue")
        $artifactSet = $true
      }
      continue
    }
    $result.Add($line)
  }

  if (-not $hasArtifactBuilds) {
    $result.Add("ac_add_options --enable-artifact-builds")
  }
  if (-not $artifactSet) {
    $result.Add("export MOZ_ARTIFACT_FILE=$ArtifactValue")
  }

  [System.IO.File]::WriteAllText(
    $MozconfigPath,
    (($result -join "`n").TrimEnd() + "`n"),
    [System.Text.UTF8Encoding]::new($false)
  )
}

if (-not (Test-Path ".\mach")) {
  throw "Run this script from repository root (where ./mach exists)."
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$mozconfigPath = Join-Path $repoRoot "mozconfig"
if (-not (Test-Path $mozconfigPath)) {
  throw "mozconfig not found: $mozconfigPath"
}

$artifactFullPath = if ([System.IO.Path]::IsPathRooted($ArtifactPath)) {
  [System.IO.Path]::GetFullPath($ArtifactPath)
} else {
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ArtifactPath))
}

$artifactParent = Split-Path -Parent $artifactFullPath
if (-not (Test-Path $artifactParent)) {
  New-Item -ItemType Directory -Path $artifactParent | Out-Null
}

$artifactForMozconfig = if ($artifactFullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
  $relative = $artifactFullPath.Substring($repoRoot.Length).TrimStart('\', '/').Replace('\', '/')
  "@TOPSRCDIR@/$relative"
} else {
  $artifactFullPath.Replace('\', '/')
}

$rawMozconfig = Get-Content -Raw -Path $mozconfigPath
$filteredMozconfig = ($rawMozconfig -split "`r?`n") | Where-Object {
  $_ -notmatch "^\s*ac_add_options\s+--enable-artifact-builds\s*$" -and
  $_ -notmatch "^\s*export\s+MOZ_ARTIFACT_FILE="
}

$tempMozconfig = Join-Path $env:TEMP ("mozconfig-local-artifact-" + [guid]::NewGuid().ToString("N"))
[System.IO.File]::WriteAllText(
  $tempMozconfig,
  (($filteredMozconfig -join "`n").TrimEnd() + "`n"),
  [System.Text.UTF8Encoding]::new($false)
)

$prevMozconfig = $env:MOZCONFIG
$hadMozconfig = Test-Path Env:MOZCONFIG
$prevArtifact = $env:MOZ_ARTIFACT_FILE
$hadArtifact = Test-Path Env:MOZ_ARTIFACT_FILE

Push-Location $repoRoot
try {
  $machPath = Resolve-MachPath -RepoRoot $repoRoot
  $env:MOZCONFIG = $tempMozconfig
  Remove-Item Env:MOZ_ARTIFACT_FILE -ErrorAction SilentlyContinue

  if (-not $SkipBuild) {
    Invoke-CheckedCommand -Exe $machPath -CmdArgs @("--no-interactive", "build")
    Invoke-CheckedCommand -Exe $machPath -CmdArgs @("--no-interactive", "package")
  }

  $topObjDir = Get-TopObjDir -RepoRoot $repoRoot -MachPath $machPath
  if (-not $topObjDir) {
    $distCandidate = Get-ChildItem -Path $repoRoot -Directory -Filter "obj-*" -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName "dist") } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if (-not $distCandidate) {
      throw "Failed to detect topobjdir via 'mach environment' and no obj-*/dist directory was found."
    }
    $topObjDir = $distCandidate.FullName
  }
  $distDir = Join-Path $topObjDir "dist"
  $zip = Get-ChildItem -Path $distDir -Recurse -File -Filter "firefox-*.zip" |
    Where-Object { $_.Name -notlike "*.xpt_artifacts.zip" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $zip) {
    throw "Zip package not found in $distDir"
  }

  Copy-Item -LiteralPath $zip.FullName -Destination $artifactFullPath -Force
  Set-MozconfigArtifact -MozconfigPath $mozconfigPath -ArtifactValue $artifactForMozconfig

  Write-Host ""
  Write-Host "Local artifact updated:"
  Write-Host "  Source zip: $($zip.FullName)"
  Write-Host "  Artifact:   $artifactFullPath"
  Write-Host "  mozconfig:  export MOZ_ARTIFACT_FILE=$artifactForMozconfig"
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
  Pop-Location
}
