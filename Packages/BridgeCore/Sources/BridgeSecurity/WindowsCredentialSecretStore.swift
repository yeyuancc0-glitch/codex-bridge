#if canImport(WinSDK)
  import Foundation
  import WinSDK

  /// Current-user Windows Credential Manager storage for Bridge secrets.
  /// Credential blobs are protected by Windows and are never written to the
  /// service database or passed through process arguments.
  public struct WindowsCredentialSecretStore: SecretStore, Sendable {
    public static let defaultService = "com.openai.codex-bridge.secrets"
    public static let maximumSecretBytes = 2_560

    private enum Constants {
      static let generic = DWORD(1)
      static let persistLocalMachine = DWORD(2)
      static let errorAccessDenied = DWORD(5)
      static let errorNotFound = DWORD(1_168)
    }

    private let service: String

    public init(service: String = Self.defaultService) {
      precondition(!service.isEmpty && service.utf8.count <= 255)
      self.service = service
    }

    public func store(_ secret: Data, for reference: SecretReference) throws {
      guard !secret.isEmpty, secret.count <= Self.maximumSecretBytes else {
        throw SecretStoreError.invalidSecret
      }
      let target = WideBuffer(targetName(for: reference))
      try secret.withUnsafeBytes { bytes in
        let blob = bytes.bindMemory(to: BYTE.self)
        var credential = CREDENTIALW()
        credential.Type = Constants.generic
        credential.TargetName = target.pointer
        credential.CredentialBlobSize = DWORD(secret.count)
        credential.CredentialBlob = blob.baseAddress.map { UnsafeMutablePointer(mutating: $0) }
        credential.Persist = Constants.persistLocalMachine
        guard CredWriteW(&credential, 0) else { throw map(GetLastError()) }
      }
    }

    public func load(_ reference: SecretReference) throws -> Data {
      let target = WideBuffer(targetName(for: reference))
      var credential: PCREDENTIALW?
      guard CredReadW(target.pointer, Constants.generic, 0, &credential) else {
        throw map(GetLastError())
      }
      guard let credential else { throw SecretStoreError.invalidStoredValue }
      defer { CredFree(credential) }
      let value = credential.pointee
      let count = Int(value.CredentialBlobSize)
      guard count > 0, count <= Self.maximumSecretBytes, let blob = value.CredentialBlob else {
        throw SecretStoreError.invalidStoredValue
      }
      return Data(bytes: blob, count: count)
    }

    public func remove(_ reference: SecretReference) throws {
      let target = WideBuffer(targetName(for: reference))
      guard !CredDeleteW(target.pointer, Constants.generic, 0) else { return }
      let error = GetLastError()
      guard error != Constants.errorNotFound else { return }
      throw map(error)
    }

    private func targetName(for reference: SecretReference) -> String {
      "\(service):\(reference.rawValue)"
    }

    private func map(_ error: DWORD) -> SecretStoreError {
      switch error {
      case Constants.errorNotFound:
        .notFound
      case Constants.errorAccessDenied:
        .accessDenied
      default:
        .credentialStoreFailure(UInt32(error))
      }
    }
  }

  private final class WideBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<WCHAR>

    init(_ value: String) {
      var units = Array(value.utf16)
      units.append(0)
      pointer = .allocate(capacity: units.count)
      units.withUnsafeBufferPointer { buffer in
        pointer.initialize(from: buffer.baseAddress!, count: buffer.count)
      }
    }

    deinit {
      pointer.deallocate()
    }
  }
#endif
