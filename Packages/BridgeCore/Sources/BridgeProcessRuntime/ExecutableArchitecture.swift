import BridgePlatform
import Foundation

public enum WindowsExecutableArchitecture: String, Codable, Equatable, Sendable {
  case amd64 = "x86_64"
  case arm64
  case i386
  case unknown
}

public enum PortableExecutableError: Error, Equatable, Sendable {
  case invalidHeader
  case headerTooLarge
  case unsupportedArchitecture(UInt16)
  case unreadable
}

public struct PortableExecutableInspector: Sendable {
  public static func architecture(in data: Data) throws -> WindowsExecutableArchitecture {
    guard data.count >= 64,
      readUInt16(data, at: 0) == 0x5A4D,
      let peOffset = readUInt32(data, at: 0x3C),
      let offset = Int(exactly: peOffset),
      offset <= data.count - 6
    else {
      throw PortableExecutableError.invalidHeader
    }
    guard
      data[offset] == 0x50,
      data[offset + 1] == 0x45,
      data[offset + 2] == 0,
      data[offset + 3] == 0,
      let machine = readUInt16(data, at: offset + 4)
    else {
      throw PortableExecutableError.invalidHeader
    }
    return try architecture(machine: machine)
  }

  public static func architecture(
    at url: URL,
    maximumHeaderOffset: Int = 1_048_576
  ) throws -> WindowsExecutableArchitecture {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw PortableExecutableError.unreadable
    }
    defer { try? handle.close() }

    let prefix: Data
    do {
      prefix = try handle.read(upToCount: 64) ?? Data()
    } catch {
      throw PortableExecutableError.unreadable
    }
    guard prefix.count >= 64,
      readUInt16(prefix, at: 0) == 0x5A4D,
      let peOffset = readUInt32(prefix, at: 0x3C)
    else {
      throw PortableExecutableError.invalidHeader
    }
    guard maximumHeaderOffset >= 0,
      peOffset <= UInt32(clamping: maximumHeaderOffset)
    else {
      throw PortableExecutableError.headerTooLarge
    }

    do {
      try handle.seek(toOffset: UInt64(peOffset))
      let header = try handle.read(upToCount: 6) ?? Data()
      guard header.count == 6,
        header[0] == 0x50,
        header[1] == 0x45,
        header[2] == 0,
        header[3] == 0,
        let machine = readUInt16(header, at: 4)
      else {
        throw PortableExecutableError.invalidHeader
      }
      return try architecture(machine: machine)
    } catch let error as PortableExecutableError {
      throw error
    } catch {
      throw PortableExecutableError.unreadable
    }
  }

  private static func architecture(machine: UInt16) throws -> WindowsExecutableArchitecture {
    switch machine {
    case 0x8664:
      return .amd64
    case 0xAA64:
      return .arm64
    case 0x014C:
      return .i386
    default:
      throw PortableExecutableError.unsupportedArchitecture(machine)
    }
  }

  private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }
}

public struct WindowsExecutableArchitecturePolicy: Sendable {
  public static func supports(
    executable: WindowsExecutableArchitecture,
    process: PlatformArchitecture
  ) -> Bool {
    switch process {
    case .amd64:
      return executable == .amd64
    case .arm64:
      return executable == .arm64 || executable == .amd64
    case .unknown:
      return false
    }
  }
}
