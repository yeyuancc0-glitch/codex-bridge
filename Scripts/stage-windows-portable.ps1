# Stages a Windows portable directory and ZIP for one architecture.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BinPath,
  [Parameter(Mandatory = $true)]
  [string]$OutDir,
  [Parameter(Mandatory = $true)]
  [ValidateSet("x64", "arm64")]
  [string]$Architecture,
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z0-9._-]+$")]
  [string]$VcpkgTriplet,
  [string]$TargetTriple = "",
  [string]$VcpkgRoot = "",
  [string]$VCRedistRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path Env:OS) -or $env:OS -ne "Windows_NT") {
  throw "Scripts\stage-windows-portable.ps1 must run on Windows."
}

$scriptDirectory = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDirectory "windows-portable-support.ps1")
. (Join-Path $scriptDirectory "windows-portable-runtime.ps1")
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $scriptDirectory))
$expectedMachine = if ($Architecture -eq "x64") { [UInt16]0x8664 } else { [UInt16]0xAA64 }
$effectiveTargetTriple = if ([string]::IsNullOrWhiteSpace($TargetTriple)) {
  if ($Architecture -eq "x64") { "x86_64-unknown-windows-msvc" } else { "aarch64-unknown-windows-msvc" }
} else { $TargetTriple }
$expectedVcpkgTriplet = "$Architecture-windows"
if (-not $VcpkgTriplet.Equals($expectedVcpkgTriplet, [StringComparison]::OrdinalIgnoreCase)) {
  throw "VcpkgTriplet must match the requested architecture: $expectedVcpkgTriplet"
}
$webView2Version = "1.0.4191.47"
$webView2Hash = "f492bbf547d0da329553b6727435b677579b1e9f91cc9e4a1ad029366d5f23d0"

function Stage-File([string]$Source, [string]$Name) {
  Assert-RegularFile $Source | Out-Null
  $destination = Join-Path $outFull $Name
  if (Test-Path -LiteralPath $destination) {
    $existingHash = Get-Sha256 $destination
    if ($existingHash -ne (Get-Sha256 $Source)) {
      throw "Conflicting files would share the staged name '$Name'."
    }
    return
  }
  Copy-Item -LiteralPath $Source -Destination $destination -Force
}

function Get-SwiftVersion {
  $output = @(& swift --version 2>&1)
  if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
    throw "swift --version failed."
  }
  return ($output | Select-Object -First 1).ToString().Trim()
}

function Get-GitCommit {
  $commit = @(& git -C $repoRoot rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -eq 0 -and $commit.Count -gt 0) {
    return ($commit | Select-Object -First 1).ToString().Trim()
  }
  if ((Test-Path Env:GITHUB_SHA) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
    return $env:GITHUB_SHA
  }
  return "unknown"
}

$binFull = Get-FullPath $BinPath
Assert-Directory $binFull | Out-Null
$outFull = Get-FullPath $OutDir
$repoComparable = Get-ComparablePath $repoRoot
$outComparable = Get-ComparablePath $outFull
$buildRoot = Get-ComparablePath (Join-Path $repoRoot ".build")
if ($outComparable.Equals($buildRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-SameOrChildPath $buildRoot $outFull)) {
  throw "OutDir must be a child of the repository .build directory."
}
if ((Test-SameOrChildPath $binFull $outFull) -or
    (Test-SameOrChildPath $outFull $binFull)) {
  throw "OutDir and BinPath must be separate trees."
}

