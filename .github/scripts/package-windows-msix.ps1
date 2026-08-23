param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture
)

$ErrorActionPreference = 'Stop'

if (-not $env:SWIFT_RUNTIME_BIN -or -not (Test-Path $env:SWIFT_RUNTIME_BIN)) {
  throw 'SWIFT_RUNTIME_BIN is unavailable.'
}
if (-not $env:SQLITE_RUNTIME_DIR -or -not (Test-Path $env:SQLITE_RUNTIME_DIR)) {
  throw 'SQLITE_RUNTIME_DIR is unavailable.'
}

$bin = swift build --show-bin-path --package-path Packages/BridgeCore
if ($LASTEXITCODE -ne 0) { throw 'Unable to locate Swift build products.' }
$service = Join-Path $bin 'codex-bridge-service.exe'
if (-not (Test-Path $service)) { throw "Service executable is missing at $service" }

$payload = Join-Path $env:RUNNER_TEMP "CodexBridge-MSIX-$Architecture"
New-Item -ItemType Directory -Path $payload -Force | Out-Null
Copy-Item -LiteralPath $service -Destination (Join-Path $payload 'codex-bridge-service.exe')
Copy-Item -Path (Join-Path $env:SWIFT_RUNTIME_BIN '*.dll') -Destination $payload
$sqlite = Join-Path $env:SQLITE_RUNTIME_DIR 'sqlite3.dll'
if (-not (Test-Path $sqlite)) { throw "SQLite runtime is missing at $sqlite" }
Copy-Item -LiteralPath $sqlite -Destination (Join-Path $payload 'sqlite3.dll')

$runtimeIdentifier = if ($Architecture -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
$arguments = @(
  'build',
  'Windows/CodexBridge.App/CodexBridge.App.csproj',
  '--configuration', 'Release',
  "-p:Platform=$Architecture",
  "-p:RuntimeIdentifier=$runtimeIdentifier",
  '-p:BuildMsix=true',
  '-p:AppxPackageSigningEnabled=false',
  "-p:BridgeServicePayload=$payload"
)
& dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw "MSIX build failed with exit code $LASTEXITCODE" }

$packages = Get-ChildItem -Path 'Windows/CodexBridge.App' -Recurse -Filter '*.msix'
if ($packages.Count -ne 1) {
  throw "Expected one unsigned MSIX, found $($packages.Count)."
}
Write-Host "Unsigned MSIX: $($packages[0].FullName)"
