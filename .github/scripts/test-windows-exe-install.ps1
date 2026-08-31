[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InstallerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
. (Join-Path $repoRoot "Scripts\windows-portable-support.ps1")
$installerFull = Get-FullPath $InstallerPath
Assert-RegularFile $installerFull | Out-Null
$installRoot = Join-Path $env:LOCALAPPDATA "Programs\CodexBridge"
$appPath = Join-Path $installRoot "codex-bridge-windows-app.exe"
$servicePath = Join-Path $installRoot "codex-bridge-service.exe"
$shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Codex Bridge\Codex Bridge.lnk"
$sentinelName = "installer-preservation-$PID.sentinel"
$dataSentinel = Join-Path $env:LOCALAPPDATA "CodexBridgeService\$sentinelName"
$webViewSentinel = Join-Path $env:LOCALAPPDATA "CodexBridge\WebView2\$sentinelName"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$legacyRunCreated = $false
$logs = @()
$service = $null
$legacyObsoletePath = Join-Path $installRoot "LegacyRuntime\obsolete.dll"

function Invoke-Setup([string]$Executable, [string]$LogName, [switch]$Uninstall) {
  $logPath = Join-Path $env:RUNNER_TEMP $LogName
  $script:logs += $logPath
  $arguments = @(
    "/VERYSILENT",
    "/SUPPRESSMSGBOXES",
    "/NORESTART",
    "/LOG=`"$logPath`""
  )
  if (-not $Uninstall) { $arguments += "/SP-" }
  $process = Start-Process -FilePath $Executable -ArgumentList $arguments -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Setup failed with exit code $($process.ExitCode)."
  }
}

function Get-ExactProcess([string]$Name, [string]$ExpectedPath) {
  $expected = Get-ComparablePath $ExpectedPath
  return @(Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object {
      try {
        (Get-ComparablePath $_.Path).Equals($expected, [StringComparison]::OrdinalIgnoreCase)
      } catch {
        $false
      }
    })
}

function Wait-ExactProcess([string]$Name, [string]$ExpectedPath, [int]$Seconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $matches = @(Get-ExactProcess $Name $ExpectedPath)
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1) { throw "Multiple exact Codex Bridge processes are running." }
    Start-Sleep -Milliseconds 200
  }
  throw "Timed out waiting for $Name."
}

function Assert-Payload([string]$Root) {
  $sumPath = Join-Path $Root "SHA256SUMS.txt"
  Assert-RegularFile $sumPath | Out-Null
  foreach ($line in Get-Content -LiteralPath $sumPath) {
    if ($line -notmatch "^([0-9a-fA-F]{64})  (.+)$") {
      throw "Installed SHA256SUMS.txt is invalid."
    }
    $candidate = Get-FullPath (Join-Path $Root ($Matches[2] -replace "/", "\"))
    if (-not (Test-SameOrChildPath $Root $candidate)) {
      throw "Installed SHA256SUMS.txt contains an unsafe path."
    }
    Assert-RegularFile $candidate | Out-Null
    if ((Get-Sha256 $candidate) -ne $Matches[1].ToLowerInvariant()) {
      throw "Installed payload checksum mismatch: $($Matches[2])"
    }
  }
  foreach ($required in @(
      "codex-bridge-windows-app.exe",
      "codex-bridge-service.exe",
      "swiftCore.dll",
      "sqlite3.dll",
      "WebView2Loader.dll",
      "BUILD-INFO.json",
      "CodexBridgeControl.v1",
      "unins000.exe")) {
    Assert-RegularFile (Join-Path $Root $required) | Out-Null
  }
}

function Assert-Shortcut {
  Assert-RegularFile $shortcutPath | Out-Null
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  if (-not (Get-ComparablePath $shortcut.TargetPath).Equals(
      (Get-ComparablePath $appPath), [StringComparison]::OrdinalIgnoreCase) -or
      -not (Get-ComparablePath $shortcut.WorkingDirectory).Equals(
        (Get-ComparablePath $installRoot), [StringComparison]::OrdinalIgnoreCase)) {
    throw "The Start Menu shortcut target is invalid."
  }
}

function Start-InstalledServiceThroughApplication {
  $launch = Start-Process -FilePath $appPath -WorkingDirectory $installRoot `
    -ArgumentList "--ensure-service" -PassThru
  $launchExitCode = Wait-DirectProcessExit $launch 30 "Installed application service control"
  if ($launchExitCode -ne 0) {
    throw "The installed application service control returned $launchExitCode."
  }
  $script:service = Wait-ExactProcess "codex-bridge-service" $servicePath 30
}

function Wait-BridgeProcessesExit {
  foreach ($process in @($script:service)) {
    if ($null -eq $process) { continue }
    try {
      $process.WaitForExit(30000) | Out-Null
      $process.Refresh()
      if (-not $process.HasExited) { throw "A Codex Bridge process did not exit." }
    } catch {
      throw
    }
  }
  $script:service = $null
}

if (Test-Path -LiteralPath $installRoot) {
  throw "Install root must not exist before the lifecycle test: $installRoot"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $legacyObsoletePath) -Force | Out-Null
[IO.File]::WriteAllText($legacyObsoletePath, "legacy", [Text.UTF8Encoding]::new($false))
$legacyManifest = @([ordered]@{
    path = "LegacyRuntime/obsolete.dll"
    bytes = 6
    sha256 = (Get-Sha256 $legacyObsoletePath)
  }) | ConvertTo-Json -Depth 3
[IO.File]::WriteAllText(
  (Join-Path $installRoot "payload-manifest.json"),
  $legacyManifest,
  [Text.UTF8Encoding]::new($false))

try {
  Invoke-Setup $installerFull "CodexBridge-install.log"
  if ((Test-Path -LiteralPath $legacyObsoletePath) -or
      (Test-Path -LiteralPath (Join-Path $installRoot "payload-manifest.json"))) {
    throw "Install retained legacy manifest-owned payload files."
  }
  Assert-Payload $installRoot
  Assert-Shortcut
  Start-InstalledServiceThroughApplication

  foreach ($sentinel in @($dataSentinel, $webViewSentinel)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $sentinel) -Force | Out-Null
    [IO.File]::WriteAllText($sentinel, "preserve", [Text.UTF8Encoding]::new($false))
  }
  $obsoletePath = Join-Path $installRoot "obsolete-runtime.dll"
  [IO.File]::WriteAllText($obsoletePath, "obsolete", [Text.UTF8Encoding]::new($false))
  Add-Content -LiteralPath (Join-Path $installRoot "SHA256SUMS.txt") `
    "$(Get-Sha256 $obsoletePath)  obsolete-runtime.dll"
  New-Item -Path $runKey -Force | Out-Null
  Set-ItemProperty -Path $runKey -Name "CodexBridgeService" -Value ('"' + $servicePath + '"')
  $legacyRunCreated = $true

  Invoke-Setup $installerFull "CodexBridge-upgrade.log"
  Wait-BridgeProcessesExit
  if (Test-Path -LiteralPath $obsoletePath) {
    throw "Upgrade retained an obsolete manifest-owned file."
  }
  Assert-Payload $installRoot
  foreach ($sentinel in @($dataSentinel, $webViewSentinel)) {
    Assert-RegularFile $sentinel | Out-Null
  }
  if (Get-ItemProperty -Path $runKey -Name "CodexBridgeService" -ErrorAction SilentlyContinue) {
    throw "Legacy startup registration remained after upgrade."
  }

  Start-InstalledServiceThroughApplication
  New-Item -Path $runKey -Force | Out-Null
  Set-ItemProperty -Path $runKey -Name "CodexBridgeService" -Value ('"' + $servicePath + '"')
  $legacyRunCreated = $true
  Invoke-Setup (Join-Path $installRoot "unins000.exe") "CodexBridge-uninstall.log" -Uninstall
  Wait-BridgeProcessesExit

  if (Test-Path -LiteralPath $installRoot) { throw "Install root remained after uninstall." }
  if (Test-Path -LiteralPath $shortcutPath) { throw "Start Menu shortcut remained after uninstall." }
  if (Get-ItemProperty -Path $runKey -Name "CodexBridgeService" -ErrorAction SilentlyContinue) {
    throw "Legacy startup registration remained after uninstall."
  }
  foreach ($sentinel in @($dataSentinel, $webViewSentinel)) {
    Assert-RegularFile $sentinel | Out-Null
    Remove-Item -LiteralPath $sentinel -Force
  }
  Write-Host "EXE install, app-to-service startup, upgrade, uninstall, and data retention passed."
} finally {
  foreach ($process in @($service)) {
    if ($null -eq $process) { continue }
    try {
      $process.Refresh()
      if (-not $process.HasExited -and
          (Test-SameOrChildPath $installRoot $process.Path)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }
  $cleanupUninstaller = Join-Path $installRoot "unins000.exe"
  if (Test-Path -LiteralPath $cleanupUninstaller) {
    Start-Process -FilePath $cleanupUninstaller -ArgumentList @(
      "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"
    ) -Wait -ErrorAction SilentlyContinue | Out-Null
  }
  if ($legacyRunCreated) {
    $runValue = Get-ItemPropertyValue -Path $runKey -Name "CodexBridgeService" `
      -ErrorAction SilentlyContinue
    if ($runValue -eq ('"' + $servicePath + '"')) {
      Remove-ItemProperty -Path $runKey -Name "CodexBridgeService" -ErrorAction SilentlyContinue
    }
  }
  foreach ($sentinel in @($dataSentinel, $webViewSentinel)) {
    if (Test-Path -LiteralPath $sentinel -PathType Leaf) {
      Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
    }
  }
  if (Test-Path -LiteralPath $legacyObsoletePath -PathType Leaf) {
    Remove-Item -LiteralPath $legacyObsoletePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Split-Path -Parent $legacyObsoletePath) `
      -ErrorAction SilentlyContinue
  }
  foreach ($log in $logs) {
    if (Test-Path -LiteralPath $log) {
      Write-Host "==== $log ===="
      Get-Content -LiteralPath $log
    }
  }
}
