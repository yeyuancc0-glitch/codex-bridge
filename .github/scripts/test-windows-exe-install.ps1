param(
  [Parameter(Mandatory = $true)]
  [string]$InstallerPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InstallerPath)) {
  throw "Installer not found: $InstallerPath"
}
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\CodexBridge'
if (Test-Path -LiteralPath $installRoot) {
  throw "Install root must not exist before smoke test: $installRoot"
}
$installLog = Join-Path $env:RUNNER_TEMP 'CodexBridge-EXE-install.log'
$upgradeLog = Join-Path $env:RUNNER_TEMP 'CodexBridge-EXE-upgrade.log'
$uninstallLog = Join-Path $env:RUNNER_TEMP 'CodexBridge-EXE-uninstall.log'
$appStdout = Join-Path $env:RUNNER_TEMP 'CodexBridge-EXE-app.stdout.log'
$appStderr = Join-Path $env:RUNNER_TEMP 'CodexBridge-EXE-app.stderr.log'
$service = $null
$app = $null

function Test-InteractiveDesktop {
  if (-not [Environment]::UserInteractive) { return $false }
  $sessionId = (Get-Process -Id $PID).SessionId
  return $null -ne (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
    Where-Object { $_.SessionId -eq $sessionId } |
    Select-Object -First 1)
}

try {
  $install = Start-Process `
    -FilePath $InstallerPath `
    -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/LOG=$installLog" `
    -Wait `
    -PassThru
  if ($install.ExitCode -ne 0) { throw "Installer failed with exit code $($install.ExitCode)" }

  foreach ($relative in @(
    'CodexBridge.App.exe',
    'CodexBridge.App.dll',
    'codex-bridge-service.exe',
    'sqlite3.dll',
    'Microsoft.WindowsAppRuntime.dll',
    'Microsoft.UI.pri',
    'Microsoft.UI.Xaml.Controls.pri',
    'payload-manifest.json',
    'TunnelClient\tunnel-client.exe',
    'TunnelClient\cloudflared.exe',
    'FixedRuntime\151.0.4129.101\msedgewebview2.exe',
    'unins000.exe'
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot $relative))) {
      throw "Installed payload is missing $relative"
    }
  }
  $shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Codex Bridge\Codex Bridge.lnk'
  if (-not (Test-Path -LiteralPath $shortcut)) { throw 'Start Menu shortcut was not installed.' }
  & "$PSScriptRoot/test-windows-payload-manifest.ps1" -Root $installRoot

  dotnet build Windows/BridgeIPC.ServiceProbe/BridgeIPC.ServiceProbe.csproj --configuration Release
  if ($LASTEXITCODE -ne 0) { throw "Service probe build failed with exit code $LASTEXITCODE" }

  $hasInteractiveDesktop = Test-InteractiveDesktop
  if ($hasInteractiveDesktop) {
    $app = Start-Process `
      -FilePath (Join-Path $installRoot 'CodexBridge.App.exe') `
      -WorkingDirectory $installRoot `
      -RedirectStandardOutput $appStdout `
      -RedirectStandardError $appStderr `
      -PassThru
  } else {
    Write-Host 'No interactive Windows shell is available; probing the installed Service directly.'
    $service = Start-Process `
      -FilePath (Join-Path $installRoot 'codex-bridge-service.exe') `
      -WorkingDirectory $installRoot `
      -PassThru
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  do {
    Start-Sleep -Milliseconds 100
    if ($app -and $app.HasExited) { throw "Installed App exited with code $($app.ExitCode)" }
    if (-not $service) {
      $service = Get-Process -Name 'codex-bridge-service' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    }
  } while (-not $service -and [DateTime]::UtcNow -lt $deadline)
  if (-not $service) {
    $source = if ($hasInteractiveDesktop) { 'App' } else { 'Service executable' }
    throw "Installed $source did not start the background Service."
  }
  dotnet run `
    --project Windows/BridgeIPC.ServiceProbe/BridgeIPC.ServiceProbe.csproj `
    --configuration Release `
    --no-build
  $probeExit = $LASTEXITCODE
  if ($probeExit -ne 0) { throw "Installed Service probe failed with exit code $probeExit" }

  $dataRoot = Join-Path $env:LOCALAPPDATA 'CodexBridge\Service'
  if (-not (Test-Path -LiteralPath $dataRoot)) { throw 'Service data root was not created.' }
  $sentinel = Join-Path $dataRoot 'installer-preservation.sentinel'
  [IO.File]::WriteAllText($sentinel, 'preserve', [Text.UTF8Encoding]::new($false))

  Stop-Process -Id $service.Id -Force
  $service.WaitForExit()
  $service = $null
  if ($app) {
    Stop-Process -Id $app.Id -Force
    $app.WaitForExit()
    $app = $null
  }

  $upgrade = Start-Process `
    -FilePath $InstallerPath `
    -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/LOG=$upgradeLog" `
    -Wait `
    -PassThru
  if ($upgrade.ExitCode -ne 0) { throw "Installer upgrade failed with exit code $($upgrade.ExitCode)" }
  & "$PSScriptRoot/test-windows-payload-manifest.ps1" -Root $installRoot
  if (-not (Test-Path -LiteralPath $sentinel)) {
    throw 'Installer upgrade removed the Service data root.'
  }

  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  New-Item -Path $runKey -Force | Out-Null
  Set-ItemProperty `
    -Path $runKey `
    -Name 'CodexBridgeService' `
    -Value ('"' + (Join-Path $installRoot 'codex-bridge-service.exe') + '"')

  $uninstaller = Join-Path $installRoot 'unins000.exe'
  $uninstall = Start-Process `
    -FilePath $uninstaller `
    -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$uninstallLog" `
    -Wait `
    -PassThru
  if ($uninstall.ExitCode -ne 0) { throw "Uninstaller failed with exit code $($uninstall.ExitCode)" }
  if (Test-Path -LiteralPath $installRoot) { throw 'Install root remained after uninstall.' }
  if (Get-ItemProperty -Path $runKey -Name 'CodexBridgeService' -ErrorAction SilentlyContinue) {
    throw 'Codex Bridge startup registration remained after uninstall.'
  }
  if (-not (Test-Path -LiteralPath $sentinel)) {
    throw 'Uninstall removed the Service data root.'
  }
  $launchMode = if ($hasInteractiveDesktop) { 'App-to-Service' } else { 'headless Service' }
  Write-Host "Codex Bridge EXE install, $launchMode probe, upgrade, and uninstall passed."
} finally {
  if ($service -and -not $service.HasExited) {
    Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue
  }
  if ($app -and -not $app.HasExited) {
    Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
  }
  $cleanupUninstaller = Join-Path $installRoot 'unins000.exe'
  if (Test-Path -LiteralPath $cleanupUninstaller) {
    Start-Process `
      -FilePath $cleanupUninstaller `
      -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' `
      -Wait `
      -ErrorAction SilentlyContinue | Out-Null
  }
  foreach ($log in @($installLog, $upgradeLog, $uninstallLog, $appStdout, $appStderr)) {
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
  }
  Get-WinEvent -FilterHashtable @{
    LogName = 'Application'
    StartTime = [DateTime]::Now.AddMinutes(-10)
  } -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProviderName -in @('Application Error', '.NET Runtime', 'Windows Error Reporting') -and
      $_.Message -like '*CodexBridge.App*'
    } |
    Select-Object -First 10 |
    Format-List TimeCreated, ProviderName, Id, LevelDisplayName, Message
}
