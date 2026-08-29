# Builds the Windows targets (service daemon and desktop shell) for the host
# architecture. Run on a Windows machine with the Swift 6.1 toolchain:
#   powershell -File Scripts\build-windows.ps1 [-Test] [-OutDir path]
param(
  [switch]$Test,
  [string]$OutDir = ".build\windows-dist"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$packagePath = Join-Path $repoRoot "Packages\BridgeCore"
$buildDir = Join-Path $packagePath ".build\debug"

Push-Location $packagePath
try {
  swift build --product codex-bridge-service
  swift build --product codex-bridge-windows-app

  if ($Test) {
    swift test --filter "BridgeDomainTests|BridgeCodexRPCTests|BridgeAgentCoreTests"
  }

  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Copy-Item (Join-Path $buildDir "codex-bridge-service.exe") $OutDir
  Copy-Item (Join-Path $buildDir "codex-bridge-windows-app.exe") $OutDir

  Write-Host "Dist artifacts written to $OutDir"
  Write-Host "Run codex-bridge-service.exe first (or let the app spawn it), then codex-bridge-windows-app.exe."
} finally {
  Pop-Location
}
