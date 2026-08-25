param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  [string]$AppVersion = '0.2.0.0',

  [switch]$FastCompression
)

$ErrorActionPreference = 'Stop'

if ($AppVersion -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$') {
  throw 'AppVersion must contain four numeric components.'
}
foreach ($component in $AppVersion.Split('.')) {
  if ([int]$component -gt 65535) { throw 'AppVersion components must not exceed 65535.' }
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Output directory already exists: $OutputDirectory"
}

$applicationManifestPath = 'Windows/CodexBridge.App/app.manifest'
[xml]$applicationManifest = Get-Content -LiteralPath $applicationManifestPath -Raw
$perMonitorV2 = $applicationManifest.SelectNodes(
  "//*[local-name()='dpiAwareness' and namespace-uri()='http://schemas.microsoft.com/SMI/2016/WindowsSettings' and normalize-space(text())='PerMonitorV2']"
)
$invalidLegacyDpi = $applicationManifest.SelectNodes(
  "//*[local-name()='dpiAware' and namespace-uri()='http://schemas.microsoft.com/SMI/2005/WindowsSettings' and contains(normalize-space(text()), 'PerMonitorV2')]"
)
if ($perMonitorV2.Count -ne 1 -or $invalidLegacyDpi.Count -ne 0) {
  throw 'The app manifest must declare PerMonitorV2 with the 2016 dpiAwareness schema.'
}

$output = New-Item -ItemType Directory -Path $OutputDirectory
$completed = $false
$stagingRoot = Join-Path $env:RUNNER_TEMP "CodexBridge-Unpackaged-$Architecture-$([guid]::NewGuid())"
$servicePayload = Join-Path $stagingRoot 'ServicePayload'
$publish = Join-Path $stagingRoot 'Publish'

try {
& "$PSScriptRoot/stage-windows-app-payload.ps1" `
  -Architecture $Architecture `
  -Destination $servicePayload

$runtimeIdentifier = if ($Architecture -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
$project = 'Windows/CodexBridge.App/CodexBridge.App.csproj'
$properties = @(
  "-p:Platform=$Architecture",
  "-p:RuntimeIdentifier=$runtimeIdentifier",
  '-p:WindowsPackageType=None',
  '-p:BuildSelfContained=true',
  '-p:PublishSingleFile=false',
  '-p:PublishTrimmed=false',
  '-p:DebugType=None',
  '-p:DebugSymbols=false',
  "-p:Version=$AppVersion",
  "-p:BridgeServicePayload=$servicePayload",
  "-p:PublishDir=$publish"
)

& dotnet restore $project @properties
if ($LASTEXITCODE -ne 0) { throw "Unpackaged restore failed with exit code $LASTEXITCODE" }
& dotnet publish $project --no-restore --configuration Release --self-contained true @properties
if ($LASTEXITCODE -ne 0) { throw "Unpackaged publish failed with exit code $LASTEXITCODE" }

$required = @(
  'CodexBridge.App.exe',
  'CodexBridge.App.dll',
  'CodexBridge.App.deps.json',
  'CodexBridge.App.runtimeconfig.json',
  'codex-bridge-service.exe',
  'sqlite3.dll',
  'coreclr.dll',
  'hostfxr.dll',
  'Microsoft.WindowsAppRuntime.dll',
  'Microsoft.UI.pri',
  'Microsoft.UI.Xaml.dll',
  'Microsoft.UI.Xaml.Controls.pri',
  'WebView2Loader.dll',
  'TunnelClient\tunnel-client.exe',
  'TunnelClient\cloudflared.exe',
  'FixedRuntime\151.0.4129.101\msedgewebview2.exe'
)
foreach ($relative in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $publish $relative))) {
    throw "Unpackaged payload is missing $relative"
  }
}

$manifest = Get-ChildItem -LiteralPath $publish -File -Recurse | Sort-Object FullName | ForEach-Object {
  [ordered]@{
    path = [IO.Path]::GetRelativePath($publish, $_.FullName).Replace('\', '/')
    bytes = $_.Length
    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}
$manifestPath = Join-Path $publish 'payload-manifest.json'
[IO.File]::WriteAllText(
  $manifestPath,
  ($manifest | ConvertTo-Json -Depth 3),
  [Text.UTF8Encoding]::new($false)
)

$architectureName = $Architecture.ToLowerInvariant()
$assetBase = "CodexBridge-Windows-$architectureName-$AppVersion"

$isccPath = @(
  Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
  Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $isccPath) {
  $isccPath = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
}
if (-not $isccPath) { throw 'Inno Setup Compiler 6.7.1 was not found.' }
$isccBanner = (& $isccPath '/?' 2>&1) -join "`n"
if ($isccBanner -notmatch '(?i)Inno Setup') {
  throw "The resolved executable is not Inno Setup Compiler: $isccBanner"
}
$installerScript = (Resolve-Path 'Windows/Installer/CodexBridge.iss').Path
$setupBase = "$assetBase-Setup"
$compression = if ($FastCompression) { 'lzma2/fast' } else { 'lzma2/max' }
& $isccPath `
  "/DPayloadDir=$publish" `
  "/DOutputDir=$($output.FullName)" `
  "/DArchitecture=$Architecture" `
  "/DAppVersion=$AppVersion" `
  "/DOutputBaseFilename=$setupBase" `
  "/DCompression=$compression" `
  $installerScript
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed with exit code $LASTEXITCODE" }

$setup = Join-Path $output.FullName "$setupBase.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw "Installer was not created at $setup" }

if ($env:GITHUB_OUTPUT) {
  Add-Content $env:GITHUB_OUTPUT "setup=$setup"
}
Write-Host "Windows installer: $setup"
$completed = $true
} finally {
  if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
  }
  if (-not $completed -and (Test-Path -LiteralPath $output.FullName)) {
    Remove-Item -LiteralPath $output.FullName -Recurse -Force
  }
}
