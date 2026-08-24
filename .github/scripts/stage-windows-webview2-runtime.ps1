param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture,

  [Parameter(Mandatory = $true)]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'

$version = '151.0.4129.101'
$platform = if ($Architecture -eq 'ARM64') {
  @{
    Name = 'arm64'
    Machine = 0xAA64
    SHA256 = '13e05c95da64c9343338e52a2681b63e2c3c30f3f700ee14a0382073ff3b0534'
    Url = 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/785d38fd-ed75-41fe-84db-c56bb45eef00/Microsoft.WebView2.FixedVersionRuntime.151.0.4129.101.arm64.cab'
  }
} else {
  @{
    Name = 'x64'
    Machine = 0x8664
    SHA256 = 'c386640d35f7a4604d088925a9bb01938400297f6da6fe985b72614daba87cda'
    Url = 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/d480b710-fe1e-4e4d-ae99-5b62e6391fd3/Microsoft.WebView2.FixedVersionRuntime.151.0.4129.101.x64.cab'
  }
}

function Assert-PEMachine([string]$Path, [int]$Expected) {
  $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'Read')
  $reader = [System.IO.BinaryReader]::new($stream)
  try {
    if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Invalid DOS signature: $Path" }
    $stream.Position = 0x3C
    $peOffset = $reader.ReadUInt32()
    if ($peOffset -gt ($stream.Length - 6)) { throw "Invalid PE offset: $Path" }
    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
    $machine = $reader.ReadUInt16()
    if ($machine -ne $Expected) {
      throw ('PE architecture mismatch for {0}: expected 0x{1:X4}, got 0x{2:X4}' -f $Path, $Expected, $machine)
    }
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

if (Test-Path -LiteralPath $Destination) {
  throw "WebView2 destination already exists: $Destination"
}

$work = Join-Path $env:RUNNER_TEMP "CodexBridge-WebView2-$Architecture-$([Guid]::NewGuid().ToString('N'))"
$archive = Join-Path $work "Microsoft.WebView2.FixedVersionRuntime.$version.$($platform.Name).cab"
$extract = Join-Path $work 'extract'
New-Item -ItemType Directory -Path $extract -Force | Out-Null

try {
  Invoke-WebRequest -Uri $platform.Url -OutFile $archive
  $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -cne $platform.SHA256) {
    throw "WebView2 archive SHA-256 mismatch: expected $($platform.SHA256), got $actual"
  }

  & expand.exe $archive -F:* $extract | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "WebView2 archive extraction failed with exit code $LASTEXITCODE" }
  $executables = @(Get-ChildItem -Path $extract -Recurse -Filter 'msedgewebview2.exe')
  if ($executables.Count -ne 1) {
    throw "Expected one msedgewebview2.exe, found $($executables.Count)."
  }
  $runtimeRoot = $executables[0].Directory.FullName
  Assert-PEMachine $executables[0].FullName $platform.Machine
  if (-not (Test-Path (Join-Path $runtimeRoot 'msedge.dll'))) {
    throw 'The fixed WebView2 runtime payload is incomplete.'
  }

  New-Item -ItemType Directory -Path $Destination | Out-Null
  Copy-Item -Path (Join-Path $runtimeRoot '*') -Destination $Destination -Recurse
  [System.IO.File]::WriteAllText(
    (Join-Path $Destination 'runtime.cab.sha256'),
    $platform.SHA256 + "`n",
    [System.Text.UTF8Encoding]::new($false)
  )
  Write-Host "Staged WebView2 Fixed Version Runtime $version for $Architecture at $Destination"
} finally {
  if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
  }
}
