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
$env:PYTHON_BASIC_REPL = "1"

if ($SignMar -and $SkipMarSign) {
  throw "Use only one of -SignMar or -SkipMarSign."
}

function Invoke-CheckedCommand([string]$Exe, [string[]]$CmdArgs, [int[]]$AllowedExitCodes = @(0)) {
  Write-Host ">> $Exe $($CmdArgs -join ' ')"
  & $Exe @CmdArgs
  $code = $LASTEXITCODE
  if ($AllowedExitCodes -notcontains $code) {
    throw "Command failed with exit code ${code}: $Exe $($CmdArgs -join ' ')"
  }
  return $code
}

function Exec([string]$Command) {
  Write-Host ">> $Command"
  Invoke-Expression $Command
}

function Convert-ToBashSingleQuoted([string]$Value) {
  $singleQuote = [char]39
  $doubleQuote = [char]34
  $escapedSingle = [string]$singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
  return [string]$singleQuote + ($Value -replace "'", $escapedSingle) + [string]$singleQuote
}

function Convert-ToPosixPath([string]$Path) {
  return $Path.Replace("\", "/")
}

function Get-PreferredBash {
  $candidates = @(
    "C:\mozilla-build\msys2\usr\bin\bash.exe",
    "C:\mozilla-build\msys\bin\bash.exe",
    "C:\msys64\usr\bin\bash.exe"
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  $allBash = @(Get-Command bash -All -ErrorAction SilentlyContinue)
  foreach ($cmd in $allBash) {
    if ($cmd.Source -and $cmd.Source -notmatch "Windows\\system32\\bash\.exe$") {
      return $cmd.Source
    }
  }

  return $null
}

function Get-IniValue([string]$Path, [string]$Section, [string]$Key) {
  $currentSection = ""
  $escapedKey = [regex]::Escape($Key)
  foreach ($line in Get-Content -Path $Path) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith(";")) {
      continue
    }
    if ($trimmed -match '^\[(.+)\]$') {
      $currentSection = $Matches[1]
      continue
    }
    if ($currentSection -eq $Section -and $trimmed -match "^$escapedKey=(.*)$") {
      return $Matches[1].Trim()
    }
  }
  return $null
}

function Invoke-Gh([string[]]$GhArgs) {
  Invoke-CheckedCommand -Exe $script:GhExe -CmdArgs $GhArgs | Out-Null
}

function Get-GitHubRepoFromRemote([string]$RemoteName) {
  $url = (& git remote get-url $RemoteName 2>$null).Trim()
  if (-not $url) {
    return $null
  }
  if ($url -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(?:\.git)?$') {
    return "$($Matches.owner)/$($Matches.repo)"
  }
  return $null
}

function Get-TopObjDir {
  $envJson = & .\mach environment --format json
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to detect topobjdir via 'mach environment'."
  }
  $objDir = ($envJson | ConvertFrom-Json).topobjdir
  if (-not $objDir) {
    throw "Unable to detect topobjdir."
  }
  return $objDir
}

function Ensure-ClobberIfNeeded([string]$TopObjDir) {
  $srcClobber = Join-Path (Get-Location) "CLOBBER"
  $objClobber = Join-Path $TopObjDir "CLOBBER"

  if (-not (Test-Path $srcClobber)) {
    return
  }

  if (-not (Test-Path $objClobber)) {
    if ($NoAutoClobber) {
      throw "CLOBBER check failed: $objClobber is missing. Run './mach clobber' and retry."
    }
    Exec ".\mach --no-interactive clobber"
    return
  }

  $srcTime = (Get-Item $srcClobber).LastWriteTimeUtc
  $objTime = (Get-Item $objClobber).LastWriteTimeUtc
  if ($srcTime -gt $objTime) {
    if ($NoAutoClobber) {
      throw "CLOBBER is newer than objdir marker. Run './mach clobber' and retry."
    }
    Exec ".\mach --no-interactive clobber"
  }
}

