# Builds the Windows targets (service daemon and desktop shell) for the host
# architecture. Run on a Windows machine with the Swift 6.3.3 toolchain:
#   powershell -File Scripts\build-windows.ps1 [-Test] [-Installer] [-OutDir path]
param(
  [switch]$Test,
  [switch]$Installer,
  [string]$OutDir = ".build\windows-dist",
  [string]$VcpkgRoot = "",
  [string]$VCRedistRoot = "",
  [string]$ISCCPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$packagePath = Join-Path $repoRoot "Packages\BridgeCore"
$resolvedOutDir = if ([IO.Path]::IsPathRooted($OutDir)) {
  [IO.Path]::GetFullPath($OutDir)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $OutDir))
}
$resolvedVcpkgRoot = if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
  ""
} elseif ([IO.Path]::IsPathRooted($VcpkgRoot)) {
  [IO.Path]::GetFullPath($VcpkgRoot)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $VcpkgRoot))
}
$resolvedVCRedistRoot = if ([string]::IsNullOrWhiteSpace($VCRedistRoot)) {
  ""
} elseif ([IO.Path]::IsPathRooted($VCRedistRoot)) {
  [IO.Path]::GetFullPath($VCRedistRoot)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $VCRedistRoot))
}

try {
  $hostArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
} catch {
  $hostArchitecture = $env:PROCESSOR_ARCHITECTURE
}
switch ($hostArchitecture.ToUpperInvariant()) {
  "X64" { $architecture = "x64" }
  "ARM64" { $architecture = "arm64" }
  default { throw "Unsupported Windows host architecture: $hostArchitecture" }
}
$vcpkgTriplet = "$architecture-windows"
$targetTriple = if ($architecture -eq "arm64") { "aarch64-unknown-windows-msvc" } else { "" }
$vcpkgRootValue = if ($resolvedVcpkgRoot) {
  $resolvedVcpkgRoot
} elseif (Test-Path Env:VCPKG_INSTALLATION_ROOT) {
  $env:VCPKG_INSTALLATION_ROOT
} else {
  ""
}
$originalPath = $env:PATH

if ($Test) {
  if (-not $vcpkgRootValue) {
    throw "VcpkgRoot or VCPKG_INSTALLATION_ROOT is required when running tests."
  }
  $sqliteRuntimeDirectory = Join-Path $vcpkgRootValue "installed\$vcpkgTriplet\bin"
  if (-not (Test-Path (Join-Path $sqliteRuntimeDirectory "sqlite3.dll"))) {
    throw "SQLite runtime is unavailable: $sqliteRuntimeDirectory\sqlite3.dll"
  }
  $env:PATH = "$sqliteRuntimeDirectory;$originalPath"
}

Push-Location $packagePath
try {
  $swiftArguments = @("-Xswiftc", "-DSQLITE_DISABLE_SNAPSHOT")
  if ($targetTriple) {
    $swiftArguments += @("--triple", $targetTriple)
  }
  $buildArguments = @($swiftArguments) + @("-c", "release")
  swift build @buildArguments --product codex-bridge-service
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  swift build @buildArguments --product codex-bridge-windows-app
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  $binPathOutput = & swift build @buildArguments --show-bin-path
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $binPath = ($binPathOutput | Select-Object -Last 1).ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($binPath)) {
    throw "Swift build output directory was empty."
  }

  if ($Test) {
    foreach ($testFilter in @(
        "BridgeDomainTests",
        "BridgeAgentCoreTests",
        "BridgeSecurityTests",
        "BridgeCodexRPCTests",
        "BridgeServiceAppCoreTests",
        "BridgeServiceHostWindowsTests",
        "BridgeCodexServiceWindowsTests",
        "BridgeServiceApplicationWindowsTests",
        "BridgeServiceCoreWindowsTests",
        "BridgeDirectCommandWindowsTests")) {
      swift test @swiftArguments --filter $testFilter
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
  }

  $portableDir = Join-Path $resolvedOutDir $architecture
  $stageScript = Join-Path $repoRoot "Scripts\stage-windows-portable.ps1"
  $stageArguments = @{
    BinPath = $binPath
    OutDir = $portableDir
    Architecture = $architecture
    VcpkgTriplet = $vcpkgTriplet
  }
  if ($targetTriple) {
    $stageArguments["TargetTriple"] = $targetTriple
  }
  if ($resolvedVcpkgRoot) {
    $stageArguments["VcpkgRoot"] = $resolvedVcpkgRoot
  }
  if ($resolvedVCRedistRoot) {
    $stageArguments["VCRedistRoot"] = $resolvedVCRedistRoot
  }
  & $stageScript @stageArguments
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  if ($Installer) {
    $installerOutDir = Join-Path $repoRoot ".build\windows-installer\$architecture"
    $installerArguments = @{
      Architecture = $architecture
      PayloadDir = $portableDir
      OutputDir = $installerOutDir
    }
    if ($ISCCPath) {
      $installerArguments["ISCCPath"] = $ISCCPath
    }
    & (Join-Path $repoRoot "Scripts\build-windows-installer.ps1") @installerArguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
} finally {
  Pop-Location
  $env:PATH = $originalPath
}
