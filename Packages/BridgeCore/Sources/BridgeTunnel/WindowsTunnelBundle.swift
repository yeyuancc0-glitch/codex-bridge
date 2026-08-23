#if canImport(WinSDK)
  import BridgePlatformWindows
  import Foundation
  import WinSDK

  public enum WindowsTunnelBundleError: Error, Equatable, Sendable {
    case invalidInstallDirectory
    case missingPayload
    case reparsePointDenied
    case invalidDigest
    case unavailable(Int32)
  }

  public struct WindowsTunnelBundle: Equatable, Sendable {
    public let helperExecutable: URL
    public let expectedSHA256: String

    public init(installDirectory: URL) throws {
      guard installDirectory.isFileURL else {
        throw WindowsTunnelBundleError.invalidInstallDirectory
      }
      let root = WindowsTunnelPathRules.normalize(installDirectory.path)
      guard WindowsTunnelPathRules.isLocalAbsolutePath(root) else {
        throw WindowsTunnelBundleError.invalidInstallDirectory
      }
      let payload = Self.join(root, "TunnelClient")
      let helper = Self.join(payload, "tunnel-client.exe")
      let digest = Self.join(payload, "tunnel-client.sha256")
      try Self.validateComponents(path: helper)
      try Self.validateComponents(path: digest)
      expectedSHA256 = try Self.readDigest(path: digest)
      helperExecutable = URL(fileURLWithPath: helper)
    }

    private static func validateComponents(path: String) throws {
      var current = String(path.prefix(3))
      for componentSlice in path.dropFirst(3).split(separator: "\\") {
        let component = String(componentSlice)
        guard WindowsTunnelPathRules.isSafeEntryName(component) else {
          throw WindowsTunnelBundleError.invalidInstallDirectory
        }
        current = join(current, component)
        let wide = WideBuffer(current)
        let attributes = GetFileAttributesW(wide.pointer)
        guard attributes != INVALID_FILE_ATTRIBUTES else {
          let code = GetLastError()
          throw code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND)
            ? WindowsTunnelBundleError.missingPayload
            : WindowsTunnelBundleError.unavailable(Int32(code))
        }
        guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
          throw WindowsTunnelBundleError.reparsePointDenied
        }
      }
    }

    private static func readDigest(path: String) throws -> String {
      let wide = WideBuffer(path)
      let handle = CreateFileW(
        wide.pointer,
        DWORD(0x120_089),
        DWORD(FILE_SHARE_READ),
        nil,
        DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
        nil
      )
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsTunnelBundleError.unavailable(Int32(GetLastError()))
      }
      defer { CloseHandle(handle) }

      var attributes = FILE_ATTRIBUTE_TAG_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileAttributeTagInfo,
          &attributes,
          DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)
        )
      else {
        throw WindowsTunnelBundleError.unavailable(Int32(GetLastError()))
      }
      guard attributes.FileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw WindowsTunnelBundleError.reparsePointDenied
      }
      guard attributes.FileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        GetFileType(handle) == DWORD(FILE_TYPE_DISK)
      else {
        throw WindowsTunnelBundleError.invalidDigest
      }

      var metadata = FILE_STANDARD_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileStandardInfo,
          &metadata,
          DWORD(MemoryLayout<FILE_STANDARD_INFO>.size)
        )
      else {
        throw WindowsTunnelBundleError.unavailable(Int32(GetLastError()))
      }
      guard metadata.NumberOfLinks == 1, metadata.DeletePending == 0,
        (64...66).contains(metadata.EndOfFile.QuadPart)
      else {
        throw WindowsTunnelBundleError.invalidDigest
      }

      var bytes = [UInt8](repeating: 0, count: Int(metadata.EndOfFile.QuadPart))
      var count = DWORD(0)
      let byteCount = DWORD(bytes.count)
      let read = bytes.withUnsafeMutableBytes { buffer in
        ReadFile(handle, buffer.baseAddress, byteCount, &count, nil)
      }
      guard read, count == DWORD(bytes.count),
        let value = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines
        ),
        WindowsTunnelPathRules.isValidSHA256(value)
      else {
        throw WindowsTunnelBundleError.invalidDigest
      }
      return value
    }

    private static func join(_ parent: String, _ child: String) -> String {
      parent.hasSuffix("\\") ? parent + child : parent + "\\" + child
    }
  }
#endif
