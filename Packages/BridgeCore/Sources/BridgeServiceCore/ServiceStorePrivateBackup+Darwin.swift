#if canImport(Darwin)
  import Darwin
  import Foundation

  extension ServiceStorePrivateBackup {
    static func prepare(at path: String) throws -> Preparation {
      FileManager.default.fileExists(atPath: path) ? .existing : .newFileReady
    }

    static func protectAndValidate(at path: String) throws {
      guard chmod(path, 0o600) == 0 else {
        throw ServiceStoreError.storageFailure
      }
      try validate(at: path)
    }

    static func validate(at path: String) throws {
      var metadata = stat()
      guard lstat(path, &metadata) == 0,
        metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_mode & 0o777 == 0o600
      else {
        throw ServiceStoreError.storageFailure
      }
    }
  }
#endif
