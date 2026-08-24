param(
  [Parameter(Mandatory = $true)]
  [string]$InputDirectory,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  [Parameter(Mandatory = $true)]
  [string]$PackageVersion,

  [Parameter(Mandatory = $true)]
  [string]$Publisher,

  [Parameter(Mandatory = $true)]
  [string]$IdentityName,

  [Parameter(Mandatory = $true)]
  [string]$ReleaseBaseUri
)

$ErrorActionPreference = 'Stop'

$parsedReleaseUri = $null
if (-not [Uri]::TryCreate($ReleaseBaseUri, [UriKind]::Absolute, [ref]$parsedReleaseUri) -or
    -not $ReleaseBaseUri.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'ReleaseBaseUri must be an absolute HTTPS URL.'
}

$packages = @(Get-ChildItem -Path $InputDirectory -Recurse -Filter 'CodexBridge.App_*.msix' | Where-Object {
  $_.FullName -notmatch '[\\/]Dependencies[\\/]'
})
if ($packages.Count -ne 2) {
  throw "Expected x64 and ARM64 MSIX packages, found $($packages.Count)."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$architectures = @{}
foreach ($package in $packages) {
  $archive = [System.IO.Compression.ZipFile]::OpenRead($package.FullName)
  try {
    $entry = $archive.GetEntry('AppxManifest.xml')
    if (-not $entry) { throw "AppxManifest.xml is missing from $($package.Name)." }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $identity = $manifest.Package.Identity
    if ($identity.GetAttribute('Name') -cne $IdentityName -or
        $identity.GetAttribute('Publisher') -cne $Publisher -or
        $identity.GetAttribute('Version') -cne $PackageVersion) {
      throw "Package identity mismatch in $($package.Name)."
    }
    $architecture = $identity.GetAttribute('ProcessorArchitecture').ToLowerInvariant()
    if ($architecture -notin @('x64', 'arm64') -or $architectures.ContainsKey($architecture)) {
      throw "Unexpected or duplicate package architecture: $architecture"
    }
    $architectures[$architecture] = $package.FullName
  } finally {
    $archive.Dispose()
  }
}

$makeAppx = Get-Command makeappx.exe -ErrorAction SilentlyContinue
if (-not $makeAppx) {
  $makeAppx = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '[\\/]x64[\\/]makeappx\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
}
if (-not $makeAppx) { throw 'makeappx.exe was not found.' }
$makeAppxPath = if ($makeAppx.Source) { $makeAppx.Source } else { $makeAppx.FullName }
$staging = Join-Path $env:RUNNER_TEMP "CodexBridge-Bundle-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $staging | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
try {
  Copy-Item -LiteralPath $architectures.x64 -Destination (Join-Path $staging 'CodexBridge-x64.msix')
  Copy-Item -LiteralPath $architectures.arm64 -Destination (Join-Path $staging 'CodexBridge-ARM64.msix')
  $bundle = Join-Path $OutputDirectory 'CodexBridge-Windows.msixbundle'
  & $makeAppxPath bundle /d $staging /p $bundle /o
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $bundle)) {
    throw "MakeAppx bundle failed with exit code $LASTEXITCODE"
  }

  function Escape-Xml([string]$Value) {
    return [System.Security.SecurityElement]::Escape($Value)
  }
  $base = $ReleaseBaseUri.TrimEnd('/')
  $appInstallerUri = "$base/CodexBridge-Windows.appinstaller"
  $bundleUri = "$base/CodexBridge-Windows.msixbundle"
  $appInstaller = Join-Path $OutputDirectory 'CodexBridge-Windows.appinstaller'
  $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller Uri="$(Escape-Xml $appInstallerUri)" Version="$(Escape-Xml $PackageVersion)" xmlns="http://schemas.microsoft.com/appx/appinstaller/2018">
  <MainBundle Name="$(Escape-Xml $IdentityName)" Publisher="$(Escape-Xml $Publisher)" Version="$(Escape-Xml $PackageVersion)" Uri="$(Escape-Xml $bundleUri)" />
  <UpdateSettings>
    <OnLaunch HoursBetweenUpdateChecks="0" ShowPrompt="true" UpdateBlocksActivation="false" />
  </UpdateSettings>
</AppInstaller>
"@
  [System.IO.File]::WriteAllText(
    $appInstaller,
    $xml,
    [System.Text.UTF8Encoding]::new($false)
  )
  if ($env:GITHUB_OUTPUT) {
    Add-Content $env:GITHUB_OUTPUT "bundle=$bundle"
    Add-Content $env:GITHUB_OUTPUT "appinstaller=$appInstaller"
  }
} finally {
  Remove-Item -LiteralPath $staging -Recurse -Force
}
