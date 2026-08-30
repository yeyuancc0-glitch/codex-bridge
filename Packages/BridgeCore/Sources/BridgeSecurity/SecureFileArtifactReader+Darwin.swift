#if canImport(Darwin)
  import Darwin
  import Foundation

  extension SecureFileArtifactReader {
    static func readData(at path: String, maximumBytes: Int) throws -> Data {
      let canonicalPath = URL(fileURLWithPath: path)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
      try SecureFileArtifactSnapshot.validateAbsolutePath(canonicalPath)
      let descriptor = Darwin.open(canonicalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw SecureFileArtifactError.openFailed }
      defer { Darwin.close(descriptor) }

      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0 else {
        throw SecureFileArtifactError.metadataUnavailable
      }
      guard metadata.st_mode & S_IFMT == S_IFREG else {
        throw SecureFileArtifactError.notRegularFile
      }
      guard metadata.st_size >= 0, UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
        throw SecureFileArtifactError.fileTooLarge
      }

      var result = Data()
      result.reserveCapacity(Int(metadata.st_size))
      var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
      while true {
        let requested = min(buffer.count, maximumBytes + 1 - result.count)
        let count = buffer.withUnsafeMutableBytes { bytes in
          Darwin.read(descriptor, bytes.baseAddress, requested)
        }
        if count == 0 { return result }
        if count < 0 {
          if errno == EINTR { continue }
          throw SecureFileArtifactError.readFailed
        }
        guard result.count + count <= maximumBytes else {
          throw SecureFileArtifactError.fileTooLarge
        }
        result.append(contentsOf: buffer.prefix(count))
      }
    }
  }
#endif
