import Crypto
import Foundation

public struct SecureFileRevision: Equatable, Sendable {
  public let sha256: String
  public let byteCount: Int

  public init(sha256: String, byteCount: Int) {
    self.sha256 = sha256
    self.byteCount = byteCount
  }

  public static func digest(of data: Data) -> SecureFileRevision {
    let digest = SHA256.hash(data: data)
    return SecureFileRevision(
      sha256: digest.map { String(format: "%02x", $0) }.joined(),
      byteCount: data.count
    )
  }
}

public enum SecureWriteMode: Equatable, Sendable {
  case create
  case replace
}

public struct SecureWriteResult: Equatable, Sendable {
  public let mode: SecureWriteMode
  public let oldRevision: SecureFileRevision?
  public let newRevision: SecureFileRevision
}

public struct SecureFileWriterStats: Sendable {
  public let openedRoot: Int32
  public let parentDescriptor: Int32
  public let targetDescriptor: Int32

  public init(openedRoot: Int32, parentDescriptor: Int32, targetDescriptor: Int32) {
    self.openedRoot = openedRoot
    self.parentDescriptor = parentDescriptor
    self.targetDescriptor = targetDescriptor
  }
}

public enum SecureDirectoryAction: Equatable, Sendable {
  case deleteFile(expectedSHA256: String?)
  case moveFile(sourceExpectedSHA256: String?, destinationExpectedAbsent: Bool)
  case createDirectory
  case deleteEmptyDirectory
}

public struct SecureDirectoryMutationResult: Equatable, Sendable {
  public let action: SecureDirectoryAction
  public let revision: SecureFileRevision?
}
