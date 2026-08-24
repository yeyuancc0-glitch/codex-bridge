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

$certificate = New-SelfSignedCertificate `
  -Type Custom `
  -Subject 'CN=CodexBridge' `
  -FriendlyName 'Codex Bridge CI package test' `
  -KeyUsage DigitalSignature `
  -CertStoreLocation 'Cert:\CurrentUser\My' `
  -TextExtension @('2.5.29.19={text}', '2.5.29.37={text}1.3.6.1.5.5.7.3.3')
$certificatePath = Join-Path $env:RUNNER_TEMP 'CodexBridge-CI.cer'
Export-Certificate -Cert $certificate -FilePath $certificatePath | Out-Null
$trusted = Import-Certificate -FilePath $certificatePath -CertStoreLocation 'Cert:\CurrentUser\TrustedPeople'
$package = $null
$serviceProcess = $null
$stdout = Join-Path $env:RUNNER_TEMP 'CodexBridge-Installed-Service.stdout.log'
$stderr = Join-Path $env:RUNNER_TEMP 'CodexBridge-Installed-Service.stderr.log'
try {
  & $signToolPath sign /fd SHA256 /s My /sha1 $certificate.Thumbprint $BundlePath
  if ($LASTEXITCODE -ne 0) { throw "Test signing failed with exit code $LASTEXITCODE" }
  & $signToolPath verify /pa /v $BundlePath
  if ($LASTEXITCODE -ne 0) { throw "Test signature verification failed with exit code $LASTEXITCODE" }

  Add-AppxPackage -Path $BundlePath -ForceApplicationShutdown
  $package = Get-AppxPackage -Name 'org.codexbridge.windows' | Select-Object -First 1
  if (-not $package) { throw 'Codex Bridge was not registered after Add-AppxPackage.' }
  $service = Join-Path $package.InstallLocation 'codex-bridge-service.exe'
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

  $dataRoot = Join-Path $env:RUNNER_TEMP 'CodexBridge-Installed-ServiceData'
  $serviceProcess = Start-Process `
    -FilePath $service `
    -ArgumentList '--foreground', '--data-root', $dataRoot `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($serviceProcess.HasExited) { throw 'Installed Service exited before becoming ready.' }
    if ((Test-Path $stdout) -and (Select-String -Path $stdout -Quiet -SimpleMatch 'service ready')) {
      break
    }
    Start-Sleep -Milliseconds 100
  }
  if (-not ((Test-Path $stdout) -and (Select-String -Path $stdout -Quiet -SimpleMatch 'service ready'))) {
    throw 'Installed Service did not become ready within 30 seconds.'
  }
  dotnet run `
    --project Windows/BridgeIPC.ServiceProbe/BridgeIPC.ServiceProbe.csproj `
    --configuration Release
  if ($LASTEXITCODE -ne 0) { throw "Installed Service probe failed with exit code $LASTEXITCODE" }
} finally {
  if ($serviceProcess -and -not $serviceProcess.HasExited) {
    Stop-Process -Id $serviceProcess.Id -Force
    $serviceProcess.WaitForExit()
  }
  if ($stdout -and (Test-Path $stdout)) { Get-Content $stdout }
  if ($stderr -and (Test-Path $stderr)) { Get-Content $stderr }
  if (-not $package) {
    $package = Get-AppxPackage -Name 'org.codexbridge.windows' | Select-Object -First 1
  }
  if ($package) {
    Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Continue
    if (Get-AppxPackage -Name 'org.codexbridge.windows') {
      throw 'Codex Bridge remained registered after Remove-AppxPackage.'
    }
  }
  Remove-Item "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -ErrorAction SilentlyContinue
  foreach ($item in $trusted) {
    Remove-Item "Cert:\CurrentUser\TrustedPeople\$($item.Thumbprint)" -ErrorAction SilentlyContinue
  }
}
