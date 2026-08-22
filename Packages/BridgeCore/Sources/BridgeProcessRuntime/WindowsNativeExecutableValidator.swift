#if canImport(WinSDK)
  import BridgePlatform
  import Foundation
  import WinSDK

  public enum WindowsExecutableValidationError: Error, Equatable, Sendable {
    case invalidPath
    case networkPathDenied
    case openFailed(Int32)
    case reparsePointDenied
    case notRegularFile
    case unsupportedArchitecture(WindowsExecutableArchitecture, PlatformArchitecture)
    case invalidPortableExecutable
  }

  public struct WindowsExecutableIdentity: Equatable, Sendable {
    public let volumeSerialNumber: UInt64
    public let fileID: [UInt8]

    public init(volumeSerialNumber: UInt64, fileID: [UInt8]) {
      self.volumeSerialNumber = volumeSerialNumber
      self.fileID = fileID
    }
  }

  public struct WindowsNativeExecutableValidator: Sendable {
    public static func isValid(
      _ url: URL,
      processArchitecture: PlatformArchitecture
    ) -> Bool {
      do {
        let lease = try WindowsExecutableLease(
          url: url,
          processArchitecture: processArchitecture
        )
        lease.close()
        return true
      } catch {
        return false
      }
    }
  }

  final class WindowsExecutableLease: @unchecked Sendable {
    let canonicalURL: URL
    let architecture: WindowsExecutableArchitecture
    let identity: WindowsExecutableIdentity

    private let lock = NSLock()
    private var handle: HANDLE?

    init(url: URL, processArchitecture: PlatformArchitecture) throws {
      let path = url.path
      guard url.pathExtension.lowercased() == "exe" else {
        throw WindowsExecutableValidationError.invalidPath
      }
      do {
        _ = try WindowsLocalPathValidator.validate(path, kind: .regularFile)
      } catch let error as WindowsLocalPathError {
        throw Self.executablePathError(error)
      }

      let opened = try Self.open(path: path)
      do {
        let attributes = try Self.attributes(of: opened)
        guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
          throw WindowsExecutableValidationError.reparsePointDenied
        }
        guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
          GetFileType(opened) == DWORD(FILE_TYPE_DISK)
        else {
          throw WindowsExecutableValidationError.notRegularFile
        }

        let canonicalPath = try Self.finalPath(handle: opened)
        guard !canonicalPath.hasPrefix("\\\\?\\UNC\\"), !canonicalPath.hasPrefix("\\\\") else {
          throw WindowsExecutableValidationError.networkPathDenied
        }
        guard WindowsPath.equivalent(canonicalPath, path) else {
          throw WindowsExecutableValidationError.reparsePointDenied
        }
        let canonicalURL = URL(fileURLWithPath: canonicalPath)
        let architecture: WindowsExecutableArchitecture
        do {
          architecture = try PortableExecutableInspector.architecture(at: canonicalURL)
        } catch {
          throw WindowsExecutableValidationError.invalidPortableExecutable
        }
        guard
          WindowsExecutableArchitecturePolicy.supports(
            executable: architecture,
            process: processArchitecture
          )
        else {
          throw WindowsExecutableValidationError.unsupportedArchitecture(
            architecture,
            processArchitecture
          )
        }

        self.canonicalURL = canonicalURL
        self.architecture = architecture
        self.identity = try Self.identity(of: opened)
        self.handle = opened
      } catch {
        CloseHandle(opened)
        throw error
      }
    }

    deinit {
      close()
    }

    func close() {
      lock.lock()
      let current = handle
      handle = nil
      lock.unlock()
      if let current { CloseHandle(current) }
    }

    private static func open(path: String) throws -> HANDLE {
      var wide = Array(path.utf16)
      wide.append(0)
      let handle = wide.withUnsafeBufferPointer { buffer in
        CreateFileW(
          buffer.baseAddress,
          DWORD(0x120_089),  // FILE_GENERIC_READ (macro, not exported)
          DWORD(FILE_SHARE_READ),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsExecutableValidationError.openFailed(Int32(GetLastError()))
      }
      return handle
    }

    private static func attributes(of handle: HANDLE) throws -> DWORD {
      var info = FILE_ATTRIBUTE_TAG_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileAttributeTagInfo,
          &info,
          DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)
        )
      else {
        throw WindowsExecutableValidationError.openFailed(Int32(GetLastError()))
      }
      return info.FileAttributes
    }

    private static func finalPath(handle: HANDLE) throws -> String {
      let flags = DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)
      let length = GetFinalPathNameByHandleW(handle, nil, 0, flags)
      guard length > 0 else {
        throw WindowsExecutableValidationError.openFailed(Int32(GetLastError()))
      }
      var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
      let written = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), flags)
      guard written > 0, written < DWORD(buffer.count) else {
        throw WindowsExecutableValidationError.openFailed(Int32(GetLastError()))
      }
      let value = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
      if value.hasPrefix("\\\\?\\") { return String(value.dropFirst(4)) }
      return value
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
        throw WindowsExecutableValidationError.openFailed(Int32(GetLastError()))
      }
      let bytes = withUnsafeBytes(of: info.FileId.Identifier) { Array($0) }
      return WindowsExecutableIdentity(
        volumeSerialNumber: info.VolumeSerialNumber,
        fileID: bytes
      )
    }

    private static func executablePathError(
      _ error: WindowsLocalPathError
    ) -> WindowsExecutableValidationError {
      switch error {
      case .invalidPath:
        return .invalidPath
      case .networkPathDenied:
        return .networkPathDenied
      case .unavailable(let code):
        return .openFailed(code)
      case .reparsePointDenied:
        return .reparsePointDenied
      case .wrongKind:
        return .notRegularFile
      }
    }
  }
#endif
