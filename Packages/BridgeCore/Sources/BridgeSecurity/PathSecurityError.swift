import Foundation

public enum PathSecurityError: Error, LocalizedError, Sendable, Equatable {
  case invalidRelativePath(String)
  case rootUnavailable
  case rootIdentityChanged
  case fileIdentityChanged
  case pathDoesNotExist
  case pathEscapeBlocked
  case sensitiveFileBlocked
  case unsupportedFileType
  case fileTooLarge(maximumBytes: Int)
  case binaryFileBlocked
  case readFailed(Int32)

  public var errorDescription: String? {
    switch self {
    case .invalidRelativePath(let reason):
      "Invalid relative path: \(reason)"
    case .rootUnavailable:
      "The registered project root is unavailable."
    case .rootIdentityChanged:
      "The project root no longer has its registered filesystem identity."
    case .fileIdentityChanged:
      "The requested file changed after path validation."
    case .pathDoesNotExist:
      "The requested path does not exist."
    case .pathEscapeBlocked:
      "The requested path resolves outside the registered project."
    case .sensitiveFileBlocked:
      "The requested path is blocked by the sensitive-file policy."
    case .unsupportedFileType:
      "Only regular files can be read."
    case .fileTooLarge(let maximumBytes):
      "The file exceeds the \(maximumBytes)-byte read limit."
    case .binaryFileBlocked:
      "Binary files cannot be returned through this text API."
    case .readFailed(let code):
      "The file could not be read (errno \(code))."
    }
  }
}
