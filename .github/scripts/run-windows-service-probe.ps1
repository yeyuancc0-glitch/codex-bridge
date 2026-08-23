$ErrorActionPreference = 'Stop'

$bin = swift build --show-bin-path --package-path Packages/BridgeCore
if ($LASTEXITCODE -ne 0) {
  throw "Unable to locate the Swift build products."
}

$service = Join-Path $bin 'codex-bridge-service.exe'
if (-not (Test-Path $service)) {
  throw "Windows Service Host was not built at $service"
}

$dataRoot = Join-Path $env:RUNNER_TEMP "CodexBridge-ServiceProbe-$PID"
$stdout = Join-Path $env:RUNNER_TEMP "codex-bridge-service-$PID.stdout.log"
$stderr = Join-Path $env:RUNNER_TEMP "codex-bridge-service-$PID.stderr.log"
$process = Start-Process `
  -FilePath $service `
  -ArgumentList '--foreground', '--data-root', $dataRoot `
  -RedirectStandardOutput $stdout `
  -RedirectStandardError $stderr `
  -PassThru

try {
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($process.HasExited) {
      throw "Windows Service Host exited before becoming ready."
    }
    if ((Test-Path $stdout) -and (Select-String -Path $stdout -Quiet -SimpleMatch 'service ready')) {
      break
    }
    Start-Sleep -Milliseconds 100
  }

  if (-not ((Test-Path $stdout) -and (Select-String -Path $stdout -Quiet -SimpleMatch 'service ready'))) {
    throw "Windows Service Host did not become ready within 30 seconds."
  }

  dotnet run `
    --project Windows/BridgeIPC.ServiceProbe/BridgeIPC.ServiceProbe.csproj `
    --configuration Release
  if ($LASTEXITCODE -ne 0) {
    throw "C# Service IPC probe failed with exit code $LASTEXITCODE"
  }
} finally {
  if (-not $process.HasExited) {
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()
  }
  if (Test-Path $stdout) { Get-Content $stdout }
  if (Test-Path $stderr) { Get-Content $stderr }
}
