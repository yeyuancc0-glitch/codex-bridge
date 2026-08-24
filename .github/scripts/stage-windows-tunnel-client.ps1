param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture,

  [Parameter(Mandatory = $true)]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'

$release = 'v0.0.12'
$commonFiles = @('cloudflared-manifest.json', 'LICENSE', 'NOTICE')
$platform = if ($Architecture -eq 'ARM64') {
  @{
    Name = 'arm64'
    Machine = 0xAA64
    ArchiveSHA256 = '65ab54221554481bb1c23b6015b99abe0b7f79b08593f4fb17a9e2e25532281d'
    TunnelClientSHA256 = '480684ec1031fc2985c7e87f9d669e7dfda4012a8ecdab21eabe1b5deafdd656'
    CloudflaredSHA256 = '31f83304590ba0d4c2e015a8a499c31a45ab4c073e6351705c89e9e01878c536'
  }
} else {
  @{
    Name = 'amd64'
    Machine = 0x8664
    ArchiveSHA256 = '2a2804933924e38a502d62b61f0266cb80d56d65744f4c29876b2bf9c1544356'
    TunnelClientSHA256 = '6649169733686805ca16cccd91774594d0c017fd729c37ad4ce1cd18323d9ae8'
    CloudflaredSHA256 = 'c8405b5b4b92d2529202aeca634a3aa6ecdaa231f42238293e4a8a755bd6c1ff'
  }
}

function Assert-SHA256([string]$Path, [string]$Expected) {
  $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -cne $Expected) {
    throw "SHA-256 mismatch for $(Split-Path $Path -Leaf): expected $Expected, got $actual"
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
  throw "Tunnel client destination already exists: $Destination"
}

$archiveName = "tunnel-client-$release-windows-$($platform.Name).zip"
$url = "https://github.com/openai/tunnel-client/releases/download/$release/$archiveName"
$work = Join-Path $env:RUNNER_TEMP "CodexBridge-TunnelClient-$Architecture-$([Guid]::NewGuid().ToString('N'))"
$archive = Join-Path $work $archiveName
$extract = Join-Path $work 'extract'
New-Item -ItemType Directory -Path $extract -Force | Out-Null

try {
  Invoke-WebRequest -Uri $url -OutFile $archive
  Assert-SHA256 $archive $platform.ArchiveSHA256

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
  try {
    $expectedEntries = @(
      'cloudflared-manifest.json',
      'cloudflared.exe',
      'LICENSE',
      'NOTICE',
      "tunnel-client-$release-windows-$($platform.Name)-licenses.txt",
      "tunnel-client-$release-windows-$($platform.Name).spdx.json",
      'tunnel-client.exe'
    ) | Sort-Object
    $actualEntries = @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object)
    if (($actualEntries -join "`n") -cne ($expectedEntries -join "`n")) {
      throw "Unexpected entries in official tunnel-client archive: $($actualEntries -join ', ')"
    }
    foreach ($entry in $zip.Entries) {
      if ($entry.Length -le 0 -or $entry.FullName.Contains('/') -or $entry.FullName.Contains('\')) {
        throw "Invalid tunnel-client archive entry: $($entry.FullName)"
      }
    }
    [System.IO.Compression.ZipFileExtensions]::ExtractToDirectory($zip, $extract)
  } finally {
    $zip.Dispose()
  }

  $tunnelClient = Join-Path $extract 'tunnel-client.exe'
  $cloudflared = Join-Path $extract 'cloudflared.exe'
  Assert-SHA256 $tunnelClient $platform.TunnelClientSHA256
  Assert-SHA256 $cloudflared $platform.CloudflaredSHA256
  Assert-PEMachine $tunnelClient $platform.Machine
  Assert-PEMachine $cloudflared $platform.Machine

  New-Item -ItemType Directory -Path $Destination | Out-Null
  Copy-Item -LiteralPath $tunnelClient -Destination (Join-Path $Destination 'tunnel-client.exe')
  Copy-Item -LiteralPath $cloudflared -Destination (Join-Path $Destination 'cloudflared.exe')
  foreach ($name in $commonFiles) {
    Copy-Item -LiteralPath (Join-Path $extract $name) -Destination (Join-Path $Destination $name)
  }
  Copy-Item `
    -LiteralPath (Join-Path $extract "tunnel-client-$release-windows-$($platform.Name)-licenses.txt") `
    -Destination (Join-Path $Destination 'ThirdPartyLicenses.txt')
  Copy-Item `
    -LiteralPath (Join-Path $extract "tunnel-client-$release-windows-$($platform.Name).spdx.json") `
    -Destination (Join-Path $Destination 'SBOM.spdx.json')
  [System.IO.File]::WriteAllText(
    (Join-Path $Destination 'tunnel-client.sha256'),
    $platform.TunnelClientSHA256 + "`n",
    [System.Text.UTF8Encoding]::new($false)
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $Destination 'cloudflared.sha256'),
    $platform.CloudflaredSHA256 + "`n",
    [System.Text.UTF8Encoding]::new($false)
  )
  Write-Host "Staged OpenAI tunnel-client $release for $Architecture at $Destination"
} finally {
  if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
  }
}
