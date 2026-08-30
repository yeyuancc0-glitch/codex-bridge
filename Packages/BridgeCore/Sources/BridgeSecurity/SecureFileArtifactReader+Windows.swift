#if os(Windows)
  import Foundation
  import WinSDK

  extension SecureFileArtifactReader {
    static func readPrefixData(at path: String, maximumBytes: Int) throws -> Data {
      let canonicalPath = try SecureFileArtifactSnapshot.windowsCanonicalPath(for: path)
      let handle: HANDLE
      do {
        (handle, _) = try WindowsSecureFile.openAbsoluteRegularFileResolving(
          canonicalPath,
          desiredAccess: DWORD(GENERIC_READ)
        )
      } catch {
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
      return try readPrefix(handle, maximumBytes: maximumBytes)
    }

    static func readData(at path: String, maximumBytes: Int) throws -> Data {
      let canonicalPath = try SecureFileArtifactSnapshot.windowsCanonicalPath(for: path)
      let handle: HANDLE
      do {
        (handle, _) = try WindowsSecureFile.openAbsoluteRegularFileResolving(
          canonicalPath,
          desiredAccess: DWORD(GENERIC_READ)
        )
      } catch {
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

    private static func readPrefix(_ handle: HANDLE, maximumBytes: Int) throws -> Data {
      var result = Data()
      var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes))
      while result.count < maximumBytes {
        let requested = min(buffer.count, maximumBytes - result.count)
        var readBytes: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(requested), &readBytes, nil)
        }
        guard succeeded else { throw SecureFileArtifactError.readFailed }
        if readBytes == 0 { return result }
        result.append(contentsOf: buffer.prefix(Int(readBytes)))
      }
      return result
    }
  }
#endif
