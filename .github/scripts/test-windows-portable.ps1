param(
  [Parameter(Mandatory = $true)]
  [string]$ArchivePath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ArchivePath)) {
  throw "Portable archive not found: $ArchivePath"
}
$extractRoot = Join-Path $env:RUNNER_TEMP "CodexBridge-Portable-$([guid]::NewGuid())"
$serviceStdout = Join-Path $env:RUNNER_TEMP 'CodexBridge-Portable-service.stdout.log'
$serviceStderr = Join-Path $env:RUNNER_TEMP 'CodexBridge-Portable-service.stderr.log'
$service = $null

try {
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractRoot
  $servicePath = Join-Path $extractRoot 'codex-bridge-service.exe'
  if (-not (Test-Path -LiteralPath (Join-Path $extractRoot 'CodexBridge.App.exe')) -or
      -not (Test-Path -LiteralPath $servicePath)) {
    throw 'Portable archive is missing the app or Service executable.'
  }
  & "$PSScriptRoot/test-windows-payload-manifest.ps1" -Root $extractRoot
  dotnet build Windows/BridgeIPC.ServiceProbe/BridgeIPC.ServiceProbe.csproj --configuration Release
  if ($LASTEXITCODE -ne 0) { throw "Service probe build failed with exit code $LASTEXITCODE" }
  $service = Start-Process `
    -FilePath $servicePath `
    -ArgumentList '--foreground' `
    -WorkingDirectory $extractRoot `
    -RedirectStandardOutput $serviceStdout `
    -RedirectStandardError $serviceStderr `
    -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  do {
    Start-Sleep -Milliseconds 100
    if ($service.HasExited) { throw "Portable Service exited with code $($service.ExitCode)" }
    dotnet run `
      --project Windows/BridgeIPC.ServiceProbe/BridgeIPC.ServiceProbe.csproj `
      --configuration Release `
      --no-build
    $probeExit = $LASTEXITCODE
  } while ($probeExit -ne 0 -and [DateTime]::UtcNow -lt $deadline)
  if ($probeExit -ne 0) { throw "Portable Service probe failed with exit code $probeExit" }
  Write-Host 'Codex Bridge portable Service probe passed.'
} finally {
  if ($service -and -not $service.HasExited) {
    Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue
    $service.WaitForExit()
  }
  if (Test-Path -LiteralPath $serviceStdout) { Get-Content -LiteralPath $serviceStdout }
  if (Test-Path -LiteralPath $serviceStderr) { Get-Content -LiteralPath $serviceStderr }
  if (Test-Path -LiteralPath $extractRoot) {
    Remove-Item -LiteralPath $extractRoot -Recurse -Force
  }
}
