param(
  [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

$targets = @(
  'BridgePlatformTests',
  'BridgeProcessRuntimeTests',
  'BridgeIPCContractTests',
  'BridgeCodexRPCWindowsTests',
  'BridgeDirectCommandWindowsTests',
  'BridgeSecurityWindowsTests',
  'BridgeIPCWindowsTests',
  'BridgePlatformWindowsTests',
  'BridgeFilesWindowsTests',
  'BridgeMCPWindowsTests',
  'BridgeTunnelWindowsTests',
  'BridgeTunnelContractWindowsTests'
)

$swift = (Get-Command swift.exe -ErrorAction Stop).Source
$packagePath = 'Packages/BridgeCore'
$listedTests = & $swift test list --skip-build --package-path $packagePath
if ($LASTEXITCODE -ne 0) {
  throw "Unable to list Windows tests (exit $LASTEXITCODE)"
}

foreach ($target in $targets) {
  $filter = "^$([regex]::Escape($target))\."
  if (-not ($listedTests -match $filter)) {
    throw "No discovered tests matched $target"
  }

  Write-Host "::group::Test $target"
  $arguments = @(
    'test',
    '--skip-build',
    '--package-path',
    $packagePath,
    '--filter',
    $filter
  )
  $process = Start-Process `
    -FilePath $swift `
    -ArgumentList $arguments `
    -NoNewWindow `
    -PassThru

  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    & taskkill.exe /PID $process.Id /T /F | Out-Host
    Write-Host '::endgroup::'
    throw "$target exceeded the ${TimeoutSeconds}s native test deadline"
  }
  if ($process.ExitCode -ne 0) {
    Write-Host '::endgroup::'
    throw "$target failed with exit code $($process.ExitCode)"
  }
  Write-Host '::endgroup::'
}
