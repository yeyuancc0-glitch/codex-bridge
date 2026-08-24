param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'ARM64')]
  [string]$Architecture,

  [Parameter(Mandatory = $true)]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'

$release = 'v0.0.11'
$commonFiles = @('cloudflared-manifest.json', 'LICENSE')
$platform = if ($Architecture -eq 'ARM64') {
  @{
    Name = 'arm64'
    Machine = 0xAA64
    ArchiveSHA256 = '38f015a720404c8ccd5976a0d6aed18d931899697eaf208548b5eb3d0f6e8592'
    TunnelClientSHA256 = 'ced04bcbc68d54cba5353e94ede8eb5c7d7621ba4809653af37d51f990b0e751'
    CloudflaredSHA256 = 'b6f2d34d9413a9ec42a790f95045f6607e4b12c0c786c1b8d084c8067ac989f0'
  }
} else {
  @{
    Name = 'amd64'
    Machine = 0x8664
    ArchiveSHA256 = 'eb912c86c6ccde90cda805cb17009507176a656725cf86c36fabe1901a12e29b'
    TunnelClientSHA256 = '7d3c7d492ce84b52835e11865a835a8a5bcd4a669dee84e169aa11b314dc952a'
    CloudflaredSHA256 = '88024cf82cec72d10604c13aa4670016dca375c602e200b551ec9d53b31e874d'
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
