import BridgeSecurity
import Foundation

struct DeepSeekHarnessACPFileSnapshot: Sendable {
  let path: String
  let device: UInt64
  let inode: UInt64
  let fileSize: UInt64
  let modificationTimeNanoseconds: Int64
  let sha256: String

  init(capturing path: String, requiresExecutable: Bool) throws {
    do {
      let snapshot = try SecureFileArtifactSnapshot(
        capturing: path,
        requiresExecutable: requiresExecutable
      )
      self.path = snapshot.canonicalPath
      self.device = snapshot.device
      self.inode = snapshot.inode
      self.fileSize = snapshot.fileSize
      self.modificationTimeNanoseconds = snapshot.modificationTimeNanoseconds
      self.sha256 = snapshot.sha256
    } catch let error as SecureFileArtifactError {
      throw DeepSeekHarnessACPError.artifactInvalid(Self.field(for: error))
    }
  }

  private static func field(for error: SecureFileArtifactError) -> String {
    switch error {
    case .invalidPath:
      "path"
    case .openFailed:
      "open"
    case .executableRequired:
      "executable"
    case .readFailed, .invalidDigest:
      "digest"
    case .changed:
      "changed"
    case .invalidModificationTime:
      "mtime"
    default:
      "identity"
    }
  }
}
