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
  case writeFailed(Int32)
  case mutationAppliedDurabilityUncertain(Int32)
  case targetAlreadyExists
  case targetNotRegularFile
  case unsupportedHardLink
  case revisionConflict
  case pathChanged

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
      "The file exceeds the \(maximumBytes)-byte limit."
    case .binaryFileBlocked:
      "Binary files cannot be used through this text API."
    case .readFailed(let code):
      "The file could not be read (errno \(code))."
    case .writeFailed(let code):
      "The file could not be written (errno \(code))."
    case .mutationAppliedDurabilityUncertain(let code):
      "The mutation was applied, but directory durability could not be confirmed (errno \(code))."
    case .targetAlreadyExists:
      "The target already exists."
    case .targetNotRegularFile:
      "The target is not a regular file."
    case .unsupportedHardLink:
      "The target has multiple hard links and cannot be replaced safely."
    case .revisionConflict:
      "The file content does not match the expected revision."
    case .pathChanged:
      "The target changed after it was validated."
    }
  }
}
