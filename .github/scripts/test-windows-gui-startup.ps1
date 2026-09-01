[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$PortableDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
. (Join-Path $repoRoot "Scripts\windows-portable-support.ps1")
$portableFull = Get-FullPath $PortableDir
Assert-Directory $portableFull | Out-Null
$appPath = Join-Path $portableFull "codex-bridge-windows-app.exe"
$servicePath = Join-Path $portableFull "codex-bridge-service.exe"
Assert-RegularFile $appPath | Out-Null
Assert-RegularFile $servicePath | Out-Null

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CodexBridgeGuiSmoke {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern IntPtr FindWindowEx(
    IntPtr parent, IntPtr after, string className, string windowName);
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

  public static IntPtr FindWindowForProcess(uint expectedProcessId) {
    IntPtr window = IntPtr.Zero;
    while ((window = FindWindowEx(
        IntPtr.Zero, window, "CodexBridgeMainWindow", null)) != IntPtr.Zero) {
      uint processId;
      GetWindowThreadProcessId(window, out processId);
      if (processId == expectedProcessId) return window;
    }
    return IntPtr.Zero;
  }
}
"@

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
    if ($matches.Count -gt 1) { throw "Multiple exact $Name processes are running." }
    Start-Sleep -Milliseconds 200
  }
  throw "Timed out waiting for $Name."
}

function Wait-MainWindow([System.Diagnostics.Process]$Process, [int]$Seconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $Process.Refresh()
    if ($Process.HasExited) {
      throw "Windows application exited before creating its main window: $($Process.ExitCode)."
    }
    $window = [CodexBridgeGuiSmoke]::FindWindowForProcess([uint32]$Process.Id)
    if ($window -ne [IntPtr]::Zero) { return }
    Start-Sleep -Milliseconds 200
  }
  throw "Timed out waiting for the Codex Bridge main window."
}

function Stop-ExactProcesses([string]$Name, [string]$ExpectedPath) {
  foreach ($process in @(Get-ExactProcess $Name $ExpectedPath)) {
    $process.Refresh()
    if ($process.HasExited) { continue }
    Stop-Process -Id $process.Id -Force -ErrorAction Stop
    if (-not $process.WaitForExit(10000)) {
      throw "Timed out cleaning up $Name."
    }
  }
}

$app = $null
$service = $null
if (@(Get-ExactProcess "codex-bridge-windows-app" $appPath).Count -ne 0 -or
    @(Get-ExactProcess "codex-bridge-service" $servicePath).Count -ne 0) {
  throw "The GUI smoke payload is already running."
}

try {
  $app = Start-Process -FilePath $appPath -WorkingDirectory $portableFull -PassThru
  Wait-MainWindow $app 30
  $service = Wait-ExactProcess "codex-bridge-service" $servicePath 30

  $appControl = Start-Process -FilePath $appPath -ArgumentList "--shutdown" -PassThru
  $appControlExit = Wait-DirectProcessExit $appControl 35 "Windows application shutdown"
  if ($appControlExit -ne 0) {
    throw "Windows application shutdown returned $appControlExit."
  }
  $app.Refresh()
  if (-not $app.HasExited) {
    throw "Windows application remained running after shutdown."
  }

  $serviceControl = Start-Process -FilePath $servicePath -ArgumentList "--shutdown" -PassThru
  $serviceControlExit = Wait-DirectProcessExit $serviceControl 45 "Windows service shutdown"
  if ($serviceControlExit -ne 0) {
    throw "Windows service shutdown returned $serviceControlExit."
  }
  $service.Refresh()
  if (-not $service.HasExited) {
    throw "Windows service remained running after shutdown."
  }
  Write-Host "Windows GUI startup, service launch, and graceful shutdown passed."
} finally {
  Stop-ExactProcesses "codex-bridge-windows-app" $appPath
  Stop-ExactProcesses "codex-bridge-service" $servicePath
}
