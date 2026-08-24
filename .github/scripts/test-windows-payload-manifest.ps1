param(
  [Parameter(Mandatory = $true)]
  [string]$Root
)

$ErrorActionPreference = 'Stop'

$rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$manifestPath = Join-Path $rootPath 'payload-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "Payload manifest is missing at $manifestPath"
}
$entries = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
if ($entries.Count -eq 0) { throw 'Payload manifest is empty.' }
$rootPrefix = $rootPath + '\'
foreach ($entry in $entries) {
  if (-not ($entry.path -is [string]) -or [IO.Path]::IsPathRooted($entry.path)) {
    throw "Payload manifest path is invalid: $($entry.path)"
  }
  $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $entry.path))
  if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Payload manifest path escapes its root: $($entry.path)"
  }
  $file = Get-Item -LiteralPath $candidate -ErrorAction Stop
  if ($file.Length -ne [long]$entry.bytes) {
    throw "Payload size mismatch: $($entry.path)"
  }
  $digest = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($digest -cne [string]$entry.sha256) {
    throw "Payload digest mismatch: $($entry.path)"
  }
}
Write-Host "Verified $($entries.Count) payload manifest entries under $rootPath."
