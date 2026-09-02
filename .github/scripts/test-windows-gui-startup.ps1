[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$PortableDir,
  [switch]$RequireWebView2
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
  private delegate bool EnumChildProc(IntPtr window, IntPtr parameter);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern IntPtr FindWindowEx(
    IntPtr parent, IntPtr after, string className, string windowName);
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll")]
  private static extern bool EnumChildWindows(
    IntPtr parent, EnumChildProc callback, IntPtr parameter);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int count);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int count);
  [DllImport("user32.dll", EntryPoint = "SendMessageW")]
  private static extern IntPtr SendMessage(
    IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)]
  private static extern IntPtr SendMessageText(
    IntPtr window, uint message, IntPtr wParam, System.Text.StringBuilder text);

  private const uint LB_GETCOUNT = 0x018B;
  private const uint LB_GETTEXT = 0x0189;
  private const uint LB_GETCURSEL = 0x0188;

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

  public static bool HasMacNavigation(IntPtr parent) {
    string[] expected = { "概览", "工作台", "项目", "日志", "连接", "设置" };
    bool found = false;
    EnumChildWindows(parent, delegate(IntPtr child, IntPtr parameter) {
      var className = new System.Text.StringBuilder(64);
      GetClassName(child, className, className.Capacity);
      if (!className.ToString().Equals("ListBox", StringComparison.OrdinalIgnoreCase)) {
        return true;
      }
      int count = SendMessage(child, LB_GETCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
      if (count != expected.Length) return true;
      if (SendMessage(child, LB_GETCURSEL, IntPtr.Zero, IntPtr.Zero).ToInt32() != 0) {
        return true;
      }
      for (int index = 0; index < expected.Length; index++) {
        var text = new System.Text.StringBuilder(256);
        SendMessageText(child, LB_GETTEXT, new IntPtr(index), text);
        if (!text.ToString().StartsWith(expected[index], StringComparison.Ordinal)) {
          return true;
        }
      }
      found = true;
      return false;
    }, IntPtr.Zero);
    return found;
  }

  public static bool HasControlText(IntPtr parent, string expected) {
    bool found = false;
    EnumChildWindows(parent, delegate(IntPtr child, IntPtr parameter) {
      var text = new System.Text.StringBuilder(256);
      GetWindowText(child, text, text.Capacity);
      if (text.ToString().Equals(expected, StringComparison.Ordinal)) {
        found = true;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return found;
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
    if ($window -ne [IntPtr]::Zero) { return $window }
    Start-Sleep -Milliseconds 200
  }
  throw "Timed out waiting for the Codex Bridge main window."
}

function Wait-MacInterface([IntPtr]$Window, [int]$Seconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ([CodexBridgeGuiSmoke]::HasMacNavigation($Window) -and
        [CodexBridgeGuiSmoke]::HasControlText($Window, "概览") -and
        [CodexBridgeGuiSmoke]::HasControlText($Window, "关键指标")) {
      return
    }
    Start-Sleep -Milliseconds 200
  }
  throw "Windows application did not finish presenting the macOS-aligned Overview."
}

function Wait-WebView2Module([System.Diagnostics.Process]$Process, [int]$Seconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $Process.Refresh()
    if ($Process.HasExited) {
      throw "Windows application exited before loading WebView2: $($Process.ExitCode)."
    }
    try {
      if (@($Process.Modules | Where-Object {
            $_.ModuleName -eq "WebView2Loader.dll"
          }).Count -eq 1) {
        return
      }
    } catch {
      # Module enumeration can briefly race process startup.
    }
    Start-Sleep -Milliseconds 200
  }
  throw "Timed out waiting for WebView2Loader.dll to load."
}

function Wait-ServiceConnection(
  [IntPtr]$Window,
  [System.Diagnostics.Process]$Process,
  [int]$Seconds
) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $Process.Refresh()
    if ($Process.HasExited) {
      throw "Windows service exited before completing a status round trip: $($Process.ExitCode)."
    }
    if ([CodexBridgeGuiSmoke]::HasControlText($Window, "● 已连接")) { return }
    Start-Sleep -Milliseconds 200
  }
  $state = if ([CodexBridgeGuiSmoke]::HasControlText($Window, "● 正在连接")) {
    "connecting"
  } elseif ([CodexBridgeGuiSmoke]::HasControlText($Window, "● 未连接")) {
    "idle"
  } elseif ([CodexBridgeGuiSmoke]::HasControlText($Window, "● 不可用")) {
    "unavailable"
  } else {
    "unknown"
  }
  throw "Windows application did not complete a service status round trip; observed: $state."
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
  $mainWindow = Wait-MainWindow $app 30
  Wait-MacInterface $mainWindow 30
  if ($RequireWebView2) {
    Wait-WebView2Module $app 30
  }
  $service = Wait-ExactProcess "codex-bridge-service" $servicePath 30
  Wait-ServiceConnection $mainWindow $service 30

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
  Write-Host "Windows navigation, Overview, service launch, and graceful shutdown passed."
} finally {
  Stop-ExactProcesses "codex-bridge-windows-app" $appPath
  Stop-ExactProcesses "codex-bridge-service" $servicePath
}
