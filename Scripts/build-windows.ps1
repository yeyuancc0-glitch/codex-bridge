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
  $swiftArguments = @("-Xswiftc", "-DSQLITE_DISABLE_SNAPSHOT")
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
    swift test @swiftArguments --filter "BridgeDomainTests"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    swift test @swiftArguments --filter "BridgeAgentCoreTests"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    swift test @swiftArguments --filter "BridgeSecurityTests"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    swift test @swiftArguments --filter "BridgeCodexRPCTests"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    swift test @swiftArguments --filter "BridgeServiceAppCoreTests"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Copy-Item (Join-Path $binPath "codex-bridge-service.exe") $OutDir
  Copy-Item (Join-Path $binPath "codex-bridge-windows-app.exe") $OutDir

  Write-Host "Dist artifacts written to $OutDir"
  Write-Host "Run codex-bridge-service.exe first (or let the app spawn it), then codex-bridge-windows-app.exe."
} finally {
  Pop-Location
}
