#if canImport(WinSDK)
  import BridgePlatform
  import BridgePlatformWindows
  import BridgeProcessRuntime
  import Crypto
  import Foundation
  import WinSDK

  public enum WindowsTunnelHelperError: Error, Equatable, Sendable {
    case invalidPath
    case networkPathDenied
    case reparsePointDenied
    case openFailed(Int32)
    case notRegularFile
    case invalidPortableExecutable
    case invalidDigest
    case digestMismatch
    case unsupportedArchitecture(WindowsExecutableArchitecture, PlatformArchitecture)
  }

  public struct WindowsTunnelVerifiedHelper: Equatable, Sendable {
    public let executable: URL
    public let architecture: WindowsExecutableArchitecture
    public let identity: WindowsExecutableIdentity
    public let sha256: String

    public init(
      executable: URL,
      architecture: WindowsExecutableArchitecture,
      identity: WindowsExecutableIdentity,
      sha256: String
    ) {
      self.executable = executable
      self.architecture = architecture
      self.identity = identity
      self.sha256 = sha256
    }
  }

  /// Verifies a bundled Windows Tunnel helper without executing it.
  ///
  /// The digest and PE header are read from the same no-reparse handle that is
  /// used to capture the file identity. This keeps the verification result
  /// tied to the local file object rather than to a path that may be replaced
  /// while it is being inspected.
  public struct WindowsTunnelHelperVerifier: Sendable {
    public init() {}

    public func verify(
      executable: URL,
      expectedSHA256: String,
      expectedArchitecture: PlatformArchitecture = TargetPlatformArchitecture.current
    ) throws -> WindowsTunnelVerifiedHelper {
      guard Self.isValidSHA256(expectedSHA256) else {
        throw WindowsTunnelHelperError.invalidDigest
      }
      let path = try Self.validatedLocalExecutablePath(executable)
      let handle = try Self.open(path: path)
      defer { CloseHandle(handle) }

      try Self.validateRegularExecutable(handle: handle)
      let canonicalPath = try Self.finalPath(handle: handle)
      guard WindowsTunnelPathRules.isLocalAbsolutePath(canonicalPath),
        WindowsPath.equivalent(canonicalPath, path)
      else {
        throw WindowsTunnelHelperError.reparsePointDenied
      }

      let identity = try Self.identity(of: handle)
      let inspected = try Self.inspectAndHash(handle: handle)
      guard
        Self.matchesNativeArchitecture(
          inspected.architecture,
          expected: expectedArchitecture
        )
      else {
        throw WindowsTunnelHelperError.unsupportedArchitecture(
          inspected.architecture,
          expectedArchitecture
        )
      }
      guard inspected.sha256 == expectedSHA256 else {
        throw WindowsTunnelHelperError.digestMismatch
      }
      return WindowsTunnelVerifiedHelper(
        executable: URL(fileURLWithPath: canonicalPath),
        architecture: inspected.architecture,
        identity: identity,
        sha256: inspected.sha256
      )
    }

    static func matchesNativeArchitecture(
      _ executable: WindowsExecutableArchitecture,
      expected: PlatformArchitecture
    ) -> Bool {
      switch expected {
      case .amd64:
        return executable == .amd64
      case .arm64:
        return executable == .arm64
      case .unknown:
        return false
      }
    }

    static func isValidSHA256(_ value: String) -> Bool {
      WindowsTunnelPathRules.isValidSHA256(value)
    }

    private static func validatedLocalExecutablePath(_ executable: URL) throws -> String {
      guard executable.isFileURL else { throw WindowsTunnelHelperError.invalidPath }
      let path = WindowsTunnelPathRules.normalize(executable.path)
      guard WindowsTunnelPathRules.isLocalAbsolutePath(path), path.lowercased().hasSuffix(".exe")
      else {
        throw WindowsTunnelPathRules.isLocalAbsolutePath(path)
          ? WindowsTunnelHelperError.invalidPath
          : (path.hasPrefix("\\\\")
            ? WindowsTunnelHelperError.networkPathDenied
            : WindowsTunnelHelperError.invalidPath)
      }

      var current = String(path.prefix(3))
      try validatePathComponent(current)
      let components = path.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
      for componentSlice in components {
        let component = String(componentSlice)
        guard WindowsTunnelPathRules.isSafeEntryName(component) else {
          throw WindowsTunnelHelperError.invalidPath
        }
        current += component
        try validatePathComponent(current)
        current += "\\"
      }
      return path
    }

    private static func validatePathComponent(_ path: String) throws {
      let wide = WideBuffer(path)
      let attributes = GetFileAttributesW(wide.pointer)
      guard attributes != INVALID_FILE_ATTRIBUTES else {
        throw WindowsTunnelHelperError.openFailed(Int32(GetLastError()))
      }
      guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw WindowsTunnelHelperError.reparsePointDenied
      }
    }

    private static func open(path: String) throws -> HANDLE {
      let wide = WideBuffer(path)
      let handle = CreateFileW(
        wide.pointer,
        DWORD(0x120_089),  // FILE_GENERIC_READ (macro, not exported)
        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
        nil,
        DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
        nil
      )
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsTunnelHelperError.openFailed(Int32(GetLastError()))
      }
      return handle
    }

    private static func validateRegularExecutable(handle: HANDLE) throws {
      var attributes = FILE_ATTRIBUTE_TAG_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileAttributeTagInfo,
          &attributes,
          DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)
        )
      else {
        throw WindowsTunnelHelperError.openFailed(Int32(GetLastError()))
      }
      guard attributes.FileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw WindowsTunnelHelperError.reparsePointDenied
      }
      guard attributes.FileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        GetFileType(handle) == DWORD(FILE_TYPE_DISK)
      else {
        throw WindowsTunnelHelperError.notRegularFile
      }
    }

    private static func finalPath(handle: HANDLE) throws -> String {
      let flags = DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)
      let length = GetFinalPathNameByHandleW(handle, nil, 0, flags)
      guard length > 0 else {
        throw WindowsTunnelHelperError.openFailed(Int32(GetLastError()))
      }
      var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
      let written = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), flags)
      guard written > 0, written < DWORD(buffer.count) else {
        throw WindowsTunnelHelperError.openFailed(Int32(GetLastError()))
      }
      let value = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
      return value.hasPrefix("\\\\?\\") ? String(value.dropFirst(4)) : value
    }

    private static func identity(of handle: HANDLE) throws -> WindowsExecutableIdentity {
      var info = FILE_ID_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileIdInfo,
          &info,
          DWORD(MemoryLayout<FILE_ID_INFO>.size)
        )
      else {
        throw WindowsTunnelHelperError.openFailed(Int32(GetLastError()))
      }
      let bytes = withUnsafeBytes(of: info.FileId.Identifier) { Array($0) }
      return WindowsExecutableIdentity(
        volumeSerialNumber: info.VolumeSerialNumber,
        fileID: bytes
      )
    }

    private static func inspectAndHash(
      handle: HANDLE
    ) throws -> (architecture: WindowsExecutableArchitecture, sha256: String) {
      var prefixBuffer = [UInt8](repeating: 0, count: 1_048_576)
      var prefixCount = DWORD(0)
      let prefixRead = prefixBuffer.withUnsafeMutableBytes { bytes in
        ReadFile(
          handle,
          bytes.baseAddress,
          DWORD(bytes.count),
          &prefixCount,
          nil
        )
      }
      guard prefixRead else {
        throw WindowsTunnelHelperError.openFailed(Int32(GetLastError()))
      }
      let prefix = Data(prefixBuffer.prefix(Int(prefixCount)))
      let architecture: WindowsExecutableArchitecture
      do {
        architecture = try PortableExecutableInspector.architecture(in: prefix)
      } catch {
        throw WindowsTunnelHelperError.invalidPortableExecutable
      }

      var hasher = SHA256()
      hasher.update(data: prefix)
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while true {
        var count = DWORD(0)
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &count, nil)
        }
        guard succeeded else {
          throw WindowsTunnelHelperError.openFailed(Int32(GetLastError()))
        }
        guard count > 0 else { break }
        hasher.update(data: Data(buffer.prefix(Int(count))))
      }
      let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      return (architecture, digest)
    }

  }
#endif
