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
  'BridgeServiceApplicationWindowsTests',
  'BridgeSecurityWindowsTests',
  'BridgeIPCWindowsTests',
  'BridgePlatformWindowsTests',
  'BridgeFilesWindowsTests',
  'BridgeMCPWindowsTests',
  'BridgeTunnelWindowsTests',
  'BridgeTunnelContractWindowsTests',
  'BridgeServiceHostWindowsTests'
)

$swift = (Get-Command swift.exe -ErrorAction Stop).Source
$packagePath = 'Packages/BridgeCore'
$listedTests = & $swift test list --skip-build --package-path $packagePath
if ($LASTEXITCODE -ne 0) {
  throw "Unable to list Windows tests (exit $LASTEXITCODE)"
}

foreach ($target in $targets) {
  $filter = "^$([regex]::Escape($target))\."
  $matchingTests = @($listedTests -match $filter)
  if ($matchingTests.Count -eq 0) {
    throw "No discovered tests matched $target"
  }

  $filters = if ($target -eq 'BridgeIPCWindowsTests') {
    @($matchingTests | Sort-Object {
      if ($_ -match '/testEcho') { return 0 }
      if ($_ -match '/testConcurrent') { return 1 }
      return 2
    })
  } else {
    @($filter)
  }
  foreach ($testFilter in $filters) {
    Write-Host "::group::Test $testFilter"
    $arguments = @(
      'test',
      '--skip-build',
      '--package-path',
      $packagePath,
      '--filter',
      $testFilter
    )
    $process = Start-Process `
      -FilePath $swift `
      -ArgumentList $arguments `
      -NoNewWindow `
      -PassThru

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      & taskkill.exe /PID $process.Id /T /F | Out-Host
      Write-Host '::endgroup::'
      throw "$testFilter exceeded the ${TimeoutSeconds}s native test deadline"
    }
    if ($process.ExitCode -ne 0) {
      Write-Host '::endgroup::'
      throw "$testFilter failed with exit code $($process.ExitCode)"
    }
    Write-Host '::endgroup::'
  }
}
