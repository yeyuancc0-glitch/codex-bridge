#if canImport(WinSDK)
  import Foundation
  import WinSDK

  enum WindowsLocalPathKind: Sendable {
    case regularFile
    case directory
  }

  enum WindowsLocalPathError: Error, Equatable, Sendable {
    case invalidPath
    case networkPathDenied
    case unavailable(Int32)
    case reparsePointDenied
    case wrongKind
  }

  struct WindowsLocalPathValidator: Sendable {
    static func validate(
      _ rawPath: String,
      kind: WindowsLocalPathKind
    ) throws -> String {
      let path = WindowsPath.normalize(rawPath)
      guard !path.hasPrefix("\\\\") else {
        throw WindowsLocalPathError.networkPathDenied
      }
      guard isDriveAbsolute(path), !path.contains("\0") else {
        throw WindowsLocalPathError.invalidPath
      }

      let root = String(path.prefix(3))
      let components = path.dropFirst(3).split(
        separator: "\\",
        omittingEmptySubsequences: false
      ).map(String.init)
      guard components.allSatisfy(isSafeComponent) else {
        throw WindowsLocalPathError.invalidPath
      }

      var current = root
      var currentAttributes = try attributes(at: current)
      try rejectReparse(currentAttributes)
      for component in components where !component.isEmpty {
        current = current.hasSuffix("\\") ? current + component : current + "\\" + component
        currentAttributes = try attributes(at: current)
        try rejectReparse(currentAttributes)
      }

      switch kind {
      case .regularFile:
        guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0 else {
          throw WindowsLocalPathError.wrongKind
        }
      case .directory:
        guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 else {
          throw WindowsLocalPathError.wrongKind
        }
      }
      return path
    }

    private static func attributes(at path: String) throws -> DWORD {
      var wide = Array(path.utf16)
      wide.append(0)
      let value = wide.withUnsafeBufferPointer { buffer in
        GetFileAttributesW(buffer.baseAddress)
      }
      guard value != DWORD(INVALID_FILE_ATTRIBUTES) else {
        throw WindowsLocalPathError.unavailable(Int32(GetLastError()))
      }
      return value
    }

    private static func rejectReparse(_ attributes: DWORD) throws {
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw WindowsLocalPathError.reparsePointDenied
      }
    }

    private static func isDriveAbsolute(_ path: String) -> Bool {
      let units = Array(path.utf16)
      guard units.count >= 3,
        units[1] == 58,
        units[2] == 92
      else { return false }
      return (65...90).contains(Int(units[0])) || (97...122).contains(Int(units[0]))
    }

    private static func isSafeComponent(_ component: String) -> Bool {
      guard component != ".", component != "..", !component.contains(":") else {
        return false
      }
      guard !component.hasSuffix("."), !component.hasSuffix(" ") else { return false }
      return true
    }
  }
#endif
