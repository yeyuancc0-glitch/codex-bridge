#if os(Windows)
  import Foundation
  import WinSDK

  /// Windows Credential Manager backed SecretStore. Generic credential blobs
  /// are capped at 5 * 512 bytes by CredMan, which is well within the sizes
  /// used for tunnel runtime keys and MCP path secrets.
  public struct WindowsCredentialStore: SecretStore, Sendable {
    public static let defaultService = "com.openai.codex-bridge.secrets"
    public static let maximumSecretBytes = 2_560

    private let service: String

    public init(service: String = Self.defaultService) {
      precondition(!service.isEmpty && service.utf8.count <= 255)
      self.service = service
    }

    public func store(_ secret: Data, for reference: SecretReference) throws {
      guard !secret.isEmpty, secret.count <= Self.maximumSecretBytes else {
        throw SecretStoreError.invalidSecret
      }
      try withTarget(reference) { target in
        var credential = CREDENTIALW(
          Flags: 0,
          Type: UInt32(CRED_TYPE_GENERIC),
          TargetName: UnsafeMutablePointer(mutating: target),
          Comment: nil,
          LastWritten: FILETIME(dwLowDateTime: 0, dwHighDateTime: 0),
          CredentialBlobSize: UInt32(secret.count),
          CredentialBlob: UnsafeMutablePointer(
            mutating: secret.withUnsafeBytes {
              $0.baseAddress?.assumingMemoryBound(to: UInt8.self)
            }),
          Persist: UInt32(CRED_PERSIST_LOCAL_MACHINE),
          AttributeCount: 0,
          Attributes: nil,
          TargetAlias: nil,
          UserName: nil
        )
        let status = CredWriteW(&credential, 0)
        guard status else {
          throw Self.map(Int32(GetLastError()))
        }
      }
    }

    public func load(_ reference: SecretReference) throws -> Data {
      try withTarget(reference) { target in
        var credentialPointer: UnsafeMutablePointer<CREDENTIALW>?
        let status = CredReadW(target, UInt32(CRED_TYPE_GENERIC), 0, &credentialPointer)
        guard status, let credential = credentialPointer?.pointee else {
          defer {
            if let pointer = credentialPointer { CredFree(pointer) }
          }
          throw Self.map(Int32(GetLastError()))
        }
        defer { CredFree(credentialPointer) }
        let blobSize = Int(credential.CredentialBlobSize)
        guard blobSize > 0, blobSize <= Self.maximumSecretBytes,
          let blob = credential.CredentialBlob
        else {
          throw SecretStoreError.invalidStoredValue
        }
        return Data(bytes: blob, count: blobSize)
      }
    }

    public func remove(_ reference: SecretReference) throws {
      try withTarget(reference) { target in
        let status = CredDeleteW(target, UInt32(CRED_TYPE_GENERIC), 0)
        guard status else {
          let error = Int32(GetLastError())
          guard error != Int32(ERROR_NOT_FOUND) else { return }
          throw Self.map(error)
        }
      }
    }

    private func withTarget<R>(
      _ reference: SecretReference,
      _ body: (UnsafePointer<WCHAR>) throws -> R
    ) throws -> R {
      let target = "\(service).\(reference.rawValue)"
      return try target.withCString(encodedAs: UTF16.self) { wide in
        try body(wide)
      }
    }

    private static func map(_ status: Int32) -> SecretStoreError {
      switch status {
      case Int32(ERROR_NOT_FOUND), Int32(ERROR_FILE_NOT_FOUND):
        return .notFound
      case Int32(ERROR_ACCESS_DENIED):
        return .accessDenied
      default:
        return .keychainFailure(status)
      }
    }
  }
#endif
