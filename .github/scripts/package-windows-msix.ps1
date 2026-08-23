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
$project = 'Windows/CodexBridge.App/CodexBridge.App.csproj'
$properties = @(
  "-p:Platform=$Architecture",
  "-p:RuntimeIdentifier=$runtimeIdentifier",
  '-p:BuildMsix=true',
  '-p:AppxPackageSigningEnabled=false',
  "-p:BridgeServicePayload=$payload"
)

& dotnet restore $project @properties
if ($LASTEXITCODE -ne 0) { throw "MSIX restore failed with exit code $LASTEXITCODE" }

$assets = Get-Content 'Windows/CodexBridge.App/obj/project.assets.json' -Raw | ConvertFrom-Json
$packageRoot = ($assets.packageFolders.PSObject.Properties | Select-Object -First 1).Name

function Resolve-PackagePath([string]$Prefix) {
  $packages = @($assets.libraries.PSObject.Properties | Where-Object { $_.Name -like "$Prefix/*" })
  if ($packages.Count -ne 1) {
    throw "Expected one $Prefix package, found $($packages.Count)."
  }
  return Join-Path $packageRoot $packages[0].Value.path
}

# The MSIX task has an undeclared System.Security.Permissions dependency. Keep
# the workaround isolated to its load directory instead of shipping it with the app.
$msixPackage = Resolve-PackagePath 'Microsoft.Windows.SDK.BuildTools.MSIX'
$permissionsPackage = Resolve-PackagePath 'System.Security.Permissions'
$taskDirectory = Join-Path $env:RUNNER_TEMP "CodexBridge-MSIX-Tasks-$Architecture"
New-Item -ItemType Directory -Path $taskDirectory -Force | Out-Null
Copy-Item -Path (Join-Path $msixPackage 'tools/net6.0/*') -Destination $taskDirectory
Copy-Item -LiteralPath (Join-Path $permissionsPackage 'lib/net8.0/System.Security.Permissions.dll') -Destination $taskDirectory
$taskAssemblyLocation = $taskDirectory.TrimEnd('\') + '\'

$arguments = @(
  'build',
  $project,
  '--no-restore',
  '--configuration', 'Release',
  $properties,
  "-p:MsixTaskAssemblyLocation=$taskAssemblyLocation"
)
& dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw "MSIX build failed with exit code $LASTEXITCODE" }

$architectureSuffix = "_$($Architecture.ToLowerInvariant()).msix"
$packages = @(Get-ChildItem -Path 'Windows/CodexBridge.App' -Recurse -Filter '*.msix' | Where-Object {
  $_.Name.StartsWith('CodexBridge.App_', [System.StringComparison]::OrdinalIgnoreCase) -and
    $_.Name.EndsWith($architectureSuffix, [System.StringComparison]::OrdinalIgnoreCase)
})
if ($packages.Count -ne 1) {
  throw "Expected one unsigned Codex Bridge $Architecture MSIX, found $($packages.Count)."
}
Write-Host "Unsigned MSIX: $($packages[0].FullName)"
