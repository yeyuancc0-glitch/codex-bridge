[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$PortableDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$portableFull = [IO.Path]::GetFullPath($PortableDir)
$smokeRoot = Join-Path $env:RUNNER_TEMP ("codex-bridge-portable-" + [Guid]::NewGuid().ToString("N"))
$dataRoot = Join-Path $smokeRoot "data"
$stdoutPath = Join-Path $smokeRoot "stdout.txt"
$stderrPath = Join-Path $smokeRoot "stderr.txt"
$originalPath = $env:PATH
$process = $null

New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
try {
  $env:PATH = "$portableFull;$env:SystemRoot\System32;$env:SystemRoot"
  $process = Start-Process -FilePath (Join-Path $portableFull "codex-bridge-service.exe") `
    -ArgumentList @("--foreground", "--data-root", "`"$dataRoot`"") `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
    -NoNewWindow -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  $ready = $false
  while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
    if (Test-Path -LiteralPath $stdoutPath) {
      $output = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
      if ($output -match "Codex Bridge service ready on 127\.0\.0\.1:\d+\.") {
        $ready = $true
        break
      }
    }
    Start-Sleep -Milliseconds 250
  }
  if (-not $ready) {
    $process.Refresh()
    $exitCode = if ($process.HasExited) { "0x" + $process.ExitCode.ToString("X8") } else { "running" }
    $standardOutput = if (Test-Path -LiteralPath $stdoutPath) {
      Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
    } else { "no stdout" }
    $standardError = if (Test-Path -LiteralPath $stderrPath) {
      Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
    } else { "no stderr" }
    throw "Portable service did not reach readiness ($exitCode). stdout: $standardOutput stderr: $standardError"
  }

  $portableRoot = $portableFull.TrimEnd("\") + "\"
  $runtimeNames = @(Get-ChildItem -LiteralPath $portableFull -File |
      Where-Object { $_.Name -match "^(concrt|msvcp|vccorlib|vcruntime)[^.]*\.dll$" } |
      Select-Object -ExpandProperty Name)
  $runtimeModules = @($process.Modules | Where-Object { $runtimeNames -contains $_.ModuleName })
  foreach ($module in $runtimeModules) {
    $modulePath = [IO.Path]::GetFullPath($module.FileName)
    if (-not $modulePath.StartsWith($portableRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Visual C++ runtime was loaded outside the portable directory: $modulePath"
    }
  }
  Write-Host "Portable service startup with app-local runtimes passed."
} finally {
  if ($process -and -not $process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
  }
  $env:PATH = $originalPath
  if (Test-Path -LiteralPath $smokeRoot) {
    Remove-Item -LiteralPath $smokeRoot -Recurse -Force
  }
}
