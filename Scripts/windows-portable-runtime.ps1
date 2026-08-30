function Resolve-VCRedistRoot([string]$ConfiguredRoot) {
  if ([string]::IsNullOrWhiteSpace($ConfiguredRoot) -and
      (Test-Path Env:CODEX_BRIDGE_VC_REDIST_ROOT)) {
    $ConfiguredRoot = $env:CODEX_BRIDGE_VC_REDIST_ROOT
  }
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredRoot)) {
    return Get-FullPath $ConfiguredRoot
  }

  $programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
  $vswherePath = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
  Assert-RegularFile $vswherePath | Out-Null
  $installationOutput = @(& $vswherePath -latest -property installationPath)
  if ($LASTEXITCODE -ne 0 -or $installationOutput.Count -eq 0) {
    throw "Visual Studio installation path was not found."
  }
  $installationPath = ($installationOutput | Select-Object -First 1).ToString().Trim()
  $versionsRoot = Join-Path $installationPath "VC\Redist\MSVC"
  Assert-Directory $versionsRoot | Out-Null
  $versionDirectories = @(Get-ChildItem -LiteralPath $versionsRoot -Directory |
      Where-Object { $_.Name -match "^[0-9]+(?:\.[0-9]+)+$" } |
      Sort-Object { [version]$_.Name } -Descending)
  if ($versionDirectories.Count -eq 0) {
    throw "Visual C++ Redistributable files were not found."
  }
  return $versionDirectories[0].FullName
}

function Resolve-SwiftRuntimeMergeModule(
  [ValidateSet("x64", "arm64")]
  [string]$Architecture
) {
  if (-not (Test-Path Env:SDKROOT) -or [string]::IsNullOrWhiteSpace($env:SDKROOT)) {
    throw "SDKROOT is required to locate Swift redistributables."
  }
  $cursor = Get-Item -LiteralPath (Get-FullPath $env:SDKROOT) -Force -ErrorAction Stop
  $versionDirectory = $null
  for ($depth = 0; $depth -lt 10 -and $cursor.Parent; $depth += 1) {
    if ($cursor.Parent.Name.Equals("Platforms", [StringComparison]::OrdinalIgnoreCase)) {
      $versionDirectory = $cursor
      break
    }
    $cursor = $cursor.Parent
  }
  if (-not $versionDirectory -or -not $versionDirectory.Parent.Parent) {
    throw "Swift platform version was not found above SDKROOT."
  }
  $swiftRoot = $versionDirectory.Parent.Parent
  Assert-Directory $swiftRoot.FullName | Out-Null
  $redistributablesRoot = Join-Path $swiftRoot.FullName "Redistributables\$($versionDirectory.Name)"
  Assert-Directory $redistributablesRoot | Out-Null
  $moduleArchitecture = if ($Architecture -eq "x64") { "amd64" } else { "arm64" }
  $moduleName = "rtl.shared.$moduleArchitecture.msm"
  $modules = @(Get-ChildItem -LiteralPath $redistributablesRoot -File -Recurse -Filter $moduleName)
  if ($modules.Count -ne 1) {
    throw "Expected exactly one Swift runtime merge module: $moduleName"
  }
  Assert-RegularFile $modules[0].FullName | Out-Null
  return $modules[0].FullName
}

function Expand-SwiftRuntimeMergeModule([string]$ModulePath, [string]$Destination) {
  Assert-RegularFile $ModulePath | Out-Null
  if (Test-Path -LiteralPath $Destination) {
    throw "Swift runtime extraction destination already exists."
  }
  $merge = New-Object -ComObject "Msm.Merge2"
  $opened = $false
  try {
    $merge.OpenModule($ModulePath, 0)
    $opened = $true
    $extractedPaths = $null
    $merge.ExtractFilesEx($Destination, $true, [ref]$extractedPaths)
  } finally {
    if ($opened) {
      $merge.CloseModule()
    }
    if ($merge) {
      [Runtime.InteropServices.Marshal]::FinalReleaseComObject($merge) | Out-Null
    }
  }
}
