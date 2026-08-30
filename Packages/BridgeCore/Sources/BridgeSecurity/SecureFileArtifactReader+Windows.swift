#if os(Windows)
  import Foundation
  import WinSDK

  extension SecureFileArtifactReader {
    static func readData(at path: String, maximumBytes: Int) throws -> Data {
      let canonicalPath = try SecureFileArtifactSnapshot.windowsCanonicalPath(for: path)
      let handle = canonicalPath.withCString(encodedAs: UTF16.self) { wide in
        CreateFileW(
          wide,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw SecureFileArtifactError.openFailed
      }
      defer { _ = CloseHandle(handle) }

      guard let metadata = SecureFileArtifactSnapshot.windowsMetadata(of: handle) else {
        throw SecureFileArtifactError.metadataUnavailable
      }
      let regular =
        metadata.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        && metadata.attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      guard regular else { throw SecureFileArtifactError.notRegularFile }
      guard metadata.size <= UInt64(maximumBytes) else {
        throw SecureFileArtifactError.fileTooLarge
      }

      var result = Data()
      result.reserveCapacity(Int(metadata.size))
      var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
      while true {
        let requested = min(buffer.count, maximumBytes + 1 - result.count)
        var readBytes: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(requested), &readBytes, nil)
        }
        guard succeeded else { throw SecureFileArtifactError.readFailed }
        if readBytes == 0 { return result }
        guard result.count + Int(readBytes) <= maximumBytes else {
          throw SecureFileArtifactError.fileTooLarge
        }
        result.append(contentsOf: buffer.prefix(Int(readBytes)))
      }
    }
  }
#endif
