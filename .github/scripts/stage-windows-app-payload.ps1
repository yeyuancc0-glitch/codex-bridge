param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture,

  [Parameter(Mandatory = $true)]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'

if (-not $env:SWIFT_RUNTIME_BIN -or -not (Test-Path -LiteralPath $env:SWIFT_RUNTIME_BIN)) {
  throw 'SWIFT_RUNTIME_BIN is unavailable.'
}
if (-not $env:SQLITE_RUNTIME_DIR -or -not (Test-Path -LiteralPath $env:SQLITE_RUNTIME_DIR)) {
  throw 'SQLITE_RUNTIME_DIR is unavailable.'
}
if (Test-Path -LiteralPath $Destination) {
  throw "Payload destination already exists: $Destination"
}

$bin = swift build --show-bin-path --package-path Packages/BridgeCore
if ($LASTEXITCODE -ne 0) { throw 'Unable to locate Swift build products.' }
$service = Join-Path $bin 'codex-bridge-service.exe'
if (-not (Test-Path -LiteralPath $service)) {
  throw "Service executable is missing at $service"
}

New-Item -ItemType Directory -Path $Destination | Out-Null
Copy-Item -LiteralPath $service -Destination (Join-Path $Destination 'codex-bridge-service.exe')
Copy-Item -Path (Join-Path $env:SWIFT_RUNTIME_BIN '*.dll') -Destination $Destination

$tunnelPayload = Join-Path $Destination 'TunnelClient'
& "$PSScriptRoot/stage-windows-tunnel-client.ps1" `
  -Architecture $Architecture `
  -Destination $tunnelPayload
if ($LASTEXITCODE -ne 0) { throw "Tunnel client staging failed with exit code $LASTEXITCODE" }

$webViewPayload = Join-Path $Destination 'FixedRuntime\151.0.4129.101'
& "$PSScriptRoot/stage-windows-webview2-runtime.ps1" `
  -Architecture $Architecture `
  -Destination $webViewPayload
if ($LASTEXITCODE -ne 0) { throw "WebView2 staging failed with exit code $LASTEXITCODE" }

$sqlite = Join-Path $env:SQLITE_RUNTIME_DIR 'sqlite3.dll'
if (-not (Test-Path -LiteralPath $sqlite)) { throw "SQLite runtime is missing at $sqlite" }
Copy-Item -LiteralPath $sqlite -Destination (Join-Path $Destination 'sqlite3.dll')

Write-Host "Windows $Architecture app payload staged at $Destination"
