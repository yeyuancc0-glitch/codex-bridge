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
$coreHostTrace = Join-Path $env:RUNNER_TEMP 'CodexBridge-EXE-corehost.log'
$cdbLog = Join-Path $env:RUNNER_TEMP 'CodexBridge-EXE-cdb.log'
$cdbCommands = Join-Path $env:RUNNER_TEMP 'CodexBridge-EXE-cdb-commands.txt'
$appCrashDump = Join-Path $env:RUNNER_TEMP 'CodexBridge.App.dmp'
$werDumpDirectory = Join-Path $env:RUNNER_TEMP 'CodexBridge-App-WER'
$werKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\CodexBridge.App.exe'
$appStartupLog = Join-Path $env:LOCALAPPDATA 'CodexBridge\Logs\app-startup.log'
$service = $null
$app = $null
$dumpMonitor = $null
$werKeyCreated = $false

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
    'CodexBridge.App.pri',
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

  $env:COREHOST_TRACE = '1'
  $env:COREHOST_TRACEFILE = $coreHostTrace
  $env:DOTNET_DbgEnableMiniDump = '1'
  $env:DOTNET_DbgMiniDumpType = '4'
  $env:DOTNET_DbgMiniDumpName = $appCrashDump
  try {
    if (-not (Test-Path -LiteralPath $werKey)) {
      New-Item -ItemType Directory -Path $werDumpDirectory -Force | Out-Null
      New-Item -Path $werKey -Force | Out-Null
      $werKeyCreated = $true
      New-ItemProperty -Path $werKey -Name DumpFolder -PropertyType ExpandString -Value $werDumpDirectory -Force | Out-Null
      New-ItemProperty -Path $werKey -Name DumpType -PropertyType DWord -Value 1 -Force | Out-Null
      New-ItemProperty -Path $werKey -Name DumpCount -PropertyType DWord -Value 2 -Force | Out-Null
    }
  }
  catch {
    Write-Warning "Unable to enable WER LocalDumps: $($_.Exception.Message)"
  }

  $debuggerArchitecture = if ($env:RUNNER_ARCH -eq 'ARM64') { 'arm64' } else { 'x64' }
  $debugger = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\$debuggerArchitecture\cdb.exe",
    "$env:ProgramFiles\Windows Kits\10\Debuggers\$debuggerArchitecture\cdb.exe"
  ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $debugger) { throw "Windows debugger for $debuggerArchitecture was not found." }
  $appExecutable = Join-Path $installRoot 'CodexBridge.App.exe'
  [IO.File]::WriteAllLines(
    $cdbCommands,
    @('g', '!analyze -v', '.ecxr', 'kb', 'lm', 'q'),
    [Text.UTF8Encoding]::new($false))
  $debugArguments = @('-o', '-G', '-logo', $cdbLog, '-cf', $cdbCommands, $appExecutable)
  $dumpMonitor = Start-Process `
    -FilePath $debugger `
    -ArgumentList $debugArguments `
    -WorkingDirectory $installRoot `
    -PassThru
  $launchDeadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 100
    $app = Get-Process -Name 'CodexBridge.App' -ErrorAction SilentlyContinue | Select-Object -First 1
  } while (-not $app -and -not $dumpMonitor.HasExited -and [DateTime]::UtcNow -lt $launchDeadline)
  if (-not $app) {
    throw "Windows debugger did not start CodexBridge.App (exit code $($dumpMonitor.ExitCode))."
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
    throw 'Installed App did not start the background Service.'
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
  Write-Host 'Codex Bridge EXE install, App-to-Service probe, upgrade, and uninstall passed.'
} finally {
  if ($service -and -not $service.HasExited) {
    Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue
  }
  if ($app -and -not $app.HasExited) {
    Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
  }
  if ($dumpMonitor -and -not $dumpMonitor.HasExited) {
    Stop-Process -Id $dumpMonitor.Id -Force -ErrorAction SilentlyContinue
  }
  if ($werKeyCreated) {
    $dumpDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Get-ChildItem -LiteralPath $werDumpDirectory -Filter '*.dmp' -ErrorAction SilentlyContinue) -and
      [DateTime]::UtcNow -lt $dumpDeadline) {
      Start-Sleep -Milliseconds 200
    }
  }
  $cleanupUninstaller = Join-Path $installRoot 'unins000.exe'
  if (Test-Path -LiteralPath $cleanupUninstaller) {
    Start-Process `
      -FilePath $cleanupUninstaller `
      -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' `
      -Wait `
      -ErrorAction SilentlyContinue | Out-Null
  }
  foreach ($name in @(
    'COREHOST_TRACE',
    'COREHOST_TRACEFILE',
    'DOTNET_DbgEnableMiniDump',
    'DOTNET_DbgMiniDumpType',
    'DOTNET_DbgMiniDumpName'
  )) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
  }
  foreach ($log in @(
    $installLog,
    $upgradeLog,
    $uninstallLog,
    $appStdout,
    $appStderr,
    $coreHostTrace,
    $cdbLog
  )) {
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
  }
  $crashDumps = @(
    Get-Item -LiteralPath $appCrashDump -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $werDumpDirectory -Filter '*.dmp' -ErrorAction SilentlyContinue
  )
  if ($crashDumps.Count -gt 0) {
    $debuggerArchitecture = if ($env:RUNNER_ARCH -eq 'ARM64') { 'arm64' } else { 'x64' }
    $debugger = @(
      "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\$debuggerArchitecture\cdb.exe",
      "$env:ProgramFiles\Windows Kits\10\Debuggers\$debuggerArchitecture\cdb.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    foreach ($dump in $crashDumps) {
      Write-Host "Codex Bridge App crash dump: $($dump.FullName)"
      if ($debugger) {
        & $debugger -z $dump.FullName -c '.symfix; .reload; !analyze -v; .ecxr; kb; q'
      }
    }
  }
  if ($werKeyCreated) {
    Remove-Item -LiteralPath $werKey -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $appStartupLog) {
    Write-Host 'Codex Bridge App startup diagnostics:'
    Get-Content -LiteralPath $appStartupLog
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
