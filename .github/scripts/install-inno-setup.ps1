[CmdletBinding()]
param(
  [string]$InstallDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path Env:OS) -or $env:OS -ne "Windows_NT") {
  throw "Inno Setup installation must run on Windows."
}

$version = "7.1.0"
$expectedHash = "0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f"
$uri = "https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe"
$temporaryRoot = Join-Path $env:RUNNER_TEMP "codex-bridge-inno-setup"
$installerPath = Join-Path $temporaryRoot "innosetup-$version-x64.exe"
$resolvedInstallDir = if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  Join-Path $temporaryRoot "InnoSetup"
} elseif ([IO.Path]::IsPathRooted($InstallDir)) {
  [IO.Path]::GetFullPath($InstallDir)
} else {
  [IO.Path]::GetFullPath((Join-Path $env:GITHUB_WORKSPACE $InstallDir))
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $installerPath
$actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
  throw "Inno Setup installer SHA-256 did not match the pinned value."
}

$arguments = @(
  "/VERYSILENT",
  "/SUPPRESSMSGBOXES",
  "/NORESTART",
  "/SP-",
  "/DIR=`"$resolvedInstallDir`""
)
$process = Start-Process -FilePath $installerPath -ArgumentList $arguments -Wait -PassThru
if ($process.ExitCode -ne 0) {
  throw "Inno Setup installation failed with exit code $($process.ExitCode)."
}
$isccPath = Join-Path $resolvedInstallDir "ISCC.exe"
if (-not (Test-Path -LiteralPath $isccPath -PathType Leaf)) {
  throw "ISCC.exe was not installed."
}
$compilerVersion = @(& $isccPath --version 2>&1)
if ($LASTEXITCODE -ne 0 -or (($compilerVersion -join " ") -notmatch "\b7\.1\.0\b")) {
  throw "The installed Inno Setup compiler version is not 7.1.0."
}

if (Test-Path Env:GITHUB_ENV) {
  Add-Content -LiteralPath $env:GITHUB_ENV "INNO_SETUP_ISCC=$isccPath"
}
Write-Host "Pinned Inno Setup compiler: $isccPath"
