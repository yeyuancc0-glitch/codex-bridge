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
if (@(Get-Process -Name "codex-bridge-service" -ErrorAction SilentlyContinue).Count -ne 0) {
  throw "A Codex Bridge service is already running."
}

$testRoot = Join-Path $env:RUNNER_TEMP ("Codex Bridge spaced path " + [Guid]::NewGuid().ToString("N"))
$service = $null
try {
  Copy-Item -LiteralPath $portableFull -Destination $testRoot -Recurse
  $appPath = Join-Path $testRoot "codex-bridge-windows-app.exe"
  $servicePath = Join-Path $testRoot "codex-bridge-service.exe"
  $launch = Start-Process -FilePath $appPath -WorkingDirectory $testRoot `
    -ArgumentList "--ensure-service" -PassThru
  $launchExitCode = Wait-DirectProcessExit $launch 30 "Application service control"
  if ($launchExitCode -ne 0) {
    throw "The application service control returned $launchExitCode."
  }

  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ([DateTime]::UtcNow -lt $deadline -and $null -eq $service) {
    $matches = @(Get-Process -Name "codex-bridge-service" -ErrorAction SilentlyContinue |
        Where-Object {
          try {
            (Get-ComparablePath $_.Path).Equals(
              (Get-ComparablePath $servicePath),
              [StringComparison]::OrdinalIgnoreCase)
          } catch {
            $false
          }
        })
    if ($matches.Count -gt 1) { throw "Multiple services started from the test payload." }
    if ($matches.Count -eq 1) { $service = $matches[0] }
    if ($null -eq $service) { Start-Sleep -Milliseconds 200 }
  }
  if ($null -eq $service) {
    throw "The app did not launch the service from its path containing spaces."
  }

  $control = Start-Process -FilePath $servicePath -ArgumentList "--shutdown" -PassThru
  $controlExitCode = Wait-DirectProcessExit $control 45 "Service shutdown control"
  if ($controlExitCode -ne 0) {
    throw "The service shutdown control returned $controlExitCode."
  }
  $service.Refresh()
  if (-not $service.HasExited) {
    throw "The service shutdown control returned before the service exited."
  }
  Write-Host "App-to-service launch from a path containing spaces passed."
} finally {
  foreach ($process in @($service)) {
    if ($null -eq $process) { continue }
    try {
      $process.Refresh()
      if (-not $process.HasExited -and
          (Test-SameOrChildPath $testRoot $process.Path)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
      }
    } catch {}
  }
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}