function Get-MarExe([string]$TopObjDir) {
  $candidates = @(
    (Join-Path $TopObjDir "dist/host/bin/mar.exe"),
    (Join-Path $TopObjDir "dist/bin/mar.exe")
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  $marCmd = Get-Command mar.exe -ErrorAction SilentlyContinue
  if ($marCmd -and $marCmd.Source) {
    return $marCmd.Source
  }

  return $null
}

function Get-PythonRuntime {
  $machPython = (& .\mach --no-interactive python -- -c "import sys; print(sys.executable)").Trim()
  if ($LASTEXITCODE -eq 0 -and $machPython -and (Test-Path $machPython)) {
    Invoke-CheckedCommand -Exe $machPython -CmdArgs @("--version") | Out-Null
    return @{
      Exe = $machPython
      PrefixArgs = @()
    }
  }

  $pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($pythonCmd -and $pythonCmd.Source) {
    Invoke-CheckedCommand -Exe $pythonCmd.Source -CmdArgs @("--version") | Out-Null
    return @{
      Exe = $pythonCmd.Source
      PrefixArgs = @()
    }
  }

  throw "Python runtime not found."
}

function Ensure-PythonMarAvailable($PythonRuntime) {
  $checkArgs = @() + $PythonRuntime.PrefixArgs + @(
    "-c",
    "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('mardor') else 1)"
  )
  $code = Invoke-CheckedCommand -Exe $PythonRuntime.Exe -CmdArgs $checkArgs -AllowedExitCodes @(0, 1)
  if ($code -eq 1) {
    $isVenvArgs = @() + $PythonRuntime.PrefixArgs + @(
      "-c",
      "import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)"
    )
    $isVenv = (Invoke-CheckedCommand -Exe $PythonRuntime.Exe -CmdArgs $isVenvArgs -AllowedExitCodes @(0, 1)) -eq 0
    if ($isVenv) {
      $installArgs = @() + $PythonRuntime.PrefixArgs + @("-m", "pip", "install", "mar")
    } else {
      $installArgs = @() + $PythonRuntime.PrefixArgs + @("-m", "pip", "install", "--user", "mar")
    }
    Invoke-CheckedCommand -Exe $PythonRuntime.Exe -CmdArgs $installArgs | Out-Null
  }
}

if (-not (Test-Path ".\mach")) {
  throw "Run this script from repository root (where ./mach exists)."
}
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
Push-Location $repoRoot

$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if ($ghCmd) {
  $script:GhExe = $ghCmd.Source
} elseif (Test-Path "C:\Program Files\GitHub CLI\gh.exe") {
  $script:GhExe = "C:\Program Files\GitHub CLI\gh.exe"
} else {
  throw "GitHub CLI (gh) is not installed or not in PATH."
}

try {
if (-not $SkipBuild) {
  $topObjDir = Get-TopObjDir
  Ensure-ClobberIfNeeded -TopObjDir $topObjDir
  Exec ".\mach --no-interactive build"
  Exec ".\mach --no-interactive package"
}

$topObjDir = Get-TopObjDir
$distDir = Join-Path $topObjDir "dist"
if (-not (Test-Path $distDir)) {
  throw "dist directory not found: $distDir"
}

$installer = Get-ChildItem -Path $distDir -Recurse -File -Filter "firefox-*.installer.exe" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

$zip = Get-ChildItem -Path $distDir -Recurse -File -Filter "firefox-*.zip" |
  Where-Object { $_.Name -notlike "*.xpt_artifacts.zip" } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if (-not $installer) {
  throw "Installer not found in $distDir"
}
if (-not $zip) {
  throw "Zip package not found in $distDir"
}

$appIniPath = Join-Path $distDir "bin/application.ini"
if (-not (Test-Path $appIniPath)) {
  throw "application.ini not found at $appIniPath"
}

$firefoxVersion = Get-IniValue -Path $appIniPath -Section "App" -Key "Version"
$buildId = Get-IniValue -Path $appIniPath -Section "App" -Key "BuildID"
if (-not $firefoxVersion) {
  $versionMatch = [regex]::Match($zip.Name, '^firefox-(.+?)\.[a-z]{2}-[A-Z]{2}\.')
  if ($versionMatch.Success) {
    $firefoxVersion = $versionMatch.Groups[1].Value
  }
}

if (-not $Tag) {
  if ($firefoxVersion) {
    $Tag = "bluffy-v$firefoxVersion"
  } else {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $sha = (git rev-parse --short HEAD).Trim()
    $Tag = "bluffy-$stamp-$sha"
  }
}

if (-not $Title) {
  if ($firefoxVersion) {
    $Title = "Bluffy Firefox $firefoxVersion"
  } else {
    $Title = $Tag
  }
}

$uploadFiles = @($installer.FullName, $zip.FullName)
$xpt = Get-ChildItem -Path $distDir -Recurse -File -Filter "*.xpt_artifacts.zip" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if ($xpt) {
  $uploadFiles += $xpt.FullName
}

$repo = Get-GitHubRepoFromRemote "fork"
if (-not $repo) {
  $repo = Get-GitHubRepoFromRemote "origin"
}
if (-not $repo) {
  throw "Cannot determine GitHub repo from git remotes."
}

$marForUpload = $null
$updateXmlOut = $null

if (-not $SkipMar) {
  $bashExe = Get-PreferredBash
  if (-not $bashExe) {
    throw "bash is required for make_full_update.sh but was not found in PATH."
  }

  $nativeMarExe = Get-MarExe -TopObjDir $topObjDir
  $shouldSignMar = $SignMar -or (-not $SkipMarSign)

  $packageRoot = Join-Path $distDir "firefox"
  if (-not (Test-Path $packageRoot)) {
    throw "Packaged Firefox directory not found at $packageRoot. Run ./mach package first."
  }

  if (-not $MarOutputPath) {
    $marName = "bluffy-$firefoxVersion-$UpdateChannel.complete.mar"
    $MarOutputPath = Join-Path $repoRoot ("updates\" + $marName)
  }
  $marOutputFull = [System.IO.Path]::GetFullPath($MarOutputPath)
  $marOutDir = Split-Path -Parent $marOutputFull
  if (-not (Test-Path $marOutDir)) {
    New-Item -ItemType Directory -Path $marOutDir | Out-Null
  }

  $marCommandParts = @()
  if ($nativeMarExe) {
    $marCommandParts = @($nativeMarExe)
    if ($shouldSignMar) {
      $keyFull = if ([System.IO.Path]::IsPathRooted($MarSigningKeyPath)) {
        $MarSigningKeyPath
      } else {
        Join-Path $repoRoot $MarSigningKeyPath
      }
      $keyFull = [System.IO.Path]::GetFullPath($keyFull)
      if (-not (Test-Path $keyFull)) {
        throw "MAR signing key not found: $keyFull"
      }
      $marCommandParts += @("-k", $keyFull)
    }
  } else {
    $python = Get-PythonRuntime
    Ensure-PythonMarAvailable -PythonRuntime $python
    $pythonDir = Split-Path -Parent $python.Exe
    $pythonMarExe = Join-Path $pythonDir "mar.exe"
    if (-not (Test-Path $pythonMarExe)) {
      throw "mar.exe was not found in Python environment: $pythonMarExe"
    }
    $marCommandParts = @($pythonMarExe)
    if ($shouldSignMar) {
      $keyFull = if ([System.IO.Path]::IsPathRooted($MarSigningKeyPath)) {
        $MarSigningKeyPath
      } else {
        Join-Path $repoRoot $MarSigningKeyPath
      }
      $keyFull = [System.IO.Path]::GetFullPath($keyFull)
      if (-not (Test-Path $keyFull)) {
        throw "MAR signing key not found: $keyFull"
      }
      $marCommandParts += @("-k", $keyFull)
    }
  }

  $marWrapperPath = Join-Path $env:TEMP ("mar-wrapper-" + [guid]::NewGuid().ToString("N") + ".sh")
  $marWrapperPosix = Convert-ToPosixPath -Path $marWrapperPath
  $marCmdBash = ($marCommandParts | ForEach-Object {
      Convert-ToBashSingleQuoted -Value (Convert-ToPosixPath -Path $_)
    }) -join " "
  $wrapperBody = "#!/usr/bin/env bash`nexec $marCmdBash `"`$@`"`n"
  [System.IO.File]::WriteAllText($marWrapperPath, $wrapperBody, [System.Text.UTF8Encoding]::new($false))

  $packageRootPosix = Convert-ToPosixPath -Path $packageRoot
  $marOutputPosix = Convert-ToPosixPath -Path $marOutputFull
  $repoRootPosix = Convert-ToPosixPath -Path $repoRoot
  $makeUpdate = "./tools/update-packaging/make_full_update.sh"
  $exportLine = "export MAR=$(Convert-ToBashSingleQuoted -Value $marWrapperPosix) MOZ_PRODUCT_VERSION=$(Convert-ToBashSingleQuoted -Value $firefoxVersion) MAR_CHANNEL_ID=$(Convert-ToBashSingleQuoted -Value $UpdateChannel)"
  $fallbackOutputMar = Join-Path $repoRoot "output.mar"
  if (Test-Path $fallbackOutputMar) {
    Remove-Item -LiteralPath $fallbackOutputMar -Force
  }
  $bashScript = @(
    "chmod +x $(Convert-ToBashSingleQuoted -Value $marWrapperPosix)",
    "cd $(Convert-ToBashSingleQuoted -Value $repoRootPosix)",
    $exportLine,
    "$makeUpdate $(Convert-ToBashSingleQuoted -Value $marOutputPosix) $(Convert-ToBashSingleQuoted -Value $packageRootPosix)"
  ) -join " && "

  try {
    Invoke-CheckedCommand -Exe $bashExe -CmdArgs @("-lc", $bashScript) | Out-Null
  } finally {
    Remove-Item -LiteralPath $marWrapperPath -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path $marOutputFull) -and (Test-Path $fallbackOutputMar)) {
    Move-Item -LiteralPath $fallbackOutputMar -Destination $marOutputFull -Force
  }
  if (-not (Test-Path $marOutputFull)) {
    throw "MAR file was not created: $marOutputFull"
  }

  $marForUpload = $marOutputFull

}

Invoke-Gh -GhArgs @("auth", "status")

$releaseExists = $true
try {
  Invoke-Gh -GhArgs @("release", "view", $Tag, "--repo", $repo)
} catch {
  $releaseExists = $false
}

if (-not $releaseExists) {
  $createArgs = @("release", "create", $Tag, "--title", $Title, "--notes", "Automated build release: $Tag")
  if ($Draft) {
    $createArgs += "--draft"
  }
  if ($PreRelease) {
    $createArgs += "--prerelease"
  }
  $createArgs += @("--repo", $repo)
  Invoke-Gh -GhArgs $createArgs
}

if (-not $SkipUpdateXml -and $marForUpload) {
  $updateXmlOut = [System.IO.Path]::GetFullPath($UpdateXmlPath)
  $updateDir = Split-Path -Parent $updateXmlOut
  if ($updateDir -and -not (Test-Path $updateDir)) {
    New-Item -ItemType Directory -Path $updateDir | Out-Null
  }

  $marFileName = Split-Path -Leaf $marForUpload
  $marUrl = if ($MarUrlOverride) {
    $MarUrlOverride
  } else {
    "https://github.com/$repo/releases/download/$Tag/$marFileName"
  }

  $marHash = (Get-FileHash -Algorithm SHA512 -LiteralPath $marForUpload).Hash.ToLowerInvariant()
  $marSize = (Get-Item -LiteralPath $marForUpload).Length
  if (-not $buildId) {
    throw "BuildID was not detected from $appIniPath"
  }

  $xml = @"
<?xml version="1.0"?>
<updates>
  <update type="minor" displayVersion="$firefoxVersion" appVersion="$firefoxVersion" platformVersion="$firefoxVersion" buildID="$buildId">
    <patch type="complete" URL="$marUrl" hashFunction="sha512" hashValue="$marHash" size="$marSize"/>
  </update>
</updates>
"@
  [System.IO.File]::WriteAllText($updateXmlOut, $xml, [System.Text.UTF8Encoding]::new($false))
}

if ($marForUpload) {
  $uploadFiles += $marForUpload
}
if ($updateXmlOut) {
  $uploadFiles += $updateXmlOut
}

$uploadArgs = @("release", "upload", $Tag) + $uploadFiles + @("--repo", $repo, "--clobber")
Invoke-Gh -GhArgs $uploadArgs

$releaseUrl = (& $script:GhExe release view $Tag --repo $repo --json url -q .url).Trim()
if ($LASTEXITCODE -ne 0) {
  throw "Failed to read release URL."
}

Write-Host ""
Write-Host "Release uploaded:"
Write-Host "Repo: $repo"
Write-Host "Tag: $Tag"
Write-Host "URL: $releaseUrl"
if ($marForUpload) {
  Write-Host "MAR: $marForUpload"
}
if ($updateXmlOut) {
  Write-Host "Update XML: $updateXmlOut"
}
Write-Host "Files:"
$uploadFiles | ForEach-Object { Write-Host " - $_" }
} finally {
  Pop-Location
}

