# Builds one architecture-specific Inno Setup EXE from a staged portable payload.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("x64", "arm64")]
  [string]$Architecture,
  [Parameter(Mandatory = $true)]
  [string]$PayloadDir,
  [Parameter(Mandatory = $true)]
  [string]$OutputDir,
  [string]$ISCCPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path Env:OS) -or $env:OS -ne "Windows_NT") {
  throw "Scripts\build-windows-installer.ps1 must run on Windows."
}

$scriptDirectory = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDirectory "windows-portable-support.ps1")
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $scriptDirectory))
$buildRoot = Join-Path $repoRoot ".build"
$installerRoot = Join-Path $buildRoot "windows-installer"

function Resolve-ISCC([string]$RequestedPath) {
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    $candidates += $RequestedPath
  }
  if (Test-Path Env:INNO_SETUP_ISCC) {
    $candidates += $env:INNO_SETUP_ISCC
  }
  $candidates += @(
    "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 7\ISCC.exe"
  )
  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and
        (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return (Get-FullPath $candidate)
    }
  }
  throw "Inno Setup 7.1.0 ISCC.exe was not found."
}

function Assert-SafePayload([string]$Root) {
  Assert-Directory $Root | Out-Null
  $directories = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force)
  foreach ($directory in $directories) {
    Assert-Directory $directory.FullName | Out-Null
  }
  $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)
  foreach ($file in $files) {
    Assert-RegularFile $file.FullName | Out-Null
  }
  return $files
}

function Assert-PayloadChecksums([string]$Root, [array]$Files) {
  $sumPath = Join-Path $Root "SHA256SUMS.txt"
  Assert-RegularFile $sumPath | Out-Null
  $seen = @{}
  foreach ($line in Get-Content -LiteralPath $sumPath) {
    if ($line -notmatch "^([0-9a-fA-F]{64})  (.+)$") {
      throw "SHA256SUMS.txt contains an invalid line."
    }
    $relative = $Matches[2] -replace "/", "\"
    $candidate = Get-FullPath (Join-Path $Root $relative)
    if (-not (Test-SameOrChildPath $Root $candidate) -or
        (Get-ComparablePath $candidate).Equals((Get-ComparablePath $Root), [StringComparison]::OrdinalIgnoreCase)) {
      throw "SHA256SUMS.txt contains an unsafe path."
    }
    $key = (Get-ComparablePath $candidate).ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
      throw "SHA256SUMS.txt contains a duplicate path."
    }
    Assert-RegularFile $candidate | Out-Null
    if ((Get-Sha256 $candidate) -ne $Matches[1].ToLowerInvariant()) {
      throw "Payload checksum mismatch: $relative"
    }
    $seen[$key] = $true
  }
  $manifestFiles = @($Files | Where-Object { $_.FullName -ne $sumPath })
  if ($seen.Count -ne $manifestFiles.Count) {
    throw "SHA256SUMS.txt does not cover the complete payload."
  }
}

$payloadFull = Get-FullPath $PayloadDir
$outputFull = Get-FullPath $OutputDir
if (-not (Test-SameOrChildPath $buildRoot $payloadFull)) {
  throw "PayloadDir must be inside the repository .build directory."
}
if (-not (Test-SameOrChildPath $installerRoot $outputFull)) {
  throw "OutputDir must be inside .build\windows-installer."
}
if ((Test-SameOrChildPath $payloadFull $outputFull) -or
    (Test-SameOrChildPath $outputFull $payloadFull)) {
  throw "PayloadDir and OutputDir must be separate trees."
}
$files = @(Assert-SafePayload $payloadFull)
Assert-PayloadChecksums $payloadFull $files

$buildInfoPath = Join-Path $payloadFull "BUILD-INFO.json"
$buildInfo = Get-Content -LiteralPath $buildInfoPath -Raw | ConvertFrom-Json
if ($buildInfo.schema -ne "codex-bridge-windows-portable/v1" -or
    $buildInfo.architecture -ne $Architecture -or
    $buildInfo.appVersion -notmatch "^[0-9]+(?:\.[0-9]+){2,3}$") {
  throw "BUILD-INFO.json does not match the installer request."
}
foreach ($required in @(
    "codex-bridge-windows-app.exe",
    "codex-bridge-service.exe",
    "swiftCore.dll",
    "sqlite3.dll",
    "WebView2Loader.dll",
    "LICENSE.txt",
    "NOTICE.txt")) {
  Assert-RegularFile (Join-Path $payloadFull $required) | Out-Null
}

$isccFull = Resolve-ISCC $ISCCPath
Assert-RegularFile $isccFull | Out-Null
$compilerVersion = @(& $isccFull --version 2>&1)
if ($LASTEXITCODE -ne 0 -or (($compilerVersion -join " ") -notmatch "\b7\.1\.0\b")) {
  throw "The installer must be compiled with Inno Setup 7.1.0."
}

Ensure-SafeDirectoryChain $repoRoot $installerRoot
if (Test-Path -LiteralPath $outputFull) {
  Assert-Directory $outputFull | Out-Null
  Remove-ExactPath $outputFull
}
New-Item -ItemType Directory -Path $outputFull | Out-Null

$outputBase = "CodexBridge-Windows-$Architecture-$($buildInfo.appVersion)-Setup"
$definitionArguments = @(
  "--no-signing",
  "--no-ide-signtools",
  "--define=PayloadDir=$payloadFull",
  "--define=OutputDir=$outputFull",
  "--define=Architecture=$Architecture",
  "--define=AppVersion=$($buildInfo.appVersion)",
  "--define=OutputBaseFilename=$outputBase"
)
$installerScript = Join-Path $repoRoot "Windows\Installer\CodexBridge.iss"
& $isccFull @definitionArguments $installerScript
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

$installerPath = Join-Path $outputFull "$outputBase.exe"
Assert-RegularFile $installerPath | Out-Null
$expectedSetupMachine = if ($Architecture -eq "x64") { [UInt16]0x8664 } else { [UInt16]0x014C }
if ((Get-PEMachine $installerPath) -ne $expectedSetupMachine) {
  throw "The setup bootstrap has the wrong architecture."
}
$installerHash = Get-Sha256 $installerPath
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
  "$installerPath.sha256",
  "$installerHash  $([IO.Path]::GetFileName($installerPath))$([Environment]::NewLine)",
  $utf8NoBom)
$installerInfo = [ordered]@{
  schema = "codex-bridge-windows-installer/v1"
  architecture = $Architecture
  appVersion = $buildInfo.appVersion
  payloadGitCommit = $buildInfo.gitCommit
  innoSetupVersion = "7.1.0"
  sha256 = $installerHash
}
[IO.File]::WriteAllText(
  (Join-Path $outputFull "INSTALLER-BUILD-INFO.json"),
  (($installerInfo | ConvertTo-Json -Depth 3) + [Environment]::NewLine),
  $utf8NoBom)

Write-Host "Installer: $installerPath"
Write-Host "SHA-256: $installerHash"
