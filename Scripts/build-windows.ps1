# Builds the Windows targets (service daemon and desktop shell) for the host
# architecture. Run on a Windows machine with the Swift 6.3.3 toolchain:
#   powershell -File Scripts\build-windows.ps1 [-Test] [-OutDir path] [-VcpkgRoot path]
param(
  [switch]$Test,
  [string]$OutDir = ".build\windows-dist",
  [string]$VcpkgRoot = ""
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

Push-Location $packagePath
try {
  $swiftArguments = @("-Xswiftc", "-DSQLITE_DISABLE_SNAPSHOT")
  if ($targetTriple) {
    $swiftArguments += @("--triple", $targetTriple)
  }
  swift build @swiftArguments --product codex-bridge-service
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  swift build @swiftArguments --product codex-bridge-windows-app
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  $binPathOutput = & swift build @swiftArguments --show-bin-path
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
        "BridgeServiceAppCoreTests")) {
      swift test @swiftArguments --filter $testFilter
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
  }

  $portableDir = Join-Path $resolvedOutDir $architecture
  $stageScript = Join-Path $repoRoot "Scripts\stage-windows-portable.ps1"
  $stageArguments = @(
    "-BinPath", $binPath,
    "-OutDir", $portableDir,
    "-Architecture", $architecture,
    "-VcpkgTriplet", $vcpkgTriplet)
  if ($targetTriple) {
    $stageArguments += @("-TargetTriple", $targetTriple)
  }
  if ($resolvedVcpkgRoot) {
    $stageArguments += @("-VcpkgRoot", $resolvedVcpkgRoot)
  }
  & $stageScript @stageArguments
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}
