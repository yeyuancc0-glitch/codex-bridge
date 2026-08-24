param(
  [Parameter(Mandatory = $true)]
  [string]$BundlePath
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $BundlePath)) { throw "MSIX bundle not found: $BundlePath" }

$signTool = Get-Command signtool.exe -ErrorAction SilentlyContinue
if (-not $signTool) {
  $signTool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '[\\/]x64[\\/]signtool\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
}
if (-not $signTool) { throw 'signtool.exe was not found.' }
$signToolPath = if ($signTool.Source) { $signTool.Source } else { $signTool.FullName }

Write-Host 'Creating CI package certificate.'
$certificate = New-SelfSignedCertificate `
  -Type Custom `
  -Subject 'CN=CodexBridge' `
  -FriendlyName 'Codex Bridge CI package test' `
  -KeyUsage DigitalSignature `
  -CertStoreLocation 'Cert:\CurrentUser\My' `
  -TextExtension @('2.5.29.19={text}', '2.5.29.37={text}1.3.6.1.5.5.7.3.3')
$certificatePath = Join-Path $env:RUNNER_TEMP 'CodexBridge-CI.cer'
Export-Certificate -Cert $certificate -FilePath $certificatePath | Out-Null
$trustedPeople = Import-Certificate -FilePath $certificatePath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
$package = $null
$serviceLauncher = $null
$serviceStdout = Join-Path $env:RUNNER_TEMP 'CodexBridge-Package-Service.stdout.log'
$serviceStderr = Join-Path $env:RUNNER_TEMP 'CodexBridge-Package-Service.stderr.log'
try {
  Write-Host 'Signing CI MSIX bundle.'
  & $signToolPath sign /fd SHA256 /s My /sha1 $certificate.Thumbprint $BundlePath
  if ($LASTEXITCODE -ne 0) { throw "Test signing failed with exit code $LASTEXITCODE" }

  Write-Host 'Registering CI MSIX bundle.'
  Add-AppxPackage -Path $BundlePath -ForceApplicationShutdown
  $package = Get-AppxPackage -Name 'org.codexbridge.windows' | Select-Object -First 1
  if (-not $package) { throw 'Codex Bridge was not registered after Add-AppxPackage.' }
  Write-Host "Registered $($package.PackageFullName)."
  foreach ($relative in @(
    'codex-bridge-service.exe',
    'CodexBridge.App.exe',
    'TunnelClient\tunnel-client.exe',
    'TunnelClient\cloudflared.exe',
    'FixedRuntime\151.0.4129.101\msedgewebview2.exe'
  )) {
    $installed = Join-Path $package.InstallLocation $relative
    if (-not (Test-Path -LiteralPath $installed)) {
      throw "Installed package is missing $relative"
    }
  }

  Write-Host 'Starting Service inside the registered package context.'
  if ($package.PackageFamilyName -cnotmatch '\A[A-Za-z0-9._-]+\z') {
    throw 'Installed package family name is invalid.'
  }
  $launchCommand = "Invoke-CommandInDesktopPackage -PackageFamilyName '$($package.PackageFamilyName)' -AppId 'App' -Command 'codex-bridge-service.exe' -Args '--foreground' -PreventBreakaway"
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launchCommand))
  $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $serviceLauncher = Start-Process `
    -FilePath $windowsPowerShell `
    -ArgumentList '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand `
    -RedirectStandardOutput $serviceStdout `
    -RedirectStandardError $serviceStderr `
    -PassThru
  Start-Sleep -Seconds 2
  if ($serviceLauncher.HasExited -and $serviceLauncher.ExitCode -ne 0) {
    if (Test-Path $serviceStdout) { Get-Content $serviceStdout }
    if (Test-Path $serviceStderr) { Get-Content $serviceStderr }
    throw "Installed Service package-context launch failed with exit code $($serviceLauncher.ExitCode)."
  }
  Write-Host 'Probing the installed Service over the production Named Pipe.'
  dotnet run `
    --project Windows/BridgeIPC.ServiceProbe/BridgeIPC.ServiceProbe.csproj `
    --configuration Release
  if ($LASTEXITCODE -ne 0) { throw "Installed Service probe failed with exit code $LASTEXITCODE" }
} finally {
  foreach ($name in @('CodexBridge.App', 'codex-bridge-service')) {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
      Stop-Process -Force -ErrorAction SilentlyContinue
  }
  if ($serviceLauncher -and -not $serviceLauncher.HasExited) {
    Stop-Process -Id $serviceLauncher.Id -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $serviceStdout) { Get-Content $serviceStdout }
  if (Test-Path $serviceStderr) { Get-Content $serviceStderr }
  if (-not $package) {
    $package = Get-AppxPackage -Name 'org.codexbridge.windows' | Select-Object -First 1
  }
  if ($package) {
    Write-Host "Removing $($package.PackageFullName)."
    Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Continue
    if (Get-AppxPackage -Name 'org.codexbridge.windows') {
      throw 'Codex Bridge remained registered after Remove-AppxPackage.'
    }
  }
  Remove-Item "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -ErrorAction SilentlyContinue
  foreach ($item in $trustedPeople) {
    Remove-Item "Cert:\LocalMachine\TrustedPeople\$($item.Thumbprint)" -ErrorAction SilentlyContinue
  }
}
