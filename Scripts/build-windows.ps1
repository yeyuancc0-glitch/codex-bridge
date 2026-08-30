# Builds the Windows targets (service daemon and desktop shell) for the host
# architecture. Run on a Windows machine with the Swift 6.3.3 toolchain:
#   powershell -File Scripts\build-windows.ps1 [-Test] [-OutDir path]
param(
  [switch]$Test,
  [string]$OutDir = ".build\windows-dist"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$packagePath = Join-Path $repoRoot "Packages\BridgeCore"

Push-Location $packagePath
try {
  swift build --product codex-bridge-service
  swift build --product codex-bridge-windows-app

  $binPathOutput = & swift build --show-bin-path
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $binPath = ($binPathOutput | Select-Object -Last 1).ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($binPath)) {
    throw "Swift build output directory was empty."
  }

  if ($Test) {
    swift test --filter "BridgeDomainTests"
  }

  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Copy-Item (Join-Path $binPath "codex-bridge-service.exe") $OutDir
  Copy-Item (Join-Path $binPath "codex-bridge-windows-app.exe") $OutDir

  Write-Host "Dist artifacts written to $OutDir"
  Write-Host "Run codex-bridge-service.exe first (or let the app spawn it), then codex-bridge-windows-app.exe."
} finally {
  Pop-Location
}
