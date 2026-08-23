#if canImport(WinSDK)
  import BridgePlatformWindows

  extension ServiceStorePrivateBackup {
    static func prepare(at path: String) throws -> Preparation {
      do {
        return try WindowsPrivateBackupProtection.create(at: path)
          ? .newFileReady
          : .existing
      } catch {
        throw ServiceStoreError.storageFailure
      }
    }

    static func protectAndValidate(at path: String) throws {
      do {
        try WindowsPrivateBackupProtection.protectAndValidate(at: path)
      } catch {
        throw ServiceStoreError.storageFailure
      }
    }

    static func validate(at path: String) throws {
      do {
        try WindowsPrivateBackupProtection.validate(at: path)
      } catch {
        throw ServiceStoreError.storageFailure
      }
    }
  }
#endif
