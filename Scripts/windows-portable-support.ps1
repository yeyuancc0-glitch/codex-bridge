function Get-FullPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "A path argument cannot be empty."
  }
  return [IO.Path]::GetFullPath($Path)
}

function Get-ComparablePath([string]$Path) {
  return ((Get-FullPath $Path) -replace "/", "\").TrimEnd("\")
}

function Test-SameOrChildPath([string]$Parent, [string]$Candidate) {
  $parentValue = Get-ComparablePath $Parent
  $candidateValue = Get-ComparablePath $Candidate
  return $candidateValue.Equals($parentValue, [StringComparison]::OrdinalIgnoreCase) -or
    $candidateValue.StartsWith("$parentValue\", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-RegularFile([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw "Expected a regular file: $Path"
  }
  return $item
}

function Assert-Directory([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw "Expected a regular directory: $Path"
  }
  return $item
}

function Ensure-SafeDirectoryChain([string]$Root, [string]$Target) {
  $rootValue = Get-ComparablePath $Root
  $targetValue = Get-ComparablePath $Target
  if (-not (Test-SameOrChildPath $rootValue $targetValue)) {
    throw "Directory target escapes its trusted root: $Target"
  }
  Assert-Directory $rootValue | Out-Null
  $relative = $targetValue.Substring($rootValue.Length).TrimStart("\")
  $current = $rootValue
  $components = $relative -split "\\"
  foreach ($component in $components) {
    if ([string]::IsNullOrEmpty($component)) {
      continue
    }
    $current = Join-Path $current $component
    if (Test-Path -LiteralPath $current) {
      Assert-Directory $current | Out-Null
    } else {
      New-Item -ItemType Directory -Path $current | Out-Null
      Assert-Directory $current | Out-Null
    }
  }
}

function Remove-ExactPath([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to remove a reparse point: $Path"
  }
  Remove-Item -LiteralPath $Path -Recurse -Force
}

function Get-PEMachine([string]$Path) {
  $stream = [IO.File]::OpenRead($Path)
  $reader = [IO.BinaryReader]::new($stream)
  try {
    if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne [UInt16]0x5A4D) {
      throw "Not a PE file: $Path"
    }
    $stream.Seek(0x3C, [IO.SeekOrigin]::Begin) | Out-Null
    $peOffset = $reader.ReadUInt32()
    if ($peOffset -gt 1MB -or $peOffset -gt ($stream.Length - 24)) {
      throw "Invalid PE header offset: $Path"
    }
    $stream.Seek([Int64]$peOffset, [IO.SeekOrigin]::Begin) | Out-Null
    if ($reader.ReadUInt32() -ne [UInt32]0x00004550) {
      throw "Invalid PE signature: $Path"
    }
    $machine = $reader.ReadUInt16()
    $stream.Seek([Int64]$peOffset + 22, [IO.SeekOrigin]::Begin) | Out-Null
    $characteristics = $reader.ReadUInt16()
    if ($machine -eq 0 -or ($characteristics -band [UInt16]0x0002) -eq 0) {
      throw "PE file is not an executable image: $Path"
    }
    return $machine
  } finally {
    $reader.Dispose()
  }
}

function Test-PEArchitectureCompatible(
  [string]$Path,
  [ValidateSet("x64", "arm64")]
  [string]$Architecture
) {
  $expected = if ($Architecture -eq "x64") { [UInt16]0x8664 } else { [UInt16]0xAA64 }
  if ((Get-PEMachine $Path) -eq $expected) {
    return $true
  }
  if ($Architecture -ne "arm64") {
    return $false
  }
  if (-not ("CodexBridgePortable.ImageMachineProbe" -as [type])) {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
namespace CodexBridgePortable {
  public static class ImageMachineProbe {
    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    public static extern int RtlGetImageFileMachines(string path, out uint machines);
  }
}
"@
  }
  [UInt32]$machines = 0
  try {
    $status = [CodexBridgePortable.ImageMachineProbe]::RtlGetImageFileMachines(
      (Get-FullPath $Path),
      [ref]$machines)
  } catch {
    return $false
  }
  return $status -eq 0 -and ($machines -band [UInt32]0x8) -ne 0
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
