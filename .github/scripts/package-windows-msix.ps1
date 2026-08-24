param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture,

  [string]$PackageVersion = '0.2.0.0',

  [string]$Publisher = 'CN=CodexBridge',

  [string]$IdentityName = 'org.codexbridge.windows'
)

$ErrorActionPreference = 'Stop'

if (-not $env:SWIFT_RUNTIME_BIN -or -not (Test-Path $env:SWIFT_RUNTIME_BIN)) {
  throw 'SWIFT_RUNTIME_BIN is unavailable.'
}
if (-not $env:SQLITE_RUNTIME_DIR -or -not (Test-Path $env:SQLITE_RUNTIME_DIR)) {
  throw 'SQLITE_RUNTIME_DIR is unavailable.'
}
if ($PackageVersion -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$') {
  throw 'PackageVersion must contain four numeric components.'
}
foreach ($component in $PackageVersion.Split('.')) {
  if ([int]$component -gt 65535) { throw 'PackageVersion components must not exceed 65535.' }
}
$publisherHasControl = @($Publisher.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0
if ([string]::IsNullOrWhiteSpace($Publisher) -or $Publisher.Length -gt 1024 -or
    $publisherHasControl) {
  throw 'Publisher is invalid.'
}
if ($IdentityName -notmatch '^[A-Za-z0-9.-]{3,50}$') {
  throw 'IdentityName is invalid.'
}

$manifestPath = (Resolve-Path 'Windows/CodexBridge.App/Package.appxmanifest').Path
$originalManifest = [System.IO.File]::ReadAllBytes($manifestPath)
try {
  [xml]$manifest = [System.IO.File]::ReadAllText($manifestPath)
  $identity = $manifest.Package.Identity
  $identity.SetAttribute('Name', $IdentityName)
  $identity.SetAttribute('Publisher', $Publisher)
  $identity.SetAttribute('Version', $PackageVersion)
  $settings = [System.Xml.XmlWriterSettings]::new()
  $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
  $settings.Indent = $true
  $writer = [System.Xml.XmlWriter]::Create($manifestPath, $settings)
  try { $manifest.Save($writer) } finally { $writer.Dispose() }

$bin = swift build --show-bin-path --package-path Packages/BridgeCore
if ($LASTEXITCODE -ne 0) { throw 'Unable to locate Swift build products.' }
$service = Join-Path $bin 'codex-bridge-service.exe'
if (-not (Test-Path $service)) { throw "Service executable is missing at $service" }

$payload = Join-Path $env:RUNNER_TEMP "CodexBridge-MSIX-$Architecture"
New-Item -ItemType Directory -Path $payload -Force | Out-Null
Copy-Item -LiteralPath $service -Destination (Join-Path $payload 'codex-bridge-service.exe')
Copy-Item -Path (Join-Path $env:SWIFT_RUNTIME_BIN '*.dll') -Destination $payload
$tunnelPayload = Join-Path $payload 'TunnelClient'
& "$PSScriptRoot/stage-windows-tunnel-client.ps1" `
  -Architecture $Architecture `
  -Destination $tunnelPayload
if ($LASTEXITCODE -ne 0) { throw "Tunnel client staging failed with exit code $LASTEXITCODE" }
$webViewPayload = Join-Path $payload 'FixedRuntime\151.0.4129.101'
& "$PSScriptRoot/stage-windows-webview2-runtime.ps1" `
  -Architecture $Architecture `
  -Destination $webViewPayload
if ($LASTEXITCODE -ne 0) { throw "WebView2 staging failed with exit code $LASTEXITCODE" }
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
$package = $packages[0]
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($package.FullName)
try {
  $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
  $requiredEntries = @(
    'TunnelClient/tunnel-client.exe',
    'TunnelClient/cloudflared.exe',
    'FixedRuntime/151.0.4129.101/msedgewebview2.exe',
    'coreclr.dll',
    'hostfxr.dll',
    'Microsoft.UI.Xaml.dll'
  )
  foreach ($entry in $requiredEntries) {
    if ($entries -inotcontains $entry) { throw "MSIX is missing required self-contained payload: $entry" }
  }
} finally {
  $archive.Dispose()
}
if ($env:GITHUB_OUTPUT) {
  Add-Content $env:GITHUB_OUTPUT "msix=$($package.FullName)"
}
Write-Host "Unsigned MSIX: $($package.FullName)"
} finally {
  [System.IO.File]::WriteAllBytes($manifestPath, $originalManifest)
}