$zipPath = Join-Path (Split-Path -Parent $outFull) "codex-bridge-windows-$Architecture.zip"
$zipComparable = Get-ComparablePath $zipPath
$zipRootComparable = Get-ComparablePath ([IO.Path]::GetPathRoot($zipPath))
if ($zipComparable.Equals($zipRootComparable, [StringComparison]::OrdinalIgnoreCase) -or
    $zipComparable.Equals($repoComparable, [StringComparison]::OrdinalIgnoreCase)) {
  throw "The sibling ZIP path is not safe."
}
Ensure-SafeDirectoryChain $repoRoot (Split-Path -Parent $outFull)
if (Test-Path -LiteralPath $outFull) {
  Assert-Directory $outFull | Out-Null
}
if (Test-Path -LiteralPath $zipPath) {
  Assert-RegularFile $zipPath | Out-Null
}
Remove-ExactPath $outFull
Remove-ExactPath $zipPath
New-Item -ItemType Directory -Path $outFull -Force | Out-Null

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-bridge-portable-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
  $servicePath = Join-Path $binFull "codex-bridge-service.exe"
  $applicationPath = Join-Path $binFull "codex-bridge-windows-app.exe"
  foreach ($binary in @($servicePath, $applicationPath)) {
    Assert-RegularFile $binary | Out-Null
    if ((Get-PEMachine $binary) -ne $expectedMachine) {
      throw "Binary has the wrong architecture: $binary"
    }
  }
  Stage-File $servicePath "codex-bridge-service.exe"
  Stage-File $applicationPath "codex-bridge-windows-app.exe"
  Stage-File (Join-Path $repoRoot "LICENSE") "LICENSE.txt"
  Stage-File (Join-Path $repoRoot "NOTICE") "NOTICE.txt"

  $swiftRuntimeModule = Resolve-SwiftRuntimeMergeModule $Architecture
  $swiftRuntimeDirectory = Join-Path $temporaryRoot "swift-runtime"
  Expand-SwiftRuntimeMergeModule $swiftRuntimeModule $swiftRuntimeDirectory
  $swiftRuntimeFiles = @(Get-ChildItem -LiteralPath $swiftRuntimeDirectory -Filter "*.dll" -File -Recurse)
  if (-not ($swiftRuntimeFiles.Name -contains "swiftCore.dll")) {
    throw "Swift runtime merge module is missing swiftCore.dll."
  }
  foreach ($swiftRuntimeFile in $swiftRuntimeFiles) {
    Assert-RegularFile $swiftRuntimeFile.FullName | Out-Null
    if ((Get-PEMachine $swiftRuntimeFile.FullName) -ne $expectedMachine) {
      throw "Swift runtime DLL has the wrong architecture: $($swiftRuntimeFile.FullName)"
    }
    Stage-File $swiftRuntimeFile.FullName $swiftRuntimeFile.Name
  }

  $vcpkgRootValue = $VcpkgRoot
  if ([string]::IsNullOrWhiteSpace($vcpkgRootValue) -and (Test-Path Env:VCPKG_INSTALLATION_ROOT)) {
    $vcpkgRootValue = $env:VCPKG_INSTALLATION_ROOT
  }
  if ([string]::IsNullOrWhiteSpace($vcpkgRootValue)) {
    throw "VcpkgRoot or VCPKG_INSTALLATION_ROOT is required."
  }
  $vcpkgRootFull = Get-FullPath $vcpkgRootValue
  Assert-Directory $vcpkgRootFull | Out-Null
  $sqlitePath = Join-Path $vcpkgRootFull "installed\$VcpkgTriplet\bin\sqlite3.dll"
  Assert-RegularFile $sqlitePath | Out-Null
  if ((Get-PEMachine $sqlitePath) -ne $expectedMachine) {
    throw "sqlite3.dll has the wrong architecture: $sqlitePath"
  }
  Stage-File $sqlitePath "sqlite3.dll"

  $vcRedistRootFull = Resolve-VCRedistRoot $VCRedistRoot
  Assert-Directory $vcRedistRootFull | Out-Null
  $vcArchitectureRoot = Join-Path $vcRedistRootFull $Architecture
  Assert-Directory $vcArchitectureRoot | Out-Null
  $vcRuntimeCandidates = @(Get-ChildItem -LiteralPath $vcArchitectureRoot -Directory |
      Where-Object { $_.Name -match "^Microsoft\.VC[0-9]+\.CRT$" })
  if ($vcRuntimeCandidates.Count -ne 1) {
    throw "Expected exactly one architecture-matching Visual C++ runtime directory."
  }
  $vcRuntimeDirectory = $vcRuntimeCandidates[0]
  Assert-Directory $vcRuntimeDirectory.FullName | Out-Null
  $vcRuntimeFiles = @(
    Get-ChildItem -LiteralPath $vcRuntimeDirectory.FullName -Filter "*.dll" -File |
      Where-Object {
        $compatible = Test-PEArchitectureCompatible $_.FullName $Architecture
        if (-not $compatible) {
          Write-Host "Skipping incompatible VC runtime companion: $($_.Name)"
        }
        $compatible
      }
  )
  if (-not ($vcRuntimeFiles.Name -contains "vcruntime140.dll")) {
    throw "Visual C++ runtime directory is missing a compatible vcruntime140.dll."
  }
  foreach ($vcRuntimeFile in $vcRuntimeFiles) {
    Assert-RegularFile $vcRuntimeFile.FullName | Out-Null
    Stage-File $vcRuntimeFile.FullName $vcRuntimeFile.Name
  }

  $resourceCandidates = @(Get-ChildItem -LiteralPath $binFull -Directory -Recurse |
      Where-Object { $_.Name -in @("BridgeCore_BridgeDeepSeekHarnessACP.bundle", "BridgeCore_BridgeDeepSeekHarnessACP.resources") })
  if ($resourceCandidates.Count -ne 1) {
    throw "Expected exactly one production DeepSeek Harness resource directory."
  }
  Assert-Directory $resourceCandidates[0].FullName | Out-Null
  Copy-Item -LiteralPath $resourceCandidates[0].FullName -Destination (Join-Path $outFull $resourceCandidates[0].Name) -Recurse -Force

  $packagePath = Join-Path $temporaryRoot "webview2-package.zip"
  $packageUri = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$webView2Version/microsoft.web.webview2.$webView2Version.nupkg"
  Invoke-WebRequest -UseBasicParsing -Uri $packageUri -OutFile $packagePath
  if ((Get-Sha256 $packagePath) -ne $webView2Hash) {
    throw "WebView2 SDK package SHA-256 did not match the pinned value."
  }
  $extractPath = Join-Path $temporaryRoot "package"
  Expand-Archive -LiteralPath $packagePath -DestinationPath $extractPath -Force
  $loaderPath = Join-Path $extractPath "build\native\$Architecture\WebView2Loader.dll"
  Assert-RegularFile $loaderPath | Out-Null
  if ((Get-PEMachine $loaderPath) -ne $expectedMachine) {
    throw "WebView2Loader.dll has the wrong architecture: $loaderPath"
  }
  Stage-File $loaderPath "WebView2Loader.dll"
  Stage-File (Join-Path $extractPath "LICENSE.txt") "Microsoft.Web.WebView2.LICENSE.txt"
  Stage-File (Join-Path $extractPath "NOTICE.txt") "Microsoft.Web.WebView2.NOTICE.txt"

  $buildInfo = [ordered]@{
    schema = "codex-bridge-windows-portable/v1"
    architecture = $Architecture
    targetTriple = $effectiveTargetTriple
    gitCommit = Get-GitCommit
    swiftVersion = Get-SwiftVersion
    swiftRuntimeMergeModule = (Split-Path -Leaf $swiftRuntimeModule)
    webView2SDKVersion = $webView2Version
    webView2PackageSHA256 = $webView2Hash
    vcRedistVersion = (Split-Path -Leaf $vcRedistRootFull)
    vcRuntimeDirectory = $vcRuntimeDirectory.Name
  }
  $buildInfoPath = Join-Path $outFull "BUILD-INFO.json"
  $utf8NoBom = [Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText(
    $buildInfoPath,
    (($buildInfo | ConvertTo-Json -Depth 3) + [Environment]::NewLine),
    $utf8NoBom)

  $sumPath = Join-Path $outFull "SHA256SUMS.txt"
  $sumLines = @(Get-ChildItem -LiteralPath $outFull -File -Recurse |
      Where-Object { $_.FullName -ne $sumPath } |
      ForEach-Object {
        $relative = $_.FullName.Substring($outFull.Length) -replace "^[\\/]+", "" -replace "\\", "/"
        [PSCustomObject]@{ Relative = $relative; Line = "$(Get-Sha256 $_.FullName)  $relative" }
      } |
      Sort-Object Relative | Select-Object -ExpandProperty Line)
  [IO.File]::WriteAllLines($sumPath, [string[]]$sumLines, $utf8NoBom)

  Push-Location $outFull
  try {
    Compress-Archive -Path .\* -DestinationPath $zipPath -CompressionLevel Optimal -Force
  } finally {
    Pop-Location
  }
  Write-Host "Portable directory: $outFull"
  Write-Host "Portable ZIP: $zipPath"
} finally {
  if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
